//! A blocking Nerva client: one VSR session, one request in flight, all memory allocated in
//! `init`. Each call drives the client's own event loop until the reply arrives, the session is
//! evicted, or `Options.timeout` passes (or, inside a `window_open`, the window ends).
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
const timings = @import("timings.zig");
const release_eviction = @import("release_eviction.zig");
const IO = @import("../io.zig").IO;
const MessageBus = @import("../message_bus.zig").MessageBusType(IO);
const MessagePool = @import("../message_pool.zig").MessagePool;
const MessageBuffer = @import("../message_buffer.zig").MessageBuffer;
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

/// The most batches one multi-batch request holds from this client (`nerva api` combines at most
/// as many requests).
pub const batches_max = 16;

/// Changes per `get_history` call in `row_as_of`.
const history_page_limit = 64;

/// `Options.timeout` over this is the time a window must have left for a call to be sent.
pub const window_remaining_divisor = 16;
comptime {
    assert(window_remaining_divisor > 1);
}

pub const Client = struct {
    pub const Options = struct {
        cluster: u128,
        /// Every replica's address, in replica index order.
        addresses: []const stdx.SocketAddress,
        /// How long a call (including registration) may wait for its reply.
        timeout: stdx.Duration,
        /// Where a gateway reads what this client counts (`timings.zig`). It outlives the client,
        /// which is replaced when it breaks, and a replacement can fail; none: nothing is counted.
        tally: ?*timings.Tally = null,
        /// When set (`window_open`), no call waits past it: a request that makes several calls,
        /// and a reconnection, is answered within `timeout` in all (#186). Null: each call has
        /// its own `timeout`.
        window_end: ?stdx.Instant = null,
    };

    pub const Error = error{
        /// The cluster evicted this client's session; create a new client.
        Evicted,
        /// No reply within `Options.timeout` (or by the window's end). The request may still
        /// commit.
        Timeout,
        /// The request's window (`window_open`) was spent, or had less than a sixteenth of
        /// `Options.timeout` left (P209), before this call was sent: nothing was sent and the
        /// session is as it was.
        Expired,
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
    /// Requests of a write (`Operation.is_write`) sent so far, whether or not answered. A gateway
    /// compares it before and after a request: unchanged, nothing was applied; changed and no
    /// reply, the write may have been (NRV-E0601).
    writes_sent: u64,
    /// The operation whose request is in flight.
    sending: ?Operation,

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
            .writes_sent = 0,
            .sending = null,
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
        const writes_sent = client.writes_sent;
        client.deinit();
        try client.init(allocator, options);
        // A count a gateway took before the request still compares with it.
        client.writes_sent = writes_sent;
    }

    /// Starts one deadline, `Options.timeout` from now, for every call until `window_close`; a
    /// call that passes it is `error.Timeout`. A gateway opens it when a request arrives. Returns
    /// the deadline, for a client that is replaced meanwhile (`Options.window_end`).
    pub fn window_open(client: *Client) stdx.Instant {
        assert(client.options.window_end == null);
        assert(client.sending == null);
        const end = client.time_os.monotonic().add(client.options.timeout);
        client.options.window_end = end;
        return end;
    }

    pub fn window_close(client: *Client) void {
        assert(client.options.window_end != null);
        client.options.window_end = null;
    }

    /// The least time a request's window must have left for a call to be sent: a sixteenth of
    /// `Options.timeout` (P209). A round trip to a healthy cluster takes a few ticks; a call
    /// started with less than this left would most likely time out, break the session and leave
    /// the write's outcome unknown, where refusing it (`Expired`) costs the client a resend.
    fn window_remaining_min(client: *const Client) stdx.Duration {
        const remaining: stdx.Duration = .{
            .ns = client.options.timeout.ns / window_remaining_divisor,
        };
        assert(remaining.ns > 0);
        assert(remaining.ns < client.options.timeout.ns);
        return remaining;
    }

    /// When the call that began at `start` gives up. A window opened before the call ends no
    /// later than the call's own timeout.
    fn deadline(client: *const Client, start: stdx.Instant) stdx.Instant {
        return client.options.window_end orelse start.add(client.options.timeout);
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

    /// Point reads of several requests at once, one batch each, in one op: `results[i].len ==
    /// keys[i].len`. Each batch is read at the same op (`op_read`).
    pub fn lookup_rows_batches(
        client: *Client,
        keys: []const []const RowKey,
        results: []const []RowValue,
    ) Error!void {
        return client.execute_batches(.lookup_rows, RowKey, RowValue, keys, results);
    }

    /// Commits several transactions at once, one batch each, in one op. The state machine
    /// admits them in order, each on its own: one that cannot commit does not stop the rest.
    /// `results[i].len == transactions[i].len`.
    pub fn commit_batches(
        client: *Client,
        transactions: []const []const Entry,
        results: []const []EntryResult,
    ) Error!void {
        return client.execute_batches(.commit, Entry, EntryResult, transactions, results);
    }

    /// As `commit_batches`, for transactions of rows and records.
    pub fn commit_wide_batches(
        client: *Client,
        transactions: []const []const nerva.WideEntry,
        results: []const []EntryResult,
    ) Error!void {
        return client.execute_batches(.commit_wide, nerva.WideEntry, EntryResult, transactions, results);
    }

    /// Whether batches of `counts` events each fit one request of `operation`: its events and
    /// trailer in the batch size limit, each batch within `event_max`, and the replies and their
    /// trailer in a message (the replicas' `input_valid`). `execute_batches` refuses what does not.
    pub fn batches_fit(client: *const Client, comptime operation: Operation, counts: []const u32) bool {
        comptime assert(operation.is_multi_batch());
        if (counts.len == 0 or counts.len > batches_max) return false;
        const limit = client.vsr_client.batch_size_limit.?;
        var events: u64 = 0;
        for (counts) |count| {
            if (count == 0 or count > operation.event_max(limit)) return false;
            events += count;
        }
        const batch_count: u16 = @intCast(counts.len);
        const request_size = events * operation.event_size() + vsr.multi_batch.trailer_total_size(.{
            .element_size = operation.event_size(),
            .batch_count = batch_count,
        });
        const reply_size = events * operation.result_size() + vsr.multi_batch.trailer_total_size(.{
            .element_size = operation.result_size(),
            .batch_count = batch_count,
        });
        return request_size <= std.mem.alignBackward(u32, limit, 2) and
            reply_size <= constants.message_body_size_max;
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

    /// Declares a ledger: a set of conserved fields that only pairs of adds change (N75).
    pub fn declare_ledger(
        client: *Client,
        definition: *const nerva.LedgerDefinition,
    ) Error!nerva.DeclareLedgerResult {
        try client.ensure_idle();
        const body = std.mem.asBytes(definition);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.declare_ledger, client.request[0..body.len]);
        try client.run_until_reply();
        const reply = stdx.bytes_as_slice(
            .exact,
            nerva.DeclareLedgerResult,
            client.reply[0..client.reply_size.?],
        );
        assert(reply.len == 1);
        return reply[0];
    }

    /// A ledger's declaration and the op it was declared at; all zero if `id` is not declared.
    pub fn get_ledger(client: *Client, id: u32) Error!nerva.Ledger {
        assert(id != 0);
        return client.get_ledger_query(.{ .id = id });
    }

    /// The ledger declared `slot`th (from 1); all zero if fewer were declared (N80).
    pub fn get_ledger_slot(client: *Client, slot: u64) Error!nerva.Ledger {
        assert(slot != 0);
        return client.get_ledger_query(.{ .id = 0, .slot = slot });
    }

    fn get_ledger_query(client: *Client, query: nerva.LedgerQuery) Error!nerva.Ledger {
        try client.ensure_idle();
        const body = std.mem.asBytes(&query);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(.get_ledger, client.request[0..body.len]);
        try client.run_until_reply();
        const reply = stdx.bytes_as_slice(
            .exact,
            nerva.Ledger,
            client.reply[0..client.reply_size.?],
        );
        assert(reply.len == 1);
        return reply[0];
    }

    // ---- Records and indexes (P123b, P123c) ----

    /// Commits one transaction of rows and records. `results.len == entries.len`.
    pub fn commit_wide(
        client: *Client,
        entries: []const nerva.WideEntry,
        results: []EntryResult,
    ) Error!void {
        assert(results.len == entries.len);
        const reply = try client.execute_multi_batch(.commit_wide, std.mem.sliceAsBytes(entries));
        stdx.copy_disjoint(
            .exact,
            EntryResult,
            results,
            stdx.bytes_as_slice(.exact, EntryResult, reply),
        );
    }

    /// Point reads of records. `results.len == keys.len`.
    pub fn lookup_records(
        client: *Client,
        keys: []const nerva.RecordKey,
        results: []nerva.RecordValue,
    ) Error!void {
        assert(results.len == keys.len);
        const reply =
            try client.execute_multi_batch(.lookup_records, std.mem.sliceAsBytes(keys));
        stdx.copy_disjoint(
            .exact,
            nerva.RecordValue,
            results,
            stdx.bytes_as_slice(.exact, nerva.RecordValue, reply),
        );
    }

    /// Reads records' change feed, as `get_changes` reads rows'.
    pub fn get_record_changes(
        client: *Client,
        filter: ChangesFilter,
        changes: []nerva.RecordChange,
    ) Error!usize {
        return client.execute_one(.get_record_changes, &filter, changes);
    }

    /// Reads one record's history, newest first, as `get_history` reads a row's.
    pub fn get_record_history(
        client: *Client,
        filter: nerva.RecordHistoryFilter,
        changes: []nerva.RecordChange,
    ) Error!usize {
        return client.execute_one(.get_record_history, &filter, changes);
    }

    pub fn declare_index(
        client: *Client,
        definition: *const nerva.IndexDefinition,
    ) Error!nerva.DeclareIndexResult {
        var result: [1]nerva.DeclareIndexResult = undefined;
        assert(try client.execute_one(.declare_index, definition, &result) == 1);
        return result[0];
    }

    /// A page of an index: the header record, then the records. `records.len` must hold
    /// `query.limit` records plus the header. Returns the number written (zero if the query is
    /// invalid).
    pub fn scan_index(
        client: *Client,
        query: nerva.IndexQuery,
        records: []nerva.IndexRecord,
    ) Error!usize {
        return client.execute_one(.scan_index, &query, records);
    }

    /// The index with this id; all zero if none.
    pub fn get_index(client: *Client, id: u64) Error!nerva.Index {
        var result: [1]nerva.Index = undefined;
        assert(try client.execute_one(.get_index, &nerva.IndexGet{ .id = id }, &result) == 1);
        return result[0];
    }

    /// Sends one event of a single-event operation; copies its results out.
    fn execute_one(
        client: *Client,
        comptime operation: Operation,
        event: *const operation.EventType(),
        results: []operation.ResultType(),
    ) Error!usize {
        try client.ensure_idle();
        const body = std.mem.asBytes(event);
        stdx.copy_disjoint(.exact, u8, client.request[0..body.len], body);
        client.send(operation, client.request[0..body.len]);
        try client.run_until_reply();
        const Result = operation.ResultType();
        const reply = stdx.bytes_as_slice(.exact, Result, client.reply[0..client.reply_size.?]);
        assert(reply.len <= results.len);
        stdx.copy_disjoint(.exact, Result, results[0..reply.len], reply);
        return reply.len;
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

    /// Sends each of `batches` as one batch of a single request of `operation`, and copies each
    /// batch's results out. Every batch is non-empty.
    fn execute_batches(
        client: *Client,
        comptime operation: Operation,
        comptime Event: type,
        comptime Result: type,
        batches: []const []const Event,
        results: []const []Result,
    ) Error!void {
        comptime assert(operation.is_multi_batch());
        comptime assert(@sizeOf(Event) == operation.event_size());
        comptime assert(@sizeOf(Result) == operation.result_size());
        assert(batches.len == results.len);
        assert(batches.len > 0);
        var counts_buffer: [batches_max]u32 = undefined;
        if (batches.len > batches_max) return error.TooManyEvents;
        for (batches, results, counts_buffer[0..batches.len]) |batch, result, *count| {
            assert(batch.len == result.len);
            count.* = @intCast(batch.len);
        }
        // Refused before the client is marked busy, so that it can serve the next request.
        if (!client.batches_fit(operation, counts_buffer[0..batches.len])) {
            return error.TooManyEvents;
        }
        try client.ensure_idle();

        const batch_size_limit = client.vsr_client.batch_size_limit.?;
        var encoder = MultiBatchEncoder.init(client.request[0..batch_size_limit], .{
            .element_size = operation.event_size(),
        });
        for (batches) |batch| {
            const bytes = std.mem.sliceAsBytes(batch);
            stdx.copy_disjoint(.inexact, u8, encoder.writable().?, bytes);
            encoder.add(@intCast(bytes.len));
        }
        const body_size = encoder.finish();

        client.send(operation, client.request[0..body_size]);
        try client.run_until_reply();

        var decoder = MultiBatchDecoder.init(client.reply[0..client.reply_size.?], .{
            .element_size = operation.result_size(),
        }) catch unreachable; // The replica encoded it.
        assert(decoder.batch_count() == batches.len);
        for (results) |result| {
            const reply = decoder.pop().?;
            stdx.copy_disjoint(.exact, Result, result, stdx.bytes_as_slice(.exact, Result, reply));
        }
        assert(decoder.pop() == null);
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
        assert(client.sending == null);
        assert(events.len % operation.event_size() == 0);
        assert(events.len <= client.vsr_client.batch_size_limit.?);

        if (client.options.tally) |tally| tally.requests += 1;
        client.sending = operation;
        if (operation.is_write()) client.writes_sent += 1;
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
        // Before anything is queued: a call that has too little time left is not sent (#186,
        // #205), so its write is known not to have gone, and the session is kept.
        if (client.state == .idle) {
            if (client.options.window_end) |end| {
                const now = client.time_os.monotonic();
                if (now.ns +| client.window_remaining_min().ns > end.ns) return error.Expired;
            }
        }
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
        defer if (client.sending) |operation| {
            // A reply, an eviction or a timeout ends a round trip.
            if (client.options.tally) |tally| {
                const elapsed = start.elapsed(client.time_os.monotonic());
                tally.operations.getPtr(operation).record(elapsed.ns);
            }
            client.sending = null;
        };
        while (true) {
            switch (client.state) {
                .idle => return client.round_trip_done(start),
                .evicted => return error.Evicted,
                .registering, .waiting => {},
                .timed_out => unreachable,
            }
            if (client.time_os.monotonic().ns > client.deadline(start).ns) {
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
        const deadline_at = client.deadline(start);
        const wait_until = if (deadline_at.ns < tick_next.ns) deadline_at else tick_next.*;
        // At least 1 ns: `run_once` always waits (a zero wait is `IO.run`'s job).
        const wait_ns: u63 = @intCast(@max(wait_until.ns -| now.ns, 1));
        try client.io.run_once(wait_ns);
    }

    /// A completed call: records its latency for the next header. It leaves
    /// `options.window_end` alone, so the next call in the request shares the window (#186).
    fn round_trip_done(client: *Client, start: stdx.Instant) void {
        assert(client.state == .idle);
        // Saturates past 4.29 s, which a primary still records as a slow round trip.
        client.latency_previous_ns =
            std.math.lossyCast(u32, start.elapsed(client.time_os.monotonic()).ns);
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
        release_eviction.record(
            eviction.header.reason,
            client.vsr_client.release,
            eviction.header.release,
        );
        // The VSR client's contract asks the callback to deinit it, but the callback runs inside
        // the message bus's receive path, which goes on to use the buffer `deinit` would free
        // (#52). `Client.deinit` deinits it instead. Nothing drives its IO after the call that
        // received the eviction; messages other connections delivered in that same IO pass are
        // dropped by the VSR client (a local patch, #74).
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
    const result: [constants.cache_line_size]u8 align(constants.cache_line_size) = @splat(0);
    const aligned: []align(constants.cache_line_size) const u8 = &result;
    Client.on_reply(@intFromPtr(&client), .register, 0, aligned);
    try std.testing.expectEqual(.timed_out, client.state);
    try std.testing.expectEqual(null, client.reply_size);
}

test "Client: a message after the eviction, in the same IO pass, is dropped (#74)" {
    // Only the field `on_messages` reads before dropping the buffer is set.
    var vsr_client: VSRClient = undefined;
    vsr_client.evicted = true;
    var pool = try MessagePool.init_capacity(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var buffer = MessageBuffer.init(&pool);
    defer buffer.deinit(&pool);
    VSRClient.on_messages(&vsr_client.message_bus, &buffer);
    try std.testing.expectEqual(.evicted, buffer.invalid.?);
}

test "Client: what a gateway tallied survives a registration that fails" {
    var tally: timings.Tally = .{};
    tally.operations.getPtr(.commit).record(2_000);
    tally.requests = 3;
    // Nothing listens at this address: registration times out, as a reconnect to a cluster that
    // is still away does, and `init` leaves the client uninitialized.
    const addresses = [_]stdx.SocketAddress{.{ .ip = .@"127.0.0.1", .port = 1 }};
    var client: Client = undefined;
    try std.testing.expectError(error.Timeout, client.init(std.testing.allocator, .{
        .cluster = 0,
        .addresses = &addresses,
        .timeout = stdx.Duration.ms(200),
        .tally = &tally,
    }));
    const commits = tally.operations.get(.commit);
    try std.testing.expectEqual(@as(u64, 1), commits.count);
    try std.testing.expectEqual(@as(u64, 2_000), commits.sum);
    try std.testing.expectEqual(@as(u64, 3), tally.requests);
}

test "Client: a completed call keeps the request's window (#186)" {
    var time_os: stdx.TimeOS = .{};
    const start = time_os.monotonic();
    const end = start.add(stdx.Duration.ms(500));
    // Only the fields `on_reply` and `round_trip_done` read: a call that has been answered.
    var reply: Body align(constants.cache_line_size) = undefined;
    var client: Client = undefined;
    client.state = .waiting;
    client.reply = &reply;
    client.reply_size = null;
    client.time_os = time_os;
    client.latency_previous_ns = 0;
    client.options = .{
        .cluster = 0,
        .addresses = &.{},
        .timeout = stdx.Duration.ms(1_000),
        .window_end = end,
    };
    const result: [constants.cache_line_size]u8 align(constants.cache_line_size) = @splat(0);
    const aligned: []align(constants.cache_line_size) const u8 = &result;
    Client.on_reply(@intFromPtr(&client), .register, 0, aligned);
    client.round_trip_done(start);
    // A call that re-armed the window for itself would give the next call a fresh `timeout`.
    try std.testing.expectEqual(end.ns, client.options.window_end.?.ns);
    try std.testing.expectEqual(end.ns, client.deadline(start).ns);
}

test "Client: one window bounds every call in it, not each call (#186)" {
    const addresses = [_]stdx.SocketAddress{.{ .ip = .@"127.0.0.1", .port = 1 }};
    var time_os: stdx.TimeOS = .{};
    const begin = time_os.monotonic();
    // Each call may wait 20 s; the window ends in 300 ms. Two registrations that fail against a
    // cluster that is away, one after the other, share it.
    const options: Client.Options = .{
        .cluster = 0,
        .addresses = &addresses,
        .timeout = stdx.Duration.ms(20_000),
        .window_end = begin.add(stdx.Duration.ms(300)),
    };
    var client: Client = undefined;
    try std.testing.expectError(error.Timeout, client.init(std.testing.allocator, options));
    const first = begin.elapsed(time_os.monotonic());
    try std.testing.expect(first.ns >= 300 * std.time.ns_per_ms);
    // The window is spent: the second call gives up at once instead of waiting 20 s more.
    try std.testing.expectError(error.Timeout, client.init(std.testing.allocator, options));
    const total = begin.elapsed(time_os.monotonic());
    try std.testing.expect(total.ns < 2 * std.time.ns_per_s);
}

test "Client: a call whose window is spent is not sent, and the session stays usable (#186)" {
    var time_os: stdx.TimeOS = .{};
    // Only the fields `ensure_idle` reads: an idle client, whose window ended a second ago.
    var client: Client = undefined;
    client.state = .idle;
    client.time_os = time_os;
    client.writes_sent = 7;
    client.options = .{
        .cluster = 0,
        .addresses = &.{},
        .timeout = stdx.Duration.ms(1_000),
        .window_end = .{ .ns = time_os.monotonic().ns - std.time.ns_per_s },
    };
    try std.testing.expectError(error.Expired, client.ensure_idle());
    // Nothing was queued: still idle, no write counted, so the gateway answers `applied: false`
    // and does not break the session.
    try std.testing.expectEqual(.idle, client.state);
    try std.testing.expectEqual(@as(u64, 7), client.writes_sent);
    // Just under a sixteenth of the timeout left (62.5 ms of 1 s; 50 ms left): refused, though
    // not yet passed. A divisor of 40 (25 ms) would send it.
    client.options.window_end = time_os.monotonic().add(stdx.Duration.ms(50));
    try std.testing.expectError(error.Expired, client.ensure_idle());
    try std.testing.expectEqual(.idle, client.state);
    try std.testing.expectEqual(@as(u64, 7), client.writes_sent);
    // Just over it (120 ms left): sent. A divisor of 1 (1 s) would refuse it.
    client.options.window_end = time_os.monotonic().add(stdx.Duration.ms(120));
    try client.ensure_idle();
    try std.testing.expectEqual(.waiting, client.state);
    client.state = .idle;
    // With time left (or no window) the same client takes a call.
    client.options.window_end = time_os.monotonic().add(stdx.Duration.ms(60_000));
    try client.ensure_idle();
    try std.testing.expectEqual(.waiting, client.state);
}
