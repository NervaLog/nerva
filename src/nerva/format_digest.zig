//! The format digest (P259b, R6): one number for everything Nerva puts on the wire or on disk.
//!
//! The digest is the SHA-256 of
//!
//! - the layout text of every wire and storage type and every persisted enum (`layout_types`,
//!   rendered by `layout_render`, the same text `format_test.zig` snapshots),
//! - the LSM tree ids,
//! - the cluster configuration (the fields `config.cluster.checksum()` fingerprints), the
//!   superblock version, and
//! - `format_epoch`, a constant moved by hand when a format change escapes the layouts: a key
//!   derivation, the meaning of a stored field, how a view's stored state is read.
//!
//! It is computed at comptime, so a binary carries it as a constant and `nerva version` prints
//! it. Two releases with one digest open each other's data files; in R6 any other pair moves a
//! cluster by export and import, never by a rolling upgrade (P259c). Nothing here is persisted
//! or sent: the digest is only read, so no persisted identifier changes.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const documents = @import("documents.zig");

/// Moved by hand, never by a layout change (those move the digest by themselves), when a
/// format change escapes the layouts. Moving it needs a decision (docs/decisions/) that says what
/// changed. Never lower it.
pub const format_epoch: u32 = 1;

/// The most text the digest hashes. The layouts take about a third of it; the render asserts.
const text_size_max = 96 * 1024;
/// Comptime evaluation quota for rendering and hashing the text.
const eval_branch_quota = 200_000_000;

/// Every wire and storage type whose layout is part of the format.
pub const layout_types = .{
    nerva.Row,
    @FieldType(nerva.Row, "flags"),
    nerva.Entry,
    nerva.EntryKind,
    nerva.EntryResult,
    nerva.EntryStatus,
    nerva.Add,
    @FieldType(nerva.Add, "flags"),
    nerva.Add.AddField,
    nerva.RowKey,
    nerva.RowValue,
    @FieldType(nerva.RowValue, "flags"),
    nerva.Change,
    @FieldType(nerva.Change, "flags"),
    nerva.ChangeKind,
    nerva.ChangesFilter,
    nerva.HistoryFilter,
    nerva.Operation,
    documents.Header,
    documents.Header.Flags,
    // Views maintained by the state machine (N52): stored in the views and groups trees, and
    // declared and read over the wire.
    nerva.FieldKind,
    nerva.FieldRef,
    nerva.Comparison,
    nerva.AggregateFunction,
    nerva.Where,
    nerva.AggregateRef,
    nerva.ViewDefinition,
    nerva.DeclareStatus,
    nerva.DeclareResult,
    nerva.ViewState,
    nerva.View,
    nerva.Group,
    nerva.ViewQuery,
    nerva.ViewRecord,
    nerva.ViewRecord.Kind,
    nerva.ViewRecord.Flags,
    // min, max and as_of (N62): the members, group versions and view versions trees.
    nerva.Member,
    nerva.Member.Flags,
    nerva.GroupVersion,
    nerva.ViewVersion,
    // Ledgers (N75): declared over the wire and stored in the ledgers tree.
    nerva.LedgerField,
    nerva.LedgerField.Flags,
    nerva.LedgerDefinition,
    nerva.DeclareLedgerStatus,
    nerva.DeclareLedgerResult,
    nerva.LedgerQuery,
    nerva.Ledger,
    // Commit keys (P123): a key's row value in `table_commit_keys`.
    nerva.CommitKey,
    // Records (P123b): `commit_wide`'s entries, stored records and their changes, and
    // the lookups and history over them.
    nerva.WideEntry,
    nerva.Record,
    nerva.RecordKey,
    nerva.RecordValue,
    @FieldType(nerva.RecordValue, "flags"),
    nerva.RecordChange,
    nerva.RecordHistoryFilter,
    // Declared indexes (P123c): declared and queried over the wire, stored in the indexes
    // and index entries trees.
    nerva.IndexDefinition,
    @FieldType(nerva.IndexDefinition, "flags"),
    nerva.DeclareIndexStatus,
    nerva.DeclareIndexResult,
    nerva.IndexState,
    nerva.Index,
    nerva.IndexEntry,
    @FieldType(nerva.IndexEntry, "flags"),
    nerva.IndexQuery,
    @FieldType(nerva.IndexQuery, "flags"),
    nerva.IndexRecord,
    nerva.IndexRecord.Kind,
    @FieldType(nerva.IndexRecord, "flags"),
    nerva.IndexGet,
};

/// The size, and each field's offset (or bit, for a packed struct), size and type, of a struct;
/// or the tag type and every value of an enum.
pub fn layout_render(writer: anytype, comptime T: type) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try writer.print("{s}: {s} struct, size {}\n", .{
                @typeName(T),
                @tagName(info.layout),
                @sizeOf(T),
            });
            inline for (info.fields) |field| {
                if (info.layout == .@"packed") {
                    try writer.print("  {s}: bit {}, {} bits, {s}\n", .{
                        field.name,
                        @bitOffsetOf(T, field.name),
                        @bitSizeOf(field.type),
                        @typeName(field.type),
                    });
                } else {
                    try writer.print("  {s}: offset {}, size {}, {s}\n", .{
                        field.name,
                        @offsetOf(T, field.name),
                        @sizeOf(field.type),
                        @typeName(field.type),
                    });
                }
            }
        },
        .@"enum" => |info| {
            try writer.print("{s}: enum({s}){s}\n", .{
                @typeName(T),
                @typeName(info.tag_type),
                if (info.is_exhaustive) "" else ", non-exhaustive",
            });
            inline for (info.fields) |field| {
                try writer.print("  {s} = {}\n", .{ field.name, field.value });
            }
        },
        else => @compileError("not a struct or an enum: " ++ @typeName(T)),
    }
}

/// What the format is made of, besides the layouts: the tree ids (a namespace like
/// `nerva.tree_ids`), the cluster configuration (`constants.config.cluster`, which
/// `config.cluster.checksum()` fingerprints; that checksum cannot run at comptime, so its fields
/// are rendered), the superblock version and the epoch.
pub fn Inputs(comptime ids_namespace: type, comptime cluster_type: type) type {
    return struct {
        ids: type = ids_namespace,
        cluster: cluster_type,
        superblock: u16,
        epoch: u32,
    };
}

/// The layouts of `types`, then the tree ids, the cluster configuration, the superblock version
/// and the epoch: the text `format_test.zig` snapshots and the digest hashes. Tree ids name the
/// LSM trees in the data file: never renumber them (CLAUDE.md).
pub fn render(writer: anytype, comptime types: anytype, comptime inputs: anytype) !void {
    inline for (types) |T| try layout_render(writer, T);

    try writer.writeAll("tree_ids:\n");
    inline for (comptime std.meta.declarations(inputs.ids)) |groove| {
        const ids = @field(inputs.ids, groove.name);
        inline for (comptime std.meta.fieldNames(@TypeOf(ids))) |tree| {
            try writer.print("  {s}.{s} = {}\n", .{ groove.name, tree, @field(ids, tree) });
        }
    }
    try writer.writeAll("cluster:\n");
    inline for (comptime std.meta.fieldNames(@TypeOf(inputs.cluster))) |name| {
        try writer.print("  {s} = {}\n", .{ name, @field(inputs.cluster, name) });
    }
    try writer.print("superblock_version: {}\n", .{inputs.superblock});
    try writer.print("format_epoch: {}\n", .{inputs.epoch});
}

/// The digest of a rendered text, at run time or comptime.
pub fn digest_text(text: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva format digest 1\n");
    hash.update(text);
    return hash.finalResult();
}

/// The digest of `types` and `inputs`, at comptime.
pub fn digest_of(comptime types: anytype, comptime inputs: anytype) [32]u8 {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var buffer: [text_size_max]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        render(stream.writer(), types, inputs) catch |err| switch (err) {
            error.NoSpaceLeft => @compileError("the format text outgrew text_size_max"),
        };
        return digest_text(stream.getWritten());
    }
}

/// This build's inputs.
pub const build_inputs = Inputs(nerva.tree_ids, @TypeOf(constants.config.cluster)){
    .cluster = constants.config.cluster,
    .superblock = vsr.superblock.SuperBlockVersion,
    .epoch = format_epoch,
};

/// This build's format digest.
pub const format_digest: [32]u8 = digest_of(layout_types, build_inputs);

/// A digest as 64 lower-case hex digits.
pub fn hex(digest: *const [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest.*, .lower);
}

const testing = std.testing;

/// An extern struct of two fields, `a: u32` and `b: u64`, in either order, reified so that both
/// orders carry one type name and only the layout differs.
fn pair(comptime b_first: bool) type {
    const a: std.builtin.Type.StructField = .{
        .name = "a",
        .type = u32,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    const b: std.builtin.Type.StructField = .{
        .name = "b",
        .type = u64,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(u64),
    };
    return @Type(.{ .@"struct" = .{
        .layout = .@"extern",
        .fields = if (b_first) &.{ b, a } else &.{ a, b },
        .decls = &.{},
        .is_tuple = false,
    } });
}

const no_ids = struct {};
const Synthetic = Inputs(no_ids, struct { clients_max: u32 });

fn synthetic(clients_max: u32, superblock: u16, epoch: u32) Synthetic {
    return .{ .cluster = .{ .clients_max = clients_max }, .superblock = superblock, .epoch = epoch };
}

test "format_digest: a field moved gives another digest" {
    const before = comptime digest_of(.{pair(false)}, synthetic(1, 2, 1));
    const after = comptime digest_of(.{pair(true)}, synthetic(1, 2, 1));
    try testing.expect(!std.mem.eql(u8, &before, &after));
    // The same list, twice, gives the same digest.
    const again = comptime digest_of(.{pair(false)}, synthetic(1, 2, 1));
    try testing.expectEqual(before, again);
    // The digests differ because the layouts do, not only the names: under the name line, the
    // two renders differ.
    var one = std.ArrayList(u8).init(testing.allocator);
    defer one.deinit();
    var other = std.ArrayList(u8).init(testing.allocator);
    defer other.deinit();
    try layout_render(one.writer(), pair(false));
    try layout_render(other.writer(), pair(true));
    const one_fields = one.items[std.mem.indexOfScalar(u8, one.items, '\n').?..];
    const other_fields = other.items[std.mem.indexOfScalar(u8, other.items, '\n').?..];
    try testing.expect(!std.mem.eql(u8, one_fields, other_fields));
}

test "format_digest: a tree id, the epoch, the cluster config and the superblock move it" {
    const ids_one = struct {
        pub const Tree = .{ .a = 1 };
    };
    const ids_two = struct {
        pub const Tree = .{ .a = 2 };
    };
    const Ones = Inputs(ids_one, struct { clients_max: u32 });
    const Twos = Inputs(ids_two, struct { clients_max: u32 });
    const base = comptime digest_of(.{pair(false)}, Ones{
        .cluster = .{ .clients_max = 1 },
        .superblock = 2,
        .epoch = 1,
    });
    const moved = [_][32]u8{
        comptime digest_of(.{pair(false)}, Twos{
            .cluster = .{ .clients_max = 1 },
            .superblock = 2,
            .epoch = 1,
        }),
        comptime digest_of(.{pair(false)}, Ones{
            .cluster = .{ .clients_max = 1 },
            .superblock = 2,
            .epoch = 2,
        }),
        comptime digest_of(.{pair(false)}, Ones{
            .cluster = .{ .clients_max = 3 },
            .superblock = 2,
            .epoch = 1,
        }),
        comptime digest_of(.{pair(false)}, Ones{
            .cluster = .{ .clients_max = 1 },
            .superblock = 3,
            .epoch = 1,
        }),
    };
    for (moved, 0..) |digest, index| {
        try testing.expect(!std.mem.eql(u8, &base, &digest));
        for (moved[0..index]) |earlier| try testing.expect(!std.mem.eql(u8, &earlier, &digest));
    }
}

test "format_digest: the comptime digest is the run-time digest of the rendered text" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    try render(out.writer(), layout_types, build_inputs);
    try testing.expect(out.items.len < text_size_max);
    const runtime = digest_text(out.items);
    try testing.expectEqual(format_digest, runtime);
    try testing.expectEqual(@as(usize, 64), hex(&runtime).len);
}
