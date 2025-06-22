#!/bin/bash
# decrypt_env.sh

# Define the plaintext file name, consistent with encrypt_env.sh
PLAINTEXT_ENV_FILE=".env"

# Assume DECRYPTION_KEY is passed as an environment variable to the container
if [ -z "$DECRYPTION_KEY" ]; then
  echo "Error: DECRYPTION_KEY is not set."
  exit 1
fi

if [ -f ".env.encrypted" ]; then
  echo "Decrypting .env.encrypted..."
  # Use openssl or another tool to decrypt .env.encrypted to .env
  openssl enc -aes-256-cbc -d -in .env.encrypted -out "$PLAINTEXT_ENV_FILE" -k "$DECRYPTION_KEY"
  if [ $? -ne 0 ]; then
    echo "Error: Decryption failed."
    exit 1
  fi
  echo ".env decrypted."
else
  echo "Warning: .env.encrypted not found. Proceeding without decryption."
  # If no encrypted file, check for plaintext .env and source it
  if [ -f "$PLAINTEXT_ENV_FILE" ]; then
    echo "Sourcing plaintext .env file."
  else
    echo "Error: Neither .env.encrypted nor .env found."
    exit 1
  fi
fi

# Source the .env file to load variables into the script's environment
# Use set -a to export all variables for subsequent commands like `airflow`
set -a
source "$PLAINTEXT_ENV_FILE"
set +a

# Create Airflow Connection using the loaded environment variables
# Ensure DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, DB_PORT are set in .env
# This makes the script idempotent. It checks if the connection exists and replaces it.
echo "Checking for existing Airflow connection 'postgres_default'..."
if airflow connections get postgres_default >/dev/null 2>&1; then
  echo "Connection 'postgres_default' exists. Deleting to re-create."
  airflow connections delete postgres_default
fi

# echo "Adding Airflow PostgreSQL connection 'postgres_default'..."
# airflow connections add postgres_default \
#     --conn-type postgres \
#     --conn-host "$DB_HOST" \
#     --conn-schema "$DB_NAME" \
#     --conn-login "$DB_USER" \
#     --conn-password "$DB_PASSWORD" \
#     --conn-port "$DB_PORT"

# Execute the original command passed to the container
exec "$@"
