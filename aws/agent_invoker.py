"""
agent_invoker.py -- Invoke Claude agents against Floci and capture output.

Usage in tests:
    from agent_invoker import invoke_agent, AgentResult

    result = invoke_agent("terraform-agent", "Create an S3 bucket named test-bucket")
    assert result.exit_code == 0
    assert "aws_s3_bucket" in result.stdout

Design decisions:
- Agents are invoked via `claude --agent <name> --print` (non-interactive).
- stdout is captured and returned as AgentResult.stdout.
- stderr is captured separately as AgentResult.stderr.
- Terraform files written by agents are captured from a temp working directory.
"""

import atexit
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class AgentResult:
    """Result of a single agent invocation."""
    exit_code: int
    stdout: str
    stderr: str
    working_dir: str
    tf_files: list[str] = field(default_factory=list)

    @property
    def success(self) -> bool:
        return self.exit_code == 0

    def get_tf_content(self) -> str:
        """Return concatenated content of all .tf files written by the agent."""
        contents = []
        for tf_file in self.tf_files:
            path = Path(self.working_dir) / tf_file
            if path.exists():
                contents.append(path.read_text())
        return "\n\n".join(contents)


def invoke_agent(
    agent_name: str,
    prompt: str,
    working_dir: Optional[str] = None,
    timeout: int = 120,
    extra_env: Optional[dict] = None,
) -> AgentResult:
    """
    Invoke a Claude agent by name with the given prompt.

    Args:
        agent_name: Name of the agent (e.g. "terraform-agent", "aws-agent").
                    Must match a file in .claude/agents/<name>.agent.md.
        prompt:     The task prompt to pass to the agent.
        working_dir: Directory to run the agent in. Defaults to a temp dir.
        timeout:    Max seconds to wait for agent completion.
        extra_env:  Additional environment variables to inject.

    Returns:
        AgentResult with exit_code, stdout, stderr, and list of .tf files created.
    """
    # Use provided working_dir or create a temp one
    if working_dir is None:
        working_dir = tempfile.mkdtemp(prefix=f"floci-{agent_name}-")
        atexit.register(shutil.rmtree, working_dir, True)

    # Build environment: inherit current env + fake credentials + any extras
    # Explicitly overwrite AWS creds to prevent real-AWS credential leakage (T-02-01)
    env = os.environ.copy()
    env["AWS_ACCESS_KEY_ID"] = os.environ.get("AWS_ACCESS_KEY_ID", "fake-agent-key-001")
    env["AWS_SECRET_ACCESS_KEY"] = os.environ.get("AWS_SECRET_ACCESS_KEY", "test")
    env["AWS_DEFAULT_REGION"] = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    env["AWS_ENDPOINT_URL"] = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
    if extra_env:
        env.update(extra_env)

    # Build the claude command
    # --agent: specifies which agent definition to use
    # --print: non-interactive, outputs to stdout
    cmd = ["claude", "--agent", agent_name, "--print", prompt]

    try:
        result = subprocess.run(
            cmd,
            cwd=working_dir,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return AgentResult(
            exit_code=-1,
            stdout="",
            stderr=f"Agent '{agent_name}' timed out after {timeout}s",
            working_dir=working_dir,
            tf_files=[],
        )

    # Collect any .tf files the agent wrote to working_dir
    tf_files = [
        f.name for f in Path(working_dir).glob("*.tf")
    ]

    return AgentResult(
        exit_code=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
        working_dir=working_dir,
        tf_files=tf_files,
    )
