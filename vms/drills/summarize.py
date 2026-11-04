"""Summarize a load.py log: totals, errors (with times and per minute), ReplicaSets seen over time.

Usage: python3 summarize.py <log> [since-epoch]"""
import collections, sys, time
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
since = float(sys.argv[2]) if len(sys.argv) > 2 else 0
rows = [r for r in rows if float(r[0]) >= since]
if not rows: sys.exit("no rows")
fmt = lambda t: time.strftime("%H:%M:%S", time.gmtime(float(t)))
t0, t1 = float(rows[0][0]), float(rows[-1][0])
ok = lambda r: r[2].startswith("200")
bad = [r for r in rows if not ok(r)]
print(f"requests {len(rows)} over {t1 - t0:.0f}s ({fmt(t0)}-{fmt(t1)}), errors {len(bad)}")
by = collections.Counter((r[1].rstrip("0123456789"), r[2]) for r in rows)
for k, v in sorted(by.items()): print(f"  {k[0]:>3} {k[1]:<22} {v}")
lat = sorted(int(r[3]) for r in rows if ok(r))
if lat: print(f"  latency ms p50 {lat[len(lat)//2]} p99 {lat[int(len(lat)*.99)]} max {lat[-1]}")
if bad: print(f"  errors from {fmt(bad[0][0])} to {fmt(bad[-1][0])}; longest gap with no 200:",
              f"{max((float(b[0]) - float(a[0]) for a, b in zip([r for r in rows if ok(r)][:-1], [r for r in rows if ok(r)][1:])), default=0):.1f}s")
rs = collections.OrderedDict()
for r in rows:
    if r[4] != "-":
        k = r[4].rsplit("-", 1)[0]; rs.setdefault(k, [r[0], r[0]]); rs[k][1] = r[0]
for k, (a, b) in rs.items(): print(f"  replicaset {k}: served {fmt(a)}-{fmt(b)}")
per_min = collections.OrderedDict()
for r in rows:
    m = time.strftime("%H:%M", time.gmtime(float(r[0])))
    per_min.setdefault(m, [0, 0]); per_min[m][1] += 1; per_min[m][0] += not ok(r)
if bad: print("  errors per minute:", " ".join(f"{m} {e}/{n}" for m, (e, n) in per_min.items() if e))
