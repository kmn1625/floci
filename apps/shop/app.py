"""shop: a small monolith with the habits of an app that grew up on one server.

Orders, stock, customers and uploads share one process and one database. Migration drills use it, so
the awkward parts are on purpose: local disk for files, sequences, a table with no primary key, and
business rules that span tables. /verify reports totals that must survive a move.
"""
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
import uuid
from functools import cache
from pathlib import Path

import boto3
import psycopg
from azure.storage.blob import BlobServiceClient
from flask import Flask, Response, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, REGISTRY, CollectorRegistry, Counter, generate_latest, multiprocess
from psycopg.types.json import Jsonb

app = Flask(__name__)
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://shop:shop@127.0.0.1:5432/shop")
STORAGE = os.environ.get("STORAGE", "disk")
if STORAGE not in ("disk", "s3", "azure"):
    # Falling through to disk here is how a first run lost every upload on Azure while health stayed green.
    raise SystemExit(f"unknown STORAGE {STORAGE!r}")
# How an order takes stock. local: one transaction, as it always was. naive: a call to catalog with a retry, the
# version most first splits ship. saga: a reservation with a key, settled after the order commits.
ORDER_MODE = os.environ.get("ORDER_MODE", "local")
if ORDER_MODE not in ("local", "naive", "saga"):
    raise SystemExit(f"unknown ORDER_MODE {ORDER_MODE!r}")
CATALOG_URL = os.environ.get("CATALOG_URL", "")
FILES_URL = os.environ.get("FILES_URL", "")
UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/var/lib/shop/uploads"))
SITE = os.environ.get("SITE", "onprem")
MAX_UPLOAD = 2 * 1024 * 1024


def db():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def bucket():
    client = boto3.client("s3", endpoint_url=os.environ.get("S3_ENDPOINT") or None)
    return client, os.environ["S3_BUCKET"]


@cache
def blobs():
    # Real Azure would use a managed identity here. floci-az does not check keys, so the lab cannot test that.
    account = {"account_name": os.environ["BLOB_ACCOUNT"], "account_key": os.environ["BLOB_KEY"]}
    return BlobServiceClient(os.environ["BLOB_URL"], credential=account).get_container_client(os.environ["BLOB_CONTAINER"])


def store(key, data):
    if STORAGE == "azure":
        blobs().upload_blob(key, data, overwrite=True)
    elif STORAGE == "s3":
        client, name = bucket()
        client.put_object(Bucket=name, Key=key, Body=data)
    else:
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        (UPLOAD_DIR / key).write_bytes(data)


def fetch(key):
    if STORAGE == "azure":
        return blobs().download_blob(key).readall()
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


@app.errorhandler(psycopg.errors.InsufficientPrivilege)
def writes_moved(_):
    return jsonify(error="this table has moved or is being moved"), 503


# Metrics. Gunicorn runs two workers, so counters live in files both write (gunicorn.conf.py clears them on start).
METRICS_DIR = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
if METRICS_DIR:
    Path(METRICS_DIR).mkdir(parents=True, exist_ok=True)
REQUESTS = Counter("shop_http_requests_total", "Requests answered, by route and status", ["route", "status"])


@app.after_request
def count(response):
    REQUESTS.labels(request.url_rule.rule if request.url_rule else "unmatched", str(response.status_code)).inc()
    return response


def stock_balance():
    """Per product, stock taken that no order and no pending reservation explains. 0 everywhere while the promise holds.

    A health check cannot see this: the naive split lost 28 units with every order a success. Local mode reads one
    database in one statement; split mode asks catalog first, so an order in flight shows for a moment and settles.
    """
    if CATALOG_URL:
        status, catalog = service(f"{CATALOG_URL}/totals", attempts=1)
        if status != 200 or "pendingTaken" not in catalog:
            return None
        with db() as conn, conn.cursor() as cur:
            cur.execute("select product_id, sum(qty) from order_items group by product_id")
            sold = {str(r[0]): int(r[1]) for r in cur.fetchall()}
        pending = catalog["pendingTaken"]
        return {p: int(t) - sold.get(p, 0) - int(pending.get(p, 0)) for p, t in catalog["taken"].items()}, sum(map(int, pending.values()))
    with db() as conn, conn.cursor() as cur:
        cur.execute("select to_regclass('reservations') is not null")
        pending = """select (l->>'product_id')::int product_id, sum((l->>'qty')::int) n
                     from reservations r, jsonb_array_elements(coalesce(r.priced, '[]')) l where r.status = 'pending' group by 1"""
        if not cur.fetchone()[0]:  # a monolith that never split has nothing pending
            pending = "select null::int product_id, 0 n where false"
        cur.execute(f"""
            with sold as (select product_id, sum(qty) n from order_items group by 1), pending as ({pending})
            select p.id, p.initial_stock - p.stock - coalesce(s.n, 0) - coalesce(q.n, 0), coalesce(q.n, 0)
            from products p left join sold s on s.product_id = p.id left join pending q on q.product_id = p.id""")
        rows = cur.fetchall()
    return {str(r[0]): int(r[1]) for r in rows}, sum(int(r[2]) for r in rows)


@app.get("/metrics")
def metrics():
    registry = REGISTRY
    if METRICS_DIR:
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
    lines = [generate_latest(registry).decode()]
    try:
        balance = stock_balance()
    except psycopg.Error:
        balance = None
    # Without this series the drift alert has nothing to fire on: say so, rather than stay silent.
    lines.append("# HELP shop_reconcile_up 1 when the stock promise could be checked on this scrape\n# TYPE shop_reconcile_up gauge\n"
                 f"shop_reconcile_up {0 if balance is None else 1}\n")
    if balance is not None:
        drift, pending = balance
        # Summed as absolute values: one product up by 3 and another down by 3 is 6 units wrong, not none.
        lines.append("# HELP shop_stock_unexplained_units Stock taken that no order or pending reservation explains, per product, summed\n"
                     "# TYPE shop_stock_unexplained_units gauge\n"
                     f"shop_stock_unexplained_units {sum(abs(v) for v in drift.values())}\n"
                     "# HELP shop_products_drifting Products whose stock no order or pending reservation explains\n"
                     "# TYPE shop_products_drifting gauge\n"
                     f"shop_products_drifting {sum(1 for v in drift.values() if v)}\n"
                     "# HELP shop_reservations_pending_units Stock held by reservations not yet settled\n"
                     "# TYPE shop_reservations_pending_units gauge\n"
                     f"shop_reservations_pending_units {pending}\n")
    return Response("".join(lines), content_type=CONTENT_TYPE_LATEST)


# Retries must fit inside the caller's patience. 3 tries of 2 s outlasted the edge's 5 s: the customer got an error
# while the order carried on and committed behind them.
RETRY_BUDGET = float(os.environ.get("RETRY_BUDGET", "3"))


def service(url, body=None, attempts=3):
    """Status and JSON from another service. Failures come back as status 0: the caller decides what they mean."""
    data = None if body is None else json.dumps(body).encode()
    status, reply = 0, {}
    deadline = time.monotonic() + RETRY_BUDGET
    for attempt in range(attempts):
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:
            req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST" if data is not None or body == {} else "GET")
            with urllib.request.urlopen(req, timeout=min(1.5, left)) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as exc:
            status, reply = exc.code, {}
            if exc.code < 500:
                return status, reply
        except OSError:
            status, reply = 0, {}
    return status, reply


def order_rows(cur, customer_id, priced, key=None):
    total = sum(line["qty"] * line["price_cents"] for line in priced)
    cur.execute("insert into orders (customer_id, total_cents, order_key) values (%s, %s, %s) returning id", (customer_id, total, key))
    order_id = cur.fetchone()[0]
    cur.executemany("insert into order_items (order_id, product_id, qty, price_cents) values (%s, %s, %s, %s)",
                    [(order_id, line["product_id"], line["qty"], line["price_cents"]) for line in priced])
    cur.execute("insert into audit_log (action, detail) values ('order', %s)", (Jsonb({"order": order_id, "total": total}),))
    return order_id, total


def order_naive(body, items):
    status, reply = service(f"{CATALOG_URL}/stock/take", {"items": items})
    if status == 409:
        return jsonify(error="out of stock"), 409
    if status != 200:
        return jsonify(error="stock unavailable"), 503
    with db() as conn, conn.cursor() as cur:
        order_id, total = order_rows(cur, body["customer_id"], reply["priced"])
    return jsonify(id=order_id, total_cents=total, site=SITE), 201


def order_saga(body, items):
    key = str(uuid.uuid4())
    status, reply = service(f"{CATALOG_URL}/reservations", {"key": key, "items": items})
    if status == 409:
        return jsonify(error="out of stock"), 409
    if status not in (200, 201):
        # It may have worked: the sweeper asks whether this key became an order, finds it did not, and puts the stock back.
        return jsonify(error="stock unavailable"), 503
    try:
        with db() as conn, conn.cursor() as cur:
            order_id, total = order_rows(cur, body["customer_id"], reply["priced"], key)
    except psycopg.Error:
        service(f"{CATALOG_URL}/reservations/{key}/release", {}, attempts=1)  # the sweeper covers this failing too
        raise
    service(f"{CATALOG_URL}/reservations/{key}/confirm", {}, attempts=1)  # the order exists: never make the customer wait on this
    return jsonify(id=order_id, total_cents=total, site=SITE), 201


@app.get("/internal/orders/by-key/<uuid:key>")
def order_by_key(key):
    with db() as conn, conn.cursor() as cur:
        cur.execute("select id from orders where order_key = %s", (key,))
        row = cur.fetchone()
    return (jsonify(id=row[0]), 200) if row else (jsonify(error="no such order"), 404)


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
    if ORDER_MODE == "naive":
        return order_naive(body, items)
    if ORDER_MODE == "saga":
        return order_saga(body, items)
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
    if CATALOG_URL:
        return verify_split()
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


def verify_split():
    """The same promise, now asked of three owners. One statement used to answer it."""
    status, catalog = service(f"{CATALOG_URL}/totals", attempts=1)
    if status != 200:
        return jsonify(error="catalog unavailable"), 503
    with db() as conn, conn.cursor() as cur:
        cur.execute("""select (select count(*) from orders), (select coalesce(sum(total_cents), 0) from orders),
                              (select coalesce(sum(qty * price_cents), 0) from order_items), (select coalesce(sum(qty), 0) from order_items)""")
        orders, revenue, items, sold = cur.fetchone()
        cur.execute("select product_id, sum(qty) from order_items group by product_id")
        by_product = {str(r[0]): int(r[1]) for r in cur.fetchall()}
    uploads = None
    if FILES_URL:
        status, reply = service(f"{FILES_URL}/totals", attempts=1)
        uploads = reply.get("uploads") if status == 200 else None
    drift = {p: catalog["taken"].get(p, 0) - by_product.get(p, 0) for p in catalog["taken"] if catalog["taken"].get(p, 0) != by_product.get(p, 0)}
    return jsonify(site=SITE, orders=orders, revenue_cents=int(revenue), uploads=uploads, orders_match_items=int(revenue) == int(items),
                   stock_balanced=int(sold) + catalog["stock"] == catalog["initial"], pending=catalog["pending"],
                   stock_drift=int(catalog["initial"]) - catalog["stock"] - int(sold), products_drifting=len(drift))
