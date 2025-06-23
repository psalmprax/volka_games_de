from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.operators.postgres import PostgresOperator
from airflow.operators.bash import BashOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.utils.dates import days_ago
from airflow.models import Variable 
from datetime import timedelta
import yaml
from pathlib import Path


DAG_ID = "volka_main_orchestrator_pipeline" 
DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False, 
    "email_on_retry": False,
    # Increased retries for robustness against transient issues (e.g., API or DB).
    "retries": 3,
    "retry_exponential_backoff": True,
    "retry_delay": timedelta(minutes=5),
}

# Path to the SQL schema file, accessible within the Airflow worker container.
# This path is determined by the volume mounts in the Docker configuration.
SCHEMA_FILE_PATH = "/opt/airflow/sql/schema.sql"

# Read the SQL content directly from the file. This approach loads the entire
# file as a string, bypassing Airflow's Jinja templating for this specific SQL.
with open(SCHEMA_FILE_PATH, 'r') as f:
    CREATE_RAW_TABLE_SQL = f.read()
 
# Path to the YAML file that configures the dynamic dbt DAG dependencies.
DBT_CONFIG_FILE_PATH = Path(__file__).parent / "dbt/dbt_dag_config.yml"

# Load dbt DAG configuration from the YAML file with robust error handling.
try:
    # The ETL script (etl_script.py) uses os.getenv() to fetch necessary
    # environment variables (e.g., AWS_REGION, API_KEY_SECRET_NAME, DB_HOST).
    # These must be available in the Airflow worker's environment.
    # The dbt project and profile directories are fetched from Airflow Variables
    # to allow for flexible path configuration across different environments.
    DBT_PROJECT_DIR = Variable.get("dbt_project_dir", "/opt/airflow/dbt_project")
    DBT_PROFILES_DIR = Variable.get("dbt_profiles_dir", "/opt/airflow/dbt_project")
    
    with open(DBT_CONFIG_FILE_PATH, "r") as f:
        dbt_config = yaml.safe_load(f)
except (FileNotFoundError, yaml.YAMLError) as e:
    print(f"Error loading dbt DAG configuration from {DBT_CONFIG_FILE_PATH}: {e}")
    dbt_config = {"dbt_dags": []} # Default to empty config to allow DAG parsing on error.

with DAG(
    dag_id=DAG_ID,
    default_args=DEFAULT_ARGS,
    schedule_interval="0 5 * * *",  
    start_date=days_ago(2), 
    catchup=False, 
    tags=["volka", "marketing", "etl"],
    doc_md="""
    ### Main Orchestrator Pipeline

    This DAG orchestrates the main marketing data pipeline. Its primary responsibilities are:
    1.  **Schema Initialization**: Ensures the raw data table exists in the database.
    2.  **ETL Execution**: Runs the Python-based ETL script to fetch and load new data.
    3.  **dbt Dependency Management**: Installs necessary dbt packages.
    4.  **Dynamic dbt DAG Triggering**: Triggers a series of dbt DAGs in a sequence defined
        by a YAML configuration file (`dbt_dag_config.yml`). This allows for a flexible,
        decoupled, and configurable dbt workflow.
    """,
) as dag:
    
    # Task to idempotently create the raw table and its indexes by executing
    # the SQL from the schema file.
    create_raw_table = PostgresOperator(
        task_id="create_raw_campaign_performance_table",
        sql=CREATE_RAW_TABLE_SQL,
        postgres_conn_id="postgres_default",
        split_statements=True,
    )
    # This task ensures dbt dependencies are installed before running any dbt commands.
    # It runs `dbt deps` and includes verification steps to confirm that key
    # packages like `dbt_expectations` are correctly installed.
    dbt_deps_task = BashOperator(
        task_id="dbt_deps",
        bash_command=f"""
            cd "{DBT_PROJECT_DIR}" && dbt clean && \\
            cd "{DBT_PROJECT_DIR}" && \\
            dbt deps --profiles-dir "{DBT_PROFILES_DIR}" && \\
            if [ $? -ne 0 ]; then
              echo "dbt deps command failed! Exiting."
              exit 1
            else
              echo "dbt deps command completed successfully."
              echo "Verifying dbt_packages directory contents:"
              ls -la "{DBT_PROJECT_DIR}/dbt_packages"
              if [ ! -d "{DBT_PROJECT_DIR}/dbt_packages/dbt_expectations" ]; then
                echo "Error: dbt_expectations package directory not found in '{DBT_PROJECT_DIR}/dbt_packages'!" && exit 1
              else
                echo "dbt_expectations package directory found in '{DBT_PROJECT_DIR}/dbt_packages'."
                # Verify that the dbt_project.yml file exists within the installed package
                if [ ! -f "{DBT_PROJECT_DIR}/dbt_packages/dbt_expectations/dbt_project.yml" ]; then
                  echo "Error: dbt_project.yml not found in dbt_expectations package. Package might be corrupted or incompletely installed." && exit 1
                fi
              fi # Closes inner if
            fi # Closes outer if
        """,
    )

    # Use Airflow's Jinja templating to pass the previous logical run date (prev_ds)
    # to downstream tasks. This is the end of the data interval for the run.
    etl_date_param = "{{ prev_ds }}"

    def etl_script_callable(target_processing_date: str):
        """Callable function to execute the main ETL flow."""
        # PYTHONPATH is set in the Dockerfile to include /opt/etl
        from etl.etl_script import main_etl_flow
        # The etl_script.py uses os.getenv for DB params, API secret name, region.
        # These must be available in the Airflow worker's environment.
        # main_etl_flow now expects a single target_processing_date_str argument.
        main_etl_flow(target_processing_date_str=target_processing_date)
        # If etl_script.py creates temporary files that need cleanup after a batch,
        # that cleanup logic should ideally be within main_etl_flow() or called by it.

    run_etl_script = PythonOperator(
        task_id="run_marketing_etl",
        python_callable=etl_script_callable,
        op_kwargs={
            "target_processing_date": etl_date_param,
        },
    )

    # --- Dynamic dbt DAG Triggering ---
    dbt_dags_config = dbt_config.get("dbt_dags", [])
    trigger_tasks = {}

    # Dynamically create TriggerDagRunOperator tasks for each dbt DAG defined in the YAML config.
    for dag_info in dbt_dags_config:
        task_id = f"trigger_{dag_info['name']}_dag"
        trigger_tasks[dag_info['name']] = TriggerDagRunOperator(
            task_id=task_id,
            trigger_dag_id=dag_info['dag_id'],
            conf={"target_processing_date": etl_date_param},
            wait_for_completion=True, # Ensures dbt DAGs run sequentially as defined.
            poke_interval=60,
        )

    # Create the dependency chain between the trigger tasks based on the 'downstream' key in the config.
    for dag_info in dbt_dags_config:
        downstream_name = dag_info.get('downstream')
        if downstream_name and downstream_name in trigger_tasks:
            upstream_task = trigger_tasks[dag_info['name']]
            downstream_task = trigger_tasks[downstream_name]
            upstream_task >> downstream_task

    # Identify the initial dbt DAGs in the chain(s) to link them to the main pipeline.
    # These are the dbt DAGs that are not listed as a 'downstream' for any other DAG.
    all_downstream_names = {dag_info['downstream'] for dag_info in dbt_dags_config if dag_info.get('downstream')}
    start_dbt_task_names = [dag_info['name'] for dag_info in dbt_dags_config if dag_info['name'] not in all_downstream_names]

    # Define the main task dependency flow for the orchestrator.
    create_raw_table >> \
    run_etl_script >> \
    dbt_deps_task

    # The dbt_deps_task triggers the first dbt DAG(s) in the dynamically defined chain.
    if start_dbt_task_names:
        for task_name in start_dbt_task_names:
            dbt_deps_task >> trigger_tasks[task_name]
    