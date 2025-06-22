import os
import requests
import pandas as pd
import json
import psycopg2
from psycopg2.extras import execute_values
from datetime import date, timedelta, datetime
import numpy as np # Added for np.inf, np.nan, np.isinf
import logging
from typing import List, Dict, Any, Optional
import pandas.io.sql
from decimal import Decimal, ROUND_HALF_UP
import time # for sleep in fetch_data_from_api

# Assuming aws_utils.py is in a 'utils' subdirectory relative to this script
try:
    from .utils.aws_utils import get_api_key_from_secret
except ImportError:
    # Fallback for direct execution or if utils is a sibling (adjust as needed for your execution context)
    from utils.aws_utils import get_api_key_from_secret

# --- Configuration ---
API_BASE_URL = "https://api.sdetest.volka.team"
API_ENDPOINT = "/campaigns-report"

# Consistent table name, assumed to be what schema.sql creates
TARGET_TABLE_NAME = "campaign_performance_raw_appends"

# --- Logging Setup ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# --- Helper Functions ---
def fetch_data_from_api(api_key_header: dict, period_from: str, period_to: str,
                        lod: str = 'a', lifedays: str = '1,3,7,14',
                        retries: int = 3, backoff_factor: float = 0.5) -> Optional[List[Dict[str, Any]]]:
    """Fetches data from the Volka SDE Test API."""
    url = f"{API_BASE_URL}{API_ENDPOINT}"
    params = {
        "lod": lod,
        "period_from": period_from,
        "period_to": period_to,
        "lifedays": lifedays
    }
    
    for attempt in range(retries):
        try:
            response = requests.get(url, headers=api_key_header, params=params, timeout=30)
            response.raise_for_status()  # Raises HTTPError for bad responses (4XX or 5XX)
            logger.info(f"Successfully fetched data for {period_from} to {period_to}. Status: {response.status_code}")
            try:
                return response.json()
            except requests.exceptions.JSONDecodeError:
                logger.error(f"Failed to decode JSON from API response (attempt {attempt + 1}/{retries}). Response text: {response.text[:500]}")
                # This is a server-side issue, so we let the retry mechanism handle it.
        except requests.exceptions.HTTPError as e:
            logger.error(f"HTTP error fetching API data (attempt {attempt + 1}/{retries}): {e.response.status_code} - {e.response.text}")
            if e.response.status_code == 404: # No data found
                logger.info(f"No data found (404) for period {period_from} to {period_to}. Returning empty list.")
                return [] 
            if e.response.status_code < 500 and e.response.status_code != 429: 
                break 
        except requests.exceptions.RequestException as e:
            logger.error(f"Request error fetching API data (attempt {attempt + 1}/{retries}): {e}")
        
        if attempt < retries - 1:
            sleep_time = backoff_factor * (2 ** attempt)
            logger.info(f"Retrying in {sleep_time} seconds...")
            time.sleep(sleep_time)
        else:
            logger.error("Max retries reached. Failed to fetch API data.")
            return None
    return None


def transform_data(api_data: List[Dict[str, Any]]) -> pd.DataFrame:
    """Transforms raw API data into a structured DataFrame."""
    if not api_data:
        return pd.DataFrame()

    # Define columns that should be non-negative
    NON_NEGATIVE_COLS = [
        'spend_cents', 'impressions', 'clicks', 'registrations', 'cpc_cents',
        'players_1d', 'payers_1d', 'payments_1d', 'revenue_1d_cents',
        'players_3d', 'payers_3d', 'payments_3d', 'revenue_3d_cents',
        'players_7d', 'payers_7d', 'payments_7d', 'revenue_7d_cents',
        'players_14d', 'payers_14d', 'payments_14d', 'revenue_14d_cents',
        'ctr', 'cr' # CTR and CR should be >= 0
    ]

    processed_records = []
    for record in api_data:
        transformed_record = {
            'campaigns_execution_date': record.get('date'),
            'campaign_name': record.get('campaign'),
            'ad_name': record.get('ad', 'N/A'),
            # Default 'cost' to 0 if missing or None, as spend_cents is NOT NULL
            'spend_cents': record.get('cost') or 0,
            'impressions': record.get('impressions'),
            'clicks': record.get('clicks'),
            'registrations': record.get('registrations'),
            'ctr': record.get('ctr'),
            'cr': record.get('cr'),
            'cpc_cents': record.get('cpc')
        }

        # Convert CPC from currency unit to cents, similar to revenue
        cpc_val = transformed_record.get('cpc_cents')
        if cpc_val is not None:
            transformed_record['cpc_cents'] = int(Decimal(str(cpc_val)) * Decimal('100').to_integral_value(rounding=ROUND_HALF_UP))


        lifeday_metrics_map = {str(m['lifeday']): m for m in record.get('metrics', [])}
        
        for ld in [1, 3, 7, 14]:
            metric = lifeday_metrics_map.get(str(ld))
            transformed_record[f'players_{ld}d'] = metric.get('players') if metric else None
            transformed_record[f'payers_{ld}d'] = metric.get('payers') if metric else None
            transformed_record[f'payments_{ld}d'] = metric.get('payments') if metric else None
            
            revenue_val = metric.get('revenue') if metric else None
            if revenue_val is not None:
                transformed_record[f'revenue_{ld}d_cents'] = int(Decimal(str(revenue_val)) * Decimal('100').to_integral_value(rounding=ROUND_HALF_UP))
            else:
                transformed_record[f'revenue_{ld}d_cents'] = None
        
        processed_records.append(transformed_record)

    df = pd.DataFrame(processed_records)
    
    if not df.empty:
        # The 'is_current' column is initialized with Python booleans, which pandas correctly
        # handles. Explicit casting is not necessary as we no longer rely on pandas schema inference.
        df['campaigns_execution_date'] = pd.to_datetime(df['campaigns_execution_date']).dt.date

        # Define columns and their target dtypes for Pandas
        # Using nullable types (Int64, Float64) to handle potential NaNs/None
        column_dtypes = {
            'spend_cents': 'Int64', 'impressions': 'Int64', 'clicks': 'Int64',
            'registrations': 'Int64', 'cpc_cents': 'Int64',
            'players_1d': 'Int64', 'payers_1d': 'Int64', 'payments_1d': 'Int64', 'revenue_1d_cents': 'Int64',
            'players_3d': 'Int64', 'payers_3d': 'Int64', 'payments_3d': 'Int64', 'revenue_3d_cents': 'Int64',
            'players_7d': 'Int64', 'payers_7d': 'Int64', 'payments_7d': 'Int64', 'revenue_7d_cents': 'Int64',
            'players_14d': 'Int64', 'payers_14d': 'Int64', 'payments_14d': 'Int64', 'revenue_14d_cents': 'Int64',
            'ctr': 'Float64', 'cr': 'Float64'
        }

        for col, dtype in column_dtypes.items():
            if col not in df.columns:
                 logger.warning(f"Column '{col}' not found in DataFrame for type casting. Skipping.")
                 continue

            # Step 1: Coerce to numeric, turning errors into NaN
            s_numeric = pd.to_numeric(df[col], errors='coerce')

            # Step 2: Handle infinities (relevant for float types)
            if pd.api.types.is_float_dtype(s_numeric.dtype):
                if np.isinf(s_numeric.to_numpy()).any(): # Use .to_numpy() for reliable check on Series with NAs
                    logger.warning(f"Column '{col}' contains infinity values. Replacing with NaN.")
                    s_numeric = s_numeric.replace([np.inf, -np.inf], np.nan) # np.nan will be converted to pd.NA by Int64

            # Step 3: Handle negative values for specified columns
            if col in NON_NEGATIVE_COLS:
                 negative_count = (s_numeric < 0).sum()
                 if negative_count > 0:
                     logger.warning(f"Column '{col}' contains {negative_count} negative values. Replacing with 0.")
                     # Replace negative values with 0, keep NaN/NA as they are
                     s_numeric = s_numeric.apply(lambda x: max(x, 0) if pd.notna(x) else x)

            # Step 4: Cast to the target nullable dtype
            try:
                df[col] = s_numeric.astype(dtype)
            except Exception as e:
                logger.error(f"Failed to cast column '{col}' to {dtype}. Error: {e}. Filling with NA.")
                df[col] = pd.Series([pd.NA] * len(df), dtype=dtype) # Fallback: fill with NA

        # After all conversions, fill any remaining NAs in numeric columns with 0
        # This ensures dbt's 'numeric' type tests pass even if original data was missing/non-numeric
        df[list(column_dtypes.keys())] = df[list(column_dtypes.keys())].fillna(0)

        df['ad_name'] = df['ad_name'].fillna('N/A')

    if not df.empty:
        # Define essential leading and trailing columns
        leading_cols = ['campaigns_execution_date', 'campaign_name', 'ad_name']

        # Get all other columns from the DataFrame
        other_cols = [col for col in df.columns if col not in leading_cols]

        # Construct the dynamic column order
        # Metadata columns like _etl_loaded_at can go at the end.
        # For simplicity, we just sort the non-key columns.
        column_order = leading_cols + sorted(other_cols)

        # Ensure all expected columns are present before reordering
        # This is a safeguard if a column was expected but not generated in processed_records
        # For simplicity, we assume all columns in df.columns are desired.
        df = df[column_order]
    
    return df


def append_data_to_postgres(df: pd.DataFrame, table_name: str, db_conn_params: dict):
    """
    Appends data from a DataFrame to a PostgreSQL table using an efficient INSERT.
    This is a simple append-only operation.
    """
    if df.empty:
        logger.info("No data to load.")
        return

    conn = None
    # Add the load timestamp just before loading
    df['_etl_loaded_at'] = datetime.utcnow()
    try:
        conn = psycopg2.connect(**db_conn_params)
        cursor = conn.cursor()

        # Prepare data for insertion
        data_tuples = [tuple(x) for x in df.replace({pd.NA: None, np.nan: None}).values]
        cols = ', '.join([f'"{c}"' for c in df.columns])

        # Execute the insert
        insert_query = f"INSERT INTO {table_name} ({cols}) VALUES %s"
        execute_values(cursor, insert_query, data_tuples)
        appended_count = cursor.rowcount
        logger.info(f"Appended {appended_count} new rows into {table_name}.")

        conn.commit()

    except Exception as e:
        logger.error(f"Database error during append load: {e}")
        if conn:
            conn.rollback()
        raise
    finally:
        if conn:
            cursor.close()
            conn.close()

def get_last_loaded_date(db_conn_params: dict, table_name: str = TARGET_TABLE_NAME) -> Optional[date]:
    """Queries the database to find the maximum execution date in the specified table."""
    conn = None
    try:
        conn = psycopg2.connect(**db_conn_params)
        cursor = conn.cursor()
        query = f"SELECT MAX(campaigns_execution_date) FROM {table_name};"
        cursor.execute(query)
        result = cursor.fetchone()
        if result and result[0]:
            logger.info(f"Last loaded date in '{table_name}' is {result[0]}.")
            return result[0]
        else:
            logger.info(f"No data found in '{table_name}' or no execution date recorded.")
            return None
    except psycopg2.Error as e:
        logger.error(f"Database error while fetching last loaded date: {e}")
        # Depending on policy, you might want to raise this or handle it
        # For now, returning None will trigger the 5-year lookback.
        return None
    finally:
        if conn:
            if 'cursor' in locals() and cursor:
                cursor.close()
            conn.close()


def _process_etl_chunk(api_key_header: dict, chunk_start_date_str: str, chunk_end_date_str: str, db_conn_params: dict) -> bool:
    """
    Processes a single ETL chunk: Fetches, transforms, and loads data.
    Returns True if successful, False otherwise (for this chunk).
    """
    logger.info(f"Processing chunk: {chunk_start_date_str} to {chunk_end_date_str}")

    raw_data = fetch_data_from_api(api_key_header, chunk_start_date_str, chunk_end_date_str, lod='a')
    if raw_data is None:
        logger.error(f"Failed to extract data for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
        return False
    if not raw_data:
        logger.info(f"No data from API for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
        return True # No data is not an error for the chunk itself

    transformed_df = transform_data(raw_data)
    if transformed_df.empty:
        logger.info(f"No data after transformation for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
        return True # No data to load is not an error

    logger.info(f"Transformed {len(transformed_df)} records for chunk.")
    try:
        append_data_to_postgres(transformed_df, TARGET_TABLE_NAME, db_conn_params)
        logger.info(f"Successfully loaded data for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
        return True
    except psycopg2.Error as db_err: # Specifically catch DB errors from append_data_to_postgres
        logger.error(f"Database error loading data for chunk {chunk_start_date_str} to {chunk_end_date_str}: {db_err}")
        raise # Re-raise to ensure the ETL process acknowledges this critical failure
    except Exception as e:
        logger.error(f"Unexpected error loading data for chunk {chunk_start_date_str} to {chunk_end_date_str}: {e}")
        # Re-raise as a runtime error to make it a critical failure for the ETL
        raise RuntimeError(f"Critical failure in chunk processing for {chunk_start_date_str}-{chunk_end_date_str}") from e


def _perform_initial_load(api_key_header: dict, target_date: date, db_conn_params: dict):
    """Performs the initial 5-year load, processing backwards month by month."""
    initial_load_newest_date = target_date
    initial_load_oldest_target_date = target_date - timedelta(days=(5 * 365) + 1) # Approx 5 years

    logger.info(f"Database is empty. Performing initial 5-year load, processing month by month "
                f"from {initial_load_newest_date.strftime('%Y-%m-%d')} back to {initial_load_oldest_target_date.strftime('%Y-%m-%d')}.")

    current_chunk_iteration_end_date = initial_load_newest_date

    while current_chunk_iteration_end_date >= initial_load_oldest_target_date:
        current_chunk_month_start_date = datetime(current_chunk_iteration_end_date.year, current_chunk_iteration_end_date.month, 1).date()
        chunk_start_date_for_api = max(current_chunk_month_start_date, initial_load_oldest_target_date)
        chunk_end_date_for_api = current_chunk_iteration_end_date

        chunk_start_date_str = chunk_start_date_for_api.strftime('%Y-%m-%d')
        chunk_end_date_str = chunk_end_date_for_api.strftime('%Y-%m-%d')

        if not _process_etl_chunk(api_key_header, chunk_start_date_str, chunk_end_date_str, db_conn_params):
            logger.warning(f"Chunk {chunk_start_date_str} to {chunk_end_date_str} failed. Moving to previous month for initial load.")
            # Note: _process_etl_chunk now raises on critical error, so this path might not be hit
            # if the failure is critical. If it returns False for non-critical, this logic is fine.

        current_chunk_iteration_end_date = chunk_start_date_for_api - timedelta(days=1)
    logger.info("Initial 5-year load process completed.")


def _perform_incremental_load(api_key_header: dict, last_loaded_db_date: date, target_date: date, db_conn_params: dict):
    """Performs incremental load from last_loaded_db_date + 1 day up to target_date."""
    incremental_fetch_start_date = last_loaded_db_date + timedelta(days=1)
    incremental_fetch_end_date = target_date

    if incremental_fetch_start_date > incremental_fetch_end_date:
        logger.info(f"Data is already up to date (last loaded: {last_loaded_db_date}, target: {target_date}). No new data to fetch.")
        return

    logger.info(f"Incremental load: Fetching data from {incremental_fetch_start_date.strftime('%Y-%m-%d')} to {incremental_fetch_end_date.strftime('%Y-%m-%d')}")

    current_chunk_process_start_date = incremental_fetch_start_date
    while current_chunk_process_start_date <= incremental_fetch_end_date:
        current_month_end = (datetime(current_chunk_process_start_date.year, current_chunk_process_start_date.month, 1) +
                                timedelta(days=32)).replace(day=1) - timedelta(days=1)
        
        chunk_end_date_for_api = min(current_month_end.date(), incremental_fetch_end_date)
        chunk_start_date_str = current_chunk_process_start_date.strftime('%Y-%m-%d')
        chunk_end_date_str = chunk_end_date_for_api.strftime('%Y-%m-%d')

        if not _process_etl_chunk(api_key_header, chunk_start_date_str, chunk_end_date_str, db_conn_params):
            logger.warning(f"Chunk {chunk_start_date_str} to {chunk_end_date_str} failed during incremental load. Skipping to next chunk.")
            # Note: _process_etl_chunk now raises on critical error, so this path might not be hit
            # if the failure is critical.

        current_chunk_process_start_date = chunk_end_date_for_api + timedelta(days=1)
    logger.info("Incremental load process completed.")


def main_etl_flow(target_processing_date_str: str):
    """
    Main ETL flow.
    Fetches data up to target_processing_date_str.
    If the target table is empty, it fetches data for the last 5 years.
    Otherwise, it fetches data from the day after the last loaded date.
    """
    logger.info(f"Starting ETL process, targeting data up to: {target_processing_date_str}")

    try:
        target_date = datetime.strptime(target_processing_date_str, '%Y-%m-%d').date()
    except ValueError:
        logger.error(f"Invalid target_processing_date_str format: {target_processing_date_str}. Expected YYYY-MM-DD. Aborting.")
        raise ValueError(f"ETL Aborted: Invalid target_processing_date_str format: {target_processing_date_str}")

    api_key_secret_name = os.getenv("API_KEY_SECRET_NAME", "test/sde_api/key") 
    aws_region = os.getenv("AWS_REGION", "eu-central-1")
    try:
        api_key_header = get_api_key_from_secret(api_key_secret_name, aws_region)
        if not api_key_header: # Ensure api_key_header is not None or empty
            raise ValueError("Retrieved API key header is empty or invalid.")
    except Exception as e:
        logger.error(f"Failed to retrieve API key: {e}. Aborting ETL.")
        raise RuntimeError(f"ETL Aborted: Failed to retrieve API key ({api_key_secret_name})") from e

    db_password_secret_name = os.getenv("DB_PASSWORD_SECRET_NAME")
    db_password = None
    if db_password_secret_name:
        try:
            # Use the imported get_api_key_from_secret, assuming it can fetch generic secrets.
            # This function might return a dict (e.g. {'x-api-key': 'val'}) or the direct secret string.
            # Adjust based on get_api_key_from_secret's actual behavior and DB secret structure.
            retrieved_secret_content = get_api_key_from_secret(db_password_secret_name, aws_region)

            if isinstance(retrieved_secret_content, dict):
                # If the secret is stored as JSON, e.g., {"password": "mysecretpassword"}
                db_password = retrieved_secret_content.get("password")
                if db_password is None:
                    # Attempt to use a common alternative if the API key function returns the key directly
                    db_password = retrieved_secret_content.get(list(retrieved_secret_content.keys())[0]) if len(retrieved_secret_content.keys()) == 1 else None
                    if db_password is None:
                        raise ValueError(f"Key 'password' or a single value not found in DB secret dictionary: {db_password_secret_name}")
            elif isinstance(retrieved_secret_content, str):
                # If the secret is stored as a plain string
                db_password = retrieved_secret_content
            else:
                raise ValueError(f"Unexpected type from secret manager for {db_password_secret_name}: {type(retrieved_secret_content)}")
            if not db_password:
                 raise ValueError(f"DB Password retrieved from {db_password_secret_name} is empty.")
        except Exception as e:
            logger.error(f"Failed to retrieve DB password from Secrets Manager ({db_password_secret_name}): {e}. Aborting ETL.")
            raise RuntimeError(f"ETL Aborted: Failed to retrieve DB password from Secrets Manager ({db_password_secret_name})") from e

    db_conn_params = {
        "host": os.getenv("DB_HOST"),
        "database": os.getenv("DB_NAME"),
        "user": os.getenv("DB_USER"),
        "password": db_password if db_password else os.getenv("DB_PASSWORD"), # Fallback for local testing if needed
        "port": os.getenv("DB_PORT", "5432")
    }
    if not all(db_conn_params.get(k) for k in ["host", "database", "user"]): # Check .get(k) for robustness
        logger.error("Database connection parameters (DB_HOST, DB_NAME, DB_USER) are not fully set. Aborting ETL.")
        raise ValueError("ETL Aborted: Essential database connection parameters (DB_HOST, DB_NAME, DB_USER) are not set.")

    last_date_in_db = get_last_loaded_date(db_conn_params) # This function is fine

    if last_date_in_db is None:
        _perform_initial_load(api_key_header, target_date, db_conn_params)
    else:
        _perform_incremental_load(api_key_header, last_date_in_db, target_date, db_conn_params)


if __name__ == "__main__":
    # For local testing, load .env file if it exists
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except ImportError:
        logger.info("python-dotenv not found, .env file will not be loaded. Ensure environment variables are set.")

    # For local testing, this will be the end date of the period to process.
    # The script will determine the actual start date based on DB content.
    target_date_param = os.getenv("ETL_TARGET_PROCESSING_DATE", date.today().strftime('%Y-%m-%d'))

    try:
        datetime.strptime(target_date_param, '%Y-%m-%d')
    except ValueError:
        logger.error("Invalid date format. Please use YYYY-MM-DD. Exiting.")
        exit(1)
    main_etl_flow(target_date_param)