#!/usr/bin/env python3
"""Turn what the split drill measured into the files the cutover gate reads in split mode.

Nothing here is typed in by hand: each number comes from the load log, the load check, the database or the logs.
  python evidence.py resolve  --raw split-check.raw.json --decisions split-decisions.json --out split-check.json
  python evidence.py attack   --log exp-saga.jsonl --check attack-check.json --committed N --lost N --killed N
                              --budget S --timeout S --out attack-drill.json
  python evidence.py rollback --check move-check.json --out rollback-drill.json
  python evidence.py window   --log run.jsonl --skew S        prints the run's first and last second, in database time
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path):
    text = Path(path).read_text(encoding="utf-8-sig")
    return json.loads(text[text.find("{"):])


def write(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(data, indent=1))


def resolve(args):
    raw, decisions = read(args.raw), read(args.decisions)
    blocking = [c["name"] for c in raw["checks"] if c["status"] == "FAIL"]
    stale = sorted(set(decisions) - set(blocking))
    if stale:
        print(f"decisions for findings that no longer exist (ignored): {stale}", file=sys.stderr)
    raw["resolved"] = [name for name in blocking if name in decisions]
    raw["decisions"] = {name: decisions[name] for name in raw["resolved"]}
    undecided = [name for name in blocking if name not in decisions]
    if undecided:
        print(f"no decision yet, the gate will refuse: {undecided}", file=sys.stderr)
    write(args.out, raw)


def orders(log):
    return [json.loads(line) for line in open(log, encoding="utf-8") if '"kind": "order"' in line]


def attack(args):
    rows, check = orders(args.log), read(args.check)
    acknowledged = sum(1 for r in rows if r["status"] == 201)
    write(args.out, {
        "finishedAt": now(), "requests": len(rows), "acknowledged": acknowledged,
        "acknowledgedMissing": check["acknowledged_but_missing"], "acknowledgedWrong": check["acknowledged_but_wrong"],
        "couldNotCheck": check["could_not_check"],
        # Orders the database committed in the run's window that no customer was told about.
        "committed": args.committed, "erroredButCommitted": max(0, args.committed - acknowledged),
        "lostAnswers": args.lost, "killed": args.killed,
        "retryBudgetSeconds": args.budget, "callerTimeoutSeconds": args.timeout,
        "source": "floci migration/shop-split gate-run.sh: load.py log and check, orders by created_at, catalog access log 502s",
    })


def rollback(args):
    check = read(args.check)
    write(args.out, {
        "finishedAt": now(), "acknowledged": check["acknowledged"], "acknowledgedMissing": check["acknowledged_but_missing"],
        "acknowledgedWrong": check["acknowledged_but_wrong"], "couldNotCheck": check["could_not_check"],
        "refusedOrFailed": check["refused_or_failed"], "failedSpanSeconds": check["failed_span_seconds"],
        "source": "floci migration/shop-split gate-run.sh: catalog forward and back under load, load.py check",
    })


def window(args):
    times = [r["t"] for r in orders(args.log)]
    print(f"{min(times) + args.skew:.3f} {max(times) + args.skew:.3f}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("resolve")
    r.add_argument("--raw", required=True)
    r.add_argument("--decisions", required=True)
    r.add_argument("--out", required=True)
    a = sub.add_parser("attack")
    a.add_argument("--log", required=True)
    a.add_argument("--check", required=True)
    a.add_argument("--committed", type=int, required=True)
    a.add_argument("--lost", type=int, required=True)
    a.add_argument("--killed", type=int, required=True)
    a.add_argument("--budget", type=float, required=True)
    a.add_argument("--timeout", type=float, required=True)
    a.add_argument("--out", required=True)
    b = sub.add_parser("rollback")
    b.add_argument("--check", required=True)
    b.add_argument("--out", required=True)
    w = sub.add_parser("window")
    w.add_argument("--log", required=True)
    w.add_argument("--skew", type=float, default=0)
    args = ap.parse_args()
    {"resolve": resolve, "attack": attack, "rollback": rollback, "window": window}[args.cmd](args)


if __name__ == "__main__":
    main()
