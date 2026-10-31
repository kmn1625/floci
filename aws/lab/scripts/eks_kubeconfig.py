#!/usr/bin/env python3
"""kubeconfig for the lab's EKS cluster (run in the toolbox), and its exec credential plugin.

    python3 scripts/eks_kubeconfig.py > out/eks.kubeconfig      # write the kubeconfig
    python3 scripts/eks_kubeconfig.py token                     # ExecCredential (kubectl calls this)

Authentication is the real EKS scheme: a `k8s-aws-v1.` token that is a presigned STS
GetCallerIdentity URL carrying the cluster name, so Floci's token webhook maps the caller's
IAM identity to Kubernetes RBAC. No token is written to disk; kubectl asks for one per call.
Floci reports the endpoint as https://localhost:6500 (published on the host, FINDINGS A-14);
from the lab network the API is the k3s container's :6443, whose cert only names localhost.
"""

import base64
import datetime
import json
import sys

import boto3
import botocore.auth
import botocore.awsrequest

CLUSTER = "flocilab-eks"
SERVER = f"https://floci-aws-eks-{CLUSTER}:6443"


def token():
    session = boto3.session.Session()
    region = session.region_name
    req = botocore.awsrequest.AWSRequest(
        method="GET",
        url=f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        headers={"x-k8s-aws-id": CLUSTER},
    )
    botocore.auth.SigV4QueryAuth(session.get_credentials().get_frozen_credentials(), "sts", region, expires=60).add_auth(req)
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=14)
    return {
        "kind": "ExecCredential",
        "apiVersion": "client.authentication.k8s.io/v1beta1",
        "status": {
            "token": "k8s-aws-v1." + base64.urlsafe_b64encode(req.url.encode()).decode().rstrip("="),
            "expirationTimestamp": expiry.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }


def kubeconfig():
    ca = boto3.client("eks").describe_cluster(name=CLUSTER)["cluster"]["certificateAuthority"]["data"]
    return {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [{"name": CLUSTER, "cluster": {"server": SERVER, "certificate-authority-data": ca, "tls-server-name": "localhost"}}],
        "users": [{"name": CLUSTER, "user": {"exec": {
            "apiVersion": "client.authentication.k8s.io/v1beta1",
            "command": "python3",
            "args": [__file__, "token"],
            "interactiveMode": "Never",
        }}}],
        "contexts": [{"name": CLUSTER, "context": {"cluster": CLUSTER, "user": CLUSTER}}],
        "current-context": CLUSTER,
    }


if __name__ == "__main__":
    print(json.dumps(token() if sys.argv[1:] == ["token"] else kubeconfig(), indent=2))
