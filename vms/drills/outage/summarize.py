"""Summarize a drill run: router JSON lines + the endpoint timeline, in 10 s buckets.

Usage: python summarize.py OUT/NAME.routers OUT/NAME.timeline

Per bucket: requests ok/failed, attempts and handshakes the routers sent (load on the backend),
backend endpoints ready, backend restarts so far. Then: success before the change, the worst
bucket, how long goodput stayed under 50%, and when it was back over 95% for 30 s.
"""
import collections, json, re, sys, time

rows, change = [], None
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("event") == "network-change":
        change = min(change or r["t"], r["t"])
    elif "event" not in r:
        rows.append(r)
if not rows:
    sys.exit("no router rows")

tl = {}
for line in open(sys.argv[2]) if len(sys.argv) > 2 else []:
    parts = line.split()
    if len(parts) < 2:
        continue
    restarts = sum(int(m) for m in re.findall(r":[\d/]+:\w+:(\d+)", line))
    tl[int(parts[0])] = (parts[1].split("=")[1], restarts)

B = 10
agg = collections.OrderedDict()
for r in sorted(rows, key=lambda r: r["t"]):
    b = agg.setdefault(r["t"] // B * B, collections.Counter())
    for k, v in r.items():
        if isinstance(v, int) and k not in ("t", "p50", "p99"):
            b[k] += v
    if "p99" in r:
        b["p99max"] = max(b["p99max"], r["p99"])

fmt = lambda t: time.strftime("%H:%M:%S", time.gmtime(t))
ts = list(agg)
print(f"routers: {len({r['pod'] for r in rows})}, mode {rows[0].get('mode')}, "
      f"{fmt(ts[0])}-{fmt(ts[-1] + B)}, network change at {fmt(change) if change else 'none'}")
print(f"{'time':>8} {'+s':>5} {'ok':>6} {'failed':>6} {'att':>6} {'hs':>6} {'p99ms':>6} {'ready':>5} {'restarts':>8}  errors")
for t, b in agg.items():
    near = [v for k, v in tl.items() if t <= k < t + B]
    ready, rst = near[-1] if near else ("?", "?")
    errs = " ".join(f"{k[2:]}={v}" for k, v in sorted(b.items()) if k.startswith("e_"))
    rel = f"{t - change:+d}" if change else ""
    print(f"{fmt(t)} {rel:>5} {b['ok']:>6} {b['failed']:>6} {b['attempts']:>6} {b['handshakes']:>6} "
          f"{b['p99max']:>6} {ready:>5} {rst!s:>8}  {errs}")

def rate(b):
    n = b["ok"] + b["failed"]
    return b["ok"] / n if n else 0.0

pre = [b for t, b in agg.items() if change is None or t + B <= change]
post = [(t, b) for t, b in agg.items() if change and t >= change // B * B]
if pre:
    ok, n = sum(b["ok"] for b in pre), sum(b["ok"] + b["failed"] for b in pre)
    print(f"before the change: {ok}/{n} ok ({100 * ok / max(n, 1):.1f}%)")
if post:
    worst = min(post, key=lambda tb: rate(tb[1]))
    under = sum(B for _, b in post if rate(b) < 0.5)
    rec = next((t for i, (t, _) in enumerate(post)
                if all(rate(b) >= 0.95 for _, b in post[i:i + 3]) and len(post[i:i + 3]) == 3), None)
    ok, n = sum(b["ok"] for _, b in post), sum(b["ok"] + b["failed"] for _, b in post)
    att = sum(b["attempts"] for _, b in post)
    print(f"after the change: {ok}/{n} ok ({100 * ok / max(n, 1):.1f}%), worst bucket {100 * rate(worst[1]):.0f}% "
          f"at +{worst[0] - change}s, {under}s under 50%, "
          f"{f'recovered (>=95% for 30 s) at +{rec - change}s' if rec is not None else 'NOT recovered'}, "
          f"attempts per request {att / max(n, 1):.2f}")
