# slanginx M1 — delivery note

Milestone: G1/G2/G3 std-face backfill, reverse proxy / upstream
core, handler model A + shared dict. Base: M0 `1b197af`.
Toolchain: sa 0.1.8 + SLA plugin (dev mode), sa_std from sci
`28fd2ceb`. All live evidence produced on the Colab box
(host `2d60bdf6bf1a`), loopback only.

## 1. G1 / G2 / G3 backfill (before → after)

The three std faces were verified on the box against the
installed sci `.sai` declarations before use (never from
memory):

- G1 `@extern sa_http_server_resp_send_head_v2(resp: ptr,
  content_length: u64, timeout_ms: u32) -> u32`
- G2 `@extern sa_http_server_req_peer_addr_v2(req: ptr,
  &out: ptr, out_cap: u64, &out_len: ptr, &out_port: ptr)
  -> u32` (too-small buffer → status 4 with the needed length)
- G3 `@extern sa_std_net_tcp_stream_send_file(stream, file,
  offset, count, &out_sent, &out_next_offset)` — **net layer
  only**; see G3′ below.

| item | M0 (before) | M1 (after), measured |
|---|---|---|
| HEAD wire shape | `curl -sI` showed `transfer-encoding: chunked`, empty chunked body, no content-length — "protocol-valid, the resource's length unknowable" | `content-length: 32` on `HEAD /hello.txt`; acceptance run 1 asserts the header + zero body bytes |
| access-log remote | hardcoded `-` in every line | real peer: log line `127.0.0.1 GET /hello.txt 200 32 …` asserted by run 1 |
| code-layer ACL | compiled + unit-tested, "cannot be wired to live requests" | evaluated live per request: peer → `config_acl_allows`; denied → 403 before resolution; a peerless request skips the ACL (remote `-`), documented in `src/main.sla` |
| static send path | buffered whole-file read; "no sendfile exists in sa_std" | **unchanged — G3′**: the net-layer `send_file` needs a raw stream, and the HTTP server face exposes no stream/fd accessor for a live request handle, so the static path cannot reach it. Seam marked with a TODO comment at the static send site in `src/main.sla` |

## 2. Reverse proxy / upstream core

Declarative layer (TOML, parsed total — any malformed entry is
a startup error rc 3, never a silent skip):

```toml
[upstream.0]
name = "api"
servers = "127.0.0.1:19001, 127.0.0.1:19002"

[route.0]
prefix = "/api/"
upstream = "api"
```

- Routing: longest-prefix match over the decoded path; the
  full path is forwarded unchanged (nginx `proxy_pass` without
  a URI part).
- Selection: round-robin per pool, cursor in a shared dict
  zone (handler model A); on transport failure the next server
  is tried, and only when the whole pool fails is the error
  mapped.
- Request headers forwarded by name (the server face has no
  header enumeration): accept, accept-language,
  accept-encoding, authorization, content-type, cookie,
  referer, user-agent — plus `X-Forwarded-For` (client value
  extended with `, <peer>`), `X-Real-IP: <peer>`,
  `X-Forwarded-Proto: http`.
- Request bodies: read in full via the v1 body reader and sent
  with the request (the client face takes a whole-body buffer;
  a body larger than memory is therefore a deployment limit,
  stated here rather than hidden).
- Response relay: status verbatim; headers content-type,
  cache-control, etag, last-modified, expires, location,
  www-authenticate, set-cookie, retry-after; GET bodies are
  streamed upstream→client in 4 KiB chunks through the v1 body
  reader on the v2 response (client-v2-send / v1-getter
  interop probe-verified live before use). HEAD is fetched
  upstream as GET and relayed as headers only — see D6.
- Error mapping, all explicit: send status 3 (timeout) →
  **504** `gateway timeout`; any other transport failure →
  **502** `bad gateway`; upstream HTTP statuses (404 etc.)
  relayed as-is. No defaulting, no masking.
- Statistics: when a zone named `stats` is declared, per-pool
  `<pool>/requests` and `<pool>/errors` counters increment per
  proxied request; `GET /__slanginx/status` (code-layer route)
  renders them plus per-zone key counts.

Live evidence — acceptance run 4 (two fixture upstreams A/B on
19001/19002, one dead pool on 19999), 17/17 checks:

```
PASS proxy GET /api/hello -> upstream A (round-robin first pick)
PASS proxy GET /api/hello -> upstream B (round-robin second pick)
PASS proxy echo: method forwarded
PASS proxy echo: full path forwarded (query: see G4)
PASS proxy echo: x-forwarded-for carries the peer (G2)
PASS proxy echo: x-real-ip carries the peer
PASS proxy echo: accept-language forwarded
PASS proxy POST: method forwarded
PASS proxy POST: content-type forwarded
PASS proxy POST: body forwarded byte-exact
PASS proxy relays upstream 404 with its body
PASS proxy HEAD: upstream content-length preserved (G1 relay)
PASS proxy dead upstream -> explicit 502 bad gateway
PASS status route answers
PASS status: dead pool counted 1 request 1 error (shared dict)
PASS status: api requests increments per proxied request (6 -> 7)
PASS proxy access log: real peer + upstream body bytes
```

## 3. Handler model A + shared dict

Ruling: `docs/HANDLER_MODEL.md` (user-approved 2026-10-28,
Jev jev-1.14.0: A p=1.0 / B p=0.0 / C p=0.0). Model B is not
merely unchosen but impossible at the SLA layer — SLA's
`Mutex<T>` accepts scalar payloads only (measured on the
slaredis M0 line), so no `Mutex<Struct>` shared-state design
can be written; model C needs a prefork primitive sa_std does
not expose.

Implementation (`src/shared_dict.sla`), on sa_std named global
cells (`sa_global_*`: process-wide, std-mutex-guarded):

- Zones declared as `[shared_dict.N] name + capacity`;
  duplicate names / bad declarations are startup errors.
- API: `dict_set` / `dict_get` (bytes), `dict_incr` /
  `dict_get_num` (u64), with logical TTL in seconds — expiry is
  evaluated on read (expired reads as missing), because the
  std face has no delete for bytes cells; the slot is reclaimed
  by the next overwrite. Stated plainly, not hidden.
- Capacity counts distinct live bytes-facet keys; a set that
  would exceed it returns explicit DICT_FULL — keys are never
  evicted to make room ("no silent fallback" rule).
- u64 cells cannot expire (no per-cell TTL primitive for them)
  — counters and cursors are permanent by design; documented
  in the module header.
- Cell names are `sd/<zone>/<key>`; keys starting with `#` are
  reserved (`#n` count cell, `#e` expiry suffix) and rejected.

Unit evidence: `tests/shared_dict_test.sla` 7/7 (set/get
round-trip, missing, TTL expiry, capacity FULL, incr from
unset, zone isolation, bad-key rejection).

## 4. Test name sets (regression gate)

Unit tests — M0 baseline vs M1, compared by name set:

| file | M0 | M1 |
|---|---|---|
| tests/webpath_test.sla | 8/8 pass | 8/8 pass (identical names) |
| tests/config_test.sla | 4/4 pass | 4/4 pass (identical names) |
| tests/upstream_test.sla | — | 4/4 pass (new) |
| tests/shared_dict_test.sla | — | 7/7 pass (new) |

Live acceptance (`scripts/acceptance.sh`): M0's 28/28 checks
preserved (runs 1–3, now 30 checks with the G1 content-length
and G2 real-peer assertions added) and run 4 adds the 17 proxy
checks: **47 PASS / 0 FAIL** total.

## 5. Benchmark gate vs native nginx

Method and scripts: `scripts/bench/` (nginx 1.24.0 (Ubuntu)
from apt; wrk 4.1.0; same box, serial; c = 1/10/50; 1 warmup +
3 measured rounds of 5 s, median; nginx `worker_processes
auto` + `sendfile on`, access log off — slanginx's access log
stays on, an asymmetry disclosed in the bench README).
Threshold T50: per row, slanginx rps ≥ 0.5 × nginx rps and
slanginx p99 ≤ 2 × nginx p99; a scenario passes only if all
its tiers pass.

Measured 2026-10-28 on the bench box (snapshot:
`scripts/bench/results-20261028.tsv`):

| scenario | c | nginx rps | slanginx rps | ratio | nginx p50 | slanginx p50 | nginx p99 | slanginx p99 | p99 ratio | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| small | 1 | 18435.89 | 5068.51 | 0.275 | 0.045ms | 0.194ms | 0.171ms | 0.285ms | 1.67 | FAIL (rps) |
| small | 10 | 100423.41 | 5383.99 | 0.054 | 0.090ms | 0.821ms | 0.225ms | 1.91ms | 8.49 | FAIL (both) |
| small | 50 | 132761.22 | 5989.59 | 0.045 | 0.243ms | 0.420ms | 2.41ms | 1.21ms | 0.50 | FAIL (rps) |
| large | 1 | 11134.22 | 2962.98 | 0.266 | 0.085ms | 0.315ms | 0.156ms | 0.542ms | 3.47 | FAIL (both) |
| large | 10 | 36477.67 | 914.13 | 0.025 | 0.197ms | 1.44ms | 0.427ms | 5.62ms | 13.16 | FAIL (both) |
| large | 50 | 37181.69 | — | — | 0.699ms | — | 1.92ms | — | — | FAIL (process dead) |
| proxy | 1 | 2197.04 | 999.26 | 0.455 | 0.446ms | 0.990ms | 0.717ms | 1.32ms | 1.84 | FAIL (rps) |
| proxy | 10 | 2462.87 | 1002.47 | 0.407 | 2.57ms | 2.00ms | 1130ms | 2.46ms | 0.002 | FAIL (rps) |
| proxy | 50 | 2429.85 | 989.99 | 0.407 | 2.53ms | 2.00ms | 1170ms | 2.63ms | 0.002 | FAIL (rps) |

**BENCH GATE: FAIL — all three scenarios fail T50.** Per the
gate rule, M1 is therefore *not* accepted on performance, and
this line does not paper over the gap: what follows is the
measured attribution, with minimal repros, for the SA/SLA
improvement line. (The slanginx proxy rows were measured in an
addendum run with a fresh process under the identical method —
the bench-run process was already dead, see F1. The proxy
p99 "passes" at c=10/50 are an artifact of nginx's p99 being
poisoned by the fixture, see F4; the rps failures are real.)

### Findings (attribution, measured)

- **F1 (sa_std, critical — stability, not just speed):
  per-request memory in both HTTP faces is never reclaimed.**
  Controlled slope experiment (keep-alive driver, RSS from
  /proc, repro `docs/repro/server_rss_slope.py`): server face
  grows **~29 kB per request fixed + ~1x the response body**
  (300x32 B: +8,720 kB; 300x210,000 B: +70,136 kB), although
  the application frees its file buffer every request. Client
  face, isolated (repro
  `docs/repro/client_loop_memory_growth.sla`: a bare loop of
  client GETs, every handle freed): RSS climbed ~70 MB →
  ~739 MB over 8,000 requests (~120–250 kB/request). In the
  bench, the slanginx process was **OOM-killed at 41.7 GB
  anon-RSS** (kernel log) during the large c=10 cell, its rps
  degrading round over round (1351 → 914 → 634) as memory
  pressure built; the proxy cells of a fresh process grew RSS
  9.9 MB → 16.75 GB over ~60k small-body exchanges
  (~280 kB/proxied request across both faces). Consequence: no
  server on these faces survives sustained load at all. This
  is the first thing the improvement line must fix, ahead of
  any throughput work.
- **F2 (process model — application layer, slanginx's own
  later milestone): serialization ceiling.** slanginx rps is
  flat against concurrency (small: 5,069 / 5,384 / 5,990 at
  c = 1/10/50; proxy: ~1,000 at every tier) because the M0
  process model is one sequential loop; nginx scales
  18k → 133k with workers. The ceiling is exactly
  1 / per-request service time (~197 µs static-with-log,
  ~1 ms proxy). The std face does offer a threaded serve
  entry, so this is addressable in a future slanginx milestone
  under handler model A — but only after F1, since threads
  would multiply the leak rate.
- **F3 (sa_std per-request costs):** strace profile of the
  static path (c=1, counts divided by the 1,513 requests in
  the window): **~29 syscalls/request**, including 2x openat +
  2x statx + 2x lseek + 2x close (the data file and the log
  file are each opened fresh per request through the fs
  layer), 3x setsockopt, 5x poll, 1x mmap per request. Two
  quantified components: (a) the access log's per-request
  open/write/close costs **~53 µs/request ≈ 27% of service
  time** (attribution-only variant with the log redirected to
  /dev/null: 6,929 rps vs 5,069 — measured for attribution,
  NOT a gate run; the gate numbers above are with the log
  on); (b) no server-face send-file shape (G3′) forces
  open/read/userspace-copy/write for every static response
  instead of one sendfile. (An nginx strace profile is not
  quoted: attaching to the master does not capture its
  pre-forked workers, and this note does not fabricate one.)
- **F4 (method caveat):** the proxy scenario's upstream is
  the shared Python fixture; it caps both servers (via nginx:
  2.2–2.5k rps) and its direct numbers carry a constant
  ~41 ms Nagle-style artifact (p50 41.0 ms at every tier;
  direct c=1: 24.5 rps). The T50 comparison is relative and
  unaffected, but absolute proxy ceilings here are
  fixture-bound, not a property of either server.

Net shape of the gap: F1 is a std-face lifecycle defect
(blocking), F3 is std-face per-request overhead, F2 is the
application's known M0 process model. None of the three is
addressed by application-layer tuning, and none was.

## 6. Registered defects and gaps found this milestone

> Addendum (improvement line, 2026-10-29): D6, G4, G5 and
> G3′ from this section are **closed**, and F3 (§5) is done;
> root causes, fixes and regression evidence are recorded in
> `docs/IMPROVE_DELIVERY.md`. The registrations below are the
> original M1 text, kept for the record.

All registered with minimal repros; none fixed in this line
(sci / sa_plugin_sla are owned by other lines; this line
registers and works around explicitly). The performance
findings F1–F4 from the bench gate are registered in §5 with
their repros (`docs/repro/server_rss_slope.py`,
`docs/repro/client_loop_memory_growth.sla`).

- **D6 (sa_std defect, severity: crash)** — the HTTP client's
  HEAD send segfaults (signal 11 inside
  `sa_http_client_req_send_v2`, against a trivial HEAD-capable
  upstream; the identical GET flow passes). Repro:
  `docs/repro/client_head_send_segfault.sla`. Impact: crashed
  the slanginx server process mid-acceptance on the first
  proxied HEAD. Workaround in `src/proxy.sla`: HEAD is fetched
  upstream as GET; headers + content-length are relayed via
  the head response shape and the body is discarded unread —
  the client-visible HEAD response is exact.
- **G5 (sa_std gap)** — a `user-agent` set via the client
  face's add-header never reaches the wire; upstreams see
  std.http's own `zig/<ver> (std.http)`. The wrapper has no
  user-agent handling and the `.sai` no setter. Pinned by
  `docs/repro/user_agent_header_not_forwarded.sla` (passes
  while the gap exists). slanginx keeps user-agent in its
  forward list — forwarding starts working the day the face
  honors it; acceptance asserts a control header
  (accept-language) instead.
- **G4 (sa_std gap)** — query strings are not exposed by the
  server face: `req_get_path` returns the path only (grep
  `query` in the runtime's server source: zero hits). Proxied
  requests therefore forward the path without the query.
  Acceptance asserts the path and records the gap; query
  forwarding returns when a raw-target getter exists.
- **G3′ (sa_std gap)** — see §1: net-layer `send_file` exists,
  no server-face stream accessor; static serving stays
  buffered.
- **D5 (SLA/SAB referee quirk)** — repeating
  `PTR_BYTE_ADD(&local_array, 0)` inline at several call sites
  in one function traps UseAfterMove (1009) at SAB lowering;
  binding the pointer once and reusing it passes. Minimal
  pair measured (inline form fails, bound form passes).
  Repro: `docs/repro/ptr_byte_add_inline_repeat.sla`. The
  bind-once shape is the house idiom throughout this repo.

## 7. Commits

Local commits on top of M0 `1b197af` (not pushed; no remote
branches, per the workspace rule):

- `8fcf084` M1: handler model A ruling + shared dict zones
- `571afc9` M1: reverse proxy + upstream pools
- `9844283` M1: G1/G2 backfill, live ACL, status route,
  acceptance run 4
- `d35952c` M1: bench gate assets — same-machine comparison
  vs native nginx
- `46f76c4` M1: minimal repros for the registered defects
- the delivery-docs commit carrying this note, the README M1
  update, and the refreshed `docs/acceptance_run.log`
  (47 PASS / 0 FAIL, this final tree)
