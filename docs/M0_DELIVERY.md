# slanginx M0 delivery note

Scope per the sala planning page M0: static file service +
two-layer configuration + access log, with the sendfile gap
verified. Built local-first (master in the repo), compiled and
acceptance-tested on the Colab box against sci main `14d9fbc8`
(sa 0.1.8, SLA plugin dev-installed). No changes to sci or
sa_plugin_sla: compiler/std defects found on the way were
reproduced minimally, registered here (§4), and worked around in
the application layer.

## 1. What was delivered

| # | Deliverable | Verdict |
|---|---|---|
| 1 | Repo scaffold: README, `src/` SLA modules named by function (main/settings/config/webpath/access_log/numfmt), sample TOML + sample roots | done |
| 2 | Static server on the std HTTP/1.1 face (v2 API of `sa_std/http_server.sai`, symbols verified in `libsa_std.a`: 46 `sa_http_server_*` exports) | done, live-verified |
| 3 | TOML layer via `sa_std/encoding/toml.sai`: host/port/root/index/access_log/max_file_bytes; restart-only changes proven by acceptance runs 2–3 | done, live-verified |
| 4 | Code layer `src/config.sla`: `/internal/` deny (403, file exists), `/assets/` alias to `www-assets`, ip.sla ACL predicate | done; deny + alias live-verified, ACL unit-tested only (see gap G2) |
| 5 | Access log: one line per request with method/path/status/body-bytes/UA, appended to the configured file; boot-time open probe | done, live-verified |
| 6 | Unit tests: `tests/webpath_test.sla` 8/8, `tests/config_test.sla` 4/4 | done |

## 2. Live acceptance evidence

`scripts/acceptance.sh`, three server runs driven by curl.
Full log: `docs/acceptance_run.log`. Result: **28 PASS, 0 FAIL**.

Run 1 (shipped `slanginx.toml`, port 18090, root `www`):
- `GET /hello.txt` 200 byte-exact; `GET /` serves `www/index.html`;
  `GET /blob.bin` byte-exact, sha256 `c8f5d0341d54d951…` on both
  sides, content-type `application/octet-stream`;
  `GET /style.css` content-type `text/css`.
- `HEAD /hello.txt` 200 + `text/plain`, raw-socket verified: **no
  body bytes on the wire** (see G1 for the content-length side).
- `GET /missing.txt` 404.
- Traversal, all refused **403** with no body leak:
  `/../slanginx.toml`, `/%2e%2e/slanginx.toml`,
  `/a/../../slanginx.toml`.
- Code layer: `GET /internal/secret.txt` → **403** and the body
  does not contain the secret text, although the file exists
  under the root; `GET /assets/logo.txt` and
  `GET /assets/only-here.txt` served from `www-assets`
  (byte-exact), `GET /assets/` serves the alt root's index.
- `GET /big.txt` (210,000 B) byte-exact on the buffered path.
- `POST` → 405.
- Access log lines include `- GET /hello.txt 200 32
  "curl/8.5.0"`, `- GET /missing.txt 404 10 …`,
  `- GET /internal/secret.txt 403 10 …`,
  `- GET /big.txt 200 210000 "slanginx-acceptance/1.0"`.

Run 2 (alt TOML: port 18091, `max_file_bytes = 1024`):
`big.txt` and `blob.bin` byte-exact over the **streaming** path;
server reachable only on the new port (TOML change live, no
recompile).

Run 3 (alt TOML: port 18092, `root = "www-assets"`):
`GET /` serves `www-assets/index.html`; `/hello.txt` (exists
only in the old root) → 404.

Unit tests (`sa test`, repo-root cwd, `SA_PLUGIN_DEV=1`):
webpath 8/8 (decoding, normalization, traversal codes, encoded
traversal, query cut, malformed escapes, MIME), config 4/4
(deny shape, alias shape, assets-root constant, ACL table:
8.8.8.8 allow; 10/8, 172.16/12 incl. the /12 boundary
172.32.0.1 allow, 192.168/16 deny; unparseable deny).

## 3. Design points worth noting

- Settings fields are fixed byte arrays + lengths, never
  Strings: a multi-String-field struct is a known SAB referee
  hazard in this toolchain; the integer/array shape is the
  proven-safe one (same reason ip.sla's types look the way they
  do).
- File sending never trusts a truncated buffer: if the buffered
  read's length disagrees with `fs_len`, the handler falls back
  to the streaming path instead of sending partial bytes.
- The accept loop logs from an Outcome struct whose method/path/
  UA were copied out while the request handle was alive, so the
  log append happens after handling without touching freed
  request memory.

## 4. Registered gaps and defects

**G1 — std server face cannot emit a correct HEAD response.**
Measured on the wire (raw socket) for `HEAD /hello.txt`
(32-byte file), three candidate shapes:
1. `resp_new_v2` + caller `content-length: 32` + send of an
   empty body → response carries `content-length: 0` (the send
   face overrides the caller's header with the body length).
2. `resp_new_v2` + send of the real 32-byte body → response
   carries `content-length: 32` **and the 32 body bytes** for a
   HEAD request — a protocol violation that desyncs keep-alive.
3. `resp_stream_new_v2` + caller `content-length: 32` + zero
   chunks → the header is dropped; response is
   `transfer-encoding: chunked` with the `0` terminator only.
M0 ships shape 3 (protocol-valid, no false length claim). The
std face needs a header-only response shape (or send honoring a
caller content-length) — follow-up for the std/compiler owners,
not worked around further here.

**G2 — no peer-address getter on the std server face.**
`sa_std/http_server.sai` (v1+v2) has no request remote/peer
address accessor, so the access log's remote field is `-` and
the code-layer ACL (`config_acl_allows`, ip.sla-backed,
unit-tested) cannot be evaluated per live request. One extern
(`sa_http_server_req_remote_addr` or similar) unblocks both.

**G3 — no sendfile / zero-copy send in sa_std** (pre-verified by
the main session: zero hits in the .sai declarations and the
sci runtime sources). M0's buffered+streaming paths are the
interim; static throughput benchmarks against nginx belong to
the milestone that adds the sendfile face.

**D1 — `PTR_COPY_BYTES` in an imported .sla unit traps
SAB-direct lowering** with `UnknownRegister` (1007, "callee is
not declared"). Minimal shape: an imported .sla fn whose body
calls `PTR_COPY_BYTES(dst, src, n)` (from `sa_std/ptr.sa`),
invoked from a test root — bisected: resolve-only probe passes,
mime-only probe (which used it in `mime_fill`) traps at sab
line 121 / source line 741. Worked around with a `PTR_BYTE_AT`
copy loop. (dns.sla uses the same macro inside sa_std's own
graph without tripping this; the trigger is the imported-unit
position.)

**D2 — bare string literal passed to a `String` parameter
segfaults inside ip.sla under the SAB test path** (signal 11).
Minimal shape: `ip_addr_parse("8.8.8.8")` in a @test body.
sa_std's own ip tests always wrap literals in `format(...)`;
doing the same fixed it. Same family as the registered
String-representation split (literal {ptr,len} vs format-built
String). Worked around by `format(...)` at every String
call site in config.sla and its tests.

**D3 — direct calls to the `sa_print_bytes` extern trap
CapabilityMismatch** (1013) even with literal arguments; only
the `println` path satisfies its `&msg` capability contract in
this toolchain. All startup messages use `println`; computed
values are not printed (the banner is static text).

**D4 — referee false positives met and avoided** (same family
as the registered multi-line findings): a no-op self-assignment
`cand_len = cand_len;` lowered to `add cand_len, 0` and trapped
UseAfterMove ("expected Consumed, actual Consumed"); a
conditional `sa_env_buffer_free` + merge trapped
PhiStateConflict on the handle register. Both avoided by
ordinary restructure (drop the no-op; guard-return helper so
the handle is freed on the single creating path). Also the
house rules confirmed again: `if`/`match` blocks take a
trailing `;`, `while` blocks do not; an imported unit's externs
are not re-exported transitively (settings.sla imports both
toml.sai and toml.sla); test files import project modules by
repo-root-relative path (`src/webpath.sla`) — `../src/…`
fails import expansion with SyntaxError.

## 5. Push-readiness notes for the main session

- The repo is self-contained; the only build artifacts are
  `src/main`, `src/main.sa`, `./slanginx`, `logs/*.log` (all
  gitignored). Box and local trees are identical by sha256 for
  every tracked file.
- Nothing in sci / sa_plugin_sla was modified. The two plugin
  builds on the box (react/mui from an earlier line) were not
  touched; this line used only the sla plugin.
- Follow-ups that belong to other owners: G1/G2 (std server
  face), G3 (std sendfile), D1/D2 (compiler/SAB), then
  slanginx M1 (reverse proxy — waits on the handler-model
  ruling).
