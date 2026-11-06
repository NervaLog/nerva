---
id: P244c
date: 2026-11-06
area: Releases
amends: P244
---

# A failed gateway heal is judged by the checker, not by teardown

**Decision.** (1) `heal-script` accepts only `iptables -C` exit 1 as "no such rule"; exit 0 or
any other code (iptables broken: 2, 3, 4) is NRV-E0604 and fails the heal. This corrects P244 (2),
whose script read every `-C` failure as healed. (2) A node's teardown after the run
(`teardown-node!`, once `setup!` ran in this DB) logs a failed heal and does not rethrow; it still
kills everything and removes the data directory. Before a run (`db/cycle!`) it rethrows. (3) The
final phase's `gateway-heal` carries `:final? true`, so a per-node failure is returned as `:error`
(the other nodes keep their results); `final-start-checker` (the `gateways` key) is invalid, with
NRV-E0604 and `:heal-failures`, for any `gateway-heal` completion with an `:error` or an
`:exception`, mid-run or final. (4) The test map carries `:nemesis-faults` (the CLI list, which the
test's own `:nemesis` key overrides); when `final-start?` holds for them, the checker requires
exactly one final `gateway-start` completion and is invalid with `:expected 1` otherwise. (5)
`signal-gateways!` signals only a gateway whose pidfile names a live process owned by that
gateway's own user (`gateway-owned?`, `stat -c %U /proc/<pid>`), which does refuse a reused pid;
this replaces P244 (3)'s `gateway-running?` filter, which only checked that the pid existed.

**Why.** Review of #244: a broken iptables healed "successfully" (the #236 failure); a heal that
threw at teardown made Jepsen skip analysis and lose the verdict (`with-db` tears down in a
`finally` before `analyze!`); no checker read a heal's failure, so `gateway-partition` alone could
leave a gateway cut and pass; a run whose expected final start never ran passed with
`:final-starts 0`.

**Costs.** One `stat` over ssh per gateway signalled. A node left dirty at the end of a run no
longer fails the run by itself: the final heal's verdict does, and the next `cycle!` refuses it.
A gateway between `setpriv` and its uid drop is not signalled; pause and resume act on gateways
that have been running for a while.
