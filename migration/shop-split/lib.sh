# Shared by the monolith split scripts. Runs on the AWS lab. Passwords live in .cache/migrate-drill, outside the repo.
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRILL=/d/devops-project/.cache/migrate-drill
DRILL_WIN=D:/devops-project/.cache/migrate-drill
TOOLS=D:/devops-project/devops-project/tools
PYTHON=D:/devops-project/.venv-py314/Scripts/python.exe
LOAD_PY=D:/devops-project/floci/migration/onprem-to-aws/load.py   # Windows path: this file exports MSYS_NO_PATHCONV
RDS=$(cat "$DRILL/rds.name")
EKS=floci-aws-eks-shop
TAG=1.2.1
DB_HOST=10.50.0.2:7002     # how pods reach RDS through Floci
URL=http://127.0.0.1:18080

sql() { docker exec "$RDS" psql -U shopadmin -d "$1" -v ON_ERROR_STOP=1 -Atqc "$2"; }
k() { docker exec "$EKS" kubectl -n shop "$@"; }

t0=$(date +%s.%N)
stamp() { printf '%6.1fs  %s\n' "$(python -c "import time;print(time.time()-$t0)")" "$1"; }

verify() { curl -s -m 8 "$URL/verify"; echo; }

# What a stop must undo: a function name, set while the freeze is on. Same rule as the cloud drills.
undo=""
on_stop() {
  [ -n "$undo" ] || return 0
  echo "STOPPED: undoing the freeze ($undo). The side that was frozen still holds everything." >&2
  "$undo"
}
trap on_stop EXIT

# Wait until a subscription has everything its publisher had when asked. A wait that runs out stops the script.
caught_up() { # publisher_db subscriber_db subscription
  local want behind=""
  want=$(sql "$1" "select pg_current_wal_lsn()")
  for _ in $(seq 1 120); do
    behind=$(sql "$2" "select pg_wal_lsn_diff('$want', coalesce(latest_end_lsn, '0/0')) from pg_stat_subscription where subname = '$3' and pid is not null and relid is null limit 1")
    [ -n "$behind" ] && [ "${behind%.*}" -le 0 ] && return 0
    sleep 0.5
  done
  echo "STOP: $3 did not catch up (behind by ${behind:-unknown} bytes)." >&2
  return 1
}

# A subscription inside one cluster needs its slot made first: creating it inline hangs forever.
subscribe() { # publisher_db subscriber_db name publication [extra options]
  sql "$1" "select pg_create_logical_replication_slot('$3', 'pgoutput')" >/dev/null
  sql "$2" "create subscription $3 connection 'host=127.0.0.1 port=5432 dbname=$1 user=mig_repl password=$(cat "$DRILL/repl.pw")' publication $4 with (create_slot = false, slot_name = '$3'${5:+, $5})"
}

# Compare only the tables that moved: the rest of the database is not meant to be there.
data_check() { # source_db target_db tables flags...
  local src=$1 dst=$2 tables=$3
  shift 3
  "$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --print-sql > "$DRILL/snapshot.sql"
  docker cp "$DRILL_WIN/snapshot.sql" "$RDS:/tmp/snapshot.sql" >/dev/null
  docker exec "$RDS" psql -U shopadmin -d "$src" -At -f /tmp/snapshot.sql > "$DRILL/split-source.json"
  docker exec "$RDS" psql -U shopadmin -d "$dst" -At -f /tmp/snapshot.sql > "$DRILL/split-target.json"
  "$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --source "$DRILL_WIN/split-source.json" --target "$DRILL_WIN/split-target.json" \
    --only "$tables" --out "$DRILL_WIN/split-data-check.json" "$@"
}
