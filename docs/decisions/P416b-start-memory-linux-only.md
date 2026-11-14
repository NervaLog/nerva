---
id: P416b
date: 2026-11-13
area: Errors
amends: P406d
---

# The memory refusal applies to Linux only

**Decision.** On a host that is not Linux, `start_memory.read` reports no limit (`unlimited`) and
`nerva start` takes no memory budget worth refusing on. NRV-E0723 is a Linux refusal.

**Why.** macOS has no `/proc/meminfo` or cgroups, so reading them there refused every start: the
macOS smoke test of the release binary failed on this pull request's first CI run with
`NRV-E0723 ... /proc/meminfo cannot be used`. The OOM kill the refusal answers is Linux's, and the
brief's hosts are generic Linux VMs (P406).

**Cost.** A Mac running a replica with caches larger than its memory is not refused. Macs run
development replicas, not the production ones R3 tunes.
