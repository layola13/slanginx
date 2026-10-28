# slanginx handler / shared-state model — FINAL RULING

Status: **decided**. User approval 2026-10-28 19:17 (CST), on the
main session's proposal routed through Jev (jev-1.14.0):

| Option | Model | Jev probability |
|---|---|---|
| **A** | **No handler-held shared state + explicit shared dict zones** | **1.0** |
| B | Threaded handlers composing shared structures via `Mutex<Struct>` | 0.0 |
| C | Multi-process workers + shared memory | 0.0 |

This document is the design record. The M1 implementation follows
it; the seams that M1 planning had left as TODO pending this
ruling are landed as specified in §3.

## 1. The question

M0's process model is a single process with a sequential accept
loop, and its code layer (config.sla) is a set of pure functions:
deny predicate, alias routing, ACL predicate. Two M1 questions
needed a ruling before implementation:

1. What may a handler (request-processing function) hold between
   requests — i.e. what is the extension model for future
   handlers (proxy today; limiters, caches, auth later)?
2. When handlers genuinely need cross-request state (counters,
   rate-limit budgets, health marks), what facility carries it?

## 2. The three options

**A — stateless handlers + explicit shared dict.**
Handlers hold no global mutable state at all. The only
cross-request mutable surface is a set of named **shared dict
zones**, declared in the TOML layer (name + capacity) and backed
by a standard-library facility: the `sa_global_*` named cells in
`sa_std/globals.sai` (process-wide cells, mutex-guarded inside
sa_std; u64 cells with an atomic add, bytes cells with set/get).
The code layer reaches a zone only through an explicit API
(`dict_get` / `dict_set` / `dict_incr`, with per-key TTL) in one
module, `src/shared_dict.sla`. Zone names are data (TOML), keys
are explicit byte strings — state is addressed, never ambient.

**B — threaded handlers + SLA-composed shared structures.**
Use the server face's threaded mode and let handlers share SLA
structs guarded by `Mutex<T>`. **Measured blocker**: in this
toolchain SLA's `Mutex<T>` accepts only scalar `T` (established
during slaredis M0); a shared struct cannot be composed at the
SLA layer at all. Any real shared structure would have to be
hand-assembled from scalar cells with hand-rolled locking —
exactly the un-auditable ambient state A exists to avoid.

**C — nginx-style multi-process workers + shared memory.**
**Measured blocker**: sa_std has no fork/process-spawn primitive
for this (the same missing primitive that gates slaredis
persistence), and no shmem face. Not implementable on the
current std surface; would start with a std/compiler project,
not a slanginx milestone.

## 3. The ruled form (A, as implemented in M1)

- A handler is a function of the request plus read-only
  configuration. It keeps no state between requests; the M0
  code layer's pure-predicate style is the permanent shape, not
  an M0 expedient.
- Shared state exists only inside declared shared dict zones:
  - zones are declared in the TOML layer as `[shared_dict.N]`
    with `name` and `capacity` (max distinct live keys in the
    bytes facet); an undeclared zone name is an explicit error
    at the call site, never an implicit creation;
  - a zone is backed by `sa_global_*` cells (the sa_std-layer
    KV facility). Namespacing: bytes facet `sd/<zone>/<key>`,
    counter facet (u64 namespace) under the same name, expiry
    in a u64 cell `sd/<zone>/<key>#e`. Keys beginning with `#`
    are reserved (the zone's entry-count cell is
    `sd/<zone>/#n` in the u64 namespace);
  - the code-layer API is `dict_set` / `dict_get` /
    `dict_incr` / `dict_get_num` in `src/shared_dict.sla`, all
    with explicit zone, key, TTL and an injected clock reading
    (the decision logic is unit-testable without sleeping);
  - TTL is **logical expiry**: an expired entry reads as
    missing and is overwritten by the next set/incr. The std
    cell facility has no delete/evict primitive, so capacity is
    enforced as "no new key once the zone holds `capacity`
    distinct keys" with an explicit FULL error — never a silent
    eviction (house rule: no silent fallbacks);
  - capacity errors, undeclared zones and oversized keys/values
    are distinct, named result codes, not defaults.
- First consumers (M1): the reverse proxy keeps per-upstream
  `requests` / `errors` counters in the `stats` zone (only when
  the operator declares it), read back through the code-layer
  status route `GET /__slanginx/status`. Handlers that do not
  need shared state — static file serving, the ACL and deny
  predicates — touch the dict not at all.

## 4. Fit with the M0 style

M0 deliberately made configuration two-layer: TOML for data,
SLA for rules, with the rules as pure functions over explicit
inputs. Model A is the same split applied to state: zone
*existence and size* are data (TOML); *what is stored and when*
is code (explicit dict calls in exactly one module). Nothing
outside `shared_dict.sla` names a `sa_global_*` extern, so the
whole shared surface of the server can be audited by reading
one file — the property B would have destroyed and C could not
have provided.

## 5. Consequences and non-goals

- Single-process model retained: zones are process-wide cells.
  If a future milestone revisits multi-process serving, zones
  do not silently change meaning — a process boundary would
  need a new ruling, exactly as C's blockers record.
- No rate limiting, caching or auth is implemented in M1; those
  are handler-layer features that will be built *on* this model
  (a limiter is a `dict_incr` with TTL, by design).
- The dict is not a database: no iteration, no delete, no
  persistence. Those absences are the std facility's current
  shape and are recorded here rather than papered over.
