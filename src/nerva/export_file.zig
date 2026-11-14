//! The export file (docs/DECISIONS.md N80): a cluster's change feed, the declarations of its
//! views and ledgers, and checks, as `nerva export` writes them and `nerva import` reads them.
//!
//! Release-independent: it carries what a client can read (changes, names, ops, definitions),
//! never a data file's structures, so that one release's export is another release's input.
//!
//!     header   "NERVAEXP", format version (u32), flags (u32)
//!     record*  size (u32), kind (u32), body (`size` bytes, fixed per kind), CRC-32 of the three
//!     end      a record of kind `end` whose body is the SHA-256 of every byte before it
//!
//! Integers are little-endian. Records come in sections, in this order: changes (rows' and
//! records', strictly by timestamp), views (by id, 1, 2, …), ledgers (by op), indexes (by id),
//! view checks, ledger checks, table checks (by table), record checks (by table), the summary,
//! then `end` and nothing after.
//!
//! Flags (P426): bit 0 (`flag_keys_off`) says a test build with commit-key deduplication off
//! wrote the export, which a release build refuses to import (NRV-E0812). A release build writes
//! 0, so its exports are byte-identical to those before the flags; every other bit is reserved,
//! and a reader refuses a set one as corrupt. A release from before P426 reads the whole word as
//! reserved zero, so it refuses a keys-off export as corrupt.
//!
//! Version 2 (P123b) adds records' changes, indexes and record checks, and three counts to the
//! summary. A writer writes version 1 when it has none of them, so that a release that reads
//! only version 1 can import it; a reader reads both. The CRC finds a damaged record; the
//! SHA-256 finds anything else (a record moved, dropped or added). Neither authenticates: an
//! export is trusted as the data files are.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");
const nerva = @import("../nerva.zig");

pub const magic = "NERVAEXP".*;
pub const format_version_max: u32 = 2;
pub const header_size = magic.len + 4 + 4;

/// Header flags (P426). Bit 0: written by a build with commit-key deduplication off.
pub const flag_keys_off: u32 = 1 << 0;
pub const flags_known: u32 = flag_keys_off;

/// Distinct tables one export may check (each has a `check_table` record).
pub const tables_max = 1 << 16;

pub const RecordKind = enum(u32) {
    change = 1,
    view = 2,
    ledger = 3,
    check_view = 4,
    check_ledger = 5,
    check_table = 6,
    summary = 7,
    end = 8,
    // Version 2 (P123b).
    record_change = 9,
    index = 10,
    check_records = 11,
    _,

    /// The body's size in an export of `version`, or null if the kind is not one of its.
    fn body_size(kind: RecordKind, version: u32) ?u32 {
        assert(version >= 1 and version <= format_version_max);
        return switch (kind) {
            .change => 4 + 8 + 8 + 8 + 1 + nerva.value_size,
            .view => 32 + 8 + 8,
            .ledger => 4 + 8 + 1 + nerva.ledger_fields_max * ledger_field_size,
            .check_view => 8 + 1 + 8 + 32,
            .check_ledger => 4 + 16,
            .check_table => 4 + 8 + 32,
            .summary => if (version == 1) 8 + 8 + 4 + 4 + 4 else 8 + 8 + 4 + 4 + 4 + 8 + 4 + 4,
            .end => 32,
            .record_change => if (version >= 2) 4 + 16 + 8 + 8 + 1 + nerva.record_value_size else null,
            .index => if (version >= 2) 8 + 8 + @sizeOf(nerva.IndexDefinition) else null,
            .check_records => if (version >= 2) 4 + 8 + 32 else null,
            _ => null,
        };
    }

    /// The section a kind belongs to: records may only move to a later section.
    fn section(kind: RecordKind) u32 {
        return switch (kind) {
            .change, .record_change => 1,
            .view => 2,
            .ledger => 3,
            .index => 4,
            .check_view => 5,
            .check_ledger => 6,
            .check_table => 7,
            .check_records => 8,
            .summary => 9,
            .end => 10,
            _ => unreachable,
        };
    }
};

const ledger_field_size = 4 + 1 + 1 + 8;
const frame_size = 4 + 4 + 4;

pub const ChangeKind = enum(u8) { put = 1, delete = 2, _ };

/// A committed put or delete: `nerva.Change` without its feed-only fields.
pub const Change = struct {
    table: u32,
    id: u64,
    op: u64,
    timestamp: u64,
    kind: ChangeKind,
    /// Zero for a delete.
    value: [nerva.value_size]u8,
};

/// A view the state machine maintains: its catalog name (its definition is rebuilt from the
/// catalog document `view.<name>`, in the feed), id and the op it was declared at.
pub const View = struct {
    /// Zero-padded.
    name: [32]u8,
    id: u64,
    declared_op: u64,
};

pub const Ledger = struct {
    op: u64,
    definition: nerva.LedgerDefinition,
};

pub const CheckView = struct {
    id: u64,
    state: nerva.ViewState,
    group_count: u64,
    hash: [32]u8,
};

/// The sum of a ledger's fields over every live row.
pub const CheckLedger = struct {
    id: u32,
    total: i128,
};

/// A table's live rows: their number, and the SHA-256 of `table, id, op, value` for each, in
/// key order (`rows_hash`).
pub const CheckTable = struct {
    table: u32,
    row_count: u64,
    rows_hash: [32]u8,
};

pub const Summary = struct {
    /// Every change at or before this op, and none after.
    as_of: u64,
    change_count: u64,
    view_count: u32,
    ledger_count: u32,
    table_count: u32,
    /// Version 2: zero in version 1.
    record_change_count: u64 = 0,
    index_count: u32 = 0,
    record_table_count: u32 = 0,
};

/// A committed put or delete of a record (P123b).
pub const RecordChange = struct {
    table: u32,
    id: u128,
    op: u64,
    timestamp: u64,
    kind: ChangeKind,
    /// Zero for a delete.
    value: [nerva.record_value_size]u8,
};

/// An index (P123c): its id, the op it was declared at, and its definition.
pub const Index = struct {
    id: u64,
    declared_op: u64,
    definition: nerva.IndexDefinition,
};

/// A record table's live records: their number, and the SHA-256 of `table, id, op, value` for
/// each, in key order (`records_hash`).
pub const CheckRecords = struct {
    table: u32,
    record_count: u64,
    records_hash: [32]u8,
};

pub const Record = union(enum) {
    change: Change,
    view: View,
    ledger: Ledger,
    check_view: CheckView,
    check_ledger: CheckLedger,
    check_table: CheckTable,
    summary: Summary,
    record_change: RecordChange,
    index: Index,
    check_records: CheckRecords,

    fn kind(record: *const Record) RecordKind {
        return switch (record.*) {
            inline else => |_, tag| @field(RecordKind, @tagName(tag)),
        };
    }
};

/// One table's row, as its check hashes it.
pub fn rows_hash_update(
    hash: *std.crypto.hash.sha2.Sha256,
    table: u32,
    id: u64,
    op: u64,
    value: *const [nerva.value_size]u8,
) void {
    var bytes: [4 + 8 + 8 + nerva.value_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], table, .little);
    std.mem.writeInt(u64, bytes[4..12], id, .little);
    std.mem.writeInt(u64, bytes[12..20], op, .little);
    bytes[20..].* = value.*;
    hash.update(&bytes);
}

/// One live record of a record table, as its check hashes it.
pub fn records_hash_update(
    hash: *std.crypto.hash.sha2.Sha256,
    table: u32,
    id: u128,
    op: u64,
    value: *const [nerva.record_value_size]u8,
) void {
    var bytes: [4 + 16 + 8 + nerva.record_value_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], table, .little);
    std.mem.writeInt(u128, bytes[4..20], id, .little);
    std.mem.writeInt(u64, bytes[20..28], op, .little);
    bytes[28..].* = value.*;
    hash.update(&bytes);
}

/// The fixed body of each kind, little-endian.
const Body = struct {
    bytes: [body_size_max]u8 = undefined,
    size: u32 = 0,

    const body_size_max = 512;

    fn int(body: *Body, comptime T: type, value: T) void {
        std.mem.writeInt(T, body.bytes[body.size..][0..@sizeOf(T)], value, .little);
        body.size += @sizeOf(T);
    }

    fn raw(body: *Body, bytes: []const u8) void {
        @memcpy(body.bytes[body.size..][0..bytes.len], bytes);
        body.size += @intCast(bytes.len);
    }

    fn encode(record: *const Record, version: u32) Body {
        var body: Body = .{};
        switch (record.*) {
            .change => |*change| {
                body.int(u32, change.table);
                body.int(u64, change.id);
                body.int(u64, change.op);
                body.int(u64, change.timestamp);
                body.int(u8, @intFromEnum(change.kind));
                body.raw(&change.value);
            },
            .view => |*view| {
                body.raw(&view.name);
                body.int(u64, view.id);
                body.int(u64, view.declared_op);
            },
            .ledger => |*ledger| {
                body.int(u32, ledger.definition.id);
                body.int(u64, ledger.op);
                body.int(u8, ledger.definition.field_count);
                for (&ledger.definition.fields) |*field| {
                    body.int(u32, field.table);
                    body.int(u8, field.offset);
                    body.int(u8, @intFromBool(field.flags.floor));
                    body.int(i64, field.floor);
                }
            },
            .check_view => |*check| {
                body.int(u64, check.id);
                body.int(u8, @intFromEnum(check.state));
                body.int(u64, check.group_count);
                body.raw(&check.hash);
            },
            .check_ledger => |*check| {
                body.int(u32, check.id);
                body.int(i128, check.total);
            },
            .check_table => |*check| {
                body.int(u32, check.table);
                body.int(u64, check.row_count);
                body.raw(&check.rows_hash);
            },
            .summary => |*summary| {
                body.int(u64, summary.as_of);
                body.int(u64, summary.change_count);
                body.int(u32, summary.view_count);
                body.int(u32, summary.ledger_count);
                body.int(u32, summary.table_count);
                if (version >= 2) {
                    body.int(u64, summary.record_change_count);
                    body.int(u32, summary.index_count);
                    body.int(u32, summary.record_table_count);
                } else {
                    assert(summary.record_change_count == 0);
                    assert(summary.index_count == 0);
                    assert(summary.record_table_count == 0);
                }
            },
            .record_change => |*change| {
                body.int(u32, change.table);
                body.int(u128, change.id);
                body.int(u64, change.op);
                body.int(u64, change.timestamp);
                body.int(u8, @intFromEnum(change.kind));
                body.raw(&change.value);
            },
            .index => |*index| {
                body.int(u64, index.id);
                body.int(u64, index.declared_op);
                body.raw(std.mem.asBytes(&index.definition));
            },
            .check_records => |*check| {
                body.int(u32, check.table);
                body.int(u64, check.record_count);
                body.raw(&check.records_hash);
            },
        }
        assert(body.size == record.kind().body_size(version).?);
        return body;
    }
};

const BodyReader = struct {
    bytes: []const u8,
    offset: u32 = 0,

    fn int(reader: *BodyReader, comptime T: type) T {
        defer reader.offset += @sizeOf(T);
        return std.mem.readInt(T, reader.bytes[reader.offset..][0..@sizeOf(T)], .little);
    }

    fn raw(reader: *BodyReader, comptime size: usize) [size]u8 {
        defer reader.offset += size;
        return reader.bytes[reader.offset..][0..size].*;
    }

    fn done(reader: *const BodyReader) void {
        assert(reader.offset == reader.bytes.len);
    }
};

/// The reason for the last `error.Corrupt` (one thread).
pub var corrupt_reason: []const u8 = "";

pub fn corrupt(reason: []const u8) error{Corrupt} {
    corrupt_reason = reason;
    return error.Corrupt;
}

/// The decoded record, or `error.Corrupt` for values no writer produces.
fn decode(kind: RecordKind, version: u32, bytes: []const u8) error{Corrupt}!Record {
    assert(bytes.len == kind.body_size(version).?);
    var body: BodyReader = .{ .bytes = bytes };
    defer body.done();
    switch (kind) {
        .change => {
            const change: Change = .{
                .table = body.int(u32),
                .id = body.int(u64),
                .op = body.int(u64),
                .timestamp = body.int(u64),
                .kind = @enumFromInt(body.int(u8)),
                .value = body.raw(nerva.value_size),
            };
            if (change.table == 0 or change.op == 0 or change.timestamp == 0) {
                return corrupt("a change has a zero table, op or timestamp");
            }
            switch (change.kind) {
                .put => {},
                .delete => if (!stdx.zeroed(&change.value)) {
                    return corrupt("a delete carries a value");
                },
                _ => return corrupt("a change is neither put nor delete"),
            }
            return .{ .change = change };
        },
        .view => {
            const view: View = .{
                .name = body.raw(32),
                .id = body.int(u64),
                .declared_op = body.int(u64),
            };
            const name_size = std.mem.indexOfScalar(u8, &view.name, 0) orelse view.name.len;
            if (name_size == 0 or !stdx.zeroed(view.name[name_size..])) {
                return corrupt("a view's name is empty or not zero-padded");
            }
            if (view.declared_op == 0) return corrupt("a view's op is zero");
            return .{ .view = view };
        },
        .ledger => {
            var definition = std.mem.zeroes(nerva.LedgerDefinition);
            definition.id = body.int(u32);
            const op = body.int(u64);
            definition.field_count = body.int(u8);
            for (&definition.fields) |*field| {
                field.table = body.int(u32);
                field.offset = body.int(u8);
                const floor = body.int(u8);
                if (floor > 1) return corrupt("a ledger field's floor flag is not 0 or 1");
                field.flags.floor = floor == 1;
                field.floor = body.int(i64);
            }
            if (op == 0) return corrupt("a ledger's op is zero");
            return .{ .ledger = .{ .op = op, .definition = definition } };
        },
        .check_view => {
            const check: CheckView = .{
                .id = body.int(u64),
                .state = std.meta.intToEnum(nerva.ViewState, body.int(u8)) catch
                    return corrupt("a view check's state is unknown"),
                .group_count = body.int(u64),
                .hash = body.raw(32),
            };
            return .{ .check_view = check };
        },
        .check_ledger => return .{ .check_ledger = .{
            .id = body.int(u32),
            .total = body.int(i128),
        } },
        .check_table => {
            const check: CheckTable = .{
                .table = body.int(u32),
                .row_count = body.int(u64),
                .rows_hash = body.raw(32),
            };
            if (check.table == 0) return corrupt("a table check names table zero");
            return .{ .check_table = check };
        },
        .summary => {
            var summary: Summary = .{
                .as_of = body.int(u64),
                .change_count = body.int(u64),
                .view_count = body.int(u32),
                .ledger_count = body.int(u32),
                .table_count = body.int(u32),
            };
            if (version >= 2) {
                summary.record_change_count = body.int(u64);
                summary.index_count = body.int(u32);
                summary.record_table_count = body.int(u32);
            }
            return .{ .summary = summary };
        },
        .record_change => {
            const change: RecordChange = .{
                .table = body.int(u32),
                .id = body.int(u128),
                .op = body.int(u64),
                .timestamp = body.int(u64),
                .kind = @enumFromInt(body.int(u8)),
                .value = body.raw(nerva.record_value_size),
            };
            if (!nerva.table_is_record(change.table)) {
                return corrupt("a record's change names a table that holds rows");
            }
            if (change.op == 0 or change.timestamp == 0) {
                return corrupt("a record's change has a zero op or timestamp");
            }
            switch (change.kind) {
                .put => {},
                .delete => if (!stdx.zeroed(&change.value)) {
                    return corrupt("a delete carries a value");
                },
                _ => return corrupt("a change is neither put nor delete"),
            }
            return .{ .record_change = change };
        },
        .index => {
            const index: Index = .{
                .id = body.int(u64),
                .declared_op = body.int(u64),
                .definition = std.mem.bytesToValue(
                    nerva.IndexDefinition,
                    &body.raw(@sizeOf(nerva.IndexDefinition)),
                ),
            };
            if (index.declared_op == 0) return corrupt("an index's op is zero");
            return .{ .index = index };
        },
        .check_records => {
            const check: CheckRecords = .{
                .table = body.int(u32),
                .record_count = body.int(u64),
                .records_hash = body.raw(32),
            };
            if (!nerva.table_is_record(check.table)) {
                return corrupt("a record check names a table that holds rows");
            }
            return .{ .check_records = check };
        },
        .end => unreachable,
        _ => unreachable,
    }
}

/// Writes an export to `inner` (any writer): the header first, then records in section order,
/// then `finish`.
pub fn WriterType(comptime Inner: type) type {
    return struct {
        const Writer = @This();

        inner: Inner,
        hash: std.crypto.hash.sha2.Sha256,
        version: u32,
        section: u32 = 0,
        finished: bool = false,
        /// The `end` record's SHA-256, once finished: the export's identity, which every data
        /// file imported from it records (`VSRState.origin`, P90).
        digest: [32]u8 = undefined,

        /// `version`: 1 if the export holds no records and no indexes, else 2. `flags`: the header's
        /// flags, 0 from a release build.
        pub fn init(inner: Inner, version: u32, flags: u32) !Writer {
            assert(version >= 1 and version <= format_version_max);
            assert(flags & ~flags_known == 0);
            var writer: Writer = .{ .inner = inner, .hash = .init(.{}), .version = version };
            var header: [header_size]u8 = undefined;
            header[0..magic.len].* = magic;
            std.mem.writeInt(u32, header[8..12], version, .little);
            std.mem.writeInt(u32, header[12..16], flags, .little);
            try writer.write_bytes(&header);
            return writer;
        }

        pub fn write(writer: *Writer, record: *const Record) !void {
            assert(!writer.finished);
            const kind = record.kind();
            assert(kind.body_size(writer.version) != null);
            assert(kind.section() >= writer.section);
            writer.section = kind.section();
            const body = Body.encode(record, writer.version);
            try writer.write_frame(kind, body.bytes[0..body.size]);
        }

        /// Writes the `end` record. The export is complete once `inner` is flushed.
        pub fn finish(writer: *Writer) !void {
            assert(!writer.finished);
            assert(writer.section == RecordKind.summary.section());
            const digest = writer.hash.finalResult();
            try writer.write_frame(.end, &digest);
            writer.finished = true;
            writer.digest = digest;
        }

        fn write_frame(writer: *Writer, kind: RecordKind, body: []const u8) !void {
            assert(body.len == kind.body_size(writer.version).?);
            var prefix: [8]u8 = undefined;
            std.mem.writeInt(u32, prefix[0..4], @intCast(body.len), .little);
            std.mem.writeInt(u32, prefix[4..8], @intFromEnum(kind), .little);
            var crc = std.hash.Crc32.init();
            crc.update(&prefix);
            crc.update(body);
            var suffix: [4]u8 = undefined;
            std.mem.writeInt(u32, &suffix, crc.final(), .little);
            try writer.write_bytes(&prefix);
            try writer.write_bytes(body);
            try writer.write_bytes(&suffix);
        }

        fn write_bytes(writer: *Writer, bytes: []const u8) !void {
            writer.hash.update(bytes);
            try writer.inner.writeAll(bytes);
        }
    };
}

/// Reads an export from `inner` (any reader), checking every record's CRC, the sections'
/// order and contents, the summary's counts, and the SHA-256 at the end. `next` returns null
/// only after all of it passed: a reader must not act on records before then (`nerva import`
/// reads the file twice).
pub fn ReaderType(comptime Inner: type) type {
    return struct {
        const Reader = @This();

        inner: Inner,
        hash: std.crypto.hash.sha2.Sha256,
        version: u32 = 0,
        /// The header's flags (`flag_keys_off`); only known bits are ever set.
        flags: u32 = 0,
        body: [Body.body_size_max]u8 = undefined,
        section: u32 = 0,
        state: enum { records, ended } = .records,
        /// What the sections' order requires of the next record.
        change_last: ?struct { op: u64, timestamp: u64 } = null,
        change_count: u64 = 0,
        view_count: u32 = 0,
        ledger_count: u32 = 0,
        ledger_op_last: u64 = 0,
        table_last: u32 = 0,
        table_count: u32 = 0,
        check_view_count: u32 = 0,
        check_ledger_count: u32 = 0,
        record_change_count: u64 = 0,
        index_count: u32 = 0,
        record_table_last: u32 = 0,
        record_table_count: u32 = 0,
        summary: ?Summary = null,
        /// The `end` record's SHA-256, once `next` returned null (see `WriterType.digest`).
        digest: [32]u8 = undefined,

        pub fn init(inner: Inner) !Reader {
            var reader: Reader = .{ .inner = inner, .hash = .init(.{}) };
            var header: [header_size]u8 = undefined;
            try reader.read_bytes(&header);
            if (!std.mem.eql(u8, header[0..magic.len], &magic)) {
                return corrupt("not an export: the magic is wrong");
            }
            reader.version = std.mem.readInt(u32, header[8..12], .little);
            if (reader.version == 0 or reader.version > format_version_max) {
                return error.VersionUnsupported;
            }
            reader.flags = std.mem.readInt(u32, header[12..16], .little);
            if (reader.flags & ~flags_known != 0) {
                return corrupt("the header sets a flag this release does not know");
            }
            return reader;
        }

        pub fn next(reader: *Reader) !?Record {
            assert(reader.state == .records);
            // The SHA-256 covers every byte before the `end` record.
            const hash_before = reader.hash;
            var prefix: [8]u8 = undefined;
            try reader.read_bytes(&prefix);
            const size = std.mem.readInt(u32, prefix[0..4], .little);
            const kind: RecordKind = @enumFromInt(std.mem.readInt(u32, prefix[4..8], .little));
            const body_size = kind.body_size(reader.version) orelse
                return corrupt("a record's kind is unknown");
            if (size != body_size) return corrupt("a record's size does not match its kind");
            if (kind.section() < reader.section) return corrupt("a record is out of order");
            reader.section = kind.section();

            const body = reader.body[0..size];
            try reader.read_bytes(body);
            var suffix: [4]u8 = undefined;
            try reader.read_bytes(&suffix);
            var crc = std.hash.Crc32.init();
            crc.update(&prefix);
            crc.update(body);
            if (crc.final() != std.mem.readInt(u32, &suffix, .little)) {
                return corrupt("a record's CRC-32 does not match");
            }

            if (kind == .end) {
                var hash_end = hash_before;
                if (!std.mem.eql(u8, body, &hash_end.finalResult())) {
                    return corrupt("the SHA-256 does not match: records were changed or moved");
                }
                if (reader.summary == null) return corrupt("the summary is missing");
                var trailing: [1]u8 = undefined;
                if (try reader.inner.read(&trailing) != 0) {
                    return corrupt("bytes follow the end record");
                }
                reader.state = .ended;
                reader.digest = body[0..32].*;
                return null;
            }
            const record = try decode(kind, reader.version, body);
            try reader.validate(&record);
            return record;
        }

        /// The order and bounds within sections, and the summary's counts.
        fn validate(reader: *Reader, record: *const Record) !void {
            switch (record.*) {
                .change => |*change| {
                    try reader.change_order(change.op, change.timestamp);
                    reader.change_count += 1;
                },
                .record_change => |*change| {
                    try reader.change_order(change.op, change.timestamp);
                    reader.record_change_count += 1;
                },
                .index => |*index| {
                    if (index.id != reader.index_count + 1) {
                        return corrupt("indexes are not 1, 2, …");
                    }
                    if (reader.index_count == nerva.indexes_max) return corrupt("too many indexes");
                    reader.index_count += 1;
                },
                .check_records => |*check| {
                    if (check.table <= reader.record_table_last) {
                        return corrupt("record checks are out of order");
                    }
                    if (reader.record_table_count == tables_max) return corrupt("too many tables");
                    reader.record_table_last = check.table;
                    reader.record_table_count += 1;
                },
                .view => |*view| {
                    if (view.id != reader.view_count + 1) return corrupt("views are not 1, 2, …");
                    if (reader.view_count == nerva.views_max) return corrupt("too many views");
                    reader.view_count += 1;
                },
                .ledger => |*ledger| {
                    if (ledger.op <= reader.ledger_op_last) {
                        return corrupt("ledgers are out of op order");
                    }
                    if (reader.ledger_count == nerva.ledgers_max) {
                        return corrupt("too many ledgers");
                    }
                    reader.ledger_op_last = ledger.op;
                    reader.ledger_count += 1;
                },
                .check_view => |*check| {
                    if (check.id != reader.check_view_count + 1) {
                        return corrupt("view checks are not 1, 2, …");
                    }
                    if (check.id > reader.view_count) return corrupt("a check for no view");
                    reader.check_view_count += 1;
                },
                .check_ledger => {
                    if (reader.check_ledger_count == reader.ledger_count) {
                        return corrupt("a check for no ledger");
                    }
                    reader.check_ledger_count += 1;
                },
                .check_table => |*check| {
                    if (check.table <= reader.table_last) {
                        return corrupt("table checks are out of order");
                    }
                    if (reader.table_count == tables_max) return corrupt("too many tables");
                    reader.table_last = check.table;
                    reader.table_count += 1;
                },
                .summary => |*summary| {
                    if (reader.summary != null) return corrupt("two summaries");
                    if (summary.change_count != reader.change_count or
                        summary.view_count != reader.view_count or
                        summary.ledger_count != reader.ledger_count or
                        summary.table_count != reader.table_count or
                        summary.record_change_count != reader.record_change_count or
                        summary.index_count != reader.index_count or
                        summary.record_table_count != reader.record_table_count or
                        reader.check_view_count != reader.view_count or
                        reader.check_ledger_count != reader.ledger_count)
                    {
                        return corrupt("the summary's counts do not match the records");
                    }
                    if (reader.change_last) |last| {
                        if (last.op > summary.as_of) return corrupt("a change is past as_of");
                    }
                    if (reader.ledger_op_last > summary.as_of) {
                        return corrupt("a ledger is past as_of");
                    }
                    reader.summary = summary.*;
                },
            }
        }

        /// Rows' and records' changes share one order: strictly by timestamp, then by op.
        fn change_order(reader: *Reader, op: u64, timestamp: u64) !void {
            if (reader.change_last) |last| {
                if (timestamp <= last.timestamp or op < last.op) {
                    return corrupt("changes are out of timestamp or op order");
                }
            }
            reader.change_last = .{ .op = op, .timestamp = timestamp };
        }

        fn read_bytes(reader: *Reader, bytes: []u8) !void {
            reader.inner.readNoEof(bytes) catch |err| switch (err) {
                error.EndOfStream => return corrupt("the export is truncated"),
                else => |e| return e,
            };
            reader.hash.update(bytes);
        }
    };
}

const testing = std.testing;

fn test_records(arena: std.mem.Allocator) ![]const Record {
    var records = std.ArrayList(Record).init(arena);
    var value: [nerva.value_size]u8 = @splat(0);
    value[0] = 7;
    try records.append(.{ .change = .{
        .table = 1,
        .id = 5,
        .op = 3,
        .timestamp = 100,
        .kind = .put,
        .value = value,
    } });
    try records.append(.{ .change = .{
        .table = 0xFFFF_0001,
        .id = 9,
        .op = 3,
        .timestamp = 109,
        .kind = .put,
        .value = value,
    } });
    try records.append(.{ .change = .{
        .table = 1,
        .id = 5,
        .op = 4,
        .timestamp = 200,
        .kind = .delete,
        .value = @splat(0),
    } });
    var name: [32]u8 = @splat(0);
    @memcpy(name[0..7], "revenue");
    try records.append(.{ .view = .{ .name = name, .id = 1, .declared_op = 2 } });
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = 3;
    definition.field_count = 2;
    definition.fields[0] = .{ .table = 7, .offset = 0, .flags = .{ .floor = true }, .floor = -4 };
    definition.fields[1] = .{ .table = 7, .offset = 8, .flags = .{}, .floor = 0 };
    try records.append(.{ .ledger = .{ .op = 4, .definition = definition } });
    try records.append(.{ .check_view = .{
        .id = 1,
        .state = .ready,
        .group_count = 2,
        .hash = @splat(0xab),
    } });
    try records.append(.{ .check_ledger = .{ .id = 3, .total = -12 } });
    try records.append(.{ .check_table = .{ .table = 1, .row_count = 0, .rows_hash = @splat(1) } });
    try records.append(.{ .check_table = .{
        .table = 0xFFFF_0001,
        .row_count = 1,
        .rows_hash = @splat(2),
    } });
    try records.append(.{ .summary = .{
        .as_of = 4,
        .change_count = 3,
        .view_count = 1,
        .ledger_count = 1,
        .table_count = 2,
    } });
    return records.items;
}

fn test_encode(arena: std.mem.Allocator, records: []const Record) ![]u8 {
    var out = std.ArrayList(u8).init(arena);
    var writer = try WriterType(std.ArrayList(u8).Writer).init(out.writer(), 1, 0);
    for (records) |*record| try writer.write(record);
    try writer.finish();
    return out.items;
}

/// Every record of `bytes`, or the error a reader returns.
fn test_decode(arena: std.mem.Allocator, bytes: []const u8) ![]const Record {
    var stream = std.io.fixedBufferStream(bytes);
    var reader = try ReaderType(@TypeOf(stream).Reader).init(stream.reader());
    var records = std.ArrayList(Record).init(arena);
    while (try reader.next()) |record| try records.append(record);
    return records.items;
}

test "export file: records round-trip" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const records = try test_records(arena);
    const bytes = try test_encode(arena, records);
    const decoded = try test_decode(arena, bytes);
    try testing.expectEqual(records.len, decoded.len);
    for (records, decoded) |expected, actual| {
        try testing.expectEqualDeep(expected, actual);
    }
}

test "export file: the writer and the reader name an export by its end record (P90)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const records = try test_records(arena);
    var out = std.ArrayList(u8).init(arena);
    var writer = try WriterType(std.ArrayList(u8).Writer).init(out.writer(), 1, 0);
    for (records) |*record| try writer.write(record);
    try writer.finish();
    // The end record's body, the last 32 bytes before its CRC-32.
    const bytes = out.items;
    try testing.expectEqualSlices(u8, bytes[bytes.len - 4 - 32 ..][0..32], &writer.digest);

    var stream = std.io.fixedBufferStream(bytes);
    var reader = try ReaderType(@TypeOf(stream).Reader).init(stream.reader());
    while (try reader.next()) |_| {}
    try testing.expectEqualSlices(u8, &writer.digest, &reader.digest);

    // Another export (one record differs) is another origin.
    var other = try arena.dupe(Record, records);
    other[other.len - 1].summary.as_of += 1;
    var out_other = std.ArrayList(u8).init(arena);
    var writer_other = try WriterType(std.ArrayList(u8).Writer).init(out_other.writer(), 1, 0);
    for (other) |*record| try writer_other.write(record);
    try writer_other.finish();
    try testing.expect(!std.mem.eql(u8, &writer.digest, &writer_other.digest));
}

test "export file: header flags (P426)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const records = try test_records(arena);
    const bytes = try test_encode(arena, records);

    // A release build writes flags 0: the header's last four bytes are the zeros the reserved
    // word held, so an export from the last release is read as it was, and ours is the same.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[12..16]);
    {
        var stream = std.io.fixedBufferStream(bytes);
        const reader = try ReaderType(@TypeOf(stream).Reader).init(stream.reader());
        try testing.expectEqual(@as(u32, 0), reader.flags);
    }

    // A keys-off build's flag round-trips, and the export has the same size (its SHA-256 covers the header, so the digest differs).
    var out = std.ArrayList(u8).init(arena);
    var writer = try WriterType(std.ArrayList(u8).Writer).init(out.writer(), 1, flag_keys_off);
    for (records) |*record| try writer.write(record);
    try writer.finish();
    try testing.expectEqual(bytes.len, out.items.len);
    var stream = std.io.fixedBufferStream(out.items);
    var reader = try ReaderType(@TypeOf(stream).Reader).init(stream.reader());
    try testing.expectEqual(flag_keys_off, reader.flags);
    var count: usize = 0;
    while (try reader.next()) |_| count += 1;
    try testing.expectEqual(records.len, count);

    // An unknown bit is corrupt, as a non-zero reserved word was.
    const unknown = try arena.dupe(u8, bytes);
    unknown[12] = 0x02;
    try testing.expectError(error.Corrupt, test_decode(arena, unknown));
    unknown[12] = 0;
    unknown[15] = 0x80;
    try testing.expectError(error.Corrupt, test_decode(arena, unknown));
}

test "export file: one byte changed, a truncation, or a record moved, each fails" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const records = try test_records(arena);
    const bytes = try test_encode(arena, records);

    // Every byte, flipped.
    const copy = try arena.dupe(u8, bytes);
    for (0..bytes.len) |index| {
        copy[index] ^= 0x01;
        defer copy[index] = bytes[index];
        if (test_decode(arena, copy)) |_| {
            std.debug.print("byte {} flipped was accepted\n", .{index});
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.Corrupt, error.VersionUnsupported => {},
            else => return err,
        }
    }

    // Every length short of the whole, and a byte more.
    for (0..bytes.len) |size| {
        try testing.expectError(error.Corrupt, test_decode(arena, bytes[0..size]));
    }
    const longer = try std.mem.concat(arena, u8, &.{ bytes, &.{0} });
    try testing.expectError(error.Corrupt, test_decode(arena, longer));

    // Two records swapped, re-framed as a writer would (each CRC still matches): caught by the
    // order, or by the SHA-256 when the order still holds.
    const frame_change = RecordKind.change.body_size(1).? + frame_size;
    const swapped = try arena.dupe(u8, bytes);
    const first = header_size;
    @memcpy(swapped[first..][0..frame_change], bytes[first + frame_change ..][0..frame_change]);
    @memcpy(swapped[first + frame_change ..][0..frame_change], bytes[first..][0..frame_change]);
    try testing.expectError(error.Corrupt, test_decode(arena, swapped));

    // The two table checks swapped, in order of kind but not of table.
    var reordered = try arena.dupe(Record, records);
    std.mem.swap(Record, &reordered[7], &reordered[8]);
    try testing.expectError(
        error.Corrupt,
        test_decode(arena, try test_encode(arena, reordered)),
    );

    // A record dropped: the summary's counts no longer match.
    const dropped = try std.mem.concat(arena, Record, &.{ records[0..1], records[2..] });
    try testing.expectError(error.Corrupt, test_decode(arena, try test_encode(arena, dropped)));

    // A format version past this release's.
    const versioned = try arena.dupe(u8, bytes);
    versioned[8] = format_version_max + 1;
    try testing.expectError(error.VersionUnsupported, test_decode(arena, versioned));
    // Version 2's summary is larger: version 1's bytes are not a version 2 export.
    versioned[8] = 2;
    try testing.expectError(error.Corrupt, test_decode(arena, versioned));
}

test "export file: version 2 carries records, indexes and record checks" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var records = std.ArrayList(Record).init(arena);
    var row_value: [nerva.value_size]u8 = @splat(0);
    row_value[0] = 1;
    var record_value: [nerva.record_value_size]u8 = @splat(0);
    record_value[447] = 9;
    const table = nerva.record_tables_min + 3;
    // Rows' and records' changes, merged by timestamp.
    try records.append(.{ .change = .{
        .table = 1,
        .id = 1,
        .op = 2,
        .timestamp = 10,
        .kind = .put,
        .value = row_value,
    } });
    try records.append(.{ .record_change = .{
        .table = table,
        .id = std.math.maxInt(u128),
        .op = 2,
        .timestamp = 19,
        .kind = .put,
        .value = record_value,
    } });
    try records.append(.{ .record_change = .{
        .table = table,
        .id = std.math.maxInt(u128),
        .op = 3,
        .timestamp = 28,
        .kind = .delete,
        .value = @splat(0),
    } });
    var definition = std.mem.zeroes(nerva.IndexDefinition);
    @memcpy(definition.name[0..2], "ix");
    definition.table = table;
    try records.append(.{ .index = .{ .id = 1, .declared_op = 1, .definition = definition } });
    try records.append(.{ .check_table = .{ .table = 1, .row_count = 1, .rows_hash = @splat(3) } });
    try records.append(.{ .check_records = .{
        .table = table,
        .record_count = 0,
        .records_hash = @splat(4),
    } });
    try records.append(.{ .summary = .{
        .as_of = 3,
        .change_count = 1,
        .view_count = 0,
        .ledger_count = 0,
        .table_count = 1,
        .record_change_count = 2,
        .index_count = 1,
        .record_table_count = 1,
    } });

    var out = std.ArrayList(u8).init(arena);
    var writer = try WriterType(std.ArrayList(u8).Writer).init(out.writer(), 2, 0);
    for (records.items) |*record| try writer.write(record);
    try writer.finish();
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out.items[8..12], .little));
    const decoded = try test_decode(arena, out.items);
    try testing.expectEqual(records.items.len, decoded.len);
    for (records.items, decoded) |expected, actual| {
        try testing.expectEqualDeep(expected, actual);
    }

    // A version 1 export cannot hold them: the kind is unknown there.
    var downgraded = try arena.dupe(u8, out.items);
    std.mem.writeInt(u32, downgraded[8..12], 1, .little);
    try testing.expectError(error.Corrupt, test_decode(arena, downgraded));
    // A record change out of timestamp order with a row's.
    var reordered = try arena.dupe(Record, records.items);
    reordered[1].record_change.timestamp = 10;
    var out_bad = std.ArrayList(u8).init(arena);
    var writer_bad = try WriterType(std.ArrayList(u8).Writer).init(out_bad.writer(), 2, 0);
    for (reordered) |*record| try writer_bad.write(record);
    try writer_bad.finish();
    try testing.expectError(error.Corrupt, test_decode(arena, out_bad.items));
}
