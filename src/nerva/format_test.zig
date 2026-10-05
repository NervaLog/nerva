//! Format guards (docs/DECISIONS.md N54): tests that fail on any change to what Nerva puts on the
//! wire or on disk, so that no such change is made by accident.
//!
//! - Every wire and storage type's layout (size, field offsets and types, flag bits) and every
//!   persisted enum's values, rendered by reflection and compared to a snapshot.
//! - Golden values for what Nerva derives and stores: row keys, document chunk ids, the catalog's
//!   canonical layout and view JSON, and how a layout packs fields into a row.
//!
//! What a fixed script of commits stores is guarded in `state_machine_tests.zig`, beside the
//! harness it uses. A change that is meant must update these, with `SNAP_UPDATE=1`, and say why
//! (CLAUDE.md); one that changes the protocol or data file also moves the release string (N32).

const std = @import("std");
const testing = std.testing;

const stdx = @import("stdx");
const Snap = stdx.Snap;
const snap = Snap.snap_fn("src");

const nerva = @import("../nerva.zig");
const views = @import("views.zig");
const documents = @import("documents.zig");
const catalog = @import("catalog.zig");

/// The size, and each field's offset (or bit, for a packed struct), size and type, of a struct;
/// or the tag type and every value of an enum.
fn layout_render(writer: anytype, comptime T: type) !void {
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

test "format: wire and storage layouts" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    const writer = out.writer();

    inline for (.{
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
    }) |T| try layout_render(writer, T);

    // Tree ids name the LSM trees in the data file: never renumber them (CLAUDE.md).
    try writer.writeAll("tree_ids:\n");
    inline for (comptime std.meta.declarations(nerva.tree_ids)) |groove| {
        const ids = @field(nerva.tree_ids, groove.name);
        inline for (comptime std.meta.fieldNames(@TypeOf(ids))) |tree| {
            try writer.print("  {s}.{s} = {}\n", .{ groove.name, tree, @field(ids, tree) });
        }
    }

    try snap(@src(),
        \\nerva.Row: extern struct, size 128
        \\  key: offset 0, size 16, u128
        \\  value: offset 16, size 80, [80]u8
        \\  op: offset 96, size 8, u64
        \\  timestamp: offset 104, size 8, u64
        \\  flags: offset 112, size 4, nerva.Row.RowFlags
        \\  reserved: offset 116, size 12, [12]u8
        \\nerva.Row.RowFlags: packed struct, size 4
        \\  deleted: bit 0, 1 bits, bool
        \\  padding: bit 1, 31 bits, u31
        \\nerva.Entry: extern struct, size 128
        \\  id: offset 0, size 8, u64
        \\  table: offset 8, size 4, u32
        \\  kind: offset 12, size 1, nerva.EntryKind
        \\  reserved_a: offset 13, size 3, [3]u8
        \\  op_seen: offset 16, size 8, u64
        \\  reserved_b: offset 24, size 8, u64
        \\  value: offset 32, size 80, [80]u8
        \\  reserved_c: offset 112, size 16, [16]u8
        \\nerva.EntryKind: enum(u8), non-exhaustive
        \\  read = 1
        \\  put = 2
        \\  delete = 3
        \\  add = 4
        \\nerva.EntryResult: extern struct, size 32
        \\  status: offset 0, size 4, nerva.EntryStatus
        \\  reserved_a: offset 4, size 4, u32
        \\  op: offset 8, size 8, u64
        \\  applied: offset 16, size 8, i64
        \\  value: offset 24, size 8, u64
        \\nerva.EntryStatus: enum(u32)
        \\  ok = 0
        \\  conflict = 1
        \\  aborted = 2
        \\  kind_invalid = 3
        \\  table_invalid = 4
        \\  reserved_not_zero = 5
        \\  value_not_zero = 6
        \\  op_seen_not_zero = 7
        \\  write_duplicate = 8
        \\  out_of_bounds = 9
        \\  row_absent = 10
        \\  field_invalid = 11
        \\  delta_from_invalid = 12
        \\  view_key_field = 13
        \\  views_busy = 14
        \\  views_too_large = 15
        \\nerva.Add: extern struct, size 80
        \\  delta: offset 0, size 8, i64
        \\  min: offset 8, size 8, u64
        \\  max: offset 16, size 8, u64
        \\  delta_from: offset 24, size 4, u32
        \\  offset: offset 28, size 1, u8
        \\  field: offset 29, size 1, nerva.Add.AddField
        \\  flags: offset 30, size 1, nerva.Add.AddFlags
        \\  reserved_a: offset 31, size 1, u8
        \\  reserved_b: offset 32, size 48, [48]u8
        \\nerva.Add.AddFlags: packed struct, size 1
        \\  min: bit 0, 1 bits, bool
        \\  max: bit 1, 1 bits, bool
        \\  clamp: bit 2, 1 bits, bool
        \\  create: bit 3, 1 bits, bool
        \\  delta_from: bit 4, 1 bits, bool
        \\  padding: bit 5, 3 bits, u3
        \\nerva.Add.AddField: enum(u8), non-exhaustive
        \\  u64 = 1
        \\  i64 = 2
        \\nerva.RowKey: extern struct, size 16
        \\  id: offset 0, size 8, u64
        \\  table: offset 8, size 4, u32
        \\  reserved: offset 12, size 4, u32
        \\nerva.RowValue: extern struct, size 128
        \\  id: offset 0, size 8, u64
        \\  table: offset 8, size 4, u32
        \\  flags: offset 12, size 4, nerva.RowValue.RowValueFlags
        \\  op: offset 16, size 8, u64
        \\  op_read: offset 24, size 8, u64
        \\  value: offset 32, size 80, [80]u8
        \\  reserved_b: offset 112, size 16, [16]u8
        \\nerva.RowValue.RowValueFlags: packed struct, size 4
        \\  exists: bit 0, 1 bits, bool
        \\  padding: bit 1, 31 bits, u31
        \\nerva.Change: extern struct, size 128
        \\  id: offset 0, size 8, u64
        \\  table: offset 8, size 4, u32
        \\  kind: offset 12, size 1, nerva.ChangeKind
        \\  flags: offset 13, size 1, nerva.Change.ChangeFlags
        \\  reserved_a: offset 14, size 2, [2]u8
        \\  op: offset 16, size 8, u64
        \\  timestamp: offset 24, size 8, u64
        \\  value: offset 32, size 80, [80]u8
        \\  reserved_b: offset 112, size 16, [16]u8
        \\nerva.Change.ChangeFlags: packed struct, size 1
        \\  more: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.ChangeKind: enum(u8)
        \\  put = 1
        \\  delete = 2
        \\  end = 3
        \\nerva.ChangesFilter: extern struct, size 64
        \\  timestamp_min: offset 0, size 8, u64
        \\  limit: offset 8, size 4, u32
        \\  reserved: offset 12, size 52, [52]u8
        \\nerva.HistoryFilter: extern struct, size 64
        \\  id: offset 0, size 8, u64
        \\  table: offset 8, size 4, u32
        \\  limit: offset 12, size 4, u32
        \\  op_max: offset 16, size 8, u64
        \\  timestamp_max: offset 24, size 8, u64
        \\  reserved: offset 32, size 32, [32]u8
        \\nerva.Operation: enum(u8)
        \\  lookup_rows = 128
        \\  commit = 129
        \\  get_changes = 130
        \\  get_history = 131
        \\  get_view = 132
        \\  declare_view = 133
        \\  pulse = 134
        \\nerva.documents.Header: extern struct, size 24
        \\  namespace: offset 0, size 8, u64
        \\  reserved_a: offset 8, size 8, u64
        \\  key_size: offset 16, size 2, u16
        \\  flags: offset 18, size 2, nerva.documents.Header.Flags
        \\  payload_size: offset 20, size 4, u32
        \\nerva.documents.Header.Flags: packed struct, size 2
        \\  deleted: bit 0, 1 bits, bool
        \\  padding: bit 1, 15 bits, u15
        \\nerva.FieldKind: enum(u8), non-exhaustive
        \\  unsigned = 1
        \\  signed = 2
        \\  boolean = 3
        \\  bytes = 4
        \\nerva.FieldRef: extern struct, size 4
        \\  offset: offset 0, size 1, u8
        \\  size: offset 1, size 1, u8
        \\  kind: offset 2, size 1, nerva.FieldKind
        \\  reserved: offset 3, size 1, u8
        \\nerva.Comparison: enum(u8), non-exhaustive
        \\  eq = 1
        \\  ne = 2
        \\  lt = 3
        \\  le = 4
        \\  gt = 5
        \\  ge = 6
        \\nerva.AggregateFunction: enum(u8), non-exhaustive
        \\  count = 1
        \\  sum = 2
        \\  min = 3
        \\  max = 4
        \\nerva.Where: extern struct, size 32
        \\  field: offset 0, size 4, nerva.FieldRef
        \\  comparison: offset 4, size 1, nerva.Comparison
        \\  reserved: offset 5, size 11, [11]u8
        \\  value: offset 16, size 16, [16]u8
        \\nerva.AggregateRef: extern struct, size 8
        \\  function: offset 0, size 1, nerva.AggregateFunction
        \\  reserved: offset 1, size 3, [3]u8
        \\  field: offset 4, size 4, nerva.FieldRef
        \\nerva.ViewDefinition: extern struct, size 256
        \\  name: offset 0, size 32, [32]u8
        \\  table: offset 32, size 4, u32
        \\  where_count: offset 36, size 1, u8
        \\  group_by_count: offset 37, size 1, u8
        \\  aggregate_count: offset 38, size 1, u8
        \\  reserved_a: offset 39, size 1, u8
        \\  where: offset 40, size 128, [4]nerva.Where
        \\  group_by: offset 168, size 12, [3]nerva.FieldRef
        \\  aggregates: offset 180, size 48, [6]nerva.AggregateRef
        \\  reserved_b: offset 228, size 28, [28]u8
        \\nerva.DeclareStatus: enum(u32)
        \\  created = 1
        \\  exists = 2
        \\  different = 3
        \\  invalid = 4
        \\  table_invalid = 5
        \\  views_full = 6
        \\  table_views_full = 7
        \\  unsupported = 8
        \\  table_extremes_full = 9
        \\nerva.DeclareResult: extern struct, size 32
        \\  status: offset 0, size 4, nerva.DeclareStatus
        \\  reserved_a: offset 4, size 4, u32
        \\  view_id: offset 8, size 8, u64
        \\  op: offset 16, size 8, u64
        \\  reserved_b: offset 24, size 8, u64
        \\nerva.ViewState: enum(u8)
        \\  missing = 0
        \\  building = 1
        \\  ready = 2
        \\  failed = 3
        \\nerva.View: extern struct, size 512
        \\  id: offset 0, size 8, u64
        \\  timestamp: offset 8, size 8, u64
        \\  declared_op: offset 16, size 8, u64
        \\  backfill_cursor: offset 24, size 8, u64
        \\  group_count: offset 32, size 8, u64
        \\  state: offset 40, size 1, nerva.ViewState
        \\  reserved_a: offset 41, size 7, [7]u8
        \\  hash: offset 48, size 32, [32]u8
        \\  definition: offset 80, size 256, nerva.ViewDefinition
        \\  reserved_b: offset 336, size 176, [176]u8
        \\nerva.Group: extern struct, size 256
        \\  key: offset 0, size 16, u128
        \\  timestamp: offset 16, size 8, u64
        \\  count: offset 24, size 8, u64
        \\  group_key: offset 32, size 64, [64]u8
        \\  sums: offset 96, size 96, [6][16]u8
        \\  op: offset 192, size 8, u64
        \\  reserved: offset 200, size 56, [56]u8
        \\nerva.ViewQuery: extern struct, size 64
        \\  view_id: offset 0, size 8, u64
        \\  group_hash_min: offset 8, size 8, u64
        \\  limit: offset 16, size 4, u32
        \\  name: offset 20, size 32, [32]u8
        \\  reserved: offset 52, size 4, [4]u8
        \\  as_of: offset 56, size 8, u64
        \\nerva.ViewRecord: extern struct, size 256
        \\  kind: offset 0, size 1, nerva.ViewRecord.Kind
        \\  state: offset 1, size 1, nerva.ViewState
        \\  flags: offset 2, size 1, nerva.ViewRecord.Flags
        \\  reserved_a: offset 3, size 5, [5]u8
        \\  view_id: offset 8, size 8, u64
        \\  op: offset 16, size 8, u64
        \\  declared_op: offset 24, size 8, u64
        \\  group_count: offset 32, size 8, u64
        \\  cursor: offset 40, size 8, u64
        \\  group_hash: offset 48, size 8, u64
        \\  count: offset 56, size 8, u64
        \\  hash: offset 64, size 32, [32]u8
        \\  group_key: offset 96, size 64, [64]u8
        \\  sums: offset 160, size 96, [6][16]u8
        \\nerva.ViewRecord.Kind: enum(u8)
        \\  header = 1
        \\  group = 2
        \\nerva.ViewRecord.Flags: packed struct, size 1
        \\  more: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.Member: extern struct, size 128
        \\  key: offset 0, size 16, u128
        \\  position: offset 16, size 16, u128
        \\  timestamp: offset 32, size 8, u64
        \\  view_id: offset 40, size 4, u32
        \\  slot: offset 44, size 1, u8
        \\  flags: offset 45, size 1, nerva.Member.Flags
        \\  reserved: offset 46, size 2, [2]u8
        \\  group_key: offset 48, size 64, [64]u8
        \\  value: offset 112, size 16, [16]u8
        \\nerva.Member.Flags: packed struct, size 1
        \\  present: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.GroupVersion: extern struct, size 256
        \\  version: offset 0, size 16, u128
        \\  timestamp: offset 16, size 8, u64
        \\  op: offset 24, size 8, u64
        \\  key: offset 32, size 16, u128
        \\  count: offset 48, size 8, u64
        \\  group_key: offset 56, size 64, [64]u8
        \\  sums: offset 120, size 96, [6][16]u8
        \\  reserved: offset 216, size 40, [40]u8
        \\nerva.ViewVersion: extern struct, size 128
        \\  version: offset 0, size 16, u128
        \\  timestamp: offset 16, size 8, u64
        \\  op: offset 24, size 8, u64
        \\  group_count: offset 32, size 8, u64
        \\  state: offset 40, size 1, nerva.ViewState
        \\  reserved_a: offset 41, size 7, [7]u8
        \\  hash: offset 48, size 32, [32]u8
        \\  reserved_b: offset 80, size 48, [48]u8
        \\tree_ids:
        \\  Row.timestamp = 1
        \\  Row.key = 2
        \\  Change.timestamp = 3
        \\  Change.row_key = 4
        \\  View.timestamp = 5
        \\  View.id = 6
        \\  Group.timestamp = 7
        \\  Group.key = 8
        \\  Member.timestamp = 9
        \\  Member.key = 10
        \\  Member.order = 11
        \\  GroupVersion.timestamp = 12
        \\  GroupVersion.version = 13
        \\  ViewVersion.timestamp = 14
        \\  ViewVersion.version = 15
        \\
    ).diff(out.items);
}

test "format: persisted derivations" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    // A row's key in the rows tree and the changes' `row_key` index: table high, id low.
    try testing.expectEqual(@as(u128, 92233720368547758087), nerva.row_key(5, 7));
    try testing.expectEqual(
        @as(u128, 79226953643784955185497899007),
        nerva.row_key(0xFFFF0002, std.math.maxInt(u64)),
    );

    // Documents' tail chunk ids, computed apart from this code (Python's hashlib), as
    // `documents.zig`'s test does for `row_id`.
    const id0 = documents.row_id(0, "table.5");
    try testing.expectEqual(@as(u64, 14508685050127223560), id0);
    try testing.expectEqual(@as(u64, 4613465043632273798), documents.tail_id(id0, 1));
    try testing.expectEqual(@as(u64, 4590579942568114901), documents.tail_id(id0, 2));

    // Views' members and versions (N62), computed apart from this code (Python's hashlib and
    // integers): the members tree's keys and the order prefix, and both versions' keys.
    var group_key: [nerva.group_key_size_max]u8 = @splat(0);
    group_key[0] = 7;
    try testing.expectEqual(@as(u64, 647901329103683596), views.member_order_prefix(1, 2, &group_key));
    try testing.expectEqual(@as(u128, 14203992936756354744419), nerva.member_key(3, 2, 99));
    try testing.expectEqual(
        @as(u128, 5166132196011238418138295778693611525),
        nerva.group_version_key(1 << 64 | 17400499127971693294, 5),
    );
    try testing.expectEqual(@as(u128, 55340232221128654853), nerva.view_version_key(3, 5));

    // The catalog stores layouts and views as canonical JSON, compares declarations by it, and
    // packs a layout's fields into rows: all three are persisted.
    const layout = try catalog.layout_parse(arena,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
        \\  {"name":"sold","type":"bool"},{"name":"delta","type":"i64"},
        \\  {"name":"holder","type":"bytes","size":5},{"name":"row","type":"u16"},
        \\  {"name":"seat","type":"u32"}]}
    );
    const view = try catalog.view_parse(arena,
        \\{"table":5,"where":[{"field":"sold","op":"eq","value":true},
        \\  {"field":"price","op":"ge","value":"100"}],"group_by":["section","row"],
        \\  "aggregates":[{"fn":"count"},{"fn":"sum","field":"price"},{"fn":"min","field":"delta"},
        \\  {"fn":"max","field":"seat"}]}
    );
    const object = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"section":3,"price":"18446744073709551615","sold":true,"delta":"-2",
        \\  "holder":"6162630000","row":513,"seat":4294967295}
    , .{});
    const row = try catalog.fields_encode(&layout, object);

    try snap(@src(),
        \\layout: {"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},{"name":"sold","type":"bool"},{"name":"delta","type":"i64"},{"name":"holder","type":"bytes","size":5},{"name":"row","type":"u16"},{"name":"seat","type":"u32"}]}
        \\view: {"table":5,"where":[{"field":"sold","op":"eq","value":"1"},{"field":"price","op":"ge","value":"100"}],"group_by":["section","row"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"},{"fn":"min","field":"delta"},{"fn":"max","field":"seat"}]}
        \\row: 0300000000000000ffffffffffffffff0100000000000000feffffffffffffff6162630000000102ffffffff000000000000000000000000000000000000000000000000000000000000000000000000
        \\
    ).diff_fmt("layout: {s}\nview: {s}\nrow: {s}\n", .{
        try catalog.layout_render(arena, &layout),
        try catalog.view_render(arena, &view),
        std.fmt.fmtSliceHexLower(&row),
    });
}
