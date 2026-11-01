#!/usr/bin/env python3
"""Bring the GCP lab back after a Docker / laptop restart (FINDINGS G-25).

    python gcp/lab/scripts/recover-after-restart.py          # on the host; needs docker

GKE: the k3s container exits with "failed to find interface with specified node ip" because
another container (the Cloud Run revision) took its pinned bridge IP; floci-gcp still reports
the cluster RUNNING. ../../scripts/k3s_reclaim_ip.py gives the address back.
Then run tests/smoke.py as the health check.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from k3s_reclaim_ip import reclaim  # shared with the AWS and Azure labs

if __name__ == "__main__":
    ok = reclaim("floci-gcp-gke-", Path(__file__).resolve().parents[1] / "out" / "gke-node-ip.txt")
    print("next: docker compose --profile tools run --rm toolbox sh -c "
          "\"pip install -q google-cloud-firestore && python3 tests/smoke.py\"")
    sys.exit(0 if ok else 1)
