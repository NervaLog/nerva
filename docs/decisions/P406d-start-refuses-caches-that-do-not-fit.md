---
id: P406d
date: 2026-11-13
area: Errors
---

# `nerva start` refuses caches that do not fit the memory it can see, with NRV-E0723

At start, a replica takes the smallest of `MemTotal` and its cgroup's limit (v2 `memory.max`, or
v1 `memory.limit_in_bytes`), less a 256 MiB reserve, as its budget. Its allocator (a
`BudgetAllocator` of Nerva's, under the vendored `CountingAllocator`) fails any allocation past the
budget before asking for the memory, and `command_start` turns that `OutOfMemory` into
NRV-E0723: exit 1, blame operator, naming `--cache-grid` and `--cache-rows` with their values and
where the limit came from. An unparsable limit file is also a refusal. There is no flag to skip the
check. It runs at startup only, never in `prefetch` or `commit`.

The reason: today a replica whose caches exceed its machine or cgroup is OOM-killed with no message
of Nerva's (#127: 3.0 GB at the defaults on 4 GB Machines). Budgeting the real allocations, not
estimating from the flags, stays right when a release moves the fixed part. The implementing slice
first proves that `Replica.open` writes nothing to the data file before its last allocation, and
stops if it does.

What it costs: a replica that used to start and run on overcommitted memory now refuses; neighbours
on the machine (a gateway, an exporter) are not counted, which is the sizing table's job.
