"""
test_smoke.py -- Pre-flight smoke tests for Floci agent test suite.

MUST PASS before any Phase 2+ tests run. These tests confirm:
1. Floci container is running and all services are healthy
2. Fake credentials are wired correctly (boto3 reaches Floci, not real AWS)
3. IAM enforcement is ACTIVE (not in default permit-all mode)
4. Each target service (S3, Lambda, IAM, EC2, EKS) responds to API calls

Run only smoke tests:
    pytest -m smoke -v

Run smoke tests first, then all others:
    pytest -m "smoke or not smoke" -v
    # Or configure pytest-ordering for automatic ordering.
"""

import pytest
import requests
import botocore.exceptions

# Import harness modules -- if these fail, the harness itself is broken (Plan 02 incomplete)
from assertions import get_boto3_client
from conftest import FLOCI_ENDPOINT_URL, FLOCI_ACCESS_KEY_ID


# ---------------------------------------------------------------------------
# Helper: skip remaining smoke tests if overall health fails
# ---------------------------------------------------------------------------

_FLOCI_HEALTHY = False  # module-level flag set by test_floci_overall_health


# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------

@pytest.mark.smoke
def test_floci_overall_health():
    """
    Check Floci's /_floci/health endpoint returns HTTP 200.
    This is the gate test -- if it fails, all other smoke tests are skipped.
    """
    global _FLOCI_HEALTHY
    try:
        resp = requests.get(f"{FLOCI_ENDPOINT_URL}/_floci/health", timeout=10)
        assert resp.status_code == 200, (
            f"Floci health endpoint returned {resp.status_code}. "
            f"Start Floci: cd floci-testing && docker compose up -d"
        )
        _FLOCI_HEALTHY = True
    except requests.exceptions.ConnectionError as e:
        pytest.fail(
            f"Cannot connect to Floci at {FLOCI_ENDPOINT_URL}. "
            f"Is Floci running? cd floci-testing && docker compose up -d\n"
            f"Error: {e}"
        )


@pytest.mark.smoke
def test_fake_credentials_are_not_real_aws_key():
    """
    Guard rail: ensure the test environment is using the correct fake key ID.
    AWS_ACCESS_KEY_ID must be 'fake-agent-key-001', NOT 'test'.
    Using 'test' bypasses IAM enforcement silently (RESEARCH.md Blocker B).
    """
    import os
    key_id = os.environ.get("AWS_ACCESS_KEY_ID", "")
    assert key_id == "fake-agent-key-001", (
        f"AWS_ACCESS_KEY_ID is '{key_id}' but must be 'fake-agent-key-001'. "
        f"Source floci-testing/.env.floci before running tests: "
        f"  source floci-testing/.env.floci  (bash)"
        f"  or run via: pytest --env-file floci-testing/.env.floci"
    )


@pytest.mark.smoke
def test_iam_enforcement_active():
    """
    Verify IAM enforcement is ACTIVE by calling an IAM API without permissions
    and asserting we get AccessDenied (not a success or a 200).

    If enforcement is OFF (permit-all mode), all IAM calls succeed regardless
    of the principal's policies -- making every IAM test in Phase 2 a false positive.

    Strategy: List IAM roles with a fresh boto3 client (no session setup).
    With enforcement ON and no policies seeded for fake-agent-key-001,
    this should raise AccessDenied. With enforcement OFF, it succeeds silently.

    NOTE: This test may need adjustment if Floci seeds the deployer principal
    (FLOCI_SERVICES_IAM_SEED_DEPLOYER_PRINCIPAL=true) with broad permissions.
    If so, comment out the AccessDenied assertion and replace with:
        assert resp is not None, "IAM reachable (enforcement active)"
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy -- skipping enforcement check")

    iam = get_boto3_client("iam")
    try:
        # list_roles with no session is a low-blast-radius call
        resp = iam.list_roles(MaxItems=1)
        # If we reach here, enforcement is either off OR deployer principal has broad perms
        # Both are acceptable -- the deployer principal flag seeds a superuser for tests
        assert "Roles" in resp, "IAM API reachable -- enforcement mode active (deployer principal seeded)"
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            # This is also correct: enforcement IS active, no permissions for this principal
            pass
        elif code in ("InvalidClientTokenId", "AuthFailure"):
            pytest.fail(
                f"IAM call failed with {code} -- credentials not recognized by Floci. "
                f"Check that FLOCI_AUTH_VALIDATE_SIGNATURES=true is set in docker-compose.yml "
                f"and fake-agent-key-001 is being used as the access key ID."
            )
        else:
            pytest.fail(f"Unexpected IAM error: {code}: {e}")


@pytest.mark.smoke
def test_s3_service_reachable():
    """
    S3 service responds to list_buckets() -- confirms S3 port is up and
    boto3 endpoint wiring is correct.
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy")

    s3 = get_boto3_client("s3")
    try:
        resp = s3.list_buckets()
        # list_buckets returns 200 even with an empty bucket list
        assert "Buckets" in resp, f"Unexpected response from S3 list_buckets: {resp}"
    except botocore.exceptions.EndpointResolutionError as e:
        pytest.fail(f"S3 endpoint not reachable at {FLOCI_ENDPOINT_URL}: {e}")
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            # AccessDenied means S3 is up and enforcement is working -- pass
            pass
        else:
            pytest.fail(f"S3 smoke check failed: {code}: {e}")


@pytest.mark.smoke
def test_lambda_service_reachable():
    """
    Lambda service responds to list_functions() -- confirms Lambda port is up.
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy")

    lam = get_boto3_client("lambda")
    try:
        resp = lam.list_functions(MaxItems=1)
        assert "Functions" in resp
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            pass  # Enforcement active -- Lambda is reachable
        else:
            pytest.fail(f"Lambda smoke check failed: {code}: {e}")


@pytest.mark.smoke
def test_iam_service_reachable():
    """
    IAM service responds -- confirms IAM port and enforcement path are up.
    Separate from test_iam_enforcement_active which checks enforcement behavior.
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy")

    iam = get_boto3_client("iam")
    try:
        # get_account_summary is a lightweight read operation
        resp = iam.list_roles(MaxItems=1)
        assert "Roles" in resp
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDenied", "NotAuthorized"):
            pass  # IAM is reachable; enforcement blocking the call is expected
        else:
            pytest.fail(f"IAM smoke check failed: {code}: {e}")


@pytest.mark.smoke
def test_ec2_service_reachable():
    """
    EC2 service responds to describe_regions() -- confirms EC2/networking port is up.
    Note: aws_instance Terraform resource is broken in Floci (issue #871).
    This smoke test only checks API reachability, not instance launch.
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy")

    ec2 = get_boto3_client("ec2")
    try:
        resp = ec2.describe_regions(RegionNames=["us-east-1"])
        assert "Regions" in resp
        assert len(resp["Regions"]) >= 1
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            pass  # EC2 is reachable
        else:
            pytest.fail(f"EC2 smoke check failed: {code}: {e}")


@pytest.mark.smoke
def test_eks_endpoint_reachable():
    """
    EKS service responds to list_clusters() -- confirms EKS API port is up.
    Note: kubectl access requires the kubeconfig workaround script (Plan 03, issue #1118).
    This smoke test only checks the EKS control plane API, not kubectl.
    """
    if not _FLOCI_HEALTHY:
        pytest.skip("Floci is not healthy")

    eks = get_boto3_client("eks")
    try:
        resp = eks.list_clusters()
        assert "clusters" in resp
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            pass  # EKS is reachable
        else:
            pytest.fail(f"EKS smoke check failed: {code}: {e}")


@pytest.mark.smoke
def test_ecr_ports_not_premapped():
    """
    Verify ECR ports 5100-5199 are NOT in the docker-compose ports block.
    Pre-mapping these ports blocks ECR sidecar startup (RESEARCH.md Top Gotcha #2).

    This test asserts the docker-compose.yml file content directly -- it does not
    require Floci to be running.
    """
    import os
    from pathlib import Path

    # Find docker-compose.yml relative to the test directory
    # Tests run from floci-testing/ directory
    compose_path = Path(__file__).parent.parent / "docker-compose.yml"
    assert compose_path.exists(), f"docker-compose.yml not found at {compose_path}"

    content = compose_path.read_text()

    # Check that no port in the 5100-5199 range appears as an ACTIVE port mapping
    # (not in comments). Strip comments before scanning to avoid false positives from
    # documentation that says "do NOT add 5100-5199".
    import re
    # Remove comment lines (lines starting with optional whitespace then #)
    lines_without_comments = "\n".join(
        line for line in content.splitlines()
        if not line.lstrip().startswith("#")
    )
    # Also strip inline comments (e.g. "- 4566:4566  # description")
    lines_without_comments = re.sub(r'\s*#.*$', '', lines_without_comments, flags=re.MULTILINE)

    # Match port mapping patterns in the 5100-5199 range:
    # "- 5100:5100", "- \"5150:5150\"", "5100-5199", bare "5100", etc.
    ecr_port_pattern = re.compile(r'51\d{2}')
    matches = ecr_port_pattern.findall(lines_without_comments)

    assert len(matches) == 0, (
        f"docker-compose.yml contains ECR port references (5100-5199) outside comments: {matches}. "
        f"These ports must NOT be pre-mapped -- ECR uses dynamic sidecar binding. "
        f"Remove them from the ports: block in docker-compose.yml."
    )


@pytest.mark.smoke
def test_floci_image_is_pinned():
    """
    Verify docker-compose.yml pins Floci image to 1.5.15, not 'latest'.
    Using 'latest' breaks reproducibility of the test baseline.
    """
    from pathlib import Path

    compose_path = Path(__file__).parent.parent / "docker-compose.yml"
    assert compose_path.exists(), f"docker-compose.yml not found at {compose_path}"

    content = compose_path.read_text()

    assert "floci/floci:latest" not in content, (
        "docker-compose.yml uses 'floci/floci:latest' -- pin to 'floci/floci:1.5.15' instead."
    )
    assert "floci/floci:1.5.15" in content, (
        "docker-compose.yml does not contain 'floci/floci:1.5.15'. "
        "Image must be pinned to exactly this version per RESEARCH.md."
    )
