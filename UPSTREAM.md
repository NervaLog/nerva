# Upstream: TigerBeetle

Nerva vendors the consensus, storage, IO and simulation layers of
[TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) (Apache 2.0, see `LICENSE` and `NOTICE`).

- **Pinned commit:** `6f8e6b58d1811bb21cd6ea4fb93cb2e9d77abd81` (2026-09-27)
- **Zig:** 0.14.1 (same as upstream at that commit)

Vendored code is copied, not linked: there is no submodule or subtree. To pull an upstream fix,
diff the relevant upstream files between the pinned commit and the new one, apply the hunks here,
then update the pinned commit above. **Every local change to a vendored file must be listed
below**, so that this diff stays tractable.

## What we kept

| Path | What it is |
|---|---|
| `src/vsr/**`, `src/vsr.zig` | Viewstamped Replication: replica, journal (WAL), superblock, grid, free set, state sync, client |
| `src/lsm/**` | LSM forest: trees, grooves, compaction, manifest, scans |
| `src/io/**`, `src/io.zig`, `src/storage.zig` | io_uring / kqueue IO, Direct IO storage |
| `src/message_*.zig` | Message bus, pool, buffer |
| `src/stdx/**` | Standard library extensions |
| `src/trace/**`, `src/trace.zig` | Tracing and metrics |
| `src/testing/**`, `src/vopr.zig`, `src/fuzz_tests.zig` | Deterministic simulator (VOPR), storage/network simulators, fuzzers |
| `src/aof.zig`, `src/multiversion.zig` | Append-only file of prepares; multi-version binary support (unused for now) |
| `docs/TIGER_STYLE.md` | Coding style |

## What we dropped

The accounting state machine and its types (`state_machine.zig`, `state_machine/`,
`state_machine_tests.zig`, `state_machine_fuzz.zig`, `tigerbeetle.zig`), the server CLI
(`tigerbeetle/`), language clients (`clients/`), change data capture (`cdc/`), the REPL
(`repl/`, `repl.zig`), the Vortex system tests (`vortex.zig`, `testing/vortex/`,
`integration_tests.zig`, `testing/tmp_tigerbeetle.zig`), release and build tooling (`build/`,
`build_multiversion.zig`, `scripts/`, `scripts.zig`), `copyhound.zig`, `inspect_snapshot.zig` and
`docs_website/`.

`src/lsm/forest_fuzz.zig` was also dropped: it is written against the accounting `Account` type.
Restore an equivalent once Nerva's forest has real grooves.

## Derived files

`src/nerva_main.zig` (the `nerva` binary) is derived from TigerBeetle's `src/tigerbeetle/main.zig`,
trimmed to `format`, `start` and `version` (Nerva has since added `api` and `view`); `src/nerva/cli.zig` follows the structure of
`src/tigerbeetle/cli.zig`. They are Nerva's own files, not patches, but upstream fixes to those
originals should be checked for relevance.

## Local patches to vendored files

| File | Change |
|---|---|
| `build.zig` | Rewritten: the `nerva` executable, `run`, `check`, `test`, `test:unit`, `test:fmt`, `test:integration`, `test:api`, `test:views`, `test:release` (N61), `test:demo`, `vopr`, `fuzz`, `bench` and `bench:load` (N55). No clients, multiversion or release fetching. Release is `0.0.6`, clients from `0.0.4` (P123; `0.0.5` in P90; `0.0.4` and clients from `0.0.4` in N62; `0.0.3` and clients from `0.0.2` in N60, `0.0.2` from N43, `0.0.1` before). `test:release` also builds this code under `release_client_min`, as a client of the oldest accepted release (P90). Nerva's own CI and release workflows are in `.github/workflows/` (not vendored). |
| `src/vsr.zig` | Re-exports `nerva` and `state_machine` instead of `tigerbeetle`, `state_machine`, `cdc`, `tb_client`, `repl`. |
| `src/vsr/replica.zig` | `Options.peer_keys`: `open` gives the message bus a `PeerAuth` of the keys, the cluster, the release and this data file's origin (P102); `on_message` treats a handshake command as misdirected; `tick_peer_connections` gives `on_origin_announced` the origin a peer's handshake proved, when the bus has `peer_origin_authenticated`. Request timing is enabled when `StateMachine.Operation == nerva.Operation` (was `tigerbeetle.Operation`). Option `release_peers_strict` (off by default): `on_message` records each peer's release from its pings and pongs and drops messages that `nerva/release_peers.zig` does not admit; `tick` forgets the release of a peer whose connection is gone and pings a newly connected one; the ping timeout's body moved to `send_ping(peer)` (N61, #34). `on_request` evicts a client whose request names the state machine's pulse operation by its raw value (`nerva/internal_operations.zig`, N67, #33). Pings and pongs carry `superblock.working.vsr_state.origin`; `on_message` also records each peer's origin and last release (`peer_origins`, `peer_releases_last`, kept across connections), passes them, this replica's origin and `release_client_min` to `release_peers.admits`, and `on_origin_announced` logs a peer of another export and exits with `origin_mismatch` when `release_peers.origin_refused` (P90, #81). |
| `src/vsr/superblock.zig` | `VSRState.origin: [32]u8`, from 32 of its `reserved` bytes (779 → 747): the export a data file was imported from, zero when formatted. `VSRState.root` and `FormatOptions` take it (default zero); `monotonic` asserts that no update after the root state changes it (P90, #81). |
| `src/vsr/message_header.zig` | `Ping.origin` and `Pong.origin: [32]u8`, from their `reserved` bytes (94 → 62, 112 → 80), with no default so that every ping and pong sets it; a comptime block asserts that no other field moved (P90). |
| `src/vsr.zig` (`FatalReason`) | `origin_mismatch = 8` (P90). |
| `src/vsr.zig` (`Command`), `src/vsr/message_header.zig` | Commands `peer_hello = 25`, `peer_challenge = 26`, `peer_proof = 27` (new ordinals; the deprecated ones stay retired), header-only, with `PeerHello`, `PeerChallenge` and `PeerProof` (nonces, MACs and origins in the command bytes, offsets asserted at comptime); `peer_type` is `.unknown` for them, since the message bus handles them before it classifies a peer (P102). |
| `src/message_bus.zig` | The replica handshake (P102), when `Options.peer_auth` is set (only by a replica given cluster keys; null on clients' buses and in the fuzzer's keyless runs, where the bus behaves as upstream's): per-connection `auth` state; a dialed connection sends `peer_hello` instead of starting its send loop, and its queued messages wait, bounded by the send queue, until both sides have proved the key; `recv_buffer_advance` consumes the handshake (`handshake_recv`) and closes a connection that sends a replica message before it, a non-client message as a client, a hello from an index at or above its own, a proof under neither key, or, after it, a message claiming another replica, a repeated handshake message, or a ping or pong announcing another origin than the proof covered; `tick` closes connections still handshaking after `peer_auth.handshake_ticks_max`; connect attempts reset only once authenticated; `peer_origin_authenticated(replica)`, the origin a replica's last completed handshake proved, kept after the connection closes. |
| `src/message_bus_fuzz.zig` | In half the runs replicas have cluster keys (handshake commands then excluded from the random messages); in half of those, replica 2 has another key, its replica messages are not expected, and the callback asserts that none passes between it and the others (P102). |
| `src/vsr/client.zig` | `on_messages` drops a buffer that arrives after the client's eviction (`buffer.invalidate(.evicted)`, as for the rest of the buffer that carried it) instead of asserting: Nerva's eviction callback does not deinit the client inside the receive path (#52), and one IO pass can deliver another replica's messages after the eviction (#74). |
| `src/message_bus.zig`, `src/testing/cluster/message_bus.zig` | Added `replica_connected(replica)` for the above; the simulated bus has no connections and answers true (N61). `tick_connect` counts the replicas whose socket could not be opened (`init_tcp`, such as an address family the kernel lacks) instead of asserting that each dial holds a connection, and `connect_connection` says such an error once per replica until a socket opens (`replicas_unopened`, a new per-replica flag; the dial backoff is untouched), since it retries every tick (#92). Upstream has the same assertion. |
| `src/testing/cluster.zig` | `Options.release_peers_strict`, passed to every replica (N61). `Options.origin`, given to every replica's format and reformat (P90). `Options.commit_stall_probability`, passed to every replica; when null and the state machine is Nerva's, `init` draws it per seed from 2/5, 1/5 and 0 with its own PRNG (the seed and a fixed salt, so no other draw of a seed moves) and logs it with the run's parameters (P143b; owner-approved 2026-10-21, PR #136). Nerva's own default stays 2/5. |
| `src/trace/event.zig` | Operation and tree enums are derived from `nerva.zig` instead of `tigerbeetle.zig` / `state_machine.zig`. The tree enum also names every id up to `tree_id_test_max` (15) that Nerva does not use (`test_<id>`), because vendored test grooves (`lsm/scan_fuzz.zig`) use ids 1–15, which TigerBeetle's trees covered (#6, N46). |
| `src/aof.zig` | `replay_message` replays every non-reserved operation (was an accounting-specific allowlist). |
| `src/config.zig`, `src/constants.zig` | Removed the accounting object-cache defaults (`cache_accounts_size_default` etc.). |
| `src/vopr.zig` | State machine choice is `nerva` (default) or `testing`, instead of `accounting` or `testing`. `on_reply` also passes the op the request committed at (`commit.prepare.header.op`), so the workload checks replies against it exactly; in `--vopr-log=short` mode the `workload` scope prints too, for its end-of-run summary (N49). The `nerva` lane runs one release, with no simulated upgrades, and `release_peers_strict` (N61); that release is 0.0.2, accepting clients from 0.0.1, and its clients run either, by seed; every replica's origin is none or a random one, by seed (P90). The main loop's "replicas reached the latest release" reads the lane's own releases (`options.cluster.releases`), not the global table: with the `nerva` lane on 0.0.2 it otherwise never held, and every seed ran to `ticks_max_requests` (P90). The `testing` lane is unchanged. |
| `src/testing/state_machine.zig` | The testing workload's `on_reply` takes the op argument above, unused (N49). |
| `src/fuzz_tests.zig` | Removed the `lsm_forest`, `state_machine` and `signal` (C client) fuzzers. Added Nerva's own: `nerva_adds`, `nerva_http_head`, `nerva_documents` (in `src/nerva/`, N46), with their smoke sizes. |
| `src/unit_tests.zig` | Regenerated by its own quine test (`SNAP_UPDATE=1`). |
| `src/lsm/scan_builder.zig` | Added `scan_unique_key_range`, the range form of `scan_unique_key` (the same scan, with two bounds instead of one value), for backfilling a view over a table's rows and for reading a view's groups (N52). Added `scan_prefix_range`, the same for a secondary index's prefixes at any timestamp, for reading a group's members in value order and its versions by op (N62). |
| `src/lsm/scan_tree.zig` | A value block that matches a scan is read as its used values (`Table.value_block_values_used`, as the same function already does above) instead of the whole block cast to values, which only compiled when the object size divides the block's payload. Nerva's records and record changes are 512-byte objects (P123b); the values and their order are unchanged. Approved by the owner in session, 2026-10-16. |
| `src/trace.zig` | Snapshot updated: tree id 1, which the sample trace names, is Nerva's `Row.timestamp`. |
| `src/vsr/replica_format.zig` | Golden checksum of a formatted data file updated. The only cause is the release string (`0.0.1` then `0.0.2`, vs upstream's test release `65535.0.0`); verified by building with the old release and getting the old checksum. Moving from `0.0.2` to `0.0.3`, to `0.0.4`, and to `0.0.5` (with `VSRState.origin`, zero when formatted) left it unchanged (N60, N62, P90). |
| `src/io/linux.zig` | Added `IO.run_once(nanoseconds)`: submit, wait up to `nanoseconds` for a completion, run the ready callbacks and return, built from the existing private helpers (N51). |
| `src/io/darwin.zig`, `src/io/windows.zig` | Added `IO.run_once`, which calls `run_for_ns` (correct, without the early return; production is Linux) (N51). |
| `src/io/test.zig` | Added the test "run_once returns after the first completion" (Linux only) (N51). |
| `src/stdx/benchmark/bench.zig` | Added `Bench.metric(name, value, unit)`: in benchmark mode, one `bench-json:` line per result for the nightly job (N55). |

## Known differences in behaviour

- Metrics are still emitted with the `tb.` prefix.
- `stdx` test `benchmark.perf: usage example` fails in sandboxes that deny `perf_event_open`
  (e.g. cloud containers with `perf_event_paranoid=2`). It fails identically on unmodified upstream.
