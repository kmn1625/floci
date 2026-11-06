#!/usr/bin/env python3
"""Copy uploads made on AWS back to the on-prem disk during a rollback. Runs on the source server."""
import os
import shutil
from pathlib import Path

import boto3

UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/var/lib/shop/uploads"))
s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"], region_name="us-east-1")
copied = 0
keys = 0
for page in s3.get_paginator("list_objects_v2").paginate(Bucket=os.environ["S3_BUCKET"]):
    for item in page.get("Contents", []):
        keys += 1
        path = UPLOAD_DIR / item["Key"]
        if not path.exists():
            s3.download_file(os.environ["S3_BUCKET"], item["Key"], str(path))
            shutil.chown(path, "www-data", "www-data")
            copied += 1
print(f"in_bucket={keys} copied_home={copied}")
