#!/usr/bin/env bash
# What happens to the stock promise once it crosses a network. Same faults, two designs.
#   bash experiment.sh naive | saga
#
# FAULT_LOST_ANSWER makes catalog commit and then lose the reply, like a timeout or a dropped connection.
# The saga run also kills pods mid-request, which leaves a reservation with nobody coming back for it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
trap - EXIT
MODE=${1:?usage: experiment.sh naive|saga}
SECONDS_LOAD=${2:-90}

repair() { # lab only: put stock back to what the orders say, so each run starts true
  sql shop "update products p set stock = p.initial_stock - coalesce((select sum(qty) from order_items i where i.product_id = p.id), 0)"
  sql shop "update reservations set status = 'released' where status = 'pending'"
}

# Repair only with no traffic: an order in flight while stock is recomputed reads as drift.
running=$(powershell -NoProfile -c "@(Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -match 'load.py' }).Count" | tr -d '')
[ "$running" = 0 ] || { echo "STOP: a load generator is still running, so the baseline would be wrong" >&2; exit 1; }
sleep 3
repair
stamp "$MODE: deploy, with 5% of answers lost after the write committed"
k set env deploy/catalog FAULT_LOST_ANSWER=0.05 >/dev/null
k set env deploy/shop ORDER_MODE="$MODE" CATALOG_URL=http://catalog >/dev/null
k rollout status deploy/catalog --timeout=240s | tail -1
k rollout status deploy/shop --timeout=240s | tail -1
stamp "before"
verify

rm -f "$DRILL/exp-$MODE.jsonl"
python "$LOAD_PY" run --url "$URL" --seconds "$SECONDS_LOAD" --rate 6 --uploads 0 --out "$DRILL_WIN/exp-$MODE.jsonl" > "$DRILL/exp-$MODE.log" 2>&1 &
LOAD=$!
if [ "$MODE" = saga ]; then
  for _ in 1 2 3 4 5; do
    sleep 25
    victim=$(k get pods -l app=shop -o 'jsonpath={.items[0].metadata.name}')
    stamp "kill $victim mid-request"
    k delete pod "$victim" --grace-period=0 --force >/dev/null 2>&1 || true
  done
fi
wait $LOAD

stamp "load finished"
verify
if [ "$MODE" = saga ]; then
  stamp "wait for the sweeper to settle what crashes left pending"
  for _ in $(seq 1 12); do
    pending=$(curl -s -m 8 "$URL/verify" | python -c "import sys,json;print(json.load(sys.stdin).get('pending'))" 2>/dev/null || echo "?")
    [ "$pending" = 0 ] && break
    sleep 10
  done
  verify
fi
python - <<PY
import json,collections
rows=[json.loads(l) for l in open(r"$DRILL_WIN/exp-$MODE.jsonl")]
print("orders:", dict(collections.Counter(r["status"] for r in rows)))
PY
k logs deploy/catalog-sweeper --tail=6 2>/dev/null | tail -4 | cut -c1-100
