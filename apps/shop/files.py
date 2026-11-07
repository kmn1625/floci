"""files: owns uploads, split out of the shop monolith.

The easy seam: no key to another table, no shared transaction. The objects stay in the same bucket, so only
the table moves. READ_ONLY keeps it from writing until the moment the traffic moves.
"""
import hashlib
import os
import uuid

import boto3
import psycopg
from flask import Flask, Response, jsonify, request

app = Flask(__name__)
DATABASE_URL = os.environ["DATABASE_URL"]
BUCKET = os.environ["S3_BUCKET"]
MAX_UPLOAD = 2 * 1024 * 1024
s3 = boto3.client("s3", endpoint_url=os.environ.get("S3_ENDPOINT") or None)


def db():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


@app.errorhandler(psycopg.errors.ReadOnlySqlTransaction)
def read_only(_):
    return jsonify(error="read only"), 503


@app.errorhandler(psycopg.OperationalError)
def database_down(_):
    return jsonify(error="database unavailable"), 503


@app.get("/health")
def health():
    return jsonify(status="ok", service="files")


@app.get("/ready")
def ready():
    with db() as conn:
        conn.execute("select 1")
    return jsonify(status="ready", service="files")


@app.post("/uploads")
def create_upload():
    data = request.get_data()
    if not data or len(data) > MAX_UPLOAD:
        return jsonify(error="empty or too large"), 400
    upload_id, digest = str(uuid.uuid4()), hashlib.sha256(data).hexdigest()
    s3.put_object(Bucket=BUCKET, Key=upload_id, Body=data)
    with db() as conn:
        conn.execute("insert into uploads (id, name, size, sha256) values (%s, %s, %s, %s)",
                     (upload_id, request.args.get("name", "file"), len(data), digest))
    return jsonify(id=upload_id, sha256=digest), 201


@app.get("/uploads/<uuid:upload_id>")
def get_upload(upload_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("select sha256 from uploads where id = %s", (upload_id,))
        row = cur.fetchone()
    if row is None:
        return jsonify(error="not found"), 404
    data = s3.get_object(Bucket=BUCKET, Key=str(upload_id))["Body"].read()
    if hashlib.sha256(data).hexdigest() != row[0]:
        return jsonify(error="checksum mismatch"), 500
    return Response(data, mimetype="application/octet-stream")


@app.get("/totals")
def totals():
    with db() as conn:
        return jsonify(uploads=conn.execute("select count(*) from uploads").fetchone()[0])
