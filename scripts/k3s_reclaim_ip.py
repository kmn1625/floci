#!/usr/bin/env python3
"""Give an emulator's k3s cluster container its pinned bridge IP back after a Docker restart.

    python scripts/k3s_reclaim_ip.py <container-name-prefix> [--saved-ip FILE]

Floci (EKS), floci-gcp (GKE) and floci-az (AKS) run each cluster as a k3s container. k3s pins
the node IP it first registered with; after a restart another container often holds that IP on
Docker's default bridge, and k3s exits with "failed to find interface with specified node ip"
while the cloud API still reports the cluster healthy (aws A-21, gcp G-25, azure F-31).

The default bridge cannot assign a fixed IP, so: stop whoever holds the address, park throwaway
placeholders (`--rm`) on any lower free address, start the cluster (Docker hands it the lowest
free one, its own), remove the placeholders and start the holder again.
Runbook: devops-project/runbooks/cluster-unhealthy.md.
"""
import argparse
import ipaddress
import json
import re
import subprocess
import sys
import time
from pathlib import Path


def sh(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True, check=False)
    if check and r.returncode:
        raise SystemExit(f"{' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def bridge():
    data = json.loads(sh("docker", "network", "inspect", "bridge"))[0]
    return {c["Name"]: c["IPv4Address"].split("/")[0] for c in data["Containers"].values()}, \
        data["IPAM"]["Config"][0]["Subnet"]


def pinned_ip(container, saved: Path):
    if saved and saved.exists():
        return saved.read_text().strip()
    logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True, check=False)  # k3s logs to stderr
    found = re.findall(r'provided-node-ip":"([\d.]+)"', logs.stdout + logs.stderr)
    return found[0] if found else None  # the first registration is the one k3s keeps


def reclaim(prefix: str, saved: "Path | None" = None) -> bool:
    names = sh("docker", "ps", "-a", "--format", "{{.Names}}").split()
    cluster = next((n for n in names if n.startswith(prefix)), None)
    if not cluster:
        print(f"k3s: no container named {prefix}*")
        return True
    if sh("docker", "inspect", cluster, "--format", "{{.State.Running}}") == "true":
        ip = bridge()[0].get(cluster)
        print(f"k3s: {cluster} already running on {ip}")
        if ip and saved:
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_text(ip)
        return True
    want = pinned_ip(cluster, saved)
    if not want:
        raise SystemExit(f"k3s: cannot tell which node IP {cluster} registered (no saved IP, nothing in its log)")
    holders, subnet = bridge()
    stopped = [name for name, ip in holders.items() if ip == want]
    for name in stopped:
        print(f"k3s: {name} holds {want}; stopping it until {cluster} has its address back")
        sh("docker", "stop", name)
    taken = set(bridge()[0].values())
    lower = [h for h in list(ipaddress.ip_network(subnet).hosts())[1:]
             if str(h) not in taken and h < ipaddress.ip_address(want)]
    placeholders = []
    for i, _ in enumerate(lower):
        name = f"k3s-ip-placeholder-{i}"
        sh("docker", "run", "-d", "--rm", "--name", name, "alpine:3.22", "sleep", "600")
        placeholders.append(name)
    sh("docker", "start", cluster)
    got = bridge()[0].get(cluster)
    for name in placeholders:
        sh("docker", "stop", name, check=False)  # --rm: gone once stopped
    for name in stopped:
        sh("docker", "start", name)
    print(f"k3s: {cluster} started on {got} (wanted {want})")
    if got != want:
        print("k3s: did not get its node IP back; k3s will exit again")
        return False
    if saved:
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_text(got)
    for _ in range(30):
        if " Ready" in sh("docker", "exec", cluster, "kubectl", "get", "nodes", "--no-headers", check=False):
            print("k3s: node Ready")
            return True
        time.sleep(5)
    print("k3s: node not Ready after 150 s; check `docker logs` of the cluster container")
    return False


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("prefix", help="cluster container name prefix, e.g. floci-aws-eks- or floci-gcp-gke-")
    ap.add_argument("--saved-ip", type=Path, help="file remembering the node IP between restarts")
    a = ap.parse_args()
    sys.exit(0 if reclaim(a.prefix, a.saved_ip) else 1)
