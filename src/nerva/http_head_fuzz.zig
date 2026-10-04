//! Fuzzes the gateways' request-head parser and key check (docs/DECISIONS.md N45, N46).
//!
//! - Generated valid heads (random methods, targets, header case and whitespace, optional
//!   `Content-Length`, `Expect`, key and filler headers) parse to exactly what was generated.
//! - Mutated valid heads and random bytes never crash `head_parse`, and whatever it accepts
//!   keeps the properties the gateways rely on.
//! - `key_matches` is true exactly for equal keys.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.fuzz_nerva_http_head);

const stdx = @import("stdx");
const fuzz = @import("../testing/fuzz.zig");
const http_connection = @import("http_connection.zig");

const Head = http_connection.Head;
const head_parse = http_connection.head_parse;

const head_size_max = 4096;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = stdx.PRNG.from_seed(args.seed);
    const events_max = args.events_max orelse 200_000;

    var buffer: [head_size_max]u8 = undefined;
    var counts: struct { valid: u64 = 0, mutated_accepted: u64 = 0, mutated_refused: u64 = 0 } =
        .{};
    for (0..events_max) |_| {
        switch (prng.int_inclusive(u8, 9)) {
            0...3 => {
                const generated = head_random(&prng, &buffer);
                const parsed = head_parse(generated.head) orelse
                    std.debug.panic("refused a valid head: {s}", .{generated.head});
                head_expect(&generated.expected, &parsed, generated.head);
                counts.valid += 1;
            },
            4...7 => {
                const generated = head_random(&prng, &buffer);
                const mutated = head_mutate(&prng, &buffer, generated.head.len);
                if (head_parse(mutated)) |parsed| {
                    head_check(mutated, &parsed);
                    counts.mutated_accepted += 1;
                } else {
                    counts.mutated_refused += 1;
                }
            },
            8 => {
                const size = prng.int_inclusive(usize, 512);
                const bytes = buffer[0..size];
                for (bytes) |*byte| byte.* = byte_random(&prng);
                if (head_parse(bytes)) |parsed| head_check(bytes, &parsed);
            },
            9 => key_matches_random(&prng),
            else => unreachable,
        }
    }
    log.info("{} events: {} valid heads; mutated heads {} accepted, {} refused", .{
        events_max,
        counts.valid,
        counts.mutated_accepted,
        counts.mutated_refused,
    });
    if (events_max >= 10_000) {
        assert(counts.valid > 0 and counts.mutated_accepted > 0 and counts.mutated_refused > 0);
    }
}

const Generated = struct { head: []const u8, expected: Head };

/// A valid head, and what `head_parse` must return for it. Slices point into `buffer`.
fn head_random(prng: *stdx.PRNG, buffer: *[head_size_max]u8) Generated {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    var expected: Head = .{
        .method = undefined,
        .target = undefined,
        .key = null,
        .content_length = 0,
        .expect_continue = false,
    };

    const methods = [_]struct { []const u8, http_connection.Method }{
        .{ "GET", .get },   .{ "POST", .post },   .{ "PUT", .put },   .{ "DELETE", .other },
        .{ "get", .other }, .{ "PATCH", .other }, .{ "X-Y", .other },
    };
    const method = methods[prng.index(&methods)];
    expected.method = method[1];
    writer.writeAll(method[0]) catch unreachable;
    writer.writeByte(' ') catch unreachable;

    const target_start = stream.pos;
    writer.writeByte('/') catch unreachable;
    for (0..prng.int_inclusive(usize, 40)) |_| {
        writer.writeByte(prng.range_inclusive(u8, 0x21, 0x7E)) catch unreachable;
    }
    expected.target = buffer[target_start..stream.pos];
    writer.writeAll(if (prng.boolean()) " HTTP/1.1\r\n" else " HTTP/1.0\r\n") catch unreachable;

    // Each header at most once, in random order, among filler headers.
    var content_length = prng.boolean();
    var key = prng.boolean();
    var expect = prng.chance(stdx.PRNG.ratio(1, 4));
    var fillers = prng.int_inclusive(u8, 6);
    while (content_length or key or expect or fillers > 0) {
        // Pick a header still to write.
        const kind = while (true) {
            const kind = prng.int_inclusive(u8, 3);
            const pending = switch (kind) {
                0 => content_length,
                1 => key,
                2 => expect,
                3 => fillers > 0,
                else => unreachable,
            };
            if (pending) break kind;
        };
        switch (kind) {
            0 => {
                content_length = false;
                expected.content_length = switch (prng.int_inclusive(u8, 2)) {
                    0 => 0,
                    1 => std.math.maxInt(u32),
                    else => prng.int(u32),
                };
                name_write(prng, writer, "content-length");
                // Leading zeros are digits too, within ten of them.
                var digits: [10]u8 = undefined;
                const text = std.fmt.bufPrint(&digits, "{}", .{expected.content_length}) catch
                    unreachable;
                for (0..prng.int_inclusive(usize, 10 - text.len)) |_| {
                    writer.writeByte('0') catch unreachable;
                }
                writer.writeAll(text) catch unreachable;
            },
            1 => {
                key = false;
                name_write(prng, writer, "x-nerva-key");
                const key_start = stream.pos;
                value_write(prng, writer);
                expected.key = std.mem.trimRight(u8, buffer[key_start..stream.pos], " \t");
            },
            2 => {
                expect = false;
                expected.expect_continue = true;
                name_write(prng, writer, "expect");
                writer.writeAll(if (prng.boolean()) "100-continue" else "100-Continue") catch
                    unreachable;
            },
            3 => {
                fillers -= 1;
                const fillers_names = [_][]const u8{
                    "host",   "user-agent", "accept", "content-type", "x-a",
                    "x-b_c~", "connection",
                };
                name_write(prng, writer, fillers_names[prng.index(&fillers_names)]);
                value_write(prng, writer);
            },
            else => unreachable,
        }
        ows_write(prng, writer);
        writer.writeAll("\r\n") catch unreachable;
    }
    writer.writeAll("\r\n") catch unreachable;
    return .{ .head = buffer[0..stream.pos], .expected = expected };
}

/// `name` in random case, a colon, and optional whitespace.
fn name_write(prng: *stdx.PRNG, writer: anytype, name: []const u8) void {
    for (name) |byte| {
        writer.writeByte(if (prng.boolean()) std.ascii.toUpper(byte) else byte) catch unreachable;
    }
    writer.writeByte(':') catch unreachable;
    ows_write(prng, writer);
}

fn ows_write(prng: *stdx.PRNG, writer: anytype) void {
    for (0..prng.int_inclusive(usize, 2)) |_| {
        writer.writeByte(if (prng.boolean()) ' ' else '\t') catch unreachable;
    }
}

/// A field value without leading or trailing whitespace: visible ASCII, inner spaces and tabs,
/// and bytes over 0x7F.
fn value_write(prng: *stdx.PRNG, writer: anytype) void {
    const size = prng.int_inclusive(usize, 30);
    for (0..size) |index| {
        const inner = index > 0 and index + 1 < size;
        const byte: u8 = switch (prng.int_inclusive(u8, 9)) {
            0 => if (inner) ' ' else 'a',
            1 => if (inner) '\t' else 'b',
            2 => prng.range_inclusive(u8, 0x80, 0xFF),
            else => prng.range_inclusive(u8, 0x21, 0x7E),
        };
        writer.writeByte(byte) catch unreachable;
    }
}

fn head_expect(expected: *const Head, parsed: *const Head, head: []const u8) void {
    const equal = expected.method == parsed.method and
        std.mem.eql(u8, expected.target, parsed.target) and
        expected.content_length == parsed.content_length and
        expected.expect_continue == parsed.expect_continue and
        (expected.key == null) == (parsed.key == null) and
        (expected.key == null or std.mem.eql(u8, expected.key.?, parsed.key.?));
    if (!equal) {
        std.debug.panic("head {s}\nexpected {}\nparsed {}", .{ head, expected.*, parsed.* });
    }
}

/// One to three mutations of the head in `buffer[0..size]`, in place: inserted, replaced or
/// deleted bytes (weighted to CR, LF, NUL, whitespace and colons), or a duplicated line.
fn head_mutate(prng: *stdx.PRNG, buffer: *[head_size_max]u8, size_start: usize) []u8 {
    var size = size_start;
    for (0..prng.range_inclusive(u8, 1, 3)) |_| {
        const position = prng.int_inclusive(usize, size);
        switch (prng.int_inclusive(u8, 3)) {
            0 => if (size < buffer.len) {
                std.mem.copyBackwards(u8, buffer[position + 1 .. size + 1], buffer[position..size]);
                buffer[position] = byte_random(prng);
                size += 1;
            },
            1 => if (position < size) {
                buffer[position] = byte_random(prng);
            },
            2 => if (position < size) {
                std.mem.copyForwards(u8, buffer[position .. size - 1], buffer[position + 1 .. size]);
                size -= 1;
            },
            3 => {
                // Duplicate the line at `position` (a repeated header, or a second request
                // line), if there is room.
                const head = buffer[0..size];
                const start = if (std.mem.lastIndexOf(u8, head[0..position], "\r\n")) |crlf|
                    crlf + 2
                else
                    0;
                const end = if (std.mem.indexOfPos(u8, head, start, "\r\n")) |crlf|
                    crlf + 2
                else
                    size;
                const line_size = end - start;
                if (size + line_size <= buffer.len) {
                    std.mem.copyBackwards(
                        u8,
                        buffer[end + line_size .. size + line_size],
                        buffer[end..size],
                    );
                    std.mem.copyForwards(u8, buffer[end .. end + line_size], buffer[start..end]);
                    size += line_size;
                }
            },
            else => unreachable,
        }
    }
    return buffer[0..size];
}

fn byte_random(prng: *stdx.PRNG) u8 {
    const special = "\r\n\x00 \t:/";
    return switch (prng.int_inclusive(u8, 3)) {
        0 => special[prng.index(special)],
        1 => prng.int(u8),
        else => prng.range_inclusive(u8, 0x21, 0x7E),
    };
}

/// What the gateways rely on in any head `head_parse` accepts. (A bare CR or LF also cannot
/// survive into a method, target, name or value, which each refuse control bytes.)
fn head_check(head: []const u8, parsed: *const Head) void {
    assert(std.mem.endsWith(u8, head, "\r\n\r\n"));
    for (head, 0..) |byte, index| {
        if (byte == '\n') assert(index > 0 and head[index - 1] == '\r');
        if (byte == '\r') assert(index + 1 < head.len and head[index + 1] == '\n');
    }
    assert(parsed.target.len > 0 and parsed.target[0] == '/');
    for (parsed.target) |byte| assert(byte > ' ' and byte < 0x7F);
    if (parsed.key) |key| {
        for (key) |byte| assert((byte >= ' ' or byte == '\t') and byte != 0x7F);
    }
    // At most one `Content-Length` and one key, and no `Transfer-Encoding`: a body has one
    // length, and a request one key.
    var content_lengths: u32 = 0;
    var keys: u32 = 0;
    var lines = std.mem.splitSequence(u8, head[0 .. head.len - "\r\n\r\n".len], "\r\n");
    _ = lines.next().?; // The request line.
    while (lines.next()) |line| {
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ':') orelse line.len];
        assert(!std.ascii.eqlIgnoreCase(name, "transfer-encoding"));
        if (std.ascii.eqlIgnoreCase(name, "content-length")) content_lengths += 1;
        if (std.ascii.eqlIgnoreCase(name, "x-nerva-key")) keys += 1;
    }
    assert(content_lengths <= 1);
    assert(keys == @intFromBool(parsed.key != null));

    // Deterministic.
    const again = head_parse(head).?;
    assert(again.method == parsed.method and again.content_length == parsed.content_length);
}

fn key_matches_random(prng: *stdx.PRNG) void {
    var key_buffer: [64]u8 = undefined;
    var header_buffer: [64]u8 = undefined;
    const key = key_buffer[0..prng.range_inclusive(usize, 1, key_buffer.len)];
    for (key) |*byte| byte.* = prng.int(u8);

    const header: ?[]const u8 = switch (prng.int_inclusive(u8, 4)) {
        0 => null,
        1 => key, // Equal.
        2 => key[0..prng.int_inclusive(usize, key.len - 1)], // A strict prefix.
        3 => header: { // One byte different.
            const header = header_buffer[0..key.len];
            @memcpy(header, key);
            header[prng.index(header)] ^= prng.range_inclusive(u8, 1, 255);
            break :header header;
        },
        4 => header: {
            const header = header_buffer[0..prng.int_inclusive(usize, header_buffer.len)];
            for (header) |*byte| byte.* = prng.int(u8);
            break :header header;
        },
        else => unreachable,
    };
    const expected = header != null and std.mem.eql(u8, header.?, key);
    assert(http_connection.key_matches(header, key) == expected);
}
