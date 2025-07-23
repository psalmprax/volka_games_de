# /volka_data_pipeline/docker/airflow/Dockerfile
ARG AIRFLOW_VERSION=2.9.2 # Use latest stable version to ensure image exists and dependencies are stable
FROM apache/airflow:${AIRFLOW_VERSION}-python3.9
ARG CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.9.txt"

# Switch to root user to install system-level packages and set permissions
USER root

# Install system dependencies that might be needed by your Python packages or dbt
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libpq-dev \
    git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Switch back to the non-privileged airflow user for application setup
USER airflow

# Install core Airflow providers for the pipeline's functionality (Celery, Postgres, Redis).
# These are best kept separate from application requirements for clarity.
RUN pip install --no-cache-dir \
    "apache-airflow-providers-celery==3.7.2" \
    "apache-airflow-providers-redis==3.7.1" \
    "apache-airflow-providers-postgres==5.11.1" \
    --constraint "${CONSTRAINT_URL}"

# Copy and install all other Python dependencies (including dbt) from a single requirements file.
COPY etl/requirements.txt /requirements-etl.txt
RUN pip install --timeout 480 --no-cache-dir -r /requirements-etl.txt --constraint "${CONSTRAINT_URL}" -i https://pypi.org/simple

# Set the Airflow home directory and add it to PYTHONPATH
ENV AIRFLOW_HOME=/opt/airflow
ENV PYTHONPATH="/opt/airflow:${PYTHONPATH}" 

# Copy project files into the image. These paths are for when the image is run without volumes (e.g., in production).
# For local dev, docker-compose.yml mounts these directories, overriding the image content.
COPY etl/ /opt/airflow/etl/
COPY dbt_project /opt/airflow/dbt_project/
COPY sql/ /opt/airflow/sql/
COPY airflow_dags /opt/airflow/dags
COPY scripts/ /opt/airflow/scripts/
COPY xlsx_excel_report/ /opt/airflow/xlsx_excel_report
COPY decrypt_env.sh /opt/airflow/decrypt_env.sh

# Expose Airflow webserver port (if this image were to also run the webserver directly)
EXPOSE 8080

# Switch to root to set correct ownership for all copied project files.
# This is crucial for environments where the container runs with a specific UID.
USER root
RUN chown -R 50000:0 /opt/airflow/ && \
    chmod +x /opt/airflow/decrypt_env.sh && \
    chmod +x /opt/airflow/scripts/*.sh

# Switch back to the non-privileged airflow user to run the application
USER airflow