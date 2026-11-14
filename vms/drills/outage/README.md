# Cascading-overload drill (Microsoft 365 outage, 12-13 Nov 2026)

On 12 Nov 2026, from about 16:00 GMT, Outlook, Exchange Online, Teams and Copilot failed worldwide for more
than a day (incident EX1550543 / MO1550821). Restored servers fell over again in Europe the next morning.
This drill rebuilds the failure pattern Microsoft described on the kubeadm lab, measures it, and measures
the fixes. Microsoft's post-incident report was not out when this was written (14 Nov), so the drill
follows the mechanism from its status updates, not its internals.

## What Microsoft said happened
Quotes are from Microsoft's status updates as collected by azureblog.co.uk and Al Jazeera (links at the
end).

| Time (GMT) | Microsoft update |
|---|---|
| 12 Nov 18:19 | "elevated load across multiple regions", not caused by more traffic: servers had become unavailable and their work moved to the rest |
| 19:43 | affected servers fail automated health checks and are taken out of rotation |
| 19:57 | the failures "may originate from a specific component that's responsible for processing server health"; an alternative health check returns some servers at 20:56 |
| 22:00 | "a core process on affected servers is becoming overwhelmed, causing capacity loss" |
| 13 Nov 00:00 | returned servers "can become unresponsive again once they begin receiving traffic" |
| overnight | "a process on the affected servers responsible for establishing secure connections becomes overwhelmed" |
| overnight | reverting "a recent network configuration change that correlates with the start of impact"; 03:07 the revert "is not taking as expected"; 04:57 a surge in outbound calls from the routing services to the backends, machines "stuck in a bad state" so the change could not sync |
| 04:22-06:17 | traffic blocking and redistribution, throttling, protocol adjustments, failover routing |
| 13 Nov 17:57 | cause: "The incident was introduced by an issue during an earlier network capacity upgrade" that "surfaced following a recent network change" |

Regions came back in stages: Asia Pacific, then Europe, then North America (13 Nov 11:04-14:56 GMT).

## The failure pattern
This is a **metastable failure**: a trigger pushes the system into an overloaded state, and a feedback
loop keeps it there after the trigger is gone. Rolling the trigger back does not help, which is what
Microsoft saw.

1. A latent weakness that is harmless in steady state (here: from the "earlier capacity upgrade").
2. A trigger that makes every client reconnect at once (the "network change").
3. Connection setup (the TLS handshake) is expensive, so the reconnect wave saturates the servers.
4. Health checks queue behind that work, time out, and take busy-but-working servers out of rotation.
   The rest get their load and fail the same way.
5. Clients time out and retry at once on new connections: more handshakes, much of it for clients that
   have already given up.
6. A server that is restarted or returned to rotation gets the whole backlog and falls over again.

## The lab version
| Microsoft | Drill (`drill.sh`) |
|---|---|
| Exchange front-end servers | `backend`: 3 hello-api pods, HTTPS on 8443 with a 4096-bit RSA certificate, 200m CPU each |
| routing services | `router`: 4 pods x 24 keep-alive connections opened over 20 s, 0.5 requests/s per connection (`router.py`) |
| earlier capacity upgrade, latent | the routers' retry policy: 1 s timeout, 3 immediate retries, each on a new connection. Harmless while connections live for hours |
| recent network change | bump `generation` in the `netconfig` ConfigMap. Every router reads it like a proxy reads xDS config and drains its connection pool. With `trigger 0` all routers apply it in the same 2 s |
| health checks | kubelet probes. `broken`: HTTPS on the client port, 1 s timeout. A failing readiness probe takes the pod out of the Service's endpoints; a failing liveness probe restarts it |

Fixes, each switchable so they can be measured alone:

| Fix | Where |
|---|---|
| **Admission control**: reset new connections while 8 are already handshaking, 503 + `Retry-After` over 32 requests in flight. Both checks run before any crypto or handler work. | `apps/hello-api/protect.go`; `MAX_HANDSHAKES`, `MAX_INFLIGHT` |
| **Probes outside the data path**: plain HTTP admin port, outside both limits. Liveness restarts only a pod that is silent for 60 s | `ADMIN_PORT=8081`; `drill.sh up protected` |
| **Client retries**: full-jitter exponential backoff before a reconnect, at most 1 retry, and only while a retry budget (10% of recent successes) has tokens; `Retry-After` honoured | `router.py` `MODE=safe` |
| **Staged change**: each router applies the network change after a spread delay | `drill.sh trigger 60` |

## Running it
```bash
cd vms/drills/outage
./drill.sh image                     # build hello-api 0.3.0-drill, import it on the workers
./drill.sh up broken naive           # or: protected naive | broken safe | protected safe
./drill.sh watch r1 &                # endpoints + restarts every 2 s
# wait 60 s of steady state
./drill.sh trigger                   # the network change, all routers at once (or: trigger 60)
# wait 4 min
./drill.sh collect r1                # router logs + summary
./drill.sh down

./drill.sh run r4 protected safe     # the same steps in one command
./drill.sh recover 4                 # during an outage: shed to 1 router, wait for Ready, ramp back to 4
```
Do not edit `drill.sh` while a run is going: bash reads the script as it runs.

## Results (14 Nov 2026)
Kubernetes 1.37.2 on the 3 lab VMs (2 vCPU each) on a 4-core laptop. Every run: fresh namespace, backends
Ready, routers started one at a time, 60 s steady state (500 requests/10 s), then the network change to all
routers at once, then 4 minutes. Raw logs: `out/` (not committed).

| Run | Backend | Routers | Before | After the change | Restarts | Recovered |
|---|---|---|---|---|---|---|
| R1 | broken | naive | 80.5% | 1.9%, 3.92 attempts per request | 16 | no |
| R2 | protected | naive | 100% | 47.5%, 2.72 attempts per request | 0 | no, slowly rising |
| R3 | broken | safe | 100% | 8.0%, 1.05 attempts per request | 14 | no |
| **R4** | **protected** | **safe** | **99.4%** | **97.8%**, worst 10 s 56%, 1.01 attempts per request | **0** | **in 34 s** |
| R5 | broken | naive, then the runbook | 100% | 0% until the shed, then 100% | 9, none after the shed | 27 s after the shed |

- **R1, broken:** the textbook cascade. HTTPS probes with a 1 s timeout queued behind the handshake wave;
  the kubelet restarted all three backends again and again (16 restarts) and every restarted pod met the
  whole backlog: "can become unresponsive again once they begin receiving traffic". Naive retries made
  every request 4 attempts. R1 had already tipped while the 4th router joined, 70 s before the change:
  the broken setup was one blip away from this state all along.
- **R2, server fixes only:** no restarts and all backends Ready the whole time, but naive clients kept the
  handshake path full (resets, instant retries, new handshakes). The fleet survived; the service did not.
- **R3, client fixes only:** the clients backed off (1.05 attempts per request), but the reconnect wave alone
  still timed out the 1 s probes, and restarted pods came back cold into it. 14 restarts, no recovery.
- **R4, both:** one bad 10 s bucket (the backends reset handshakes over the limit, the clients backed off),
  recovered in 34 s, no restarts. Each half alone failed; together they held.
- **R5, the runbook on a collapsed fleet:** 90 s into the outage, routers 4 -> 1. All backends Ready 27 s
  later and the remaining router at 100%; routers back one per 30 s with 0 failures. Taking load away is
  what ended it; nothing was rolled back. (The 3 removed routers took their logs with them: R5's numbers
  are from the router that stayed.)

## Findings
| # | Finding | Fix |
|---|---|---|
| O-01 | A liveness probe on the client port with the default 1 s timeout restarts busy, healthy pods; the restart throws away warm connections and the backlog kills the next pod. The cluster cannot leave this state on its own | Probes on an admin port; liveness `timeoutSeconds: 5`, 60 s window; boot in a `startupProbe` (devops-project §K021, `overload-safety` check) |
| O-02 | A server that accepts every connection finishes none under a wave: the handshakes it completes are for clients that have already timed out | Admission control before the expensive part: `MAX_HANDSHAKES`, `MAX_INFLIGHT` + `Retry-After` (`apps/hello-api/protect.go`) |
| O-03 | Immediate retries on a new connection multiply the load by up to 4 when there is no capacity to spare | One retry, full-jitter backoff, retry budget, `Retry-After` (`router.py` safe mode) |
| O-04 | A change pushed to every client at once is a reconnect wave | Stage it (`trigger 60`); proxies warm pools gradually (`START_SPREAD`) |
| O-05 | Recovery is load removal, then a stepped ramp; restarts and rollbacks do not end it | `runbooks/overload-cascade.md` in devops-project, measured by R5 |
| O-06 | The lab control plane had the same failure: both Calico CRD sets were installed, so tigera-operator and kube-apiserver fought over the `v3.projectcalico.org` APIService several times a second. cp1 sat at load 20-30, tigera-operator had 51 restarts. Cause: `vms/ansible/site.yml` applies `operator-crds.yaml` (the v1 `crd.projectcalico.org` set, aggregated-API mode), while tigera-operator 1.44 with `-manage-crds=true` treats a Kubernetes 1.34+ cluster as a new native-v3 install and adds the `projectcalico.org` v3 CRDs and admission policies. calico-node still reads v1: new IPAM handles land there, the v3 copies stopped on 3 Nov. Deleting the v1 set would have wiped live IPAM | Operator scaled to 0: errors stopped at once, cp1 load fell from about 20 to 5 in 4 minutes. Permanent fix pending: one mode end to end (rebuild with `v3_projectcalico_org.yaml` only, or remove the v3 set and keep v1) |
| O-07 | kube-controller-manager lost its 10 s lease renewal on the starved cp1, exited, re-listed everything on restart and lost the lease again: 64 restarts, stale EndpointSlices (all 3 endpoints "ready" while every pod crashlooped), a namespace stuck in Terminating | Lease 60 s, renew deadline 40 s for controller-manager and scheduler (`vms/ansible/templates/kubeadm-config.yaml.j2`; applied by hand on cp1, backups in `/root/manifest-backup-*`) |
| O-08 | The 4-core host cannot run the 3 VMs plus a parallel heavy job (a Go build, a test suite, a Whisper transcription): the control plane fell over each time | Check host load before a drill; build with `--cpus 1` and cached Go volumes (`drill.sh image`) |
| O-09 | A Go module cache on a Windows bind mount stalled `go vet` for 20+ minutes | Docker named volumes for the module and build caches |
| O-10 | Pod CIDR `192.168.0.0/16` overlaps the Hyper-V Default Switch NAT range, which moves on every host restart (14 Nov: `192.168.192.0/20`). Calico does not NAT traffic to an address inside its pool, so CoreDNS's upstream `192.168.192.1` timed out from pods while the nodes resolved fine; Argo CD could not reach GitHub and every app went `Unknown`. A latent setup choice surfaced by a network change, the outage pattern again | CoreDNS forwards to `1.1.1.1 8.8.8.8` (backup of the old ConfigMap kept locally). Permanent fix: a pod CIDR outside 192.168/16 (e.g. `10.244.0.0/16`) at the next rebuild |

## Lessons for a real project
1. Liveness probes ask "is the process stuck?", never "is it busy?". The default 1 s timeout on the client
   port turns any overload into an outage.
2. Protect the server and the clients. Admission control without client backoff leaves a live fleet that
   serves little; backoff without admission control and safe probes leaves a dead fleet.
3. Stage changes that make clients reconnect, and warm connection pools gradually.
4. A metastable outage outlives its trigger. The first move is to take load away, then bring it back in
   steps; rolling back or restarting first wastes the time Microsoft lost overnight.
5. The control plane obeys the same rules: tight leases and a hot reconcile loop made our own Kubernetes
   restart its controllers into the same spiral.

## Sources
- Microsoft status updates, collected: https://azureblog.co.uk/posts/microsoft-365-outage-12-november-2026/
- Timeline and reactions: https://www.aljazeera.com/news/2026/11/13/microsoft-hit-by-global-outages-what-happened-and-why
- Metastable failures: Bronson et al., "Metastable Failures in Distributed Systems", HotOS 2021
