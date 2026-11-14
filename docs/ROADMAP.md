# Roadmap

*Written 2026-11-11 from `main`; the owner accepted the release split on 2026-11-12. It maps the
work already planned to releases. The milestones themselves are defined elsewhere, and this page
does not change them:*

- *[docs/PRODUCTION.md](./PRODUCTION.md): R1 to R8, what stands between the engine and
  strangers' money;*
- *[docs/GOALS-1.0.md](./GOALS-1.0.md): G1 to G8, what 1.0 does.*

*Anything here marked **proposed** is not decided until the owner says so. A release ships a
milestone only when that milestone's demo is green in CI.*

## Where things stand

| Release | Name | State |
| --- | --- | --- |
| v0.6.0 | Facts beside money | Released: commit keys, records, declared indexes (G1) |
| v0.7.0 | Production gate, part one | Released: R4 Gateway and R5 Recover delivered |
| v0.7.1 | Alpha | Being released: soak, Jepsen, packages and docs for a first outside user |

## v0.7.1 · Alpha (in release)

For someone who is not us to install Nerva, run it and trust what it says.

- A 24-hour soak of the simulator and the fuzzers, and a Jepsen night, on the release commit.
- `.deb` and `.rpm` packages; a macOS binary signed with a Developer ID and notarized in CI,
  behind a protected environment (`apple-signing`).
- Install, quickstart, operating and troubleshooting docs, and the error register
  (`docs/ERRORS.md`).

No engine change: `src/` has been frozen since the soak candidate.

## v0.7.2 · Packages you can update (decided)

- **apt and dnf repositories**, served from a Cloudflare Worker, with signed packages (#296).
- **Fixes held during the freeze:** #300, #302, #304 and #306 (pull requests #332, #333 and
  #338), and the pre-flight lock wait (#294).
- **Security fixes:** #335 and #336 (keys), #222 (mixing keys-off and release binaries). For
  #303 (client port), only documentation: replica client ports must be reachable only by
  replicas and their gateways.
- **Process:** a machine account for sessions, CODEOWNERS, and "prevent self-review" on
  `apple-signing`.

## v0.8 · Proven and upgradable (decided)

The first release that can upgrade without closing the cluster. This is also the release the
production gate (R1 to R5) is meant to close.

- **R1 · Proven:** Jepsen nightly on the dedicated host, delivered once it runs there green.
- **R2 · Fleet:** the always-on simulator and fuzzer fleet, delivered once it has run 24 hours
  and filed its findings.
- **R6 · Upgrade:** rolling upgrades through multiversion binaries
  ([brief](./briefs/r6.md); its owner questions are answered, P259b to P259g). Upgrading from
  v0.7.x to v0.8 is still an export and import (P259g). Rolling upgrades apply from v0.8 on.
- **R3 · Measured:** sizing and latency on three machines, and the Fly p99 explained.
- **Client authentication at the replica (#303):** a client key checked in a connection
  handshake, a wire change, designed in #353.
- **Toolshed tutorial:** a complete small application on Nerva, from its brief (written after
  v0.7.1).

## v0.9 · Bounded (planned)

Disk, export and import stop growing with all of history.

- **R7 · Retention:** a declared horizon for row and record history and view and group
  versions; a read before the horizon answers `before_horizon`. Commit keys and facts stay kept
  (P123); their retention is cut from R7 (P422).
- **Engine gaps named in GOALS-1.0:** index reads as of a past op, and `group_by` on `bytes`
  fields.
- **View snapshots** (README roadmap item 5).

## v0.10 · Native and effects (planned)

- **R8 · Native client:** a C ABI and a JVM binding, with batched ops and no gateway in the
  client's path.
- **G5 · Effect sinks:** outbound actions as views keyed by `(view, row, op)`, so each happens
  once on Nerva's side.
- **G7 · Attributed approvals:** these need an identity model first (N30).

## 1.0

Every goal in GOALS-1.0 is delivered and every R milestone is green. The first application
(Botpike) runs its money, facts and receipts on Nerva (GOALS-1.0, milestone 7).

An external correctness review stays an owner-accepted risk (GOALS-1.0, "Non-goals").

## Not on this roadmap

Object-storage tiering, external operators (embeddings), SQL, and application-specific routes
(GOALS-1.0, "Non-goals"; [docs/NON-GOALS.md](./NON-GOALS.md)). TLS on the gateway is also left
out (PRODUCTION.md, "Not here").
