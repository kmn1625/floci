#!/usr/bin/env python3
"""Pull uploads from the source server into S3, repeatably. Runs in a container, using the shop image.

A pull, like a DataSync agent: nothing is opened from the old server towards the cloud, which is often
the only direction a firewall allows. The source serves the folder on a port limited to this client
for the length of the migration (see source-share.sh).

Each run copies only what the bucket lacks, so it can run before cutover and once more during it.
With --verify every object is read back and hashed against the checksum in the database, because a
count of objects says nothing about whether the bytes survived. --verify-new hashes only what this run
copied, for use during the freeze. Files with no database row are strays from failed uploads: the app
writes the file first, so the database decides what counts.

While customers are still uploading, a row can appear after the file listing was taken, so a file
missing from the bucket only counts once writes have stopped: pass --frozen then.

  SOURCE_URL=http://10.77.0.20:8099 S3_ENDPOINT=http://floci-lab:4566 S3_BUCKET=shop-uploads \\
      DATABASE_URL=postgresql://... python sync-uploads.py [--verify | --verify-new] [--frozen]
"""
import hashlib
import json
import os
import sys
import time
import urllib.request

import boto3
import psycopg

SOURCE = os.environ["SOURCE_URL"].rstrip("/")
BUCKET = os.environ["S3_BUCKET"]


def get(url, attempts=5):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                return r.read()
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(attempt + 1)


def main():
    s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"], region_name="us-east-1")
    present = set()
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
        present.update(o["Key"] for o in page.get("Contents", []))
    names = [e["name"] for e in json.loads(get(f"{SOURCE}/")) if e["type"] == "file"]
    missing = [n for n in names if n not in present]
    for name in missing:
        s3.put_object(Bucket=BUCKET, Key=name, Body=get(f"{SOURCE}/{name}"))
    summary = {"on_source": len(names), "copied": len(missing), "in_bucket": len(present | set(missing))}
    full, new_only = "--verify" in sys.argv, "--verify-new" in sys.argv
    if not full and not new_only:
        print(json.dumps(summary))
        return 0
    with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=5) as conn:
        expected = {str(k): v for k, v in conn.execute("select id, sha256 from uploads").fetchall()}
    absent = [k for k in expected if k not in present | set(missing)]
    wrong = []
    check = set(expected) if full else set(expected) & set(missing)
    for key, digest in expected.items():
        if key in check and key not in absent:
            body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
            if hashlib.sha256(body).hexdigest() != digest:
                wrong.append(key)
    summary.update(in_database=len(expected), not_in_bucket=len(absent), hashed=len(check), checksum_mismatch=len(wrong))
    print(json.dumps(summary))
    return 1 if wrong or (absent and "--frozen" in sys.argv) else 0


if __name__ == "__main__":
    sys.exit(main())
