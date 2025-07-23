#!/bin/bash

# Create all required directories to prevent errors. These directories are
# mounted as volumes in docker-compose.yml.
echo "Ensuring all required directories exist..."
mkdir -p ./airflow_dags ./etl ./dbt_project ./sql ./logs ./plugins ./xlsx_excel_report ./dwh

# Clean up previous log files to ensure a fresh start.
echo "Cleaning up old log files..."
sudo rm -rf ./logs/*

# Set correct permissions for mounted volumes. The official Airflow Docker image
# runs as the 'airflow' user with UID 50000. This command sets the ownership
# of the mounted directories to match, preventing permission errors inside the containers.
# The script now creates these directories if they don't exist.
echo "Setting volume permissions for Airflow container (may require sudo)..."
sudo chown -R 50000:0 ./airflow_dags ./etl ./dbt_project ./sql ./logs ./plugins ./xlsx_excel_report ./dwh

# Stop existing services if they are running.
echo "Stopping existing Docker services (if any)..."
sudo docker compose down

# Start all services, building images if they are out of date.
echo "Starting services and building images if needed..."
sudo docker compose up --build -d

# Wait for the webserver to be healthy before proceeding. This is more reliable than a fixed sleep.
echo "Waiting for Airflow webserver to be healthy..."
while [ "$(sudo docker inspect -f '{{.State.Health.Status}}' volka_airflow_webserver 2>/dev/null)" != "healthy" ]; do
    echo -n "."
    sleep 5
done
echo -e "\nAirflow webserver is healthy."

# Find the Airflow worker container ID
worker_container_id=$(sudo docker compose ps -q airflow-worker)

if [ -z "$worker_container_id" ]; then
  echo "Error: Could not find the airflow-worker container. Please check docker-compose configuration."
  exit 1
fi

# Configure Airflow connections and variables inside the running container.
# This is idempotent and safe to run multiple times.
echo "Configuring Airflow environment inside the container..."
sudo docker exec "$worker_container_id" bash /opt/airflow/scripts/configure_airflow.sh

echo -e "\nSetup complete! Airflow is running at http://localhost:8080"
