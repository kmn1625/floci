#!/usr/bin/env python3
"""Data-plane smoke tests for the GCP lab. Run in the toolbox (CLOUD=gcp):

    docker compose --profile tools run --rm toolbox sh -c "pip install -q google-cloud-firestore && python3 tests/smoke.py"

Reads names from `terraform output -json` and uses each service the way an app would, over
REST with Floci-issued service-account tokens so IAM enforcement is exercised:
GCS (CMEK, versioning, public access prevention, bucket IAM), Pub/Sub (publish IAM,
dead-lettering), KMS, Secret Manager IAM, IAM token minting, BigQuery, Cloud SQL
PostgreSQL (TLS), Cloud Run (service, invoker IAM, job), Cloud Scheduler, Firestore,
Logging, Monitoring, Firebase Auth, GKE.
Objects and users the tests create are removed again. Known emulator gaps report as GAP
(see FINDINGS.md); exit code = number of FAILs.
"""

import base64
import datetime
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

results = []
E = os.environ.get("FLOCI_GCP_ENDPOINT", "http://floci-gcp:4588")
PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT", "flocilab")
REGION = "us-central1"


class KnownGap(Exception):
    """Behaviour already recorded in FINDINGS.md."""


def check(name, fn):
    try:
        results.append(("PASS", name, fn() or ""))
    except KnownGap as e:
        results.append(("GAP", name, str(e)))
    except Exception as e:  # noqa: BLE001 — a smoke test reports every failure
        results.append(("FAIL", name, f"{type(e).__name__}: {e}"[:260]))


def call(method, url, token=None, body=None, raw=None, headers=None):
    """(status, parsed JSON or bytes). Never raises on HTTP errors."""
    h = dict(headers or {})
    if token:
        h["Authorization"] = f"Bearer {token}"
    data = raw
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url if url.startswith("http") else E + url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, payload = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, payload = e.code, e.read()
    try:
        return status, json.loads(payload or b"{}")
    except ValueError:
        return status, payload


def ok(status, payload, *expected):
    assert status in (expected or (200,)), f"HTTP {status}: {str(payload)[:200]}"
    return payload


out = json.loads(subprocess.run(["terraform", "-chdir=terraform", "output", "-json"],
                                capture_output=True, text=True, check=True).stdout)
o = {k: v["value"] for k, v in out.items() if not v["sensitive"]}
tag = uuid.uuid4().hex[:8]
b64 = lambda b: base64.b64encode(b).decode()  # noqa: E731


def mint(email):
    """Floci-issued token for a service account (IAM Credentials generateAccessToken)."""
    s, p = call("POST", f"/v1/projects/-/serviceAccounts/{email}:generateAccessToken",
                token=os.environ["GOOGLE_OAUTH_ACCESS_TOKEN"],
                body={"scope": ["https://www.googleapis.com/auth/cloud-platform"], "lifetime": "900s"})
    return ok(s, p)["accessToken"]


DEPLOYER = f"flocilab-deployer@{PROJECT}.iam.gserviceaccount.com"
tok = {"deployer": mint(DEPLOYER), "app": mint(o["app_service_account"]), "invoker": mint(o["invoker_service_account"])}


def gcs():
    b, name = o["artifacts_bucket"], f"smoke/{tag}.txt"
    up = lambda body: call("POST", f"/upload/storage/v1/b/{b}/o?uploadType=media&name={urllib.parse.quote(name, safe='')}",  # noqa: E731
                           token=tok["deployer"], raw=body, headers={"Content-Type": "text/plain"})
    ok(*up(b"v1"))
    meta = ok(*up(b"v2"))
    obj = f"/storage/v1/b/{b}/o/{urllib.parse.quote(name, safe='')}"
    s, body = call("GET", obj + "?alt=media", token=tok["deployer"])
    versions = ok(*call("GET", f"/storage/v1/b/{b}/o?versions=true&prefix=smoke/{tag}", token=tok["deployer"])).get("items", [])
    for v in versions:
        call("DELETE", f"{obj}?generation={v['generation']}", token=tok["deployer"])
    assert s == 200 and body == b"v2", (s, body)
    assert len(versions) == 2, f"versioning kept {len(versions)} generations"
    if not meta.get("kmsKeyName"):
        raise KnownGap("objects stored and versioned, but the bucket's default CMEK key is not applied (G-14)")
    return "2 generations, CMEK applied"


def gcs_iam():
    b, readme = o["artifacts_bucket"], f"/storage/v1/b/{o['artifacts_bucket']}/o/README.txt?alt=media"
    app_read = call("GET", readme, token=tok["app"])[0]
    invoker_read = call("GET", readme, token=tok["invoker"])[0]
    app_write = call("POST", f"/upload/storage/v1/b/{b}/o?uploadType=media&name=smoke-denied-{tag}",
                     token=tok["app"], raw=b"x", headers={"Content-Type": "text/plain"})[0]
    if app_write == 200:
        call("DELETE", f"/storage/v1/b/{b}/o/smoke-denied-{tag}", token=tok["deployer"])
    assert (app_read, invoker_read, app_write) == (200, 403, 403), \
        f"app read {app_read}, invoker read {invoker_read}, app write {app_write}; want 200/403/403"
    # public access prevention: granting allUsers must be refused
    policy = ok(*call("GET", f"/storage/v1/b/{b}/iam", token=tok["deployer"]))
    public = dict(policy, bindings=policy.get("bindings", []) + [{"role": "roles/storage.objectViewer", "members": ["allUsers"]}])
    s, _ = call("PUT", f"/storage/v1/b/{b}/iam", token=tok["deployer"], body=public)
    if s == 200:
        call("PUT", f"/storage/v1/b/{b}/iam", token=tok["deployer"],
             body=dict(policy, etag=ok(*call("GET", f"/storage/v1/b/{b}/iam", token=tok["deployer"])).get("etag")))
        raise KnownGap("bucket IAM enforced, but public_access_prevention=enforced still accepts allUsers (G-16)")
    return f"app reads, invoker denied, app write denied, allUsers grant refused (HTTP {s})"


def pubsub():
    topic, sub = f"/v1/projects/{PROJECT}/topics/{o['orders_topic']}", f"/v1/projects/{PROJECT}/subscriptions/{o['orders_subscription']}"
    msg = {"messages": [{"data": b64(json.dumps({"order_id": tag}).encode())}]}
    app_pub = call("POST", topic + ":publish", token=tok["app"], body=msg)[0]
    invoker_pub = call("POST", topic + ":publish", token=tok["invoker"], body=msg)[0]
    assert (app_pub, invoker_pub) == (200, 403), f"app publish {app_pub}, invoker publish {invoker_pub}; want 200/403"
    got = []
    for _ in range(10):
        got += ok(*call("POST", sub + ":pull", token=tok["deployer"], body={"maxMessages": 10})).get("receivedMessages", [])
        if any(tag in base64.b64decode(m["message"]["data"]).decode() for m in got):
            break
        time.sleep(1)
    ok(*call("POST", sub + ":acknowledge", token=tok["deployer"], body={"ackIds": [m["ackId"] for m in got]}))
    assert any(tag in base64.b64decode(m["message"]["data"]).decode() for m in got), "published order not pulled"
    return "app publishes, invoker denied, order pulled and acked"


def pubsub_dead_letter():
    topic, sub = f"/v1/projects/{PROJECT}/topics/{o['orders_topic']}", f"/v1/projects/{PROJECT}/subscriptions/{o['orders_subscription']}"
    dlq = f"/v1/projects/{PROJECT}/subscriptions/{o['orders_dlq_subscription']}"
    marker = f"poison-{tag}"
    ok(*call("POST", topic + ":publish", token=tok["deployer"], body={"messages": [{"data": b64(marker.encode())}]}))
    for _ in range(12):  # nack until max_delivery_attempts (5) is exceeded
        got = ok(*call("POST", sub + ":pull", token=tok["deployer"], body={"maxMessages": 10})).get("receivedMessages", [])
        ids = [m["ackId"] for m in got]
        if ids:
            call("POST", sub + ":modifyAckDeadline", token=tok["deployer"], body={"ackIds": ids, "ackDeadlineSeconds": 0})
        time.sleep(1)
    dead = ok(*call("POST", dlq + ":pull", token=tok["deployer"], body={"maxMessages": 10})).get("receivedMessages", [])
    if dead:
        call("POST", dlq + ":acknowledge", token=tok["deployer"], body={"ackIds": [m["ackId"] for m in dead]})
    assert any(base64.b64decode(m["message"]["data"]).decode() == marker for m in dead), \
        "message nacked past max_delivery_attempts never reached the dead-letter topic"
    return "poison message moved to the DLQ after 5 attempts"


def kms():
    key = o["kms_key"]
    ct = ok(*call("POST", f"/v1/{key}:encrypt", token=tok["deployer"], body={"plaintext": b64(b"floci-lab")}))["ciphertext"]
    pt = ok(*call("POST", f"/v1/{key}:decrypt", token=tok["deployer"], body={"ciphertext": ct}))["plaintext"]
    assert base64.b64decode(pt) == b"floci-lab"
    return "encrypt/decrypt round trip"


def secret_manager():
    path = f"/v1/projects/{PROJECT}/secrets/{o['db_password_secret']}/versions/latest:access"
    s_app, p = call("GET", path, token=tok["app"])
    s_inv, _ = call("GET", path, token=tok["invoker"])
    assert (s_app, s_inv) == (200, 403), f"app {s_app}, invoker {s_inv}; want 200/403"
    assert len(base64.b64decode(p["payload"]["data"])) == 24
    return "app reads the password, invoker denied"


def iam_impersonation():
    s, _ = call("POST", f"/v1/projects/-/serviceAccounts/{DEPLOYER}:generateAccessToken", token=tok["invoker"],
                body={"scope": ["https://www.googleapis.com/auth/cloud-platform"]})
    assert s == 403, f"invoker minted a deployer token (HTTP {s})"
    s, _ = call("POST", f"/v1/projects/-/serviceAccounts/{DEPLOYER}:generateAccessToken", token="anonymous-external",
                body={"scope": ["https://www.googleapis.com/auth/cloud-platform"]})
    if s == 200:
        raise KnownGap("SA callers are checked, but any external token mints any service account's token (G-18)")
    return "token minting needs iam.serviceAccounts.getAccessToken"


def bigquery():
    ds, tbl = o["bq_dataset"], f"/bigquery/v2/projects/{PROJECT}/datasets/{o['bq_dataset']}/tables/orders"
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    rows = [{"json": {"order_id": f"{tag}-{i}", "amount": str(10 * i), "created_at": now}} for i in (1, 2, 3)]
    p = ok(*call("POST", tbl + "/insertAll", token=tok["deployer"], body={"rows": rows}))
    assert not p.get("insertErrors"), p
    q = f"SELECT SUM(amount) AS total FROM `{PROJECT}.{ds}.orders` WHERE STARTS_WITH(order_id, '{tag}')"
    r = ok(*call("POST", f"/bigquery/v2/projects/{PROJECT}/queries", token=tok["deployer"], body={"query": q, "useLegacySql": False}))
    total = r["rows"][0]["f"][0]["v"]
    assert float(total) == 60, total
    return f"3 rows streamed, GoogleSQL SUM = {total}"


def cloud_sql():
    inst = ok(*call("GET", f"/sql/v1beta4/projects/{PROJECT}/instances/{o['sql_instance'].split(':')[-1]}", token=tok["deployer"]))
    ip = next(a for a in inst["ipAddresses"] if a["type"] == "PRIMARY")
    pw = base64.b64decode(ok(*call("GET", f"/v1/projects/{PROJECT}/secrets/{o['db_password_secret']}/versions/latest:access",
                                   token=tok["app"]))["payload"]["data"]).decode()
    env = dict(os.environ, PGPASSWORD=pw, PGCONNECT_TIMEOUT="10")
    dsn = f"host={ip['ipAddress']} port={ip.get('port', 5432)} user=app dbname=app"
    psql = lambda mode: subprocess.run(["psql", f"{dsn} sslmode={mode}", "-tAc", "select version()"],  # noqa: E731
                                       capture_output=True, text=True, env=env)
    plain, tls = psql("disable"), psql("require")
    assert plain.returncode == 0 or tls.returncode == 0, (plain.stderr or tls.stderr)[:200]
    ver = (plain.stdout or tls.stdout).split(",")[0].strip()
    if tls.returncode != 0:
        raise KnownGap(f"{ver} reachable with the Secret Manager password, but only without TLS though ssl_mode=ENCRYPTED_ONLY (G-19)")
    if plain.returncode == 0:
        raise KnownGap(f"{ver} over TLS, but plaintext is also accepted though ssl_mode=ENCRYPTED_ONLY (G-19)")
    return f"{ver}, TLS only"


def cloud_run():
    uri = o["hello_api_uri"]
    s, p = call("GET", uri + "/", token=tok["invoker"])
    assert s == 200 and p.get("env") == "cloudrun", (s, p)
    s_anon, _ = call("GET", uri + "/")
    if s_anon == 200:
        raise KnownGap(f"hello-api {p['version']} serves, but invocation is not IAM-checked: anonymous call allowed (G-20)")
    return f"hello-api {p['version']}, anonymous denied ({s_anon})"


def cloud_run_job():
    job = f"/v2/projects/{PROJECT}/locations/{REGION}/jobs/{o['migrate_job']}"
    ok(*call("POST", job + ":run", token=tok["deployer"], body={}))
    for _ in range(60):
        execs = ok(*call("GET", job + "/executions", token=tok["deployer"])).get("executions", [])
        latest = max(execs, key=lambda e: e.get("createTime", "")) if execs else {}
        if latest.get("completionTime"):
            assert latest.get("succeededCount") == 1, latest
            return f"execution {latest['name'].rsplit('/', 1)[-1]} succeeded"
        time.sleep(2)
    raise AssertionError("job execution did not complete in 120s")


def scheduler():
    job = f"/v1/projects/{PROJECT}/locations/{REGION}/jobs/{o['probe_job']}"
    ok(*call("POST", job + ":run", token=tok["deployer"], body={}))
    time.sleep(3)
    status = ok(*call("GET", job, token=tok["deployer"])).get("status", {})
    if status.get("code", 0) != 0:
        raise KnownGap(f"job fires, but the HTTP call to the Cloud Run URL fails inside floci-gcp (status {status}) (G-15)")
    return "probe job ran, target answered"


def firestore():
    from google.cloud import firestore as fs  # emulator via FIRESTORE_EMULATOR_HOST
    db = fs.Client(project=PROJECT)
    ref = db.collection("orders").document(tag)
    ref.set({"amount": 42, "status": "new"})
    ref.update({"status": "paid"})
    snap = ref.get().to_dict()
    hits = [d.id for d in db.collection("orders").where(filter=fs.FieldFilter("status", "==", "paid")).stream()]
    ref.delete()
    assert snap == {"amount": 42, "status": "paid"} and tag in hits, (snap, hits)
    return "set, update, query, delete"


def logging_entries():
    ok(*call("POST", "/v2/entries:write", token=tok["app"], body={"entries": [{
        "logName": f"projects/{PROJECT}/logs/smoke", "resource": {"type": "global"},
        "severity": "ERROR", "textPayload": f"smoke {tag}"}]}))
    p = ok(*call("POST", "/v2/entries:list", token=tok["deployer"], body={
        "resourceNames": [f"projects/{PROJECT}"], "filter": f'logName="projects/{PROJECT}/logs/smoke"', "orderBy": "timestamp desc"}))
    assert any(tag in e.get("textPayload", "") for e in p.get("entries", [])), "entry not listed"
    time.sleep(2)
    objs = ok(*call("GET", f"/storage/v1/b/{o['logs_bucket']}/o?prefix=smoke", token=tok["deployer"])).get("items", [])
    assert objs, "entry written and listed, but the ERROR sink did not export it to the logs bucket"
    return f"entry listed and exported by the sink ({len(objs)} object(s))"


def monitoring():
    mtype = "custom.googleapis.com/hello_api/orders_total"
    now = datetime.datetime.now(datetime.timezone.utc)
    end = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ok(*call("POST", f"/v3/projects/{PROJECT}/timeSeries", token=tok["app"], body={"timeSeries": [{
        "metric": {"type": mtype, "labels": {"env": tag}}, "resource": {"type": "global", "labels": {"project_id": PROJECT}},
        "points": [{"interval": {"endTime": end}, "value": {"int64Value": "3"}}]}]}))
    start = (now - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    q = urllib.parse.urlencode({"filter": f'metric.type="{mtype}" AND metric.labels.env="{tag}"',
                                "interval.startTime": start, "interval.endTime": (now + datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})
    series = ok(*call("GET", f"/v3/projects/{PROJECT}/timeSeries?{q}", token=tok["deployer"])).get("timeSeries", [])
    assert series and series[0]["points"][0]["value"]["int64Value"] in ("3", 3), series
    return "custom metric point written and read back"


def firebase_auth():
    base = "/identitytoolkit.googleapis.com/v1"
    s, p = call("POST", f"{base}/accounts:signUp?key=lab", body={"email": f"weak{tag}@example.com", "password": "short", "returnSecureToken": True})
    assert s == 400 and "WEAK_PASSWORD" in json.dumps(p), (s, p)
    p = ok(*call("POST", f"{base}/accounts:signUp?key=lab", body={"email": f"user{tag}@example.com", "password": "Str0ng!Passw0rd#", "returnSecureToken": True}))
    header = json.loads(base64.urlsafe_b64decode(p["idToken"].split(".")[0] + "=="))
    call("POST", f"{base}/accounts:delete?key=lab", body={"idToken": p["idToken"]})
    if header.get("alg") in (None, "none"):
        raise KnownGap(f"weak password refused and sign-up works, but ID tokens are unsigned (alg={header.get('alg')}) (G-22)")
    return f"weak password refused, signed ID token ({header['alg']})"


def gke():
    c = ok(*call("GET", f"/v1/projects/{PROJECT}/locations/{REGION}/clusters/{o['gke_cluster']}",
                 token=tok["deployer"], headers={"Host": "container.floci-gcp:4588"}))
    assert c["status"] == "RUNNING", c["status"]
    pools = [n["name"] for n in c.get("nodePools", [])]
    ca = "/tmp/gke-ca.crt"
    with open(ca, "wb") as f:
        f.write(base64.b64decode(c["masterAuth"]["clusterCaCertificate"]))
    # the advertised endpoint (container name) is not in the k3s certificate (G-23)
    kubectl = lambda token: subprocess.run(  # noqa: E731
        ["kubectl", f"--server=https://{c['endpoint']}", f"--certificate-authority={ca}", "--tls-server-name=kubernetes",
         f"--token={token}",
         "auth", "can-i", "*", "*", "--all-namespaces"], capture_output=True, text=True)
    real, bogus = kubectl(tok["deployer"]), kubectl("not-a-google-token")
    assert real.stdout.strip() == "yes", (real.stdout + real.stderr)[:200]
    if bogus.stdout.strip() == "yes":
        raise KnownGap(f"cluster RUNNING ({pools}), but any bearer token is cluster-admin (G-24)")
    return f"cluster RUNNING ({pools}), only Google tokens accepted"


for name, fn in [
    ("gcs", gcs), ("gcs iam", gcs_iam), ("pubsub", pubsub), ("pubsub dead-letter", pubsub_dead_letter),
    ("kms", kms), ("secret manager", secret_manager), ("iam impersonation", iam_impersonation),
    ("bigquery", bigquery), ("cloud sql", cloud_sql), ("cloud run", cloud_run), ("cloud run job", cloud_run_job),
    ("scheduler", scheduler), ("firestore", firestore), ("logging", logging_entries), ("monitoring", monitoring),
    ("firebase auth", firebase_auth), ("gke", gke),
]:
    check(name, fn)

width = max(len(n) for _, n, _ in results)
for status, name, detail in results:
    print(f"  [{status}] {name:<{width}}  {detail}")
failed = sum(1 for s, _, _ in results if s == "FAIL")
gaps = sum(1 for s, _, _ in results if s == "GAP")
print(f"\n{len(results) - failed - gaps} passed, {gaps} known emulator gaps, {failed} failed")
raise SystemExit(failed)
