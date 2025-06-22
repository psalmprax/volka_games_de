#!/bin/bash

# sudo chown -R "$(whoami):$(id -gn)" .
# The Airflow container runs as user with UID 50000. To prevent permission errors on
# mounted volumes (e.g., dags, logs), we set the ownership of the current directory
# to match this user.
echo "Setting volume permissions (may require sudo)..."
sudo chown -R 50000:0 . > /dev/null 2>&1 || echo "Could not set ownership. Continuing..."
sudo chmod -R u+wx . > /dev/null 2>&1 || echo "Could not set permissions. Continuing..."

# Stop existing services using `down` to preserve volumes (database data) and
# downloaded images for faster restarts.
# For a full reset (including data), run: docker-compose down -v --rmi local
echo "Stopping existing services (if any)..."
docker-compose down

# Start all services, building images if they are out of date.
echo "Starting services and building images if needed..."
docker-compose up --build -d

# Wait for the webserver to be healthy before proceeding. This is more reliable than a fixed sleep.
echo "Waiting for Airflow webserver to be healthy..."
while [ "$(docker inspect -f '{{.State.Health.Status}}' volka_airflow_webserver 2>/dev/null)" != "healthy" ]; do
    echo -n "."
    sleep 5
done
echo -e "\nAirflow webserver is healthy."

# Find the Airflow worker container ID
worker_container_id=$(docker-compose ps -q airflow-worker)

if [ -z "$worker_container_id" ]; then
  echo "Error: Could not find the airflow-worker container. Please check docker-compose configuration."
  exit 1
fi

# Execute the Airflow connection creation command inside the worker container
docker exec "$worker_container_id" bash -c "
  set -e # Exit immediately if a command fails.
  echo \"Adding Airflow PostgreSQL connection 'postgres_default'...\"
  airflow connections add postgres_default \
    --conn-type postgres \
    --conn-host \"\$DB_HOST\" --conn-schema \"\$DB_NAME\" --conn-login \"\$DB_USER\" --conn-password \"\$DB_PASSWORD\" --conn-port \"\$DB_PORT\"
"

# Set Airflow Variables needed by the dbt DAG factory. This is idempotent.
echo "Setting Airflow variables for dbt..."
today=$(date +%Y%m%d)
docker exec "$worker_container_id" bash -c "
airflow variables set dbt_project_dir /opt/airflow/dbt_project &&
airflow variables set dbt_profiles_dir /opt/airflow/dbt_project &&
airflow variables set dbt_target_profile dev &&
airflow variables set approve_volka_dbt_staging_pipeline_${today} true &&
echo '----------- Unpausing generated dbt DAGs-------------'
for dag in volka_dbt_staging_pipeline volka_dbt_snapshot_pipeline volka_dbt_marts_core_pipeline volka_dbt_marts_reporting_pipeline volka_main_orchestrator_pipeline airflow_log_cleanup; do
  if [ -n \"\$dag\" ]; then
    airflow dags unpause \"\$dag\" || true
  fi
done
"



