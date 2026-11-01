#!/usr/bin/env python3
"""Bring the AWS lab back after a Docker / laptop restart (FINDINGS A-20, A-21, A-23).

    python aws/lab/scripts/recover-after-restart.py          # on the host; needs docker and boto3

1. EKS: k3s exits with "failed to find interface with specified node ip" while DescribeCluster
   says ACTIVE, because another container took its pinned bridge IP. ../../scripts/k3s_reclaim_ip.py
   gives the address back (start order with placeholders).
2. EC2: Floci reports `pending` after a restart. Stop + start through the API, and keep the
   instance container in line with what the API says (Floci leaves them out of step).
3. RDS needs nothing here: its endpoint IP moves to the VPC network (A-20); clients outside the
   VPC connect through Floci's name and the reported port, as tests/smoke.py does.

Then run tests/smoke.py as the health check.
"""
import os
import sys
import time
from pathlib import Path

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "floci")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "floci")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
SAVED_IP = Path(__file__).resolve().parents[1] / "out" / "eks-node-ip.txt"


sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from k3s_reclaim_ip import reclaim, sh  # shared with the GCP and Azure labs


def recover_eks():
    reclaim("floci-aws-eks-", SAVED_IP)


def recover_ec2():
    import boto3
    ec2 = boto3.client("ec2", endpoint_url=ENDPOINT)
    for res in ec2.describe_instances()["Reservations"]:
        for inst in res["Instances"]:
            iid, state = inst["InstanceId"], inst["State"]["Name"]
            if state != "pending":
                continue
            print(f"ec2: {iid} stuck in pending; stop + start")
            ec2.stop_instances(InstanceIds=[iid])
            container = f"floci-aws-ec2-{iid}"
            sh("docker", "stop", container, check=False)
            ec2.start_instances(InstanceIds=[iid])
            sh("docker", "start", container, check=False)
            for _ in range(20):
                state = ec2.describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]["State"]["Name"]
                if state == "running":
                    break
                time.sleep(3)
            print(f"ec2: {iid} {state}")


if __name__ == "__main__":
    recover_eks()
    recover_ec2()
    print("next: docker compose --profile tools run --rm toolbox sh -c "
          "\"pip install -q boto3 && python3 tests/smoke.py\"")
    sys.exit(0)
