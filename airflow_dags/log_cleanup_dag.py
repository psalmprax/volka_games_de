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

# The base directory for Airflow logs inside the container. This path should
# correspond to the volume mount for logs in your Docker configuration.
LOG_BASE_DIR = "/opt/airflow/logs"

# The number of days to retain logs. This is configurable via an Airflow Variable
# named 'log_cleanup_days_to_keep', with a default of 7 days.
DAYS_TO_KEEP = int(Variable.get("log_cleanup_days_to_keep", 7))

# The `find` command to locate and delete old log files and directories.
# - `find "{LOG_BASE_DIR}"`: Search within the specified log directory.
# - `-mindepth 1`: Prevents `find` from evaluating the base log directory itself,
#   ensuring it is not deleted.
# - `-mtime +{DAYS_TO_KEEP}`: Finds files and directories modified more than the
#   specified number of days ago.
# - `-delete`: A safe and efficient way to delete the found items. It is a
#   built-in `find` action and is generally safer than using `-exec rm -rf {{}} +`.
CLEANUP_COMMAND = f'find "{LOG_BASE_DIR}" -mindepth 1 -mtime +{DAYS_TO_KEEP} -delete'

# A non-destructive version of the cleanup command for testing and debugging.
# This command will only list the files and directories that would be deleted.
CLEANUP_TEST_COMMAND = f'find "{LOG_BASE_DIR}" -mindepth 1 -mtime +{DAYS_TO_KEEP}'

with DAG(
    dag_id=DAG_ID,
    default_args=DEFAULT_ARGS,
    schedule_interval="0 0 * * *",  # Run daily at midnight UTC
    start_date=days_ago(1),
    catchup=False,
    tags=["airflow_maintenance", "log_cleanup"],
    doc_md="""
    ### Airflow Log Cleanup

    This maintenance DAG automatically cleans up old Airflow task logs to prevent
    the log directory from growing indefinitely.

    - **Configurability**: The log retention period is controlled by the Airflow
      Variable `log_cleanup_days_to_keep` (default is 7 days).
    - **Safety**: It uses the `find ... -delete` command, which is safer than
      piping to `xargs rm`.
    - **Permissions**: The Airflow worker user needs write/delete permissions
      on the log volume (`/opt/airflow/logs`).
    """
) as dag:

    clean_old_logs = BashOperator(
        task_id="clean_old_airflow_logs",
        bash_command=CLEANUP_COMMAND,
        doc_md="Deletes log files and empty directories older than the configured retention period."
    )

    # Optional task to test the find command without actually deleting anything.
    # Uncomment this task to perform a dry run and see what would be deleted.
    # test_log_cleanup_find = BashOperator(
    #     task_id="test_log_cleanup_find",
    #     bash_command=CLEANUP_TEST_COMMAND,
    #     doc_md="Lists all files and directories that are candidates for deletion."
    # )
