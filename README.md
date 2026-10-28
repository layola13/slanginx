# slanginx

An SLA-native web server — an nginx-class static/reverse-proxy
server written entirely in SLA on the SA standard library. The
design record is the sala planning page
`content/01_overview/09_nginx_rebuild_roadmap.html` (the project
was renamed from the working name on that page to the repository
name, slanginx).

## M1 status (this delivery)

Everything from M0, plus (details and measured evidence in
`docs/M1_DELIVERY.md`):

- **Reverse proxying**: upstream pools and proxy routes in the
  declarative layer (`[upstream.N]` / `[route.N]` in the TOML),
  longest-prefix routing, round-robin server selection,
  request-header forwarding (incl. `X-Forwarded-For` /
  `X-Real-IP` from the real peer address), response-header
  relay, chunked-streamed GET bodies, exact explicit errors:
  upstream transport failure → **502**, upstream timeout →
  **504**, upstream HTTP statuses relayed verbatim. No silent
  fallbacks anywhere.
- **Backfilled std faces** (delivered by the sa_std line into
  sci, consumed here): HEAD responses carry the real
  content-length (head response shape); the access log's remote
  field is the real peer address and the code-layer ACL is
  evaluated live per request; dedicated status route
  `GET /__slanginx/status` reporting per-pool request/error
  counters.
- **Handler / shared-state model A** (ruling recorded in
  `docs/HANDLER_MODEL.md`): handlers hold no global mutable
  state; the only cross-request state is configuration-declared
  **shared dict** zones (`[shared_dict.N]`, `src/shared_dict.sla`)
  backed by sa_std named global cells — explicit get/set/incr
  with logical TTL, explicit FULL when a zone's capacity is
  exhausted (never eviction), backing the proxy statistics and
  the status route.
- **Benchmark gate vs native nginx** (see `scripts/bench/`):
  same-machine wrk comparison — static small file, static large
  file, reverse proxy — against the T50 thresholds (throughput
  ≥ 50% of nginx, p99 latency ≤ 2x nginx). The measured table
  and per-scenario verdicts are in `docs/M1_DELIVERY.md`.

Still true from M0: static file serving over the sa_std
built-in HTTP/1.1 server face (GET/HEAD, byte-exact bodies,
404, MIME by extension, index files, path-traversal containment
with explicit 403), the two-layer configuration (declarative
TOML + typed code layer in `src/config.sla` with the
`/internal/` deny rule and the `/assets/` alias), the access
log (one line per request, real peer since M1), and the
process model: single process, sequential accept loop.

## Registered gaps (M1)

Closed by the improvement line (see
`docs/IMPROVE_DELIVERY.md` for root causes, fixes and the
regression evidence):

- **G3′ — server-face send-file** ✓: the HTTP server face
  grew `sa_http_server_resp_send_file_v2`; static serving is
  sendfile end to end, with an explicit logged 500 (never a
  silent buffered fallback) on platforms without sendfile.
- **G4 — query strings exposed** ✓: the server face grew
  `sa_http_server_req_get_target_v2` / `req_get_query_v2`;
  the proxy forwards the query byte-exact.
- **G5 — client `user-agent` honored** ✓: the client routes
  the slotted standard headers (user-agent among them) into
  std's header slots as overrides, on both send paths.
- **D6 — client HEAD segfault** ✓: root-caused to reading a
  body through std's shared read-only `Io.Reader.ending`
  singleton; the client no longer reads a body for HEAD/TRACE.
  The proxy fetches HEAD as HEAD again.

Still open:

- **D5 — referee quirk**: repeating `PTR_BYTE_ADD(&local, 0)`
  inline at several call sites traps UseAfterMove; the house
  idiom binds the pointer once. Repro in `docs/repro/`.
- Directory requested without a trailing slash is served its
  index directly; nginx's 301 redirect is not issued.
- TLS/HTTP2 termination, rate limiting and caching remain
  later milestones (M2–M3 on the planning page), as is the
  VM-plugin extension model.

## Layout

```
src/main.sla        server entry: accept loop, dispatch, sending
src/settings.sla    declarative layer: TOML -> all sections
src/config.sla      code layer: deny rule, assets alias, ACL
src/webpath.sla     percent-decoding, normalization, traversal
                    containment, MIME table
src/upstream.sla    upstream pools, routes, round-robin pick
src/proxy.sla       reverse-proxy exchange with the upstreams
src/shared_dict.sla shared dict zones (handler model A)
src/access_log.sla  access-log line format + append
src/numfmt.sla      decimal formatting helper
tests/              @test unit tests (webpath, config,
                    upstream, shared_dict)
scripts/acceptance.sh  live curl acceptance (four runs, incl.
                    a real two-upstream proxy run)
scripts/upstream_fixture.py  trivial upstream used by the
                    acceptance and the bench
scripts/bench/      nginx comparison gate (method + scripts)
www/, www-assets/   sample roots used by the acceptance
slanginx.toml       sample declarative configuration
docs/M0_DELIVERY.md M0 delivery note with measured evidence
docs/M1_DELIVERY.md M1 delivery note with measured evidence
docs/HANDLER_MODEL.md handler/shared-state model ruling (A)
docs/repro/         minimal repros for the registered defects
```

## Build and run

Requires the SA toolchain (`sa` + the SLA plugin) on PATH:

```
sa check src/main.sla
sa build-exe src/main.sla        # produces src/main
cp src/main ./slanginx
./slanginx                       # reads ./slanginx.toml
```

The config path can be overridden with the `SLANGINX_CONFIG`
environment variable. Tests and acceptance:

```
sa test tests/webpath_test.sla
sa test tests/config_test.sla
sa test tests/upstream_test.sla
sa test tests/shared_dict_test.sla
bash scripts/acceptance.sh
bash scripts/bench/bench.sh      # needs apt nginx + wrk
```
