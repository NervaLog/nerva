---
id: P209
date: 2026-11-06
area: Releases
amends: P195b
---

# A call with less than a sixteenth of the timeout left is not sent

**Decision.** `Client` refuses a call (`error.Expired`, NRV-E0606, nothing sent) when the time left
in the request's window is less than `Options.timeout / 16` (`window_remaining_divisor`): 1.9 s of
the default 30 s, 62 ms of the 1 s minimum. P195b refused only a window already spent. No flag:
the bound follows `--request-timeout`, and `applied` is reported as before (`false`, `"unknown"`
only if an earlier call of the request wrote).

**Why.** A call started with a few milliseconds left is sent, cannot be answered in time, and
times out (NRV-E0601): the session breaks, requests answer NRV-E0605 for 5 s, and the write's
outcome is unknown. That is the slow-cluster case P195b set out to fix. A healthy round trip
takes a few 10 ms ticks, so a sixteenth of the timeout leaves it room, and a refusal costs the
client only a resend. A fraction of the existing timeout needs no new constant to tune.

**Also (issue #205).** An explicit `min_op` or `as_of` that the view has already reached reads
nothing from the feed, so it never gets NRV-E0606; a test now holds it so.

**Left as it is.** A `views_busy` member whose send again expires is `unknown`, though that
send never went out (`Client` refuses before queueing) and its busy answer was a refusal.
`applied` is the group's write count taken at exit; a per-member override would be correct but
`unknown` is the safe direction, and a retry with the same key is safe either way.

**Cost.** A request whose first call starts with under a sixteenth of the window left, for
instance after a slow reconnection, is refused where it might have just fit. A call that is sent
and still passes the window is NRV-E0601, as before.
