//! The format digest (P259b, P269c, R6): one number for the wire and disk formats that decide
//! whether two releases can share a cluster or a data file.
//!
//! The digest is the SHA-256 of
//!
//! - the layout text of every state machine wire and storage type and every persisted enum
//!   (`layout_types`, rendered by `layout_render`, the text `format_test.zig` snapshots),
//! - the LSM tree ids,
//! - the cluster configuration (the fields `config.cluster.checksum()` fingerprints), the
//!   superblock version,
//! - `format_epoch`, a constant moved by hand when a format change escapes the layouts: a key
//!   derivation, the meaning of a stored field, how a view's stored state is read, and
//! - the layouts of the vendored wire and disk types (`vendored_types`, P269c): the message
//!   `vsr.Header` and every command's header (Ping, Pong, PeerHello, PeerChallenge, PeerProof
//!   and the rest), the request bodies of `vsr.zig`, the `SuperBlockHeader`, `VSRState` and
//!   `CheckpointState`, and the LSM block metadata, manifest entry and label of `lsm/schema.zig`,
//!   with the enums and structs their fields name (a field's type is rendered by name only, so
//!   `the walk` test fails when one is missing), and
//! - the outputs of the pure persisted derivations (`derivations_render`, P269d): the row, record,
//!   member, version and index keys, and the document, tail and commit-key ids, for fixed inputs.
//!
//! What no layout shows is not covered: how bytes are computed (checksums, MACs), what a value
//! means, the encoding of keys and values a tree stores as bytes, and the derivations that cannot
//! run at comptime (the catalog's canonical JSON and `fields_encode`, which
//! `format_test.zig` pins to `format_epoch`, P269d). A change to those moves `format_epoch`.
//!
//! The text names types and fields as well as sizes and offsets (P269c), so a pure rename moves
//! the digest too. It is computed at comptime, so a binary carries it as a constant and
//! `nerva version` prints it. Two releases with one digest open each other's data files; in R6
//! any other pair moves a cluster by export and import, never by a rolling upgrade (P259c).
//! Nothing here is persisted or sent: the digest is only read, so no persisted identifier
//! changes.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");
const constants = @import("../constants.zig");
const vsr = @import("../vsr.zig");
const documents = @import("documents.zig");
const indexes = @import("indexes.zig");
const views = @import("views.zig");
const schema = @import("../lsm/schema.zig");
const CompositeKeyType = @import("../lsm/composite_key.zig").CompositeKeyType;
const UniqueKeyType = @import("../lsm/unique_key.zig").UniqueKeyType;

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

/// The vendored wire and disk types whose layout is part of the format (P269c), besides the
/// header of every command (`vendored_headers`). Their files are never edited for the digest.
pub const vendored_types = [_]type{
    vsr.Header,
    vsr.Command,
    vsr.Operation,
    vsr.Release,
    vsr.RegisterRequest,
    vsr.RegisterResult,
    vsr.BlockRequest,
    vsr.ReconfigurationRequest,
    vsr.ReconfigurationResult,
    vsr.Header.Eviction.Reason,
    vsr.UpgradeRequest,
    vsr.superblock.SuperBlockHeader,
    vsr.superblock.SuperBlockHeader.VSRState,
    vsr.CheckpointState,
    schema.BlockType,
    schema.Checksum,
    schema.TableIndex.Metadata,
    schema.TableValue.Metadata,
    schema.TrailerNode.Metadata,
    schema.ManifestNode.Metadata,
    schema.ManifestNode.TableInfo,
    schema.ManifestNode.Event,
    schema.ManifestNode.Label,
    // The keys Nerva's index and unique-key (id) trees store: `groove.zig` instantiates them over
    // the field's type normalized to `u64` or `u128`.
    CompositeKeyType(u64),
    CompositeKeyType(u128),
    UniqueKeyType(u64),
    UniqueKeyType(u128),
};

/// The header of every command, each once (several commands share `Deprecated`).
pub const vendored_headers = blk: {
    const commands = std.meta.fields(vsr.Command);
    var list: [commands.len]type = undefined;
    var count: usize = 0;
    for (commands) |command| {
        const T = vsr.Header.Type(@enumFromInt(command.value));
        const seen = for (list[0..count]) |earlier| {
            if (earlier == T) break true;
        } else false;
        if (!seen) {
            list[count] = T;
            count += 1;
        }
    }
    const result: [count]type = list[0..count].*;
    break :blk result;
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

/// The outputs of the persisted derivations that are pure and run at comptime, for fixed inputs
/// (P269d). The hash behind a row id, a key's bit packing or a position prefix is a format as
/// much as a layout is: a replica of another release would compute other tree keys for the same
/// prepare. The inputs are those `format_test.zig` pinned apart from this code.
pub fn derivations_render(writer: anytype) !void {
    var eq_key: [nerva.group_key_size_max]u8 = @splat(0);
    eq_key[0] = 2;
    var group_key: [nerva.group_key_size_max]u8 = @splat(0);
    group_key[0] = 7;
    const id0 = documents.row_id(0, "table.5");
    try writer.print("row_key(5, 7) = {}\n", .{nerva.row_key(5, 7)});
    try writer.print("row_key(0xFFFF0002, max) = {}\n", .{
        nerva.row_key(0xFFFF0002, std.math.maxInt(u64)),
    });
    try writer.print("documents.row_id(0, table.5) = {}\n", .{id0});
    try writer.print("documents.tail_id(id0, 1) = {}\n", .{documents.tail_id(id0, 1)});
    try writer.print("documents.tail_id(id0, 2) = {}\n", .{documents.tail_id(id0, 2)});
    try writer.print("commit_key_id(1) = {}\n", .{nerva.commit_key_id(1)});
    try writer.print("commit_key_id(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef) = {}\n", .{
        nerva.commit_key_id(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef),
    });
    try writer.print("record_key(0x8000_0001, 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef) = {}\n", .{
        nerva.record_key(0x8000_0001, 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef),
    });
    try writer.print("indexes.position_prefix(3, eq 02..) = {}\n", .{
        indexes.position_prefix(3, &eq_key),
    });
    try writer.print("index_entry_key(3, 0x8000_0001_0000_0000_0000_0000_0000_0005) = {}\n", .{
        nerva.index_entry_key(3, 0x8000_0001_0000_0000_0000_0000_0000_0005),
    });
    try writer.print("views.member_order_prefix(1, 2, key 07..) = {}\n", .{
        views.member_order_prefix(1, 2, &group_key),
    });
    try writer.print("member_key(3, 2, 99) = {}\n", .{nerva.member_key(3, 2, 99)});
    try writer.print("group_version_key(1 << 64 | 17400499127971693294, 5) = {}\n", .{
        nerva.group_version_key(1 << 64 | 17400499127971693294, 5),
    });
    try writer.print("view_version_key(3, 5) = {}\n", .{nerva.view_version_key(3, 5)});
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

/// The layouts of `types`, then the tree ids, the cluster configuration, the superblock version,
/// the epoch, the layouts of `vendored` and the derivations' outputs: the text `format_test.zig`
/// snapshots and the digest hashes. Tree ids name the LSM trees in the data file: never renumber
/// them (CLAUDE.md).
pub fn render(
    writer: anytype,
    comptime types: anytype,
    comptime vendored: anytype,
    comptime inputs: anytype,
) !void {
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
    try writer.writeAll("vendored:\n");
    inline for (vendored) |T| try layout_render(writer, T);
    try writer.writeAll("derivations:\n");
    try derivations_render(writer);
}

/// The digest of a rendered text, at run time or comptime.
pub fn digest_text(text: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("nerva format digest 1\n");
    hash.update(text);
    return hash.finalResult();
}

/// The digest of `types`, `vendored` and `inputs`, at comptime.
pub fn digest_of(
    comptime types: anytype,
    comptime vendored: anytype,
    comptime inputs: anytype,
) [32]u8 {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var buffer: [text_size_max]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        render(stream.writer(), types, vendored, inputs) catch |err| switch (err) {
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
pub const format_digest: [32]u8 = digest_of(
    layout_types,
    vendored_types ++ vendored_headers,
    build_inputs,
);

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
    return .{
        .cluster = .{ .clients_max = clients_max },
        .superblock = superblock,
        .epoch = epoch,
    };
}

test "format_digest: a field moved gives another digest" {
    const before = comptime digest_of(.{pair(false)}, .{}, synthetic(1, 2, 1));
    const after = comptime digest_of(.{pair(true)}, .{}, synthetic(1, 2, 1));
    try testing.expect(!std.mem.eql(u8, &before, &after));
    // The same list, twice, gives the same digest.
    const again = comptime digest_of(.{pair(false)}, .{}, synthetic(1, 2, 1));
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

/// `T` with its first and last fields exchanged: the same members in another order, the layout
/// of a vendored header or superblock after a field moved. Only the layout differs from
/// `exchanged(T, false)`.
fn exchanged(comptime T: type, comptime exchange: bool) type {
    const info = @typeInfo(T).@"struct";
    var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
    for (info.fields, 0..) |field, index| fields[index] = field;
    if (exchange) std.mem.swap(std.builtin.Type.StructField, &fields[0], &fields[fields.len - 1]);
    return @Type(.{ .@"struct" = .{
        .layout = info.layout,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn vendored_digest(comptime T: type, comptime exchange: bool) [32]u8 {
    return comptime digest_of(.{}, .{exchanged(T, exchange)}, synthetic(1, 2, 1));
}

test "format_digest: a change to a message header, a command header or the superblock moves it" {
    const Superblock = vsr.superblock.SuperBlockHeader;
    inline for (.{
        vsr.Header,
        vsr.Header.PeerHello,
        vsr.Header.Ping,
        Superblock,
        Superblock.VSRState,
        vsr.CheckpointState,
        schema.ManifestNode.TableInfo,
    }) |T| {
        try testing.expectEqual(vendored_digest(T, false), vendored_digest(T, false));
        try testing.expect(!std.mem.eql(u8, &vendored_digest(T, false), &vendored_digest(T, true)));
    }
}

test "format_digest: the vendored layouts are in the digest" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    try render(out.writer(), layout_types, vendored_types ++ vendored_headers, build_inputs);
    const vendored_text = out.items[std.mem.indexOf(u8, out.items, "vendored:\n").?..];
    inline for (.{
        "Header: extern struct, size 256",
        "Header.Ping",
        "Header.Pong",
        "Header.PeerHello",
        "Header.PeerChallenge",
        "Header.PeerProof",
        "SuperBlockHeader: extern",
        "VSRState: extern",
        "CheckpointState: extern",
        "Header.Block: extern",
        "Header.Eviction.Reason: enum",
        "ReconfigurationResult: enum",
        "CompositeKey",
        "UniqueKey",
    }) |name| {
        try testing.expect(std.mem.indexOf(u8, vendored_text, name) != null);
    }
    // Each distinct command header once: Deprecated is shared by four commands.
    try testing.expect(vendored_headers.len < std.meta.fields(vsr.Command).len);
    // A vendored type moves the digest when it is left out of the list.
    const without = comptime digest_of(layout_types, .{}, build_inputs);
    try testing.expect(!std.mem.eql(u8, &without, &format_digest));
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
    const base = comptime digest_of(.{pair(false)}, .{}, Ones{
        .cluster = .{ .clients_max = 1 },
        .superblock = 2,
        .epoch = 1,
    });
    const moved = [_][32]u8{
        comptime digest_of(.{pair(false)}, .{}, Twos{
            .cluster = .{ .clients_max = 1 },
            .superblock = 2,
            .epoch = 1,
        }),
        comptime digest_of(.{pair(false)}, .{}, Ones{
            .cluster = .{ .clients_max = 1 },
            .superblock = 2,
            .epoch = 2,
        }),
        comptime digest_of(.{pair(false)}, .{}, Ones{
            .cluster = .{ .clients_max = 3 },
            .superblock = 2,
            .epoch = 1,
        }),
        comptime digest_of(.{pair(false)}, .{}, Ones{
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
    try render(out.writer(), layout_types, vendored_types ++ vendored_headers, build_inputs);
    try testing.expect(out.items.len < text_size_max);
    const runtime = digest_text(out.items);
    try testing.expectEqual(format_digest, runtime);
    try testing.expectEqual(@as(usize, 64), hex(&runtime).len);
}

/// Types a listed type's field names that the digest deliberately does not render, each with its
/// reason (P269d). A new entry needs a reason that is true of every field that names it.
const walk_excluded = .{};

fn walk_listed(comptime T: type, comptime lists: anytype) bool {
    inline for (lists) |list| {
        inline for (list) |listed| if (listed == T) return true;
    }
    return false;
}

/// The struct, enum and union types named by the fields of `T`, through arrays, optionals and
/// pointers, that are in none of `lists` nor `walk_excluded`.
fn walk_unlisted(comptime T: type, comptime lists: anytype) []const type {
    comptime {
        @setEvalBranchQuota(eval_branch_quota);
        var found: []const type = &.{};
        for (switch (@typeInfo(T)) {
            .@"struct" => |info| info.fields,
            else => &.{},
        }) |field| {
            var F = field.type;
            while (true) switch (@typeInfo(F)) {
                .array => |info| F = info.child,
                .optional => |info| F = info.child,
                .pointer => |info| F = info.child,
                else => break,
            };
            switch (@typeInfo(F)) {
                .@"struct", .@"enum", .@"union" => {
                    var excluded = false;
                    for (walk_excluded) |entry| {
                        if (entry[0] == F) excluded = true;
                    }
                    if (!excluded and !walk_listed(F, lists)) found = found ++ &[_]type{F};
                },
                else => {},
            }
        }
        return found;
    }
}

test "format_digest: the walk finds no type a listed field names that is not listed" {
    @setEvalBranchQuota(eval_branch_quota);
    const lists = .{ layout_types, vendored_types, vendored_headers };
    var unlisted: usize = 0;
    inline for (lists) |list| {
        inline for (list) |T| {
            inline for (comptime walk_unlisted(T, lists)) |missing| {
                std.debug.print("unlisted: {s}.{s}\n", .{ @typeName(T), @typeName(missing) });
                unlisted += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), unlisted);
    inline for (walk_excluded) |entry| try testing.expect(entry[1].len > 0);
}
