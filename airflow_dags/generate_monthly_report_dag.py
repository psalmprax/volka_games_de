import logging
from datetime import datetime
from pathlib import Path
from airflow.models import DagRun
from airflow import settings
from airflow.exceptions import AirflowSkipException

import glob
import pandas as pd
import os
import duckdb
from airflow.decorators import dag, task
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.sensors.external_task import ExternalTaskSensor

# Directory containing SQL query files, from the perspective of the Airflow worker.
SQL_QUERY_DIR = Path("/opt/airflow/sql/queries")

# Output path for the generated Excel reports. This directory should be mounted
# as a volume in docker-compose.yml to persist the files on the host.
EXCEL_OUTPUT_DIR = Path("/opt/airflow/xlsx_excel_report")

def log_task_start(context):
    """Callback function to log the start of a task."""
    logging.info(f"Starting task: {context['task_instance'].task_id} in DAG: {context['dag'].dag_id}")
    
def get_most_recent_dag_run(execution_date, **kwargs):
    """
    Callback for ExternalTaskSensor to find the latest execution date of the target DAG.
    This is used when the sensor should wait for the most recent run of the upstream
    DAG to complete, rather than a run with the same logical execution date. This is
    useful if the upstream DAG runs on a different schedule.

    Note: This function returns a list of datetimes. If no upstream run is found, it
    returns an empty list. In many Airflow versions, this will cause the sensor to
    succeed immediately. This is a workaround to prevent a crash when the function
    returns `None` on older Airflow versions.
    """
    session = settings.Session()
    recent_run = session.query(DagRun).filter(
        DagRun.dag_id == kwargs['task'].external_dag_id
    ).order_by(DagRun.execution_date.desc()).first()
    if recent_run:
        return [recent_run.execution_date]
    else:
        # Raise an exception to keep the sensor poking (will not succeed)
        raise AirflowSkipException("No upstream run found yet; will try again.")


@dag(
    dag_id="generate_dynamic_marketing_reports",
    start_date=datetime(2024, 10, 1),
    schedule_interval="*/5 * * * *",  # Runs at the beginning of each month. "@monthly" but for testing, it runs every 5 minutes
    catchup=False,
    tags=["volka", "marketing", "reporting", "dynamic"],
    doc_md="""
    ### Generate Dynamic Marketing Reports

    This DAG dynamically discovers SQL query files in a specified directory,
    and for each file, generates a marketing report in Excel format.
    The report filename will include the base name of the SQL file and the execution date.

    **Dependencies:**
    - **This DAG waits for the `volka_dbt_marts_reporting_pipeline` DAG to complete successfully.**
    - The `openpyxl` Python library must be installed in the Airflow environment.
    - The dbt model `public_reporting.monthly_campaign_summary` must exist and be up-to-date.
    - The output directory `/opt/airflow/xlsx_excel_report` must be writable and ideally
      mounted as a volume to the host machine for access.
    """,
)
def generate_monthly_report_dag():
    """
    A production-ready DAG to dynamically generate monthly marketing reports in Excel format.
    """

    @task
    def generate_excel_report(
        sql_file_path: str,
        report_base_name: str,
        output_dir: Path,
        data_interval_end,  # Use the end of the data interval for more intuitive naming
        postgres_conn_id: str = "postgres_default",
    ) -> str:
        """
        Executes a SQL query and saves the result as an Excel file.

        :param sql_file_path: Path to the specific SQL file for this task instance.
        :param report_base_name: The base name for the output report file.
        :param output_dir: The directory where the Excel report will be saved.
        :param data_interval_end: The end of the data interval for the DAG run.
        :param postgres_conn_id: The Airflow connection ID for the PostgreSQL database.
        """
        output_dir.mkdir(parents=True, exist_ok=True)

        try:
            sql_query = Path(sql_file_path).read_text()
            logging.info(f"Successfully read SQL from {sql_file_path}")
        except FileNotFoundError:
            logging.error(f"SQL file not found at: {sql_file_path}")
            raise

        pg_hook = PostgresHook(postgres_conn_id=postgres_conn_id)
        logging.info(f"Executing query:\n{sql_query}")
        # Note: The SQL query itself can be templated (e.g., using {{ ds_nodash }})
        # if it needs to filter data dynamically based on the execution date.

        dbt_target = os.getenv("DBT_TARGET_PROFILE", "dev")
        df = pd.DataFrame()

        if dbt_target == 'duckdb_iceberg':
            duckdb_path = os.getenv("DBT_DUCKDB_PATH", "/opt/airflow/dwh/volka_lakehouse.duckdb")
            logging.info(f"Querying DuckDB lakehouse at {duckdb_path}")
            try:
                with duckdb.connect(duckdb_path, read_only=True) as con:
                    df = con.execute(sql_query).fetchdf()
            except Exception as e:
                logging.error(f"Failed to query DuckDB: {e}")
                raise
        else: # Default to postgres
            logging.info(f"Querying PostgreSQL warehouse using conn_id: {postgres_conn_id}")
            df = pg_hook.get_pandas_df(sql=sql_query)
        if df.empty:
            logging.warning(f"Query from {report_base_name} returned no data. No Excel file will be generated.")
            return "No data found, report not generated."

        report_date_str = datetime.now().strftime('%Y%m%d')
        output_file_path = output_dir / f"{report_base_name}_{report_date_str}.xlsx"

        try:
            df.to_excel(output_file_path, index=False, engine="openpyxl")
            logging.info(f"Successfully generated report at: {output_file_path}")
            return str(output_file_path)
        except Exception as e:
            logging.error(f"Failed to write Excel file: {e}")
            raise

    # This sensor waits for the completion of the upstream dbt reporting pipeline.
    # It uses `execution_date_fn` to wait for the *most recent* run of the target
    # DAG, which provides flexibility if the upstream DAG runs on a different schedule.
    wait_for_dbt_pipeline = ExternalTaskSensor(
        task_id="wait_for_volka_dbt_marts_reporting_pipeline",
        external_dag_id="volka_dbt_marts_reporting_pipeline",
        external_task_id=f'dbt_test_marts_reporting',
        execution_date_fn=get_most_recent_dag_run,
        allowed_states=["success"],
        failed_states=["failed"],
        mode="reschedule",      # Frees up a worker slot while waiting for the upstream DAG.
        poke_interval=30,       # How often to check for the upstream DAG's status.
        deferrable=False,       # Must be False to use 'reschedule' mode. Deferrable mode requires a running Triggerer.
        timeout=60 * 60 * 24,   # Max wait time for the upstream DAG (24 hours).
        on_success_callback=log_task_start,
    )

    # Dynamically discover all .sql files to generate a report task for each one.
    sql_files = glob.glob(str(SQL_QUERY_DIR / "*.sql"))

    if not sql_files:
        logging.warning(f"No SQL files found in {SQL_QUERY_DIR}. No reports will be generated.")
        return # Stop DAG generation if no SQL files are found, preventing an empty DAG.

    report_tasks = []

    for sql_file in sql_files:
        # Use the SQL file's stem as the base name for the report and task ID.
        # e.g., "monthly_summary.sql" -> "monthly_summary"
        report_base_name = Path(sql_file).stem
        
        report_task = generate_excel_report.override(task_id=f"generate_report_{report_base_name}")(
            sql_file_path=sql_file,
            report_base_name=report_base_name,
            output_dir=EXCEL_OUTPUT_DIR,
        )
        report_tasks.append(report_task)
    
    # Set the dependency: All report generation tasks will run in parallel
    # after the upstream dbt pipeline has successfully completed.
    wait_for_dbt_pipeline >> report_tasks

generate_monthly_report_dag()