#!/usr/bin/env python3
"""Upgrade pre-flight: what would make a node drain hang or lose a workload.

    kubectl get nodes,pdb,pods -A -o json | python3 upgrade_preflight.py

Prints one line per problem and exits 1 if there is any.
"""
import json
import sys

items = json.load(sys.stdin)["items"]
problems = []
for i in items:
    meta, kind = i["metadata"], i["kind"]
    name = f"{meta.get('namespace', '')}/{meta['name']}".lstrip("/")
    if kind == "Node":
        ready = {c["type"]: c["status"] for c in i["status"].get("conditions", [])}.get("Ready")
        if ready != "True":
            problems.append(f"node {name} is not Ready")
    elif kind == "PodDisruptionBudget":
        if i.get("status", {}).get("disruptionsAllowed", 0) == 0:
            problems.append(f"PDB {name} allows no disruption: a drain of its pods' nodes never finishes")
    elif kind == "Pod":
        done = i["status"].get("phase") in ("Succeeded", "Failed")
        if not meta.get("ownerReferences") and not done:
            problems.append(f"pod {name} has no controller: a drain refuses it, --force deletes it for good")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
