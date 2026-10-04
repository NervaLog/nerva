# Nerva 1.0 — Design goals

**First customer: [Botpike](https://github.com/Botpike/app)**, budget leases for AI agents.

Nerva 1.0 is done when Botpike can answer an auditor's three questions — *what ran, who
authorized it, is it current?* — from properties of its database instead of from application
discipline spread across two stores. The pitch this enables: **every authorization, receipt and
report is a position in one verifiable log.**

Status of this document: agreed 2026-10-04. v0.1 (the core loop in the
[README roadmap](../README.md#roadmap)) is a step towards it; 1.0 is "Botpike-ready".

## Why Botpike

Botpike today keeps balances in TigerBeetle and facts in PostgreSQL, and its own documents name
the gaps that follow. Each 1.0 goal below closes one of them.

| Botpike today | The gap, in Botpike's own words | Nerva 1.0 goal |
|---|---|---|
| TigerBeetle for balances, PostgreSQL for facts, reconciliation rebuilds from TigerBeetle | `AGENTS.md` forbids "any dual truth" and warns against breaking reconciliation | G1 |
| Freshness from a per-agent sequence counter | The control room "can show a stale question" after a crash | G2 |
| One receipt should map to one run | "Two daemons … could still both claim it. Closing that needs a lease in the ledger." | G3 |
| Weekly report, spend rollups, obligations | Built by hand from the facts | G4 |
| Exactly-once spending | "In-flight provider calls repeat after a crash" | G5 |
| Allowance answers journalled by hand so re-runs decide the same way | Reconstructing "what did the agent know when it decided?" | G6 |
| Suspend, resume and approvals in files under a state directory | "Approvals are not signed"; the receipt lock is per state directory | G7 |
| Many agents spending from one org budget | Contention on hot accounts | G8 |

## Goals

**G1. One log, no dual truth.** A reservation and the record of its attempt, a settlement and
its receipt, commit in the same transaction. There is nothing to reconcile because there is only
one history.

**G2. Every read names its position.** Every reply is stamped with the op it reflects. A reader
can demand "at least op M" (read-your-writes on any view) or "as of op N". Freshness is a
property of the store, not a counter maintained beside it.

**G3. Claims are compare-and-set.** Exclusive ownership (a receipt, a lease, an approval) is a
read at the version seen plus a write; a second claimant gets `conflict`.
*Delivered by the commit core, and demonstrated* by the receipt race (Milestone 1).

**G4. Derived state is declared and verifiable.** Reports, rollups and obligations are views
maintained from the log, each with a watermark, and two copies of a view can compare a hash at
op N. The report cannot disagree with the ledger.

**G5. Effects happen once on Nerva's side.** Outbound actions are views whose sink is an
effect, keyed by `(view, row, op)`. Honest limit, kept in the docs: a provider call in flight
during a crash is repeated unless the provider honours that idempotency key.

**G6. History is queryable as of any op.** "What was this agent's allowance when it decided?"
is a read at the op of the decision, not a hand-kept journal.

**G7. Durable, attributed workflow state.** Suspended agents, pending approvals and their
answers live in the replicated log, and every approval is attributed to an identity. No
per-directory locks, no files that two daemons can both claim.

**G8. Hot balances without conflicts.** Optimistic transactions conflict when many agents draw
on one budget at once — exactly the contended pattern TigerBeetle was built for. Nerva 1.0
offers conditional, commutative operations applied inside the commit (for example "reserve up to
X if the balance allows"), the way TigerBeetle applies transfers, so a hot budget does not
serialize clients through retries.
*Open decision:* whether Botpike moves balances to Nerva at 1.0, or keeps TigerBeetle for
balances and uses Nerva for facts, receipts and views. Nerva must support the second
arrangement either way.

## Non-goals for 1.0

- Holding real money before Nerva has an external correctness review comparable to
  TigerBeetle's Jepsen analysis. Until then Botpike's balances stay in TigerBeetle.
- SQL and general-purpose queries; full PostgreSQL compatibility.
- Object-storage tiering, external operators (embeddings) and other north-star features Botpike
  does not need.

## Milestones

1. **The receipt race as a simulator scenario.** ✅ Two daemons claim the same receipt under crash
   and disk-fault injection; exactly one wins, every time. Uses only the commit core (G3).
   The VOPR workload races clients over 1–4 receipts and checks that each receipt's sequence
   advances by exactly one per winning claim; `state_machine_tests.zig` has the deterministic
   cases (`receipt race: …`).
2. **Server and client** (`nerva format`, `nerva start`, a client library) so Botpike can call
   Nerva outside the simulator.
   - 2a ✅ The `nerva` binary and a blocking Zig client (`src/nerva/client.zig`), proven by
     `zig build test:integration`: three real replicas, the receipt race between two clients,
     change-feed paging, and a replica crash and restart.
   - 2b An HTTP/JSON gateway (`nerva gateway`) so Botpike (Kotlin, JDK 21) can call Nerva without
     native code. Chosen over a C ABI + JNI client (more work) and Java FFM (preview on JDK 21).
3. **Positioned reads and the first view** (G2, G4): Botpike's spend rollup maintained from the
   change feed, read at a position.
4. **As-of reads and workflow state** (G6, G7).
5. **Effect sinks** (G5) and **conditional operations for hot balances** (G8).
6. **Botpike integration**: facts, receipts and views on Nerva, balances per the G8 decision.
