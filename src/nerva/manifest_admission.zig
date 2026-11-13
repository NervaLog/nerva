//! The primary refuses new requests before the LSM manifest is exhausted (#334).
//!
//! The manifest's node pool is a fixed size (`constants.lsm_manifest_memory_size_default`) and the
//! forest's table count has a limit (`Forest.manifest_log_compaction_pace.tables_max`). Reaching
//! either ends the replica with a fatal exit (status 3, NRV-E0721; status 6, NRV-E0722) at the same
//! op on every replica and again on every restart, and nothing committed can then be exported. Both
//! are functions of the committed log, so the primary can see them coming: it admits a request only
//! while enough nodes are free and enough tables remain for everything already admitted (the ops
//! in its pipeline, which have not yet been compacted into the manifest) to land. The check is the
//! primary's own policy; it adds nothing to the log, so determinism is untouched, and a backup that
//! becomes primary applies the same check to what it sees.
//!
//! The reserve is a bound, not a measurement. A bar (`lsm_compaction_ops` ops) inserts at most
//! `compaction_tables_input_max + 1` tables per tree (the level-A table moved down, the level-B
//! tables rewritten, and a flushed table), and each inserted table can split at most one node of
//! the level's keys and one of its tables, so `nodes_per_table` is 2. Ops in flight span at most
//! `ops_in_flight / lsm_compaction_ops + 2` bars.

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const Storage = @import("../storage.zig").StorageType(@import("../io.zig").IO);
const StateMachine = @import("state_machine.zig").StateMachineType(Storage);
const compaction = @import("../lsm/compaction.zig");

/// What the manifest holds now.
pub const Usage = struct {
    /// Nodes still free in the manifest's pool.
    nodes_free: u32,
    /// Tables in the forest's manifest.
    tables: u32,
    /// The most tables the forest's manifest log may hold.
    tables_max: u32,
};

/// Each inserted table can acquire a node for its level's keys and one for its tables.
pub const nodes_per_table = 2;

/// The tables that the ops already admitted can still insert: `trees` trees, at most
/// `tables_per_tree_per_bar` of them per bar, over the bars `ops_in_flight` ops span.
pub fn tables_reserve(
    trees: u32,
    tables_per_tree_per_bar: u32,
    ops_in_flight: u32,
    ops_per_bar: u32,
) u32 {
    assert(trees > 0);
    assert(tables_per_tree_per_bar > 0);
    assert(ops_in_flight > 0);
    assert(ops_per_bar > 0);
    const bars = std.math.divCeil(u32, ops_in_flight, ops_per_bar) catch unreachable;
    return (bars + 1) * trees * tables_per_tree_per_bar;
}

/// Whether the primary admits a new request given what the manifest holds and the tables that
/// admitted ops can still insert. False once either limit could be reached.
pub fn admits(usage: Usage, reserve_tables: u32) bool {
    assert(reserve_tables > 0);
    assert(usage.tables <= usage.tables_max);
    const reserve_nodes = reserve_tables * nodes_per_table;
    if (usage.nodes_free < reserve_nodes) return false;
    return usage.tables_max - usage.tables >= reserve_tables;
}

test "manifest_admission: the reserve covers every bar of ops in flight" {
    // 4 trees, 9 tables per tree per bar, 64 ops over 32-op bars: 2 bars + 1.
    try std.testing.expectEqual(3 * 4 * 9, tables_reserve(4, 9, 64, 32));
    // One op more spans another bar.
    try std.testing.expectEqual(4 * 4 * 9, tables_reserve(4, 9, 65, 32));
    try std.testing.expectEqual(2 * 4 * 9, tables_reserve(4, 9, 1, 32));
}

test "manifest_admission: admits at the bound and refuses one past it" {
    const reserve: u32 = 10;
    const nodes_needed = reserve * nodes_per_table;
    var usage: Usage = .{ .nodes_free = nodes_needed, .tables = 90, .tables_max = 100 };
    try std.testing.expect(admits(usage, reserve)); // Exactly at both bounds.
    usage.nodes_free = nodes_needed - 1;
    try std.testing.expect(!admits(usage, reserve)); // One node short.
    usage.nodes_free = nodes_needed;
    usage.tables = 91;
    try std.testing.expect(!admits(usage, reserve)); // One table short.
    usage.tables = 100; // The limit itself.
    try std.testing.expect(!admits(usage, reserve));
    usage.tables = 0;
    usage.nodes_free = 0; // An empty pool.
    try std.testing.expect(!admits(usage, reserve));
}

test "manifest_admission: the reserve is a small part of the default pool" {
    // A reserve as large as the pool would refuse every request on a healthy cluster.
    const reserve_tables = tables_reserve(
        StateMachine.Forest.tree_infos.len,
        compaction.compaction_tables_input_max + 1,
        constants.pipeline_prepare_queue_max + constants.pipeline_request_queue_max,
        constants.lsm_compaction_ops,
    );
    const nodes_default = constants.lsm_manifest_memory_size_default /
        constants.lsm_manifest_node_size;
    try std.testing.expect(reserve_tables * nodes_per_table <= nodes_default / 4);
    try std.testing.expect(reserve_tables <= StateMachine.Forest.manifest_log_compaction_pace.tables_max / 4);
}
