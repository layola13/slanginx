# Benchmark gate: slanginx vs native nginx

The M1 acceptance gate (user ruling 2026-10-28 19:29; threshold
via Jev jev-1.14.0, option T50 at p=0.56): slanginx is accepted
only if, **per scenario**, its throughput is at least **50% of
native nginx** and its **p99 latency is at most 2x nginx's**.
Any scenario failing means the milestone is not accepted; the
gap is then attributed with measurements and handed to the
SA/SLA improvement line — never papered over at the app layer.

## Method

- One machine (the Colab box), both servers run serially in the
  same bench session; nothing else heavy runs concurrently
  (bench.sh warns if a `zig build` is active).
- Native nginx comes from apt (version recorded in the
  delivery doc), configured by `nginx-bench.conf.tmpl`: stock
  shape (`worker_processes auto`, `sendfile on`), same `www`
  root as slanginx, `location /api/` proxying to the same
  trivial upstream. Its access log is off; slanginx's access
  log stays on (it is part of the product; the asymmetry is
  disclosed in the delivery doc, not hidden).
- slanginx runs with `slanginx-bench.toml` (same root, route
  `/api/` to the same upstream, stats zone declared).
- Upstream for the proxy scenario is the acceptance fixture
  (`scripts/upstream_fixture.py`, a threaded Python HTTP
  server). Its own direct throughput is measured too, as the
  scenario's ceiling.
- Tool: `wrk`, 2 threads, concurrency tiers c = 1 / 10 / 50,
  `BENCH_DUR` seconds per run (default 5s). Each cell: one
  warmup run (discarded), three measured runs, median reported.
- Scenarios: `small` = GET /hello.txt (32 B static), `large` =
  GET /big.txt (210,000 B static), `proxy` = GET /api/hello
  through each server to the fixture.
- Verdict per (scenario, tier) row; a scenario passes only if
  all its tiers pass; the gate passes only if all scenarios
  pass. Results land in the M1 delivery doc (numbers, ratios,
  verdicts) and a snapshot TSV (`results-20261028.tsv`,
  regenerated per bench session).

## Rerun

```
# on the box, from the repo root, with ./slanginx built:
apt-get install -y nginx wrk   # once
bash scripts/bench/bench.sh
```
