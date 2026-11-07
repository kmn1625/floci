#!/usr/bin/env bash
# Prove the app can really use its storage on one side, from inside its own pod, before anyone freezes anything.
# /ready touches only the database. The first run of this drill cut over with health, readiness and orders
# all green, and every upload failed. The proof goes through the app's own store() and fetch().
#   bash proof.sh aws | azure
set -euo pipefail
source "$(dirname "$0")/lib.sh"
case "$1" in aws) NODE=$EKS ;; azure) NODE=$AKS ;; *) echo "usage: proof.sh aws|azure" >&2; exit 2 ;; esac

code='
import os, sys, uuid
sys.path.insert(0, "/app")
import app
key, data = f"proof-{uuid.uuid4()}", os.urandom(2048)
app.store(key, data)
assert app.fetch(key) == data, "read back different bytes"
print(app.SITE, app.STORAGE)
'
ok=false
if out=$(docker exec "$NODE" kubectl -n shop exec deploy/shop -- python -c "$code" 2>&1); then ok=true; fi
python -c "import json,datetime;json.dump({'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'site':'$1','proved':{'storage write and read through the app':$( [ "$ok" = true ] && echo True || echo False )}},open(r'$DRILL_WIN/target-smoke.json','w'))"
if [ "$ok" != true ]; then
  echo "STOP: the app on $1 cannot use its storage. Nothing was frozen." >&2
  printf '%s\n' "$out" | tail -2 >&2
  exit 1
fi
echo "proved on $1: $out"
