# Deploy drills on the kubeadm cluster

Zero-downtime rollouts and bad deploys, run on 3-4 Nov 2026 against `hello-api` on the kubeadm VMs
(Kubernetes 1.37.2, Calico 3.33, Argo CD 3.5 with auto-sync and selfHeal). Every change went through Git,
as a commit on `main` that Argo CD synced. The rules and runbook that came out of the drills are in the
devops-project repo (§K019, §K020, `runbooks/bad-deploy-rollback.md`).

## Setup
- `hello-api`: 2 replicas, RollingUpdate `maxSurge: 1, maxUnavailable: 0`, readiness `/readyz` every 5 s,
  liveness `/healthz` every 10 s, preStop sleep 10 s, grace period 25 s, a PDB that allows 1.
- Load (`vms/drills/load.py`): 6 workers on k8s-cp1 through the Service's ClusterIP, 65-75 requests/s.
  - `new`: a new connection per request.
  - `ka`: keep-alive, no retry.
  - `kar`: keep-alive, and one retry of the GET when the server closed the reused connection. This is
    RFC 9112 §9.3.1 behaviour, the same as Go's Transport, browsers and Envoy.
- `vms/drills/start.sh NAME` / `stop.sh NAME` (as root on k8s-cp1) record the load and a 2 s timeline of the
  Deployment and the Argo CD app, then summarize both.

```bash
multipass transfer vms/drills/load.py k8s-cp1:/home/ubuntu/drills/   # and summarize.py, start.sh, stop.sh
multipass exec k8s-cp1 -- sudo bash /home/ubuntu/drills/start.sh z1
# commit + push a change, then: kubectl -n argocd annotate application hello-api argocd.argoproj.io/refresh=normal --overwrite
multipass exec k8s-cp1 -- sudo bash /home/ubuntu/drills/stop.sh z1
```

## Zero-downtime rollouts
| Drill | Change | Requests | Failed |
|---|---|---|---|
| Z1 | New pod template, same image | 5,826 | 2, all `ka` (`RemoteDisconnected`) |
| Z1b | Same, again | 9,105 | 3, all `ka` |
| Z2 | `strategy: Recreate` | 9,141 | 1,665: every request for 19.3 s |
| Z2 revert | Back to RollingUpdate | 8,088 | 2 `ka`; `kar` retried 2 and lost none |

The cluster side is zero downtime. A client that reuses keep-alive connections without retrying loses 1-3
requests per rollout: Go's `Shutdown` closes idle connections when the old pod stops, and a request already
sent on one of them fails.

## Bad deploys and rollback
| Drill | Bad change | Failed | Argo CD showed |
|---|---|---|---|
| R1 | Image that does not exist (ImagePullBackOff) | 0 of 39,380 | "Synced Progressing", no message |
| R2 | App exits at start (CrashLoopBackOff) | 0 of 61,143 | "OutOfSync Healthy" for 6 min (stale) |
| R3 | Liveness path the app does not serve; readiness passes | 5-34% per minute for 5 min, then 100% for 3 min 50 s | "Synced Healthy" during the errors |
| R3b | R3 again, with `minReadySeconds: 45` | 803 of 25,420 (~4%) | "Synced Progressing" |

- **R1, R2:** the surge pod never got Ready, so `maxUnavailable: 0` kept both old pods serving.
- **R3:** the bad pods passed readiness, so both old pods were replaced within 30 s. Liveness then
  restarted the new ones, and CrashLoopBackOff's growing back-off kept them out longer each time. At
  04:16 UTC both were down at once.
- **R3b:** a pod that liveness restarts never stays Ready for 45 s, so it never counted as available. The
  rollout stalled on one surge pod while the old pods kept serving. The failures were requests that reached
  the surge pod while it restarted. They hit only `new` clients, because keep-alive connections stayed on the
  old pods. `minReadySeconds: 45` stays in `k8s/hello-api`.

Rolling back:
| Method | Result |
|---|---|
| `kubectl rollout undo` | Undone by selfHeal after 78 s |
| `argocd app rollback` | Refused: `rollback cannot be initiated when auto-sync is enabled` |
| `git revert` + push + refresh | R1 and R2: old version serving in 81-95 s. R3: 4 min 17 s. R3b: about 2 min. R3 and R3b waited on the controller-manager (D-07) |

## Findings
- **D-01** Keep-alive clients without retry lose 1-3 requests per rollout. A client that retries once on a
  reused connection loses none.
- **D-02** `Recreate` stops every pod first: 19.3 s outage on a good deploy.
- **D-03** `maxUnavailable: 0` with a readiness probe absorbs a bad image and a crash at start: 0 failures.
- **D-04** Argo CD status does not show a bad deploy. Watch error rate and restarts. R2's stale status
  matches the Calico finding below: Argo CD logged "Reconciling Kubernetes APIs ... due to APIService event"
  up to 34 times in 10 minutes. Calico 3.33 installs its v3 CRDs, and the operator also registers the
  aggregated `v3.projectcalico.org` APIService, so the two keep rewriting it. Not changed here (CNI change).
- **D-05** A version that passes readiness and fails liveness ends in a full outage. `minReadySeconds`
  longer than the liveness window (10 s x 3) holds it back (R3b).
- **D-06** Under auto-sync, the only rollback that sticks is `git revert`.
- **D-07** k8s-cp1 is too small. It has 2 vCPU and 2.4 GB, kube-apiserver alone uses 1.1 GB, and Calico's
  API server, typha and webhooks also run there.
  - From 03:50 UTC (R1) on, the kubelet reported kube-controller-manager and kube-scheduler in
    CrashLoopBackOff 2-9 times per 10 minutes. There were none during the Z drills. The cause from before the reboot was not kept. After the reboot, its log shows "Error
    retrieving lease lock".
  - The EndpointSlice controller runs in kube-controller-manager. In R3, the rolled-back pods were Ready
    from 04:18:10 but got no traffic until 04:20:00. kube-proxy's watches had broken with `http2: client
    connection lost`.
  - In R3b, the crash-looping pod stayed in the EndpointSlice as ready until the controller-manager came
    back.
  - Fix, still to do: give k8s-cp1 4 GB (`multipass set local.k8s-cp1.memory=4G` while it is stopped), and
    run the load from somewhere other than the control plane.
- **D-08** After a laptop restart, the Default Switch gave all 3 VMs new IPs. The certificates and kubeconfigs
  point at k8s-cp1's first IP. The workaround is in the README. The drill's IP-based NetworkPolicy
  (`hello/upgrade-probe-from-cp1`) also had to allow k8s-cp1's new address.
