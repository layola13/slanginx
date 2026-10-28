# slanginx

An SLA-native web server — an nginx-class static/reverse-proxy
server written entirely in SLA on the SA standard library. The
design record is the sala planning page
`content/01_overview/09_nginx_rebuild_roadmap.html` (the project
was renamed from the working name on that page to the repository
name, slanginx).

## M0 status (this delivery)

Working, acceptance-verified on a live server:

- **Static file serving** over the sa_std built-in HTTP/1.1
  server face (std, not a plugin): GET/HEAD, byte-exact bodies,
  404, MIME by extension, directory requests serve the index
  file, **path-traversal containment** (a `..` that would escape
  the root — raw or percent-encoded — is refused 403, never
  clamped into the root).
- **Two-layer configuration**:
  - *Declarative layer* — `slanginx.toml` (see the shipped
    sample): listen host/port, server root, index file, access
    log path, buffered-read cap. Edit + restart takes effect,
    no recompilation. A present key with the wrong type is a
    startup error, not a silent default.
  - *Code layer* — `src/config.sla`, a typed SLA module compiled
    into the server: the `/internal/` deny rule (403 even though
    the files exist), the `/assets/` alias to a second root, and
    an ACL predicate built on the sa_std `ip.sla` value layer.
- **Access log**: one line per request —
  `<remote> <method> <path> <status> <body-bytes> "<user-agent>"`
  appended to the configured file. The log file must be openable
  at boot; a bad path fails startup (nginx behavior).

Process model for M0: single process, sequential accept loop.

## Registered gaps (M0)

- **No sendfile / zero-copy send path exists in sa_std** (checked:
  zero hits for sendfile across the sa_std declarations and the
  sci runtime sources). M0 serves through a buffered path
  (whole-file buffer under `max_file_bytes`, chunked streaming
  above it). This is the known static-throughput ceiling until
  the std surface grows a sendfile face.
- **HEAD responses cannot carry the resource's content-length**
  with the current std server face — measured on the wire, all
  three response shapes fail differently (details in
  docs/M0_DELIVERY.md). HEAD currently answers 200 +
  content-type with an empty chunked body (protocol-valid, no
  body bytes), and the gap is registered for the std surface.
- **The access log's remote field is `-`**: the std server face
  exposes no peer-address getter for a request handle. The
  code-layer ACL predicate (`config_acl_allows`) is compiled in
  and unit-tested but cannot be wired to live requests until
  that getter exists.
- Directory requested without a trailing slash is served its
  index directly; nginx's 301 redirect is not issued in M0.
- Reverse proxying, TLS/HTTP2 termination, rate limiting and
  caching are later milestones (M1–M3 on the planning page), as
  is the VM-plugin extension model.

## Layout

```
src/main.sla        server entry: accept loop, dispatch, sending
src/settings.sla    declarative layer: TOML -> Settings
src/config.sla      code layer: deny rule, assets alias, ACL
src/webpath.sla     percent-decoding, normalization, traversal
                    containment, MIME table
src/access_log.sla  access-log line format + append
src/numfmt.sla      decimal formatting helper
tests/              @test unit tests (webpath, config)
scripts/acceptance.sh  live curl acceptance (three config runs)
www/, www-assets/   sample roots used by the acceptance
slanginx.toml       sample declarative configuration
docs/M0_DELIVERY.md delivery note with measured evidence
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
bash scripts/acceptance.sh
```
