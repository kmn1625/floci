#!/usr/bin/env python3
"""Data-plane smoke tests for the AWS lab. Run in the toolbox (CLOUD=aws):

    docker compose --profile tools run --rm toolbox sh -c "pip install -q boto3 && python3 tests/smoke.py"

Reads names from `terraform output -json` and uses each service the way an app would:
S3 (KMS), DynamoDB, SQS, SNS -> SQS fan-out, KMS, Secrets Manager, SSM SecureString,
Kinesis, Step Functions -> DynamoDB, HTTP API -> Lambda -> DynamoDB, RDS PostgreSQL,
ElastiCache (IAM auth, TLS), Cognito sign-up,
EKS/EC2 state, and IAM policy enforcement (deny, then allow after a grant).
Known emulator gaps report as GAP (see FINDINGS.md); exit code = number of FAILs.
"""

import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request
import uuid

import boto3
import botocore
import botocore.auth
import botocore.awsrequest

results = []


class KnownGap(Exception):
    """Behaviour already recorded in FINDINGS.md."""


def check(name, fn):
    try:
        results.append(("PASS", name, fn() or ""))
    except KnownGap as e:
        results.append(("GAP", name, str(e)))
    except Exception as e:  # noqa: BLE001 — a smoke test reports every failure
        results.append(("FAIL", name, f"{type(e).__name__}: {e}"[:260]))


out = json.loads(subprocess.run(["terraform", "-chdir=terraform", "output", "-json"],
                                capture_output=True, text=True, check=True).stdout)
o = {k: v["value"] for k, v in out.items() if not v["sensitive"]}
aws = boto3.session.Session()
tag = uuid.uuid4().hex[:8]


def s3_roundtrip():
    s3 = aws.client("s3")
    key = f"smoke/{tag}.txt"
    s3.put_object(Bucket=o["bucket"], Key=key, Body=b"floci-lab")
    head = s3.head_object(Bucket=o["bucket"], Key=key)
    body = s3.get_object(Bucket=o["bucket"], Key=key)["Body"].read()
    s3.delete_object(Bucket=o["bucket"], Key=key)
    assert body == b"floci-lab"
    sse = head.get("ServerSideEncryption")
    if sse != "aws:kms":
        raise KnownGap(f"object stored, but default bucket encryption not applied (SSE={sse}) (A-08)")
    return "put/get/delete, SSE aws:kms"


def dynamodb_roundtrip():
    t = aws.resource("dynamodb").Table(o["orders_table"])
    t.put_item(Item={"customerId": f"c-{tag}", "orderId": "1", "total": 42})
    item = t.get_item(Key={"customerId": f"c-{tag}", "orderId": "1"})["Item"]
    assert int(item["total"]) == 42
    return "put/get"


def sqs_roundtrip():
    sqs = aws.client("sqs")
    sqs.send_message(QueueUrl=o["jobs_queue_url"], MessageBody=f"direct-{tag}")
    return f"send/receive ({wait_for(f'direct-{tag}')})"


def wait_for(text, seconds=20):
    sqs = aws.client("sqs")
    deadline = time.time() + seconds
    while time.time() < deadline:
        msgs = sqs.receive_message(QueueUrl=o["jobs_queue_url"], MaxNumberOfMessages=10, WaitTimeSeconds=2).get("Messages", [])
        for m in msgs:
            sqs.delete_message(QueueUrl=o["jobs_queue_url"], ReceiptHandle=m["ReceiptHandle"])
            if text in m["Body"]:
                return "received"
    raise AssertionError(f"'{text}' not delivered within {seconds}s")


def sns_fanout():
    aws.client("sns").publish(TopicArn=o["events_topic_arn"], Message=f"fanout-{tag}")
    return f"publish -> SQS {wait_for(f'fanout-{tag}')}"


def kms_roundtrip():
    kms = aws.client("kms")
    blob = kms.encrypt(KeyId="alias/flocilab", Plaintext=b"secret")["CiphertextBlob"]
    assert kms.decrypt(CiphertextBlob=blob)["Plaintext"] == b"secret"
    return "encrypt/decrypt via alias"


def secrets_and_params():
    s = json.loads(aws.client("secretsmanager").get_secret_value(SecretId=o["db_secret_arn"])["SecretString"])
    p = aws.client("ssm").get_parameter(Name="/flocilab/app/feature-x", WithDecryption=True)["Parameter"]
    assert len(s["password"]) == 24 and p["Value"] == "enabled" and p["Type"] == "SecureString"
    return "secret read (value not printed); SecureString decrypted"


def kinesis_roundtrip():
    k = aws.client("kinesis")
    k.put_record(StreamName="flocilab-clicks", Data=f"click-{tag}".encode(), PartitionKey="p")
    shard = k.list_shards(StreamName="flocilab-clicks")["Shards"][0]["ShardId"]
    it = k.get_shard_iterator(StreamName="flocilab-clicks", ShardId=shard, ShardIteratorType="TRIM_HORIZON")["ShardIterator"]
    data = [r["Data"] for r in k.get_records(ShardIterator=it, Limit=1000)["Records"]]
    assert f"click-{tag}".encode() in data
    return "put/get record"


def step_functions():
    sfn = aws.client("stepfunctions")
    name = f"smoke-{tag}"
    sfn.start_execution(stateMachineArn=o["state_machine_arn"], name=name, input=json.dumps({"customerId": f"sfn-{tag}"}))
    arn = o["state_machine_arn"].replace(":stateMachine:", ":execution:") + f":{name}"
    for _ in range(30):
        st = sfn.describe_execution(executionArn=arn)["status"]
        if st != "RUNNING":
            break
        time.sleep(1)
    assert st == "SUCCEEDED", st
    item = aws.resource("dynamodb").Table(o["orders_table"]).get_item(Key={"customerId": f"sfn-{tag}", "orderId": name}).get("Item")
    assert item, "state machine did not write the order"
    return "Choice -> dynamodb:putItem, item stored"


def http_api_lambda():
    # api_endpoint is https://<id>.execute-api.<region>.amazonaws.com, which the egress guard sinks
    # (A-10); Floci also serves every API under /_aws/execute-api/<id>/<stage>/ on its own port.
    api_id = o["api_endpoint"].split("//")[1].split(".")[0]
    url = f"{os.environ['AWS_ENDPOINT_URL']}/_aws/execute-api/{api_id}/$default/orders"
    req = urllib.request.Request(url, data=b"{}", method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:  # first call pulls the Lambda runtime image
        status, order = r.status, json.loads(r.read())
    item = aws.resource("dynamodb").Table(o["orders_table"]).get_item(Key=order).get("Item")
    assert status == 201 and item, (status, order)
    return f"POST /orders -> 201, Lambda wrote {order['customerId']} to DynamoDB"


def rds_postgres():
    db = aws.client("rds").describe_db_instances(DBInstanceIdentifier="flocilab-pg")["DBInstances"][0]
    pw = json.loads(aws.client("secretsmanager").get_secret_value(SecretId=o["db_secret_arn"])["SecretString"])["password"]
    host, port = db["Endpoint"]["Address"], str(db["Endpoint"]["Port"])
    # Floci reports an IP, not a DNS name (A-11), and after a restart it is the IP on the VPC
    # network, which a client outside the VPC cannot reach (A-20). Real RDS endpoints are DNS
    # names that resolve per network, so connect the same way: Floci's name, the reported port.
    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", host):
        host = urllib.parse.urlparse(os.environ.get("AWS_ENDPOINT_URL", "http://floci-lab:4566")).hostname
    r = subprocess.run(["psql", "-h", host, "-p", port, "-U", "labadmin", "-d", "app", "-tAc", "show server_version"],
                       capture_output=True, text=True, env={**os.environ, "PGPASSWORD": pw, "PGCONNECT_TIMEOUT": "10"})
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-200:])
    version = r.stdout.strip()
    if not version.startswith("16"):
        raise KnownGap(f"server {version}, requested 16")
    return f"{host}:{port} db app, server {version}"


def iam_auth_token(user, group):
    """ElastiCache IAM auth token: a SigV4-presigned `connect` request (what redis IAM clients send)."""
    q = urllib.parse.urlencode({"Action": "connect", "User": user})
    req = botocore.awsrequest.AWSRequest(method="GET", url=f"http://{group}/?{q}")
    botocore.auth.SigV4QueryAuth(aws.get_credentials().get_frozen_credentials(), "elasticache",
                                 aws.region_name, expires=900).add_auth(req)
    return req.url.removeprefix("http://")


def elasticache_tls():
    g = aws.client("elasticache").describe_replication_groups(ReplicationGroupId="flocilab-cache")["ReplicationGroups"][0]
    ep = g["NodeGroups"][0]["PrimaryEndpoint"]
    host, port = ep["Address"], str(ep["Port"])

    def ping(*extra, password=None):
        auth = ["--user", "default", "--pass", password, "--no-auth-warning"] if password else []
        r = subprocess.run(["redis-cli", "-h", host, "-p", port, *extra, *auth, "PING"], capture_output=True, text=True, timeout=15)
        return (r.stdout + r.stderr).strip()

    anonymous = ping()
    if "NOAUTH" not in anonymous:
        raise AssertionError(f"anonymous client was not challenged: {anonymous[:80]}")
    token = iam_auth_token("default", "flocilab-cache")
    if ping("--tls", "--insecure", password=token) == "PONG":
        return f"{host}:{port} anonymous -> NOAUTH; IAM token -> PONG over TLS"
    if ping(password=token) == "PONG":
        raise KnownGap(f"{host}:{port} IAM auth enforced (anonymous NOAUTH, token PONG), but plaintext only "
                       "although transit_encryption_enabled=true (A-09)")
    raise RuntimeError(f"IAM token rejected: {ping(password=token)[:80]}")


def cognito_signup():
    idp = aws.client("cognito-idp")
    pool = next(p for p in idp.list_user_pools(MaxResults=20)["UserPools"] if p["Name"] == "flocilab-users")
    client = idp.list_user_pool_clients(UserPoolId=pool["Id"])["UserPoolClients"][0]["ClientId"]
    try:
        idp.sign_up(ClientId=client, Username=f"weak{tag}@example.com", Password="short",
                    UserAttributes=[{"Name": "email", "Value": f"weak{tag}@example.com"}])
        weak = "ACCEPTED (policy not enforced)"
    except botocore.exceptions.ClientError as e:
        weak = f"rejected ({e.response['Error']['Code']})"
    idp.sign_up(ClientId=client, Username=f"user{tag}@example.com", Password="Str0ng!Passw0rd#",
                UserAttributes=[{"Name": "email", "Value": f"user{tag}@example.com"}])
    if weak.startswith("ACCEPTED"):
        raise KnownGap(f"strong password signed up; weak password 'short' {weak}")
    return f"strong password signed up; weak password {weak}"


def iam_enforcement():
    iam = aws.client("iam")
    user = f"smoke-{tag}"
    iam.create_user(UserName=user)
    key = iam.create_access_key(UserName=user)["AccessKey"]
    try:
        s3 = boto3.client("s3", aws_access_key_id=key["AccessKeyId"], aws_secret_access_key=key["SecretAccessKey"])
        try:
            s3.list_buckets()
            denied = False
        except botocore.exceptions.ClientError as e:
            denied = e.response["Error"]["Code"] in ("AccessDenied", "AccessDeniedException")
        iam.put_user_policy(UserName=user, PolicyName="list", PolicyDocument=json.dumps(
            {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "s3:ListAllMyBuckets", "Resource": "*"}]}))
        time.sleep(1)
        allowed = any(b["Name"] == o["bucket"] for b in s3.list_buckets()["Buckets"])
    finally:
        try:
            iam.delete_user_policy(UserName=user, PolicyName="list")
        except iam.exceptions.NoSuchEntityException:
            pass
        iam.delete_access_key(UserName=user, AccessKeyId=key["AccessKeyId"])
        iam.delete_user(UserName=user)
    assert denied, "a user with no policy could list buckets"
    assert allowed, "granting s3:ListAllMyBuckets did not allow the call"
    return "no policy -> AccessDenied; after grant -> allowed (user removed)"


def compute_state():
    eks = aws.client("eks").describe_cluster(name=o["eks_cluster"])["cluster"]["status"]
    ec2 = [i["State"]["Name"] for r in aws.client("ec2").describe_instances(
        Filters=[{"Name": "tag:Name", "Values": ["flocilab-app"]}])["Reservations"] for i in r["Instances"]]
    assert eks == "ACTIVE" and "running" in ec2, (eks, ec2)
    return f"EKS {eks}, EC2 {ec2}"


for name, fn in [
    ("s3", s3_roundtrip), ("dynamodb", dynamodb_roundtrip), ("sqs", sqs_roundtrip), ("sns -> sqs", sns_fanout),
    ("kms", kms_roundtrip), ("secrets + ssm", secrets_and_params), ("kinesis", kinesis_roundtrip),
    ("step functions", step_functions), ("http api -> lambda", http_api_lambda), ("rds postgres", rds_postgres), ("elasticache", elasticache_tls),
    ("cognito", cognito_signup), ("iam enforcement", iam_enforcement), ("eks + ec2", compute_state),
]:
    check(name, fn)

width = max(len(n) for _, n, _ in results)
for status, name, detail in results:
    print(f"  [{status}] {name:<{width}}  {detail}")
failed = sum(1 for s, _, _ in results if s == "FAIL")
gaps = sum(1 for s, _, _ in results if s == "GAP")
print(f"\n{len(results) - failed - gaps} passed, {gaps} known emulator gaps, {failed} failed")
raise SystemExit(failed)
