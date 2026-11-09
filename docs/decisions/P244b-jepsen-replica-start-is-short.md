---
id: P244b
date: 2026-11-06
area: Releases
amends: P238c
---

# The replica kill's start settles briefly; the final phase judges every gateway

**Decision.** (1) The replica `kill` nemesis's `:start` (`db/start!`) calls `restart-api!`, which
starts the gateways that are not running and probes them for `start-settle-s` (10 s) plus one
round, as the gateway nemesis's start does; it no longer calls `start-api!`, whose 35 s waits and
up to 6 restarts (P238c) stay for `setup!` only. A gateway left down or pending is warned about.
(2) The nemesis package now emits the final `gateway-start` (`:final? true`) also when the replica
`kill` fault is on, not only with `gateway-kill`; it runs after the replicas' final `:start`, waits
for and restarts every gateway not up, and `final-start-checker` fails the run with NRV-E0604
for one that stays down or silent. Runs with only `pause` or `partition` have no final start:
they do not kill a gateway. (3) `final-start-checker` pairs each final `gateway-start`
invocation with its completion by process: Jepsen records both as `:info`. `:final-starts`
counts completions, and an invocation with no completion makes the run invalid (`:incomplete`,
NRV-E0604).

**Why.** Review of #238: under `partition` a gateway on a node without a quorum exits at 30 s,
so one `:start` took about 3 minutes per gateway while the single nemesis worker held every
other fault back (the nightly `kill,partition --time-limit 300`), and a gateway left down by
that `:start` was never judged (`:gateways {:valid? true, :final-starts 0}`). The checker counted
each final start twice and passed an invocation that never completed.

**Costs.** Under `kill`, a gateway that exits at a main-phase `:start` stays down until the next
`:start` or the final phase, so the run has fewer gateways meanwhile (never wrong results). The
final phase of `kill` runs gains up to the bound of P238c's final start per gateway that is not
up, and nothing for gateways that are.
