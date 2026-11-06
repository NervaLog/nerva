//! The codes `nerva api` and `nerva view` put on the wire (P147c, R4, P168b): every non-2xx
//! reply carries `"code"` and `"applied"` beside the identifiers clients already match on.
//!
//! `Code` holds the codes a reply can carry. A unit test keeps each one registered in
//! `docs/ERRORS.md`. A refusal of a request names its code where it is made; the many texts of
//! a malformed request (`api.bad`, `catalog.invalid`) share a family of codes, and `of_bad` and
//! `of_invalid` place each text in its family. A unit test reads the sources and fails for a
//! text it cannot place.

const std = @import("std");
const assert = std.debug.assert;

/// A code a reply can carry. Never renumber or reuse one (docs/ERRORS.md).
pub const Code = enum {
    E0101,
    E0102,
    E0103,
    E0104,
    E0105,
    E0106,
    E0107,
    E0108,
    E0109,
    E0110,
    E0111,
    E0112,
    E0113,
    E0114,
    E0115,
    E0116,
    W0201,
    E0202,
    E0203,
    E0204,
    E0205,
    E0206,
    E0207,
    E0208,
    E0209,
    E0210,
    E0211,
    E0212,
    E0301,
    E0302,
    E0303,
    E0304,
    E0305,
    E0306,
    E0307,
    E0308,
    E0309,
    E0311,
    E0312,
    E0401,
    E0402,
    E0403,
    E0404,
    E0405,
    E0406,
    E0407,
    E0408,
    E0409,
    E0410,
    E0501,
    E0502,
    E0503,
    E0504,
    E0601,
    E0602,
    E0605,
    E0606,
    E1001,
    E1002,
    B0001,
    B0002,

    /// `NRV-E0101`.
    pub fn text(code: Code) []const u8 {
        return switch (code) {
            inline else => |known| "NRV-" ++ @tagName(known),
        };
    }
};

/// Whether the request may have changed the cluster's state.
pub const Applied = enum {
    /// Nothing reached the cluster, or the cluster refused it.
    no,
    /// A write went out and no reply came back.
    unknown,

    /// The JSON value.
    pub fn json(applied: Applied) []const u8 {
        return switch (applied) {
            .no => "false",
            .unknown => "\"unknown\"",
        };
    }
};

/// The body of an error reply whose reason is fixed: `{"error":…,"applied":…,"code":…}`. The
/// reason has nothing to escape.
pub fn error_body(comptime code: Code, comptime reason: []const u8, applied: Applied) []const u8 {
    comptime for (reason) |byte| assert(byte >= ' ' and byte != '"' and byte != '\\');
    return switch (applied) {
        inline else => |known| "{\"error\":\"" ++ reason ++ "\",\"applied\":" ++
            comptime known.json() ++ ",\"code\":\"" ++ code.text() ++ "\"}",
    };
}

const Rule = struct {
    how: enum { exact, prefix, suffix, contains },
    text: []const u8,
    code: Code,

    fn matches(rule: Rule, reason: []const u8) bool {
        return switch (rule.how) {
            .exact => std.mem.eql(u8, reason, rule.text),
            .prefix => std.mem.startsWith(u8, reason, rule.text),
            .suffix => std.mem.endsWith(u8, reason, rule.text),
            .contains => std.mem.indexOf(u8, reason, rule.text) != null,
        };
    }
};

fn exact(text: []const u8, code: Code) Rule {
    return .{ .how = .exact, .text = text, .code = code };
}
fn prefix(text: []const u8, code: Code) Rule {
    return .{ .how = .prefix, .text = text, .code = code };
}
fn suffix(text: []const u8, code: Code) Rule {
    return .{ .how = .suffix, .text = text, .code = code };
}
fn contains(text: []const u8, code: Code) Rule {
    return .{ .how = .contains, .text = text, .code = code };
}

fn find(rules: []const Rule, reason: []const u8) ?Code {
    for (rules) |rule| {
        if (rule.matches(reason)) return rule.code;
    }
    return null;
}

/// The family of a malformed request's reason (`api.bad`); the first rule that matches wins.
pub fn of_bad(reason: []const u8) ?Code {
    const rules = comptime [_]Rule{
        exact("malformed JSON", .E0105),
        exact("unknown field", .E0105),
        exact("missing field", .E0105),
        exact("unexpected body", .E0105),
        // Before the suffixes: `table is out of range`, `eq is required`.
        prefix("table ", .E0108),
        exact("eq is required", .E0409),
        suffix(" must be a decimal string", .E0106),
        suffix(" is out of range", .E0106),
        exact("malformed query", .E0107),
        exact("unknown query parameter", .E0107),
        exact("repeated query parameter", .E0107),
        exact("unexpected query", .E0107),
        suffix(" is required", .E0107),
        suffix(" must be positive", .E0107),
        suffix(" is not hex", .E0109),
        contains("bytes of hex", .E0109),
        exact("key must not be zero", .E0109),
        exact("a lookup reads rows or records, not both: send two", .E0111),
        exact("rows must not be empty", .E0111),
        contains("needs a layout", .E0114),
        contains("need a layout", .E0114),
        exact("no such field", .E0114),
        exact("an add's field must be u64 or i64", .E0114),
        exact("the index's table has no layout", .E0114),
        // A malformed commit entry.
        exact("entries must not be empty", .E0110),
        exact("records take no adds", .E0110),
        prefix("only a", .E0110),
        prefix("a read ", .E0110),
        prefix("a put ", .E0110),
        prefix("a delete ", .E0110),
        prefix("an add ", .E0110),
        prefix("delta_from ", .E0110),
        exact("min must not exceed max", .E0110),
        exact("offset must be at most 72", .E0110),
        // Declarations.
        prefix("a ledger", .E0304),
        exact("invalid ledger id", .E0304),
        prefix("an index ", .E0311),
        prefix("the index breaks", .E0311),
        exact("at most 4 where clauses", .E0311),
        exact("unknown field in eq", .E0311),
        exact("unknown order field", .E0311),
        exact("unknown field in where", .E0311),
        exact("where compares numbers and bools only", .E0311),
        exact("a where value is a number", .E0311),
        // Reads.
        exact("invalid cursor", .E0408),
        exact("after is malformed", .E0408),
        exact("min_op or as_of, not both", .E0410),
        prefix("the view has more groups", .E0407),
        exact("eq is required", .E0409),
        prefix("eq ", .E0409),
        exact("min is above max", .E0409),
        exact("the scan is malformed", .E0409),
        exact("min and max are numbers", .E0409),
    };
    return find(&rules, reason);
}

/// The family of a catalog declaration's reason (`catalog.invalid`).
pub fn of_invalid(reason: []const u8) ?Code {
    const rules = comptime [_]Rule{
        exact("unknown field", .E0114),
        exact("fields must be an object", .E0115),
        suffix(" field takes true or false", .E0115),
        prefix("a bytes field takes", .E0115),
        prefix("a number is", .E0115),
        prefix("an integer field takes", .E0115),
        contains("view name is", .E0307),
        contains("ledger name is", .E0304),
        contains("index name is", .E0311),
        contains("layout name is", .E0301),
        prefix("a layout", .E0301),
        prefix("the layout", .E0301),
        exact("duplicate field", .E0301),
        exact("only a bytes field has a size", .E0301),
        prefix("a bytes field ", .E0301),
        prefix("the fields do not fit", .E0301),
        prefix("a view", .E0307),
        prefix("the view", .E0307),
        prefix("count has no field", .E0307),
        prefix("unknown field in ", .E0307),
        prefix("where compares", .E0307),
        prefix("sum, min and max", .E0307),
    };
    return find(&rules, reason);
}

const testing = std.testing;

test "wire_code: error_body" {
    try testing.expectEqualStrings(
        "{\"error\":\"busy\",\"applied\":false,\"code\":\"NRV-E0602\"}",
        error_body(.E0602, "busy", .no),
    );
    try testing.expectEqualStrings(
        "{\"error\":\"cluster unavailable\",\"applied\":\"unknown\",\"code\":\"NRV-E0601\"}",
        error_body(.E0601, "cluster unavailable", .unknown),
    );
}

test "wire_code: every code is registered in docs/ERRORS.md" {
    const text = try std.fs.cwd().readFileAlloc(testing.allocator, "docs/ERRORS.md", 1 << 20);
    defer testing.allocator.free(text);
    inline for (@typeInfo(Code).@"enum".fields) |field| {
        const needle = "| NRV-" ++ field.name ++ " | ";
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("{s} is not registered in docs/ERRORS.md\n", .{field.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqualStrings("NRV-E0602", Code.E0602.text());
    try testing.expectEqualStrings("NRV-W0201", Code.W0201.text());
}

/// The text of every string literal given to `name("...")` in `source`.
fn literals_expect_placed(
    source: []const u8,
    comptime name: []const u8,
    place: *const fn ([]const u8) ?Code,
) !void {
    var rest = source;
    // Tests come last in each file and name reasons too: stop before them.
    if (std.mem.indexOf(u8, rest, "\ntest ")) |end| rest = rest[0..end];
    var count: u32 = 0;
    while (std.mem.indexOf(u8, rest, name ++ "(\"")) |at| {
        // Not the tail of a longer name (`refuse(`).
        const before: u8 = if (at == 0) ' ' else rest[at - 1];
        const start = at + name.len + 2;
        rest = rest[start..];
        if (std.ascii.isAlphanumeric(before) or before == '_') continue;
        // Up to the closing quote, past escaped ones.
        var end: usize = 0;
        while (rest[end] != '"') : (end += 1) {
            if (rest[end] == '\\') end += 1;
        }
        const literal = rest[0..end];
        // A literal joined to another with `++` is only a piece of a reason.
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, rest[end + 1 ..], " \n"), "++")) continue;
        var unescaped: [256]u8 = undefined;
        var length: usize = 0;
        var index: usize = 0;
        while (index < literal.len) : (index += 1) {
            if (literal[index] == '\\') index += 1;
            unescaped[length] = literal[index];
            length += 1;
        }
        if (place(unescaped[0..length]) == null) {
            std.debug.print("{s}(\"{s}\") has no code\n", .{ name, literal });
            return error.TestUnexpectedResult;
        }
        count += 1;
    }
    try testing.expect(count > 0);
}

test "wire_code: every reason the gateway refuses with has a code" {
    try literals_expect_placed(@embedFile("api/api.zig"), "bad", of_bad);
    try literals_expect_placed(@embedFile("catalog.zig"), "invalid", of_invalid);
}
