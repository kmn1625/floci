"""Load for the deploy drills: 2 workers open a new connection per request, 2 keep one alive,
2 keep one alive and retry a GET once when the server closed that connection (RFC 9112 9.3.1, as
Go's Transport, browsers and nginx/Envoy upstreams do).
Logs every request (epoch, worker, status, ms, pod) to the output file until the stop file exists."""
import http.client, json, os, sys, threading, time
HOST, OUT, STOP = sys.argv[1], sys.argv[2], sys.argv[2] + ".stop"
lock = threading.Lock()
log = open(OUT, "w", buffering=1)

def get(conn):
    conn.request("GET", "/")
    r = conn.getresponse()
    return r, r.read()


def worker(name, keepalive, retry=False):
    conn = None
    while not os.path.exists(STOP):
        t0 = time.time()
        retried = False
        try:
            if conn is None or not keepalive:
                conn = http.client.HTTPConnection(HOST, 80, timeout=2)
            try:
                r, body = get(conn)
            except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError):
                if not retry:
                    raise
                conn.close(); conn = http.client.HTTPConnection(HOST, 80, timeout=2)
                r, body = get(conn)
                retried = True
            status, pod = str(r.status) + ("-retried" if retried else ""), (json.loads(body).get("host", "-") if r.status == 200 else "-")
            if not keepalive:
                conn.close()
        except Exception as e:
            status, pod = "ERR:" + type(e).__name__, "-"
            try: conn.close()
            except Exception: pass
            conn = None
        with lock:
            log.write(f"{t0:.3f} {name} {status} {int((time.time() - t0) * 1000)} {pod}\n")
        time.sleep(0.05)

ts = [threading.Thread(target=worker, args=(f"{k}{i}", k != "new", k == "kar")) for k in ("new", "ka", "kar") for i in range(2)]
for t in ts: t.start()
for t in ts: t.join()
