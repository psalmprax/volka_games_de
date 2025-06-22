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


# Consider renaming to reflect its orchestrator role, e.g., "volka_main_orchestrator_pipeline"
DAG_ID = "volka_main_orchestrator_pipeline" 
DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False, 
    "email_on_retry": False,
    # Increased retries for robustness, especially for API calls or transient DB issues
    "retries": 3,
    # Add exponential backoff for retries
    "retry_exponential_backoff": True,
    "retry_delay": timedelta(minutes=5),
}

# Define the path to the SQL schema file
# This path should be accessible within the Airflow worker container
# based on your docker-compose.yml volume mounts. We will read its content.
SCHEMA_FILE_PATH = "/opt/airflow/sql/schema.sql"

# Read the SQL content from the file
# This ensures the SQL is loaded as a string, bypassing Jinja's template loader for this file.
with open(SCHEMA_FILE_PATH, 'r') as f:
    CREATE_RAW_TABLE_SQL = f.read()
 
# Path to the dbt DAGs YAML config file.
DBT_CONFIG_FILE_PATH = Path(__file__).parent / "dbt/dbt_dag_config.yml"

# Load the dbt DAG configuration from the YAML file with error handling
try:
    # Note: ETL_ENV_VARS previously used for DockerOperator are now expected to be
    # available in the Airflow worker's environment, as etl_script.py uses os.getenv().
    # Ensure variables like AWS_REGION, API_KEY_SECRET_NAME, DB_HOST, DB_NAME, etc.,
    # are set in the worker's environment (e.g., via .env file in docker-compose).
    # Use paths that align with docker-compose mounts for local development
    # For production (Fargate), these variables should be set to the paths
    # where the code is copied in the production Docker image (e.g., /opt/airflow/dbt_project)
    DBT_PROJECT_DIR = Variable.get("dbt_project_dir", "/opt/airflow/dbt_project")
    DBT_PROFILES_DIR = Variable.get("dbt_profiles_dir", "/opt/airflow/dbt_project")
    
    with open(DBT_CONFIG_FILE_PATH, "r") as f:
        dbt_config = yaml.safe_load(f)
except (FileNotFoundError, yaml.YAMLError) as e:
    print(f"Error loading dbt DAG configuration from {DBT_CONFIG_FILE_PATH}: {e}")
    dbt_config = {"dbt_dags": []} # Provide an empty config to allow DAG to parse

with DAG(
    dag_id=DAG_ID,
    default_args=DEFAULT_ARGS,
    schedule_interval="0 5 * * *",  
    start_date=days_ago(2), 
    catchup=False, 
    tags=["volka", "marketing", "etl"],
) as dag:
    
    # Task to create the raw table and indexes if they don't exist,
    # by executing the SQL from the schema file.
    create_raw_table = PostgresOperator(
        task_id="create_raw_campaign_performance_table",
        sql=CREATE_RAW_TABLE_SQL, # Pass the SQL string content
        postgres_conn_id="postgres_default", # Ensure this connection ID exists in Airflow
        split_statements=True,
    )
    # This task ensures that dbt packages are installed.
    # It's useful if packages.yml changes or if the environment
    # doesn't have them pre-installed (e.g., when dbt_project is mounted).
    # Enhanced with error checking
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
              fi # Closes inner if
            fi # Closes outer if
        """,
    )

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
            "target_processing_date": etl_date_param, # prev_ds will be passed here
        },
    )

    # --- Dynamic dbt DAG Triggering ---
    dbt_dags_config = dbt_config.get("dbt_dags", [])
    trigger_tasks = {}

    # First, create all the TriggerDagRunOperator tasks
    for dag_info in dbt_dags_config:
        task_id = f"trigger_{dag_info['name']}_dag"
        trigger_tasks[dag_info['name']] = TriggerDagRunOperator(
            task_id=task_id,
            trigger_dag_id=dag_info['dag_id'],
            conf={"target_processing_date": etl_date_param},
            wait_for_completion=True,
            poke_interval=60,
        )

    # Now, set the dependencies between the trigger tasks based on the 'downstream' key
    for dag_info in dbt_dags_config:
        downstream_name = dag_info.get('downstream')
        if downstream_name and downstream_name in trigger_tasks:
            upstream_task = trigger_tasks[dag_info['name']]
            downstream_task = trigger_tasks[downstream_name]
            upstream_task >> downstream_task

    # Find the start of the dbt chain(s) to link to the main pipeline
    all_downstream_names = {dag_info['downstream'] for dag_info in dbt_dags_config if dag_info.get('downstream')}
    start_dbt_task_names = [dag_info['name'] for dag_info in dbt_dags_config if dag_info['name'] not in all_downstream_names]

    # Define the task dependencies
    create_raw_table >> \
    run_etl_script >> \
    dbt_deps_task

    # The dbt_deps_task now triggers the first dbt DAG(s) in the chain
    if start_dbt_task_names:
        for task_name in start_dbt_task_names:
            dbt_deps_task >> trigger_tasks[task_name]
    