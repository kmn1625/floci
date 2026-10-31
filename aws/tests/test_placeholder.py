"""
test_placeholder.py -- Harness import smoke test.

This test does NOT start Floci. It only verifies:
1. All harness modules import without errors.
2. pytest configuration loads without errors.

Delete or replace this file once real tests are added in Phase 2.
"""

import pytest


def test_harness_imports():
    """Verify all harness modules are importable -- catches missing deps early."""
    import conftest          # noqa: F401
    import agent_invoker     # noqa: F401
    import assertions        # noqa: F401
    assert True, "All harness modules imported successfully"


def test_agent_result_dataclass():
    """AgentResult dataclass behaves correctly."""
    from agent_invoker import AgentResult
    result = AgentResult(
        exit_code=0,
        stdout="some agent output",
        stderr="",
        working_dir="/tmp/test",
        tf_files=["main.tf"],
    )
    assert result.success is True
    assert result.exit_code == 0


def test_boto3_client_factory_uses_fake_credentials(monkeypatch):
    """boto3 client factory injects Floci endpoint, not real AWS."""
    import os
    monkeypatch.setenv("AWS_ENDPOINT_URL", "http://localhost:4566")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "fake-agent-key-001")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    from assertions import get_boto3_client
    client = get_boto3_client("s3")
    # Verify the client's endpoint is Floci, not real AWS
    assert "localhost:4566" in client.meta.endpoint_url
