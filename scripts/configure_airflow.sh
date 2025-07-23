#!/bin/bash
set -e # Exit immediately if a command fails

echo "--- Running Airflow Configuration ---"
today=$(date +%Y%m%d) # This needs to be outside the sudo exec block


echo "--> Adding/Updating Airflow PostgreSQL connection 'postgres_default'..."
# Variables are evaluated by the shell *inside* the container.
airflow connections add postgres_default --conn-type postgres --conn-host "$DB_HOST" --conn-schema "$DB_NAME" --conn-login "$DB_USER" --conn-password "$DB_PASSWORD" --conn-port "$DB_PORT"

echo "--> Setting Airflow variables for dbt..."
airflow variables set dbt_project_dir /opt/airflow/dbt_project
airflow variables set dbt_profiles_dir /opt/airflow/dbt_project
# Use the DBT_TARGET_PROFILE from docker-compose, defaulting to 'dev'
airflow variables set dbt_target_profile "${DBT_TARGET_PROFILE:-dev}"
# The \${today} variable is expanded by the local shell, which is the desired behavior.
airflow variables set approve_volka_dbt_staging_pipeline_${today} true

echo '--> Unpausing all available DAGs...'
# The command substitution and variables are evaluated inside the container.
for dag_id in $(airflow dags list | awk 'NR > 2 {print $1}'); do
  echo "Unpausing DAG: $dag_id"
  airflow dags unpause "$dag_id" || true
done

echo "--- Airflow Configuration Complete ---"