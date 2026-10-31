"""
assertions.py -- boto3-based assertion helpers for Floci resource verification.

All clients are pre-wired to Floci endpoint (localhost:4566) with fake credentials.
Never point these at real AWS -- that would be both unsafe and incorrect.

Usage in tests:
    from assertions import get_boto3_client, assert_s3_bucket_exists

    assert_s3_bucket_exists("my-test-bucket")
"""

import boto3
import botocore
import os
from typing import Any


FLOCI_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
FLOCI_REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")


def get_boto3_client(service: str, **kwargs) -> Any:
    """
    Return a boto3 client pre-configured for Floci.

    Args:
        service: AWS service name (e.g. "s3", "iam", "lambda", "ec2")
        **kwargs: Additional kwargs passed to boto3.client()

    Returns:
        boto3 client pointing at Floci endpoint with fake credentials.
    """
    return boto3.client(
        service,
        region_name=FLOCI_REGION,
        endpoint_url=FLOCI_ENDPOINT_URL,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "fake-agent-key-001"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
        **kwargs,
    )


def assert_resource_exists(client_type: str, describe_fn: str, **describe_kwargs) -> dict:
    """
    Generic resource existence assertion.

    Args:
        client_type: boto3 client type (e.g. "s3", "iam")
        describe_fn: Method name on the client (e.g. "head_bucket", "get_role")
        **describe_kwargs: Kwargs to pass to the describe function.

    Returns:
        The describe response dict on success.

    Raises:
        AssertionError: If the resource does not exist (ClientError raised).
    """
    client = get_boto3_client(client_type)
    method = getattr(client, describe_fn)
    try:
        response = method(**describe_kwargs)
        return response
    except botocore.exceptions.ClientError as e:
        raise AssertionError(
            f"Resource not found: {client_type}.{describe_fn}({describe_kwargs}) "
            f"raised {e.response['Error']['Code']}: {e.response['Error']['Message']}"
        ) from e


def assert_iam_role_exists(role_name: str) -> dict:
    """Assert IAM role exists in Floci. Returns the role dict."""
    client = get_boto3_client("iam")
    try:
        resp = client.get_role(RoleName=role_name)
        return resp["Role"]
    except botocore.exceptions.ClientError as e:
        raise AssertionError(f"IAM role '{role_name}' not found: {e}") from e


def assert_s3_bucket_exists(bucket_name: str) -> dict:
    """Assert S3 bucket exists in Floci. Returns head_bucket response."""
    return assert_resource_exists("s3", "head_bucket", Bucket=bucket_name)


def assert_lambda_exists(function_name: str) -> dict:
    """Assert Lambda function exists in Floci. Returns function config dict."""
    client = get_boto3_client("lambda")
    try:
        resp = client.get_function_configuration(FunctionName=function_name)
        return resp
    except botocore.exceptions.ClientError as e:
        raise AssertionError(f"Lambda function '{function_name}' not found: {e}") from e
