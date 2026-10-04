# Decision log

Decisions taken while building Nerva towards 1.0, with the reason for each and what it costs.
Newest sections at the bottom. Dates are 2026-10-04 unless stated. Botpike is the first customer
(see [GOALS-1.0.md](./GOALS-1.0.md)); where a decision rests on reading Botpike's repositories,
the repository and file are named.

Decisions marked **(assumed)** were taken without the owner's input under a standing
instruction to proceed on reasonable assumptions; they are the first to revisit.

## Foundations (recorded after the fact)

**N1. Vendor TigerBeetle's consensus, storage, IO and simulator; write our own state machine.**
Pinned at `6f8e6b5`, copied rather than linked (see UPSTREAM.md). Reason: VSR, protocol-aware
recovery and the VOPR are the hardest parts to build and the most valuable. Cost: a permanent
fork; upstream fixes are pulled by hand.

**N2. Rows are fixed-size: `(table: u32, id: u64)` → 80-byte value.**
TigerBeetle's LSM stores fixed-size values only. Cost: anything longer must be chunked by the
caller (see N12).

**N3. Deletes are tombstones.**
Upstream `Groove.remove` is untested and compiles only in verification builds. Tombstones also
keep versions exact: a row deleted and re-created never looks unchanged. Cost: rows are never
reclaimed.

**N4. One batch is one transaction; reads assert the version (`op`) they saw.**
Optimistic validation at commit, serial execution, so point reads are serializable. Fits
TigerBeetle's multi-batch framing with no framework change. Cost: hot rows conflict (G8).

**N5. The integration test is an executable, not a `zig test`.**
Test binaries use the `test_min` config; the client must share the server's production config.

## Milestone 2b: how Botpike reaches Nerva

**N6. The gateway speaks the Botpike runtime's ledger protocol, not a new JSON API.**
`Botpike/runtime` already defines a small HTTP protocol between its daemon and a ledger
(README, "The ledger protocol"): `POST` with `key=value` lines, `X-Ledger-Key`, sixteen routes,
a reference implementation (`ledger/ledgerd.py`) and an acceptance bar — "the same journal
against it as against `ledgerd.py`". Botpike's app serves the same protocol from TigerBeetle +
PostgreSQL (`/runtime-ledger/v1/...`). Serving it from Nerva gives Nerva a real consumer with no
change to Botpike, and exercises G1 (one log), G3 (`/v1/claim` is the receipt race) and G7
(blocks, approvals and journalled results). A general-purpose JSON API is deferred until a
consumer needs it. Cost: the gateway is shaped by one customer's protocol; it lives in
`src/nerva/ledgerd/`, separate from the core, so it can be replaced without touching the core.

**N7. (assumed) Nerva's ledger is a reference ledger, not Botpike's money.**
GOALS-1.0 keeps Botpike's balances in TigerBeetle until Nerva has an external correctness review.
`nerva ledgerd` therefore replaces `ledgerd.py` (dev, CI, demos), not Botpike's production
adapter. Revisit with the G8 decision.

**N8. Acceptance is differential: identical requests to `ledgerd.py` and to Nerva must produce
identical replies.**
Scripted scenarios plus randomized sequences, compared byte for byte (status, every reply line,
every journal line). The runtime's own scenarios (`demo.sh`, `tests/*.sh`) need the Unison
toolchain, which this sandbox cannot download (Unison Share and GitHub release downloads are
blocked); running them against Nerva is a follow-up wherever `ucm` is available. A copy of
`ledgerd.py` is kept as the oracle, with its source commit.

**N9. Error replies match on status and the presence of `error=`, not on message text.**
`ledgerd.py`'s 400 messages are Python exception strings (`'request_id'`, `invalid literal for
int()…`). The runtime treats any non-2xx or `error=` reply as a failure and never parses the
text (README: "a reply is an answer only if…"). Cost: operators see different wording.

**N10. The gateway is part of the `nerva` binary (`nerva ledgerd`), single-threaded, one
request at a time.**
`ledgerd.py` holds one global lock; one Nerva client allows one request in flight. Sequential
handling gives the same serialization with no locking. The listen address and cluster come from
flags; the key from `LEDGER_KEY`, as in `ledgerd.py`, so it never appears in `ps`. Cost:
throughput is one route at a time per gateway (adequate for a reference ledger).

**N11. Each route is one Nerva transaction over a key-value view of the ledger; conflicts
retry.**
`ledgerd.py` keeps a flat dict (`ledger.txt`), an append-only journal and a results file. The
gateway keeps the same keys as Nerva rows, reads what a route needs (recording each row's
version), computes the reply with the same rules, and commits reads plus writes atomically. A
`conflict` (another gateway on the same ledger) re-runs the route from scratch, up to 8 times,
then answers 503. Route logic is written against a small store interface, so it is unit tested
against an in-memory store and run against Nerva unchanged.

**N12. (assumed) Values longer than a row are chunked across rows.**
Memos, journal lines and recalled results are arbitrary text; rows hold 80 bytes (N2). A value
is stored as chunk 0 (header: key length, total length, then data) plus chunks 1..n of 80 bytes,
each a row whose id is derived from the key (N13). Reading costs one lookup for chunk 0 and one
for the rest; a shorter rewrite leaves stale tail chunks, which the header's length makes
unreachable. A value is at most 64 KiB. Cost: write amplification and an extra round trip for
long values. This is the "variable-size data" open question of the white paper; native support
would replace this encoding without changing the protocol.

**N13. Row ids are the first 8 bytes of SHA-256 over (ledger, generation, key, chunk).**
Keys are strings (`hold.planner-1:0:3`); rows are keyed by `u64`. SHA-256 is stable across Zig
versions (unlike `std.hash`). Chunk 0 stores the key itself, so a 64-bit collision is detected
on read and answered 500 rather than read as another key's value.

**N14. One Nerva cluster hosts many ledgers; `--ledger=<id>` picks one.**
`ledgerd.py` is one ledger per process and state directory; Botpike runs many runs. A ledger's
rows live in one table (1000), namespaced by the hash (N13); its root row (table 1001, id =
ledger) holds a generation number.

**N15. `/v1/admin/init` starts a new generation instead of deleting rows.**
`ledgerd.py` resets the dict and deletes its journal and results. Bumping the generation makes
every old key unreachable in one write, and keeps the old generation's history in the log for
audit. Cost: old rows are never reclaimed (as N3).

**N16. `/v1/status` lists state keys from an index row, since Nerva has no range scans.**
`ledgerd.py` lists every key starting `seq.`, `hold.`, `resuming.` or `blocked.`. The gateway
keeps that set of key names as one more chunked value, updated whenever such a key appears or
disappears. Cost: an extra write on those routes; the list is bounded by the 64 KiB value limit.

**N17. Inputs outside what `ledgerd.py` documents are not chased for parity.**
Python's `int()` accepts `+5`, ` 5` and `1_000`; `bytes.fromhex` accepts spaces between bytes;
`str.splitlines` splits on Unicode line separators. The gateway accepts canonical decimal and
hex and splits lines on `\n`, `\r\n` and `\r`, and the differential fuzzer sends what the runtime
sends. Invalid UTF-8 inside hex text *is* matched (replaced with U+FFFD per maximal subpart, as
Python does), because agent-chosen memos reach the journal.

**N18. A route's writes commit even when it answers 400; routes check before they write.**
`ledgerd.py` persists only at explicit `write_ledger()` calls, and `count_denial` persists
immediately, so `/v1/refused` with a bad `memo_hex` answers 400 yet counts the denial. The
gateway commits whatever a route wrote before failing, and every route computes its checked
totals before its first write, so a 400 leaves exactly what `ledgerd.py` leaves.

**N19. Journal lines are stored under random unique keys, not a shared counter.**
Found by the two-gateway race test: a `journal.count` row written by every journaling route
made any two of them conflict, and a request gave up with 503. Unique keys remove that hot row;
the change feed records the order in which lines were committed. Cost: reading the journal back
in order means reading the change feed, not counting keys.

**N20. Conflicts back off with random jitter, up to 32 attempts, then answer 503.**
Also found by the race test: immediate retries let two gateways keep colliding. Backoff is
1..min(2^attempt, 64) ms. A 503 is safe: the runtime treats it as a crash and every route is
safe to repeat (runtime README). Contention on the shared balance (`available`) remains
inherent to one budget; that is G8's problem, not the gateway's.
