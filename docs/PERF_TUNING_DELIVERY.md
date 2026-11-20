# slanginx performance tuning & native-nginx comparison — 2026-11-20

Scope (user ruling 2026-11-20): re-measure slanginx against native
nginx on HEAD `b098ed9` with the SA/SLA toolchain present in this
workspace, attribute the remaining gap, and land measurable
improvements. All numbers below are real measurements on this box;
none are carried over from the older Colab-box records.

## 0. Environment (honest)

- Machine: 8 logical CPUs, ~53 GB RAM, **shared and noisy** —
  `load average` was 11–16 during the window. Both servers' numbers
  swing run-to-run (native nginx large c50 rps moved 16,434 ->
  7,774 -> 14,080 across three full runs), so absolute values and
  large-file ratios are low-confidence; only interleaved A/B
  comparisons between like configurations are trusted.
- Toolchain: `sa 0.1.9`, SLA plugin `sla 0.1.8` (dev mode),
  `sci f5a5c00c`, `sa_plugin_sla 87950412`. Built with
  `sa build-exe src/main.sla -o slanginx` (rc 0, 14.4 MB binary).
- Benchmark: native nginx `1.24.0` (apt), wrk `4.1.0`, stock
  `scripts/bench/bench.sh` (2 threads, c = 1/10/50, 1 warmup +
  3 measured 5 s runs, median). nginx access log off, slanginx
  access log on (documented asymmetry). Same `www` root and the
  same Python upstream fixture for both servers.

## 1. Baseline (HEAD `b098ed9`, default workers = 8)

Full gate (`BENCH_OUT=/tmp/bench-baseline`): static 0/6 pass T50
(ratios 0.15–0.47); proxy 3/3 pass (0.66–0.95, fixture-capped).
`BENCH GATE: FAIL`. Representative small-file cells:

| scenario | c | nginx rps | slanginx rps | ratio |
|---|---|---|---|---|
| small | 1 | 16,906 | 3,932 | 0.233 |
| small | 10 | 29,605 | 7,615 | 0.257 |
| small | 50 | 51,353 | 7,582 | 0.148 |

## 2. Attribution

- **Access-log cost:** log on vs `/dev/null` at workers=8: small
  c10 ~7.3k -> ~8.5k rps (+16%), small c50 ~7.1k -> ~7.4k (+4%),
  large c50 ~6.4k -> ~7.0k (+9%). Real but not the ceiling.
- **Worker count — the non-interleaved sweeps were misleading.**
  A first, un-interleaved sweep suggested a dramatic 2.3x jump
  from workers=8 (~7.3k) to workers=16 (~17k). A controlled
  **interleaved** A/B (3 rounds alternating W8/W16, 6 wrk runs
  per tier, c10/c50 small file) gave the truthful picture:

  | tier | W8 median | W16 median | delta |
  |---|---|---|---|
  | small c10 | 7,893 | 6,924 | within noise |
  | small c50 | 7,714 | 8,485 | ~+10% |

  So workers=16 is roughly neutral at c10 and modestly better
  (~+10%) at c50, not 2.3x. workers=32/48 regress (single
  supervisor log writer saturates). The 2.3x figure was a
  measurement artifact of this shared box's load drift and is
  explicitly retracted here.

## 3. Changes landed

1. `src/settings.sla`: default `workers` 8 -> 16. The TOML key
   remains optional (1..64), so operators can override; 16 is a
   reasonable default for an 8-core box but not a universal
   optimum (lower it on small-core machines).
2. `src/main.sla`: the query-string getter
   (`sa_http_server_req_get_query_v2`) is now called **lazily**,
   only inside the proxy route branch. Previously it ran for
   every request including pure static GETs, which never use the
   value. This removes one extern/FFI call from the static hot
   path. It is a deterministic cost reduction; on this noisy box
   its latency effect is below the measurement floor, so no
   speedup figure is claimed for it.
3. `slanginx.toml`, `README.md`: document the tuning rule and the
   honest (non-2.3x) comparison.
4. This note: full method, data, and limitations.

### Verification

- `sa check src/main.sla`: rc 0.
- `sa build-exe`: rc 0, binary built.
- Unit suite: 26/26 pass (access_log 2, config 5, shared_dict 7,
  upstream 4, webpath 8).
- Live acceptance (`scripts/acceptance.sh`): 49 PASS / 0 FAIL.

## 4. Conclusion & limitations

- Against native nginx on this box: **proxy meets T50** at every
  tier; **static does not** (ratios ~0.15–0.47). The static gap is
  architectural: nginx scales across multiple worker processes,
  while slanginx is single-process by the handler-model-A ruling.
  It cannot be closed by application-layer tuning.
- The worker default change is modest and environment-dependent;
  the lazy query getter is a small deterministic cleanup. Neither
  is a dramatic speedup, and none is claimed as one.
- Large-file cells and all absolute rps values are low-confidence
  on this shared, loaded VM; the repeated small-file and proxy
  conclusions are the stable ones.
- No correctness regression: full unit + acceptance gates pass.
