import boto3
import json
import logging
import os

logger = logging.getLogger(__name__)

def get_secret(secret_name: str, region_name: str) -> dict:
    """
    Retrieves a secret from AWS Secrets Manager.
    Assumes the secret is a JSON string containing key-value pairs.
    """
    session = boto3.session.Session()
    client = session.client(service_name='secretsmanager', region_name=region_name)
    try:
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
    except Exception as e:
        logger.error(f"Error retrieving secret {secret_name}: {e}")
        raise
    else:
        if 'SecretString' in get_secret_value_response:
            secret = get_secret_value_response['SecretString']
            return json.loads(secret)
        else:
            logger.error(f"Secret {secret_name} does not contain SecretString.")
            raise ValueError(f"Secret {secret_name} does not contain SecretString.")

def get_api_key_from_secret(secret_name: str, region_name: str) -> dict:
    """
    Retrieves the API key specifically, expecting a structure like {"x-api-key": "value"}.
    """
    secret_content = get_secret(secret_name, region_name)
    if "x-api-key" not in secret_content:
        raise ValueError(f"Secret {secret_name} is missing 'x-api-key' field.")
    return {"x-api-key": secret_content["x-api-key"]}