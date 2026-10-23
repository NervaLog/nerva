//! How Nerva's HTTP gateways (`api`, `view`) receive requests and send replies
//! (docs/DECISIONS.md N37, N45).
//!
//! A gateway executes one request at a time, but reads requests from up to `connections_max`
//! connections at once, so a client that sends its request slowly, or never, holds up nobody.
//! With every slot busy, a new connection displaces the oldest one still sending its request
//! (N58): holding slots open with idle connections cannot lock others out (#28).
//! Each connection carries one request (replies say `connection: close`), which must arrive
//! whole within `deadline_ns` of the connection being accepted; the reply is written within the
//! same budget, counted afresh. Request heads are parsed strictly (`head_parse`): anything
//! malformed answers 400 rather than being guessed at. Replies are sent without Nagle's delay
//! (`TCP_NODELAY`).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const log = std.log.scoped(.http);

pub const Method = enum { get, post, put, other };

/// A request head, parsed strictly. Slices point into the head's bytes.
pub const Head = struct {
    method: Method,
    target: []const u8,
    /// `X-Nerva-Key`, if sent (at most once).
    key: ?[]const u8,
    content_length: u32,
    /// `Expect: 100-continue` (curl sends it for bodies over 1 KiB).
    expect_continue: bool,
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    key: ?[]const u8,
    body: []const u8,
};

/// Parses a complete request head: the request line and headers, ending with an empty line.
/// Null if anything is malformed: a line not ending in CRLF (or a bare CR or LF anywhere),
/// control bytes, a folded header line, a header without a name or colon, `Content-Length`
/// twice or not plain digits, any `Transfer-Encoding` (a body must have a length), `X-Nerva-Key`
/// twice, an `Expect` other than `100-continue`, or a version other than HTTP/1.0 or 1.1.
pub fn head_parse(head: []const u8) ?Head {
    if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return null;
    // Every LF ends a CRLF, and every CR starts one.
    for (head, 0..) |byte, index| {
        switch (byte) {
            '\n' => if (index == 0 or head[index - 1] != '\r') return null,
            '\r' => if (index + 1 == head.len or head[index + 1] != '\n') return null,
            else => {},
        }
    }

    var lines = std.mem.splitSequence(u8, head[0 .. head.len - "\r\n\r\n".len], "\r\n");
    var parsed: Head = .{
        .method = .other,
        .target = undefined,
        .key = null,
        .content_length = 0,
        .expect_continue = false,
    };

    // The request line: method SP target SP version.
    var parts = std.mem.splitScalar(u8, lines.next().?, ' ');
    const method = parts.next().?;
    const target = parts.next() orelse return null;
    const version = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!token_valid(method)) return null;
    parsed.method = if (std.mem.eql(u8, method, "GET"))
        .get
    else if (std.mem.eql(u8, method, "POST"))
        .post
    else if (std.mem.eql(u8, method, "PUT"))
        .put
    else
        .other;
    if (target.len == 0 or target[0] != '/') return null;
    for (target) |byte| if (byte <= ' ' or byte >= 0x7F) return null;
    parsed.target = target;
    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) {
        return null;
    }

    var content_length_seen = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = line[0..colon];
        // Also refuses a folded line, which starts with whitespace.
        if (!token_valid(name)) return null;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for (value) |byte| if ((byte < ' ' and byte != '\t') or byte == 0x7F) return null;

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length_seen) return null;
            content_length_seen = true;
            if (value.len == 0 or value.len > 10) return null;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
            parsed.content_length = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return null;
        } else if (std.ascii.eqlIgnoreCase(name, "x-nerva-key")) {
            if (parsed.key != null) return null;
            parsed.key = value;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (!std.ascii.eqlIgnoreCase(value, "100-continue")) return null;
            parsed.expect_continue = true;
        }
    }
    return parsed;
}

/// A non-empty run of RFC 9110 token characters.
fn token_valid(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
        if (!valid) return false;
    }
    return true;
}

/// Whether `key_header` is the gateway's key, in time independent of where the two differ and
/// of their lengths: both are hashed, and the digests compared in constant time.
pub fn key_matches(key_header: ?[]const u8, key: []const u8) bool {
    assert(key.len > 0);
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(key, &expected, .{});
    var actual: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(key_header orelse "", &actual, .{});
    const equal = std.crypto.timing_safe.eql([Sha256.digest_length]u8, expected, actual);
    return equal and key_header != null;
}

/// A gateway's keys (P96): `X-Nerva-Key` must equal `current` or, during a rotation, `next`.
pub const Keys = struct {
    current: []const u8,
    next: ?[]const u8 = null,

    /// Why `NERVA_KEY` (`current`) and `NERVA_KEY_NEXT` (`next`) cannot be used, if they cannot:
    /// each set key is non-empty, and `next` differs from `current`. The message names no key.
    pub fn invalid(current: []const u8, next: ?[]const u8) ?[]const u8 {
        if (current.len == 0) return "set NERVA_KEY";
        const key_next = next orelse return null;
        if (key_next.len == 0) return "NERVA_KEY_NEXT is set but empty";
        if (std.mem.eql(u8, current, key_next)) return "NERVA_KEY_NEXT equals NERVA_KEY";
        return null;
    }
};

/// Whether `candidate` (`X-Nerva-Key`, if sent) is one of `keys`. Both keys are always compared,
/// each in constant time (`key_matches`), with no early return: the time taken does not tell
/// which key matched, nor whether a next key is set.
pub fn key_accepted(keys: Keys, candidate: ?[]const u8) bool {
    assert(Keys.invalid(keys.current, keys.next) == null);
    const current = key_matches(candidate, keys.current);
    const next = key_matches(candidate, keys.next orelse keys.current);
    const next_set = keys.next != null;
    return (@intFromBool(current) | (@intFromBool(next) & @intFromBool(next_set))) == 1;
}

pub const Options = struct {
    /// Connections read at once. A further connection displaces the oldest one still sending its
    /// request (or, with every slot's request complete, waits until one is served).
    connections_max: u32,
    head_size_max: u32 = 16 * 1024,
    body_size_max: u32,
    /// From accept to the request's last byte; and, afresh, for writing the reply.
    deadline_ns: u64 = 10 * std.time.ns_per_s,
};

/// A complete request, handed out by `Receiver.next` and valid until `Receiver.respond`.
pub const Received = struct {
    slot: u32,
    request: Request,
};

/// Accepts connections and reads their requests concurrently; hands out complete requests one at
/// a time, oldest connection first. All memory is allocated in `init`.
pub const Receiver = struct {
    options: Options,
    server: std.net.Server,
    timer: std.time.Timer,
    slots: []Slot,
    /// The listening socket, then one entry per slot.
    poll_fds: []posix.pollfd,
    /// Connections accepted so far: orders slots, oldest first.
    accepted_count: u64 = 0,

    const Slot = struct {
        state: enum { free, reading, complete, serving } = .free,
        fd: posix.fd_t = -1,
        /// Head, then body.
        buffer: []u8,
        size: u32 = 0,
        /// Set once the whole head has been received and parsed.
        head: ?Head = null,
        head_size: u32 = 0,
        /// A `timer` reading.
        deadline: u64 = 0,
        accepted: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, listen: std.net.Address, options: Options) !Receiver {
        assert(options.connections_max > 0);
        assert(options.head_size_max >= 64);
        assert(options.deadline_ns > 0);

        const slots = try gpa.alloc(Slot, options.connections_max);
        errdefer gpa.free(slots);
        var buffers_allocated: u32 = 0;
        errdefer for (slots[0..buffers_allocated]) |slot| gpa.free(slot.buffer);
        for (slots) |*slot| {
            slot.* = .{
                .buffer = try gpa.alloc(u8, options.head_size_max + options.body_size_max),
            };
            buffers_allocated += 1;
        }
        const poll_fds = try gpa.alloc(posix.pollfd, options.connections_max + 1);
        errdefer gpa.free(poll_fds);

        var server = try listen.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        return .{
            .options = options,
            .server = server,
            .timer = try std.time.Timer.start(),
            .slots = slots,
            .poll_fds = poll_fds,
        };
    }

    pub fn deinit(receiver: *Receiver, gpa: std.mem.Allocator) void {
        for (receiver.slots) |*slot| {
            if (slot.state != .free) receiver.close(slot);
            gpa.free(slot.buffer);
        }
        gpa.free(receiver.slots);
        gpa.free(receiver.poll_fds);
        receiver.server.deinit();
    }

    pub fn listen_address(receiver: *const Receiver) std.net.Address {
        return receiver.server.listen_address;
    }

    /// The next complete request, waiting at most `timeout_ms` for one (-1: until there is one).
    /// Meanwhile accepts connections, reads them, and closes those past their deadline.
    pub fn next(receiver: *Receiver, timeout_ms: i32) !?Received {
        assert(timeout_ms >= -1);
        for (receiver.slots) |*slot| assert(slot.state != .serving);
        const start = receiver.timer.read();
        while (true) {
            receiver.expire();
            if (receiver.oldest_complete()) |index| {
                return receiver.serve(index);
            }

            // Wait for activity, the nearest deadline, or the caller's timeout.
            const now = receiver.timer.read();
            var wait_ns: ?u64 = null;
            if (timeout_ms >= 0) {
                const timeout_ns = @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
                if (now - start >= timeout_ns) return null;
                wait_ns = timeout_ns - (now - start);
            }
            for (receiver.slots) |*slot| {
                if (slot.state == .reading) {
                    const left = slot.deadline -| now;
                    wait_ns = if (wait_ns) |wait| @min(wait, left) else left;
                }
            }
            _ = try receiver.poll(wait_ns, .displace);
        }
    }

    /// Complete requests that `accepted` approves of, oldest connection first, handed out as
    /// `next` does but without waiting for any: it only reads what has already arrived, and
    /// stops when nothing more is readable. At most `out.len` are taken, returned in `out`. Unlike `next`, it may
    /// be called while other requests are being served; each must be answered with `respond`.
    pub fn take(
        receiver: *Receiver,
        context: anytype,
        comptime accepted: fn (@TypeOf(context), *const Request) bool,
        out: []Received,
    ) usize {
        var count: usize = 0;
        // Accepting and reading take one pass each: bounded by the work that can be there.
        for (0..receiver.slots.len * 2) |_| {
            receiver.expire();
            const ready = receiver.poll(0, .keep) catch break;
            if (ready == 0) break;
        }
        while (count < out.len) {
            var oldest: ?u32 = null;
            for (receiver.slots, 0..) |*slot, index| {
                if (slot.state != .complete) continue;
                if (!accepted(context, &receiver.request_of(slot))) continue;
                if (oldest == null or slot.accepted < receiver.slots[oldest.?].accepted) {
                    oldest = @intCast(index);
                }
            }
            out[count] = receiver.serve(oldest orelse break);
            count += 1;
        }
        return count;
    }

    fn request_of(receiver: *const Receiver, slot: *const Slot) Request {
        _ = receiver;
        assert(slot.state == .complete or slot.state == .serving);
        const head = slot.head.?;
        return .{
            .method = head.method,
            .target = head.target,
            .key = head.key,
            .body = slot.buffer[slot.head_size..slot.size],
        };
    }

    /// Hands out the complete request in slot `index`.
    fn serve(receiver: *Receiver, index: u32) Received {
        const slot = &receiver.slots[index];
        assert(slot.state == .complete);
        const request = receiver.request_of(slot);
        slot.state = .serving;
        return .{ .slot = index, .request = request };
    }

    /// One `poll` over the connections still reading and the listening socket, waiting at most
    /// `wait_ns` (null: until there is activity), and the work it finds: accepting, reading.
    /// With every slot taken, a waiting connection displaces the oldest one still sending its
    /// request once that one is `displace_grace_ns` old (`.displace`, #28), or waits for a slot
    /// (`.keep`: the listening socket is not even looked at, so that requests being served are
    /// never preferred over a connection that is on its way). Returns how many descriptors were
    /// ready.
    fn poll(receiver: *Receiver, wait_ns_max: ?u64, full: enum { displace, keep }) !usize {
        var wait_ns = wait_ns_max;
        var fds_count: usize = 0;
        for (receiver.slots) |*slot| {
            switch (slot.state) {
                .free, .complete, .serving => {},
                .reading => {
                    receiver.poll_fds[fds_count] = .{
                        .fd = slot.fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    };
                    fds_count += 1;
                },
            }
        }
        // The listening socket, and last: with every slot busy, a waiting connection
        // displaces the oldest one still sending its request (#28). Last, so that a slot
        // closed for it has had its own events handled before its fd can be reused.
        const listening = receiver.slot_free() or full == .displace and listening: {
            // A connection that has only just arrived may be about to send: it is displaced
            // only when it has had its grace, and the wait ends then.
            const oldest = receiver.oldest_reading() orelse break :listening false;
            const accepted_ns = receiver.slots[oldest].deadline - receiver.options.deadline_ns;
            const now = receiver.timer.read();
            if (now >= accepted_ns + displace_grace_ns) break :listening true;
            const left = accepted_ns + displace_grace_ns - now;
            wait_ns = if (wait_ns) |wait| @min(wait, left) else left;
            break :listening false;
        };
        if (listening) {
            receiver.poll_fds[fds_count] = .{
                .fd = receiver.server.stream.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            fds_count += 1;
        }
        if (fds_count == 0) return 0;
        const ready = try posix.poll(receiver.poll_fds[0..fds_count], milliseconds(wait_ns));
        if (ready == 0) return 0;

        for (receiver.poll_fds[0..fds_count]) |poll_fd| {
            if (poll_fd.revents == 0) continue;
            if (poll_fd.fd == receiver.server.stream.handle) {
                if (!receiver.slot_free()) {
                    // Every slot complete: serve them first, then accept.
                    const oldest = receiver.oldest_reading() orelse continue;
                    log.debug("every slot busy: closing the oldest unfinished request", .{});
                    receiver.close(&receiver.slots[oldest]);
                }
                receiver.accept();
            } else {
                receiver.read(receiver.slot_reading(poll_fd.fd));
            }
        }
        return ready;
    }

    /// Writes the reply to a request handed out by `next`, then closes its connection.
    pub fn respond(receiver: *Receiver, received: Received, status: u16, body: []const u8) void {
        const slot = &receiver.slots[received.slot];
        assert(slot.state == .serving);
        receiver.reply(slot, status, body);
        receiver.close(slot);
    }

    fn accept(receiver: *Receiver) void {
        const slot = for (receiver.slots) |*slot| {
            if (slot.state == .free) break slot;
        } else unreachable; // `next` frees one first.
        const fd = posix.accept(
            receiver.server.stream.handle,
            null,
            null,
            posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        ) catch |err| {
            log.warn("accept: {}", .{err});
            return;
        };
        // A reply is written in two pieces (head, then body). With Nagle's algorithm the second
        // waits for the client's delayed ACK, about 40 ms.
        const enable: c_int = 1;
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&enable)) catch |err|
            log.warn("no delay: {}", .{err});

        receiver.accepted_count += 1;
        slot.* = .{
            .state = .reading,
            .fd = fd,
            .buffer = slot.buffer,
            .deadline = receiver.timer.read() + receiver.options.deadline_ns,
            .accepted = receiver.accepted_count,
        };
    }

    fn read(receiver: *Receiver, slot: *Slot) void {
        assert(slot.state == .reading);
        const size_max: u32 = if (slot.head) |head|
            slot.head_size + head.content_length
        else
            receiver.options.head_size_max;
        assert(slot.size < size_max);
        const count = posix.read(slot.fd, slot.buffer[slot.size..size_max]) catch |err|
            switch (err) {
                error.WouldBlock => return,
                else => return receiver.close(slot),
            };
        // Closed before sending the whole request.
        if (count == 0) return receiver.close(slot);
        const size_before = slot.size;
        slot.size += @intCast(count);
        assert(slot.size <= size_max);

        if (slot.head == null) {
            const bytes = slot.buffer[0..slot.size];
            const head_end = std.mem.indexOfPos(u8, bytes, size_before -| 3, "\r\n\r\n");
            // Refuse a bare LF in the head at once, rather than wait for a CRLF CRLF that never
            // comes. Bytes past the head are the body's, where an LF is just a byte (#36).
            const head_read = if (head_end) |index| index + "\r\n\r\n".len else slot.size;
            assert(head_read > size_before);
            for (bytes[size_before..head_read], size_before..) |byte, index| {
                if (byte == '\n' and (index == 0 or bytes[index - 1] != '\r')) {
                    return receiver.refuse(slot, "malformed request");
                }
            }
            const end = head_end orelse {
                if (slot.size == receiver.options.head_size_max) {
                    return receiver.refuse(slot, "request head too large");
                }
                return;
            };
            slot.head_size = @intCast(end + "\r\n\r\n".len);
            const head = head_parse(bytes[0..slot.head_size]) orelse
                return receiver.refuse(slot, "malformed request");
            if (head.content_length > receiver.options.body_size_max) {
                return receiver.refuse(slot, "body too large");
            }
            slot.head = head;
            // Bytes past the body (a second request) are not the server's to read.
            slot.size = @min(slot.size, slot.head_size + head.content_length);
            if (head.expect_continue and slot.size < slot.head_size + head.content_length) {
                receiver.write_all(slot.fd, "HTTP/1.1 100 Continue\r\n\r\n", slot.deadline) catch
                    return receiver.close(slot);
            }
        }
        if (slot.size == slot.head_size + slot.head.?.content_length) slot.state = .complete;
    }

    /// Answers 400 to a request that cannot be served, and closes the connection.
    fn refuse(receiver: *Receiver, slot: *Slot, comptime reason: []const u8) void {
        log.debug("refused: " ++ reason, .{});
        receiver.reply(slot, 400, "{\"error\":\"" ++ reason ++ "\"}");
        // Closing with unread bytes would reset the connection, which can discard the reply
        // before the client reads it: end the reply, then discard what has already arrived.
        posix.shutdown(slot.fd, .send) catch {};
        var discard: [4096]u8 = undefined;
        for (0..16) |_| {
            const count = posix.read(slot.fd, &discard) catch break;
            if (count == 0) break;
        }
        receiver.close(slot);
    }

    fn reply(receiver: *Receiver, slot: *Slot, status: u16, body: []const u8) void {
        assert(slot.state != .free);
        var head_buffer: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buffer, "HTTP/1.1 {d} {s}\r\n" ++
            "content-type: application/json\r\n" ++
            "content-length: {d}\r\n" ++
            "connection: close\r\n\r\n", .{
            status,
            reason_phrase(status),
            body.len,
        }) catch unreachable;
        const deadline = receiver.timer.read() + receiver.options.deadline_ns;
        receiver.write_all(slot.fd, head, deadline) catch |err|
            return log.debug("reply: {}", .{err});
        receiver.write_all(slot.fd, body, deadline) catch |err|
            return log.debug("reply: {}", .{err});
    }

    /// Writes all of `bytes` to a non-blocking socket by `deadline` (a `timer` reading).
    fn write_all(receiver: *Receiver, fd: posix.fd_t, bytes: []const u8, deadline: u64) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            written += posix.send(fd, bytes[written..], send_flags) catch |err|
                switch (err) {
                    error.WouldBlock => {
                        const now = receiver.timer.read();
                        if (now >= deadline) return error.Timeout;
                        var fds = [_]posix.pollfd{.{
                            .fd = fd,
                            .events = posix.POLL.OUT,
                            .revents = 0,
                        }};
                        _ = try posix.poll(&fds, milliseconds(deadline - now));
                        continue;
                    },
                    else => return err,
                };
        }
    }

    fn close(receiver: *Receiver, slot: *Slot) void {
        _ = receiver;
        assert(slot.state != .free);
        posix.close(slot.fd);
        slot.* = .{ .buffer = slot.buffer };
    }

    /// Closes every connection still reading past its deadline.
    fn expire(receiver: *Receiver) void {
        const now = receiver.timer.read();
        for (receiver.slots) |*slot| {
            if (slot.state == .reading and now >= slot.deadline) {
                log.debug("request not received within the deadline", .{});
                receiver.close(slot);
            }
        }
    }

    fn slot_free(receiver: *const Receiver) bool {
        for (receiver.slots) |*slot| {
            if (slot.state == .free) return true;
        }
        return false;
    }

    /// The connection accepted first among those still sending their request.
    fn oldest_reading(receiver: *const Receiver) ?u32 {
        var oldest: ?u32 = null;
        for (receiver.slots, 0..) |*slot, index| {
            if (slot.state != .reading) continue;
            if (oldest == null or slot.accepted < receiver.slots[oldest.?].accepted) {
                oldest = @intCast(index);
            }
        }
        return oldest;
    }

    fn oldest_complete(receiver: *const Receiver) ?u32 {
        var oldest: ?u32 = null;
        for (receiver.slots, 0..) |*slot, index| {
            if (slot.state != .complete) continue;
            if (oldest == null or slot.accepted < receiver.slots[oldest.?].accepted) {
                oldest = @intCast(index);
            }
        }
        return oldest;
    }

    fn slot_reading(receiver: *Receiver, fd: posix.fd_t) *Slot {
        for (receiver.slots) |*slot| {
            if (slot.state == .reading and slot.fd == fd) return slot;
        }
        unreachable;
    }
};

/// How old a connection still sending its request must be before a waiting one may displace it
/// (#28): a client that connects and then sends is not cut off in between.
const displace_grace_ns = 50 * std.time.ns_per_ms;

/// A write to a closed connection must fail, not kill the process. Zig's start code ignores
/// SIGPIPE on every target; Linux also gets `MSG_NOSIGNAL` (macOS has no such flag).
const send_flags: u32 = if (builtin.os.tag == .linux) posix.MSG.NOSIGNAL else 0;

/// A `poll` timeout: nanoseconds rounded up to milliseconds; null waits indefinitely.
fn milliseconds(ns: ?u64) i32 {
    const wait = ns orelse return -1;
    const ms = std.math.divCeil(u64, wait, std.time.ns_per_ms) catch unreachable;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

fn reason_phrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

const testing = std.testing;

test reason_phrase {
    // Every status the gateways answer has its phrase (RFC 9110), so no status line goes bare.
    for ([_]u16{ 200, 400, 401, 404, 405, 409, 413, 500, 503, 504 }) |status| {
        try testing.expect(reason_phrase(status).len > 0);
    }
    try testing.expectEqualStrings("Content Too Large", reason_phrase(413));
}

test head_parse {
    const valid = head_parse("POST /v1/commit HTTP/1.1\r\nHost: x\r\n" ++
        "X-Nerva-Key:  secret \r\nContent-Length: 12\r\nExpect: 100-continue\r\n\r\n").?;
    try testing.expectEqual(Method.post, valid.method);
    try testing.expectEqualStrings("/v1/commit", valid.target);
    try testing.expectEqualStrings("secret", valid.key.?);
    try testing.expectEqual(12, valid.content_length);
    try testing.expect(valid.expect_continue);

    const minimal = head_parse("DELETE /x HTTP/1.0\r\n\r\n").?;
    try testing.expectEqual(Method.other, minimal.method);
    try testing.expectEqual(null, minimal.key);
    try testing.expectEqual(0, minimal.content_length);

    const malformed = [_][]const u8{
        "GET / HTTP/1.1\n\n", // Bare LF.
        "POST /v1/lookupaa HTTP/1.1\r\n\n\r\n", // Bare LF ending the head (issue #8).
        "GET / HTTP/1.1\r\nA: b\rc\r\n\r\n", // Bare CR.
        "GET / HTTP/1.1\r\nA: b\x00c\r\n\r\n", // NUL.
        "GET / HTTP/1.1\r\nA: b\r\n folded\r\n\r\n", // Folded line.
        "GET / HTTP/1.1\r\nno colon\r\n\r\n",
        "GET / HTTP/1.1\r\n: no name\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: +5\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n",
        "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nX-Nerva-Key: a\r\nx-nerva-key: b\r\n\r\n",
        "GET / HTTP/1.1\r\nExpect: something\r\n\r\n",
        "GET / HTTP/2.0\r\n\r\n",
        "GET  / HTTP/1.1\r\n\r\n", // Two spaces.
        "GET x HTTP/1.1\r\n\r\n", // Target not absolute.
        "GET / HTTP/1.1\r\n", // Not ended by an empty line.
        "\r\n\r\n",
    };
    for (malformed) |head| {
        if (head_parse(head)) |_| {
            std.debug.print("accepted: {s}\n", .{head});
            return error.TestUnexpectedResult;
        }
    }
}

test key_matches {
    try testing.expect(key_matches("secret", "secret"));
    try testing.expect(!key_matches("secreT", "secret"));
    try testing.expect(!key_matches("secret2", "secret"));
    try testing.expect(!key_matches("", "secret"));
    try testing.expect(!key_matches(null, "secret"));
}

test key_accepted {
    const current_only: Keys = .{ .current = "current-key" };
    try testing.expect(key_accepted(current_only, "current-key"));
    try testing.expect(!key_accepted(current_only, "next-key"));
    try testing.expect(!key_accepted(current_only, ""));
    try testing.expect(!key_accepted(current_only, null));

    const rotating: Keys = .{ .current = "current-key", .next = "next-key" };
    try testing.expect(key_accepted(rotating, "current-key"));
    try testing.expect(key_accepted(rotating, "next-key"));
    try testing.expect(!key_accepted(rotating, "other-key"));
    try testing.expect(!key_accepted(rotating, "next-keY"));
    try testing.expect(!key_accepted(rotating, ""));
    try testing.expect(!key_accepted(rotating, null));
}

test "Keys.invalid" {
    try testing.expectEqual(null, Keys.invalid("current-key", null));
    try testing.expectEqual(null, Keys.invalid("current-key", "next-key"));
    try testing.expectEqualStrings("set NERVA_KEY", Keys.invalid("", null).?);
    try testing.expectEqualStrings("set NERVA_KEY", Keys.invalid("", "next-key").?);
    try testing.expect(Keys.invalid("current-key", "") != null);
    try testing.expectEqualStrings(
        "NERVA_KEY_NEXT equals NERVA_KEY",
        Keys.invalid("same-key", "same-key").?,
    );
}

fn test_connect(receiver: *const Receiver) !std.net.Stream {
    return std.net.tcpConnectToAddress(receiver.listen_address());
}

test "Receiver: a slow client holds up nobody, and is closed at its deadline" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 64, .deadline_ns = 200 * std.time.ns_per_ms },
    );
    defer receiver.deinit(testing.allocator);

    const slow = try test_connect(&receiver);
    defer slow.close();
    try slow.writeAll("GET /slow HTTP/1.1\r\n");

    const fast = try test_connect(&receiver);
    defer fast.close();
    try fast.writeAll("POST /fast HTTP/1.1\r\nContent-Length: 2\r\nX-Nerva-Key: k\r\n\r\nhi");

    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/fast", received.request.target);
    try testing.expectEqualStrings("k", received.request.key.?);
    try testing.expectEqualStrings("hi", received.request.body);
    receiver.respond(received, 200, "{}");
    var reply: [256]u8 = undefined;
    const reply_size = try fast.readAll(&reply);
    try testing.expect(std.mem.startsWith(u8, reply[0..reply_size], "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, reply[0..reply_size], "\r\n\r\n{}"));

    // The slow client never finishes: it is closed at its deadline, with no reply.
    try testing.expectEqual(null, try receiver.next(400));
    try testing.expectEqual(0, try slow.read(&reply));
}

test "Receiver: a body may hold LFs, though the head may not, when both arrive in one read" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 64 },
    );
    defer receiver.deinit(testing.allocator);

    // Head and a pretty-printed body in one write, as `curl -d` sends them (#36).
    const client = try test_connect(&receiver);
    defer client.close();
    try client.writeAll("POST /v1/lookup HTTP/1.1\r\nContent-Length: 13\r\n\r\n{\"rows\":[\n]}\n");
    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("{\"rows\":[\n]}\n", received.request.body);
    receiver.respond(received, 200, "{}");

    // A bare LF in the head is still refused, with a body behind it in the same read.
    const bare = try test_connect(&receiver);
    defer bare.close();
    try bare.writeAll("POST / HTTP/1.1\nContent-Length: 2\r\n\r\n{}");
    try testing.expectEqual(null, try receiver.next(100));
    var reply: [256]u8 = undefined;
    const reply_size = try bare.readAll(&reply);
    try testing.expect(std.mem.startsWith(u8, reply[0..reply_size], "HTTP/1.1 400 "));
    try testing.expect(std.mem.indexOf(u8, reply[0..reply_size], "malformed request") != null);
}

test "Receiver: malformed and oversized requests are refused with 400" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .head_size_max = 64, .body_size_max = 4 },
    );
    defer receiver.deinit(testing.allocator);

    const cases = [_][]const u8{
        "POST /v1/lookupaa HTTP/1.1\r\n\n\r\n",
        "GET / HTTP/1.1\r\nA: " ++ "a" ** 64,
        "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n",
    };
    const replies = [_][]const u8{
        "malformed request",
        "request head too large",
        "body too large",
    };
    for (cases, replies) |case, expected| {
        const client = try test_connect(&receiver);
        defer client.close();
        try client.writeAll(case);
        try testing.expectEqual(null, try receiver.next(100));
        var reply: [256]u8 = undefined;
        const reply_size = try client.readAll(&reply);
        try testing.expect(std.mem.startsWith(u8, reply[0..reply_size], "HTTP/1.1 400 "));
        try testing.expect(std.mem.indexOf(u8, reply[0..reply_size], expected) != null);
    }
}

test "Receiver: with every slot busy, a new connection displaces the oldest unfinished one" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 0 },
    );
    defer receiver.deinit(testing.allocator);

    // Two connections that send nothing hold both slots (#28).
    const idle_old = try test_connect(&receiver);
    defer idle_old.close();
    try testing.expectEqual(null, try receiver.next(50));
    const idle_new = try test_connect(&receiver);
    defer idle_new.close();
    try testing.expectEqual(null, try receiver.next(50));

    // A full request arrives: it is served at once, displacing the oldest idle connection.
    const client = try test_connect(&receiver);
    defer client.close();
    try client.writeAll("GET /served HTTP/1.1\r\n\r\n");
    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/served", received.request.target);
    receiver.respond(received, 200, "{}");

    var buffer: [16]u8 = undefined;
    try testing.expectEqual(0, try idle_old.read(&buffer)); // Closed.

    // The newer idle connection kept its slot, and can still send its request.
    try idle_new.writeAll("GET /later HTTP/1.1\r\n\r\n");
    const later = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/later", later.request.target);
    receiver.respond(later, 200, "{}");
}

fn test_target_commit(_: void, request: *const Request) bool {
    return std.mem.eql(u8, request.target, "/v1/commit");
}

test "Receiver.take hands out the requests already waiting that it is asked for, and waits for none (P143)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 8, .body_size_max = 64 },
    );
    defer receiver.deinit(testing.allocator);

    // Nothing is waiting: nothing is taken, at once.
    var taken: [8]Received = undefined;
    const start = receiver.timer.read();
    try testing.expectEqual(0, receiver.take({}, test_target_commit, &taken));
    try testing.expect(receiver.timer.read() - start < 50 * std.time.ns_per_ms);

    var clients: [6]std.net.Stream = undefined;
    for (&clients, 0..) |*client, index| {
        client.* = try test_connect(&receiver);
        if (index == 3) {
            try client.writeAll("GET /v1/other HTTP/1.1\r\n\r\n");
        } else {
            var request: [128]u8 = undefined;
            try client.writeAll(try std.fmt.bufPrint(
                &request,
                "POST /v1/commit HTTP/1.1\r\nContent-Length: 2\r\n\r\n{d}{d}",
                .{ index, index },
            ));
        }
    }
    defer for (clients) |client| client.close();

    // The first is handed out as before, the connections behind it are accepted and read by
    // `take`, oldest first, the one for another route left alone.
    const first = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("00", first.request.body);
    var count: usize = 0;
    // Some may still be on their way through the loopback: ask until all are in, but never wait.
    for (0..100) |_| {
        count += receiver.take({}, test_target_commit, taken[count..4]);
        if (count == 4) break;
        std.time.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(4, count);
    const bodies = [_][]const u8{ "11", "22", "44", "55" };
    for (taken[0..4], bodies) |one, body| try testing.expectEqualStrings(body, one.request.body);
    // Everything taken is answered.
    receiver.respond(first, 200, "{}");
    for (taken[0..4]) |one| receiver.respond(one, 200, "{}");
    var reply: [256]u8 = undefined;
    for ([_]usize{ 0, 1, 2, 4, 5 }) |index| {
        const size = try clients[index].readAll(&reply);
        try testing.expect(std.mem.startsWith(u8, reply[0..size], "HTTP/1.1 200 OK\r\n"));
    }
    // The other route is served as always.
    const other = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/v1/other", other.request.target);
    receiver.respond(other, 200, "{}");
}

test "Receiver.take never displaces a connection that is on its way (P143)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 64 },
    );
    defer receiver.deinit(testing.allocator);

    const served = try test_connect(&receiver);
    defer served.close();
    try served.writeAll("POST /v1/commit HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi");
    const first = (try receiver.next(1000)).?;

    // Another connection holds the second slot, its request still on its way; a third waits.
    const slow = try test_connect(&receiver);
    defer slow.close();
    var taken: [2]Received = undefined;
    for (0..20) |_| {
        try testing.expectEqual(0, receiver.take({}, test_target_commit, &taken));
        std.time.sleep(std.time.ns_per_ms);
    }
    const waiting = try test_connect(&receiver);
    defer waiting.close();
    for (0..20) |_| {
        try testing.expectEqual(0, receiver.take({}, test_target_commit, &taken));
        std.time.sleep(std.time.ns_per_ms);
    }
    // The slow one was not closed for the third: it can still send its request.
    try slow.writeAll("POST /v1/commit HTTP/1.1\r\nContent-Length: 2\r\n\r\nok");
    var count: usize = 0;
    for (0..100) |_| {
        count += receiver.take({}, test_target_commit, taken[count..]);
        if (count == 1) break;
        std.time.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(1, count);
    try testing.expectEqualStrings("ok", taken[0].request.body);
    receiver.respond(first, 200, "{}");
    receiver.respond(taken[0], 200, "{}");

    // With the slots free again, the third is served.
    try waiting.writeAll("POST /v1/commit HTTP/1.1\r\nContent-Length: 2\r\n\r\nno");
    const third = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("no", third.request.body);
    receiver.respond(third, 200, "{}");
}

test "Receiver: a connection that has only just arrived is not displaced before it can send (P143)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 64 },
    );
    defer receiver.deinit(testing.allocator);

    const young_a = try test_connect(&receiver);
    defer young_a.close();
    const young_b = try test_connect(&receiver);
    defer young_b.close();
    try testing.expectEqual(null, try receiver.next(10));

    // Both slots are held by connections that are about to send, a third waits with its request.
    const waiting = try test_connect(&receiver);
    defer waiting.close();
    try waiting.writeAll("GET /waiting HTTP/1.1\r\n\r\n");
    try testing.expectEqual(null, try receiver.next(10));
    try young_a.writeAll("GET /a HTTP/1.1\r\n\r\n");
    const a = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/a", a.request.target);
    receiver.respond(a, 200, "{}");

    // Its slot goes to the waiting one.
    const waited = (try receiver.next(2000)).?;
    try testing.expectEqualStrings("/waiting", waited.request.target);
    receiver.respond(waited, 200, "{}");
}
