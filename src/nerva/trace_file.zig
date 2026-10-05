//! The file `start --trace` writes spans to (#30).
//!
//! The vendored tracer panics when its writer fails, and writes one span at a time on the
//! replica's thread. This writer never fails: it buffers spans and writes them `buffer_size` at a
//! time, stops tracing (logging why, once) on a write error or once the file would pass
//! `size_max`, and from then on accepts and drops whatever it is given. Tracing is for
//! diagnostic runs; a full or failing trace disk must not take the replica down.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.trace_file);

pub const buffer_size = 64 * 1024;
pub const size_max_default = 1024 * 1024 * 1024;

pub const TraceFile = struct {
    sink: std.io.AnyWriter,
    size_max: u64,
    buffer: [buffer_size]u8 = undefined,
    buffered: usize = 0,
    /// Bytes handed to `sink`.
    written: u64 = 0,
    stopped: bool = false,

    pub fn init(sink: std.io.AnyWriter, size_max: u64) TraceFile {
        assert(size_max > 0);
        return .{ .sink = sink, .size_max = size_max };
    }

    pub fn writer(trace: *TraceFile) std.io.AnyWriter {
        return .{ .context = trace, .writeFn = write_any };
    }

    /// Writes what is buffered; call before closing the file.
    pub fn flush(trace: *TraceFile) void {
        if (trace.stopped or trace.buffered == 0) return;
        trace.sink.writeAll(trace.buffer[0..trace.buffered]) catch |err| {
            trace.stop("writing it failed: {}", .{err});
            return;
        };
        trace.written += trace.buffered;
        trace.buffered = 0;
    }

    fn write_any(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const trace: *TraceFile = @constCast(@ptrCast(@alignCast(context)));
        trace.write(bytes);
        return bytes.len;
    }

    fn write(trace: *TraceFile, bytes: []const u8) void {
        if (trace.stopped) return;
        if (trace.written + trace.buffered + bytes.len > trace.size_max) {
            trace.flush();
            trace.stop("it reached --trace-size-max ({} bytes)", .{trace.size_max});
            return;
        }
        if (trace.buffered + bytes.len > buffer_size) trace.flush();
        if (trace.stopped) return;
        if (bytes.len > buffer_size) {
            // A span larger than the buffer (the tracer bounds them well below it).
            trace.sink.writeAll(bytes) catch |err| {
                trace.stop("writing it failed: {}", .{err});
                return;
            };
            trace.written += bytes.len;
            return;
        }
        @memcpy(trace.buffer[trace.buffered..][0..bytes.len], bytes);
        trace.buffered += bytes.len;
    }

    fn stop(trace: *TraceFile, comptime format: []const u8, args: anytype) void {
        assert(!trace.stopped);
        trace.stopped = true;
        trace.buffered = 0;
        log.warn("tracing stopped: " ++ format, args);
    }
};

const testing = std.testing;

test "TraceFile: buffers spans and writes them in large writes" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    var trace = TraceFile.init(out.writer().any(), size_max_default);
    const writer = trace.writer();

    try writer.writeAll("[\n");
    try writer.writeAll("{\"span\":1},\n");
    try testing.expectEqual(@as(usize, 0), out.items.len); // Buffered.
    trace.flush();
    try testing.expectEqualStrings("[\n{\"span\":1},\n", out.items);

    // Past the buffer, it writes what it holds first, in order.
    const span = "x" ** 1000;
    for (0..100) |_| try writer.writeAll(span);
    trace.flush();
    try testing.expectEqual(@as(usize, 14 + 100 * span.len), out.items.len);
    try testing.expect(!trace.stopped);
}

test "TraceFile: a write error stops tracing, and the writer never fails" {
    const Failing = struct {
        fn write(_: *const anyopaque, _: []const u8) anyerror!usize {
            return error.NoSpaceLeft;
        }
    };
    const failing: std.io.AnyWriter = .{ .context = undefined, .writeFn = Failing.write };
    var trace = TraceFile.init(failing, size_max_default);
    const writer = trace.writer();
    try writer.writeAll("[\n");
    trace.flush();
    try testing.expect(trace.stopped);
    for (0..1000) |_| try writer.writeAll("{\"span\":1},\n"); // Dropped, without error.
    trace.flush();
}

test "TraceFile: stops at its size limit" {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    var trace = TraceFile.init(out.writer().any(), 100);
    const writer = trace.writer();
    for (0..20) |_| try writer.writeAll("0123456789");
    trace.flush();
    try testing.expect(trace.stopped);
    try testing.expectEqual(@as(usize, 100), out.items.len);
}
