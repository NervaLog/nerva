//! `nerva backup` and `nerva restore` (docs/briefs/r5.md, P149): a backup is an export and a
//! manifest beside it. The manifest records what the export must check out as, kept apart from
//! the export so that a damaged or swapped export is caught by a record it did not carry.
//!
//! The manifest is JSON of one canonical form, version 1, at most `manifest_size_max`:
//!
//! ```
//! {"format":"nerva-backup","version":1,"release":"0.0.6","cluster":"0","op":"1234",
//!  "export_sha256":"…","export_size":"128838400","export_version":2,
//!  "views":[{"name":"revenue","id":1,"state":"ready","view_hash":"…","groups":"12"}],
//!  "ledgers":[{"id":1,"total":"0"}]}
//! ```
//!
//! (one line, no spaces, a newline at the end). 64-bit and wider numbers are decimal strings, as
//! in the JSON API; a number has no sign (except a ledger's total), no plus and no leading zero.
//! The parser accepts exactly what `render` writes and nothing else: two spellings of one number
//! or one hash are one thing, and a flipped byte is either refused or reads as another manifest
//! that the comparison with the export then refuses.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");
const catalog = @import("catalog.zig");
const export_file = @import("export_file.zig");
const import_ = @import("import.zig");

pub const manifest_version: u32 = 1;
/// A manifest is read whole.
pub const manifest_size_max = 64 * 1024;
/// The longest release string.
pub const release_size_max = 32;
/// The suffix of the manifest's path beside the backup.
pub const manifest_suffix = ".manifest.json";

/// All of these are NRV-E0808.
pub const Error = error{
    /// Not a manifest `render` could have written.
    Malformed,
    /// More than `manifest_size_max` bytes.
    TooLarge,
    /// A well-formed start that names a version this release does not read.
    UnknownVersion,
};

pub const View = struct {
    /// Zero-padded.
    name: [32]u8,
    id: u64,
    state: nerva.ViewState,
    hash: [32]u8,
    groups: u64,
};

pub const Ledger = struct {
    id: u32,
    total: i128,
};

pub const Manifest = struct {
    release: [release_size_max]u8,
    release_len: u8,
    cluster: u128,
    op: u64,
    export_sha256: [32]u8,
    export_size: u64,
    export_version: u32,
    view_count: u32,
    views: [nerva.views_max]View,
    ledger_count: u32,
    ledgers: [nerva.ledgers_max]Ledger,

    pub fn release_slice(manifest: *const Manifest) []const u8 {
        return manifest.release[0..manifest.release_len];
    }

    pub fn view_slice(manifest: *const Manifest) []const View {
        return manifest.views[0..manifest.view_count];
    }

    pub fn ledger_slice(manifest: *const Manifest) []const Ledger {
        return manifest.ledgers[0..manifest.ledger_count];
    }
};

/// What a verified export (pass 1) says, as a manifest. `export_size` is the export file's.
pub fn from_plan(
    plan: *const import_.Plan,
    release: []const u8,
    cluster: u128,
    export_size: u64,
) Manifest {
    assert(release.len >= 1 and release.len <= release_size_max);
    const summary = &plan.summary;
    var manifest: Manifest = undefined;
    manifest.release = @splat(0);
    @memcpy(manifest.release[0..release.len], release);
    manifest.release_len = @intCast(release.len);
    manifest.cluster = cluster;
    manifest.op = summary.as_of;
    manifest.export_sha256 = plan.origin;
    manifest.export_size = export_size;
    manifest.export_version = plan.version;
    manifest.view_count = summary.view_count;
    for (plan.view_slice(), plan.checks_view[0..summary.view_count], 0..) |*view, *check, index| {
        manifest.views[index] = .{
            .name = view.record.name,
            .id = view.record.id,
            .state = check.state,
            .hash = check.hash,
            .groups = check.group_count,
        };
    }
    manifest.ledger_count = summary.ledger_count;
    for (plan.checks_ledger[0..summary.ledger_count], 0..) |*check, index| {
        manifest.ledgers[index] = .{ .id = check.id, .total = check.total };
    }
    return manifest;
}

/// The longest line a view or a ledger takes, and the rest, from the widest value of each field.
const view_size_max = len("{\"name\":\"") + 32 + len("\",\"id\":") + 20 + len(",\"state\":\"") +
    len("building") + len("\",\"view_hash\":\"") + 64 + len("\",\"groups\":\"") + 20 +
    len("\"},");
const ledger_size_max = len("{\"id\":") + 10 + len(",\"total\":\"") + 40 + len("\"},");
const fixed_size_max = len("{\"format\":\"nerva-backup\",\"version\":") + 10 +
    len(",\"release\":\"") + release_size_max + len("\",\"cluster\":\"") + 39 +
    len("\",\"op\":\"") + 20 + len("\",\"export_sha256\":\"") + 64 +
    len("\",\"export_size\":\"") + 20 + len("\",\"export_version\":") + 10 +
    len(",\"views\":[") + len("],\"ledgers\":[") + len("]}\n");
comptime {
    assert(fixed_size_max + nerva.views_max * view_size_max +
        nerva.ledgers_max * ledger_size_max <= manifest_size_max);
}

fn len(comptime text: []const u8) usize {
    return text.len;
}

/// Writes `manifest` to `buffer`; returns the bytes.
pub fn render(manifest: *const Manifest, buffer: *[manifest_size_max]u8) []const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    // The buffer holds the widest manifest (comptime assert above), so a write cannot fail.
    render_to(manifest, writer) catch unreachable;
    return stream.getWritten();
}

fn render_to(manifest: *const Manifest, writer: anytype) !void {
    assert(manifest.release_len >= 1);
    assert(manifest.view_count <= nerva.views_max);
    assert(manifest.ledger_count <= nerva.ledgers_max);
    try writer.print("{{\"format\":\"nerva-backup\",\"version\":{},\"release\":\"{s}\"," ++
        "\"cluster\":\"{}\",\"op\":\"{}\",\"export_sha256\":\"{}\",\"export_size\":\"{}\"," ++
        "\"export_version\":{},\"views\":[", .{
        manifest_version,
        manifest.release_slice(),
        manifest.cluster,
        manifest.op,
        std.fmt.fmtSliceHexLower(&manifest.export_sha256),
        manifest.export_size,
        manifest.export_version,
    });
    for (manifest.view_slice(), 0..) |*view, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"id\":{},\"state\":\"{s}\"," ++
            "\"view_hash\":\"{}\",\"groups\":\"{}\"}}", .{
            std.mem.sliceTo(&view.name, 0),
            view.id,
            @tagName(view.state),
            std.fmt.fmtSliceHexLower(&view.hash),
            view.groups,
        });
    }
    try writer.writeAll("],\"ledgers\":[");
    for (manifest.ledger_slice(), 0..) |*ledger, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{},\"total\":\"{}\"}}", .{ ledger.id, ledger.total });
    }
    try writer.writeAll("]}\n");
}

/// Reads a manifest `render` could have written; anything else is an error. `manifest` is
/// written only through the counts it reads, and is undefined after an error.
pub fn parse(bytes: []const u8, manifest: *Manifest) Error!void {
    if (bytes.len > manifest_size_max) return error.TooLarge;
    var parser: Parser = .{ .bytes = bytes };
    try parser.literal("{\"format\":\"nerva-backup\",\"version\":");
    const version = try parser.unsigned(u32);
    if (version != manifest_version) return error.UnknownVersion;
    try parser.literal(",\"release\":\"");
    manifest.release = @splat(0);
    manifest.release_len = try parser.release(&manifest.release);
    try parser.literal("\",\"cluster\":");
    manifest.cluster = try parser.quoted(u128);
    try parser.literal(",\"op\":");
    manifest.op = try parser.quoted(u64);
    if (manifest.op == 0) return error.Malformed;
    try parser.literal(",\"export_sha256\":\"");
    manifest.export_sha256 = try parser.hex32();
    try parser.literal("\",\"export_size\":");
    manifest.export_size = try parser.quoted(u64);
    if (manifest.export_size == 0) return error.Malformed;
    try parser.literal(",\"export_version\":");
    manifest.export_version = try parser.unsigned(u32);
    if (manifest.export_version < 1 or manifest.export_version > export_file.format_version_max) {
        return error.Malformed;
    }
    try parser.literal(",\"views\":[");
    manifest.view_count = 0;
    while (!parser.peek(']')) {
        if (manifest.view_count > 0) try parser.literal(",");
        if (manifest.view_count == nerva.views_max) return error.Malformed;
        const view = &manifest.views[manifest.view_count];
        try parser.literal("{\"name\":\"");
        view.name = try parser.view_name();
        try parser.literal("\",\"id\":");
        view.id = try parser.unsigned(u64);
        // Ids follow declaration order (import's pass 1 asserts the same).
        if (view.id != manifest.view_count + 1) return error.Malformed;
        try parser.literal(",\"state\":\"");
        view.state = try parser.view_state();
        try parser.literal("\",\"view_hash\":\"");
        view.hash = try parser.hex32();
        try parser.literal("\",\"groups\":");
        view.groups = try parser.quoted(u64);
        try parser.literal("}");
        manifest.view_count += 1;
    }
    try parser.literal("],\"ledgers\":[");
    manifest.ledger_count = 0;
    while (!parser.peek(']')) {
        if (manifest.ledger_count > 0) try parser.literal(",");
        if (manifest.ledger_count == nerva.ledgers_max) return error.Malformed;
        const ledger = &manifest.ledgers[manifest.ledger_count];
        try parser.literal("{\"id\":");
        ledger.id = try parser.unsigned(u32);
        try parser.literal(",\"total\":");
        ledger.total = try parser.quoted_signed();
        try parser.literal("}");
        manifest.ledger_count += 1;
    }
    try parser.literal("]}\n");
    if (parser.pos != bytes.len) return error.Malformed;
}

const Parser = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn literal(parser: *Parser, comptime text: []const u8) Error!void {
        if (!std.mem.startsWith(u8, parser.bytes[parser.pos..], text)) return error.Malformed;
        parser.pos += text.len;
    }

    fn peek(parser: *const Parser, byte: u8) bool {
        return parser.pos < parser.bytes.len and parser.bytes[parser.pos] == byte;
    }

    /// A run of digits with no leading zero (a lone `0` is fine).
    fn digits(parser: *Parser) Error![]const u8 {
        const start = parser.pos;
        while (parser.pos < parser.bytes.len and std.ascii.isDigit(parser.bytes[parser.pos])) {
            parser.pos += 1;
        }
        const text = parser.bytes[start..parser.pos];
        if (text.len == 0 or text.len > 39) return error.Malformed;
        if (text.len > 1 and text[0] == '0') return error.Malformed;
        return text;
    }

    fn unsigned(parser: *Parser, comptime T: type) Error!T {
        return std.fmt.parseInt(T, try parser.digits(), 10) catch error.Malformed;
    }

    /// A decimal string: `"123"`.
    fn quoted(parser: *Parser, comptime T: type) Error!T {
        try parser.literal("\"");
        const value = try parser.unsigned(T);
        try parser.literal("\"");
        return value;
    }

    /// A decimal string with an optional minus sign, never `-0`.
    fn quoted_signed(parser: *Parser) Error!i128 {
        try parser.literal("\"");
        const start = parser.pos;
        const negative = parser.peek('-');
        if (negative) parser.pos += 1;
        const text = try parser.digits();
        if (negative and std.mem.eql(u8, text, "0")) return error.Malformed;
        const value = std.fmt.parseInt(i128, parser.bytes[start..parser.pos], 10) catch
            return error.Malformed;
        try parser.literal("\"");
        return value;
    }

    /// 64 lowercase hex digits; the closing quote is the caller's.
    fn hex32(parser: *Parser) Error![32]u8 {
        if (parser.bytes.len - parser.pos < 64) return error.Malformed;
        const text = parser.bytes[parser.pos..][0..64];
        for (text) |c| {
            if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.Malformed;
        }
        var result: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&result, text) catch return error.Malformed;
        parser.pos += 64;
        return result;
    }

    /// Up to the closing quote (the caller's): letters, digits, `.`, `+` and `-`.
    fn release(parser: *Parser, out: *[release_size_max]u8) Error!u8 {
        const start = parser.pos;
        while (parser.pos < parser.bytes.len and parser.bytes[parser.pos] != '"') {
            const c = parser.bytes[parser.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '+' and c != '-') {
                return error.Malformed;
            }
            parser.pos += 1;
        }
        const text = parser.bytes[start..parser.pos];
        if (text.len == 0 or text.len > release_size_max) return error.Malformed;
        @memcpy(out[0..text.len], text);
        return @intCast(text.len);
    }

    fn view_name(parser: *Parser) Error![32]u8 {
        const start = parser.pos;
        while (parser.pos < parser.bytes.len and parser.bytes[parser.pos] != '"') parser.pos += 1;
        const text = parser.bytes[start..parser.pos];
        catalog.view_name_validate(text) catch return error.Malformed;
        var result: [32]u8 = @splat(0);
        @memcpy(result[0..text.len], text);
        return result;
    }

    fn view_state(parser: *Parser) Error!nerva.ViewState {
        const start = parser.pos;
        while (parser.pos < parser.bytes.len and parser.bytes[parser.pos] != '"') parser.pos += 1;
        const state = std.meta.stringToEnum(nerva.ViewState, parser.bytes[start..parser.pos]) orelse
            return error.Malformed;
        if (state == .missing) return error.Malformed;
        return state;
    }
};

/// The first way `actual` (what the export says) differs from `expected` (the manifest), as a
/// sentence for NRV-E0809, or null if every compared value is equal. The release and the cluster
/// are not compared: a restore drill goes into another cluster, and a backup outlives its release.
pub fn first_difference(
    buffer: []u8,
    expected: *const Manifest,
    actual: *const Manifest,
) ?[]const u8 {
    if (expected.export_size != actual.export_size) return std.fmt.bufPrint(
        buffer,
        "the backup is {} bytes; the manifest says {}",
        .{ actual.export_size, expected.export_size },
    ) catch buffer;
    if (!std.mem.eql(u8, &expected.export_sha256, &actual.export_sha256)) return std.fmt.bufPrint(
        buffer,
        "the backup's SHA-256 is {}; the manifest says {}",
        .{
            std.fmt.fmtSliceHexLower(&actual.export_sha256),
            std.fmt.fmtSliceHexLower(&expected.export_sha256),
        },
    ) catch buffer;
    if (expected.op != actual.op) return std.fmt.bufPrint(
        buffer,
        "the backup is as of op {}; the manifest says op {}",
        .{ actual.op, expected.op },
    ) catch buffer;
    if (expected.export_version != actual.export_version) return std.fmt.bufPrint(
        buffer,
        "the backup is export version {}; the manifest says {}",
        .{ actual.export_version, expected.export_version },
    ) catch buffer;
    if (expected.view_count != actual.view_count) return std.fmt.bufPrint(
        buffer,
        "the backup declares {} views; the manifest says {}",
        .{ actual.view_count, expected.view_count },
    ) catch buffer;
    for (expected.view_slice(), actual.view_slice()) |*want, *got| {
        const name = std.mem.sliceTo(&got.name, 0);
        if (!std.mem.eql(u8, &want.name, &got.name) or want.id != got.id) return std.fmt.bufPrint(
            buffer,
            "view {} is {s} in the backup; the manifest says {s}",
            .{ got.id, name, std.mem.sliceTo(&want.name, 0) },
        ) catch buffer;
        if (want.state != got.state) return std.fmt.bufPrint(
            buffer,
            "view {s} is {s} in the backup; the manifest says {s}",
            .{ name, @tagName(got.state), @tagName(want.state) },
        ) catch buffer;
        if (!std.mem.eql(u8, &want.hash, &got.hash)) return std.fmt.bufPrint(
            buffer,
            "view {s}'s hash is {} in the backup; the manifest says {}",
            .{ name, std.fmt.fmtSliceHexLower(&got.hash), std.fmt.fmtSliceHexLower(&want.hash) },
        ) catch buffer;
        if (want.groups != got.groups) return std.fmt.bufPrint(
            buffer,
            "view {s} has {} groups in the backup; the manifest says {}",
            .{ name, got.groups, want.groups },
        ) catch buffer;
    }
    if (expected.ledger_count != actual.ledger_count) return std.fmt.bufPrint(
        buffer,
        "the backup declares {} ledgers; the manifest says {}",
        .{ actual.ledger_count, expected.ledger_count },
    ) catch buffer;
    for (expected.ledger_slice(), actual.ledger_slice()) |*want, *got| {
        if (want.id != got.id) return std.fmt.bufPrint(
            buffer,
            "ledger {} in the backup is ledger {} in the manifest",
            .{ got.id, want.id },
        ) catch buffer;
        if (want.total != got.total) return std.fmt.bufPrint(
            buffer,
            "ledger {}'s total is {} in the backup; the manifest says {}",
            .{ got.id, got.total, want.total },
        ) catch buffer;
    }
    return null;
}

/// `3 views and 1 ledger`, for the line `restore` prints.
pub fn counts_text(buffer: []u8, manifest: *const Manifest) []const u8 {
    return std.fmt.bufPrint(buffer, "{} view{s} and {} ledger{s}", .{
        manifest.view_count,
        if (manifest.view_count == 1) "" else "s",
        manifest.ledger_count,
        if (manifest.ledger_count == 1) "" else "s",
    }) catch buffer;
}

const testing = std.testing;

fn name_of(text: []const u8) [32]u8 {
    var result: [32]u8 = @splat(0);
    @memcpy(result[0..text.len], text);
    return result;
}

fn sample() Manifest {
    var manifest: Manifest = undefined;
    manifest.release = @splat(0);
    @memcpy(manifest.release[0..5], "0.0.6");
    manifest.release_len = 5;
    manifest.cluster = 7;
    manifest.op = 1234;
    manifest.export_sha256 = @splat(0xAB);
    manifest.export_size = 128838400;
    manifest.export_version = 2;
    manifest.view_count = 2;
    manifest.views[0] = .{
        .name = name_of("revenue"),
        .id = 1,
        .state = .ready,
        .hash = @splat(0x12),
        .groups = 12,
    };
    manifest.views[1] = .{
        .name = name_of("late_2"),
        .id = 2,
        .state = .building,
        .hash = @splat(0xFE),
        .groups = 0,
    };
    manifest.ledger_count = 2;
    manifest.ledgers[0] = .{ .id = 1, .total = 0 };
    manifest.ledgers[1] = .{ .id = 2, .total = -5 };
    return manifest;
}

/// A manifest filled with a known byte, so that parse is seen to write what it reads.
fn poisoned() Manifest {
    var manifest: Manifest = undefined;
    @memset(std.mem.asBytes(&manifest), 0xAA);
    return manifest;
}

test "backup: manifest round trip" {
    const manifest = sample();
    var buffer: [manifest_size_max]u8 = undefined;
    const bytes = render(&manifest, &buffer);
    try testing.expectEqualStrings(
        "{\"format\":\"nerva-backup\",\"version\":1,\"release\":\"0.0.6\",\"cluster\":\"7\"," ++
            "\"op\":\"1234\",\"export_sha256\":\"" ++ "ab" ** 32 ++
            "\",\"export_size\":\"128838400\",\"export_version\":2,\"views\":[" ++
            "{\"name\":\"revenue\",\"id\":1,\"state\":\"ready\",\"view_hash\":\"" ++ "12" ** 32 ++
            "\",\"groups\":\"12\"},{\"name\":\"late_2\",\"id\":2,\"state\":\"building\"," ++
            "\"view_hash\":\"" ++ "fe" ** 32 ++ "\",\"groups\":\"0\"}]," ++
            "\"ledgers\":[{\"id\":1,\"total\":\"0\"},{\"id\":2,\"total\":\"-5\"}]}\n",
        bytes,
    );
    var parsed = poisoned();
    try parse(bytes, &parsed);
    var buffer_again: [manifest_size_max]u8 = undefined;
    try testing.expectEqualStrings(bytes, render(&parsed, &buffer_again));
    var difference: [256]u8 = undefined;
    try testing.expect(first_difference(&difference, &manifest, &parsed) == null);
    try testing.expectEqualStrings("0.0.6", parsed.release_slice());
    try testing.expectEqual(@as(u128, 7), parsed.cluster);
}

test "backup: an empty manifest (no views, no ledgers) round trips" {
    var manifest = sample();
    manifest.view_count = 0;
    manifest.ledger_count = 0;
    var buffer: [manifest_size_max]u8 = undefined;
    const bytes = render(&manifest, &buffer);
    var parsed = poisoned();
    try parse(bytes, &parsed);
    try testing.expectEqual(@as(u32, 0), parsed.view_count);
    try testing.expectEqual(@as(u32, 0), parsed.ledger_count);
}

test "backup: every flipped bit is refused or reads as another manifest, every truncation is refused" {
    const manifest = sample();
    var buffer: [manifest_size_max]u8 = undefined;
    const original = render(&manifest, &buffer);
    var copy: [manifest_size_max]u8 = undefined;
    var buffer_again: [manifest_size_max]u8 = undefined;
    for (0..original.len) |index| {
        for (0..8) |bit| {
            @memcpy(copy[0..original.len], original);
            copy[index] ^= @as(u8, 1) << @intCast(bit);
            const flipped = copy[0..original.len];
            var parsed = poisoned();
            parse(flipped, &parsed) catch continue;
            // Accepted: it is canonical (it renders to the same bytes), so it is another
            // manifest, which the comparison with the export refuses.
            try testing.expectEqualStrings(flipped, render(&parsed, &buffer_again));
        }
        var parsed = poisoned();
        try testing.expectError(error.Malformed, parse(original[0..index], &parsed));
    }
    var parsed = poisoned();
    try testing.expectError(error.Malformed, parse(original[0..0], &parsed));
    try testing.expectError(
        error.Malformed,
        parse(original[0 .. original.len - 1], &parsed),
    );
    // Bytes after the newline.
    @memcpy(copy[0..original.len], original);
    copy[original.len] = '\n';
    try testing.expectError(error.Malformed, parse(copy[0 .. original.len + 1], &parsed));
}

/// The widest manifest text, with `views` views and `ledgers` ledgers.
fn text_widest(allocator: std.mem.Allocator, views: u32, ledgers: u32) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    const writer = out.writer();
    try writer.print("{{\"format\":\"nerva-backup\",\"version\":1,\"release\":\"{s}\"," ++
        "\"cluster\":\"{}\",\"op\":\"{}\",\"export_sha256\":\"{s}\",\"export_size\":\"{}\"," ++
        "\"export_version\":2,\"views\":[", .{
        "a" ** release_size_max,
        std.math.maxInt(u128),
        std.math.maxInt(u64),
        "f" ** 64,
        std.math.maxInt(u64),
    });
    for (0..views) |index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"id\":{},\"state\":\"building\"," ++
            "\"view_hash\":\"{s}\",\"groups\":\"{}\"}}", .{
            "n" ** 32,
            index + 1,
            "f" ** 64,
            std.math.maxInt(u64),
        });
    }
    try writer.writeAll("],\"ledgers\":[");
    for (0..ledgers) |index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{},\"total\":\"{}\"}}", .{
            std.math.maxInt(u32),
            std.math.minInt(i128),
        });
    }
    try writer.writeAll("]}\n");
    return out.toOwnedSlice();
}

test "backup: 64 views and 64 ledgers at their widest fit manifest_size_max; 65 are refused" {
    const text = try text_widest(testing.allocator, nerva.views_max, nerva.ledgers_max);
    defer testing.allocator.free(text);
    try testing.expect(text.len <= manifest_size_max);
    var parsed = poisoned();
    try parse(text, &parsed);
    try testing.expectEqual(@as(u32, nerva.views_max), parsed.view_count);
    try testing.expectEqual(@as(u32, nerva.ledgers_max), parsed.ledger_count);
    var buffer: [manifest_size_max]u8 = undefined;
    try testing.expectEqualStrings(text, render(&parsed, &buffer));

    const views_over = try text_widest(testing.allocator, nerva.views_max + 1, 0);
    defer testing.allocator.free(views_over);
    try testing.expectError(error.Malformed, parse(views_over, &parsed));
    const ledgers_over = try text_widest(testing.allocator, 0, nerva.ledgers_max + 1);
    defer testing.allocator.free(ledgers_over);
    try testing.expectError(error.Malformed, parse(ledgers_over, &parsed));
}

test "backup: manifest_size_max bytes are read, one more is too large" {
    var parsed = poisoned();
    const at = try testing.allocator.alloc(u8, manifest_size_max);
    defer testing.allocator.free(at);
    @memset(at, ' ');
    // At the bound: read, and found not to be a manifest.
    try testing.expectError(error.Malformed, parse(at, &parsed));
    const past = try testing.allocator.alloc(u8, manifest_size_max + 1);
    defer testing.allocator.free(past);
    @memset(past, ' ');
    try testing.expectError(error.TooLarge, parse(past, &parsed));
}

/// `original` with the first `from` replaced by `to`.
fn replaced(
    allocator: std.mem.Allocator,
    original: []const u8,
    from: []const u8,
    to: []const u8,
) ![]u8 {
    const at = std.mem.indexOf(u8, original, from).?;
    return std.mem.concat(allocator, u8, &.{ original[0..at], to, original[at + from.len ..] });
}

test "backup: an unknown version is its own refusal, after the start is well formed" {
    var buffer: [manifest_size_max]u8 = undefined;
    const original = render(&sample(), &buffer);
    var parsed = poisoned();
    const unknown = [_][]const u8{ "2", "0", "4294967295" };
    const malformed = [_][]const u8{ "01", "-1", "+1", "1.0", "\"1\"", "", "4294967296" };
    for (unknown ++ malformed, 0..) |version, index| {
        const to = try std.fmt.allocPrint(testing.allocator, "\"version\":{s}", .{version});
        defer testing.allocator.free(to);
        const text = try replaced(testing.allocator, original, "\"version\":1", to);
        defer testing.allocator.free(text);
        try testing.expectError(
            if (index < unknown.len) error.UnknownVersion else error.Malformed,
            parse(text, &parsed),
        );
    }
}

test "backup: two spellings of one number are one: only the canonical one is read" {
    var buffer: [manifest_size_max]u8 = undefined;
    const original = render(&sample(), &buffer);
    var parsed = poisoned();
    const cases = [_][2][]const u8{
        .{ "\"op\":\"1234\"", "\"op\":\"01234\"" },
        .{ "\"op\":\"1234\"", "\"op\":\"0012\"" },
        .{ "\"op\":\"1234\"", "\"op\":\"+1234\"" },
        .{ "\"op\":\"1234\"", "\"op\":1234" },
        .{ "\"op\":\"1234\"", "\"op\":\"0\"" },
        .{ "\"cluster\":\"7\"", "\"cluster\":\"07\"" },
        .{ "\"export_size\":\"128838400\"", "\"export_size\":\"0128838400\"" },
        .{ "\"export_version\":2", "\"export_version\":02" },
        .{ "\"id\":1,\"state\"", "\"id\":01,\"state\"" },
        .{ "\"groups\":\"12\"", "\"groups\":\"012\"" },
        .{ "\"groups\":\"12\"", "\"groups\":\"\"" },
        .{ "\"total\":\"-5\"", "\"total\":\"-05\"" },
        .{ "\"total\":\"-5\"", "\"total\":\"+5\"" },
        .{ "\"total\":\"0\"", "\"total\":\"-0\"" },
        .{ "\"total\":\"-5\"", "\"total\":\"-\"" },
        .{ "\"groups\":\"12\"", "\"groups\":\"18446744073709551616\"" },
        .{ "\"total\":\"-5\"", "\"total\":\"170141183460469231731687303715884105728\"" },
    };
    for (cases) |case| {
        const text = try replaced(testing.allocator, original, case[0], case[1]);
        defer testing.allocator.free(text);
        try testing.expectError(error.Malformed, parse(text, &parsed));
    }
}

test "backup: only canonical hashes, names, states and releases are read" {
    var buffer: [manifest_size_max]u8 = undefined;
    const original = render(&sample(), &buffer);
    var parsed = poisoned();
    const cases = [_][2][]const u8{
        .{ "\"export_sha256\":\"" ++ "ab" ** 32, "\"export_sha256\":\"" ++ "AB" ** 32 },
        .{ "\"export_sha256\":\"" ++ "ab" ** 32, "\"export_sha256\":\"" ++ "ab" ** 31 },
        .{ "\"export_sha256\":\"" ++ "ab" ** 32, "\"export_sha256\":\"" ++ "ab" ** 31 ++ "zz" },
        .{ "\"name\":\"revenue\"", "\"name\":\"Revenue\"" },
        .{ "\"name\":\"revenue\"", "\"name\":\"\"" },
        .{ "\"name\":\"revenue\"", "\"name\":\"rev\\u0065nue\"" },
        .{ "\"name\":\"revenue\"", "\"name\":\"" ++ "a" ** 33 ++ "\"" },
        .{ "\"state\":\"ready\"", "\"state\":\"missing\"" },
        .{ "\"state\":\"ready\"", "\"state\":\"Ready\"" },
        .{ "\"id\":2,\"state\"", "\"id\":3,\"state\"" },
        .{ "\"release\":\"0.0.6\"", "\"release\":\"\"" },
        .{ "\"release\":\"0.0.6\"", "\"release\":\"0.0 6\"" },
        .{ "\"release\":\"0.0.6\"", "\"release\":\"" ++ "a" ** 33 ++ "\"" },
        .{ "{\"format\":\"nerva-backup\"", "{ \"format\":\"nerva-backup\"" },
        .{ "\"views\":[", "\"views\": [" },
    };
    for (cases) |case| {
        const text = try replaced(testing.allocator, original, case[0], case[1]);
        defer testing.allocator.free(text);
        try testing.expectError(error.Malformed, parse(text, &parsed));
    }
}

test "backup: first_difference names the first value that differs" {
    const expected = sample();
    var difference: [256]u8 = undefined;
    try testing.expect(first_difference(&difference, &expected, &expected) == null);

    var actual = expected;
    actual.cluster = 99; // Not compared: a drill restores into another cluster.
    actual.release_len = 3;
    try testing.expect(first_difference(&difference, &expected, &actual) == null);

    actual = expected;
    actual.export_size += 1;
    try testing.expectEqualStrings(
        "the backup is 128838401 bytes; the manifest says 128838400",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.export_sha256[31] ^= 1;
    try testing.expect(std.mem.startsWith(
        u8,
        first_difference(&difference, &expected, &actual).?,
        "the backup's SHA-256 is ",
    ));
    actual = expected;
    actual.op += 1;
    try testing.expectEqualStrings(
        "the backup is as of op 1235; the manifest says op 1234",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.export_version = 1;
    try testing.expectEqualStrings(
        "the backup is export version 1; the manifest says 2",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.view_count = 1;
    try testing.expectEqualStrings(
        "the backup declares 1 views; the manifest says 2",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.views[1].hash[0] ^= 1;
    try testing.expect(std.mem.startsWith(
        u8,
        first_difference(&difference, &expected, &actual).?,
        "view late_2's hash is ",
    ));
    actual = expected;
    actual.views[0].groups += 1;
    try testing.expectEqualStrings(
        "view revenue has 13 groups in the backup; the manifest says 12",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.views[0].state = .failed;
    try testing.expectEqualStrings(
        "view revenue is failed in the backup; the manifest says ready",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.ledgers[1].total = 0;
    try testing.expectEqualStrings(
        "ledger 2's total is 0 in the backup; the manifest says -5",
        first_difference(&difference, &expected, &actual).?,
    );
    actual = expected;
    actual.ledger_count = 0;
    try testing.expectEqualStrings(
        "the backup declares 0 ledgers; the manifest says 2",
        first_difference(&difference, &expected, &actual).?,
    );
}

test "backup: counts_text" {
    var manifest = sample();
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("2 views and 2 ledgers", counts_text(&buffer, &manifest));
    manifest.view_count = 1;
    manifest.ledger_count = 1;
    try testing.expectEqualStrings("1 view and 1 ledger", counts_text(&buffer, &manifest));
    manifest.view_count = 0;
    manifest.ledger_count = 0;
    try testing.expectEqualStrings("0 views and 0 ledgers", counts_text(&buffer, &manifest));
}
