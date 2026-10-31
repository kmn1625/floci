"""
conftest.py -- Shared pytest fixtures for all Floci agent test phases.

Session fixture strategy:
- FlociContainer starts ONCE per pytest session (not per test).
- All tests share the same running Floci instance.
- Fake credentials are injected into os.environ at session start.
- Container is torn down after the full session completes.

IMPORTANT: AWS_ACCESS_KEY_ID must be 'fake-agent-key-001', NOT 'test'.
Using 'test' bypasses IAM enforcement in Floci silently (RESEARCH.md Blocker B).
"""

import os
import pytest
import requests
try:
    from floci import FlociContainer  # testcontainers-floci >= 0.4 (top-level package)
except ImportError:
    from testcontainers.floci import FlociContainer  # older layout

# ---------------------------------------------------------------------------
# Fake credential constants -- used here and importable by test modules
# ---------------------------------------------------------------------------
FLOCI_ACCESS_KEY_ID = "fake-agent-key-001"   # NOT "test" -- see module docstring
FLOCI_SECRET_ACCESS_KEY = "test"
FLOCI_REGION = "us-east-1"
FLOCI_ENDPOINT_URL = "http://localhost:4566"
FLOCI_ACCOUNT_ID = "000000000000"


@pytest.fixture(scope="session", autouse=True)
def floci_container():
    """
    Session-scoped fixture: starts Floci container with IAM enforcement flags active.

    Yields the running FlociContainer instance. All tests that need AWS resources
    should request this fixture (directly or via the `aws_client` fixture below).

    Note: If Floci is already running externally (e.g., via docker compose up -d),
    this fixture detects the existing instance and skips starting a new one.
    """
    # Check if Floci is already running externally (preferred for local dev)
    try:
        resp = requests.get(f"{FLOCI_ENDPOINT_URL}/_floci/health", timeout=3)
        if resp.status_code == 200:
            # Floci already up -- inject credentials and yield None (no managed container)
            _inject_credentials()
            yield None
            return
    except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
        pass

    # Start managed container via testcontainers-floci
    container = FlociContainer()
    container.with_env("FLOCI_SERVICES_IAM_ENFORCEMENT_ENABLED", "true")
    container.with_env("FLOCI_AUTH_VALIDATE_SIGNATURES", "true")
    container.with_env("FLOCI_SERVICES_IAM_SEED_DEPLOYER_PRINCIPAL", "true")
    container.with_env("LAMBDA_EXECUTOR", "docker")
    container.with_env("LAMBDA_REMOVE_CONTAINERS", "true")

    with container:
        # Managed container binds a random host port; point everything at it.
        _inject_credentials(container.get_endpoint())
        yield container


def _inject_credentials(endpoint_url=FLOCI_ENDPOINT_URL):
    """Inject fake credentials into os.environ for boto3 and AWS CLI usage."""
    os.environ["AWS_ACCESS_KEY_ID"] = FLOCI_ACCESS_KEY_ID
    os.environ["AWS_SECRET_ACCESS_KEY"] = FLOCI_SECRET_ACCESS_KEY
    os.environ["AWS_DEFAULT_REGION"] = FLOCI_REGION
    os.environ["AWS_ENDPOINT_URL"] = endpoint_url
    os.environ["AWS_ACCOUNT_ID"] = FLOCI_ACCOUNT_ID
    # Prevent boto3 from trying real AWS metadata endpoint
    os.environ["AWS_EC2_METADATA_DISABLED"] = "true"


@pytest.fixture(scope="session")
def floci_endpoint(floci_container):
    """Return the Floci endpoint URL. Use in tests: `def test_foo(floci_endpoint)`."""
    return os.environ.get("AWS_ENDPOINT_URL", FLOCI_ENDPOINT_URL)


@pytest.fixture(scope="session")
def aws_credentials():
    """Return the fake credential dict for explicit boto3 client construction."""
    return {
        "aws_access_key_id": FLOCI_ACCESS_KEY_ID,
        "aws_secret_access_key": FLOCI_SECRET_ACCESS_KEY,
        "region_name": FLOCI_REGION,
        "endpoint_url": os.environ.get("AWS_ENDPOINT_URL", FLOCI_ENDPOINT_URL),
    }
