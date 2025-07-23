import os
import requests
import pandas as pd
import psycopg2
import awswrangler as wr
import duckdb
from psycopg2.extras import execute_values
from datetime import date, timedelta, datetime
import numpy as np
import logging
from typing import List, Dict, Any, Optional
from decimal import Decimal, ROUND_HALF_UP
import time

# Assuming aws_utils.py is in a 'utils' subdirectory relative to this script
from .utils.aws_utils import get_api_key_from_secret, get_secret

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
    """Fetches data from the API with a robust retry mechanism.

    This function handles transient network errors, server-side issues (5xx), and
    rate limiting (429) by using an exponential backoff retry strategy. A 404
    (Not Found) status is treated as a successful call that simply returned no data.

    Args:
        api_key_header: The authorization header containing the API key.
        period_from: The start date of the reporting period (YYYY-MM-DD).
        period_to: The end date of the reporting period (YYYY-MM-DD).
        lod, lifedays: API-specific parameters for data granularity.
        retries: The maximum number of retry attempts.
        backoff_factor: The base factor for calculating sleep time between retries.

    Returns:
        A list of dictionaries representing the raw data, an empty list if no data
        is found (404), or None if the request ultimately fails after all retries.
    """
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
                logger.error(f"API returned non-JSON response (attempt {attempt + 1}/{retries}). Response text: {response.text[:500]}")
                # This is treated as a server-side issue, allowing the retry mechanism to handle it.
        except requests.exceptions.HTTPError as e:
            logger.error(f"HTTP error fetching API data (attempt {attempt + 1}/{retries}): {e.response.status_code} - {e.response.text}")
            if e.response.status_code == 404: # A 404 indicates no data for the period, which is not an error.
                logger.info(f"API returned 404 (No Data Found) for period {period_from} to {period_to}. Returning empty list.")
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
    """Transforms raw API data into a structured and cleaned DataFrame.

    This function performs several key transformations:
    - Unnests the 'metrics' list into distinct columns for each lifeday (1d, 3d, 7d, 14d).
    - Converts monetary values (cost, cpc, revenue) to cents (integers) to prevent
      floating-point inaccuracies during calculations.
    - Enforces consistent, nullable data types for all numeric columns.
    - Cleans data by handling nulls, infinities, and negative values in key metrics.

    Args:
        api_data: A list of dictionaries, with each dictionary being a raw record from the API.

    Returns:
        A pandas DataFrame with cleaned, structured, and consistently typed data.
    """
    if not api_data:
        return pd.DataFrame()

    # Define columns that should be non-negative
    NON_NEGATIVE_COLS = [
        'spend_cents', 'impressions', 'clicks', 'registrations', 'cpc_cents',
        'players_1d', 'payers_1d', 'payments_1d', 'revenue_1d_cents',
        'players_3d', 'payers_3d', 'payments_3d', 'revenue_3d_cents',
        'players_7d', 'payers_7d', 'payments_7d', 'revenue_7d_cents',
        'players_14d', 'payers_14d', 'payments_14d', 'revenue_14d_cents', # Note: spend_cents is handled via default
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
        # Standardize date column to datetime.date objects for database compatibility.
        df['campaigns_execution_date'] = pd.to_datetime(df['campaigns_execution_date']).dt.date

        # Define columns and their target dtypes for Pandas.
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

            # Robustly convert columns to their target numeric types, handling data quality issues.
            s_numeric = pd.to_numeric(df[col], errors='coerce')

            # Replace infinite values (e.g., from division by zero) with NaN.
            if pd.api.types.is_float_dtype(s_numeric.dtype): # Check only applies to float columns
                if np.isinf(s_numeric.to_numpy()).any(): # Use .to_numpy() for reliable check on Series with NAs
                    logger.warning(f"Column '{col}' contains infinity values. Replacing with NaN.")
                    s_numeric = s_numeric.replace([np.inf, -np.inf], np.nan) # np.nan will be converted to pd.NA by Int64

            # Ensure key metrics are non-negative, replacing negative values with 0.
            if col in NON_NEGATIVE_COLS:
                 negative_count = (s_numeric < 0).sum()
                 if negative_count > 0:
                     logger.warning(f"Column '{col}' contains {negative_count} negative values. Replacing with 0.")
                     s_numeric = s_numeric.apply(lambda x: max(x, 0) if pd.notna(x) else x)

            # Cast to the final target nullable dtype (e.g., 'Int64').
            try:
                df[col] = s_numeric.astype(dtype)
            except Exception as e:
                logger.error(f"Failed to cast column '{col}' to {dtype}. Error: {e}. Filling with NA.")
                df[col] = pd.Series([pd.NA] * len(df), dtype=dtype) # Fallback: fill with NA

        # Business Decision: After all conversions, fill any remaining NAs in numeric
        # columns with 0. This ensures that downstream analytics and database
        # constraints (e.g., NOT NULL) are met.
        df[list(column_dtypes.keys())] = df[list(column_dtypes.keys())].fillna(0)
        # Ensure 'ad_name' has a consistent default value.
        df['ad_name'] = df['ad_name'].fillna('N/A')

    if not df.empty:
        # Define essential leading and trailing columns
        leading_cols = ['campaigns_execution_date', 'campaign_name', 'ad_name']

        # Get all other columns from the DataFrame
        other_cols = [col for col in df.columns if col not in leading_cols]

        # Enforce a consistent column order for reliable loading.
        column_order = leading_cols + sorted(other_cols)
        df = df[column_order]
    
    return df


def append_data_to_iceberg(df: pd.DataFrame, table_name: str, lakehouse_params: dict):
    """Appends data from a DataFrame to an Iceberg table using DuckDB.

    This function provides a conceptual example of writing to a local Iceberg
    table managed by DuckDB. A full production setup would typically use a
    shared catalog like AWS Glue.

    Args:
        df: The DataFrame containing the data to load.
        table_name: The name of the target Iceberg table.
        lakehouse_params: A dictionary containing the path to the DuckDB file.
    """
    if df.empty:
        logger.info("No data to load to Iceberg.")
        return

    db_file = lakehouse_params.get("duckdb_path")
    if not db_file:
        raise ValueError("duckdb_path not provided in lakehouse_params for Iceberg sink.")

    # Add the load timestamp just before loading
    df['_etl_loaded_at'] = datetime.utcnow()

    try:
        with duckdb.connect(db_file) as con:
            # DuckDB can directly query pandas DataFrames registered as virtual tables.
            con.register('df_to_load', df)

            # Idempotent table creation: Create the table from the DataFrame schema if it doesn't exist.
            # This makes the ETL script self-sufficient for the local lakehouse setup.
            # The schema is inferred directly from the pandas DataFrame.
            con.execute(f"CREATE TABLE IF NOT EXISTS {table_name} AS SELECT * FROM df_to_load LIMIT 0")

            # Now, the INSERT operation will succeed.
            con.execute(f"INSERT INTO {table_name} SELECT * FROM df_to_load")
            appended_count = len(df)
            logger.info(f"Appended {appended_count} new rows into Iceberg table {table_name}.")
    except Exception as e:
        logger.error(f"DuckDB/Iceberg error during append load: {e}")
        raise


def append_data_to_iceberg_glue(df: pd.DataFrame, table_name: str, lakehouse_params: dict):
    """Appends data from a DataFrame to a Glue-cataloged Iceberg table on S3.

    This function uses the awswrangler library, which is well-suited for this task
    in a cloud environment. It handles writing Parquet files to S3 and updating
    the Iceberg table metadata in the AWS Glue Data Catalog.

    Args:
        df: The DataFrame containing the data to load.
        table_name: The name of the target Iceberg table.
        lakehouse_params: A dictionary containing the S3 path and Glue database name.
    """
    if df.empty:
        logger.info("No data to load to Iceberg on S3.")
        return

    s3_path = lakehouse_params.get("s3_path")
    glue_database = lakehouse_params.get("glue_database")

    # Add the load timestamp just before loading
    df['_etl_loaded_at'] = datetime.utcnow()

    wr.s3.to_iceberg(df=df, database=glue_database, table=table_name, s3_path=s3_path)
    logger.info(f"Successfully wrote {len(df)} rows to Glue Iceberg table '{glue_database}.{table_name}'.")

def append_data_to_postgres(df: pd.DataFrame, table_name: str, db_conn_params: dict):
    """Appends data from a DataFrame to a PostgreSQL table.

    This function uses the highly efficient `psycopg2.extras.execute_values`
    to perform a bulk INSERT operation. It is an append-only operation.

    Args:
        df: The DataFrame containing the data to load.
        table_name: The name of the target database table.
        db_conn_params: A dictionary of connection parameters for psycopg2.
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
    except (psycopg2.Error, psycopg2.OperationalError) as e:
        logger.warning(f"Could not connect to DB or query failed: {e}. "
                       "Returning None, which will trigger an initial load if applicable.")
        return None
    finally:
        if conn:
            if 'cursor' in locals() and cursor:
                cursor.close()
            conn.close()

def get_last_loaded_date_from_iceberg(lakehouse_params: dict, table_name: str = TARGET_TABLE_NAME) -> Optional[date]:
    """Queries an Iceberg table via DuckDB to find the maximum execution date."""
    db_file = lakehouse_params.get("duckdb_path")
    if not db_file:
        raise ValueError("duckdb_path not provided for get_last_loaded_date_from_iceberg.")

    try:
        with duckdb.connect(db_file, read_only=True) as con:
            # Check if table exists first to prevent errors on initial load
            tables = con.execute("SHOW TABLES;").fetchall()
            if any(table_name in t for t in tables):
                result = con.execute(f"SELECT MAX(campaigns_execution_date) FROM {table_name};").fetchone()
                if result and result[0]:
                    logger.info(f"Last loaded date in Iceberg table '{table_name}' is {result[0]}.")
                    return result[0]
            logger.info(f"No data found in Iceberg table '{table_name}'.")
            return None
    except Exception as e:
        logger.warning(f"Could not query Iceberg table via DuckDB: {e}. Returning None.")
        return None


def _process_etl_chunk(api_key_header: dict, chunk_start_date_str: str, chunk_end_date_str: str, db_conn_params: dict) -> bool:
    """Processes a single ETL chunk: fetch, transform, and load.

    This function orchestrates the ETL process for a specific date range (a "chunk").

    Args:
        api_key_header: The API key header for the request.
        chunk_start_date_str: The start date for the API query.
        chunk_end_date_str: The end date for the API query.
        db_conn_params: Database connection parameters.

    Returns:
        True on success (including no-data scenarios).

    Raises:
        RuntimeError or psycopg2.Error on critical, unrecoverable failures during the load step.
    """
    sink_type = os.getenv("ETL_SINK_TYPE", "postgres") # Default to postgres

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
    
    if sink_type == "duckdb_iceberg":
        try:
            append_data_to_iceberg(transformed_df, TARGET_TABLE_NAME, db_conn_params)
            logger.info(f"Successfully loaded data to Iceberg for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
            return True
        except Exception as e:
            logger.error(f"Unexpected error loading data to Iceberg for chunk {chunk_start_date_str} to {chunk_end_date_str}: {e}")
            raise RuntimeError(f"Critical failure in Iceberg chunk processing for {chunk_start_date_str}-{chunk_end_date_str}") from e
    elif sink_type == "redshift_iceberg":
        try:
            append_data_to_iceberg_glue(transformed_df, TARGET_TABLE_NAME, db_conn_params)
        except Exception as e:
            logger.error(f"Unexpected error loading data to Glue/S3 Iceberg for chunk {chunk_start_date_str} to {chunk_end_date_str}: {e}")
            raise RuntimeError(f"Critical failure in Iceberg chunk processing for {chunk_start_date_str}-{chunk_end_date_str}") from e
    else: # Default to postgres
        try:
            append_data_to_postgres(transformed_df, TARGET_TABLE_NAME, db_conn_params)
            logger.info(f"Successfully loaded data to PostgreSQL for chunk {chunk_start_date_str} to {chunk_end_date_str}.")
            return True
        except Exception as e:
            logger.error(f"Unexpected error loading data to PostgreSQL for chunk {chunk_start_date_str} to {chunk_end_date_str}: {e}")
            raise RuntimeError(f"Critical failure in PostgreSQL chunk processing for {chunk_start_date_str}-{chunk_end_date_str}") from e


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
    """Main ETL orchestration logic.

    This function determines whether to perform a large initial load (for an empty
    table) or a smaller incremental load based on the latest data present in the
    database. It manages secret retrieval, database connections, and calls the
    appropriate load function.
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
    db_password = None # Will be populated from Secrets Manager or environment variable
    if db_password_secret_name:
        try:
            # Retrieve the secret, which is expected to be a JSON with a 'password' key.
            secret_content = get_secret(db_password_secret_name, aws_region)
            db_password = secret_content.get("password")
            if not db_password:
                raise ValueError(f"Key 'password' not found or is empty in secret '{db_password_secret_name}'.")
        except Exception as e:
            logger.error(f"Failed to retrieve DB password from Secrets Manager '{db_password_secret_name}': {e}. Aborting ETL.")
            raise RuntimeError(f"ETL Aborted: Could not retrieve DB password.") from e

    sink_type = os.getenv("ETL_SINK_TYPE", "postgres")
    conn_params = {}
    last_date_in_db = None

    if sink_type == "duckdb_iceberg":
        logger.info("ETL sink is configured for Iceberg (via DuckDB).")
        conn_params = {"duckdb_path": os.getenv("DBT_DUCKDB_PATH", "/opt/airflow/dwh/volka_lakehouse.duckdb")}
        last_date_in_db = get_last_loaded_date_from_iceberg(conn_params)
    elif sink_type == "redshift_iceberg":
        logger.info("ETL sink is configured for Iceberg (via AWS Glue/S3).")
        conn_params = {
            "s3_path": os.getenv("ICEBERG_S3_PATH"),
            "glue_database": os.getenv("ICEBERG_GLUE_DATABASE")
        }
        # Note: get_last_loaded_date would need a Redshift/Athena implementation. For now, we assume initial load.
    else:
        logger.info("ETL sink is configured for PostgreSQL.")
        conn_params = {
            "host": os.getenv("DB_HOST"),
            "database": os.getenv("DB_NAME"),
            "user": os.getenv("DB_USER"),
            "password": db_password if db_password else os.getenv("DB_PASSWORD"),
            "port": os.getenv("DB_PORT", "5432")
        }
        if not all(conn_params.get(k) for k in ["host", "database", "user"]):
            raise ValueError("ETL Aborted: Essential PostgreSQL connection parameters are not set.")
        last_date_in_db = get_last_loaded_date(conn_params)

    if last_date_in_db is None:
        _perform_initial_load(api_key_header, target_date, conn_params)
    else:
        _perform_incremental_load(api_key_header, last_date_in_db, target_date, conn_params)


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

    main_etl_flow(target_date_param)