//! Views over `nerva ledgerd` ledgers, maintained from the change feed (docs/DECISIONS.md N24).
//!
//! - `journal`: a ledger's journal lines in commit order (N19 left the order to the feed), each
//!   with the op that wrote it: the position to read the ledger as of (G6).
//! - `spend`: Botpike's agent spend rollup (own and subtree settled spend, settled and denied
//!   counts, depth), over the agent tree that the runtime's request ids encode (runtime D6:
//!   `agent:sequence:step`, then `/child:step` per sub-agent).
//!
//! Rows arrive as chunks (N12, N25). The view mirrors every ledgerd row, recognises chunk 0 by
//! its header (and by recomputing its id from the key it contains), and reassembles the value.

const std = @import("std");

const nerva = @import("../../nerva.zig");
const store = @import("../ledgerd/store.zig");

const Change = nerva.Change;
const value_size = nerva.value_size;

pub const LedgerdViews = struct {
    allocator: std.mem.Allocator,
    /// Every live ledgerd row (all ledgers, all chunks), by id.
    rows: std.AutoHashMapUnmanaged(u64, [value_size]u8) = .{},
    ledgers: std.AutoHashMapUnmanaged(u64, *Ledger) = .{},

    pub const Ledger = struct {
        generation: u64 = 0,
        journal: std.ArrayListUnmanaged(JournalLine) = .{},
        /// Agent path (segments joined by '/') → spend.
        spend: std.StringHashMapUnmanaged(Spend) = .{},
        /// `done.`/`denied.` key → what it contributed, so a rewrite replaces, not adds.
        contributions: std.StringHashMapUnmanaged(Contribution) = .{},
        arena: std.heap.ArenaAllocator,

        fn reset(ledger: *Ledger, generation: u64) void {
            ledger.journal = .{};
            ledger.spend = .{};
            ledger.contributions = .{};
            _ = ledger.arena.reset(.free_all);
            ledger.generation = generation;
        }
    };

    pub const JournalLine = struct { op: u64, line: []const u8 };

    pub const Spend = struct {
        own: u64 = 0,
        settled_count: u64 = 0,
        denied_count: u64 = 0,
    };

    const Contribution = struct { path: []const u8, kind: enum { settled, denied }, amount: u64 };

    pub fn init(allocator: std.mem.Allocator) LedgerdViews {
        return .{ .allocator = allocator };
    }

    pub fn deinit(views: *LedgerdViews) void {
        var iterator = views.ledgers.valueIterator();
        while (iterator.next()) |ledger| {
            ledger.*.arena.deinit();
            views.allocator.destroy(ledger.*);
        }
        views.ledgers.deinit(views.allocator);
        views.rows.deinit(views.allocator);
    }

    /// Applies one complete op (called by the follower, in op order).
    pub fn apply(views: *LedgerdViews, op: u64, changes: []const Change) !void {
        // Rows first: a value's chunks may arrive in any order within the op.
        for (changes) |*change| {
            switch (change.table) {
                store.table_roots => if (change.kind == .put) {
                    const generation = std.mem.readInt(u64, change.value[0..8], .little);
                    const ledger = try views.ledger_get(change.id);
                    if (generation > ledger.generation) ledger.reset(generation);
                },
                store.table_rows => switch (change.kind) {
                    .put => try views.rows.put(views.allocator, change.id, change.value),
                    .delete => _ = views.rows.remove(change.id),
                    .end => unreachable,
                },
                else => {},
            }
        }
        // Then values, in the order their chunk 0 was written (the order of the route).
        for (changes) |*change| {
            if (change.table != store.table_rows or change.kind != .put) continue;
            var arena = std.heap.ArenaAllocator.init(views.allocator);
            defer arena.deinit();
            const decoded = views.chunk0_decode(arena.allocator(), change.id) orelse continue;
            try views.value_apply(op, decoded);
        }
    }

    /// The value whose chunk 0 is row `id`, or null if `id` is not a chunk 0.
    fn chunk0_decode(
        views: *LedgerdViews,
        arena: std.mem.Allocator,
        id: u64,
    ) ?store.Decoded {
        const chunk0 = views.rows.get(id) orelse return null;
        const count = store.chunk0_count(&chunk0) catch return null;
        const chunks = arena.alloc([value_size]u8, count) catch return null;
        chunks[0] = chunk0;
        for (chunks[1..], 1..) |*chunk, index| {
            chunk.* = views.rows.get(store.tail_id(id, @intCast(index))) orelse return null;
        }
        const decoded = store.chunks_decode(arena, chunks) catch return null;
        // A tail chunk can look like a header; only a true chunk 0 hashes back to its own id.
        if (store.row_id(decoded.ledger, decoded.generation, decoded.key, 0) != id) return null;
        return decoded;
    }

    fn value_apply(views: *LedgerdViews, op: u64, decoded: store.Decoded) !void {
        const ledger = try views.ledger_get(decoded.ledger);
        if (decoded.generation > ledger.generation) ledger.reset(decoded.generation);
        if (decoded.generation < ledger.generation) return; // A write to a forgotten generation.
        const arena = ledger.arena.allocator();

        if (std.mem.startsWith(u8, decoded.key, "journal.")) {
            try ledger.journal.append(arena, .{
                .op = op,
                .line = try arena.dupe(u8, decoded.value),
            });
            return;
        }

        const Kind = @FieldType(Contribution, "kind");
        const kind: Kind = if (std.mem.startsWith(u8, decoded.key, "done."))
            .settled
        else if (std.mem.startsWith(u8, decoded.key, "denied."))
            .denied
        else
            return;
        const rid = decoded.key[if (kind == .settled) "done.".len else "denied.".len..];
        const amount = std.fmt.parseInt(u64, decoded.value, 10) catch 0;

        // Replace this key's earlier contribution, if any.
        if (ledger.contributions.get(decoded.key)) |previous| {
            const spend = ledger.spend.getPtr(previous.path).?;
            switch (previous.kind) {
                .settled => {
                    spend.own -= previous.amount;
                    spend.settled_count -= 1;
                },
                .denied => spend.denied_count -= 1,
            }
        }
        const path = try agent_path(arena, rid);
        const entry = try ledger.spend.getOrPut(arena, path);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        switch (kind) {
            .settled => {
                entry.value_ptr.own += amount;
                entry.value_ptr.settled_count += 1;
            },
            .denied => entry.value_ptr.denied_count += 1,
        }
        try ledger.contributions.put(arena, try arena.dupe(u8, decoded.key), .{
            .path = path,
            .kind = kind,
            .amount = amount,
        });
    }

    fn ledger_get(views: *LedgerdViews, id: u64) !*Ledger {
        const entry = try views.ledgers.getOrPut(views.allocator, id);
        if (!entry.found_existing) {
            const ledger = try views.allocator.create(Ledger);
            ledger.* = .{ .arena = std.heap.ArenaAllocator.init(views.allocator) };
            entry.value_ptr.* = ledger;
        }
        return entry.value_ptr.*;
    }

    pub fn journal(views: *const LedgerdViews, ledger_id: u64) []const JournalLine {
        const ledger = views.ledgers.get(ledger_id) orelse return &.{};
        return ledger.journal.items;
    }

    pub const RollupRow = struct {
        path: []const u8,
        depth: u32,
        own: u64,
        subtree: u64,
        settled_count: u64,
        denied_count: u64,
    };

    /// The rollup, one row per agent (including ancestors with no spend of their own), sorted
    /// by path.
    pub fn rollup(
        views: *const LedgerdViews,
        arena: std.mem.Allocator,
        ledger_id: u64,
    ) ![]const RollupRow {
        const ledger = views.ledgers.get(ledger_id) orelse return &.{};

        // Every agent, and every ancestor of one.
        var paths: std.StringArrayHashMapUnmanaged(Spend) = .{};
        var iterator = ledger.spend.iterator();
        while (iterator.next()) |entry| {
            var end: usize = 0;
            while (end <= entry.key_ptr.len) : (end += 1) {
                if (end == entry.key_ptr.len or entry.key_ptr.*[end] == '/') {
                    const prefix = entry.key_ptr.*[0..end];
                    const slot = try paths.getOrPut(arena, prefix);
                    if (!slot.found_existing) slot.value_ptr.* = .{};
                }
            }
            paths.getPtr(entry.key_ptr.*).?.* = entry.value_ptr.*;
        }

        const rows = try arena.alloc(RollupRow, paths.count());
        for (paths.keys(), paths.values(), rows) |path, spend, *row| {
            row.* = .{
                .path = path,
                .depth = @intCast(std.mem.count(u8, path, "/")),
                .own = spend.own,
                .subtree = 0,
                .settled_count = spend.settled_count,
                .denied_count = spend.denied_count,
            };
        }
        for (rows) |*row| {
            for (paths.keys(), paths.values()) |path, spend| {
                const descendant = std.mem.eql(u8, path, row.path) or
                    (std.mem.startsWith(u8, path, row.path) and path[row.path.len] == '/');
                if (descendant) row.subtree += spend.own;
            }
        }
        std.mem.sort(RollupRow, rows, {}, struct {
            fn less_than(_: void, a: RollupRow, b: RollupRow) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less_than);
        return rows;
    }
};

/// The agent path of a request id: each '/'-separated segment's name (the text before its
/// first ':'), joined by '/'. `planner-1:0:1/scout-b:0` → `planner-1/scout-b`.
pub fn agent_path(arena: std.mem.Allocator, rid: []const u8) ![]const u8 {
    var path = std.ArrayList(u8).init(arena);
    var segments = std.mem.splitScalar(u8, rid, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try path.append('/');
        first = false;
        const colon = std.mem.indexOfScalar(u8, segment, ':') orelse segment.len;
        try path.appendSlice(segment[0..colon]);
    }
    return path.items;
}

const testing = std.testing;

test agent_path {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    try testing.expectEqualStrings("planner-1", try agent_path(arena, "planner-1:0:3"));
    try testing.expectEqualStrings(
        "planner-1/scout-b",
        try agent_path(arena, "planner-1:0:1/scout-b:0"),
    );
    try testing.expectEqualStrings("x", try agent_path(arena, "x"));
}

test "ledgerd views: journal and spend rollup from chunked rows" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var views = LedgerdViews.init(testing.allocator);
    defer views.deinit();

    // Writes as `nerva ledgerd` stores them: chunked values, chunk 0 last within the op to
    // show that order within an op does not matter for reassembly.
    var op: u64 = 1;
    const Write = struct { key: []const u8, value: []const u8 };
    const ops = [_][]const Write{
        &.{
            .{ .key = "journal.01", .value = "RESERVE  3000  llm.complete  [planner-1:0:0]" },
            .{ .key = "done.planner-1:0:0", .value = "2500" },
        },
        &.{
            .{ .key = "done.planner-1:0:1/scout-b:0", .value = "700" },
            .{ .key = "denied.planner-1:0:1/scout-b:1", .value = "9000" },
            .{ .key = "journal.02", .value = "x" ** 300 }, // Several chunks.
        },
    };
    for (ops) |writes| {
        var changes = std.ArrayList(Change).init(arena);
        for (writes) |write| {
            const chunks = try store.chunks_encode(arena, 1, 0, write.key, write.value);
            var index = chunks.len;
            while (index > 0) {
                index -= 1;
                try changes.append(.{
                    .id = store.chunk_id(1, 0, write.key, @intCast(index)),
                    .table = store.table_rows,
                    .kind = .put,
                    .flags = .{},
                    .op = op,
                    .timestamp = op * 100 + changes.items.len,
                    .value = chunks[index],
                });
            }
        }
        try views.apply(op, changes.items);
        op += 1;
    }

    const journal = views.journal(1);
    try testing.expectEqual(@as(usize, 2), journal.len);
    try testing.expectEqualStrings("RESERVE  3000  llm.complete  [planner-1:0:0]", journal[0].line);
    try testing.expectEqual(@as(u64, 1), journal[0].op);
    try testing.expectEqualStrings("x" ** 300, journal[1].line);
    try testing.expectEqual(@as(u64, 2), journal[1].op);

    const rollup = try views.rollup(arena, 1);
    try testing.expectEqual(@as(usize, 2), rollup.len);
    try testing.expectEqualStrings("planner-1", rollup[0].path);
    try testing.expectEqual(@as(u64, 2500), rollup[0].own);
    try testing.expectEqual(@as(u64, 3200), rollup[0].subtree);
    try testing.expectEqual(@as(u32, 0), rollup[0].depth);
    try testing.expectEqualStrings("planner-1/scout-b", rollup[1].path);
    try testing.expectEqual(@as(u64, 700), rollup[1].own);
    try testing.expectEqual(@as(u64, 1), rollup[1].denied_count);
    try testing.expectEqual(@as(u32, 1), rollup[1].depth);

    // A new generation (`admin/init`) forgets everything.
    var root: [value_size]u8 = @splat(0);
    std.mem.writeInt(u64, root[0..8], 1, .little);
    try views.apply(op, &.{.{
        .id = 1,
        .table = store.table_roots,
        .kind = .put,
        .flags = .{},
        .op = op,
        .timestamp = op * 100,
        .value = root,
    }});
    try testing.expectEqual(@as(usize, 0), views.journal(1).len);
    try testing.expectEqual(@as(usize, 0), (try views.rollup(arena, 1)).len);
}
