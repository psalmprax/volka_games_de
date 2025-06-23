#!/bin/bash
# This script encrypts the .env file into .env.encrypted using openssl.

PLAINTEXT_ENV_FILE=".env"
ENCRYPTED_ENV_FILE=".env.encrypted"

# Check if the plaintext .env file exists
if [ ! -f "$PLAINTEXT_ENV_FILE" ]; then
  echo "Error: Plaintext file '$PLAINTEXT_ENV_FILE' not found in the current directory."
  exit 1
fi

# Prompt for the encryption key
echo -n "Enter the encryption key (this will be your DECRYPTION_KEY): "
read -s ENCRYPTION_KEY # -s flag hides the input
echo # Newline after hidden input

if [ -z "$ENCRYPTION_KEY" ]; then
  echo "Error: Encryption key cannot be empty."
  exit 1
fi

echo "Encrypting '$PLAINTEXT_ENV_FILE' to '$ENCRYPTED_ENV_FILE'..."
openssl enc -aes-256-cbc -salt -in "$PLAINTEXT_ENV_FILE" -out "$ENCRYPTED_ENV_FILE" -k "$ENCRYPTION_KEY"

if [ $? -eq 0 ]; then
  echo "Encryption successful: '$ENCRYPTED_ENV_FILE' created."
  echo "IMPORTANT: Remember to export the key as DECRYPTION_KEY for the start.sh script to use."
else
  echo "Error: Encryption failed."
  exit 1
fi