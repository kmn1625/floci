# Shared by the AWS to Azure drill scripts. Passwords live in .cache/migrate-drill, outside the repo.
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DRILL=/d/devops-project/.cache/migrate-drill
DRILL_WIN=D:/devops-project/.cache/migrate-drill
TOOLS=D:/devops-project/devops-project/tools
PYTHON=D:/devops-project/.venv-py314/Scripts/python.exe
RDS=$(cat "$DRILL/rds.name")
AZPG=$(tr -d '\r\n' < "$DRILL/azpg.name")
AKS=$(docker ps -a --filter name=floci-az-lab-aks- --format '{{.Names}}' | head -1)
EKS=floci-aws-eks-shop
ACCOUNT=$(tr -d '\r\n' < "$DRILL/az-storage.name")
TAG=1.1.1

aws_sql() { docker exec "$RDS" psql -U shopadmin -d shop -v ON_ERROR_STOP=1 -Atqc "$1"; }
az_sql() { docker exec "$AZPG" psql -U shopadmin -d shop -v ON_ERROR_STOP=1 -Atqc "$1"; }

t0=$(date +%s.%N)
stamp() { printf '%6.1fs  %s\n' "$(python -c "import time;print(time.time()-$t0)")" "$1"; }

# Both SDKs are in the app image, so the copy runs next to it. $1 is s3-to-blob or blob-to-s3.
sync_files() {
  local url
  case "$1" in
    s3-to-blob) url="postgresql://shop_app:$(cat "$DRILL/app.pw")@aws-rds:5432/shop" ;;
    blob-to-s3) url="postgresql://shop_app:$(cat "$DRILL/app.pw")@$AZPG:5432/shop" ;;
  esac
  docker run --rm --memory 256m --network azure_default -v "D:/devops-project/floci/migration/aws-to-azure/sync-files.py:/sync.py:ro" \
    -v "$DRILL_WIN:/out" -e S3_ENDPOINT=http://floci-lab:4566 -e S3_BUCKET=shop-uploads -e AWS_REGION=us-east-1 \
    -e AWS_ACCESS_KEY_ID=floci -e AWS_SECRET_ACCESS_KEY=floci -e BLOB_URL="http://floci-az:4577/$ACCOUNT" -e BLOB_ACCOUNT="$ACCOUNT" \
    -e BLOB_KEY="$(cat "$DRILL/az-storage.key")" -e BLOB_CONTAINER=uploads -e DATABASE_URL="$url" \
    --entrypoint python "shop:$TAG" /sync.py "$@"
}

# Compare both databases with the product's own check. Extra flags go to it.
data_check() {
  "$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --print-sql > "$DRILL/snapshot.sql"
  docker cp "$DRILL_WIN/snapshot.sql" "$RDS:/tmp/snapshot.sql" >/dev/null
  docker cp "$DRILL_WIN/snapshot.sql" "$AZPG:/tmp/snapshot.sql" >/dev/null
  docker exec "$RDS" psql -U shopadmin -d shop -At -f /tmp/snapshot.sql > "$DRILL/aws.json"
  docker exec "$AZPG" psql -U shopadmin -d shop -At -f /tmp/snapshot.sql > "$DRILL/azure.json"
  "$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" "$@" --out "$DRILL_WIN/data-check.json"
}

# A stop before the target opens must never leave the app frozen: the side that is frozen still holds everything,
# so unfreezing it loses nothing and ends the outage. Printing "unfreeze it" and exiting left writes down for minutes.
frozen_side=""
unfreeze() {
  [ -n "$frozen_side" ] || return 0
  echo "STOPPED: unfreezing $frozen_side, which still holds everything. Customers can write again." >&2
  "${frozen_side}_sql" "alter role shop_app reset default_transaction_read_only"
}
trap unfreeze EXIT
