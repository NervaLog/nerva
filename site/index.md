# Nerva

A research database where **derived state is declared, not hand-built**: base data and every
index, aggregate, change feed and history are deterministic functions of one ordered, replicated,
hash-chained log, and every read says which log position it reflects.

Current release: **v{{version}}**. Status: toy / research. Do not put data in it that you cannot
lose.

## Start here

- **[Tutorial](../docs/TUTORIAL.md)**: from an empty directory to a running three-replica cluster, then every capability, step by step, with real output.
- **[Design and reference](../README.md)**: the design in one picture, the commit core's operations, running a cluster, the JSON API, ledgers, views and limits.
- **[Goals and milestones](../docs/GOALS-1.0.md)**: what 1.0 means, the eight goals (G1 to G8), and each milestone's state.
- **[Changelog](../CHANGELOG.md)**: what changed in each release, with examples and upgrade steps.

## Tutorial

1. [The idea in five minutes](../docs/TUTORIAL.md#part-0-the-idea-in-five-minutes)
2. [Build and start a cluster](../docs/TUTORIAL.md#part-1-build-and-start-a-cluster)
3. [Rows and versions](../docs/TUTORIAL.md#part-2-rows-and-versions)
4. [Transactions](../docs/TUTORIAL.md#part-3-transactions)
5. [The log: changes, history, time travel](../docs/TUTORIAL.md#part-4-the-log-changes-history-time-travel)
6. [Layouts: typed fields instead of hex](../docs/TUTORIAL.md#part-5-layouts-typed-fields-instead-of-hex)
7. [Adds and ledgers: counters and balances](../docs/TUTORIAL.md#part-6-adds-and-ledgers-counters-and-balances)
8. [Declared views](../docs/TUTORIAL.md#part-7-declared-views)
9. [Documents: larger values by key](../docs/TUTORIAL.md#part-8-documents-larger-values-by-key)
10. [Facts beside money: commit keys, records and indexes](../docs/TUTORIAL.md#part-9-facts-beside-money-commit-keys-records-and-indexes)
11. [Crashes, retries and upgrades](../docs/TUTORIAL.md#part-10-crashes-retries-and-upgrades)
12. [The Zig client](../docs/TUTORIAL.md#part-11-the-zig-client)
13. [Inside Nerva, for contributors](../docs/TUTORIAL.md#part-12-inside-nerva-for-contributors)
14. [Cheat sheet](../docs/TUTORIAL.md#cheat-sheet)

## Milestones to 1.0

A summary of [the milestones in the 1.0 goals](../docs/GOALS-1.0.md#milestones), which say what
each one delivered and what is left. The site's build fails when the goals list a milestone this
table does not.

| # | Milestone | Goals | State |
|---|---|---|---|
| 1 | The receipt race as a simulator scenario: two daemons claim one receipt under crashes and disk faults, and exactly one wins | G3 | ✅ Done |
| 2 | Server and client: the `nerva` binary, a Zig client, and `nerva api` (JSON over HTTP) | | ✅ Done |
| 3 | Positioned reads: every reply carries the op it reflects; `min_op` waits | G2 | ✅ Done |
| 4 | As-of reads and workflow state | G6, G7 | 🟡 As-of reads done; attributed approvals need an identity model |
| 5 | Declared views, maintained by every commit, with a hash every replica agrees on | G4 | ✅ Done |
| 6 | Effect sinks and conditional operations for hot balances | G5, G8 | 🟡 Adds and declared ledgers done; effect sinks open |
| 7 | First production use: the dog-fooding service's facts, receipts and views on Nerva | G1, G8 | 🟡 Engine side in v0.6.0; application side next |

## Built on TigerBeetle

Consensus (Viewstamped Replication), storage (an LSM forest on a checksummed block grid), io_uring
IO and the VOPR deterministic simulator are vendored from
[TigerBeetle](https://github.com/tigerbeetle/tigerbeetle), under Apache 2.0.
