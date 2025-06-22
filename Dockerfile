# /volka_data_pipeline/docker/airflow/Dockerfile
ARG AIRFLOW_VERSION=2.8.1 # Choose your desired Airflow version
FROM apache/airflow:${AIRFLOW_VERSION}-python3.9

USER root

# Install system dependencies that might be needed by your Python packages or dbt
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # Example: libpq-dev for psycopg2 if not handled by base image, git for dbt packages from git
    libpq-dev \
    git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER airflow

# Install dbt and adapter
RUN pip install --no-cache-dir dbt-postgres==1.7.0 # Choose your dbt version

# Install Celery and Redis provider for CeleryExecutor
RUN pip install --no-cache-dir apache-airflow-providers-celery==3.5.0 apache-airflow-providers-redis==3.3.0

# Copy ETL requirements and install Python dependencies for the ETL script
COPY etl/requirements.txt /requirements-etl.txt
RUN pip install --no-cache-dir -r /requirements-etl.txt

# Copy the ETL scripts and dbt project into the image
# These paths will be accessible by Airflow tasks running within this image.
WORKDIR /opt/airflow
COPY etl/ /opt/airflow/etl/
COPY dbt_project /opt/dbt_project 

# Switch to root to copy and set permissions for decrypt_env.sh
USER root
# Assuming decrypt_env.sh is in the same directory as the Dockerfile or a known path
COPY decrypt_env.sh /opt/airflow/decrypt_env.sh 
RUN chmod +x /opt/airflow/decrypt_env.sh
USER airflow # Switch back to airflow user

# Set PYTHONPATH if your ETL scripts have relative imports that need it
ENV PYTHONPATH="/opt/airflow:${PYTHONPATH}" 

# Optional: Copy SQL schema if needed within the container for some reason
COPY sql/ /opt/airflow/sql/

# Note: DAGs are typically mounted as a volume in docker-compose,
# but you could copy them if you prefer them baked into the image.
COPY airflow_dags /opt/airflow/dags

# Expose Airflow webserver port (if this image were to also run the webserver directly)
EXPOSE 8080

# Default command (can be overridden in docker-compose)
# CMD ["bash"] # Or ["standalone"] for Airflow 2.7+ standalone mode

# Ensure correct permissions for Airflow user
USER root
# Use AIRFLOW_UID and AIRFLOW_GID which are set by the base image (default UID 50000, GID can vary, often 0 or 50000)
# It's safer to chown to the UID. If GID is 0 (root), chown airflow:root or just chown airflow.
# If GID is also 50000, then airflow:airflow (by name) should work if the group exists.
RUN chown -R ${AIRFLOW_UID}:${AIRFLOW_GID:-0} /opt/airflow/etl /opt/airflow/sql /opt/airflow/dags /opt/dbt_project /opt/airflow/decrypt_env.sh
# If you copied dags:
# RUN chown -R airflow:airflow /opt/airflow/dags
USER airflow

# For Airflow 2.7+ standalone mode, you might not need a separate entrypoint/cmd
# if you use the base image's entrypoint. The base image entrypoint handles
# running webserver, scheduler, worker, etc. based on the command passed.
# CMD ["bash"] # Example: override default entrypoint for debugging
# ENTRYPOINT ["/entrypoint.sh"] # Example: if you have a custom entrypoint script

# Example: If you want to run `dbt deps` on startup
# RUN cd /opt/dbt_project && dbt deps --profiles-dir . # Assuming profiles.yml is also copied or generated

# Healthcheck (optional, but good for production)
HEALTHCHECK CMD ["airflow", "jobs", "check", "--job-type", "SchedulerJob", "--local"]