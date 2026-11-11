//! How Nerva's HTTP gateways (`api`, `view`) receive requests and send replies
//! (docs/DECISIONS.md N37, N45).
//!
//! A gateway executes one request at a time, but reads requests from up to `connections_max`
//! connections at once, so a client that sends its request slowly, or never, holds up nobody.
//! With every slot busy, a new connection displaces the oldest one that has sent nothing yet
//! (N58): holding slots open with idle connections cannot lock others out (#28). A connection that
//! has sent bytes is never displaced (#120): a newcomer that cannot be placed is answered
//! `503 busy` unread. Nothing is closed without a status line (P168b, P168c): a refusal, a
//! displacement and a missed deadline (`408`) are written, then the connection lingers for a
//! moment (`linger_ns`), discarding what the client still sends, so that closing it cannot
//! reset the connection and destroy the reply.
//! Each connection carries one request (replies say `connection: close`), which must arrive
//! whole within `deadline_ns` of the connection being accepted; the reply is written within the
//! same budget, counted afresh. The gateway listens on a socket of its own, without
//! `SO_REUSEPORT`: a second gateway on the port is refused (#112). Request heads are parsed strictly (`head_parse`): anything
//! malformed answers 400 rather than being guessed at. Replies are sent without Nagle's delay
//! (`TCP_NODELAY`).

const std = @import("std");
const builtin = @import("builtin");
const peer_auth = @import("peer_auth.zig");
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

/// The value `packaging/linux/api.env.example` ships for `NERVA_KEY`: published in this
/// repository, so it is refused (#306).
pub const placeholder_key = "replace-with-a-long-random-key";

/// The shortest gateway key: the cluster key's own minimum (`peer_auth.key_length_min`, #335).
/// `openssl rand -hex 32` makes 64 characters.
pub const key_length_min = peer_auth.key_length_min;

/// A gateway's keys (P96): `X-Nerva-Key` must equal `current` or, during a rotation, `next`.
pub const Keys = struct {
    current: []const u8,
    next: ?[]const u8 = null,

    /// Why `NERVA_KEY` (`current`) and `NERVA_KEY_NEXT` (`next`) cannot be used, if they cannot:
    /// each set key is at least `key_length_min` bytes and not the placeholder, and `next` differs
    /// from `current`. The message names no key.
    pub fn invalid(current: []const u8, next: ?[]const u8) ?[]const u8 {
        if (current.len == 0) return "set NERVA_KEY";
        if (current.len < key_length_min) return "NERVA_KEY is shorter than 32 bytes";
        if (std.mem.eql(u8, current, placeholder_key)) {
            return "NERVA_KEY is the example's placeholder: " ++
                "make a key with openssl rand -hex 32";
        }
        const key_next = next orelse return null;
        if (key_next.len == 0) return "NERVA_KEY_NEXT is set but empty";
        if (key_next.len < key_length_min) return "NERVA_KEY_NEXT is shorter than 32 bytes";
        if (std.mem.eql(u8, key_next, placeholder_key)) {
            return "NERVA_KEY_NEXT is the example's placeholder: " ++
                "make a key with openssl rand -hex 32";
        }
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

const metrics = @import("api/metrics.zig");

pub const Options = struct {
    /// Connections read at once. A further connection displaces the oldest one that has sent
    /// nothing, or is refused `503 busy` if every connection has sent bytes.
    connections_max: u32,
    head_size_max: u32 = 16 * 1024,
    body_size_max: u32,
    /// From accept to the request's last byte; and, afresh, for writing the reply.
    deadline_ns: u64 = 10 * std.time.ns_per_s,
    /// How long a connection that was answered and shut lingers, at most (`linger_ns`).
    linger_ns: u64 = linger_ns_default,
    /// How many answered connections linger at once, at most `linger_max`.
    linger_entries_max: u32 = linger_max,
    /// How long a complete request waits for the caller to take it (`next`, `take`) before it
    /// is refused `503 busy` (NRV-E0602, `queue_wait_max`).
    queue_wait_ns: u64 = queue_wait_ns_default,
    /// What the receiver counts for a gateway's metrics (`api/metrics.zig`); `nerva view` has none.
    counters: ?*metrics.Counters = null,
};

/// How long a complete request may wait to be taken: past it nothing was applied, and the
/// client is told to resend (R4, P168b).
pub const queue_wait_ns_default = std.time.ns_per_s;

/// Connections the kernel queues for `accept` (was Zig's default, 128). Past it the kernel drops
/// the SYN: the client's connect fails, nothing was sent.
pub const listen_backlog: u31 = 128;
/// Connections refused in one wake of the poll loop: no more than can be waiting.
pub const refusals_per_wake_max: u32 = listen_backlog;
/// Answered connections that linger at once: as many as one wake can refuse
/// (`refusals_per_wake_max`), so that a burst of newcomers is not closed on while it still sends
/// (a close with a request unread resets the connection, and the client may never read its
/// reply: R4 slice 2, `tests/api/busy.py`). A further one is closed as soon as its reply is
/// written, and counted in `Receiver.lingering_dropped`.
pub const linger_max = refusals_per_wake_max;
/// How long an answered connection lingers at most: a loopback client's request has arrived by
/// then.
pub const linger_ns_default = std.time.ns_per_s;
/// How much a lingering connection may still send before it is closed: the most a refused
/// client's request can be, as the gateways see it.
pub const linger_bytes_max = 64 * 1024;

/// What a connection is told when it cannot be taken (NRV-E0602): nothing reached the cluster.
pub const busy_body = "{\"error\":\"busy\",\"applied\":false,\"code\":\"NRV-E0602\"}";
/// What a connection is told when its request did not arrive whole in time (NRV-E0116).
pub const deadline_body = "{\"error\":\"request not received within 10 s\"," ++
    "\"applied\":false,\"code\":\"NRV-E0116\"}";

/// A complete request, handed out by `Receiver.next` and valid until `Receiver.respond`.
pub const Received = struct {
    slot: u32,
    request: Request,
};

/// Accepts connections and reads their requests concurrently; hands out complete requests one at
/// a time, oldest connection first. All memory is allocated in `init`.
pub const Receiver = struct {
    options: Options,
    /// The listening socket (non-blocking), and the address it is bound to.
    listen_fd: posix.socket_t,
    address: std.net.Address,
    timer: std.time.Timer,
    slots: []Slot,
    /// One entry per slot reading, one per lingering connection, and the listening socket.
    poll_fds: []posix.pollfd,
    /// Connections accepted so far: orders slots, oldest first.
    accepted_count: u64 = 0,
    /// Connections that were answered and shut, and are read until they close (`shut`).
    lingering: [linger_max]Lingering = undefined,
    lingering_count: u32 = 0,
    /// Answers whose connection could not linger because the table was full: closed at once.
    lingering_dropped: u64 = 0,

    const Lingering = struct {
        fd: posix.fd_t,
        /// A `timer` reading.
        deadline: u64,
        /// Bytes discarded so far.
        bytes: u32,
    };

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
        /// A `timer` reading: when the request became complete.
        completed: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, listen: std.net.Address, options: Options) !Receiver {
        assert(options.connections_max > 0);
        assert(options.head_size_max >= 64);
        assert(options.deadline_ns > 0);
        assert(options.linger_entries_max <= linger_max);

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
        const poll_fds = try gpa.alloc(posix.pollfd, options.connections_max + linger_max + 1);
        errdefer gpa.free(poll_fds);

        // The gateway's own socket: `SO_REUSEADDR` so that a restart does not wait out
        // TIME_WAIT, never `SO_REUSEPORT`, which would let a second gateway bind the same port
        // and share its connections (#112). Bound twice, the second `bind` is `AddressInUse`.
        const listen_fd = try posix.socket(
            listen.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(listen_fd);
        try posix.setsockopt(
            listen_fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        var address = listen;
        var address_size = address.getOsSockLen();
        try posix.bind(listen_fd, &address.any, address_size);
        try posix.listen(listen_fd, listen_backlog);
        try posix.getsockname(listen_fd, &address.any, &address_size);
        return .{
            .options = options,
            .listen_fd = listen_fd,
            .address = address,
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
        for (receiver.lingering[0..receiver.lingering_count]) |entry| posix.close(entry.fd);
        gpa.free(receiver.slots);
        gpa.free(receiver.poll_fds);
        posix.close(receiver.listen_fd);
    }

    pub fn listen_address(receiver: *const Receiver) std.net.Address {
        return receiver.address;
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
                // With every slot taken, a newcomer waits in the kernel's queue, silent: look
                // at the listening socket once, so that it is told `busy` now.
                if (!receiver.slot_free()) _ = try receiver.poll(0, .displace);
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
            for (receiver.lingering[0..receiver.lingering_count]) |entry| {
                const left = entry.deadline -| now;
                wait_ns = if (wait_ns) |wait| @min(wait, left) else left;
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
        if (receiver.options.counters) |counters| {
            counters.waited(receiver.timer.read() -| slot.completed);
        }
        const request = receiver.request_of(slot);
        slot.state = .serving;
        return .{ .slot = index, .request = request };
    }

    /// One `poll` over the connections still reading, the lingering ones and the listening
    /// socket, waiting at most `wait_ns` (null: until there is activity), and the work it finds:
    /// accepting, reading, discarding. With every slot taken, a waiting connection displaces the
    /// oldest one that has sent nothing once that one is `displace_grace_ns` old (`.displace`,
    /// #28); if every connection has sent bytes it is refused `503 busy` instead, unread, and no
    /// connection that has sent bytes is ever displaced (#120). With `.keep` the listening
    /// socket is not even looked at when every slot is taken, so that requests being served are
    /// never preferred over a connection that is on its way. Returns how many descriptors were
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
        const slots_end = fds_count;
        for (receiver.lingering[0..receiver.lingering_count]) |entry| {
            receiver.poll_fds[fds_count] = .{ .fd = entry.fd, .events = posix.POLL.IN, .revents = 0 };
            fds_count += 1;
        }
        const lingering_end = fds_count;
        // The listening socket, and last: with every slot busy, a waiting connection displaces
        // the oldest one that has sent nothing (#28), or is refused. Last, so that a slot closed
        // for it has had its own events handled before its fd can be reused.
        const listening = receiver.slot_free() or full == .displace and listening: {
            // A silent connection that has only just arrived may be about to send: it is
            // displaced only when it has had its grace, and the wait ends then.
            const silent = receiver.oldest_silent() orelse break :listening true;
            const accepted_ns = receiver.slots[silent].deadline - receiver.options.deadline_ns;
            const now = receiver.timer.read();
            if (now >= accepted_ns + displace_grace_ns) break :listening true;
            const left = accepted_ns + displace_grace_ns - now;
            wait_ns = if (wait_ns) |wait| @min(wait, left) else left;
            break :listening false;
        };
        if (listening) {
            receiver.poll_fds[fds_count] = .{
                .fd = receiver.listen_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            fds_count += 1;
        }
        if (fds_count == 0) return 0;
        assert(fds_count <= receiver.poll_fds.len);
        const ready = try posix.poll(receiver.poll_fds[0..fds_count], milliseconds(wait_ns));
        if (ready == 0) return 0;

        for (receiver.poll_fds[0..fds_count], 0..) |poll_fd, index| {
            if (poll_fd.revents == 0) continue;
            if (index < slots_end) {
                receiver.read(receiver.slot_reading(poll_fd.fd));
            } else if (index < lingering_end) {
                receiver.linger_read(poll_fd.fd);
            } else if (receiver.slot_free()) {
                receiver.accept();
            } else if (receiver.oldest_silent()) |silent| {
                // Every slot taken, and one holds a connection that has sent nothing in its
                // grace: it is told, and its slot goes to the one waiting.
                log.debug("every slot busy: displacing the oldest silent connection", .{});
                receiver.shut(&receiver.slots[silent], 503, busy_body, .displaced);
                receiver.accept();
            } else {
                receiver.refuse_waiting();
            }
        }
        return ready;
    }

    /// Writes the reply to a request handed out by `next`, then closes its connection.
    pub fn respond(receiver: *Receiver, received: Received, status: u16, body: []const u8) void {
        _ = receiver.respond_written(received, status, body);
    }

    /// Like `respond`; true if the whole reply was written (the peer may still not read it).
    pub fn respond_written(
        receiver: *Receiver,
        received: Received,
        status: u16,
        body: []const u8,
    ) bool {
        const slot = &receiver.slots[received.slot];
        assert(slot.state == .serving);
        const written = receiver.reply(slot, status, body);
        receiver.close(slot);
        return written;
    }

    /// Accepts one waiting connection, non-blocking; null if none is, or it was lost.
    fn accept_fd(receiver: *Receiver) ?posix.fd_t {
        return posix.accept(
            receiver.listen_fd,
            null,
            null,
            posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        ) catch |err| {
            switch (err) {
                error.WouldBlock, error.ConnectionAborted => {},
                else => log.warn("accept: {}", .{err}),
            }
            return null;
        };
    }

    fn accept(receiver: *Receiver) void {
        const slot = for (receiver.slots) |*slot| {
            if (slot.state == .free) break slot;
        } else unreachable; // The caller made sure there is one.
        const fd = receiver.accept_fd() orelse return;
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
        if (receiver.options.counters) |counters| counters.connections_seen(receiver.slots_in_use());
    }

    /// Slots holding a connection now, at most as many as there are slots.
    pub fn slots_in_use(receiver: *const Receiver) u32 {
        var in_use: u32 = 0;
        for (receiver.slots) |other| in_use += @intFromBool(other.state != .free);
        assert(in_use <= receiver.slots.len);
        return in_use;
    }

    /// With every slot holding a connection that has sent bytes: answers the connections
    /// waiting `503 busy` without reading a byte of them, and without a slot, at most
    /// `refusals_per_wake_max` (#120).
    fn refuse_waiting(receiver: *Receiver) void {
        for (0..refusals_per_wake_max) |_| {
            const fd = receiver.accept_fd() orelse return;
            log.debug("every slot busy: refusing a new connection", .{});
            receiver.linger(fd, 503, busy_body, .busy);
        }
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
                    return receiver.refuse(slot, 400, "malformed request", "NRV-E0101");
                }
            }
            const end = head_end orelse {
                if (slot.size == receiver.options.head_size_max) {
                    return receiver.refuse(slot, 400, "request head too large", "NRV-E0101");
                }
                return;
            };
            slot.head_size = @intCast(end + "\r\n\r\n".len);
            const head = head_parse(bytes[0..slot.head_size]) orelse
                return receiver.refuse(slot, 400, "malformed request", "NRV-E0101");
            if (head.content_length > receiver.options.body_size_max) {
                return receiver.refuse(slot, 413, "body too large", "NRV-E0102");
            }
            slot.head = head;
            // Bytes past the body (a second request) are not the server's to read.
            slot.size = @min(slot.size, slot.head_size + head.content_length);
            if (head.expect_continue and slot.size < slot.head_size + head.content_length) {
                receiver.write_all(slot.fd, "HTTP/1.1 100 Continue\r\n\r\n", slot.deadline) catch
                    return receiver.close(slot);
            }
        }
        if (slot.size == slot.head_size + slot.head.?.content_length) {
            slot.state = .complete;
            slot.completed = receiver.timer.read();
        }
    }

    /// Answers `status` (400, or 413 for a body too large) to a request that cannot be served,
    /// and shuts the connection (`shut`).
    fn refuse(
        receiver: *Receiver,
        slot: *Slot,
        comptime status: u16,
        comptime reason: []const u8,
        comptime code: []const u8,
    ) void {
        log.debug("refused: " ++ reason, .{});
        const body = "{\"error\":\"" ++ reason ++ "\",\"applied\":false,\"code\":\"" ++
            code ++ "\"}";
        receiver.shut(slot, status, body, if (status == 413) .too_large else .malformed);
    }

    /// Answers the request in `slot` (still being read, or complete and not yet taken) with
    /// `status` and `body` (short, written without waiting), ends the reply, and frees the
    /// slot. The connection lingers (`linger`): nothing is closed without a status line.
    fn shut(
        receiver: *Receiver,
        slot: *Slot,
        status: u16,
        body: []const u8,
        reason: metrics.RefusalReason,
    ) void {
        assert(slot.state == .reading or slot.state == .complete);
        receiver.linger(slot.fd, status, body, reason);
        slot.* = .{ .buffer = slot.buffer };
    }

    /// Writes the reply on `fd`, shuts down its send side and moves it to the `lingering` table,
    /// where what the client still sends is discarded until it closes, `linger_ns` have passed
    /// or `linger_bytes_max` have arrived. Closing at once instead, with a request unread,
    /// would reset the connection, which can discard the reply before the client reads it. With
    /// the table full the reply is still written, the connection is closed and counted.
    fn linger(
        receiver: *Receiver,
        fd: posix.fd_t,
        status: u16,
        body: []const u8,
        reason: metrics.RefusalReason,
    ) void {
        var message: [512]u8 = undefined;
        assert(body.len <= 256);
        const head = std.fmt.bufPrint(&message, "HTTP/1.1 {d} {s}\r\n" ++
            "content-type: application/json\r\n" ++
            "content-length: {d}\r\n" ++
            "connection: close\r\n\r\n", .{ status, reason_phrase(status), body.len }) catch unreachable;
        @memcpy(message[head.len..][0..body.len], body);
        // One send into a connection that has been sent nothing: it fits the socket's buffer.
        const sent = posix.send(fd, message[0 .. head.len + body.len], send_flags) catch 0;
        if (sent == head.len + body.len) {
            // Counted only if written, as `answer` does.
            if (receiver.options.counters) |counters| counters.refusal_written(reason, status);
        } else {
            log.debug("refusal: not written whole ({d} bytes)", .{sent});
        }
        posix.shutdown(fd, .send) catch {};
        if (receiver.lingering_count == receiver.options.linger_entries_max) {
            receiver.lingering_dropped += 1;
            return posix.close(fd);
        }
        receiver.lingering[receiver.lingering_count] = .{
            .fd = fd,
            .deadline = receiver.timer.read() + receiver.options.linger_ns,
            .bytes = 0,
        };
        receiver.lingering_count += 1;
    }

    /// Discards what a lingering connection has sent; closes it when the client has closed too,
    /// or has sent `linger_bytes_max`.
    fn linger_read(receiver: *Receiver, fd: posix.fd_t) void {
        const index = for (receiver.lingering[0..receiver.lingering_count], 0..) |entry, index| {
            if (entry.fd == fd) break index;
        } else unreachable;
        const entry = &receiver.lingering[index];
        var discard: [4096]u8 = undefined;
        // Each read takes at least a byte of the allowance.
        for (0..linger_bytes_max) |_| {
            const count = posix.read(fd, &discard) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return receiver.linger_close(index),
            };
            if (count == 0) return receiver.linger_close(index);
            entry.bytes += @intCast(count);
            if (entry.bytes >= linger_bytes_max) return receiver.linger_close(index);
        }
        unreachable;
    }

    fn linger_close(receiver: *Receiver, index: usize) void {
        assert(index < receiver.lingering_count);
        posix.close(receiver.lingering[index].fd);
        receiver.lingering_count -= 1;
        receiver.lingering[index] = receiver.lingering[receiver.lingering_count];
    }

    fn reply(receiver: *Receiver, slot: *Slot, status: u16, body: []const u8) bool {
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
        receiver.write_all(slot.fd, head, deadline) catch |err| {
            log.debug("reply: {}", .{err});
            return false;
        };
        receiver.write_all(slot.fd, body, deadline) catch |err| {
            log.debug("reply: {}", .{err});
            return false;
        };
        return true;
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

    /// Answers `408` to every connection still reading past its deadline (NRV-E0116), `503 busy`
    /// to every complete request that has waited `queue_wait_ns` to be taken (NRV-E0602), and
    /// closes the lingering connections past theirs.
    fn expire(receiver: *Receiver) void {
        const now = receiver.timer.read();
        for (receiver.slots) |*slot| {
            if (slot.state == .reading and now >= slot.deadline) {
                log.debug("request not received within the deadline", .{});
                receiver.shut(slot, 408, deadline_body, .deadline);
            } else if (slot.state == .complete and
                now - slot.completed >= receiver.options.queue_wait_ns)
            {
                log.debug("request not taken within the queue wait", .{});
                receiver.shut(slot, 503, busy_body, .queue_wait);
            }
        }
        var index: usize = receiver.lingering_count;
        while (index > 0) {
            index -= 1;
            if (now >= receiver.lingering[index].deadline) receiver.linger_close(index);
        }
    }

    fn slot_free(receiver: *const Receiver) bool {
        for (receiver.slots) |*slot| {
            if (slot.state == .free) return true;
        }
        return false;
    }

    /// The connection accepted first among those that have sent nothing yet.
    fn oldest_silent(receiver: *const Receiver) ?u32 {
        var oldest: ?u32 = null;
        for (receiver.slots, 0..) |*slot, index| {
            if (slot.state != .reading or slot.size > 0) continue;
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

const test_key_a = "a" ** 32;
const test_key_b = "b" ** 32;
const test_key_b_case = "b" ** 31 ++ "B";
const test_key_other = "c" ** 32;

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
    const current_only: Keys = .{ .current = test_key_a };
    try testing.expect(key_accepted(current_only, test_key_a));
    try testing.expect(!key_accepted(current_only, test_key_b));
    try testing.expect(!key_accepted(current_only, ""));
    try testing.expect(!key_accepted(current_only, null));

    const rotating: Keys = .{ .current = test_key_a, .next = test_key_b };
    try testing.expect(key_accepted(rotating, test_key_a));
    try testing.expect(key_accepted(rotating, test_key_b));
    try testing.expect(!key_accepted(rotating, test_key_other));
    try testing.expect(!key_accepted(rotating, test_key_b_case));
    try testing.expect(!key_accepted(rotating, ""));
    try testing.expect(!key_accepted(rotating, null));
}

test "Keys.invalid" {
    try testing.expectEqual(null, Keys.invalid(test_key_a, null));
    try testing.expectEqual(null, Keys.invalid(test_key_a, test_key_b));
    try testing.expectEqualStrings("set NERVA_KEY", Keys.invalid("", null).?);
    try testing.expectEqualStrings("set NERVA_KEY", Keys.invalid("", test_key_b).?);
    try testing.expect(Keys.invalid(test_key_a, "") != null);
    try testing.expectEqualStrings(
        "NERVA_KEY_NEXT equals NERVA_KEY",
        Keys.invalid(test_key_a, test_key_a).?,
    );
    // #335: a key shorter than 32 bytes is refused, as current or as next; 32 is accepted.
    try testing.expectEqualStrings(
        "NERVA_KEY is shorter than 32 bytes",
        Keys.invalid(test_key_a[1..], null).?,
    );
    try testing.expectEqualStrings(
        "NERVA_KEY_NEXT is shorter than 32 bytes",
        Keys.invalid(test_key_a, test_key_b[1..]).?,
    );
    try testing.expectEqual(null, Keys.invalid(test_key_a, test_key_b));
    // #306: the example's published placeholder is refused, as current or as next.
    try testing.expectEqualStrings(
        "NERVA_KEY is the example's placeholder: make a key with openssl rand -hex 32",
        Keys.invalid(placeholder_key, null).?,
    );
    try testing.expectEqualStrings(
        "NERVA_KEY_NEXT is the example's placeholder: make a key with openssl rand -hex 32",
        Keys.invalid(test_key_a, placeholder_key).?,
    );
    // No message names a key.
    for ([_]?[]const u8{
        Keys.invalid(placeholder_key, null),
        Keys.invalid(test_key_a, placeholder_key),
    }) |message| {
        try testing.expect(std.mem.indexOf(u8, message.?, placeholder_key) == null);
        try testing.expect(std.mem.indexOf(u8, message.?, test_key_a) == null);
    }
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

    // The slow client never finishes: it is answered 408 at its deadline (NRV-E0116), and
    // closed after that.
    try testing.expectEqual(null, try receiver.next(400));
    const slow_size = try slow.readAll(&reply);
    try expect_refusal(reply[0..slow_size], 408, "NRV-E0116");
}

/// `reply` is a whole refusal: a status line with `status`, and a body that says nothing was
/// applied and carries `code`.
fn expect_refusal(reply: []const u8, status: u16, code: []const u8) !void {
    var prefix: [32]u8 = undefined;
    try testing.expect(std.mem.startsWith(
        u8,
        reply,
        try std.fmt.bufPrint(&prefix, "HTTP/1.1 {d} ", .{status}),
    ));
    try testing.expect(std.mem.indexOf(u8, reply, "\"applied\":false") != null);
    var expected: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expected, "\"code\":\"{s}\"", .{code});
    try testing.expect(std.mem.indexOf(u8, reply, needle) != null);
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

test "Receiver: malformed requests are refused with 400, and a body too large with 413" {
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
    const codes = [_][]const u8{ "NRV-E0101", "NRV-E0101", "NRV-E0102" };
    const statuses = [_]u16{ 400, 400, 413 };
    for (cases, replies, codes, statuses) |case, expected, code, status| {
        const client = try test_connect(&receiver);
        defer client.close();
        try client.writeAll(case);
        try testing.expectEqual(null, try receiver.next(100));
        var reply: [256]u8 = undefined;
        const reply_size = try client.readAll(&reply);
        try testing.expect(std.mem.indexOf(u8, reply[0..reply_size], expected) != null);
        try expect_refusal(reply[0..reply_size], status, code);
    }
}

test "Receiver: with every slot busy, a new connection displaces the oldest silent one" {
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

    // The displaced connection is told why before it is closed.
    var buffer: [256]u8 = undefined;
    const told = try idle_old.readAll(&buffer);
    try expect_refusal(buffer[0..told], 503, "NRV-E0602");
    try testing.expect(std.mem.indexOf(u8, buffer[0..told], "\"error\":\"busy\"") != null);

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

/// Sends `bytes` of a request head that never ends, on a new connection.
fn test_partial(receiver: *const Receiver) !std.net.Stream {
    const client = try test_connect(receiver);
    errdefer client.close();
    try client.writeAll("POST /v1/commit HTTP/1.1\r\nContent-Length: 2\r\n");
    return client;
}

test "Receiver: with every slot holding a partial request, a newcomer is refused busy, and no request is lost (#120)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 16, .body_size_max = 8 },
    );
    defer receiver.deinit(testing.allocator);

    // Step 1: sixteen clients have sent the first part of their requests.
    var partial: [16]std.net.Stream = undefined;
    var connected: usize = 0;
    defer for (partial[0..connected]) |client| client.close();
    for (&partial) |*client| {
        client.* = try test_partial(&receiver);
        connected += 1;
    }
    try testing.expectEqual(null, try receiver.next(100));

    // Step 2: a seventeenth asks for /healthz. It reads 503 busy, without a slot, at once.
    const seventeenth = try test_connect(&receiver);
    defer seventeenth.close();
    try seventeenth.writeAll("GET /healthz HTTP/1.1\r\n\r\n");
    try testing.expectEqual(null, try receiver.next(100));
    var reply: [256]u8 = undefined;
    const size = try seventeenth.readAll(&reply);
    try expect_refusal(reply[0..size], 503, "NRV-E0602");
    try testing.expectEqual(0, receiver.lingering_dropped);

    // Step 3: none of the sixteen was displaced: all finish, and are served.
    for (partial) |client| try client.writeAll("\r\nhi");
    for (0..16) |_| {
        const received = (try receiver.next(1000)).?;
        try testing.expectEqualStrings("hi", received.request.body);
        receiver.respond(received, 200, "{}");
    }
    for (partial) |client| {
        const done = try client.readAll(&reply);
        try testing.expect(std.mem.startsWith(u8, reply[0..done], "HTTP/1.1 200 OK\r\n"));
    }
}

test "Receiver: sixteen silent connections and a seventeenth: the oldest is told busy, the new one is served" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 16, .body_size_max = 8 },
    );
    defer receiver.deinit(testing.allocator);

    var silent: [16]std.net.Stream = undefined;
    var connected: usize = 0;
    defer for (silent[0..connected]) |client| client.close();
    for (&silent) |*client| {
        client.* = try test_connect(&receiver);
        connected += 1;
    }
    try testing.expectEqual(null, try receiver.next(100));

    const newcomer = try test_connect(&receiver);
    defer newcomer.close();
    try newcomer.writeAll("GET /served HTTP/1.1\r\n\r\n");
    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/served", received.request.target);
    receiver.respond(received, 200, "{}");

    // Only the oldest silent connection was displaced, and it was told.
    var reply: [256]u8 = undefined;
    const size = try silent[0].readAll(&reply);
    try expect_refusal(reply[0..size], 503, "NRV-E0602");
    // The others still hold their slots and can send.
    try silent[1].writeAll("GET /second HTTP/1.1\r\n\r\n");
    const second = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/second", second.request.target);
    receiver.respond(second, 200, "{}");
}

fn test_reject_all(_: void, _: *const Request) bool {
    return false;
}

test "Receiver: a complete request not taken within the queue wait is refused busy (NRV-E0602)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 4, .body_size_max = 0, .queue_wait_ns = 50 * std.time.ns_per_ms },
    );
    defer receiver.deinit(testing.allocator);

    const first = try test_connect(&receiver);
    defer first.close();
    try first.writeAll("GET /first HTTP/1.1\r\n\r\n");
    const second = try test_connect(&receiver);
    defer second.close();
    try second.writeAll("GET /second HTTP/1.1\r\n\r\n");

    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/first", received.request.target);
    // Read what has arrived: the second request is complete, and waits for the caller.
    var none: [1]Received = undefined;
    for (0..4) |_| _ = receiver.take({}, test_reject_all, &none);
    std.time.sleep(80 * std.time.ns_per_ms);
    receiver.respond(received, 200, "{}");

    try testing.expectEqual(null, try receiver.next(0));
    var reply: [256]u8 = undefined;
    const reply_size = try second.readAll(&reply);
    try expect_refusal(reply[0..reply_size], 503, "NRV-E0602");
    var first_reply: [256]u8 = undefined;
    const first_size = try first.readAll(&first_reply);
    try testing.expect(std.mem.startsWith(u8, first_reply[0..first_size], "HTTP/1.1 200 "));
}

test "Receiver: a newcomer behind complete requests is refused busy while one is taken" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 0 },
    );
    defer receiver.deinit(testing.allocator);

    const first = try test_connect(&receiver);
    defer first.close();
    try first.writeAll("GET /first HTTP/1.1\r\n\r\n");
    const second = try test_connect(&receiver);
    defer second.close();
    try second.writeAll("GET /second HTTP/1.1\r\n\r\n");
    var none: [1]Received = undefined;
    for (0..4) |_| _ = receiver.take({}, test_reject_all, &none);
    // Both slots hold complete requests; the third connection waits in the kernel's queue.
    const third = try test_connect(&receiver);
    defer third.close();

    const received = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/first", received.request.target);
    var reply: [256]u8 = undefined;
    const reply_size = try third.readAll(&reply);
    try expect_refusal(reply[0..reply_size], 503, "NRV-E0602");
    receiver.respond(received, 200, "{}");
    // The second request, whole and not stale, is still served.
    const next = (try receiver.next(1000)).?;
    try testing.expectEqualStrings("/second", next.request.target);
    receiver.respond(next, 200, "{}");
}

test "Receiver: a drip is answered 408 at the deadline, though it kept sending (NRV-E0116)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 2, .body_size_max = 8, .deadline_ns = 300 * std.time.ns_per_ms },
    );
    defer receiver.deinit(testing.allocator);

    const drip = try test_connect(&receiver);
    defer drip.close();
    try drip.writeAll("GET /healthz HTTP/1.1\r\n");
    const start = receiver.timer.read();
    var reply: [256]u8 = undefined;
    var size: usize = 0;
    while (receiver.timer.read() - start < 2 * std.time.ns_per_s) {
        // A byte at a time, until the 408 arrives.
        drip.writeAll("x") catch break;
        try testing.expectEqual(null, try receiver.next(50));
        var fds = [_]posix.pollfd{.{ .fd = drip.handle, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 0) == 0) continue;
        size = try drip.readAll(&reply);
        break;
    }
    try expect_refusal(reply[0..size], 408, "NRV-E0116");
    // Not before the deadline.
    try testing.expect(receiver.timer.read() - start >= 300 * std.time.ns_per_ms);
}

test "Receiver: a refused client that sends a body still reads its 503, at the lingering bound" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 1, .body_size_max = 8 },
    );
    defer receiver.deinit(testing.allocator);
    const holder = try test_partial(&receiver);
    defer holder.close();
    try testing.expectEqual(null, try receiver.next(100));

    // A request of exactly `linger_bytes_max`, head and body: all of it is discarded, so closing
    // does not reset the connection.
    const head = "POST /v1/commit HTTP/1.1\r\nContent-Length: 65000\r\n\r\n";
    var request: [linger_bytes_max]u8 = undefined;
    @memset(&request, 'x');
    @memcpy(request[0..head.len], head);
    const client = try test_connect(&receiver);
    defer client.close();
    try client.writeAll(&request);
    try testing.expectEqual(null, try receiver.next(200));
    var reply: [256]u8 = undefined;
    const size = try client.readAll(&reply);
    try expect_refusal(reply[0..size], 503, "NRV-E0602");
    // It was read to the bound and closed: nothing lingers.
    try testing.expectEqual(0, receiver.lingering_count);
    try testing.expectEqual(0, receiver.lingering_dropped);

    // One past the bound: still closed when the allowance is spent. (The client may see a reset
    // for the bytes left unread; it is not promised the reply, and the unknown is safe under a
    // key.)
    const past = try test_connect(&receiver);
    defer past.close();
    var big: [linger_bytes_max + 4096]u8 = undefined;
    @memset(&big, 'x');
    past.writeAll(&big) catch {};
    try testing.expectEqual(null, try receiver.next(200));
    try testing.expectEqual(0, receiver.lingering_count);
}

fn socket_pair() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    // Linux builds without libc and calls the kernel; macOS always links libSystem and has no
    // such wrapper in `std.os` (#278).
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
        try testing.expectEqual(@as(usize, 0), rc);
    } else {
        const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
        try testing.expectEqual(@as(c_int, 0), rc);
    }
    return fds;
}

test "Receiver: a refusal is counted only when it was written whole" {
    var counters: metrics.Counters = .{};
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 1, .body_size_max = 8, .counters = &counters },
    );
    defer receiver.deinit(testing.allocator);
    const busy = @intFromEnum(metrics.RefusalReason.busy);

    // The sending side is shut: the send fails, so nothing is counted.
    const shut = try socket_pair();
    defer posix.close(shut[1]);
    try posix.shutdown(shut[0], .send);
    receiver.linger(shut[0], 503, busy_body, .busy);
    try testing.expectEqual(@as(u64, 0), counters.refused[busy]);

    // An open one is written whole and counted.
    const open = try socket_pair();
    defer posix.close(open[1]);
    receiver.linger(open[0], 503, busy_body, .busy);
    try testing.expectEqual(@as(u64, 1), counters.refused[busy]);
}

test "Receiver: a second Receiver on the same port is refused (#112)" {
    var first = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{ .connections_max = 1, .body_size_max = 8 },
    );
    defer first.deinit(testing.allocator);
    const taken = first.listen_address();
    try testing.expect(taken.getPort() != 0);
    try testing.expectError(error.AddressInUse, Receiver.init(
        testing.allocator,
        taken,
        .{ .connections_max = 1, .body_size_max = 8 },
    ));
}

const lingering_test_max = 16;

test "Receiver: sixteen connections linger, a seventeenth is closed at once, and all end (linger_entries_max)" {
    var receiver = try Receiver.init(
        testing.allocator,
        try std.net.Address.parseIp("127.0.0.1", 0),
        .{
            .connections_max = 1,
            .body_size_max = 8,
            .linger_ns = 300 * std.time.ns_per_ms,
            .linger_entries_max = lingering_test_max,
        },
    );
    defer receiver.deinit(testing.allocator);
    const holder = try test_partial(&receiver);
    defer holder.close();
    try testing.expectEqual(null, try receiver.next(100));

    // Seventeen newcomers that send nothing and do not close are all refused, and all read
    // their 503; sixteen linger.
    var newcomers: [lingering_test_max + 1]std.net.Stream = undefined;
    var connected: usize = 0;
    defer for (newcomers[0..connected]) |client| client.close();
    for (&newcomers) |*client| {
        client.* = try test_connect(&receiver);
        connected += 1;
    }
    try testing.expectEqual(null, try receiver.next(100));
    var reply: [256]u8 = undefined;
    for (newcomers) |client| {
        const size = try client.readAll(&reply);
        try expect_refusal(reply[0..size], 503, "NRV-E0602");
    }
    try testing.expectEqual(lingering_test_max, receiver.lingering_count);
    try testing.expectEqual(1, receiver.lingering_dropped);

    // They are let go after `linger_ns`, closing their end of the connection.
    try testing.expectEqual(null, try receiver.next(500));
    try testing.expectEqual(0, receiver.lingering_count);

    // Sixteen exactly: none is dropped.
    var again: [lingering_test_max]std.net.Stream = undefined;
    var again_connected: usize = 0;
    defer for (again[0..again_connected]) |client| client.close();
    for (&again) |*client| {
        client.* = try test_connect(&receiver);
        again_connected += 1;
    }
    try testing.expectEqual(null, try receiver.next(100));
    try testing.expectEqual(lingering_test_max, receiver.lingering_count);
    try testing.expectEqual(1, receiver.lingering_dropped);
}

test "Receiver: the codes it writes are registered in docs/ERRORS.md" {
    const text = try std.fs.cwd().readFileAlloc(testing.allocator, "docs/ERRORS.md", 1 << 20);
    defer testing.allocator.free(text);
    for ([_][]const u8{ busy_body, deadline_body }) |body| {
        const start = std.mem.indexOf(u8, body, "NRV-").?;
        const row = try std.fmt.allocPrint(testing.allocator, "| {s} | ", .{body[start..][0..9]});
        defer testing.allocator.free(row);
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
    for ([_][]const u8{ "NRV-E0101", "NRV-E0102" }) |code| {
        const row = try std.fmt.allocPrint(testing.allocator, "| {s} | ", .{code});
        defer testing.allocator.free(row);
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
}
