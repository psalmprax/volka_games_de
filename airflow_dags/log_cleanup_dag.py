from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.utils.dates import days_ago
from airflow.models import Variable
from datetime import timedelta

DAG_ID = "airflow_log_cleanup"
DEFAULT_ARGS = {
    "owner": "airflow",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

# Define the base log directory within the Airflow container
# This should match the volume mount for logs in your docker-compose.yml
LOG_BASE_DIR = "/opt/airflow/logs"

# Define the number of days of logs to keep
# You can configure this via an Airflow Variable named 'log_cleanup_days_to_keep'
# Defaulting to 7 days if the variable is not set.
DAYS_TO_KEEP = int(Variable.get("log_cleanup_days_to_keep", 7))

# Bash command to find and delete files/directories older than DAYS_TO_KEEP
# -type f -or -type d : Target both files and directories
# We group the type checks with parentheses to ensure correct boolean evaluation.
# -mtime +$DAYS_TO_KEEP : Find files/directories modified more than DAYS_TO_KEEP days ago
# -delete : Delete the found files/directories
# Be cautious with the find -delete command! Test it first without -delete.
# CLEANUP_COMMAND = f'find "{LOG_BASE_DIR}" -mindepth 1 \\( -type f -or -type d \\) -mtime +{DAYS_TO_KEEP} -delete'
CLEANUP_COMMAND = f'find "{LOG_BASE_DIR}" -mindepth 1 -mmin +180 -exec rm -rf {{}} +'


# Add a test command without -delete for debugging purposes
CLEANUP_TEST_COMMAND = f'find "{LOG_BASE_DIR}" -mindepth 1 \\( -type f -or -type d \\) -mtime +{DAYS_TO_KEEP}'

with DAG(
    dag_id=DAG_ID,
    default_args=DEFAULT_ARGS,
    schedule_interval="0 0 * * *",  # Run daily at midnight UTC
    start_date=days_ago(1),
    catchup=False,
    tags=["airflow_maintenance", "log_cleanup"],
) as dag:

    clean_old_logs = BashOperator(
        task_id="clean_old_airflow_logs",
        bash_command=CLEANUP_COMMAND,
        # Add a trigger_rule if you want this to run even if previous tasks in a theoretical chain fail
        # trigger_rule="all_done",
    )

    # Optional task to test the find command without deleting
    # You can uncomment this and run it first to see what files would be deleted
    # test_log_cleanup_find = BashOperator(
    #     task_id="test_log_cleanup_find",
    #     bash_command=CLEANUP_TEST_COMMAND,
    # )

# Note: This DAG assumes that the user running the Airflow worker task has
# the necessary file system permissions to delete files and directories
# within the LOG_BASE_DIR. This is usually the 'airflow' user in standard
# Docker setups, and the log directory volume mount should be writable by this user.
