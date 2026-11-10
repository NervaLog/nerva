//! Format guards (docs/DECISIONS.md N54): tests that fail on any change to what Nerva puts on the
//! wire or on disk, so that no such change is made by accident.
//!
//! - Every wire and storage type's layout (size, field offsets and types, flag bits) and every
//!   persisted enum's values, rendered by reflection and compared to a snapshot.
//! - Golden values for what Nerva derives and stores: row keys, document chunk ids, the catalog's
//!   canonical layout and view JSON, and how a layout packs fields into a row.
//! - The export file's bytes (N80): one release writes it, another reads it, so its format
//!   changes only with its format version.
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
const indexes = @import("indexes.zig");
const documents = @import("documents.zig");
const catalog = @import("catalog.zig");
const export_file = @import("export_file.zig");
const format_digest = @import("format_digest.zig");

test "format: wire and storage layouts" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    const writer = out.writer();

    try format_digest.render(
        writer,
        format_digest.layout_types,
        format_digest.vendored_types ++ format_digest.vendored_headers,
        format_digest.build_inputs,
    );
    // The digest follows the layouts (P259b): a change to either fails this test. Updating the
    // snapshot needs a decision (docs/decisions/) that says what changed and whether
    // `format_digest.format_epoch` moves with it.
    const digest = format_digest.digest_text(out.items);
    try testing.expectEqual(format_digest.format_digest, digest);
    try writer.print("format_digest: {s}\n", .{format_digest.hex(&digest)});

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
        \\  key = 5
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
        \\  unpaired = 16
        \\  conserved_write = 17
        \\  committed_before = 18
        \\  key_reused = 19
        \\  key_collision = 20
        \\  key_misplaced = 21
        \\  key_invalid = 22
        \\  id_invalid = 23
        \\  id_collision = 24
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
        \\  pair: bit 5, 1 bits, bool
        \\  padding: bit 6, 2 bits, u2
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
        \\  declare_ledger = 135
        \\  get_ledger = 136
        \\  commit_wide = 137
        \\  lookup_records = 138
        \\  get_record_changes = 139
        \\  get_record_history = 140
        \\  declare_index = 141
        \\  scan_index = 142
        \\  get_index = 143
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
        \\  offset_high: offset 3, size 1, u8
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
        \\  ledger_field = 10
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
        \\  backfill_cursor_high: offset 336, size 4, u32
        \\  reserved_b: offset 340, size 172, [172]u8
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
        \\nerva.LedgerField: extern struct, size 16
        \\  table: offset 0, size 4, u32
        \\  offset: offset 4, size 1, u8
        \\  flags: offset 5, size 1, nerva.LedgerField.Flags
        \\  reserved: offset 6, size 2, [2]u8
        \\  floor: offset 8, size 8, i64
        \\nerva.LedgerField.Flags: packed struct, size 1
        \\  floor: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.LedgerDefinition: extern struct, size 264
        \\  id: offset 0, size 4, u32
        \\  field_count: offset 4, size 1, u8
        \\  reserved: offset 5, size 3, [3]u8
        \\  fields: offset 8, size 256, [16]nerva.LedgerField
        \\nerva.DeclareLedgerStatus: enum(u32)
        \\  created = 1
        \\  exists = 2
        \\  ledger_immutable = 3
        \\  ledger_field_taken = 4
        \\  invalid = 5
        \\  table_invalid = 6
        \\  ledgers_full = 7
        \\  field_viewed = 8
        \\nerva.DeclareLedgerResult: extern struct, size 16
        \\  status: offset 0, size 4, nerva.DeclareLedgerStatus
        \\  reserved: offset 4, size 4, u32
        \\  op: offset 8, size 8, u64
        \\nerva.LedgerQuery: extern struct, size 16
        \\  id: offset 0, size 4, u32
        \\  reserved: offset 4, size 4, [4]u8
        \\  slot: offset 8, size 8, u64
        \\nerva.Ledger: extern struct, size 512
        \\  slot: offset 0, size 8, u64
        \\  timestamp: offset 8, size 8, u64
        \\  op: offset 16, size 8, u64
        \\  reserved_a: offset 24, size 8, u64
        \\  definition: offset 32, size 264, nerva.LedgerDefinition
        \\  reserved_b: offset 296, size 216, [216]u8
        \\nerva.CommitKey: extern struct, size 80
        \\  key: offset 0, size 16, u128
        \\  checksum: offset 16, size 16, u128
        \\  entry_count: offset 32, size 4, u32
        \\  reserved: offset 36, size 44, [44]u8
        \\nerva.WideEntry: extern struct, size 512
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  kind: offset 20, size 1, nerva.EntryKind
        \\  reserved_a: offset 21, size 3, [3]u8
        \\  op_seen: offset 24, size 8, u64
        \\  reserved_b: offset 32, size 32, [32]u8
        \\  value: offset 64, size 448, [448]u8
        \\nerva.Record: extern struct, size 512
        \\  key: offset 0, size 16, u128
        \\  id: offset 16, size 16, u128
        \\  table: offset 32, size 4, u32
        \\  flags: offset 36, size 4, nerva.Row.RowFlags
        \\  op: offset 40, size 8, u64
        \\  timestamp: offset 48, size 8, u64
        \\  reserved: offset 56, size 8, [8]u8
        \\  value: offset 64, size 448, [448]u8
        \\nerva.RecordKey: extern struct, size 32
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  reserved: offset 20, size 12, [12]u8
        \\nerva.RecordValue: extern struct, size 512
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  flags: offset 20, size 4, nerva.RecordValue.RecordValueFlags
        \\  op: offset 24, size 8, u64
        \\  op_read: offset 32, size 8, u64
        \\  reserved: offset 40, size 24, [24]u8
        \\  value: offset 64, size 448, [448]u8
        \\nerva.RecordValue.RecordValueFlags: packed struct, size 4
        \\  exists: bit 0, 1 bits, bool
        \\  collision: bit 1, 1 bits, bool
        \\  padding: bit 2, 30 bits, u30
        \\nerva.RecordChange: extern struct, size 512
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  kind: offset 20, size 1, nerva.ChangeKind
        \\  flags: offset 21, size 1, nerva.Change.ChangeFlags
        \\  reserved_a: offset 22, size 2, [2]u8
        \\  op: offset 24, size 8, u64
        \\  timestamp: offset 32, size 8, u64
        \\  reserved_b: offset 40, size 24, [24]u8
        \\  value: offset 64, size 448, [448]u8
        \\nerva.RecordHistoryFilter: extern struct, size 64
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  limit: offset 20, size 4, u32
        \\  op_max: offset 24, size 8, u64
        \\  timestamp_max: offset 32, size 8, u64
        \\  reserved: offset 40, size 24, [24]u8
        \\nerva.IndexDefinition: extern struct, size 256
        \\  name: offset 0, size 32, [32]u8
        \\  table: offset 32, size 4, u32
        \\  eq_count: offset 36, size 1, u8
        \\  where_count: offset 37, size 1, u8
        \\  flags: offset 38, size 1, nerva.IndexDefinition.Flags
        \\  reserved_a: offset 39, size 1, u8
        \\  eq: offset 40, size 12, [3]nerva.FieldRef
        \\  order: offset 52, size 4, nerva.FieldRef
        \\  where: offset 56, size 128, [4]nerva.Where
        \\  reserved_b: offset 184, size 72, [72]u8
        \\nerva.IndexDefinition.Flags: packed struct, size 1
        \\  order: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.DeclareIndexStatus: enum(u32)
        \\  created = 1
        \\  exists = 2
        \\  different = 3
        \\  invalid = 4
        \\  table_invalid = 5
        \\  indexes_full = 6
        \\  table_indexes_full = 7
        \\nerva.DeclareIndexResult: extern struct, size 32
        \\  status: offset 0, size 4, nerva.DeclareIndexStatus
        \\  reserved_a: offset 4, size 4, u32
        \\  index_id: offset 8, size 8, u64
        \\  op: offset 16, size 8, u64
        \\  reserved_b: offset 24, size 8, u64
        \\nerva.IndexState: enum(u8)
        \\  missing = 0
        \\  building = 1
        \\  ready = 2
        \\nerva.Index: extern struct, size 512
        \\  id: offset 0, size 8, u64
        \\  timestamp: offset 8, size 8, u64
        \\  backfill_cursor: offset 16, size 16, u128
        \\  declared_op: offset 32, size 8, u64
        \\  entry_count: offset 40, size 8, u64
        \\  state: offset 48, size 1, nerva.IndexState
        \\  reserved_a: offset 49, size 15, [15]u8
        \\  definition: offset 64, size 256, nerva.IndexDefinition
        \\  reserved_b: offset 320, size 192, [192]u8
        \\nerva.IndexEntry: extern struct, size 128
        \\  key: offset 0, size 16, u128
        \\  position: offset 16, size 16, u128
        \\  id: offset 32, size 16, u128
        \\  timestamp: offset 48, size 8, u64
        \\  index_id: offset 56, size 4, u32
        \\  flags: offset 60, size 1, nerva.IndexEntry.Flags
        \\  reserved: offset 61, size 3, [3]u8
        \\  eq_key: offset 64, size 64, [64]u8
        \\nerva.IndexEntry.Flags: packed struct, size 1
        \\  present: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.IndexQuery: extern struct, size 192
        \\  index_id: offset 0, size 8, u64
        \\  eq_key: offset 8, size 64, [64]u8
        \\  order_min: offset 72, size 8, u64
        \\  order_max: offset 80, size 8, u64
        \\  cursor_order: offset 88, size 8, u64
        \\  cursor_timestamp: offset 96, size 8, u64
        \\  limit: offset 104, size 4, u32
        \\  flags: offset 108, size 1, nerva.IndexQuery.Flags
        \\  reserved_a: offset 109, size 3, [3]u8
        \\  name: offset 112, size 32, [32]u8
        \\  reserved_b: offset 144, size 48, [48]u8
        \\nerva.IndexQuery.Flags: packed struct, size 1
        \\  descending: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.IndexRecord: extern struct, size 512
        \\  id: offset 0, size 16, u128
        \\  table: offset 16, size 4, u32
        \\  kind: offset 20, size 1, nerva.IndexRecord.Kind
        \\  flags: offset 21, size 1, nerva.IndexRecord.Flags
        \\  state: offset 22, size 1, nerva.IndexState
        \\  reserved_a: offset 23, size 1, u8
        \\  op: offset 24, size 8, u64
        \\  order: offset 32, size 8, u64
        \\  timestamp: offset 40, size 8, u64
        \\  index_id: offset 48, size 8, u64
        \\  reserved_b: offset 56, size 8, [8]u8
        \\  value: offset 64, size 448, [448]u8
        \\nerva.IndexRecord.Kind: enum(u8)
        \\  header = 1
        \\  record = 2
        \\nerva.IndexRecord.Flags: packed struct, size 1
        \\  more: bit 0, 1 bits, bool
        \\  padding: bit 1, 7 bits, u7
        \\nerva.IndexGet: extern struct, size 32
        \\  id: offset 0, size 8, u64
        \\  reserved: offset 8, size 24, [24]u8
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
        \\  Ledger.timestamp = 16
        \\  Ledger.slot = 17
        \\  Record.timestamp = 18
        \\  Record.key = 19
        \\  RecordChange.timestamp = 20
        \\  RecordChange.record_key = 21
        \\  Index.timestamp = 22
        \\  Index.id = 23
        \\  IndexEntry.timestamp = 24
        \\  IndexEntry.key = 25
        \\  IndexEntry.order = 26
        \\cluster:
        \\  cache_line_size = 64
        \\  clients_max = 7
        \\  pipeline_prepare_queue_max = 4
        \\  view_change_headers_suffix_max = 5
        \\  quorum_replication_max = 3
        \\  journal_slot_count = 32
        \\  message_size_max = 4096
        \\  superblock_copies = 4
        \\  block_size = 4096
        \\  lsm_levels = 7
        \\  lsm_growth_factor = 4
        \\  lsm_compaction_ops = 4
        \\  lsm_snapshots_max = 32
        \\  lsm_manifest_compact_extra_blocks = 5
        \\  lsm_table_coalescing_threshold_percent = 50
        \\  vsr_releases_max = 64
        \\  lsm_scans_max = 12
        \\superblock_version: 2
        \\format_epoch: 1
        \\vendored:
        \\vsr.message_header.Header: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved_command: offset 128, size 128, [128]u8
        \\vsr.Command: enum(u8)
        \\  reserved = 0
        \\  ping = 1
        \\  pong = 2
        \\  ping_client = 3
        \\  pong_client = 4
        \\  request = 5
        \\  prepare = 6
        \\  prepare_ok = 7
        \\  reply = 8
        \\  commit = 9
        \\  exit_view = 10
        \\  join_view = 11
        \\  get_view = 13
        \\  get_headers = 14
        \\  get_prepare = 15
        \\  get_reply = 16
        \\  get_blocks = 19
        \\  headers = 17
        \\  eviction = 18
        \\  block = 20
        \\  view = 24
        \\  peer_hello = 25
        \\  peer_challenge = 26
        \\  peer_proof = 27
        \\  deprecated_12 = 12
        \\  deprecated_21 = 21
        \\  deprecated_22 = 22
        \\  deprecated_23 = 23
        \\vsr.Operation: enum(u8), non-exhaustive
        \\  reserved = 0
        \\  root = 1
        \\  register = 2
        \\  reconfigure = 3
        \\  pulse = 4
        \\  upgrade = 5
        \\  noop = 6
        \\multiversion.Release: extern struct, size 4
        \\  value: offset 0, size 4, u32
        \\vsr.RegisterRequest: extern struct, size 256
        \\  batch_size_limit: offset 0, size 4, u32
        \\  reserved: offset 4, size 252, [252]u8
        \\vsr.RegisterResult: extern struct, size 64
        \\  batch_size_limit: offset 0, size 4, u32
        \\  reserved: offset 4, size 60, [60]u8
        \\vsr.BlockRequest: extern struct, size 32
        \\  block_checksum: offset 0, size 16, u128
        \\  block_address: offset 16, size 8, u64
        \\  reserved: offset 24, size 8, [8]u8
        \\vsr.ReconfigurationRequest: extern struct, size 256
        \\  members: offset 0, size 192, [12]u128
        \\  epoch: offset 192, size 4, u32
        \\  replica_count: offset 196, size 1, u8
        \\  standby_count: offset 197, size 1, u8
        \\  reserved: offset 198, size 54, [54]u8
        \\  result: offset 252, size 4, vsr.ReconfigurationResult
        \\vsr.ReconfigurationResult: enum(u32)
        \\  reserved = 0
        \\  ok = 1
        \\  replica_count_zero = 2
        \\  replica_count_max_exceeded = 3
        \\  standby_count_max_exceeded = 4
        \\  members_invalid = 5
        \\  members_count_invalid = 6
        \\  reserved_field = 7
        \\  result_must_be_reserved = 8
        \\  epoch_in_the_past = 9
        \\  epoch_in_the_future = 10
        \\  different_replica_count = 11
        \\  different_standby_count = 12
        \\  different_member_set = 13
        \\  configuration_applied = 14
        \\  configuration_conflict = 15
        \\  configuration_is_no_op = 16
        \\vsr.message_header.Header.Eviction.Reason: enum(u8)
        \\  reserved = 0
        \\  no_session = 1
        \\  client_release_too_low = 2
        \\  client_release_too_high = 3
        \\  invalid_request_operation = 4
        \\  invalid_request_body = 5
        \\  invalid_request_body_size = 6
        \\  session_too_low = 7
        \\  session_release_mismatch = 8
        \\vsr.UpgradeRequest: extern struct, size 16
        \\  release: offset 0, size 4, multiversion.Release
        \\  reserved: offset 4, size 12, [12]u8
        \\vsr.superblock.SuperBlockHeader: extern struct, size 8192
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  copy: offset 32, size 2, u16
        \\  version: offset 34, size 2, u16
        \\  release_format: offset 36, size 4, multiversion.Release
        \\  sequence: offset 40, size 8, u64
        \\  cluster: offset 48, size 16, u128
        \\  parent: offset 64, size 16, u128
        \\  parent_padding: offset 80, size 16, u128
        \\  vsr_state: offset 96, size 2048, vsr.superblock.SuperBlockHeader.VSRState
        \\  flags: offset 2144, size 8, u64
        \\  view_headers_count: offset 2152, size 4, u32
        \\  reserved: offset 2156, size 1940, [1940]u8
        \\  view_headers_all: offset 4096, size 1792, [7]vsr.message_header.Header.Prepare
        \\  view_headers_reserved: offset 5888, size 2304, [2304]u8
        \\vsr.superblock.SuperBlockHeader.VSRState: extern struct, size 2048
        \\  checkpoint: offset 0, size 1024, vsr.superblock.SuperBlockHeader.CheckpointState
        \\  replica_id: offset 1024, size 16, u128
        \\  members: offset 1040, size 192, [12]u128
        \\  commit_max: offset 1232, size 8, u64
        \\  sync_op_min: offset 1240, size 8, u64
        \\  sync_op_max: offset 1248, size 8, u64
        \\  sync_view: offset 1256, size 4, u32
        \\  log_view: offset 1260, size 4, u32
        \\  view: offset 1264, size 4, u32
        \\  replica_count: offset 1268, size 1, u8
        \\  origin: offset 1269, size 32, [32]u8
        \\  reserved: offset 1301, size 747, [747]u8
        \\vsr.superblock.SuperBlockHeader.CheckpointState: extern struct, size 1024
        \\  header: offset 0, size 256, vsr.message_header.Header.Prepare
        \\  free_set_blocks_acquired_last_block_checksum: offset 256, size 16, u128
        \\  free_set_blocks_acquired_last_block_checksum_padding: offset 272, size 16, u128
        \\  free_set_blocks_released_last_block_checksum: offset 288, size 16, u128
        \\  free_set_blocks_released_last_block_checksum_padding: offset 304, size 16, u128
        \\  client_sessions_last_block_checksum: offset 320, size 16, u128
        \\  client_sessions_last_block_checksum_padding: offset 336, size 16, u128
        \\  manifest_oldest_checksum: offset 352, size 16, u128
        \\  manifest_oldest_checksum_padding: offset 368, size 16, u128
        \\  manifest_newest_checksum: offset 384, size 16, u128
        \\  manifest_newest_checksum_padding: offset 400, size 16, u128
        \\  snapshots_block_checksum: offset 416, size 16, u128
        \\  snapshots_block_checksum_padding: offset 432, size 16, u128
        \\  free_set_blocks_acquired_checksum: offset 448, size 16, u128
        \\  free_set_blocks_released_checksum: offset 464, size 16, u128
        \\  client_sessions_checksum: offset 480, size 16, u128
        \\  parent_checkpoint_id: offset 496, size 16, u128
        \\  grandparent_checkpoint_id: offset 512, size 16, u128
        \\  free_set_blocks_acquired_last_block_address: offset 528, size 8, u64
        \\  free_set_blocks_released_last_block_address: offset 536, size 8, u64
        \\  client_sessions_last_block_address: offset 544, size 8, u64
        \\  manifest_oldest_address: offset 552, size 8, u64
        \\  manifest_newest_address: offset 560, size 8, u64
        \\  snapshots_block_address: offset 568, size 8, u64
        \\  storage_size: offset 576, size 8, u64
        \\  free_set_blocks_acquired_size: offset 584, size 8, u64
        \\  free_set_blocks_released_size: offset 592, size 8, u64
        \\  client_sessions_size: offset 600, size 8, u64
        \\  manifest_block_count: offset 608, size 4, u32
        \\  release: offset 612, size 4, multiversion.Release
        \\  reserved: offset 616, size 408, [408]u8
        \\lsm.schema.BlockType: enum(u8)
        \\  reserved = 0
        \\  free_set = 1
        \\  client_sessions = 2
        \\  manifest = 3
        \\  index = 4
        \\  value = 5
        \\lsm.schema.Checksum: extern struct, size 32
        \\  value: offset 0, size 16, u128
        \\  padding: offset 16, size 16, u128
        \\lsm.schema.TableIndex.Metadata: extern struct, size 96
        \\  value_block_count: offset 0, size 4, u32
        \\  value_block_count_max: offset 4, size 4, u32
        \\  key_size: offset 8, size 4, u32
        \\  tree_id: offset 12, size 2, u16
        \\  reserved: offset 14, size 82, [82]u8
        \\lsm.schema.TableValue.Metadata: extern struct, size 96
        \\  value_count_max: offset 0, size 4, u32
        \\  value_count: offset 4, size 4, u32
        \\  value_size: offset 8, size 4, u32
        \\  tree_id: offset 12, size 2, u16
        \\  reserved: offset 14, size 82, [82]u8
        \\lsm.schema.TrailerNode.Metadata: extern struct, size 96
        \\  previous_trailer_block_checksum: offset 0, size 16, u128
        \\  previous_trailer_block_checksum_padding: offset 16, size 16, u128
        \\  previous_trailer_block_address: offset 32, size 8, u64
        \\  reserved: offset 40, size 56, [56]u8
        \\lsm.schema.ManifestNode.Metadata: extern struct, size 96
        \\  previous_manifest_block_checksum: offset 0, size 16, u128
        \\  previous_manifest_block_checksum_padding: offset 16, size 16, u128
        \\  previous_manifest_block_address: offset 32, size 8, u64
        \\  entry_count: offset 40, size 4, u32
        \\  reserved: offset 44, size 52, [52]u8
        \\lsm.schema.ManifestNode.TableInfo: extern struct, size 128
        \\  key_min: offset 0, size 32, [32]u8
        \\  key_max: offset 32, size 32, [32]u8
        \\  checksum: offset 64, size 16, u128
        \\  checksum_padding: offset 80, size 16, u128
        \\  address: offset 96, size 8, u64
        \\  snapshot_min: offset 104, size 8, u64
        \\  snapshot_max: offset 112, size 8, u64
        \\  value_count: offset 120, size 4, u32
        \\  tree_id: offset 124, size 2, u16
        \\  label: offset 126, size 1, lsm.schema.ManifestNode.Label
        \\  reserved: offset 127, size 1, [1]u8
        \\lsm.schema.ManifestNode.Event: enum(u2)
        \\  reserved = 0
        \\  insert = 1
        \\  update = 2
        \\  remove = 3
        \\lsm.schema.ManifestNode.Label: packed struct, size 1
        \\  level: bit 0, 6 bits, u6
        \\  event: bit 6, 2 bits, lsm.schema.ManifestNode.Event
        \\lsm.composite_key.CompositeKeyType(u64): extern struct, size 16
        \\  field: offset 0, size 8, u64
        \\  timestamp: offset 8, size 8, u64
        \\  padding: offset 16, size 0, u0
        \\lsm.composite_key.CompositeKeyType(u128): extern struct, size 32
        \\  field: offset 0, size 16, u128
        \\  timestamp: offset 16, size 8, u64
        \\  padding: offset 24, size 8, u64
        \\lsm.unique_key.UniqueKeyType(u64): extern struct, size 16
        \\  field: offset 0, size 8, u64
        \\  timestamp: offset 8, size 8, u64
        \\  padding: offset 16, size 0, u0
        \\lsm.unique_key.UniqueKeyType(u128): extern struct, size 32
        \\  field: offset 0, size 16, u128
        \\  timestamp: offset 16, size 8, u64
        \\  padding: offset 24, size 8, u64
        \\vsr.message_header.Header.Reserved: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved: offset 128, size 128, [128]u8
        \\vsr.message_header.Header.Ping: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  checkpoint_id: offset 128, size 16, u128
        \\  checkpoint_op: offset 144, size 8, u64
        \\  ping_timestamp_monotonic: offset 152, size 8, u64
        \\  release_count: offset 160, size 2, u16
        \\  origin: offset 162, size 32, [32]u8
        \\  reserved: offset 194, size 62, [62]u8
        \\vsr.message_header.Header.Pong: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  ping_timestamp_monotonic: offset 128, size 8, u64
        \\  pong_timestamp_wall: offset 136, size 8, u64
        \\  origin: offset 144, size 32, [32]u8
        \\  reserved: offset 176, size 80, [80]u8
        \\vsr.message_header.Header.PingClient: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  client: offset 128, size 16, u128
        \\  ping_timestamp_monotonic: offset 144, size 8, u64
        \\  session: offset 152, size 8, u64
        \\  reserved: offset 160, size 96, [96]u8
        \\vsr.message_header.Header.PongClient: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  ping_timestamp_monotonic: offset 128, size 8, u64
        \\  reserved: offset 136, size 120, [120]u8
        \\vsr.message_header.Header.Request: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  parent: offset 128, size 16, u128
        \\  parent_padding: offset 144, size 16, u128
        \\  client: offset 160, size 16, u128
        \\  session: offset 176, size 8, u64
        \\  timestamp: offset 184, size 8, u64
        \\  request: offset 192, size 4, u32
        \\  operation: offset 196, size 1, vsr.Operation
        \\  previous_request_latency_padding: offset 197, size 3, [3]u8
        \\  previous_request_latency: offset 200, size 4, u32
        \\  reserved: offset 204, size 52, [52]u8
        \\vsr.message_header.Header.Prepare: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  parent: offset 128, size 16, u128
        \\  parent_padding: offset 144, size 16, u128
        \\  request_checksum: offset 160, size 16, u128
        \\  request_checksum_padding: offset 176, size 16, u128
        \\  checkpoint_id: offset 192, size 16, u128
        \\  client: offset 208, size 16, u128
        \\  op: offset 224, size 8, u64
        \\  commit: offset 232, size 8, u64
        \\  timestamp: offset 240, size 8, u64
        \\  request: offset 248, size 4, u32
        \\  operation: offset 252, size 1, vsr.Operation
        \\  reserved: offset 253, size 3, [3]u8
        \\vsr.message_header.Header.PrepareOk: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  parent: offset 128, size 16, u128
        \\  parent_padding: offset 144, size 16, u128
        \\  prepare_checksum: offset 160, size 16, u128
        \\  prepare_checksum_padding: offset 176, size 16, u128
        \\  checkpoint_id: offset 192, size 16, u128
        \\  client: offset 208, size 16, u128
        \\  op: offset 224, size 8, u64
        \\  commit_min: offset 232, size 8, u64
        \\  timestamp: offset 240, size 8, u64
        \\  request: offset 248, size 4, u32
        \\  operation: offset 252, size 1, vsr.Operation
        \\  reserved: offset 253, size 3, [3]u8
        \\vsr.message_header.Header.Reply: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  request_checksum: offset 128, size 16, u128
        \\  request_checksum_padding: offset 144, size 16, u128
        \\  context: offset 160, size 16, u128
        \\  context_padding: offset 176, size 16, u128
        \\  client: offset 192, size 16, u128
        \\  op: offset 208, size 8, u64
        \\  commit: offset 216, size 8, u64
        \\  timestamp: offset 224, size 8, u64
        \\  request: offset 232, size 4, u32
        \\  operation: offset 236, size 1, vsr.Operation
        \\  reserved: offset 237, size 19, [19]u8
        \\vsr.message_header.Header.Commit: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  commit_checksum: offset 128, size 16, u128
        \\  commit_checksum_padding: offset 144, size 16, u128
        \\  checkpoint_id: offset 160, size 16, u128
        \\  checkpoint_op: offset 176, size 8, u64
        \\  commit: offset 184, size 8, u64
        \\  timestamp_monotonic: offset 192, size 8, u64
        \\  reserved: offset 200, size 56, [56]u8
        \\vsr.message_header.Header.ExitView: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved: offset 128, size 128, [128]u8
        \\vsr.message_header.Header.JoinView: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  present_bitset: offset 128, size 16, u128
        \\  nack_bitset: offset 144, size 16, u128
        \\  op: offset 160, size 8, u64
        \\  commit_min: offset 168, size 8, u64
        \\  checkpoint_op: offset 176, size 8, u64
        \\  log_view: offset 184, size 4, u32
        \\  reserved: offset 188, size 68, [68]u8
        \\vsr.message_header.Header.GetView: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  nonce: offset 128, size 16, u128
        \\  reserved: offset 144, size 112, [112]u8
        \\vsr.message_header.Header.GetHeaders: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  op_min: offset 128, size 8, u64
        \\  op_max: offset 136, size 8, u64
        \\  reserved: offset 144, size 112, [112]u8
        \\vsr.message_header.Header.GetPrepare: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  prepare_checksum: offset 128, size 16, u128
        \\  prepare_checksum_padding: offset 144, size 16, u128
        \\  prepare_op: offset 160, size 8, u64
        \\  reserved: offset 168, size 88, [88]u8
        \\vsr.message_header.Header.GetReply: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reply_checksum: offset 128, size 16, u128
        \\  reply_checksum_padding: offset 144, size 16, u128
        \\  reply_client: offset 160, size 16, u128
        \\  reply_op: offset 176, size 8, u64
        \\  reserved: offset 184, size 72, [72]u8
        \\vsr.message_header.Header.GetBlocks: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved: offset 128, size 128, [128]u8
        \\vsr.message_header.Header.Headers: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved: offset 128, size 128, [128]u8
        \\vsr.message_header.Header.Eviction: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  client: offset 128, size 16, u128
        \\  reserved: offset 144, size 111, [111]u8
        \\  reason: offset 255, size 1, vsr.message_header.Header.Eviction.Reason
        \\vsr.message_header.Header.Block: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  metadata_bytes: offset 128, size 96, [96]u8
        \\  address: offset 224, size 8, u64
        \\  snapshot: offset 232, size 8, u64
        \\  block_type: offset 240, size 1, lsm.schema.BlockType
        \\  reserved_block: offset 241, size 15, [15]u8
        \\vsr.message_header.Header.View: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  nonce: offset 128, size 16, u128
        \\  op: offset 144, size 8, u64
        \\  commit_max: offset 152, size 8, u64
        \\  checkpoint_op: offset 160, size 8, u64
        \\  reserved: offset 168, size 88, [88]u8
        \\vsr.message_header.Header.PeerHello: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  nonce: offset 128, size 16, u128
        \\  origin: offset 144, size 32, [32]u8
        \\  reserved: offset 176, size 80, [80]u8
        \\vsr.message_header.Header.PeerChallenge: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  nonce: offset 128, size 16, u128
        \\  mac: offset 144, size 16, [16]u8
        \\  origin: offset 160, size 32, [32]u8
        \\  reserved: offset 192, size 64, [64]u8
        \\vsr.message_header.Header.PeerProof: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  mac: offset 128, size 16, [16]u8
        \\  reserved: offset 144, size 112, [112]u8
        \\vsr.message_header.Header.Deprecated: extern struct, size 256
        \\  checksum: offset 0, size 16, u128
        \\  checksum_padding: offset 16, size 16, u128
        \\  checksum_body: offset 32, size 16, u128
        \\  checksum_body_padding: offset 48, size 16, u128
        \\  nonce_reserved: offset 64, size 16, u128
        \\  cluster: offset 80, size 16, u128
        \\  size: offset 96, size 4, u32
        \\  epoch: offset 100, size 4, u32
        \\  view: offset 104, size 4, u32
        \\  release: offset 108, size 4, multiversion.Release
        \\  protocol: offset 112, size 2, u16
        \\  command: offset 114, size 1, vsr.Command
        \\  replica: offset 115, size 1, u8
        \\  reserved_frame: offset 116, size 12, [12]u8
        \\  reserved: offset 128, size 128, [128]u8
        \\derivations:
        \\row_key(5, 7) = 92233720368547758087
        \\row_key(0xFFFF0002, max) = 79226953643784955185497899007
        \\documents.row_id(0, table.5) = 14508685050127223560
        \\documents.tail_id(id0, 1) = 4613465043632273798
        \\documents.tail_id(id0, 2) = 4590579942568114901
        \\commit_key_id(1) = 10562569181977696665
        \\commit_key_id(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef) = 6225441356227291988
        \\record_key(0x8000_0001, 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef) = 170141183601885234047750166926088000722
        \\indexes.position_prefix(3, eq 02..) = 16297427750713542426
        \\index_entry_key(3, 0x8000_0001_0000_0000_0000_0000_0000_0005) = 237684487542793012780631851013
        \\views.member_order_prefix(1, 2, key 07..) = 647901329103683596
        \\member_key(3, 2, 99) = 14203992936756354744419
        \\group_version_key(1 << 64 | 17400499127971693294, 5) = 5166132196011238418138295778693611525
        \\view_version_key(3, 5) = 55340232221128654853
        \\format_digest: f2060561d266df00982069391927c8bc31aabf7156ef5af134393f0f5d78b0e1
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

    // Commit keys' row ids (P123), computed apart from this code (Python's hashlib).
    try testing.expectEqual(@as(u64, 10562569181977696665), nerva.commit_key_id(1));
    try testing.expectEqual(
        @as(u64, 6225441356227291988),
        nerva.commit_key_id(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef),
    );

    // Records' keys (P123b), computed apart from this code (Python's hashlib).
    try testing.expectEqual(
        @as(u128, 170141183601885234047750166926088000722),
        nerva.record_key(0x8000_0001, 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef),
    );

    // Indexes' entry keys and positions (P123c), computed apart from this code (Python's
    // hashlib and integers).
    var eq_key: [nerva.group_key_size_max]u8 = @splat(0);
    eq_key[0] = 2;
    try testing.expectEqual(@as(u64, 16297427750713542426), indexes.position_prefix(3, &eq_key));
    try testing.expectEqual(
        @as(u128, 237684487542793012780631851013),
        nerva.index_entry_key(3, 0x8000_0001_0000_0000_0000_0000_0000_0005),
    );

    // Views' members and versions (N62), computed apart from this code (Python's hashlib and
    // integers): the members tree's keys and the order prefix, and both versions' keys.
    var group_key: [nerva.group_key_size_max]u8 = @splat(0);
    group_key[0] = 7;
    try testing.expectEqual(
        @as(u64, 647901329103683596),
        views.member_order_prefix(1, 2, &group_key),
    );
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
    , 5);
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
    const row = (try catalog.fields_encode(&layout, object))[0..nerva.value_size];

    const layout_text = try catalog.layout_render(arena, &layout);
    const view_text = try catalog.view_render(arena, &view);

    try snap(@src(),
        \\layout: {"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},{"name":"sold","type":"bool"},{"name":"delta","type":"i64"},{"name":"holder","type":"bytes","size":5},{"name":"row","type":"u16"},{"name":"seat","type":"u32"}]}
        \\view: {"table":5,"where":[{"field":"sold","op":"eq","value":"1"},{"field":"price","op":"ge","value":"100"}],"group_by":["section","row"],"aggregates":[{"fn":"count"},{"fn":"sum","field":"price"},{"fn":"min","field":"delta"},{"fn":"max","field":"seat"}]}
        \\row: 0300000000000000ffffffffffffffff0100000000000000feffffffffffffff6162630000000102ffffffff000000000000000000000000000000000000000000000000000000000000000000000000
        \\
    ).diff_fmt("layout: {s}\nview: {s}\nrow: {s}\n", .{
        layout_text,
        view_text,
        std.fmt.fmtSliceHexLower(row),
    });

    // The pure derivations above are hashed into the format digest (P269d), so changing one
    // moves it. These three cannot run at comptime (they parse JSON), so their output is tied to
    // `format_epoch` by a ledger: a change needs a new entry with a higher epoch, and the last
    // entry must be the current epoch, so the epoch moves with it.
    var text = std.ArrayList(u8).init(testing.allocator);
    defer text.deinit();
    try text.writer().print("layout: {s}\nview: {s}\nrow: {s}\n", .{
        layout_text,
        view_text,
        std.fmt.fmtSliceHexLower(row),
    });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text.items, &hash, .{});
    const ledger = [_]struct { epoch: u32, hash: []const u8 }{
        .{
            .epoch = 1,
            .hash = "d2303cb82f62ccf70f7a0309df9009fb81f899dc13e4a8a32430ccae6bfceff6",
        },
    };
    for (ledger[1..], ledger[0 .. ledger.len - 1]) |entry, earlier| {
        try testing.expect(entry.epoch > earlier.epoch);
    }
    const last = ledger[ledger.len - 1];
    try testing.expectEqual(format_digest.format_epoch, last.epoch);
    try testing.expectEqualStrings(last.hash, &format_digest.hex(&hash));
}

test "format: the export file" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    var writer = try export_file.WriterType(std.ArrayList(u8).Writer).init(out.writer(), 1);

    var value: [nerva.value_size]u8 = @splat(0);
    value[0] = 0xaa;
    value[79] = 0x55;
    try writer.write(&.{ .change = .{
        .table = 5,
        .id = 7,
        .op = 3,
        .timestamp = 1_700_000_000_000_000_000,
        .kind = .put,
        .value = value,
    } });
    try writer.write(&.{ .change = .{
        .table = 0xFFFF_0001,
        .id = std.math.maxInt(u64),
        .op = 4,
        .timestamp = 1_700_000_000_000_000_009,
        .kind = .delete,
        .value = @splat(0),
    } });
    var name: [32]u8 = @splat(0);
    @memcpy(name[0..7], "revenue");
    try writer.write(&.{ .view = .{ .name = name, .id = 1, .declared_op = 2 } });
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = 9;
    definition.field_count = 2;
    definition.fields[0] = .{ .table = 7, .offset = 0, .flags = .{ .floor = true }, .floor = -1 };
    definition.fields[1] = .{ .table = 7, .offset = 8, .flags = .{}, .floor = 0 };
    try writer.write(&.{ .ledger = .{ .op = 4, .definition = definition } });
    try writer.write(&.{ .check_view = .{
        .id = 1,
        .state = .ready,
        .group_count = 3,
        .hash = @splat(0x11),
    } });
    try writer.write(&.{ .check_ledger = .{ .id = 9, .total = -5 } });
    try writer.write(&.{ .check_table = .{
        .table = 5,
        .row_count = 1,
        .rows_hash = @splat(0x22),
    } });
    try writer.write(&.{ .summary = .{
        .as_of = 4,
        .change_count = 2,
        .view_count = 1,
        .ledger_count = 1,
        .table_count = 1,
    } });
    try writer.finish();

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
    try snap(@src(),
        \\size: 800
        \\header and first record: 4e4552564145585001000000000000006d00000001000000050000000700000000000000030000000000000000002a36fe9c971701aa000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000558a95ff8a
        \\sha256: cabcdbdf6d9006b821ad049c7e974460ac0f39573518b09b488e005fb2a8a5b3
        \\
    ).diff_fmt("size: {}\nheader and first record: {s}\nsha256: {s}\n", .{
        out.items.len,
        std.fmt.fmtSliceHexLower(out.items[0 .. export_file.header_size + 8 + 109 + 4]),
        std.fmt.fmtSliceHexLower(&digest),
    });
}
