#!/usr/bin/env python3
"""Copy uploads between S3 and Azure Blob, repeatably, and prove the bytes survived.

    python sync-files.py s3-to-blob | blob-to-s3 [--verify | --verify-new] [--frozen] [--out FILE]

The database decides what counts, as in the on-prem drill: failed uploads leave strays. Only the bytes can
prove a copy here. An S3 ETag is an MD5 for simple uploads and a Blob ETag is an opaque id, so comparing them
across clouds means nothing. Each object is hashed as it is read from the source, and refused if it does
not match the database. --verify reads every object back from the target, --verify-new only this run's.
Before the freeze a row can appear before its object does, so a missing object fails only with --frozen.
"""
import hashlib
import json
import os
import sys

import boto3
import psycopg
from azure.core.exceptions import ResourceNotFoundError
from azure.storage.blob import BlobServiceClient

BUCKET = os.environ["S3_BUCKET"]


class S3:
    def __init__(self):
        self.client = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"])

    def keys(self):
        pages = self.client.get_paginator("list_objects_v2").paginate(Bucket=BUCKET)
        return {o["Key"] for page in pages for o in page.get("Contents", [])}

    def read(self, key):
        try:
            return self.client.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        except self.client.exceptions.NoSuchKey:
            return None

    def write(self, key, data):
        self.client.put_object(Bucket=BUCKET, Key=key, Body=data)


class Blob:
    def __init__(self):
        account = {"account_name": os.environ["BLOB_ACCOUNT"], "account_key": os.environ["BLOB_KEY"]}
        service = BlobServiceClient(os.environ["BLOB_URL"], credential=account)
        self.client = service.get_container_client(os.environ["BLOB_CONTAINER"])

    def keys(self):
        return {b.name for b in self.client.list_blobs()}

    def read(self, key):
        try:
            return self.client.download_blob(key).readall()
        except ResourceNotFoundError:
            return None

    def write(self, key, data):
        self.client.upload_blob(key, data, overwrite=True)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    source, target = (S3(), Blob()) if sys.argv[1] == "s3-to-blob" else (Blob(), S3())
    with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=5) as conn:
        expected = {str(k): v for k, v in conn.execute("select id, sha256 from uploads").fetchall()}
    present = target.keys()
    copied, source_wrong = [], []
    for key in sorted(set(expected) - present):
        data = source.read(key)
        if data is None:
            continue  # counted as absent below
        if sha(data) != expected[key]:
            source_wrong.append(key)
        else:
            target.write(key, data)
            copied.append(key)
    check = set(expected) if "--verify" in sys.argv else set(copied) if "--verify-new" in sys.argv else set()
    wrong = [key for key in sorted(check) if (data := target.read(key)) is None or sha(data) != expected[key]]
    absent = [key for key in expected if key not in present | set(copied)]
    summary = {"inDatabase": len(expected), "copied": len(copied), "notInBucket": len(absent), "hashed": len(check),
               "checksumMismatch": len(wrong) + len(source_wrong)}
    print(json.dumps(summary))
    if "--out" in sys.argv:
        with open(sys.argv[sys.argv.index("--out") + 1], "w", encoding="utf-8") as f:
            json.dump(summary, f)
    return 1 if wrong or source_wrong or (absent and "--frozen" in sys.argv) else 0


if __name__ == "__main__":
    sys.exit(main())
