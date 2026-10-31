#!/usr/bin/env python3
"""Data-plane smoke tests for the Azure lab. Run inside the toolbox:

    docker compose run --rm toolbox python3 tests/smoke.py

Reads names from `terraform output -json` and exercises each service the way an
app would (not through ARM): blob, queue, table, Key Vault (Entra token), Postgres,
Redis. Also records emulator behaviour that differs from Azure (FINDINGS.md).
Exit code: number of failed checks.
"""

import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

ARM = "https://floci-az:4577"
TENANT = "00000000-0000-0000-0000-000000000002"
results = []


class KnownGap(Exception):
    """Emulator behaviour already recorded in FINDINGS.md: reported, not counted as a failure."""


def check(name, fn):
    try:
        detail = fn() or ""
        results.append(("PASS", name, detail))
    except KnownGap as e:
        results.append(("GAP", name, str(e)))
    except Exception as e:  # noqa: BLE001 — a smoke test reports every failure
        results.append(("FAIL", name, f"{type(e).__name__}: {e}"[:300]))


def http(method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, r.read().decode("utf-8", "replace")


def tf_outputs():
    out = subprocess.run(["terraform", "-chdir=terraform", "output", "-json"],
                         capture_output=True, text=True, check=True).stdout
    return {k: v["value"] for k, v in json.loads(out).items()}


o = tf_outputs()
st, kv, pg, redis = o["storage_account"], o["key_vault_uri"], o["postgres_host"], o["redis"]
xms = {"x-ms-version": "2021-08-06", "x-ms-date": "Thu, 01 Jan 2026 00:00:00 GMT"}
blob = f"http://{st}.blob.core.windows.net/artifacts/smoke-{uuid.uuid4().hex[:8]}.txt"


def blob_roundtrip():
    http("PUT", blob, b"floci-lab", {**xms, "x-ms-blob-type": "BlockBlob", "Content-Type": "text/plain"})
    status, text = http("GET", blob, headers=xms)
    assert text == "floci-lab", text
    http("DELETE", blob, headers=xms)
    return "put/get/delete"


def queue_roundtrip():
    q = f"http://{st}.queue.core.windows.net/jobs/messages"
    http("POST", q, b"<QueueMessage><MessageText>smoke</MessageText></QueueMessage>", xms)
    status, text = http("GET", q, headers=xms)
    assert "smoke" in text, text[:200]
    return "enqueue/dequeue"


def table_roundtrip():
    base = f"http://{st}.table.core.windows.net"
    h = {**xms, "Content-Type": "application/json", "Accept": "application/json;odata=nometadata"}
    name = "smoke" + uuid.uuid4().hex[:6]
    http("POST", f"{base}/Tables", json.dumps({"TableName": name}).encode(), h)
    http("POST", f"{base}/{name}", json.dumps({"PartitionKey": "p", "RowKey": "1", "v": 42}).encode(), h)
    status, text = http("GET", f"{base}/{name}(PartitionKey='p',RowKey='1')", headers=h)
    assert json.loads(text)["v"] == 42, text
    http("DELETE", f"{base}/Tables('{name}')", headers=h)
    return "create/insert/query/drop"


def keyvault_secret():
    status, text = http("POST", f"{ARM}/{TENANT}/oauth2/v2.0/token", urllib.parse.urlencode({
        "grant_type": "client_credentials", "client_id": "lab", "client_secret": "lab",
        "scope": "https://vault.azure.net/.default"}).encode(),
        {"Content-Type": "application/x-www-form-urlencoded"})
    token = json.loads(text)["access_token"]
    status, text = http("GET", f"{kv.rstrip('/')}/secrets/db-password?api-version=7.4",
                        headers={"Authorization": f"Bearer {token}"})
    assert len(json.loads(text)["value"]) == 24
    return "Entra token -> secret read (value not printed)"


def keyvault_without_token_rejected():
    try:
        http("GET", f"{kv.rstrip('/')}/secrets/db-password?api-version=7.4")
    except urllib.error.HTTPError as e:
        assert e.code == 401, e.code
        return "401 without a bearer token"
    raise AssertionError("secret readable without a token")


def psql(db, sql):
    env = {**os.environ, "PGPASSWORD": o["db_password"], "PGCONNECT_TIMEOUT": "10"}
    r = subprocess.run(["psql", "-h", pg, "-U", "labadmin", "-d", db, "-tAc", sql],
                       capture_output=True, text=True, env=env)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-200:])
    return r.stdout.strip()


def postgres():
    version = psql("postgres", "show server_version")
    if not version.startswith("16"):
        raise KnownGap(f"F-29: server is {version}, Terraform asked for version 16")
    return f"server_version {version}"


def postgres_app_database():
    names = psql("postgres", "select datname from pg_database").split()
    if "app" not in names:
        raise KnownGap("F-28: azurerm_postgresql_flexible_server_database 'app' exists only in ARM, not in the server")
    return "database 'app' present"


def redis_ping():
    out = subprocess.run(["redis-cli", "-h", redis["host"], "-p", str(redis["port"]), "--no-auth-warning",
                          "-a", redis["key"], "PING"], capture_output=True, text=True, timeout=15).stdout.strip()
    assert out == "PONG", out
    return "PING -> PONG"


def redis_plaintext_disabled():
    # non_ssl_port_enabled = false: Azure serves TLS on 6380 only.
    out = subprocess.run(["redis-cli", "-h", redis["host"], "-p", "6379", "--no-auth-warning",
                          "-a", redis["key"], "PING"], capture_output=True, text=True, timeout=15).stdout.strip()
    if out == "PONG":
        raise KnownGap("F-27: plaintext port 6379 answers although enableNonSslPort=false")
    return "plaintext port closed"


for name, fn in [("blob", blob_roundtrip), ("queue", queue_roundtrip), ("table", table_roundtrip),
                 ("keyvault secret", keyvault_secret), ("keyvault auth", keyvault_without_token_rejected),
                 ("postgres", postgres), ("postgres app db", postgres_app_database),
                 ("redis", redis_ping), ("redis tls-only", redis_plaintext_disabled)]:
    check(name, fn)

width = max(len(n) for _, n, _ in results)
for status, name, detail in results:
    print(f"  [{status}] {name:<{width}}  {detail}")
failed = sum(1 for s, _, _ in results if s == "FAIL")
gaps = sum(1 for s, _, _ in results if s == "GAP")
print(f"\n{len(results) - failed - gaps} passed, {gaps} known emulator gaps, {failed} failed")
raise SystemExit(failed)
