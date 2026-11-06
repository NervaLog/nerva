---
id: P238c
date: 2026-11-06
area: Releases
amends: P238b
---

# The final gateway start is judged by a checker, not by a throw

**Decision.** (1) `nemesis/final-start-checker`, composed under the key `:gateways` of every
test's top-level checker (so both workloads), is `:valid? false` when a completed `:final? true`
`gateway-start` has an `:exception`, a non-empty `:down` or `:pending`, or an `:error`. Its result
names the gateways and NRV-E0604. Jepsen turns a throw in a nemesis op into an `:info` op that its
own checkers count as valid, so P238b's "throws, which fails the run" was wrong; the verdict now
carries it, and `jepsen_report.py` reads the top-level `:valid?`, which merges the key. (2) The
final start no longer throws for a gateway that does not come up: it returns it under `:down` or
`:pending`, so the other gateways and nodes keep their results; a node whose start still throws
(ssh) is caught per node and recorded under `:error`. (3) The final start probes every gateway:
`:up` is kept, `:dead` is started with `start-gateway-until-up!`, `:pending` (running, silent) is
waited for and, if it exits or stays silent, killed and started. (4) Each wait is
`gateway-wait-s`: the registration window plus 5 s. The window is the test's `--request-timeout`,
else 30,000 ms (`request_timeout_default_ms`, `src/nerva/cli.zig:703`; the call deadline includes
registration, `client.zig` `Options.timeout`). A `:pending` result at the end of a wait is waited
for again (at most `gateway-waits-max` = 2 waits per start), never restarted; only `:dead` is
restarted (6 starts, backoff 0.5 s doubling to 4 s). (5) Bound per gateway: 6 starts x 2 waits x
(35 s + a probe) + 11.5 s of backoff, about 7 minutes at the default; a gateway that exits ends
its wait at once, so a real run takes far less. Gateways of a node are started in turn.

**Why.** Second review of PR #238: a gateway that never reaches the cluster after the heal was
reported valid; a running-but-pending gateway was skipped; a 15 s wait was shorter than the 30 s
registration, so a healthy start was given up on.

**Costs.** A final start can take minutes when the cluster is really unreachable. A gateway killed
after being pending is restarted once more, which the history shows only as its final state.
NRV-E0604 is now raised by the harness as well as by `nerva api`: ERRORS.md says so (surface and
blame); no code was added.
