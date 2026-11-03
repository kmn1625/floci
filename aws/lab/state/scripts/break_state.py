#!/usr/bin/env python3
"""Break the state-lab's remote state on purpose, for the recovery drills (README.md).

    python state/scripts/break_state.py corrupt | delete | rollback | versions

Emulator only: refuses any endpoint that is not Floci on this machine.
"""
import os
import sys

import boto3

ENDPOINT = os.environ.get("FLOCI_ENDPOINT", "http://localhost:4566")
if not ENDPOINT.startswith(("http://localhost", "http://127.0.0.1", "http://floci-lab")):
    sys.exit(f"refusing {ENDPOINT}: drills run against the local emulator only")
kw = {"endpoint_url": ENDPOINT, "region_name": "us-east-1",
      "aws_access_key_id": "floci", "aws_secret_access_key": "floci"}
s3 = boto3.client("s3", **kw)
BUCKET, KEY = "flocilab-tfstate", "state-lab/terraform.tfstate"

op = sys.argv[1] if len(sys.argv) > 1 else "versions"
versions = [v for v in s3.list_object_versions(Bucket=BUCKET, Prefix=KEY).get("Versions", []) if v["Key"] == KEY]
versions.sort(key=lambda v: v["LastModified"], reverse=True)
if op == "corrupt":      # a half-written or hand-edited state
    body = s3.get_object(Bucket=BUCKET, Key=KEY)["Body"].read()
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=body[: len(body) // 2])
elif op == "delete":     # leaves a delete marker; versioning keeps the history
    s3.delete_object(Bucket=BUCKET, Key=KEY)
elif op == "rollback":   # an older version copied on top, as a careless restore would
    old = versions[-1]["VersionId"]
    s3.copy_object(Bucket=BUCKET, Key=KEY, CopySource={"Bucket": BUCKET, "Key": KEY, "VersionId": old})
    print("copied", old, "on top")
for v in versions[:5]:
    print(v["VersionId"], v["LastModified"], v["Size"])
