---
id: N70
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# An evicted client is deinit'ed by `Client.deinit`, not by its eviction callback.

The vendored VSR client asks its eviction callback to deinit it, but calls the callback from
inside the message bus's receive path, which then invalidates the receive buffer that `deinit`
has just freed. Every eviction aborted the process (#52): `nerva api`, `nerva view` and Zig
clients, whatever the reason (`no_session` after `clients_max` newer sessions, a release too
low, an invalid operation such as #33's raw `pulse`). Nerva's `Client.on_eviction` now only
records the eviction; `Client.deinit` (and so `reconnect`) deinits the VSR client. In between,
nothing drives the client's IO, since every call returns `error.Evicted`, so the evicted VSR
client processes no message. No vendored file changes. Test: `test:integration` ends by
restarting replica 0 (down since the failover step, which makes registrations slow) and pushing
a client's session out with `clients_max` newer ones; its next two requests get
`error.Evicted` (before: the process aborted on an assertion in `MessageBuffer.invalidate`).
