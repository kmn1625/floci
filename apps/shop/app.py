"""shop: a small monolith with the habits of an app that grew up on one server.

Orders, stock, customers and uploads share one process and one database. Migration drills use it, so
the awkward parts are on purpose: local disk for files, sequences, a table with no primary key, and
business rules that span tables. /verify reports totals that must survive a move.
"""
import hashlib
import os
import uuid
from pathlib import Path

import boto3
import psycopg
from flask import Flask, Response, jsonify, request
from psycopg.types.json import Jsonb

app = Flask(__name__)
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://shop:shop@127.0.0.1:5432/shop")
STORAGE = os.environ.get("STORAGE", "disk")
UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/var/lib/shop/uploads"))
SITE = os.environ.get("SITE", "onprem")
MAX_UPLOAD = 2 * 1024 * 1024


def db():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def bucket():
    client = boto3.client("s3", endpoint_url=os.environ.get("S3_ENDPOINT") or None)
    return client, os.environ["S3_BUCKET"]


def store(key, data):
    if STORAGE == "s3":
        client, name = bucket()
        client.put_object(Bucket=name, Key=key, Body=data)
    else:
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        (UPLOAD_DIR / key).write_bytes(data)


def fetch(key):
    if STORAGE == "s3":
        client, name = bucket()
        return client.get_object(Bucket=name, Key=key)["Body"].read()
    return (UPLOAD_DIR / key).read_bytes()


@app.errorhandler(psycopg.errors.ReadOnlySqlTransaction)
def read_only(_):
    return jsonify(error="read only"), 503


@app.errorhandler(psycopg.OperationalError)
def database_down(_):
    return jsonify(error="database unavailable"), 503


@app.get("/health")
def health():
    return jsonify(status="ok", site=SITE)


@app.get("/ready")
def ready():
    with db() as conn:
        conn.execute("select 1")
    return jsonify(status="ready", site=SITE)


@app.post("/orders")
def create_order():
    body = request.get_json(force=True)
    items = body.get("items") or []
    if not items:
        return jsonify(error="no items"), 400
    with db() as conn, conn.cursor() as cur:
        total = 0
        priced = []
        for item in items:
            cur.execute("update products set stock = stock - %s where id = %s and stock >= %s returning price_cents",
                        (item["qty"], item["product_id"], item["qty"]))
            row = cur.fetchone()
            if row is None:
                conn.rollback()
                return jsonify(error="out of stock", product_id=item["product_id"]), 409
            priced.append((item["product_id"], item["qty"], row[0]))
            total += item["qty"] * row[0]
        cur.execute("insert into orders (customer_id, total_cents) values (%s, %s) returning id", (body["customer_id"], total))
        order_id = cur.fetchone()[0]
        cur.executemany("insert into order_items (order_id, product_id, qty, price_cents) values (%s, %s, %s, %s)",
                        [(order_id, *p) for p in priced])
        cur.execute("insert into audit_log (action, detail) values ('order', %s)", (Jsonb({"order": order_id, "total": total}),))
    return jsonify(id=order_id, total_cents=total, site=SITE), 201


@app.get("/orders/<int:order_id>")
def get_order(order_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("select id, customer_id, total_cents, status from orders where id = %s", (order_id,))
        row = cur.fetchone()
    if row is None:
        return jsonify(error="not found"), 404
    return jsonify(id=row[0], customer_id=row[1], total_cents=row[2], status=row[3])


@app.post("/uploads")
def create_upload():
    data = request.get_data()
    if not data or len(data) > MAX_UPLOAD:
        return jsonify(error="empty or too large"), 400
    upload_id = str(uuid.uuid4())
    digest = hashlib.sha256(data).hexdigest()
    store(upload_id, data)
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
    data = fetch(str(upload_id))
    if hashlib.sha256(data).hexdigest() != row[0]:
        return jsonify(error="checksum mismatch"), 500
    return Response(data, mimetype="application/octet-stream")


@app.get("/verify")
def verify():
    """Business totals. The stock rule holds only if no write was lost or applied twice."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("""
            select (select count(*) from orders),
                   (select coalesce(sum(total_cents), 0) from orders),
                   (select coalesce(sum(qty * price_cents), 0) from order_items),
                   (select coalesce(sum(qty), 0) from order_items),
                   (select coalesce(sum(stock), 0) from products),
                   (select coalesce(sum(initial_stock), 0) from products),
                   (select count(*) from uploads)
        """)
        orders, revenue, items, sold, stock, initial, uploads = cur.fetchone()
    return jsonify(site=SITE, orders=orders, revenue_cents=int(revenue), uploads=uploads,
                   orders_match_items=int(revenue) == int(items), stock_balanced=int(sold) + int(stock) == int(initial))
