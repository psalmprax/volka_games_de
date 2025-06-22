import yaml
import logging
from pathlib import Path
from datetime import timedelta

from airflow.models.dag import DAG
from airflow.operators.bash import BashOperator
from airflow.utils.dates import days_ago
from airflow.models import Variable
from airflow.sensors.python import PythonSensor
from airflow.operators.python import PythonOperator

# Path to the YAML config file. This path is relative to the DAGs folder.
CONFIG_FILE_PATH = Path(__file__).parent / "dbt_dag_config.yml"

DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
}

# --- Helper Functions for Manual Approval Gate ---

def check_approval_variable(dag_id: str, ds_nodash: str) -> bool:
    """Checks if the approval variable for this DAG run exists."""
    var_name = f"approve_{dag_id}_{ds_nodash}"
    try:
        Variable.get(var_name)
        logging.info(f"Approval variable '{var_name}' found. Proceeding.")
        return True
    except KeyError:
        logging.info(f"Approval variable '{var_name}' not found. Waiting.")
        return False

def cleanup_approval_variable(dag_id: str, ds_nodash: str):
    """Deletes the approval variable after the DAG run. Idempotent."""
    var_name = f"approve_{dag_id}_{ds_nodash}"
    try:
        Variable.delete(var_name)
        logging.info(f"Cleaned up approval variable '{var_name}'.")
    except KeyError:
        logging.info(f"Approval variable '{var_name}' was not found for cleanup (already deleted or never created).")


def create_dbt_dag(dag_config: dict) -> DAG:
    """
    Dynamically creates an Airflow DAG for a dbt stage based on YAML configuration.
    """
    dag_id = dag_config['dag_id']
    tags = ["volka", "dbt", "generated"] + dag_config.get("tags", [])
    
    dag = DAG(
        dag_id=dag_id,
        default_args=DEFAULT_ARGS,
        schedule_interval=dag_config.get("schedule"),
        start_date=days_ago(1),
        catchup=False,
        tags=tags,
        doc_md=f"### {dag_config.get('description', dag_id)}\n\nThis DAG was dynamically generated from `dbt_dag_config.yml`.",
    )
        
    with dag:
        # This will be the first task in the chain, if any.
        chain_head = None
        # This will be the last task in the chain, to link new tasks.
        chain_tail = None

        if dag_config.get("requires_manual_start"):
            wait_for_approval = PythonSensor(
                task_id="wait_for_manual_approval",
                python_callable=check_approval_variable,
                op_kwargs={'dag_id': dag.dag_id, 'ds_nodash': '{{ ds_nodash }}'},
                poke_interval=60,  # Check every 60 seconds
                timeout=60 * 60 * 24,  # Timeout after 24 hours
                mode='poke',
                doc_md="""
                ### Wait for Manual Approval
                This task waits for an Airflow Variable to be created to signal that the DAG run can proceed.
                To approve this run, create a Variable with the key:
                **`approve_{{ dag.dag_id }}_{{ ds_nodash }}`**
                The value can be anything (e.g., `true`).
                """
            )
            chain_head = wait_for_approval
            chain_tail = wait_for_approval
        
        for task_config in dag_config['commands']:
            dbt_command = task_config['command']
            task_id = f"dbt_{dbt_command}_{dag_config['name']}"
            
            # Build the dbt command as a list of parts to be joined with spaces
            dbt_command_parts = [f"dbt {dbt_command}"]
            
            selector = task_config.get('selector')
            if selector:
                # No extra quotes are needed here; the shell handles the argument correctly.
                dbt_command_parts.append(f"--select {selector}")
            
            # Add common dbt flags using Jinja templating
            dbt_command_parts.append("--profiles-dir {{ var.value.get('dbt_profiles_dir', '/opt/airflow/dbt_project') }}")
            dbt_command_parts.append("--target {{ var.value.get('dbt_target_profile', 'dev') }}")

            # Join the dbt command parts with spaces to form a single command
            final_dbt_command = " ".join(dbt_command_parts)

            # Construct the full bash command, changing directory first
            bash_command = (
                "cd {{ var.value.get('dbt_project_dir', '/opt/airflow/dbt_project') }} && "
                f"{final_dbt_command}"
            )
            
            dbt_task = BashOperator(
                task_id=task_id,
                bash_command=bash_command,
            )
            
            if chain_tail:
                chain_tail >> dbt_task
            else:  # This is the first task in the whole DAG
                chain_head = dbt_task
            
            chain_tail = dbt_task  # The new task is now the end of the chain
            
        # Add a cleanup task at the end if approval was required
        if dag_config.get("requires_manual_start") and chain_tail:
            cleanup_variable = PythonOperator(
                task_id="cleanup_approval_variable",
                python_callable=cleanup_approval_variable,
                op_kwargs={'dag_id': dag.dag_id, 'ds_nodash': '{{ ds_nodash }}'},
                trigger_rule='all_done', # Ensures this runs even if dbt tasks fail
            )
            chain_tail >> cleanup_variable
    return dag

# --- DAG Generation Loop ---
try:
    with open(CONFIG_FILE_PATH, "r") as f:
        config = yaml.safe_load(f)
except (FileNotFoundError, yaml.YAMLError) as e:
    print(f"Error loading dbt DAG configuration from {CONFIG_FILE_PATH}: {e}")
    config = {"dbt_dags": []} # Provide an empty config to prevent parsing errors

for dag_conf in config.get("dbt_dags", []):
    globals()[dag_conf['dag_id']] = create_dbt_dag(dag_conf)