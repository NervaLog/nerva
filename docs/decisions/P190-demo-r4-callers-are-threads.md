---
id: P190
date: 2026-11-05
area: Releases
---

# The R4 demo's clients are caller threads, and a waiting request is not "unknown"

**Decision.** In `tests/demo/r4.py`, clients A and B are two groups of caller threads in the
demo process, each group using its own `nerva api` process (GA, GB), not two Python
subprocesses. Step 9 asserts that every request in flight when the replicas stop is answered
`503` within 4 s, that at least one of them is `"applied":"unknown"` with NRV-E0601, and that any
other is `"applied":false` (NRV-E0605 or NRV-E0602): a request that was still waiting its turn
was never sent.

**Reason.** What the demo shows is the gateway's: the failure domain is the gateway process and
its sockets, which are separate processes either way. A caller subprocess would add a control
channel (start, stop, report) without changing any assertion. A gateway that answered `"unknown"`
for a request it never sent would be wrong, not safe; the brief's "in-flight requests get
unknown" is about requests the cluster may have seen.

**Cost.** Both clients share one Python interpreter, so the callers are limited by its lock rather
than by two processes (about 700 commits a second here). The refusals at 16 held connections do
not depend on speed, and the run still keeps 32 callers busy for 30 s.

## Amended in this pull request (review of #190)

- **Step 6 asserts `refused{reason:displaced}` is 0.** Every connection the script opens sends
  bytes at once, and displacement needs 50 ms of silence, so a displaced connection is the
  bug #120 closed. `queue_wait` is summed with `busy` (a client cannot tell them apart); the
  sum must equal the busy replies seen, polled for up to three 10 s windows, not checked once.
  This deviates from the brief's "`reason:busy` sums to the busy replies".
- **Step 9's 0.5 s window.** A `200` or `409` answered less than 0.5 s after the last SIGSTOP
  returned is accepted: it committed while the signals were still being delivered, and a 200
  only reports a real commit. Every `503` in the stall, in flight or not, must be `unknown`
  exactly when its code is NRV-E0601.
- **Steps 7 and 8 count what happened.** A transport error before the connect is made is
  "refused at connect" (never sent); after it, "cut mid-flight" (unknown). Step 7 needs at least one
  cut; step 8 prints first-time against replayed answers and fails on a 409.
- **No vacuous passes.** A worker that raises is recorded and fails the step, and a step that
  resends or replays keys fails unless every key was verified. The dripper's errors fail step 5,
  and it must complete two rounds. A hung gateway start or join ends in a `demo-r4: FAIL` line
  (a 20 minute watchdog backs it), not CI's timeout.
