"""Routing-tier client for the cascading-overload drill (README.md).

Each router keeps THREADS keep-alive HTTPS connections to the backend Service and sends
RATE requests/s on each. Every 2 s it reads the ConfigMap `netconfig` through the API (as a
proxy reads its xDS config). When `generation` changes, the router drains its pool: every
thread drops its connection and reconnects. That is the drill's "network change". With
`stagger_s` > 0 a router applies the change after a random delay of up to stagger_s.

MODE=naive  timeout 1 s, retry at once up to 3 times on a new connection (the latent bug)
MODE=safe   timeout 1 s, at most 1 retry, only while the retry budget (10% of recent
            successes) allows; full-jitter exponential backoff before any reconnect;
            honours Retry-After

Prints one JSON line per second: requests ok/failed, attempts and TLS handshakes started
(the load the router puts on the backend), latency p50/p99 of successes, errors by kind.
"""
import collections, hashlib, http.client, json, os, random, ssl, threading, time, urllib.request

UP, PORT = os.environ["UPSTREAM"], int(os.environ.get("PORT", "443"))
THREADS, RATE = int(os.environ.get("THREADS", "16")), float(os.environ.get("RATE", "2"))
MODE, TIMEOUT = os.environ.get("MODE", "naive"), float(os.environ.get("TIMEOUT", "1"))
SPREAD = float(os.environ.get("START_SPREAD", "20"))  # first connections spread over this many seconds
POD = os.environ.get("HOSTNAME", "router")
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE  # drill cert is self-signed

lock = threading.Lock()
stats = collections.Counter()
lat = []
generation = None  # applied config generation
gen_seq = 0  # bumps each time a change is applied, threads compare against their own copy


class Budget:
    """Retry budget: each success earns 0.1 retry, capped at 10; a retry spends 1."""
    def __init__(self):
        self.tokens, self.lock = 10.0, threading.Lock()

    def earn(self):
        with self.lock:
            self.tokens = min(10.0, self.tokens + 0.1)

    def spend(self):
        with self.lock:
            if self.tokens >= 1:
                self.tokens -= 1
                return True
            return False


budget = Budget()


def count(**kv):
    with lock:
        stats.update(kv)


def attempt(conn):
    """One request on conn (a new conn handshakes first). Returns (status, pod, retry_after)."""
    conn.request("GET", "/")
    r = conn.getresponse()
    body = r.read()
    pod = json.loads(body).get("host", "-") if r.status == 200 else "-"
    return r.status, pod, r.getheader("Retry-After")


def new_conn():
    count(handshakes=1)
    return http.client.HTTPSConnection(UP, PORT, timeout=TIMEOUT, context=CTX)


def worker():
    conn, my_seq, fails = None, gen_seq, 0
    interval = 1.0 / RATE
    next_at = time.time() + random.random() * max(SPREAD, interval)  # warm the pool gradually
    while True:
        time.sleep(max(0, next_at - time.time()))
        next_at += interval
        if my_seq != gen_seq:  # network change: drain the pool
            my_seq = gen_seq
            if conn:
                conn.close()
            conn = None
        t0, tries = time.time(), 0
        max_tries = 4 if MODE == "naive" else 2
        status, err = None, None
        while tries < max_tries:
            if tries > 0:
                if MODE == "safe" and not budget.spend():
                    count(retry_denied=1)
                    break
                count(retries=1)
            tries += 1
            count(attempts=1)
            try:
                if conn is None:
                    if MODE == "safe" and fails:
                        time.sleep(random.uniform(0, min(10.0, 0.2 * 2 ** min(fails, 6))))
                    conn = new_conn()
                status, pod, retry_after = attempt(conn)
                if status == 200:
                    break
                err = f"http{status}"
                if MODE == "safe" and retry_after:
                    time.sleep(float(retry_after) * random.uniform(0.5, 1.5))
            except Exception as e:  # timeout, reset, refused, TLS error
                err = type(e).__name__
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
        if status == 200:
            fails = 0
            budget.earn()
            ms = int((time.time() - t0) * 1000)
            with lock:
                stats["ok"] += 1
                lat.append(ms)
        else:
            fails += 1
            count(failed=1, **{"e_" + (err or "none"): 1})
        if time.time() > next_at + 5 * interval:  # far behind after timeouts: skip, do not burst
            next_at = time.time()


def watch_config():
    """Poll ConfigMap netconfig; on a new generation, drain the pool (after the stagger)."""
    global generation, gen_seq
    token = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read()
    ns = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read()
    api = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    url = f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/configmaps/netconfig"
    while True:
        try:
            req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
            data = json.load(urllib.request.urlopen(req, context=api, timeout=5))["data"]
            g, stagger = data.get("generation"), float(data.get("stagger_s", "0"))
            if generation is None:
                generation = g
            elif g != generation:
                generation = g
                if stagger:
                    # deterministic per router so the spread is even, not a coin toss
                    time.sleep(int(hashlib.sha1(POD.encode()).hexdigest(), 16) % 1000 / 1000 * stagger)
                gen_seq += 1
                print(json.dumps({"t": int(time.time()), "pod": POD, "event": "network-change", "generation": g}), flush=True)
        except Exception as e:
            print(json.dumps({"t": int(time.time()), "pod": POD, "event": "config-error", "error": str(e)[:80]}), flush=True)
        time.sleep(2)


def reporter():
    while True:
        time.sleep(1 - time.time() % 1)
        with lock:
            s, l = dict(stats), sorted(lat)
            stats.clear()
            lat.clear()
        row = {"t": int(time.time()) - 1, "pod": POD, "mode": MODE, **s}
        if l:
            row["p50"], row["p99"] = l[len(l) // 2], l[int(len(l) * 0.99)]
        print(json.dumps(row), flush=True)


threading.Thread(target=watch_config, daemon=True).start()
threading.Thread(target=reporter, daemon=True).start()
for _ in range(THREADS):
    threading.Thread(target=worker, daemon=True).start()
while True:
    time.sleep(3600)
