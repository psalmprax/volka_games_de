import boto3
import json
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

def get_secret(secret_name: str, region_name: str) -> dict:
    """Retrieves and parses a JSON secret from AWS Secrets Manager.

    Args:
        secret_name: The name or ARN of the secret.
        region_name: The AWS region where the secret is stored.

    Returns:
        A dictionary containing the secret's key-value pairs.

    Raises:
        ClientError: If an AWS API error occurs (e.g., secret not found).
        ValueError: If the secret does not contain a 'SecretString',
                    or if the 'SecretString' is not valid JSON.
    """
    session = boto3.session.Session()
    client = session.client(service_name='secretsmanager', region_name=region_name)
    try:
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
    except ClientError as e:
        logger.error(f"AWS error retrieving secret '{secret_name}': {e}")
        raise

    secret_string = get_secret_value_response.get('SecretString')
    if not secret_string:
        logger.error(f"Secret '{secret_name}' does not contain a SecretString.")
        raise ValueError(f"Secret '{secret_name}' does not contain a SecretString.")

    try:
        return json.loads(secret_string)
    except json.JSONDecodeError as e:
        logger.error(f"Failed to decode JSON from secret '{secret_name}': {e}")
        raise ValueError(f"Secret '{secret_name}' is not a valid JSON string.") from e

def get_api_key_from_secret(secret_name: str, region_name: str) -> dict:
    """Retrieves an API key from a secret, formatted for use as a header.

    This function expects the secret to be a JSON object with an "x-api-key" field.

    Args:
        secret_name: The name or ARN of the secret containing the API key.
        region_name: The AWS region where the secret is stored.

    Returns:
        A dictionary in the format `{'x-api-key': 'your-api-key'}`.

    Raises:
        ValueError: If the secret does not contain the 'x-api-key' field.
        ClientError: If an AWS API error occurs (propagated from get_secret).
    """
    secret_content = get_secret(secret_name, region_name)
    api_key = secret_content.get("x-api-key")
    if not api_key:
        raise ValueError(f"Secret '{secret_name}' is missing 'x-api-key' field.")
    return {"x-api-key": api_key}