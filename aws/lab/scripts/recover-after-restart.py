#!/usr/bin/env python3
"""Bring the AWS lab back after a Docker / laptop restart (FINDINGS A-20, A-21, A-23).

    python aws/lab/scripts/recover-after-restart.py          # on the host; needs docker and boto3

1. EKS: k3s pins the node IP it first registered with (Docker's default bridge). After a
   restart another container often holds that IP and k3s exits with "failed to find interface
   with specified node ip" while DescribeCluster still says ACTIVE. The default bridge cannot
   assign a fixed IP, so this frees the address, parks throwaway placeholders on any lower free
   address, starts the cluster (it gets its IP back), then removes the placeholders.
2. EC2: Floci reports `pending` after a restart. Stop + start through the API, and keep the
   instance container in line with what the API says (Floci leaves them out of step).
3. RDS needs nothing here: its endpoint IP moves to the VPC network (A-20); clients outside the
   VPC connect through Floci's name and the reported port, as tests/smoke.py does.

Then run tests/smoke.py as the health check.
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "floci")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "floci")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
SAVED_IP = Path(__file__).resolve().parents[1] / "out" / "eks-node-ip.txt"


def sh(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True, check=False)
    if check and r.returncode:
        raise SystemExit(f"{' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def bridge():
    data = json.loads(sh("docker", "network", "inspect", "bridge"))[0]
    return {c["Name"]: c["IPv4Address"].split("/")[0] for c in data["Containers"].values()}, \
        data["IPAM"]["Config"][0]["Subnet"]


def wanted_ip(eks):
    if SAVED_IP.exists():
        return SAVED_IP.read_text().strip()
    logs = subprocess.run(["docker", "logs", eks], capture_output=True, text=True, check=False)  # k3s logs to stderr
    m = re.search(r'provided-node-ip":"([\d.]+)"', logs.stdout + logs.stderr)
    return m.group(1) if m else None


def recover_eks():
    names = sh("docker", "ps", "-a", "--format", "{{.Names}}").split()
    eks = next((n for n in names if n.startswith("floci-aws-eks-")), None)
    if not eks:
        print("eks: no cluster container")
        return
    if sh("docker", "inspect", eks, "--format", "{{.State.Running}}") == "true":
        ip = bridge()[0].get(eks)
        print(f"eks: {eks} already running on {ip}")
        if ip:
            SAVED_IP.parent.mkdir(exist_ok=True)
            SAVED_IP.write_text(ip)
        return
    want = wanted_ip(eks)
    if not want:
        raise SystemExit("eks: cannot tell which node IP k3s registered (no saved IP, nothing in its log)")
    holders, subnet = bridge()
    stopped = []
    for name, ip in holders.items():
        if ip == want:
            print(f"eks: {name} holds {want}; stopping it until the cluster has its address back")
            sh("docker", "stop", name)
            stopped.append(name)
    taken = set(bridge()[0].values())
    net = ipaddress.ip_network(subnet)
    lower = [str(h) for h in list(net.hosts())[1:] if str(h) not in taken and h < ipaddress.ip_address(want)]
    placeholders = []
    for i, _ in enumerate(lower):
        name = f"eks-ip-placeholder-{i}"
        sh("docker", "run", "-d", "--rm", "--name", name, "alpine:3.22", "sleep", "600")
        placeholders.append(name)
    sh("docker", "start", eks)
    got = bridge()[0].get(eks)
    for name in placeholders:
        sh("docker", "stop", name, check=False)  # --rm: gone once stopped
    for name in stopped:
        sh("docker", "start", name)
    print(f"eks: started on {got} (wanted {want})")
    if got != want:
        raise SystemExit("eks: did not get its node IP back; k3s will exit again")
    SAVED_IP.parent.mkdir(exist_ok=True)
    SAVED_IP.write_text(got)
    for _ in range(30):
        if " Ready" in sh("docker", "exec", eks, "kubectl", "get", "nodes", "--no-headers", check=False):
            print("eks: node Ready")
            return
        time.sleep(5)
    print("eks: node not Ready after 150 s; check `docker logs` of the cluster container")


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
