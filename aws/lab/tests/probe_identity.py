"""Which credentials does Floci accept? (IAM enforcement + signature validation on.)"""
import boto3
import botocore

CANDIDATES = [("floci", "floci"), ("floci", "test"), ("fake-agent-key-001", "test"), ("test", "test")]

for key, secret in CANDIDATES:
    try:
        r = boto3.client("sts", aws_access_key_id=key, aws_secret_access_key=secret).get_caller_identity()
        print(f"{key:20} {secret:8} OK    account={r['Account']} arn={r['Arn']}")
    except botocore.exceptions.ClientError as e:
        err = e.response["Error"]
        print(f"{key:20} {secret:8} DENY  {err['Code']}: {err['Message'][:80]}")
    except Exception as e:  # noqa: BLE001 — probe reports everything
        print(f"{key:20} {secret:8} ERR   {type(e).__name__}: {str(e)[:100]}")
