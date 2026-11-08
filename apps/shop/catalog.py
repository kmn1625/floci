"""catalog: owns products and stock, split out of the shop monolith.

Taking stock used to be one statement in the same transaction as the order, so the database kept the promise
that sold + stock = initial. Across a service boundary nobody keeps it for free. This service keeps it with
reservations: a key the caller chose makes a retry safe, and a reservation is pending until the owner of the
order says what happened.

/stock/take is the naive version, kept so the drill can show what it does under failure.
"""
import json
import os
import random
import time
import urllib.error
import urllib.request

import psycopg
from flask import Flask, jsonify, request
from psycopg.types.json import Jsonb

app = Flask(__name__)
DATABASE_URL = os.environ["DATABASE_URL"]
ORDERS_URL = os.environ.get("ORDERS_URL", "")
# The share of successful writes whose answer never reaches the caller: a timeout, a dropped connection, a restart.
LOST_ANSWER = float(os.environ.get("FAULT_LOST_ANSWER", "0"))


def db():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def answer(body, status):
    if random.random() < LOST_ANSWER:
        return jsonify(error="the answer was lost after the write committed"), 502
    return jsonify(body), status


@app.errorhandler(psycopg.errors.ReadOnlySqlTransaction)
def read_only(_):
    return jsonify(error="read only"), 503


@app.errorhandler(psycopg.OperationalError)
def database_down(_):
    return jsonify(error="database unavailable"), 503


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/ready")
def ready():
    with db() as conn:
        conn.execute("select 1")
    return jsonify(status="ready")


def take(cur, items):
    """Stock for each line, or None if any line cannot be met. The caller rolls back."""
    priced = []
    for item in items:
        cur.execute("update products set stock = stock - %s where id = %s and stock >= %s returning price_cents",
                    (item["qty"], item["product_id"], item["qty"]))
        row = cur.fetchone()
        if row is None:
            return None
        priced.append({"product_id": item["product_id"], "qty": item["qty"], "price_cents": row[0]})
    return priced


@app.post("/stock/take")
def naive_take():
    """No key: the caller cannot tell a lost answer from a failed write, so a retry takes the stock twice."""
    with db() as conn, conn.cursor() as cur:
        priced = take(cur, request.get_json(force=True)["items"])
        if priced is None:
            conn.rollback()
            return jsonify(error="out of stock"), 409
    return answer({"priced": priced}, 200)


@app.post("/reservations")
def reserve():
    body = request.get_json(force=True)
    with db() as conn, conn.cursor() as cur:
        cur.execute("insert into reservations (key, status) values (%s, 'pending') on conflict (key) do nothing returning key", (body["key"],))
        if cur.fetchone() is None:  # a retry: the first attempt's answer stands
            cur.execute("select priced, status from reservations where key = %s", (body["key"],))
            priced, status = cur.fetchone()
            return (jsonify(error="out of stock"), 409) if status == "refused" else (answer({"priced": priced, "status": status}, 200))
        priced = take(cur, body["items"])
        if priced is None:
            conn.rollback()
            cur.execute("insert into reservations (key, status) values (%s, 'refused') on conflict (key) do nothing", (body["key"],))
            conn.commit()
            return jsonify(error="out of stock"), 409
        cur.execute("update reservations set priced = %s where key = %s", (Jsonb(priced), body["key"]))
    return answer({"priced": priced, "status": "pending"}, 201)


def settle(conn, key, outcome):
    """Pending to confirmed, or pending to released with the stock put back. Doing it twice changes nothing."""
    with conn.cursor() as cur:
        cur.execute("update reservations set status = %s where key = %s and status = 'pending' returning priced", (outcome, key))
        row = cur.fetchone()
        if row is not None and outcome == "released":
            for line in row[0]:
                cur.execute("update products set stock = stock + %s where id = %s", (line["qty"], line["product_id"]))
    return row is not None


@app.post("/reservations/<uuid:key>/confirm")
def confirm(key):
    with db() as conn:
        settle(conn, key, "confirmed")
    return answer({"status": "confirmed"}, 200)


@app.post("/reservations/<uuid:key>/release")
def release(key):
    with db() as conn:
        settle(conn, key, "released")
    return answer({"status": "released"}, 200)


def order_exists(key):
    """True, False, or None when the owner of orders cannot say. None settles nothing: guessing is how stock gets lost."""
    try:
        with urllib.request.urlopen(f"{ORDERS_URL}/internal/orders/by-key/{key}", timeout=3):
            return True
    except urllib.error.HTTPError as exc:
        return False if exc.code == 404 else None
    except OSError:
        return None


@app.post("/sweep")
def sweep():
    """Settle what a crash left pending. `older` must exceed the longest order request, or a live order looks abandoned."""
    older = int(request.args.get("older", 30))
    with db() as conn:
        keys = [r[0] for r in conn.execute("select key from reservations where status = 'pending' and created_at < now() - %s * interval '1 second'", (older,)).fetchall()]
    done = {"confirmed": 0, "released": 0, "unknown": 0}
    for key in keys:
        exists = order_exists(key)
        if exists is None:
            done["unknown"] += 1
            continue
        outcome = "confirmed" if exists else "released"
        with db() as conn:
            settle(conn, key, outcome)
        done[outcome] += 1
    return jsonify(done)


@app.get("/totals")
def totals():
    with db() as conn, conn.cursor() as cur:
        cur.execute("""select (select coalesce(sum(stock), 0) from products), (select coalesce(sum(initial_stock), 0) from products),
                              (select count(*) from reservations where status = 'pending')""")
        stock, initial, pending = cur.fetchone()
        cur.execute("select id, initial_stock - stock from products")
        taken = {str(r[0]): r[1] for r in cur.fetchall()}
        # What pending reservations hold, per product: taken but not yet an order or released. The shop's drift metric
        # subtracts it, or every order in flight would read as drift.
        cur.execute("""select l->>'product_id', sum((l->>'qty')::int) from reservations r, jsonb_array_elements(coalesce(r.priced, '[]')) l
                       where r.status = 'pending' group by 1""")
        pending_taken = {r[0]: int(r[1]) for r in cur.fetchall()}
    return jsonify(stock=int(stock), initial=int(initial), pending=pending, taken=taken, pendingTaken=pending_taken)


if __name__ == "__main__":
    while True:  # the sweeper is this file with no web server
        try:
            url = os.environ["CATALOG_URL"] + "/sweep?older=" + os.environ.get("SWEEP_OLDER", "30")
            with urllib.request.urlopen(urllib.request.Request(url, method="POST"), timeout=30) as r:
                result = json.loads(r.read())
            if any(result.values()):
                print(result, flush=True)
        except OSError as exc:
            print(f"sweep failed: {exc}", flush=True)
        time.sleep(10)
