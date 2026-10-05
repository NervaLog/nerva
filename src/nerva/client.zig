//! A blocking Nerva client: one VSR session, one request in flight, all memory allocated in
//! `init`. Each call drives the client's own event loop until the reply arrives, the session is
//! evicted, or `Options.timeout` passes.
//!
//! After `error.Timeout` the request may still commit; the client must not be used again
//! (only `deinit`).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.nerva_client);

const stdx = @import("stdx");
const vsr = @import("../vsr.zig");
const constants = @import("../constants.zig");
const nerva = @import("../nerva.zig");
const IO = @import("../io.zig").IO;
const MessageBus = @import("../message_bus.zig").MessageBusType(IO);
const MessagePool = @import("../message_pool.zig").MessagePool;
const Message = MessagePool.Message;
const MultiBatchDecoder = vsr.multi_batch.MultiBatchDecoder;
const MultiBatchEncoder = vsr.multi_batch.MultiBatchEncoder;

const Operation = nerva.Operation;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const ChangesFilter = nerva.ChangesFilter;
const HistoryFilter = nerva.HistoryFilter;
const Change = nerva.Change;
const ViewDefinition = nerva.ViewDefinition;
const DeclareResult = nerva.DeclareResult;
const ViewQuery = nerva.ViewQuery;
const ViewRecord = nerva.ViewRecord;

const VSRClient = vsr.ClientType(Operation, MessageBus);

comptime {
    // Replicas read `previous_request_latency` as nanoseconds from releases before 0.17.0, and
    // as microseconds from 0.17.0 on (`replica.zig`); `Client.send` sends nanoseconds.
    assert(constants.config.process.release.value <
        vsr.Release.from(.{ .major = 0, .minor = 17, .patch = 0 }).value);
}
const Body = [constants.message_body_size_max]u8;

/// Changes per `get_history` call in `row_as_of`.
const history_page_limit = 64;

pub const Client = struct {
    pub const Options = struct {
        cluster: u128,
        /// Every replica's address, in replica index order.
        addresses: []const stdx.SocketAddress,
        /// How long a call (including registration) may wait for its reply.
        timeout: stdx.Duration,
    };

    pub const Error = error{
        /// The cluster evicted this client's session; create a new client.
        Evicted,
        /// No reply within `Options.timeout`. The request may still commit.
        Timeout,
        /// More events than fit in one request.
        TooManyEvents,
    };

    allocator: std.mem.Allocator,
    options: Options,
    io: IO,
    time_os: stdx.TimeOS,
    message_pool: MessagePool,
    vsr_client: VSRClient,

    state: enum { registering, idle, waiting, timed_out, evicted },
    /// The reply to the request in flight, copied out of the message bus.
    reply: *align(constants.cache_line_size) Body,
    reply_size: ?usize,
    request: *align(constants.cache_line_size) Body,
    /// The previous request's round trip, sent with the next request so that the primary
    /// records it as `client_request_round_trip` (0 until a request has completed).
    latency_previous_ns: u32,

    /// Connects and registers a session; blocks until registered.
    pub fn init(client: *Client, allocator: std.mem.Allocator, options: Options) !void {
        assert(options.addresses.len > 0);
        assert(options.addresses.len <= constants.replicas_max);

        client.* = .{
            .allocator = allocator,
            .options = options,
            .io = try IO.init(32, 0),
            .time_os = .{},
            .message_pool = undefined,
            .vsr_client = undefined,
            .state = .registering,
            .reply = undefined,
            .reply_size = null,
            .request = undefined,
            .latency_previous_ns = 0,
        };
        errdefer client.io.deinit();

        client.message_pool = try MessagePool.init(allocator, .client);
        errdefer client.message_pool.deinit(allocator);

        client.reply = try body_alloc(allocator);
        errdefer allocator.free(client.reply[0..]);
        client.request = try body_alloc(allocator);
        errdefer allocator.free(client.request[0..]);

        client.vsr_client = try VSRClient.init(
            allocator,
            client.time_os.interface(),
            &client.message_pool,
            .{
                .id = stdx.crypto_u128(),
                .cluster = options.cluster,
                .replica_count = @intCast(options.addresses.len),
                .aof_recovery = false,
                .message_bus_options = .{
                    .configuration = options.addresses,
                    .io = &client.io,
                    .trace = null,
                    .time = client.time_os.interface(),
                },
                .eviction_callback = on_eviction,
            },
        );
        errdefer client.vsr_client.deinit(allocator);

        client.vsr_client.register(on_register, @intFromPtr(client));
        try client.run_until_reply();
        assert(client.state == .idle);
        assert(client.vsr_client.batch_size_limit.? > 0);
    }

    /// Replaces a client that timed out or was evicted with a new session, in place, so that
    /// references to it stay valid (#27). On failure the client is uninitialized: call `init`
    /// again, never `deinit`.
    pub fn reconnect(client: *Client) !void {
        assert(client.state == .timed_out or client.state == .evicted);
        const allocator = client.allocator;
        const options = client.options;
        client.deinit();
        try client.init(allocator, options);
    }

    pub fn deinit(client: *Client) void {
        const allocator = client.allocator;
        if (client.state != .evicted) {
            // Close connections gracefully, bounded by the timeout.
            client.vsr_client.shutdown();
            const start = client.time_os.monotonic();
            var tick_next = start;
            while (!client.vsr_client.shutdown_complete()) {
                if (start.elapsed(client.time_os.monotonic()).ns > client.options.timeout.ns) break;
                client.run_io_once(start, &tick_next) catch break;
            }
        }
        // An evicted VSR client must process no more messages, so its IO is not driven again
        // (#52): every call returned `error.Evicted` since.
        client.vsr_client.deinit(allocator);
        allocator.free(client.request[0..]);
        allocator.free(client.reply[0..]);
        client.message_pool.deinit(allocator);
        client.io.deinit();
        client.* = undefined;
    }

    /// Point reads. `results.len == keys.len`.
    pub fn lookup_rows(client: *Client, keys: []const RowKey, results: []RowValue) Error!void {
        assert(results.len == keys.len);
        const reply = try client.execute_multi_batch(.lookup_rows, std.mem.sliceAsBytes(keys));
        stdx.copy_disjoint(.exact, RowValue, results, stdx.bytes_as_slice(.exact, RowValue, reply));
    }

    /// Commits one transaction. `results.len == entries.len`.
    pub fn commit(client: *Client, entries: []const Entry, results: []EntryResult) Error!void {
        assert(results.len == entries.len);
        const reply = try client.execute_multi_batch(.commit, std.mem.sliceAsBytes(entries));
        stdx.copy_disjoint(
            .exact,
            EntryResult,
            results,
            stdx.bytes_as_slice(.exact, EntryResult, reply),
        );
    }

    /// Reads the change feed. `changes.len` must hold `filter.limit` changes plus the `end`
    /// record. Returns the number of records written (zero if the filter is invalid).
    pub fn get_changes(client: *Client, filter: ChangesFilter, changes: []Change) Error!usize {
        assert(changes.len >= @min(
            filter.limit +| 1,
            Operation.get_changes.result_max(constants.message_body_size_max),
        ));
        try client.ensure_idle();
        const body = std.mem.asBytes(&filter);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.get_changes, client.request[0..body.len]);
        try client.run_until_reply();

        const reply = stdx.bytes_as_slice(.exact, Change, client.reply[0..client.reply_size.?]);
        assert(reply.len <= changes.len);
        stdx.copy_disjoint(.exact, Change, changes[0..reply.len], reply);
        return reply.len;
    }

    /// Reads one row's history, newest first (see `HistoryFilter`). `changes.len` must hold
    /// `filter.limit` changes plus the `end` record. Returns the number of records written (zero
    /// if the filter is invalid).
    pub fn get_history(client: *Client, filter: HistoryFilter, changes: []Change) Error!usize {
        assert(changes.len >= @min(
            filter.limit +| 1,
            Operation.get_history.result_max(constants.message_body_size_max),
        ));
        try client.ensure_idle();
        const body = std.mem.asBytes(&filter);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.get_history, client.request[0..body.len]);
        try client.run_until_reply();

        const reply = stdx.bytes_as_slice(.exact, Change, client.reply[0..client.reply_size.?]);
        assert(reply.len <= changes.len);
        stdx.copy_disjoint(.exact, Change, changes[0..reply.len], reply);
        return reply.len;
    }

    /// Declares a view, maintained from then on by every commit (N52).
    pub fn declare_view(client: *Client, definition: *const ViewDefinition) Error!DeclareResult {
        try client.ensure_idle();
        const body = std.mem.asBytes(definition);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.declare_view, client.request[0..body.len]);
        try client.run_until_reply();
        const reply = stdx.bytes_as_slice(
            .exact,
            DeclareResult,
            client.reply[0..client.reply_size.?],
        );
        assert(reply.len == 1);
        return reply[0];
    }

    /// A view's latest state (the header record) and a page of its groups (N52). `records.len`
    /// must hold `query.limit` groups plus the header. Returns the number of records written
    /// (zero if the query is invalid).
    pub fn get_view(client: *Client, query: ViewQuery, records: []ViewRecord) Error!usize {
        assert(records.len >= @min(
            query.limit +| 1,
            Operation.get_view.result_max(constants.message_body_size_max),
        ));
        try client.ensure_idle();
        const body = std.mem.asBytes(&query);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.get_view, client.request[0..body.len]);
        try client.run_until_reply();

        const reply = stdx.bytes_as_slice(.exact, ViewRecord, client.reply[0..client.reply_size.?]);
        assert(reply.len <= records.len);
        stdx.copy_disjoint(.exact, ViewRecord, records[0..reply.len], reply);
        return reply.len;
    }

    /// The row as it was at `op` (G6): its last change at or before `op`, or null if it did not
    /// exist then (never written, or deleted). Pages through changes made after `op`.
    pub fn row_as_of(client: *Client, table: u32, id: u64, op: u64) Error!?Change {
        assert(table != 0);
        assert(op != 0);
        var page: [history_page_limit + 1]Change = undefined;
        var timestamp_max: u64 = 0;
        while (true) {
            const count = try client.get_history(.{
                .table = table,
                .id = id,
                .limit = history_page_limit,
                .op_max = op,
                .timestamp_max = timestamp_max,
            }, &page);
            assert(count >= 1);
            const end = page[count - 1];
            assert(end.kind == .end);
            if (count > 1) {
                const change = page[0];
                assert(change.op <= op);
                return if (change.kind == .put) change else null;
            }
            if (!end.flags.more) return null;
            assert(end.timestamp != 0);
            timestamp_max = end.timestamp;
        }
    }

    /// Sends `events` as a single batch and returns that batch's results.
    fn execute_multi_batch(
        client: *Client,
        comptime operation: Operation,
        events: []const u8,
    ) Error![]const u8 {
        comptime assert(operation.is_multi_batch());
        // Refused before the client is marked busy, so that it can serve the next request.
        const batch_size_limit = client.vsr_client.batch_size_limit.?;
        const event_count = @divExact(events.len, operation.event_size());
        if (event_count > operation.event_max(batch_size_limit)) return error.TooManyEvents;
        try client.ensure_idle();

        var encoder = MultiBatchEncoder.init(client.request[0..batch_size_limit], .{
            .element_size = operation.event_size(),
        });
        stdx.copy_disjoint(.inexact, u8, encoder.writable().?, events);
        encoder.add(@intCast(events.len));
        const body_size = encoder.finish();

        client.send(operation, client.request[0..body_size]);
        try client.run_until_reply();

        var decoder = MultiBatchDecoder.init(client.reply[0..client.reply_size.?], .{
            .element_size = operation.result_size(),
        }) catch unreachable; // The replica encoded it.
        assert(decoder.batch_count() == 1);
        const results = decoder.pop().?;
        assert(results.len == event_count * operation.result_size());
        return results;
    }

    /// Like `vsr.Client.request`, but the header carries the previous round trip.
    fn send(client: *Client, operation: Operation, events: []const u8) void {
        assert(client.state == .waiting);
        assert(events.len % operation.event_size() == 0);
        assert(events.len <= client.vsr_client.batch_size_limit.?);

        const message = client.vsr_client.get_message().build(.request);
        message.header.* = .{
            .client = client.vsr_client.id,
            .request = 0, // Set by `raw_request`.
            .cluster = client.options.cluster,
            .command = .request,
            .release = client.vsr_client.release,
            .operation = operation.to_vsr(),
            .size = @intCast(@sizeOf(vsr.Header) + events.len),
            .previous_request_latency = client.latency_previous_ns,
        };
        stdx.copy_disjoint(.exact, u8, message.body_used(), events);
        client.vsr_client.raw_request(on_reply, @intFromPtr(client), message);
    }

    fn ensure_idle(client: *Client) Error!void {
        switch (client.state) {
            .idle => {},
            .evicted => return error.Evicted,
            .timed_out => return error.Timeout,
            .registering, .waiting => unreachable, // One request at a time.
        }
        client.state = .waiting;
        client.reply_size = null;
    }

    /// Drives the event loop until the request in flight is answered.
    fn run_until_reply(client: *Client) Error!void {
        assert(client.state == .registering or client.state == .waiting);
        const start = client.time_os.monotonic();
        var tick_next = start;
        while (true) {
            switch (client.state) {
                .idle => {
                    // Saturates past 4.29 s, which a primary still records as a slow round trip.
                    client.latency_previous_ns =
                        std.math.lossyCast(u32, start.elapsed(client.time_os.monotonic()).ns);
                    return;
                },
                .evicted => return error.Evicted,
                .registering, .waiting => {},
                .timed_out => unreachable,
            }
            if (start.elapsed(client.time_os.monotonic()).ns > client.options.timeout.ns) {
                client.state = .timed_out;
                return error.Timeout;
            }
            client.run_io_once(start, &tick_next) catch |err| {
                log.err("io: {}", .{err});
                client.state = .timed_out;
                return error.Timeout;
            };
        }
    }

    /// Ticks the VSR client every `tick_ms` (its timeouts count ticks), then waits for IO until
    /// the next tick or the call's deadline, and returns as soon as any callback has run. The
    /// reply callback therefore ends a wait at once, rather than at the end of a 10 ms tick.
    fn run_io_once(client: *Client, start: stdx.Instant, tick_next: *stdx.Instant) !void {
        const tick: stdx.Duration = .{ .ns = constants.tick_ms * std.time.ns_per_ms };
        const now = client.time_os.monotonic();
        if (now.ns >= tick_next.ns) {
            client.vsr_client.tick();
            tick_next.* = now.add(tick);
        }
        const deadline = start.add(client.options.timeout);
        const wait_until = if (deadline.ns < tick_next.ns) deadline else tick_next.*;
        // At least 1 ns: `run_once` always waits (a zero wait is `IO.run`'s job).
        const wait_ns: u63 = @intCast(@max(wait_until.ns -| now.ns, 1));
        try client.io.run_once(wait_ns);
    }

    fn on_register(user_data: u128, result: *const vsr.RegisterResult) void {
        const client: *Client = @ptrFromInt(@as(usize, @intCast(user_data)));
        assert(client.state == .registering);
        assert(result.batch_size_limit > 0);
        client.state = .idle;
    }

    fn on_reply(
        user_data: u128,
        operation: vsr.Operation,
        timestamp: u64,
        result: []align(constants.cache_line_size) const u8,
    ) void {
        _ = operation;
        _ = timestamp;
        const client: *Client = @ptrFromInt(@as(usize, @intCast(user_data)));
        if (client.state == .timed_out) {
            // The reply to a request this client gave up on, arriving while `deinit` closes its
            // connections (#42): nobody waits for it.
            log.debug("on_reply: dropping a reply after the timeout", .{});
            return;
        }
        assert(client.state == .waiting);
        assert(client.reply_size == null);
        stdx.copy_disjoint(.inexact, u8, client.reply, result);
        client.reply_size = result.len;
        client.state = .idle;
    }

    fn on_eviction(vsr_client: *VSRClient, eviction: *const Message.Eviction) void {
        const client: *Client = @fieldParentPtr("vsr_client", vsr_client);
        log.warn("evicted: {s}", .{@tagName(eviction.header.reason)});
        // The VSR client's contract asks the callback to deinit it, but the callback runs inside
        // the message bus's receive path, which goes on to use the buffer `deinit` would free
        // (#52). `Client.deinit` deinits it instead; the evicted VSR client processes no more
        // messages because nothing drives its IO until then.
        client.state = .evicted;
    }

    fn body_alloc(allocator: std.mem.Allocator) !*align(constants.cache_line_size) Body {
        const bytes = try allocator.alignedAlloc(u8, constants.cache_line_size, @sizeOf(Body));
        return bytes[0..@sizeOf(Body)];
    }
};

test "Client: a reply after the timeout is dropped (#42)" {
    // Only the fields `on_reply` reads are set: it must not touch the rest.
    var client: Client = undefined;
    client.state = .timed_out;
    client.reply_size = null;
    const result = [_]u8{0} ** constants.cache_line_size;
    const aligned: []align(constants.cache_line_size) const u8 = @alignCast(&result);
    Client.on_reply(@intFromPtr(&client), .register, 0, aligned);
    try std.testing.expectEqual(.timed_out, client.state);
    try std.testing.expectEqual(null, client.reply_size);
}
