# slanginx improvement line — delivery record

Scope (user sequence, 2026-10-29): after the db line closed,
close the five items registered against M1 — D6, G4, G5, F3,
G3′ — code only. **No performance numbers were measured on
this line** (the local VM is a 2-core sandbox instance; all
bench/99% re-verification is deferred to the Colab box
recovery, per the line's charter). Nothing below cites an old
number as a new result.

Work landed in two staging trees, local commits only:

- `sci-httpfix-local` (sa_std fixes; base = the int3
  integration tip `220dabe7`): the four std-face items
  (D6, G5, G4, G3′) live here, because all four defects/gaps
  are sa_std's, registered as such in M1.
- this repo (base `59808d8` = pushed M1 main): F3, the proxy
  and static-path wiring for D6/G4/G3′, acceptance checks.

## D6 — client HEAD segfault in `req_send_v2` ✓

**Root cause.** For a HEAD response, `std.http.Client`'s
`Response.reader()` returns the process-wide
`Io.Reader.ending` singleton — `@constCast(&ending_instance)`,
a pointer to a **const global that lands in `.data.rel.ro`**.
`Io.Reader.readSliceShort` writes the reader's `seek` field
through that pointer. In binaries linked by `zig cc` (LLD —
exactly how SA test/exe binaries are linked) the RELRO
segment is mapped read-only after relocation, so the write
segfaults; in Zig-self-hosted-linked test binaries the same
global happens to sit in writable memory, which is why the
defect never reproduced at the Zig test level. The wrapper's
read loop in `executeRequestV2` (and the identical loop in
the v1 `httpRequestExecOnce`) called `readSliceShort` on that
reader for every HEAD/TRACE response.

**Fix** (sci `src/runtime/sa_http_client.zig`): skip the body
read loop entirely when `method.responseHasBody()` is false
(HEAD, TRACE) — the body is empty by definition, and the
ending reader is never touched. Both the v2 and v1 paths.

**Evidence.** The M1 repro `docs/repro/client_head_send_segfault.sla`
died with signal 11 before the fix and passes after (kept as
the standing regression; its header carries the root cause).
New Zig tests pin the semantics at both faces:
`http client v2: HEAD against keep-alive upstream returns
empty body promptly (D6)` and the v1 twin — status 200, empty
body, upstream `Content-Length: 22` preserved, return well
before the handler's 3 s keep-alive hold expires. Crash
forensics (marker bisection + a ptrace catcher + symbolized
backtrace `_saasm_test_0 → sa_http_client_req_send_v2 →
executeRequestV2 → Io.Reader.readSliceShort`, faulting store
`mov %rdx,0x18(%rax)` with rax = the ending singleton) are
summarized in the fix commit message.

## G5 — client `user-agent` never reached the wire ✓

**Root cause.** The wrapper passed every caller header to
std via `extra_headers`. std's `Request.Headers` has slotted
fields (host, authorization, user_agent, connection,
accept_encoding, content_type) whose defaults are emitted
**before** extra headers, so a caller `user-agent` in
extra_headers was shadowed/duplicated by std's own
`user-agent: zig/<ver> (std.http)`.

**Fix**: `splitStdHeaders` in `sa_http_client.zig` routes the
six slotted names (case-insensitive, last wins) into the
slots as `.override` and leaves the rest as extra headers;
wired into both send paths (v1 and v2).

**Evidence.** Wire-level: Zig tests with an echo handler —
`http client v2: add_header user-agent reaches the wire
(G5)`, the v1 twin, and `http client v2: unset user-agent
keeps the std default (G5)` (documents what used to shadow).
SLA-level: the M1 pinning repro
`docs/repro/user_agent_header_not_forwarded.sla` failed with
its gap-panic 705 after the fix (the header now arrives) and
was inverted in place into the standing regression.
Acceptance run 4 now asserts the proxied echo carries
`user-agent proxy-check/1.0`.

## G4 — server face exposes the query string ✓

**Fix** (sci `src/runtime/sa_http_server.zig` +
`sa_std/http_server.sai`): the request already stored the
raw target; two getters were missing.
`sa_http_server_req_get_target_v2` returns it verbatim;
`sa_http_server_req_get_query_v2` returns the bytes after
the first `?` (absent → ok, length 0). In this repo,
`proxy_serve` takes the query from `handle_request` and
appends `?` + query to the forwarded target byte-exact
(never decoded/re-encoded; no `?` when absent).

**Evidence.** Zig test `v2 req_get_target/req_get_query
expose the raw target and query (G4)` (target verbatim incl.
`%32`, query slice exact, `req_get_path` unchanged, no-query
→ length 0). Acceptance run 4 asserts the echo's
`path /api/echo?x=1` line.

## F3 — access log syscall diet ✓

**Shape.** `src/access_log.sla` rewritten around a `LogSink`:
the log is opened **once** at boot (the M1 probe's fail-fast
check is preserved as a real open), one seek-to-end at open,
then each line is assembled in the sink's buffer (same
2048-byte cap semantics) and written with **one**
`sa_fs_file_write_all` per line: 4 syscalls per line
(open/seek/write/close) → 1, with the line format
byte-identical. Recorded trade-off, in the module header: a
file truncated or rotated externally is not noticed until
restart (nginx-like); per-line single write (rather than
threshold flushing) is deliberate — the sequential accept
loop has no later flush point, and acceptance kills the
server and then reads the log.

**Evidence.** New `tests/access_log_test.sla` (2 tests):
two appended lines read back byte-exact; unopened sink
refuses; bad path fails fast. All M1 access-log acceptance
checks pass unchanged (format/content semantics untouched).

## G3′ — static serving via sendfile ✓

**Fix.** sci: `HttpResponse.sendFile` +
`sa_http_server_resp_send_file_v2` — frames the head with
`content-length = count`, loops `sendfile(2)` kernel-side
(chunks ≤ 0x7ffff000), reports the true sent count. This
repo: the static GET path in `src/main.sla` opens the file,
borrows the raw fd (`sa_std_fd_as_raw`, handle stays owner),
and sends via the new face; `max_file_bytes` no longer gates
GET (still parsed for config compatibility — run 2's
byte-exactness checks are unaffected).

**Failure semantics (explicit, no silent fallback).**
Platforms without sendfile: the face returns status **8
(unsupported) before sending a single byte**; slanginx logs
a warning and answers a plain 500 — this is the one explicit
platform-UNSUPPORTED branch, named here as required. A short
send mid-body (e.g. the file shrank after measuring) cannot
be taken back: the access log reports the bytes that
actually reached the wire and the face closes the
connection.

**Evidence.** Zig test `v2 resp_send_file streams the file
body kernel-side (G3')` (head framing + exact bytes on a
live loopback exchange). Acceptance runs 1–3 exercise the
sendfile path for every static check (47 baseline checks,
all passing). The status-8 branch itself is not exercisable
on this Linux host — stated plainly, it is covered by code
inspection and the face's contract tests-to-come on a
non-sendfile platform, not by a local run.

## Also closed en passant

- The proxy's D6 workaround (fetch HEAD as GET, relay
  headers) is removed: HEAD is fetched as HEAD.
- M1's acceptance note "query not exposed by the server
  face" is gone; one baseline check was renamed accordingly
  (`proxy echo: full path forwarded`, same assertion) and
  two checks were added (G4 query, G5 user-agent).

## Newly found, registered here, NOT fixed on this line

- **The v2 client ignores `no_proxy`.** The v1 path honors
  it (`maybeBypassProxy`); `executeRequestV2` relies on std's
  native proxy handling, which routes even `no_proxy` hosts
  (e.g. 127.0.0.1) through `http_proxy`. On this sandbox VM
  that made every v2 loopback call hang inside the egress
  proxy — it contaminated the first local D6 repro attempts
  and an early full-suite run before the cause was isolated.
  All local verification on this line was therefore run with
  the proxy env stripped. The defect is real for any
  deployment that sets `http_proxy` with `no_proxy` upstreams;
  it wants its own fix (mirror the v1 bypass in the v2 path)
  and is registered here for the owning line.

## Test inventory (this line)

- slanginx unit tests: 23/23 baseline names pass, plus 2 new
  F3 tests (`tests/access_log_test.sla`) = 25/25.
- Acceptance (`scripts/acceptance.sh`), name-set comparison
  against the M1 baseline extracted from `59808d8`: **zero
  missing, zero failing**; 47 baseline + 2 new = **49 PASS /
  0 FAIL** locally (log: `~/workspace/acceptance_improve.log`
  at line time). One baseline check renamed (see above).
- sci `sa-std-unit` (local, clean env), three runs: pristine
  `220dabe7` 265 pass / 10 fail of 275; this line's tree
  270/10 of 280 mid-line and **272 pass / 10 fail of 282**
  final (275 + 5 new client + 2 new server tests; all 7 new
  tests pass, and no http client/server test fails in any
  run). The failure sets share a stable environmental core of
  9 names — keyring library availability, the sandbox's
  wildcard-DNS behavior, 7× tree-sitter library availability
  — while the 10th slot rotates among environmental flakes
  across runs (a pty test on the first two runs, a different
  pty member each time; the public-internet TLS handshake
  test on the final run). No failure is attributable to this
  line's changes.
- SLA repros: D6 and G5 both exercised before/after (signal
  11 → pass; gap-panic 705 → inverted regression pass).

## Not verified on this line (honest list)

- All performance numbers (F3/G3′/D6 throughput or latency
  effects, the M1 99% re-check): deferred to the box, by
  charter. The M1 wrk baselines were not re-measured and are
  not cited as results here.
- G3′ status-8 (unsupported platform) branch: not runnable
  on this Linux host (see above).
- The full sci unit suite on the box (the box's failure set
  is smaller — most local failures are this instance's
  missing libraries): to be re-run at integration.
- F2 (threaded serve) was not touched and not pre-wired, per
  charter; it remains blocked on the F-perf-2 residuals.