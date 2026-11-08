# Drill: splitting the monolith

The shop's code could be moved in a week. What cannot be moved is a promise: `create_order` took stock and wrote the
order in one transaction, so the database guaranteed sold + stock = initial for free. This drill carves the monolith
into services, with customers shopping, and tests whether that promise survives once it crosses a network.

It runs on one cloud, the AWS lab, so nothing here is about where the app lives. Only its shape changes.

| Service | Owns | Why this order |
|---|---|---|
| `files` | `uploads` | The easy seam: no key, no shared transaction |
| `catalog` | `products`, `reservations` | The hard seam: stock was inside the order's transaction |
| `shop` (the monolith) | orders, customers, audit log | What is left. It shrinks, it is not rewritten |

`shop-edge` is the strangler: one address outside, moving one route at a time.

## The seams, found first

`migration-split-check.py` read the schema and code before any service existed, and named the three things that block this
split: the key `order_items -> products`, the statement in `/verify` that touches all three services, and the transaction in
`create_order`. `uploads` had none, which is why it went first.

## The same failure, two designs

Catalog commits, then 5% of its answers are lost, as with a timeout or a dropped connection. Nothing else is wrong.

| | Orders that succeeded | Stock wrong by | Products wrong |
|---|---|---|---|
| Naive: an HTTP call and a retry | **106 of 106** | **28 units** | **12** |
| Reservations with a key, plus 5 pods killed mid-request | 182 of 183 | 0 | 0 |

The naive split had a perfect success rate and silently corrupted stock. Nothing failed, no alert would fire, and it would
surface weeks later as a stock count that does not match. Each retry took the stock a second time, because the caller cannot
tell a lost answer from a failed write.

Reservations fix this with a key the caller chooses, so a retry changes nothing. A sweeper settles what a crash left pending
by asking the owner of orders whether the order exists. When the owner cannot answer, it holds: it logged `unknown` while
the monolith was down, and released the stock once it could tell.

## Result of the full journey

Files split, catalog split, catalog rolled back, all under load with 2% of catalog answers lost.

| | |
|---|---|
| Confirmed writes | 567 |
| **Lost or changed** | **0** |
| Stock drift, per product, at each step | 0 |
| Data checks during each freeze | all passed |
| File writes stopped | about 88 s, with orders still flowing |
| Orders refused, stock moving | about 65 s forward, 35 s back, with reads and uploads still flowing |

This is what a split gives that a move does not: a freeze stops one seam, not the shop. The times come from a shared laptop.
Of the file freeze, roughly 70 s was a restart of the files service that turned out not to be needed, because it opens a new
connection per request. It was left in so the script matches what ran.

The 111 refused requests fall mostly inside those freezes. The rest came from rolling restarts and lost answers: 17 were
connection failures while pods restarted.

## The split gate, on real runs (8 Nov)

`gate-run.sh <name>` collects every file `migration-cutover-gate.py --split` reads, from the drill itself: a baseline
snapshot, the split check with a decision per seam (`split-decisions.json`), an attack drill, a frozen per-item
reconciliation, the catalog move and rollback under load, and the restored check. `evidence.py` turns the load logs, the
load check, the orders' `created_at` and catalog's access log into JSON. Nothing is typed in by hand.

| | Run r2 | Run r3, rollback fixed |
|---|---|---|
| Attack: orders acknowledged / answers lost after commit / pods killed | 229 of 229 / 20 / 5 | 271 of 271 / 23 / 5 |
| Errored for the customer but committed | 0 | 0 |
| Reconciliation while frozen | 50 of 50 products | 50 of 50 products |
| Move and back under load: acknowledged, lost | 278, 0 | 306, 0 |
| Restored check against the baseline | **FAIL: `order_items_product_id_fkey` gone** | 11 of 11 |
| Gate | refused: restored, monitoring, approval | refused: monitoring, approval |

Run r2 is the 7 Nov bug caught: `split.sh catalog` drops the key to products before the data moves, and `catalog-back`
never put it back. Every other check passed, and the old shop would have run on without it. `catalog-back` now restores
it (`NOT VALID`, then `VALIDATE`, so no long lock under traffic) and r3 passes. Monitoring and approval stay refused: nobody
watched or approved a lab run, and the gate is right not to take the script's word for it.

The same reconciliation on the naive design, 60 s with 5% of answers lost: 252 of 253 orders succeeded, and 15 of 50
products drifted, 50 units in all. `migration-reconcile` names each one.

Each run moves catalog into a database of its own (`CATALOG_DB=catalog_<run>`): `split.sh` reuses a database that already
has tables, and the last run's copy is stale. The move now proves `catalog-next` can do its job on its own database first:
it reads products and holds the grants it needs, without writing to the target before cutover.

## And back: the services into the monolith (8 Nov)

`merge-run.sh <name>` runs `merge.sh catalog` then `merge.sh files` with customers shopping and reading their uploads back.
The shop ends as one deployment, in one transaction, with catalog, its sweeper and files at 0 replicas as the way back.

| | |
|---|---|
| Orders acknowledged | 441 of 451, and 441 new orders in the database: nothing committed behind an error |
| Uploads acknowledged, read straight back | 70 of 77, 70 of 70 read back |
| **Lost or changed** | **0** |
| Data check of `uploads` during the freeze | passed |
| Per product, writes frozen | 50 of 50 match |
| Merged schema against the monolith before the split | 11 of 11: every key and index is back |

What a merge has to undo, found by reading before running:
- **The split took rights away.** The monolith's role kept only `SELECT` on `products` and had lost `INSERT` on `uploads`. Switching
  back without granting them would have failed every order and every upload, with health green.
- **Pending reservations must settle first.** Catalog and its sweeper retire only once nothing is pending.
- **Prove the monolith can read what the service stored.** The 5 newest uploads, written by the files service, were served by the
  monolith with the right bytes before any traffic moved.

What went wrong: **each rolling restart of the shop dropped orders.** 5 orders failed with a 502 in each of the two restarts (one
for the order mode, one for the files link). The shop has no preStop drain, so a pod stops while traffic still reaches it. The 7
refused uploads all fall inside the 7 s file freeze, as designed.

Not tested: going back out to the services after the merge. The files database is read-only and replicating, and the
deployments are at 0, but that path has not been run.

## What went wrong on the way

| Trap | What happened |
|---|---|
| Silent corruption | Above. A success rate says nothing about whether a retry was safe |
| Retries outlasted the caller | 3 tries of 2 s against an edge that gives up at 5 s. Customers got an error while orders kept committing: 21 acknowledged, 40 in the database, and only 21 of 102 succeeded. A shared budget of 3 s took that to 182 of 183 |
| A repair during traffic | Recomputing stock while an order was in flight created drift of its own, and spoiled that run. It was thrown away |
| One statement became three calls | `/verify` now reports `catalog unavailable` when catalog is slow. It used to be one query that could not partly fail |

Expected, and it did not happen: a read from the new service missing an upload made a moment earlier. 127 uploads were
read straight back and none came back missing, so replication outran the customer here. That is a property of one laptop. On
a real replica this can happen, and the edge keeps a fallback to the old service for it.

## Not tested

- Real networks. Everything shares one host, so latency, partitions and real timeouts are simulated at best.
- Several services' worth of size. One database cluster holds all three databases, on one laptop.
- Contract: the old `uploads` table and the monolith's unused code are still there. Removing the old path is its own risky
  step and has not been rehearsed. (The key to `products` the 7 Nov rollback left dropped is restored now: see above.)
- Going forward again after the catalog rollback.
- Customers retrying. `load.py` never retries an order, so a customer who resubmits after a timeout can still order twice.
- An order can still commit while the customer gets an error, if a pod dies at that moment. This drill did not measure how
  often. Only an idempotency key from the client would close that.
- An ORM. The seam check finds SQL by shape and refuses a codebase where it finds none.
- Monitoring. `/verify` is a check the drill runs, not an alert. Real use needs drift as a metric.
- The cutover gate was not run on this drill. Its evidence is written for a whole-system move.

## Run it

Needs the AWS lab running and shop 1.2.1 built from `apps/shop`.

```bash
bash edge.sh start
bash setup.sh                  # additive only: the monolith still does everything
bash experiment.sh naive       # lost answers, a call and a retry
bash experiment.sh saga        # the same, with reservations and pods killed
python ../onprem-to-aws/load.py run --url http://127.0.0.1:18080 --seconds 900 --read-back --out run.jsonl &
bash split.sh files
bash split.sh catalog
bash split.sh catalog-back
python ../onprem-to-aws/load.py check --url http://127.0.0.1:18080 --log run.jsonl
```

`experiment.sh` repairs stock before it starts and refuses to run while a load generator is alive.
