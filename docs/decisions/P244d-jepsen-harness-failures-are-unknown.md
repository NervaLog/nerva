---
id: P244d
date: 2026-11-06
area: Releases
amends: P244c
---

# Jepsen harness failures are `:unknown` with NRV-E0607, and only the final heal is judged

**Decision.** (1) NRV-E0607 is registered for a failure of the Jepsen harness. The `gateways`
checker gives `:valid? :unknown` and NRV-E0607 when the final `gateway-heal` failed, the final
`gateway-start` threw or did not finish, or an expected final start never ran; the heal script's
iptables failures print NRV-E0607 too. NRV-E0604 stays for a gateway left `:down` or `:pending`
after the final start (`:valid? false`, and it wins when both hold). (2) Only `:final? true`
heals are judged. A mid-run heal that threw is listed as `:mid-run-heal-failures` for information:
the final heal confirms with `iptables -C` that no rule is left. (3) `final-start?` is true for
every fault in `replica-restarting-faults`, `kill` and the LazyFS `lose-unfsynced-writes` (draft
#242, not on main yet), since both restart replicas through `db/start!`, which only settles
briefly. (4) `signal-gateways!` checks the owner and signals in one shell command that reads the
pidfile once (`signal-script`); `gateway-owned?` is gone.

**Why.** Review of #244: a transient ssh error mid-run failed a run whose final heal was clean;
a LazyFS-only run would get no final start; a broken iptables or a generator bug blamed Nerva
(CLAUDE.md: a message that blames the wrong layer is a bug).

**Costs.** A run with a harness failure is `:unknown`, which Jepsen reports as not valid, so it is
still not a pass. Left as they are, on purpose: the `id -u` skip in `heal-script` (it trusts that
nothing deletes the gateway users; `run.sh` recreates the containers, so a stale uid rule cannot
survive), and `ran?` in `db` (it assumes a fresh DB per test; a `db/cycle!` setup retry would see
it true after a failed setup and log a heal failure instead of rethrowing).
