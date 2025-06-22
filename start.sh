#!/bin/bash

# sudo chown -R "$(whoami):$(id -gn)" .
# Set file permissions to match the Airflow user inside the container.
# This prevents permission errors with mounted volumes.
# The user is defined as 50000:0 in docker-compose.yml.
echo "Setting volume permissions..."
sudo chown -R 50000:0 .
sudo chmod -R u+wx .

# # Stop and remove existing containers, also remove volumes
# docker-compose down -v

# # Remove all unused images, stopped containers, networks, and volumes
# docker system prune -af

# Stop existing services, remove containers, associated volumes, and locally built images.
# This is safer than `docker system prune`.
echo "Stopping and cleaning up previous environment..."
docker-compose down -v --rmi local

# Start the services, building images if necessary, in detached mode
docker-compose up --build -d

# Wait for the webserver to be healthy before proceeding. This is more reliable than a fixed sleep.
echo "Waiting for Airflow webserver to be healthy..."
while [ "$(docker inspect -f {{.State.Health.Status}} volka_airflow_webserver 2>/dev/null)" != "healthy" ]; do
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
  # set -a && source .env && set +a &&
  echo \"Adding Airflow PostgreSQL connection 'postgres_default'...\" &&
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



