# Nerva 1.0 — Design goals

**Motivating workload: budget and authorization services for AI agents.** Nerva is dog-fooded
on such a service, but specialized for none (DECISIONS N31, N39): it grows only general
capabilities, and an application's own rules live in the application.

Nerva 1.0 is done when a service like that can answer an auditor's three questions — *what ran,
who authorized it, is it current?* — from properties of its database instead of from
application discipline spread across several stores. The pitch this enables: **every
authorization, receipt and report is a position in one verifiable log.**

Status of this document: agreed 2026-10-04. v0.1 (the core loop in the
[README roadmap](../README.md#roadmap)) is a step towards it.

## Why this workload

A typical agent-budget service keeps balances in one store and facts in another, and the gaps
that follow are the goals below.

| Typical arrangement | The gap | Nerva 1.0 goal |
|---|---|---|
| A ledger for balances, a relational database for facts, reconciliation between them | Two truths to keep in step | G1 |
| Freshness from a counter kept beside the data | A reader can act on a stale question after a crash | G2 |
| One receipt should map to one run | Two workers can both claim it without a lease in the store | G3 |
| Reports, spend rollups, obligations | Built by hand from the facts | G4 |
| Exactly-once spending | In-flight external calls repeat after a crash | G5 |
| Answers journalled by hand so re-runs decide the same way | Reconstructing "what did the agent know when it decided?" | G6 |
| Suspend, resume and approvals in local files | Unattributed approvals; locks per directory | G7 |
| Many agents spending from one budget | Contention on hot accounts | G8 |

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

**G7. Durable, attributed workflow state.** Suspended work, pending approvals and their answers
live in the replicated log, and every approval is attributed to an identity. No per-directory
locks, no files that two workers can both claim.

**G8. Hot balances without conflicts.** Optimistic transactions conflict when many agents draw
on one budget at once — exactly the contended pattern TigerBeetle was built for. Nerva 1.0
offers conditional, commutative operations applied inside the commit (for example "reserve up to
X if the balance allows"), the way TigerBeetle applies transfers, so a hot budget does not
serialize clients through retries.
*Decided* (N75, closing what was this goal's open decision): balances move to Nerva. Declared
ledgers make conservation the cluster's job: their fields change only by pairs of adds that move
one amount between them, never below a floor, whoever sends the request. Nerva still supports
balances kept in a dedicated ledger, with Nerva holding facts, receipts and views.

## Non-goals for 1.0

- Holding real money before Nerva has an external correctness review comparable to
  TigerBeetle's Jepsen analysis. (The owner accepted this risk on 2026-10-05, for the first
  application; the VOPR's ledger invariant under faults, that application's contract tests on
  both ledgers, a week of staging with a restore drill and a verified cutover stand in for the
  review.)
- SQL and general-purpose queries; full PostgreSQL compatibility.
- Object-storage tiering, external operators (embeddings) and other north-star features the
  workload does not need.
- Application-specific protocols or routes (N39).

## Milestones

1. **The receipt race as a simulator scenario.** ✅ Two daemons claim the same receipt under crash
   and disk-fault injection; exactly one wins, every time. Uses only the commit core (G3).
   The VOPR workload races clients over 1–4 receipts and checks that each receipt's sequence
   advances by exactly one per winning claim; `state_machine_tests.zig` has the deterministic
   cases (`receipt race: …`).
2. **Server and client** (`nerva format`, `nerva start`, client access).
   - 2a ✅ The `nerva` binary and a blocking Zig client (`src/nerva/client.zig`), proven by
     `zig build test:integration`: three real replicas, the receipt race between two clients,
     change-feed paging, and a replica crash and restart.
   - 2b ✅ `nerva api`: the core operations as JSON over HTTP (N33), checked against a model.
     (An earlier, application-specific gateway was removed in N39.)
3. ✅ **Positioned reads** (G2): `lookup_rows` results carry `op_read`; views answer at a
   watermark, with `min_op` waits (N21–N23).
4. **As-of reads and workflow state** (G6, G7).
   - G6 ✅ `get_history` reads any row as of any op, through an index on the change feed
     (N27); `nerva api` serves `row?as_of=`, and declared views answer `as_of` any op.
   - G7 open: larger values than 80-byte rows ✅ (documents of up to 64 KiB through
     `nerva api`, N41); attributed approvals still need an identity model (N30).
5. ✅ **Declared views** (G4): layouts and view declarations in the log, computed by `nerva view`
   latest or as of any op, with a hash per answer (N34, N35); demonstrated by the seat and
   canvas demos under crashes (N36, N38). Views are also maintained by the state machine
   itself, with a hash every replica agrees on (N52), `min` and `max` included, read as of any
   op (N62), and served whole by `nerva api`, which `nerva view` recomputes to the byte (N66).
6. **Effect sinks** (G5) and **conditional operations for hot balances** (G8).
   - G8 ✅ adds: bounded, clampable changes to a 64-bit field inside the commit, which never
     conflict; `delta_from` moves exactly what an earlier add took (N42). The VOPR checks that
     hot budgets conserve what was funded under crashes and faults. Balances move to Nerva:
     declared ledgers (N75) refuse any move that is not a balanced pair within floors.
7. **First production use**: the dog-fooding service's facts, receipts and views on Nerva
   through the generic API, balances in declared ledgers (G8, N75).
