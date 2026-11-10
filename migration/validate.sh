#!/usr/bin/env bash
# Check the drills' Kubernetes manifests with the devops engine's validate-k8s, as the scripts render them.
# The templates hold __PLACEHOLDERS__ (a replica count among them) that only become valid Kubernetes once filled
# in, so each drill's set is rendered with sample values first, then checked as one directory: a NetworkPolicy
# in one file covers a Deployment in another.
#
#   bash migration/validate.sh            # both drills
#   bash migration/validate.sh eks|aks    # one
#
# Needs the devops-project checkout next to this one (D:/devops-project/devops-project), as the drills do.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE=${ENGINE:-D:/devops-project/devops-project}
PYTHON=${PYTHON:-$ENGINE/.venv/Scripts/python.exe}
OUT=${OUT:-$(mktemp -d)}
if command -v cygpath >/dev/null; then OUT=$(cygpath -m "$OUT"); fi   # Git Bash: Windows Python cannot read /tmp/...

fill() {  # sample values: what matters is that the result is valid Kubernetes
  sed -e 's/__TAG__/1.3.0/g' -e 's/__REPLICAS__/2/g' -e 's/__FLOCI_IP__/10.50.0.2/g' -e 's/__BUCKET__/shop-files/g' \
      -e 's#__DATABASE_URL__#postgresql://shop_app:x@10.50.0.2:7002/shop#g' -e 's/__CONFIG_HASH__/sample/g' \
      -e 's#__ONCALL_URL__#http://alert-sink.monitoring:8080/#g' -e 's#__BLOB_URL__#http://10.60.0.2:4577#g' \
      -e 's/__BLOB_KEY__/sample/g' -e 's/__ACCOUNT__/shopfiles/g' "$@"
}

eks() {
  local d="$OUT/eks"; mkdir -p "$d"
  fill "$HERE/onprem-to-aws/shop.k8s.yaml" > "$d/shop.yaml"
  cp "$HERE/onprem-to-aws/audit-purge.k8s.yaml" "$d/audit-purge.yaml"
  fill "$HERE/shop-split/split.k8s.yaml" > "$d/split.yaml"
  fill "$HERE/shop-split/monitoring.k8s.yaml" > "$d/monitoring.yaml"
  for svc in catalog files; do   # as setup.sh renders them
    fill "$HERE/shop-split/service.tmpl.yaml" | sed -e "s/__NAME__/$svc/g" -e "s/__SERVICE__/$svc/g" -e "s/__SECRET_KEY__/$svc-own/g" > "$d/$svc.yaml"
  done
  echo "$d"
}

aks() {
  local d="$OUT/aks"; mkdir -p "$d"
  fill "$HERE/aws-to-azure/shop.aks.yaml" > "$d/shop.yaml"
  echo "$d"
}

failed=0
for set in "${@:-eks aks}"; do
  for s in $set; do
    dir=$("$s")
    echo "== $s ($dir)"
    (cd "$ENGINE" && DEVOPS_ENGINE_ARTIFACTS="$OUT/kept" DEVOPS_ENGINE_AUDIT_LOG="$OUT/audit.jsonl" \
      "$PYTHON" -X utf8 -m engine validate-k8s "$dir" --json) > "$OUT/$s.json" || true
    "$PYTHON" -X utf8 - "$OUT/$s.json" <<'EOF' || failed=1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for c in d["checks"]:
    print(f"  {c['status']:5} {c['name']}" + ("" if c["status"] in ("PASS", "SKIP") else ": " + c["detail"].strip().replace("\n", "\n        ")))
sys.exit(0 if d["status"] == "PASS" else 1)
EOF
  done
done
exit $failed
