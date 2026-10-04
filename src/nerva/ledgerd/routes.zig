//! The Botpike runtime's ledger protocol: route logic.
//!
//! A port of `ledgerd.py` (Botpike/runtime, `ledger/ledgerd.py`; oracle copy in
//! `tests/ledgerd/ledgerd_reference.py`). Every rule, reply line and journal line follows that
//! file; see docs/DECISIONS.md N6–N17 for where and why the storage differs.
//!
//! Routes run against a `store` with four methods, so the same logic runs against an in-memory
//! map (tests) and a Nerva transaction (`store.zig`):
//!
//!     get(key: []const u8) !?[]const u8     // The value, or null.
//!     put(key: []const u8, value: []const u8) !void
//!     remove(key: []const u8) !void
//!     reset() !void                          // Forget every key (`/v1/admin/init`).
//!     unique() u128                          // An id never returned before (journal keys).

const std = @import("std");
const assert = std.debug.assert;

/// The same limits as `amount.max` and `amount.totalMax` in the runtime.
pub const amount_max: u64 = 1_000_000_000_000_000; // 10^15
pub const total_max: u64 = 1 << 62;

/// Keys listed by `/v1/status`.
const state_prefixes = [_][]const u8{ "seq.", "hold.", "resuming.", "blocked." };
const state_index_key = "index.state";

pub const Fields = std.StringHashMapUnmanaged([]const u8);

/// A route's writes are kept even when it answers 400: `ledgerd.py` persists at fixed points,
/// and a request that fails after one (a bad memo after `count_denial`) keeps that write.
/// Routes therefore compute every checked value before writing (N18).
pub const Reply = struct {
    status: u16,
    /// The reply body: lines joined with `\n`, no trailing newline.
    body: []const u8,
};

pub const Error = error{OutOfMemory} || error{
    /// A missing field, a malformed number or hex string, or an amount out of range: 400.
    BadRequest,
};

/// Parses a request body: `key=value` lines; a later key wins; lines without `=` are ignored.
pub fn fields_parse(arena: std.mem.Allocator, body: []const u8) Error!Fields {
    var fields: Fields = .{};
    var start: usize = 0;
    var index: usize = 0;
    while (index <= body.len) : (index += 1) {
        const end_of_line = index == body.len or body[index] == '\n' or body[index] == '\r';
        if (!end_of_line) continue;
        const line = body[start..index];
        if (std.mem.indexOfScalar(u8, line, '=')) |equals| {
            try fields.put(arena, line[0..equals], line[equals + 1 ..]);
        }
        // `\r\n` is one line break.
        if (index < body.len and body[index] == '\r' and index + 1 < body.len and
            body[index + 1] == '\n') index += 1;
        start = index + 1;
    }
    return fields;
}

/// Runs one route. Returns null for an unknown route (404). Store errors propagate: the caller
/// retries on conflict.
pub fn handle(
    arena: std.mem.Allocator,
    store: anytype,
    route: []const u8,
    fields: *const Fields,
) !?Reply {
    var context: Context(@TypeOf(store)) = .{ .arena = arena, .store = store, .fields = fields };
    const known = context.route(route) catch |err| switch (err) {
        error.BadRequest => return .{
            .status = 400,
            .body = try std.fmt.allocPrint(arena, "error=bad request: {s}", .{context.bad_request}),
        },
        else => |e| return e,
    };
    if (!known) return null;

    var body = std.ArrayList(u8).init(arena);
    for (context.out.items) |line| {
        try body.appendSlice(line);
        try body.append('\n');
    }
    for (context.said.items) |line| {
        try body.appendSlice("line_hex=");
        try hex_encode(body.writer(), line);
        try body.append('\n');
    }
    try body.appendSlice("ok=true");
    return .{ .status = 200, .body = body.items };
}

fn Context(comptime Store: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        store: Store,
        fields: *const Fields,
        out: std.ArrayListUnmanaged([]const u8) = .{},
        said: std.ArrayListUnmanaged([]const u8) = .{},
        bad_request: []const u8 = "",

        fn route(c: *Self, route_name: []const u8) !bool {
            const eql = std.mem.eql;
            if (eql(u8, route_name, "/v1/available")) {
                try c.reply("available={}", .{try c.nat("available")});
            } else if (eql(u8, route_name, "/v1/summary")) {
                try c.reply("summary={s}", .{try c.summary()});
            } else if (eql(u8, route_name, "/v1/status")) {
                try c.reply("summary={s}", .{try c.summary()});
                try c.state_lines();
            } else if (eql(u8, route_name, "/v1/note")) {
                try c.journal("{s}", .{try c.unhex("text_hex")});
            } else if (eql(u8, route_name, "/v1/refused")) {
                try c.refused();
            } else if (eql(u8, route_name, "/v1/reserve")) {
                try c.reserve();
            } else if (eql(u8, route_name, "/v1/settle")) {
                try c.settle();
            } else if (eql(u8, route_name, "/v1/block")) {
                const key = try c.field("key");
                const why = try c.unhex("why_hex");
                try c.put(try c.key2("blocked.", key), try hex_alloc(c.arena, why));
                try c.journal("BLOCK    {s} until a person reviews: {s}", .{ key, why });
            } else if (eql(u8, route_name, "/v1/blocked")) {
                if (try c.store.get(try c.key2("blocked.", try c.field("key")))) |why_hex| {
                    try c.reply("held=true", .{});
                    try c.reply("why_hex={s}", .{why_hex});
                } else {
                    try c.reply("held=false", .{});
                }
            } else if (eql(u8, route_name, "/v1/unblock")) {
                const key = try c.field("key");
                const blocked = try c.key2("blocked.", key);
                if (try c.store.get(blocked) != null) {
                    try c.remove(blocked);
                    try c.journal("UNBLOCK  {s}", .{key});
                }
            } else if (eql(u8, route_name, "/v1/recall")) {
                const rid = try c.field("request_id");
                if (try c.store.get(try c.key2("result.", rid))) |value_hex| {
                    try c.reply("found=true", .{});
                    try c.reply("value_hex={s}", .{value_hex});
                    if (std.mem.endsWith(u8, rid, "/allowance")) {
                        try c.journal("REUSE    journalled allowance answer  [{s}]", .{rid});
                    } else {
                        try c.journal(
                            "REUSE    journalled result, provider not called again  [{s}]",
                            .{rid},
                        );
                    }
                } else {
                    try c.reply("found=false", .{});
                }
            } else if (eql(u8, route_name, "/v1/remember")) {
                // `ledgerd.py` appends to a file and `recall` returns the first match.
                const key = try c.key2("result.", try c.field("request_id"));
                const value_hex = try c.field("value_hex");
                if (try c.store.get(key) == null) try c.put(key, value_hex);
            } else if (eql(u8, route_name, "/v1/sequence")) {
                try c.reply("seq={}", .{try c.nat(try c.key2("seq.", try c.field("agent")))});
            } else if (eql(u8, route_name, "/v1/bump")) {
                const agent = try c.field("agent");
                const seq = try c.nat(try c.key2("seq.", agent)) + 1;
                try c.put(try c.key2("seq.", agent), try c.int(seq));
                const resuming = try c.key2("resuming.", agent);
                if (try c.store.get(resuming) != null) try c.remove(resuming);
                try c.reply("seq={}", .{seq});
            } else if (eql(u8, route_name, "/v1/claim")) {
                try c.claim();
            } else if (eql(u8, route_name, "/v1/admin/init")) {
                const available = try c.amount("amount");
                try c.store.reset();
                try c.put("available", try c.int(available));
                try c.put("held", "0");
                try c.put("settled", "0");
                try c.put("prevented", "0");
                try c.reply("summary={s}", .{try c.summary()});
            } else if (eql(u8, route_name, "/v1/admin/topup")) {
                const added = try c.amount("amount");
                try c.put("available", try c.total(try c.nat("available") + added));
                try c.journal("TOPUP    {}", .{added});
                try c.reply("summary={s}", .{try c.summary()});
            } else {
                return false;
            }
            return true;
        }

        fn refused(c: *Self) !void {
            const estimate = try c.amount("estimate");
            const rid = try c.field("request_id");
            const why = try c.unhex("why_hex");
            const counted = try c.count_denial(rid, estimate);
            // After counting, as in `ledgerd.py`: a bad memo still leaves the denial counted.
            const memo = try c.unhex("memo_hex");
            try c.journal("DENIED   {}  {s}  ({s}{s})  [{s}]", .{
                estimate,
                memo,
                why,
                if (counted) "" else "; already counted",
                rid,
            });
        }

        fn reserve(c: *Self) !void {
            const rid = try c.field("request_id");
            const memo = try c.unhex("memo_hex");
            const estimate = try c.amount("estimate");
            const available = try c.nat("available");
            const request_value = try std.fmt.allocPrint(c.arena, "{}:{s}", .{
                estimate,
                try hex_alloc(c.arena, memo),
            });

            if (try c.mismatch(rid, request_value)) |was| {
                try c.journal("REFUSED  {}  {s}  (request id already used for {s})  [{s}]", .{
                    estimate,
                    memo,
                    was,
                    rid,
                });
                try c.reply("granted=false", .{});
                try c.reply("state=mismatch", .{});
            } else if (try c.store.get(try c.key2("done.", rid)) != null) {
                try c.journal("REPLAY   already settled, not charged again  {s}  [{s}]", .{
                    memo,
                    rid,
                });
                try c.reply("granted=true", .{});
                try c.reply("state=already_settled", .{});
            } else if (try c.store.get(try c.key2("hold.", rid)) != null) {
                try c.journal("RECOVER  reservation already held  {s}  [{s}]", .{ memo, rid });
                try c.reply("granted=true", .{});
                try c.reply("state=already_reserved", .{});
            } else if (estimate > available) {
                const retry = c.fields.get("retry");
                if (retry != null and std.mem.eql(u8, retry.?, "1")) {
                    try c.journal("DENIED   {}  {s}  " ++
                        "(retry, not recounted; available {})  [{s}]", .{
                        estimate,
                        memo,
                        available,
                        rid,
                    });
                } else if (try c.count_denial(rid, estimate)) {
                    try c.journal("DENIED   {}  {s}  (available {})  [{s}]", .{
                        estimate,
                        memo,
                        available,
                        rid,
                    });
                } else {
                    try c.journal("DENIED   {}  {s}  (already counted; available {})  [{s}]", .{
                        estimate,
                        memo,
                        available,
                        rid,
                    });
                }
                try c.reply("granted=false", .{});
                try c.reply("state=denied", .{});
            } else {
                const held = try c.total(try c.nat("held") + estimate);
                try c.put("available", try c.int(available - estimate));
                try c.put("held", held);
                try c.put(try c.key2("hold.", rid), try c.int(estimate));
                try c.put(try c.key2("req.", rid), request_value);
                try c.journal("RESERVE  {}  {s}  [{s}]", .{ estimate, memo, rid });
                try c.reply("granted=true", .{});
                try c.reply("state=reserved", .{});
            }
        }

        fn settle(c: *Self) !void {
            const rid = try c.field("request_id");
            const actual = try c.amount("actual");
            var within = true;
            if (try c.store.get(try c.key2("hold.", rid))) |held| {
                const estimate = int_parse(held) orelse 0;
                const available = try c.nat("available");
                const excess = actual - estimate;
                // Every checked total before any write (N18).
                const settled = try c.total(try c.nat("settled") + actual);
                const available_after: ?[]const u8 = if (excess <= 0)
                    try c.total(available - excess)
                else if (excess <= available)
                    try c.int(available - excess)
                else
                    null;
                const overage = if (available_after == null)
                    try c.total(try c.nat("overage") + excess)
                else
                    null;

                try c.put("held", try c.int(@max(0, try c.nat("held") - estimate)));
                try c.put("settled", settled);
                try c.remove(try c.key2("hold.", rid));
                try c.put(try c.key2("done.", rid), try c.int(actual));
                if (excess <= 0) {
                    try c.put("available", available_after.?);
                    try c.journal("SETTLE   {}  released {}  [{s}]", .{ actual, -excess, rid });
                } else if (excess <= available) {
                    try c.put("available", available_after.?);
                    try c.journal("SETTLE   {}  {} above its hold, charged to available  [{s}]", .{
                        actual,
                        excess,
                        rid,
                    });
                } else {
                    try c.put("overage", overage.?);
                    try c.put(try c.key2("review.", rid), try c.int(excess));
                    within = false;
                    try c.journal("OVERAGE  {}  {} above its hold with {} available, " ++
                        "booked to overage; agent stops for review  [{s}]", .{
                        actual,
                        excess,
                        available,
                        rid,
                    });
                }
            } else {
                // A re-run's settle: if the first stopped the agent for review, so does this.
                if (try c.store.get(try c.key2("review.", rid)) != null) within = false;
                if (try c.store.get(try c.key2("done.", rid)) == null) {
                    const settled = try c.total(try c.nat("settled") + actual);
                    const overage = try c.total(try c.nat("overage") + actual);
                    try c.put("settled", settled);
                    try c.put("overage", overage);
                    try c.put(try c.key2("done.", rid), try c.int(actual));
                    try c.journal(
                        "OVERAGE  {}  settled with no hold, booked to overage  [{s}]",
                        .{ actual, rid },
                    );
                }
            }
            try c.reply("within={s}", .{if (within) "true" else "false"});
        }

        fn claim(c: *Self) !void {
            const agent = try c.field("agent");
            const expected = int_parse(try c.field("expected")) orelse
                return c.bad("invalid literal for int(): expected");
            const seq = try c.nat(try c.key2("seq.", agent));
            const resuming = try c.store.get(try c.key2("resuming.", agent));
            if (expected == seq) {
                try c.put(try c.key2("seq.", agent), try c.int(seq + 1));
                try c.put(try c.key2("resuming.", agent), try c.int(expected));
                try c.reply("result=claimed", .{});
                try c.reply("seq={}", .{seq + 1});
            } else if (resuming != null and int_parse(resuming.?) == expected) {
                try c.reply("result=reentered", .{});
                try c.reply("seq={}", .{seq});
            } else {
                try c.reply("result=stale", .{});
                try c.reply("seq={}", .{seq});
            }
        }

        /// What a known request id was reserved for, if this reserve asks for something else.
        fn mismatch(c: *Self, rid: []const u8, request_value: []const u8) !?[]const u8 {
            const was = try c.store.get(try c.key2("req.", rid)) orelse return null;
            if (std.mem.eql(u8, was, request_value)) return null;
            const colon = std.mem.indexOfScalar(u8, was, ':') orelse was.len;
            const memo_was = if (hex_decode(c.arena, was[@min(colon + 1, was.len)..])) |bytes|
                try utf8_replace(c.arena, bytes)
            else |_|
                "?";
            return try std.fmt.allocPrint(c.arena, "{s} {s}", .{ was[0..colon], memo_was });
        }

        /// Adds a refused request to `prevented` once; false if it was already counted.
        fn count_denial(c: *Self, rid: []const u8, estimate: i128) !bool {
            const denied = try c.key2("denied.", rid);
            if (try c.store.get(denied) != null) return false;
            try c.put("prevented", try c.total(try c.nat("prevented") + estimate));
            try c.put(denied, try c.int(estimate));
            return true;
        }

        fn summary(c: *Self) ![]const u8 {
            const overage = try c.nat("overage");
            return std.fmt.allocPrint(
                c.arena,
                "ledger: available {}, held {}, settled {}, prevented {}{s}",
                .{
                    try c.nat("available"),
                    try c.nat("held"),
                    try c.nat("settled"),
                    try c.nat("prevented"),
                    if (overage != 0)
                        try std.fmt.allocPrint(c.arena, ", overage {}", .{overage})
                    else
                        "",
                },
            );
        }

        fn state_lines(c: *Self) !void {
            const index = try c.store.get(state_index_key) orelse return;
            var keys = std.mem.splitScalar(u8, index, '\n');
            while (keys.next()) |key| {
                if (key.len == 0) continue;
                const value = (try c.store.get(key)).?;
                try c.reply("{s}={s}", .{ key, value });
            }
        }

        /// Writes `key`, keeping the state index in step (N16).
        fn put(c: *Self, key: []const u8, value: []const u8) !void {
            if (state_key(key) and try c.store.get(key) == null) try c.index_update(key, .add);
            try c.store.put(key, value);
        }

        fn remove(c: *Self, key: []const u8) !void {
            assert(try c.store.get(key) != null);
            if (state_key(key)) try c.index_update(key, .remove);
            try c.store.remove(key);
        }

        fn index_update(c: *Self, key: []const u8, action: enum { add, remove }) !void {
            var keys = std.ArrayList([]const u8).init(c.arena);
            if (try c.store.get(state_index_key)) |index| {
                var iterator = std.mem.splitScalar(u8, index, '\n');
                while (iterator.next()) |existing| {
                    if (existing.len == 0) continue;
                    if (std.mem.eql(u8, existing, key)) {
                        assert(action == .remove);
                        continue;
                    }
                    try keys.append(existing);
                }
            }
            if (action == .add) try keys.append(key);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn less_than(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less_than);
            try c.store.put(state_index_key, try std.mem.join(c.arena, "\n", keys.items));
        }

        /// Appends a journal line: persisted, and returned to the caller as `line_hex`.
        fn journal(c: *Self, comptime format: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(c.arena, format, args);
            for (text) |*byte| {
                if (byte.* == '\n' or byte.* == '\r') byte.* = ' ';
            }
            // A unique key, not a shared counter: a counter would be a row every journaling
            // route writes, so every two of them would conflict (N19). The change feed orders
            // the lines.
            try c.store.put(
                try std.fmt.allocPrint(c.arena, "journal.{x:0>32}", .{c.store.unique()}),
                text,
            );
            try c.said.append(c.arena, text);
        }

        fn reply(c: *Self, comptime format: []const u8, args: anytype) !void {
            try c.out.append(c.arena, try std.fmt.allocPrint(c.arena, format, args));
        }

        fn field(c: *Self, name: []const u8) Error![]const u8 {
            return c.fields.get(name) orelse c.bad(name);
        }

        /// A required amount: a decimal integer in `0..amount_max`.
        fn amount(c: *Self, name: []const u8) Error!i128 {
            const text = try c.field(name);
            const value = int_parse(text) orelse return c.bad(name);
            if (value < 0 or value > amount_max) return c.bad(name);
            return value;
        }

        /// A running total, refused past `total_max` rather than wrapping.
        fn total(c: *Self, value: i128) Error![]const u8 {
            if (value > total_max) return c.bad("a ledger total would pass 4611686018427387904");
            return c.int(value);
        }

        /// A stored integer; zero when absent or unparseable (as `nat` in `ledgerd.py`).
        fn nat(c: *Self, key: []const u8) !i128 {
            const value = try c.store.get(key) orelse return 0;
            return int_parse(value) orelse 0;
        }

        fn unhex(c: *Self, name: []const u8) Error![]const u8 {
            const bytes = hex_decode(c.arena, c.fields.get(name) orelse "") catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidHex => return c.bad(name),
                };
            return utf8_replace(c.arena, bytes);
        }

        fn int(c: *Self, value: i128) Error![]const u8 {
            return std.fmt.allocPrint(c.arena, "{}", .{value});
        }

        fn key2(c: *Self, prefix: []const u8, suffix: []const u8) Error![]const u8 {
            return std.mem.concat(c.arena, u8, &.{ prefix, suffix });
        }

        fn bad(c: *Self, reason: []const u8) error{BadRequest} {
            c.bad_request = reason;
            return error.BadRequest;
        }
    };
}

fn state_key(key: []const u8) bool {
    for (state_prefixes) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

/// A decimal integer with an optional leading `-` (N17: no `+`, spaces or underscores).
fn int_parse(text: []const u8) ?i128 {
    if (text.len == 0 or text.len > 38) return null;
    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;
    if (digits.len == 0) return null;
    var value: i128 = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return null;
        value = value * 10 + (digit - '0');
    }
    return if (negative) -value else value;
}

fn hex_decode(arena: std.mem.Allocator, text: []const u8) error{ OutOfMemory, InvalidHex }![]u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const bytes = try arena.alloc(u8, text.len / 2);
    _ = std.fmt.hexToBytes(bytes, text) catch return error.InvalidHex;
    return bytes;
}

fn hex_encode(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte| try writer.print("{x:0>2}", .{byte});
}

fn hex_alloc(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hex = std.ArrayList(u8).init(arena);
    try hex_encode(hex.writer(), bytes);
    return hex.items;
}

/// Decodes UTF-8 as Python's `bytes.decode("utf-8", "replace")` does: each maximal ill-formed
/// subpart becomes U+FFFD.
pub fn utf8_replace(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out = std.ArrayList(u8).init(arena);
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        const length: usize, const low: u8, const high: u8 = switch (first) {
            0x00...0x7f => .{ 1, 0, 0 },
            0xc2...0xdf => .{ 2, 0x80, 0xbf },
            0xe0 => .{ 3, 0xa0, 0xbf },
            0xe1...0xec, 0xee...0xef => .{ 3, 0x80, 0xbf },
            0xed => .{ 3, 0x80, 0x9f },
            0xf0 => .{ 4, 0x90, 0xbf },
            0xf1...0xf3 => .{ 4, 0x80, 0xbf },
            0xf4 => .{ 4, 0x80, 0x8f },
            else => .{ 0, 0, 0 }, // Never a valid first byte.
        };
        if (length == 0) {
            try out.appendSlice("\u{fffd}");
            index += 1;
            continue;
        }
        // Count the continuation bytes that are valid so far: the second byte has a
        // first-byte-specific range, the rest 0x80..0xbf.
        var valid: usize = 1;
        while (valid < length and index + valid < bytes.len) : (valid += 1) {
            const byte = bytes[index + valid];
            const in_range = if (valid == 1)
                byte >= low and byte <= high
            else
                byte >= 0x80 and byte <= 0xbf;
            if (!in_range) break;
        }
        if (valid == length) {
            try out.appendSlice(bytes[index..][0..length]);
        } else {
            try out.appendSlice("\u{fffd}");
        }
        index += valid;
    }
    return out.items;
}

/// An in-memory store, for tests.
pub const MemoryStore = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},
    allocator: std.mem.Allocator,
    unique_next: u128 = 1,

    pub fn unique(store: *MemoryStore) u128 {
        defer store.unique_next += 1;
        return store.unique_next;
    }

    pub fn get(store: *MemoryStore, key: []const u8) !?[]const u8 {
        return store.map.get(key);
    }

    pub fn put(store: *MemoryStore, key: []const u8, value: []const u8) !void {
        try store.map.put(
            store.allocator,
            try store.allocator.dupe(u8, key),
            try store.allocator.dupe(u8, value),
        );
    }

    pub fn remove(store: *MemoryStore, key: []const u8) !void {
        assert(store.map.remove(key));
    }

    pub fn reset(store: *MemoryStore) !void {
        store.map.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn test_request(
    arena: std.mem.Allocator,
    store: *MemoryStore,
    route: []const u8,
    body: []const u8,
) ![]const u8 {
    const fields = try fields_parse(arena, body);
    const reply = (try handle(arena, store, route, &fields)).?;
    return reply.body;
}

fn test_hex(comptime text: []const u8) *const [text.len * 2]u8 {
    return comptime hex: {
        const digits = "0123456789abcdef";
        var result: [text.len * 2]u8 = undefined;
        for (text, 0..) |byte, index| {
            result[index * 2] = digits[byte >> 4];
            result[index * 2 + 1] = digits[byte & 0xf];
        }
        const final = result;
        break :hex &final;
    };
}

test "ledgerd routes: reserve, settle, replay and summary" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var store: MemoryStore = .{ .allocator = arena };

    try testing.expectEqualStrings(
        "summary=ledger: available 20000, held 0, settled 0, prevented 0\nok=true",
        try test_request(arena, &store, "/v1/admin/init", "amount=20000"),
    );
    const reserve = "request_id=a:0:0\nmemo_hex=" ++ test_hex("llm.complete") ++ "\nestimate=3000";
    try testing.expectEqualStrings(
        "granted=true\nstate=reserved\nline_hex=" ++
            test_hex("RESERVE  3000  llm.complete  [a:0:0]") ++ "\nok=true",
        try test_request(arena, &store, "/v1/reserve", reserve),
    );
    try testing.expectEqualStrings(
        "within=true\nline_hex=" ++ test_hex("SETTLE   2500  released 500  [a:0:0]") ++ "\nok=true",
        try test_request(arena, &store, "/v1/settle", "request_id=a:0:0\nactual=2500"),
    );
    try testing.expectEqualStrings(
        "granted=true\nstate=already_settled\nline_hex=" ++
            test_hex("REPLAY   already settled, not charged again  llm.complete  [a:0:0]") ++
            "\nok=true",
        try test_request(arena, &store, "/v1/reserve", reserve),
    );
    try testing.expectEqualStrings(
        "summary=ledger: available 17500, held 0, settled 2500, prevented 0\nok=true",
        try test_request(arena, &store, "/v1/summary", ""),
    );
}

test "ledgerd routes: claim, status and bad requests" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var store: MemoryStore = .{ .allocator = arena };

    _ = try test_request(arena, &store, "/v1/admin/init", "amount=100");
    try testing.expectEqualStrings(
        "result=claimed\nseq=1\nok=true",
        try test_request(arena, &store, "/v1/claim", "agent=r\nexpected=0"),
    );
    try testing.expectEqualStrings(
        "result=reentered\nseq=1\nok=true",
        try test_request(arena, &store, "/v1/claim", "agent=r\nexpected=0"),
    );
    try testing.expectEqualStrings(
        "result=stale\nseq=1\nok=true",
        try test_request(arena, &store, "/v1/claim", "agent=r\nexpected=5"),
    );
    try testing.expectEqualStrings(
        "summary=ledger: available 100, held 0, settled 0, prevented 0\n" ++
            "resuming.r=0\nseq.r=1\nok=true",
        try test_request(arena, &store, "/v1/status", ""),
    );

    const fields = try fields_parse(arena, "estimate=12");
    const reply = (try handle(arena, &store, "/v1/reserve", &fields)).?;
    try testing.expectEqual(@as(u16, 400), reply.status);
    try testing.expect(std.mem.startsWith(u8, reply.body, "error=bad request: "));
    try testing.expectEqual(null, try handle(arena, &store, "/v1/nope", &fields));
}

test utf8_replace {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Expected values from Python: bytes(...).decode("utf-8", "replace").
    try testing.expectEqualStrings("ok", try utf8_replace(arena, "ok"));
    try testing.expectEqualStrings("a\u{fffd}b", try utf8_replace(arena, "a\xffb"));
    try testing.expectEqualStrings("\u{fffd}\u{fffd}", try utf8_replace(arena, "\xc0\xaf"));
    try testing.expectEqualStrings("\u{fffd}", try utf8_replace(arena, "\xe2\x82"));
    try testing.expectEqualStrings("\u{fffd}A", try utf8_replace(arena, "\xe2\x82A"));
    try testing.expectEqualStrings(
        "\u{fffd}\u{fffd}",
        try utf8_replace(arena, "\xed\xa0\x80"[0..2]),
    );
    try testing.expectEqualStrings("\u{20ac}", try utf8_replace(arena, "\xe2\x82\xac"));
}

test fields_parse {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const fields = try fields_parse(arena, "a=1\r\nb=x=y\rnoequals\nA=2\na=3");
    try testing.expectEqualStrings("3", fields.get("a").?);
    try testing.expectEqualStrings("x=y", fields.get("b").?);
    try testing.expectEqualStrings("2", fields.get("A").?);
    try testing.expectEqual(null, fields.get("noequals"));
}
