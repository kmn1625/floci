#!/usr/bin/env python3
"""Customers who keep shopping through a migration.

`run` places orders and uploads files through the edge and records every answer. `check` then asks the
edge for each order and file the app acknowledged. That is the test that matters: a migration can look
perfect and still have lost a write the customer was told had succeeded.

  python load.py run --url http://localhost:18080 --seconds 600 --rate 5 --out run.jsonl
  python load.py check --url http://localhost:18080 --log run.jsonl
"""
import argparse
import hashlib
import json
import os
import random
import threading
import time
import urllib.error
import urllib.request


def call(url, data=None, headers=None, timeout=5):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # a dropped connection is a result, not a crash
        return 0, str(e).encode()


def fetch(url, tries=6):
    """The check must not report a network blip as lost data: only a real answer counts."""
    status, raw = 0, b""
    for attempt in range(tries):
        status, raw = call(url, timeout=10)
        if status in (200, 404):
            return status, raw, attempt
        time.sleep(0.5 * (attempt + 1))
    return status, raw, tries


def run(args):
    stop = time.time() + args.seconds

    def running():
        return time.time() < stop and not (args.stop_file and os.path.exists(args.stop_file))

    lock = threading.Lock()
    log = open(args.out, "a", encoding="utf-8", buffering=1)

    def write(entry):
        with lock:
            log.write(json.dumps(entry) + "\n")

    def order():
        items = [{"product_id": random.randint(1, 50), "qty": random.randint(1, 3)} for _ in range(random.randint(1, 3))]
        body = json.dumps({"customer_id": random.randint(1, 200), "items": items}).encode()
        t0 = time.time()
        status, raw = call(f"{args.url}/orders", body, {"content-type": "application/json"})
        entry = {"t": round(t0, 3), "kind": "order", "status": status, "ms": round((time.time() - t0) * 1000)}
        if status == 201:
            entry.update(json.loads(raw))
        write(entry)

    def upload():
        data = os.urandom(random.randint(2000, 20000))
        t0 = time.time()
        status, raw = call(f"{args.url}/uploads?name=load.bin", data, {"content-type": "application/octet-stream"})
        entry = {"t": round(t0, 3), "kind": "upload", "status": status, "ms": round((time.time() - t0) * 1000)}
        if status == 201:
            entry.update(json.loads(raw))
            entry["expect"] = hashlib.sha256(data).hexdigest()
        write(entry)
        if status == 201 and args.read_back:
            # A customer opens what they just uploaded. Reads from a replica can miss it.
            t1 = time.time()
            got, _ = call(f"{args.url}/uploads/{entry['id']}")
            write({"t": round(t1, 3), "kind": "readback", "status": got, "ms": round((time.time() - t1) * 1000)})

    def worker():
        while running():
            (upload if random.random() < args.uploads else order)()
            time.sleep(args.workers / args.rate)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(args.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log.close()


def check(args):
    rows = [json.loads(line) for line in open(args.log, encoding="utf-8")]
    backs = [r for r in rows if r["kind"] == "readback"]
    rows = [r for r in rows if r["kind"] != "readback"]
    ok = [r for r in rows if r["status"] == 201]
    bad = [r for r in rows if r["status"] != 201]
    sites = {}
    for r in ok:
        sites[r.get("site", "?")] = sites.get(r.get("site", "?"), 0) + 1
    lost, wrong, unchecked, retried = [], [], [], 0
    for r in ok:
        path = f"orders/{r['id']}" if r["kind"] == "order" else f"uploads/{r['id']}"
        status, raw, attempts = fetch(f"{args.url}/{path}")
        retried += attempts
        if status == 404:
            lost.append(r["id"])
        elif status != 200:
            unchecked.append(r["id"])
        elif r["kind"] == "order" and json.loads(raw)["total_cents"] != r["total_cents"]:
            wrong.append(r["id"])
        elif r["kind"] == "upload" and hashlib.sha256(raw).hexdigest() != r["expect"]:
            wrong.append(r["id"])
    outage = (round(bad[-1]["t"] - bad[0]["t"], 1) if len(bad) > 1 else 0) if bad else 0
    report = {"requests": len(rows), "acknowledged": len(ok), "refused_or_failed": len(bad), "by_site": sites,
              "failed_span_seconds": outage, "failures": sorted({r["status"] for r in bad}),
              "acknowledged_but_missing": len(lost), "acknowledged_but_wrong": len(wrong), "could_not_check": len(unchecked),
              "check_retries": retried, "first_missing": lost[:5], "first_wrong": wrong[:5],
              "read_back": len(backs), "read_back_failed": sum(1 for r in backs if r["status"] != 200)}
    print(json.dumps(report, indent=1))
    return 1 if lost or wrong or unchecked else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--url", required=True)
    r.add_argument("--seconds", type=int, default=600)
    r.add_argument("--rate", type=float, default=5)
    r.add_argument("--workers", type=int, default=2)
    r.add_argument("--uploads", type=float, default=0.1)
    r.add_argument("--out", required=True)
    r.add_argument("--stop-file", help="stop early once this file exists")
    r.add_argument("--read-back", action="store_true", help="read each upload straight after making it")
    c = sub.add_parser("check")
    c.add_argument("--url", required=True)
    c.add_argument("--log", required=True)
    args = ap.parse_args()
    return run(args) if args.cmd == "run" else check(args)


if __name__ == "__main__":
    raise SystemExit(main())
