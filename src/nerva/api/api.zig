//! `nerva api`: Nerva's core operations as JSON over HTTP (docs/DECISIONS.md N33).
//!
//! A thin translation, with no application concepts: every route is one Nerva request.
//!
//!     POST /v1/lookup   {"rows": [{"table": 1, "id": "5"}, …]}
//!     POST /v1/commit   {"entries": [{"kind": "read", "table": 1, "id": "5", "op_seen": "9"},
//!                                    {"kind": "put", "table": 1, "id": "5", "value_hex": "…"},
//!                                    {"kind": "delete", "table": 1, "id": "6"},
//!                                    {"kind": "add", "table": 1, "id": "7", "field": "stock",
//!                                     "delta": "-3", "min": "0"}]}
//!     GET  /v1/changes?cursor=<c>&limit=<n>
//!     GET  /v1/history?table=<t>&id=<i>&op_max=<n|latest>&cursor=<c>&limit=<n>
//!     GET  /v1/row?table=<t>&id=<i>&as_of=<op>
//!     PUT  /v1/tables/<t>   {"name": "seats", "fields": [{"name": "price", "type": "u64"}, …]}
//!     GET  /v1/tables/<t>
//!     PUT  /v1/views/<name>  {"table": 5, "where": […], "group_by": […], "aggregates": […]}
//!     GET  /v1/views         (the views the state machine maintains)
//!     GET  /v1/views/<name>?min_op=<n|latest>|as_of=<op>
//!                            (the view, whole, as `nerva view` answers it: N66)
//!     GET  /v1/views/<name>/definition
//!     GET  /v1/views/<name>/groups?cursor=<c>&limit=<n>&as_of=<op>
//!                            (the view, maintained by the state machine: N52, N62)
//!     PUT  /v1/ledgers/<id>  {"fields": [{"table": 7, "field": "available", "floor": "0"}, …]}
//!     GET  /v1/ledgers/<id>  (conserved fields: N75)
//!     POST /v1/documents/get, POST /v1/documents/commit, GET /v1/documents/changes
//!                            (larger values, by key: `documents_routes.zig`)
//!     GET  /v1/indexes       (the declared indexes: P123c)
//!     PUT  /v1/indexes/<name>  {"table": 2147483655, "eq": ["agent"], "order": "created",
//!                               "where": [{"field": "status", "op": "eq", "value": 1}]}
//!     GET  /v1/indexes/<name>
//!     POST /v1/indexes/<name>/scan  {"eq": {"agent": "…"}, "min", "max", "descending",
//!                                    "limit", "after"}
//!
//! Conventions:
//! - 64-bit numbers (`id`, `op`, `op_seen`, cursors) are decimal strings: JSON numbers lose
//!   precision past 2^53 in JavaScript. `table` (32-bit) and `limit` are numbers.
//! - A value is `value_hex`: up to 80 bytes as hex, zero-padded on write, always the full 80
//!   bytes on read.
//! - A commit is one transaction: `200 {"status": "committed", "op"}`, or `409 {"status":
//!   "conflict", "index", "op"}` (the entry whose read was stale, and the row's current version),
//!   or `400 {"error", "index"}` for an invalid entry. Nothing applies unless it committed.
//! - An add (N42) changes one 64-bit field inside the commit, without a read: `field` (by name,
//!   with a layout) or `offset` and `type` (`u64` or `i64`); `delta` (or `delta_from`, the index
//!   of an earlier add whose applied amount it moves, negated); optional `min`, `max`, `clamp`
//!   and `create`. A committed reply lists `adds`: each add's `index`, `applied` and new
//!   `value`. An add that would cross a bound answers `409 {"status": "out_of_bounds", "index",
//!   "value"}`; one to an absent row without `create`, `409 {"status": "row_absent", "index"}`.
//! - A field of a ledger (N75) changes only by a pair: an add with `"pair": true` (which may
//!   clamp), then an add naming it in `delta_from` (which may not). Otherwise `409 {"status":
//!   "unpaired", "index"}`; a put, delete or overlapping add that would change it, `409
//!   {"status": "conserved_write", "index"}`.
//! - A commit may carry a `key` (P123): 16 bytes as 32 hex digits. The same request again then
//!   answers `200 {"status": "committed", "op", "replayed": true}` with the op it committed at,
//!   and applies nothing; other entries under the key answer `409 {"status": "key_reused" (or
//!   "key_collision"), "op"}`. Indices in replies are the request's, not counting the key.
//! - A table may have a layout (`catalog.zig`, N34): then puts may give `fields` instead of
//!   `value_hex`, and every row or change of that table also comes back with `fields`.
//! - Tables from `0x80000000` to `catalog.tables_reserved_min` hold records (P123b): `id` is 16
//!   bytes as 32 hex digits, `value_hex` and a layout are up to 448 bytes, and adds are refused.
//!   A commit may mix rows and records (sent as `commit_wide`); a lookup reads one or the other.
//!   `changes` merges rows' and records' feeds into one order, under one cursor.
//! - An index (P123c) finds a record table's records by up to three `eq` fields and orders them
//!   by one number field (or the op); `where` makes it partial. Declared over existing records,
//!   it builds by pulses: until then a scan answers 503. A scan pages one `eq` key, from `min`
//!   to `max` of the order field; `next` is the `after` of the following page, or null.
//! - Tables from `catalog.tables_reserved_min` up are Nerva's own: refused here, and left out of
//!   `changes`.
//! - Errors are `{"error": "<reason>"}` with 400, 401, 404, 405, 409 or 503.
//! - A commit or a lookup of rows may be answered together with others that were waiting for the
//!   gateway (`handle_group`, P143): one cluster request, one transaction or read each. Each
//!   reply is the one the request would have had alone.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const stdx = @import("stdx");

const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");
const declared_views = @import("../view/declared.zig");
const documents = @import("../documents.zig");
const documents_routes = @import("documents_routes.zig");
const ledgers_static = @import("../ledgers.zig");
const view_fields = @import("../views.zig");
const wire = @import("../wire_code.zig");
pub const Code = wire.Code;
pub const Applied = wire.Applied;
const layout_cache = @import("layout_cache.zig");
const server = @import("server.zig");

const Change = nerva.Change;
const Entry = nerva.Entry;
const EntryResult = nerva.EntryResult;
const RowKey = nerva.RowKey;
const RowValue = nerva.RowValue;
const value_size = nerva.value_size;

/// Changes per `changes` or `history` call, at most; larger limits are capped.
pub const page_limit_max = 1024;

pub const Method = enum { get, post, put };

pub const Reply = struct {
    status: u16,
    /// JSON.
    body: []const u8,
};

pub const Route = enum {
    lookup,
    commit,
    changes,
    history,
    row,
    tables,
    views,
    documents_get,
    documents_commit,
    documents_changes,
    view_groups,
    view_definition,
    view_list,
    ledgers,
    index_list,
    indexes,
    index_scan,
};

pub const routes = [_]struct { path: []const u8, route: Route, method: Method }{
    .{ .path = "/v1/lookup", .route = .lookup, .method = .post },
    .{ .path = "/v1/commit", .route = .commit, .method = .post },
    .{ .path = "/v1/changes", .route = .changes, .method = .get },
    .{ .path = "/v1/history", .route = .history, .method = .get },
    .{ .path = "/v1/row", .route = .row, .method = .get },
    .{ .path = "/v1/documents/get", .route = .documents_get, .method = .post },
    .{ .path = "/v1/documents/commit", .route = .documents_commit, .method = .post },
    .{ .path = "/v1/documents/changes", .route = .documents_changes, .method = .get },
};

pub const tables_prefix = "/v1/tables/";
pub const views_prefix = "/v1/views/";
pub const ledgers_prefix = "/v1/ledgers/";
pub const indexes_prefix = "/v1/indexes/";
pub const index_scan_suffix = "/scan";
pub const views_groups_suffix = "/groups";
pub const views_definition_suffix = "/definition";
/// The most groups `GET /v1/views/<name>` answers with at once (N66); larger views are read in
/// pages from `/groups`.
pub const view_answer_groups_max = 10_000;

/// What `handle` needs of the catalog (`catalog_store.zig` in the server, a map in tests):
///
///     layout(arena, table: u32) !?catalog.Layout
///     layout_put(arena, table: u32, layout: *const catalog.Layout) !LayoutPut
///     view(arena, name: []const u8) !?catalog.View
///     view_put(arena, name: []const u8, view: *const catalog.View) !ViewPut
///
/// and, for the layouts kept between requests ("Layouts"):
///
///     layout_cached(arena, table: u32) !?layout_cache.Cached
///     layout_fresh(arena, table: u32) !LayoutRead
///     layout_probe(table: u32) nerva.RowKey
pub const LayoutPut = enum { created, extended, unchanged, incompatible };
/// A layout read from the log, and the version of its document (0: there is none).
pub const LayoutRead = struct { layout: ?catalog.Layout, version: u64 };
/// A view's declaration is immutable: declaring a different one under the same name conflicts.
pub const ViewPut = enum { created, unchanged, different };

/// Runs one request against `client` (a `Client`, or anything with its methods) and `layouts`
/// (see `LayoutPut`). Client errors other than `TooManyEvents` propagate: the server answers 503.
pub fn handle(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    target: []const u8,
    body: []const u8,
) !Reply {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..question];
    const query = if (question < target.len) target[question + 1 ..] else "";

    const route: Route = if (std.mem.eql(u8, path, "/v1/indexes")) route: {
        if (method != .get) return error_reply(arena, .E0104, 405, "method not allowed", .no);
        if (query.len > 0) return error_reply(arena, .E0107, 400, "unexpected query", .no);
        break :route .index_list;
    } else if (std.mem.startsWith(u8, path, indexes_prefix)) route: {
        if (query.len > 0) return error_reply(arena, .E0107, 400, "unexpected query", .no);
        const scan = std.mem.endsWith(u8, path, index_scan_suffix) and
            path.len > indexes_prefix.len + index_scan_suffix.len;
        if (scan) {
            if (method != .post) return error_reply(arena, .E0104, 405, "method not allowed", .no);
            break :route .index_scan;
        }
        if (method != .get and method != .put) {
            return error_reply(arena, .E0104, 405, "method not allowed", .no);
        }
        break :route .indexes;
    } else if (std.mem.startsWith(u8, path, ledgers_prefix)) route: {
        if (method != .get and method != .put) {
            return error_reply(arena, .E0104, 405, "method not allowed", .no);
        }
        if (query.len > 0) return error_reply(arena, .E0107, 400, "unexpected query", .no);
        break :route .ledgers;
    } else if (std.mem.eql(u8, path, "/v1/views")) route: {
        if (method != .get) return error_reply(arena, .E0104, 405, "method not allowed", .no);
        if (query.len > 0) return error_reply(arena, .E0107, 400, "unexpected query", .no);
        break :route .view_list;
    } else if (std.mem.startsWith(u8, path, tables_prefix) or
        std.mem.startsWith(u8, path, views_prefix))
    route: {
        if (method != .get and method != .put) {
            return error_reply(arena, .E0104, 405, "method not allowed", .no);
        }
        // `/v1/views/<name>/groups` and `/definition`, with a name: `/v1/views/groups` is the
        // view named `groups`.
        const view_suffix = struct {
            fn is(path_: []const u8, suffix: []const u8) bool {
                return std.mem.startsWith(u8, path_, views_prefix) and
                    std.mem.endsWith(u8, path_, suffix) and
                    path_.len > views_prefix.len + suffix.len;
            }
        }.is;
        const groups = view_suffix(path, views_groups_suffix);
        const definition = view_suffix(path, views_definition_suffix);
        const tables_route = std.mem.startsWith(u8, path, tables_prefix);
        if ((groups or definition) and method != .get) {
            return error_reply(arena, .E0104, 405, "method not allowed", .no);
        }
        // A view takes `as_of` and `min_op` (N66); a table or a definition takes none.
        const queried = groups or (!tables_route and !definition and method == .get);
        if (!queried and query.len > 0) return error_reply(arena, .E0107, 400, "unexpected query", .no);
        break :route if (tables_route)
            .tables
        else if (groups)
            .view_groups
        else if (definition)
            .view_definition
        else
            .views;
    } else route: {
        const entry = for (routes) |entry| {
            if (std.mem.eql(u8, entry.path, path)) break entry;
        } else return error_reply(arena, .E0104, 404, "not found", .no);
        if (entry.method != method) return error_reply(arena, .E0104, 405, "method not allowed", .no);
        break :route entry.route;
    };
    if (method == .get and body.len > 0) return error_reply(arena, .E0105, 400, "unexpected body", .no);

    const kept = route == .lookup or route == .commit;
    const Cache = Layouts(@TypeOf(layouts));
    var cache: Cache = .{
        .arena = arena,
        .layouts = layouts,
        .source = if (kept) .kept else .log,
    };
    return dispatch(arena, client, layouts, &cache, route, method, path, query, body) catch |err| switch (err) {
        error.BadRequest, error.Invalid => retry: {
            // A kept layout may be behind the log: it lacks a field the request names. Ask the
            // log before refusing.
            if (!cache.used_kept()) return refuse(arena, err);
            var fresh: Cache = .{ .arena = arena, .layouts = layouts, .source = .refresh };
            break :retry dispatch(
                arena,
                client,
                layouts,
                &fresh,
                route,
                method,
                path,
                query,
                body,
            ) catch |err_fresh| refuse(arena, err_fresh);
        },
        else => |e| refuse(arena, e),
    };
}

/// The most requests `handle_group` takes at once (the connections a gateway reads at once).
pub const group_max = 16;
/// The largest body of a request in a group. A parsed body costs up to ~200 times its size
/// (N69): 16 bodies of 16 KiB stay far below one request's budget.
pub const group_body_max = 16 * 1024;

/// A request waiting to be answered with others in one cluster request (`handle_group`).
pub const Member = struct {
    /// `/v1/commit` or `/v1/lookup`, with no query (`group_route`).
    target: []const u8,
    body: []const u8,
    /// Set by `handle_group`. A member left null when it returns an error was not answered.
    result: ?(anyerror!Reply) = null,
    /// Set by `handle_group`, also when it returns an error: whether a write of this member
    /// went out (`unknown`), or nothing of it did (`no`). Not the group's: a member that was not
    /// sent is not `unknown` because another was.
    applied: Applied = .no,
};

/// Whether a request may be answered by `handle_group`: the routes whose requests are one
/// transaction (`commit`) or one set of rows to read (`lookup`) and nothing more.
pub fn group_route(method: Method, target: []const u8) bool {
    return method == .post and
        (std.mem.eql(u8, target, "/v1/commit") or std.mem.eql(u8, target, "/v1/lookup"));
}

/// What `handle_group` keeps of a member between its phases.
fn GroupState(comptime Cache: type) type {
    return struct {
        const State = @This();

        /// The layouts this member uses, kept or fresh as `handle` would have them.
        cache: Cache,
        what: union(enum) {
            /// Answered while it was prepared (a refusal), or by `handle` since.
            answered,
            commit: Commit,
            lookup: Lookup,
            /// A lookup of records: not combined.
            records,
        } = .answered,

        /// The operation of the cluster request this member could be a batch of.
        fn operation(state: *const State) ?nerva.Operation {
            return switch (state.what) {
                .commit => |commit_| if (commit_.records) .commit_wide else .commit,
                .lookup => .lookup_rows,
                .answered, .records => null,
            };
        }

        /// Its events.
        fn count(state: *const State) u32 {
            return switch (state.what) {
                .commit => |commit_| @intCast(commit_.sent.len),
                .lookup => |lookup_| lookup_.count(),
                .answered, .records => unreachable,
            };
        }
    };
}

/// A member's outcome: its answer, or the error that stops the whole group.
fn settle(member: *Member, arena: std.mem.Allocator, result: anytype) !void {
    if (result) |reply| {
        member.result = reply;
    } else |err| {
        const any: anyerror = err;
        if (any == error.Timeout or any == error.Evicted or any == error.Expired) return err;
        member.result = refuse(arena, err);
    }
}

/// Answers `members` (all the same `group_route`) with one cluster request where it can: each
/// is one batch of a multi-batch `commit`, `commit_wide` or `lookup_rows`, which the state
/// machine admits on its own. Every member's answer is the one it would have had alone:
///
/// - A request that is refused (400) is refused before anything is sent, after the same second
///   look at the log as for a single request when it used a kept layout (P135).
/// - A transaction refused `views_busy`, because transactions before it in the op filled its
///   views budget, is sent again on its own, once: it then commits, or is `views_too_large`.
/// - Each transaction keeps its own key, and the state machine answers `committed_before`,
///   `key_reused` and `key_collision` in order, among the transactions of one op as among ops.
/// - Each lookup brings its own probes, and compares them with the versions it kept.
/// - A member that does not fit the request with the others, is of the other operation
///   (`commit_wide` among `commit`s, a lookup of records), or is the only one left, runs alone
///   through `handle`.
///
/// `error.Timeout`, `error.Evicted` and `error.Expired` from a call are returned, with every
/// member that had no answer yet left null; an `Expired` from a `views_busy` send again is the
/// exception (below). Each member's `applied` says whether a write of its own went out. A member
/// whose `views_busy` send again expires has `result = error.Expired` and `applied = unknown`
/// (its first batch went out): `handle_group` goes on, trying the members after it in turn, and
/// those whose answers came back keep them.
pub fn handle_group(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    members: []Member,
) !void {
    assert(members.len > 0 and members.len <= group_max);
    const commits = std.mem.eql(u8, members[0].target, "/v1/commit");
    for (members) |member| {
        assert(group_route(.post, member.target));
        assert(std.mem.eql(u8, member.target, members[0].target));
        assert(member.result == null);
    }
    const Cache = Layouts(@TypeOf(layouts));
    const State = GroupState(Cache);
    var states_buffer: [group_max]State = undefined;
    const states = states_buffer[0..members.len];

    // Prepare: every refusal is made here, before anything is sent.
    for (members, states) |*member, *state| {
        state.* = .{ .cache = .{ .arena = arena, .layouts = layouts, .source = .kept } };
        if (commits) {
            if (commit_prepare_kept(arena, layouts, &state.cache, member.body)) |prepared| {
                state.what = .{ .commit = prepared };
                continue;
            } else |err| try settle(member, arena, refuse(arena, err));
        } else {
            if (lookup_prepare_kept(arena, layouts, &state.cache, member.body)) |prepared| {
                state.what = switch (prepared) {
                    .rows => |rows| .{ .lookup = rows },
                    .records => .records,
                };
                continue;
            } else |err| try settle(member, arena, refuse(arena, err));
        }
    }

    // Choose who travels together: the operation of the first, and as many as fit.
    var operation: ?nerva.Operation = null;
    var counts: [group_max]u32 = undefined;
    var selected: [group_max]u8 = undefined;
    var selected_count: u32 = 0;
    for (states, 0..) |*state, index| {
        const candidate = state.operation() orelse continue;
        if (operation != null and operation.? != candidate) continue;
        counts[selected_count] = state.count();
        if (!batches_fit(client, candidate, counts[0 .. selected_count + 1])) continue;
        operation = candidate;
        selected[selected_count] = @intCast(index);
        selected_count += 1;
    }

    if (selected_count >= 2) {
        const batched = selected[0..selected_count];
        const writes_before = client.writes_sent;
        defer for (batched) |index| {
            members[index].applied = applied_since(writes_before, client.writes_sent);
        };
        try group_send(arena, client, operation.?, states, batched);
        for (batched) |index| {
            const member = &members[index];
            const state = &states[index];
            switch (state.what) {
                .commit => |*commit_| {
                    // Refused only because earlier transactions of this op filled its views
                    // budget: it was never judged. Alone it commits or is too large.
                    for (commit_.results_sent) |result| {
                        if (result.status != .views_busy) continue;
                        commit_send(arena, client, commit_) catch |err| {
                            if (err != error.Expired) return err;
                            member.result = error.Expired;
                            state.what = .answered;
                        };
                        break;
                    }
                    if (member.result != null) continue;
                    try settle(member, arena, commit_reply(arena, commit_));
                },
                .lookup => |*lookup_| {
                    try settle(member, arena, lookup_reply(arena, &state.cache, lookup_));
                },
                .answered, .records => unreachable,
            }
            state.what = .answered;
        }
    }

    // Whoever is left runs alone, as a single request does.
    for (members, states) |*member, *state| {
        if (state.what == .answered) continue;
        const writes_before = client.writes_sent;
        defer member.applied = applied_since(writes_before, client.writes_sent);
        try settle(member, arena, handle(arena, client, layouts, .post, member.target, member.body));
    }
}

/// Whether `client` takes batches of `counts` events of `operation` in one request.
fn batches_fit(client: anytype, operation: nerva.Operation, counts: []const u32) bool {
    return switch (operation) {
        .commit => client.batches_fit(.commit, counts),
        .commit_wide => client.batches_fit(.commit_wide, counts),
        .lookup_rows => client.batches_fit(.lookup_rows, counts),
        else => unreachable,
    };
}

/// Sends the chosen members, one batch each, as one cluster request.
fn group_send(
    arena: std.mem.Allocator,
    client: anytype,
    operation: nerva.Operation,
    states: anytype,
    selected: []const u8,
) !void {
    assert(selected.len >= 2 and selected.len <= group_max);
    switch (operation) {
        .commit => {
            var events: [group_max][]const Entry = undefined;
            var results: [group_max][]EntryResult = undefined;
            for (selected, events[0..selected.len], results[0..selected.len]) |index, *e, *r| {
                const commit_ = &states[index].what.commit;
                e.* = try commit_narrow(arena, commit_);
                r.* = commit_.results_sent;
            }
            try client.commit_batches(events[0..selected.len], results[0..selected.len]);
        },
        .commit_wide => {
            var events: [group_max][]const nerva.WideEntry = undefined;
            var results: [group_max][]EntryResult = undefined;
            for (selected, events[0..selected.len], results[0..selected.len]) |index, *e, *r| {
                const commit_ = &states[index].what.commit;
                e.* = commit_.sent;
                r.* = commit_.results_sent;
            }
            try client.commit_wide_batches(events[0..selected.len], results[0..selected.len]);
        },
        .lookup_rows => {
            var events: [group_max][]const RowKey = undefined;
            var results: [group_max][]RowValue = undefined;
            for (selected, events[0..selected.len], results[0..selected.len]) |index, *e, *r| {
                const lookup_ = &states[index].what.lookup;
                e.* = lookup_.keys_all;
                r.* = lookup_.results_all;
            }
            try client.lookup_rows_batches(events[0..selected.len], results[0..selected.len]);
        },
        else => unreachable,
    }
}

/// Whether `err` is a refusal that `handle` asks the log about before it stands: it used a kept
/// layout (P135).
fn refusal_to_recheck(err: anyerror, cache: anytype) bool {
    return (err == error.BadRequest or err == error.Invalid) and cache.used_kept();
}

/// `commit_prepare` as `handle` does it: with the gateway's kept layouts, then, if that refuses
/// a request that used one, with every layout read from the log (P135).
fn commit_prepare_kept(
    arena: std.mem.Allocator,
    layouts: anytype,
    cache: anytype,
    body: []const u8,
) !Commit {
    return commit_prepare(arena, cache, body) catch |err| {
        if (!refusal_to_recheck(err, cache)) return err;
        cache.* = .{ .arena = arena, .layouts = layouts, .source = .refresh };
        return commit_prepare(arena, cache, body);
    };
}

fn lookup_prepare_kept(
    arena: std.mem.Allocator,
    layouts: anytype,
    cache: anytype,
    body: []const u8,
) !LookupPrepared {
    return lookup_prepare(arena, cache, body) catch |err| {
        if (!refusal_to_recheck(err, cache)) return err;
        cache.* = .{ .arena = arena, .layouts = layouts, .source = .refresh };
        return lookup_prepare(arena, cache, body);
    };
}

/// The answer to an error of a request: a 400 (or a 504, for an op not committed yet), or the
/// error itself. Nothing was applied.
fn refuse(arena: std.mem.Allocator, err: anyerror) !Reply {
    return switch (err) {
        error.BadRequest => error_reply(
            arena,
            bad_request_code orelse wire.of_bad(bad_request_reason) orelse .E0105,
            400,
            bad_request_reason,
            .no,
        ),
        error.TooManyEvents => error_reply(
            arena,
            .E0112,
            400,
            "too many rows or entries for one request",
            .no,
        ),
        error.Invalid => error_reply(
            arena,
            wire.of_invalid(catalog.invalid_reason) orelse .E0301,
            400,
            catalog.invalid_reason,
            .no,
        ),
        error.NotCommitted => error_reply(arena, .E0401, 504, not_committed_reason, .no),
        else => err,
    };
}

fn dispatch(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    cache: anytype,
    route: Route,
    method: Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
) !Reply {
    return switch (route) {
        .lookup => lookup(arena, client, cache, body),
        .commit => commit(arena, client, cache, body),
        .changes => changes(arena, client, cache, query),
        .history => history(arena, client, cache, query),
        .row => row(arena, client, cache, query),
        .tables => tables(arena, layouts, method, path[tables_prefix.len..], body),
        .views => views(arena, client, layouts, method, path[views_prefix.len..], query, body),
        .view_definition => view_definition(
            arena,
            layouts,
            path[views_prefix.len .. path.len - views_definition_suffix.len],
        ),
        .view_list => view_list(arena, client),
        .ledgers => ledgers(arena, client, layouts, method, path[ledgers_prefix.len..], body),
        .index_list => index_list(arena, client),
        .indexes => indexes_route(arena, client, layouts, method, path[indexes_prefix.len..], body),
        .index_scan => index_scan(
            arena,
            client,
            cache,
            path[indexes_prefix.len .. path.len - index_scan_suffix.len],
            body,
        ),
        .view_groups => view_groups(
            arena,
            client,
            layouts,
            path[views_prefix.len .. path.len - views_groups_suffix.len],
            query,
        ),
        .documents_get => documents_routes.get(arena, client, body),
        .documents_commit => documents_routes.commit(arena, client, body),
        .documents_changes => documents_routes.changes(arena, client, query),
    };
}

/// The layouts one request uses, each read at most once per request.
///
/// Layouts. A gateway keeps the layouts it has read between requests (`layout_cache.zig`), so
/// that a `lookup` or a `commit` does not read them from the log: that was most of a Botpike
/// submit's log ops (#134). A kept layout may be behind the log, because another gateway
/// extended it. It must never make an answer wrong:
///
/// - A write is exact. A layout only grows by appending fields (`catalog.layout_extends`), and
///   `fields_encode` and `add_parse` use a named field's offset, size and type alone: absent
///   fields are zero and unknown ones are refused. So bytes a put or an add produces under a
///   layout that is behind are those it would produce under the log's, or it is refused. A
///   refusal (`bad`, `Invalid`) after a kept layout was used is answered only after running the
///   request again with every layout read from the log (`handle`). The commit's entries, and
///   with them its indices and its key's checksum, are the same either way.
/// - A read is checked. What a lookup renders as `fields` depends on every field of the layout,
///   so the kept layouts' catalog rows are read at the version they were kept at: in the lookup's
///   own `lookup_rows` (the same op), or, when those rows do not fit its batch or the lookup is
///   of records (P123b), in one that follows it, which is as exact: the layouts were kept before
///   the request began, so an unchanged version later is unchanged at the lookup's op. A layout
///   that moved is read again before it is rendered.
///
/// `changes`, `history`, `row` and `index_scan` render fields too, and read their layouts from
/// the log for each request, as before.
fn Layouts(comptime Catalog: type) type {
    return struct {
        const Self = @This();

        arena: std.mem.Allocator,
        layouts: Catalog,
        source: enum {
            /// From the log, for this request alone.
            log,
            /// From the gateway's cache if it is there, else from the log (and kept).
            kept,
            /// From the log, and kept.
            refresh,
        },
        loaded: std.AutoHashMapUnmanaged(u32, Loaded) = .{},

        const Loaded = struct { layout: ?catalog.Layout, version: u64, kept: bool };

        fn get(self: *Self, table: u32) !?*const catalog.Layout {
            assert(table != 0 and table < catalog.tables_reserved_min);
            const entry = try self.loaded.getOrPut(self.arena, table);
            if (!entry.found_existing) entry.value_ptr.* = try self.load(table);
            return if (entry.value_ptr.layout) |*layout| layout else null;
        }

        fn load(self: *Self, table: u32) !Loaded {
            if (self.source == .log) {
                const layout = try self.layouts.layout(self.arena, table);
                return .{ .layout = layout, .version = 0, .kept = false };
            }
            if (self.source == .kept) {
                if (try self.layouts.layout_cached(self.arena, table)) |hit| {
                    return .{ .layout = hit.layout, .version = hit.version, .kept = true };
                }
            }
            const read = try self.layouts.layout_fresh(self.arena, table);
            return .{ .layout = read.layout, .version = read.version, .kept = false };
        }

        /// Whether a layout from the cache was used.
        fn used_kept(self: *const Self) bool {
            var values = self.loaded.valueIterator();
            while (values.next()) |loaded| {
                if (loaded.kept) return true;
            }
            return false;
        }

        /// The catalog rows to read to check the kept layouts of `table_ids` (a table at most once
        /// each, and not one this request has loaded): their layouts are now loaded.
        fn probes(self: *Self, table_ids: []const u32) ![]const Probe {
            var found = std.ArrayListUnmanaged(Probe){};
            if (self.source != .kept) return found.items;
            for (table_ids) |table| {
                if (self.loaded.contains(table)) continue;
                const hit = try self.layouts.layout_cached(self.arena, table) orelse continue;
                try self.loaded.put(self.arena, table, .{
                    .layout = hit.layout,
                    .version = hit.version,
                    .kept = true,
                });
                try found.append(self.arena, .{
                    .table = table,
                    .key = self.layouts.layout_probe(table),
                });
            }
            return found.items;
        }

        /// Checks each probe against its row, read in the same op as the rows to render or after
        /// them: a layout that moved is read again.
        fn probes_check(self: *Self, found: []const Probe, rows: []const RowValue) !void {
            assert(found.len == rows.len);
            for (found, rows) |probe, row_| {
                const loaded = self.loaded.getPtr(probe.table).?;
                assert(loaded.kept);
                assert(row_.table == catalog.table_catalog and row_.id == probe.key.id);
                if (row_.op == loaded.version) continue;
                loaded.* = try self.load_fresh(probe.table);
            }
        }

        fn load_fresh(self: *Self, table: u32) !Loaded {
            const read = try self.layouts.layout_fresh(self.arena, table);
            return .{ .layout = read.layout, .version = read.version, .kept = false };
        }
    };
}

/// A kept layout's catalog row to read.
const Probe = struct { table: u32, key: RowKey };

/// The reason for the last `error.BadRequest` (set just before it is returned; one thread).
var bad_request_reason: []const u8 = "";
/// The code of the last `error.BadRequest`, when its maker named one (`bad_as`).
var bad_request_code: ?Code = null;

pub fn bad(reason: []const u8) error{BadRequest} {
    bad_request_reason = reason;
    bad_request_code = null;
    return error.BadRequest;
}

/// `bad`, for a reason whose family is not told by its text alone.
pub fn bad_as(code: Code, reason: []const u8) error{BadRequest} {
    bad_request_reason = reason;
    bad_request_code = code;
    return error.BadRequest;
}

/// A read of an op that is not committed yet: answered `504` NRV-E0401, on every route.
var not_committed_reason: []const u8 = "";

pub fn not_committed(reason: []const u8) error{NotCommitted} {
    not_committed_reason = reason;
    return error.NotCommitted;
}

// ---- Routes ----

fn lookup(arena: std.mem.Allocator, client: anytype, layouts: anytype, body: []const u8) !Reply {
    switch (try lookup_prepare(arena, layouts, body)) {
        .records => |rows| return lookup_records(arena, client, layouts, rows),
        .rows => |*prepared| {
            try lookup_send(client, prepared);
            return lookup_reply(arena, layouts, prepared);
        },
    }
}

const LookupRequestRow = struct { table: u32, id: []const u8 };

/// A lookup of rows, parsed and checked.
const Lookup = struct {
    /// The rows asked for.
    keys: []const RowKey,
    /// The kept layouts to check, by their catalog rows, read with `keys`.
    probes: []const Probe,
    /// `keys` then the probes' rows.
    keys_all: []RowKey,
    results_all: []RowValue,

    fn results(lookup_: *const Lookup) []RowValue {
        return lookup_.results_all[0..lookup_.keys.len];
    }

    /// Rows to read, the probes included.
    fn count(lookup_: *const Lookup) u32 {
        return @intCast(lookup_.keys_all.len);
    }
};

const LookupPrepared = union(enum) {
    /// A lookup of records (P123b): `lookup_records` reads them.
    records: []const LookupRequestRow,
    rows: Lookup,
};

/// Every refusal of a lookup is made here, before anything is sent.
fn lookup_prepare(arena: std.mem.Allocator, layouts: anytype, body: []const u8) !LookupPrepared {
    const Request = struct { rows: []const LookupRequestRow };
    const request = try json_parse(Request, arena, body);
    if (request.rows.len == 0) return bad("rows must not be empty");
    // One lookup reads at one op: rows, or records (P123b), not both.
    const records = nerva.table_is_record(request.rows[0].table);
    for (request.rows) |row_request| {
        if (nerva.table_is_record(row_request.table) != records) {
            return bad("a lookup reads rows or records, not both: send two");
        }
    }
    if (records) return .{ .records = request.rows };

    const keys = try arena.alloc(RowKey, request.rows.len);
    for (keys, request.rows) |*key, row_request| {
        try table_check(row_request.table);
        key.* = .{ .table = row_request.table, .id = try u64_parse(row_request.id, "id") };
    }
    // The kept layouts are checked in the same op, by reading their catalog rows with the rows.
    const table_ids = try arena.alloc(u32, keys.len);
    for (table_ids, keys) |*table, key| table.* = key.table;
    const probes = try layouts.probes(table_ids);
    const keys_all = try arena.alloc(RowKey, keys.len + probes.len);
    @memcpy(keys_all[0..keys.len], keys);
    for (keys_all[keys.len..], probes) |*key, probe| key.* = probe.key;
    return .{ .rows = .{
        .keys = keys,
        .probes = probes,
        .keys_all = keys_all,
        .results_all = try arena.alloc(RowValue, keys_all.len),
    } };
}

/// Reads the rows, and the probes with them, as one cluster request.
fn lookup_send(client: anytype, prepared: *const Lookup) !void {
    const keys = prepared.keys;
    const results = prepared.results();
    if (prepared.probes.len == 0) {
        try client.lookup_rows(keys, results);
    } else {
        client.lookup_rows(prepared.keys_all, prepared.results_all) catch |err| switch (err) {
            // No room for the probes: read them after, in an op that is not before the rows'.
            error.TooManyEvents => {
                try client.lookup_rows(keys, results);
                try client.lookup_rows(prepared.keys_all[keys.len..], prepared.results_all[keys.len..]);
            },
            else => return err,
        };
    }
}

/// Checks the kept layouts against their rows, then renders the rows.
fn lookup_reply(arena: std.mem.Allocator, layouts: anytype, prepared: *const Lookup) !Reply {
    const results = prepared.results();
    if (prepared.probes.len > 0) {
        try layouts.probes_check(prepared.probes, prepared.results_all[prepared.keys.len..]);
    }

    var out = Writer.init(arena);
    try out.raw("{\"op\":");
    try out.number(results[0].op_read);
    try out.raw(",\"rows\":[");
    for (results, 0..) |*result, index| {
        assert(result.op_read == results[0].op_read);
        if (index > 0) try out.raw(",");
        try out.raw("{\"table\":");
        try out.print("{}", .{result.table});
        try out.raw(",\"id\":");
        try out.number(result.id);
        try out.print(",\"exists\":{},\"op\":", .{result.flags.exists});
        try out.number(result.op);
        try out.raw(",\"value_hex\":");
        try out.hex(&result.value);
        if (result.flags.exists) try out.fields(try layouts.get(result.table), &result.value);
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

fn lookup_records(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    rows: anytype,
) !Reply {
    const keys = try arena.alloc(nerva.RecordKey, rows.len);
    for (keys, rows) |*key, row_request| {
        try table_check(row_request.table);
        key.* = .{ .table = row_request.table, .id = try id_parse(row_request.table, row_request.id) };
    }
    const results = try arena.alloc(nerva.RecordValue, keys.len);
    try client.lookup_records(keys, results);

    // The kept layouts of the records to render are checked after, in a lookup of their rows.
    var table_ids = std.ArrayListUnmanaged(u32){};
    for (results) |result| {
        if (result.flags.exists) try table_ids.append(arena, result.table);
    }
    const probes = try layouts.probes(table_ids.items);
    if (probes.len > 0) {
        const probe_keys = try arena.alloc(RowKey, probes.len);
        for (probe_keys, probes) |*key, probe| key.* = probe.key;
        const probe_rows = try arena.alloc(RowValue, probes.len);
        try client.lookup_rows(probe_keys, probe_rows);
        try layouts.probes_check(probes, probe_rows);
    }

    var out = Writer.init(arena);
    try out.raw("{\"op\":");
    try out.number(results[0].op_read);
    try out.raw(",\"rows\":[");
    for (results, 0..) |*result, index| {
        assert(result.op_read == results[0].op_read);
        if (index > 0) try out.raw(",");
        try out.print("{{\"table\":{},\"id\":", .{result.table});
        try out.id(result.table, result.id);
        try out.print(",\"exists\":{},\"op\":", .{result.flags.exists});
        try out.number(result.op);
        if (result.flags.collision) try out.raw(",\"collision\":true");
        try out.raw(",\"value_hex\":");
        try out.hex(&result.value);
        if (result.flags.exists) try out.fields(try layouts.get(result.table), &result.value);
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

fn commit(arena: std.mem.Allocator, client: anytype, layouts: anytype, body: []const u8) !Reply {
    const prepared = try commit_prepare(arena, layouts, body);
    try commit_send(arena, client, &prepared);
    return commit_reply(arena, &prepared);
}

/// A commit request, parsed and checked, ready to be sent as one transaction.
const Commit = struct {
    key: ?u128,
    /// The request's entries, as `commit_wide` carries them.
    entries: []const nerva.WideEntry,
    /// Per entry: an add's field type, for rendering its value.
    add_fields: []const ?nerva.Add.AddField,
    /// What is sent: `entries`, preceded by the key's entry under a key.
    sent: []const nerva.WideEntry,
    /// Whether an entry is a record's: sent as `commit_wide`, else as `commit`.
    records: bool,
    results_sent: []EntryResult,
};

/// Every refusal of a commit is made here, before anything is sent.
fn commit_prepare(arena: std.mem.Allocator, layouts: anytype, body: []const u8) !Commit {
    const Request = struct {
        key: ?[]const u8 = null,
        entries: []const EntryRequest,
    };
    const request = try json_parse(Request, arena, body);
    if (request.entries.len == 0) return bad("entries must not be empty");
    const key: ?u128 = if (request.key) |text| try key_parse(text) else null;

    // Every entry as `commit_wide` carries it; sent as `commit` when it writes rows only.
    const entries = try arena.alloc(nerva.WideEntry, request.entries.len);
    var records = false;
    // Per entry: an add's field type, for rendering its value.
    const add_fields = try arena.alloc(?nerva.Add.AddField, request.entries.len);
    for (entries, request.entries, add_fields, 0..) |*entry, entry_request, *add_field, index| {
        try table_check(entry_request.table);
        const record = nerva.table_is_record(entry_request.table);
        records = records or record;
        if (record and entry_request.kind == .add) return bad("records take no adds");
        if (entry_request.kind != .put and entry_request.fields != null) {
            return bad("only a put has fields");
        }
        if (entry_request.kind != .add and entry_request.add_fields_present()) {
            return bad("only an add has field, offset, type, delta, min, max, clamp, create, " ++
                "delta_from or pair");
        }
        add_field.* = null;
        entry.* = .{
            .id = try id_parse(entry_request.table, entry_request.id),
            .table = entry_request.table,
            .kind = switch (entry_request.kind) {
                .read => .read,
                .put => .put,
                .delete => .delete,
                .add => .add,
            },
            .op_seen = 0,
            .value = @splat(0),
        };
        switch (entry_request.kind) {
            .read => {
                if (entry_request.value_hex != null) return bad("a read has no value_hex");
                const op_seen = entry_request.op_seen orelse
                    return bad("a read needs op_seen (\"0\" if the row was absent)");
                entry.op_seen = try u64_parse(op_seen, "op_seen");
            },
            .put => {
                if (entry_request.op_seen != null) return bad("a put has no op_seen");
                if (entry_request.fields) |fields| {
                    if (entry_request.value_hex != null) {
                        return bad("a put has value_hex or fields, not both");
                    }
                    const layout = try layouts.get(entry_request.table) orelse
                        return bad("fields need a layout for the table (PUT /v1/tables/<t>)");
                    entry.value = try catalog.fields_encode(layout, fields);
                } else {
                    const value_hex = entry_request.value_hex orelse
                        return bad("a put needs value_hex or fields");
                    entry.value = try value_parse_sized(
                        value_hex,
                        nerva.table_value_size(entry_request.table),
                    );
                }
            },
            .delete => {
                if (entry_request.op_seen != null) return bad("a delete has no op_seen");
                if (entry_request.value_hex != null) return bad("a delete has no value_hex");
            },
            .add => {
                if (entry_request.op_seen != null) return bad("an add has no op_seen");
                if (entry_request.value_hex != null) return bad("an add has no value_hex");
                const add = try add_parse(layouts, &entry_request, entries[0..index]);
                entry.value[0..value_size].* = add.value();
                add_field.* = add.field;
            },
        }
        assert(nerva.wide_entry_validate(entry) == null);
    }

    // Under a key, the transaction starts with its key entry, so every index moves by one.
    const sent: []const nerva.WideEntry = if (key) |k| sent: {
        const sent = try arena.alloc(nerva.WideEntry, entries.len + 1);
        sent[0] = nerva.WideEntry.from_entry(&nerva.commit_key_entry(k));
        for (sent[1..], entries) |*entry_sent, entry| {
            entry_sent.* = entry;
            if (entry.kind != .add) continue;
            var add = nerva.Add.from_entry(&entry);
            if (!add.flags.delta_from) continue;
            add.delta_from += 1;
            entry_sent.value[0..value_size].* = add.value();
        }
        break :sent sent;
    } else entries;
    return .{
        .key = key,
        .entries = entries,
        .add_fields = add_fields,
        .sent = sent,
        .records = records,
        .results_sent = try arena.alloc(EntryResult, sent.len),
    };
}

/// Rows alone are sent as `commit`, which every release since 0.1 takes.
fn commit_narrow(arena: std.mem.Allocator, prepared: *const Commit) ![]const Entry {
    assert(!prepared.records);
    const narrow = try arena.alloc(Entry, prepared.sent.len);
    for (narrow, prepared.sent) |*entry, *wide| entry.* = narrow_entry(wide);
    return narrow;
}

/// Sends the transaction alone, as one cluster request.
fn commit_send(arena: std.mem.Allocator, client: anytype, prepared: *const Commit) !void {
    if (prepared.records) {
        try client.commit_wide(prepared.sent, prepared.results_sent);
    } else {
        try client.commit(try commit_narrow(arena, prepared), prepared.results_sent);
    }
}

/// The answer to a keyed transaction's key entry (P123), or null when the key admits the
/// transaction (`ok`, or `aborted` by an entry): a resend of a committed transaction answers
/// `replayed`, other entries under the key `key_reused` or `key_collision`. Shared by every
/// route that commits under a key (`/v1/commit`, `/v1/documents/commit`).
pub fn key_reply(arena: std.mem.Allocator, out: *Writer, result: EntryResult) !?Reply {
    switch (result.status) {
        .ok, .aborted => return null,
        // A resend of a transaction that committed: nothing applied now. Its adds' amounts
        // are not kept: read the rows as of `op`.
        .committed_before => {
            try out.raw("{\"status\":\"committed\",\"op\":");
            try out.number(result.op);
            try out.raw(",\"replayed\":true,\"code\":\"NRV-W0201\"}");
            return .{ .status = 200, .body = out.items() };
        },
        .key_reused, .key_collision => {
            try out.print("{{\"status\":\"{s}\",\"op\":", .{@tagName(result.status)});
            try out.number(result.op);
            try out.raw("}");
            return try refused_reply(
                out,
                409,
                if (result.status == .key_reused) .E0207 else .E0208,
            );
        },
        else => return try unexpected_status(arena, "commit rejected key", result.status),
    }
}

/// The answer to a commit, from the results of its transaction.
fn commit_reply(arena: std.mem.Allocator, prepared: *const Commit) !Reply {
    const key = prepared.key;
    const entries = prepared.entries;
    const add_fields = prepared.add_fields;
    const results_sent = prepared.results_sent;
    var out = Writer.init(arena);
    if (key != null) {
        if (try key_reply(arena, &out, results_sent[0])) |reply| return reply;
    }
    const results = results_sent[@intFromBool(key != null)..];
    assert(results.len == entries.len);
    for (results, 0..) |result, index| {
        switch (result.status) {
            .ok, .aborted => continue,
            .conflict => {
                try out.print("{{\"status\":\"conflict\",\"index\":{},\"op\":", .{index});
                try out.number(result.op);
                try out.raw("}");
                return refused_reply(&out, 409, .E0202);
            },
            .id_collision => {
                try out.print(
                    "{{\"status\":\"id_collision\",\"index\":{}}}",
                    .{index},
                );
                return refused_reply(&out, 409, .E0209);
            },
            .write_duplicate => {
                try out.print(
                    "{{\"error\":\"a transaction writes a row at most once (adds aside)\"," ++
                        "\"index\":{}}}",
                    .{index},
                );
                return refused_reply(&out, 400, .E0210);
            },
            .out_of_bounds => {
                try out.print("{{\"status\":\"out_of_bounds\",\"index\":{},\"value\":", .{index});
                try out.field_value(add_fields[index].?, result.value);
                try out.raw("}");
                return refused_reply(&out, 409, .E0203);
            },
            .row_absent => {
                try out.print("{{\"status\":\"row_absent\",\"index\":{}}}", .{index});
                return refused_reply(&out, 409, .E0204);
            },
            // An add to a field a view filters or groups by (N52).
            .view_key_field => {
                try out.print("{{\"status\":\"view_key_field\",\"index\":{}}}", .{index});
                return refused_reply(&out, 409, .E0206);
            },
            // This op's views budget is spent; nothing applied, so retrying is safe (N52).
            .views_busy => {
                try out.print("{{\"status\":\"views_busy\",\"index\":{}}}", .{index});
                return refused_reply(&out, 503, .E0211);
            },
            // The transaction alone is too large for any op: nothing applied; split it (#32).
            .views_too_large => {
                try out.print("{{\"status\":\"views_too_large\",\"index\":{}}}", .{index});
                return refused_reply(&out, 413, .E0212);
            },
            // A conserved field changed other than by a pair (N75).
            .unpaired, .conserved_write => {
                try out.print("{{\"status\":\"{s}\",\"index\":{}}}", .{
                    @tagName(result.status),
                    index,
                });
                return refused_reply(&out, 409, .E0205);
            },
            // Validated above: the server would be at fault.
            else => return unexpected_status(arena, "commit rejected an entry", result.status),
        }
    }
    assert(results[0].status == .ok);
    try out.raw("{\"status\":\"committed\",\"op\":");
    try out.number(results[0].op);
    var adds: u32 = 0;
    for (results, add_fields, 0..) |result, add_field, index| {
        const field_type = add_field orelse continue;
        try out.raw(if (adds == 0) ",\"adds\":[" else ",");
        adds += 1;
        try out.print("{{\"index\":{},\"applied\":\"{}\",\"value\":", .{ index, result.applied });
        try out.field_value(field_type, result.value);
        try out.raw("}");
    }
    if (adds > 0) try out.raw("]");
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

/// A commit result the gateway's own checks make impossible (NRV-B0002): where it once stopped
/// the process, it answers 500. The transaction was sent, so whether it was applied is unknown.
pub fn unexpected_status(arena: std.mem.Allocator, what: []const u8, status: anytype) !Reply {
    // The test runner fails a test that logs an error: the tests that reach this path on
    // purpose cannot log it.
    if (!builtin.is_test) std.log.scoped(.api).err("{s}: {s}", .{ what, @tagName(status) });
    return error_reply(arena, .B0002, 500, "internal error", .unknown);
}

const EntryRequest = struct {
    kind: enum { read, put, delete, add },
    table: u32,
    id: []const u8,
    op_seen: ?[]const u8 = null,
    value_hex: ?[]const u8 = null,
    fields: ?std.json.Value = null,
    // Adds only.
    field: ?[]const u8 = null,
    offset: ?u8 = null,
    type: ?enum { u64, i64 } = null,
    delta: ?[]const u8 = null,
    delta_from: ?u32 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    clamp: bool = false,
    create: bool = false,
    pair: bool = false,

    fn add_fields_present(request: *const EntryRequest) bool {
        return request.field != null or request.offset != null or request.type != null or
            request.delta != null or request.delta_from != null or request.min != null or
            request.max != null or request.clamp or request.create or request.pair;
    }
};

/// An add's parameters, checked as the state machine would (`entry_validate`, and `delta_from`
/// against the entries before it).
fn add_parse(
    layouts: anytype,
    request: *const EntryRequest,
    previous: []const nerva.WideEntry,
) !nerva.Add {
    var add: nerva.Add = .{
        .delta = 0,
        .min = 0,
        .max = 0,
        .delta_from = 0,
        .offset = 0,
        .field = .u64,
        .flags = .{ .clamp = request.clamp, .create = request.create, .pair = request.pair },
    };
    if (request.field) |name| {
        if (request.offset != null or request.type != null) {
            return bad("an add has field, or offset and type, not both");
        }
        const layout = try layouts.get(request.table) orelse
            return bad("field needs a layout for the table (PUT /v1/tables/<t>)");
        const field = layout.field(name) orelse return bad("no such field");
        // A row's field: within 80 bytes.
        add.offset = @intCast(field.offset);
        add.field = switch (field.type) {
            .u64 => .u64,
            .i64 => .i64,
            else => return bad("an add's field must be u64 or i64"),
        };
    } else {
        const offset = request.offset orelse return bad("an add needs field, or offset and type");
        if (offset > value_size - 8) return bad("offset must be at most 72");
        add.offset = offset;
        add.field = switch (request.type orelse return bad("an add needs a type with offset")) {
            .u64 => .u64,
            .i64 => .i64,
        };
    }

    if (request.delta_from) |index| {
        if (request.delta != null) return bad("an add has delta or delta_from, not both");
        if (index >= previous.len or previous[index].kind != .add) {
            return bad("delta_from must be the index of an earlier add");
        }
        add.flags.delta_from = true;
        add.delta_from = index;
    } else {
        const delta = request.delta orelse return bad("an add needs delta or delta_from");
        add.delta = try i64_parse(delta, "delta");
        if (add.delta == std.math.minInt(i64)) return bad("delta is out of range");
    }

    if (request.min) |text| {
        add.flags.min = true;
        add.min = try bound_parse(add.field, text, "min");
    }
    if (request.max) |text| {
        add.flags.max = true;
        add.max = try bound_parse(add.field, text, "max");
    }
    // The remaining checks (bounds in order) are `entry_validate`'s.
    if (nerva.entry_validate(&.{
        .id = 1,
        .table = 1,
        .kind = .add,
        .op_seen = 0,
        .value = add.value(),
    })) |status| return switch (status) {
        .field_invalid => bad("min must not exceed max"),
        else => unreachable,
    };
    return add;
}

const LedgerRequest = struct {
    fields: []const struct {
        table: u32,
        offset: ?u8 = null,
        field: ?[]const u8 = null,
        floor: ?[]const u8 = null,
    },
};

/// A ledger (N75): a set of conserved i64 fields that only pairs of adds change.
///
///     PUT /v1/ledgers/<id>  {"fields": [{"table": 7, "field": "available", "floor": "0"},
///                                       {"table": 7, "offset": 8, "floor": null}, …]}
///     GET /v1/ledgers/<id>
///
/// A field is named by layout (`field`) or by `offset`; `floor` (an i64 as a string, or null)
/// stops conserved adds that move it down. The fields are sent sorted, so their order in the
/// request does not matter.
fn ledgers(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    id_text: []const u8,
    body: []const u8,
) !Reply {
    const id_wide = std.fmt.parseInt(u64, id_text, 10) catch return bad("invalid ledger id");
    if (id_wide == 0 or id_wide > std.math.maxInt(u32)) return bad("invalid ledger id");
    const id: u32 = @intCast(id_wide);
    var out = Writer.init(arena);
    switch (method) {
        .get => {
            const ledger = try client.get_ledger(id);
            if (ledger.slot == 0) return error_reply(arena, .E0402, 404, "no such ledger", .no);
            assert(ledger.definition.id == id);
            try out.print("{{\"ledger\":{},\"op\":", .{id});
            try out.number(ledger.op);
            try out.raw(",\"fields\":[");
            const definition = &ledger.definition;
            for (definition.fields[0..definition.field_count], 0..) |*field, index| {
                if (index > 0) try out.raw(",");
                try out.print("{{\"table\":{},\"offset\":{}", .{ field.table, field.offset });
                if (try layouts.layout(arena, field.table)) |layout| {
                    for (layout.fields) |*named| {
                        if (named.offset != field.offset or named.type != .i64) continue;
                        try out.raw(",\"field\":");
                        try std.json.stringify(named.name, .{}, out.list.writer());
                    }
                }
                try out.raw(",\"floor\":");
                if (field.flags.floor) {
                    try out.print("\"{}\"", .{field.floor});
                } else {
                    try out.raw("null");
                }
                try out.raw("}");
            }
            try out.raw("]}");
            return .{ .status = 200, .body = out.items() };
        },
        .put => {
            const definition = try ledger_parse(arena, layouts, id, body);
            const declared = try client.declare_ledger(&definition);
            const conflict: ?[]const u8 = switch (declared.status) {
                .created, .exists => null,
                .ledger_immutable => "ledger_immutable",
                .ledger_field_taken => "ledger_field_taken",
                .field_viewed => "field_viewed",
                .ledgers_full => "ledgers_full",
                // Checked here first: the state machine would agree.
                .invalid, .table_invalid => unreachable,
            };
            if (conflict) |status| {
                try out.print("{{\"status\":\"{s}\",\"ledger\":{}}}", .{ status, id });
                return refused_reply(
                    &out,
                    409,
                    if (declared.status == .ledgers_full) .E0306 else .E0305,
                );
            }
            try out.print("{{\"ledger\":{},\"declared\":\"{s}\",\"op\":", .{
                id,
                @tagName(declared.status),
            });
            try out.number(declared.op);
            try out.raw("}");
            return .{ .status = 200, .body = out.items() };
        },
        .post => unreachable,
    }
}

fn ledger_parse(
    arena: std.mem.Allocator,
    layouts: anytype,
    id: u32,
    body: []const u8,
) !nerva.LedgerDefinition {
    const request = try json_parse(LedgerRequest, arena, body);
    if (request.fields.len < 2 or request.fields.len > nerva.ledger_fields_max) {
        return bad("a ledger has 2 to 16 fields");
    }
    var definition = std.mem.zeroes(nerva.LedgerDefinition);
    definition.id = id;
    definition.field_count = @intCast(request.fields.len);
    for (request.fields, definition.fields[0..request.fields.len]) |field, *target| {
        try table_check(field.table);
        const offset: u8 = if (field.field) |name| offset: {
            if (field.offset != null) return bad("a ledger field has field or offset, not both");
            const layout = try layouts.layout(arena, field.table) orelse
                return bad("field needs a layout for the table (PUT /v1/tables/<t>)");
            const named = layout.field(name) orelse return bad("no such field");
            if (named.type != .i64) return bad("a ledger's fields must be i64");
            break :offset @intCast(named.offset);
        } else field.offset orelse return bad("a ledger field needs field or offset");
        if (offset % 8 != 0 or offset > value_size - 8) {
            return bad("a ledger field's offset must be a multiple of 8, at most 72");
        }
        target.* = .{ .table = field.table, .offset = offset, .flags = .{}, .floor = 0 };
        if (field.floor) |text| {
            target.flags.floor = true;
            target.floor = try i64_parse(text, "floor");
        }
    }
    const fields = definition.fields[0..definition.field_count];
    std.mem.sortUnstable(nerva.LedgerField, fields, {}, struct {
        fn less_than(_: void, a: nerva.LedgerField, b: nerva.LedgerField) bool {
            if (a.table != b.table) return a.table < b.table;
            return a.offset < b.offset;
        }
    }.less_than);
    for (fields[1..], fields[0 .. fields.len - 1]) |field, previous| {
        if (field.table == previous.table and field.offset == previous.offset) {
            return bad("a ledger names each field once");
        }
    }
    assert(ledgers_static.definition_validate(&definition) == null);
    return definition;
}

fn bound_parse(field: nerva.Add.AddField, text: []const u8, comptime name: []const u8) !u64 {
    return switch (field) {
        .u64 => try u64_parse(text, name),
        .i64 => @bitCast(try i64_parse(text, name)),
        _ => unreachable,
    };
}

fn i64_parse(text: []const u8, comptime name: []const u8) error{BadRequest}!i64 {
    const negative = text.len > 0 and text[0] == '-';
    const magnitude = try u64_parse(if (negative) text[1..] else text, name);
    if (negative) {
        if (magnitude > @as(u64, std.math.maxInt(i64)) + 1) return bad(name ++ " is out of range");
        return @intCast(-@as(i128, magnitude));
    }
    if (magnitude > std.math.maxInt(i64)) return bad(name ++ " is out of range");
    return @intCast(magnitude);
}

fn changes(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(arena, query, &.{ "cursor", "limit" });
    const limit = try limit_parse(parameters.get("limit"));
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;

    // Rows' feed and records' (P123b), merged by timestamp: one cursor reads both.
    const rows_page = try arena.alloc(Change, limit + 1);
    const rows_count =
        try client.get_changes(.{ .timestamp_min = cursor, .limit = limit }, rows_page);
    if (rows_count == 0) return bad("invalid cursor");
    const records_page = try arena.alloc(nerva.RecordChange, limit + 1);
    const records_count =
        try client.get_record_changes(.{ .timestamp_min = cursor, .limit = limit }, records_page);
    assert(records_count > 0);
    const rows_end = rows_page[rows_count - 1];
    const records_end = records_page[records_count - 1];
    const rows_ = rows_page[0 .. rows_count - 1];
    const records_ = records_page[0 .. records_count - 1];
    // A feed with more may hold changes past its page's last but before the other's: take
    // nothing past the earlier of the two pages' last, when its feed has more.
    var bound: u64 = std.math.maxInt(u64);
    if (rows_end.flags.more) bound = @min(bound, rows_[rows_.len - 1].timestamp);
    if (records_end.flags.more) bound = @min(bound, records_[records_.len - 1].timestamp);
    // Records were read at a later op than rows. Rows' feed, complete, is complete only through
    // its own op: a record change of a later op may lie past row changes committed between the
    // two reads, which the next cursor would skip (#125). Take none of those, and say there is
    // more. (With more, `bound` already keeps records before rows' last change.)
    const rows_op: ?u64 = if (rows_end.flags.more) null else rows_end.op;

    const merged = try arena.alloc(nerva.RecordChange, limit + 1);
    var count: usize = 0;
    var cut = false;
    var row_index: usize = 0;
    var record_index: usize = 0;
    while (count < limit) {
        const row_next = if (row_index < rows_.len) &rows_[row_index] else null;
        const record_next = if (record_index < records_.len) &records_[record_index] else null;
        const take_row = if (row_next) |row_change|
            record_next == null or row_change.timestamp < record_next.?.timestamp
        else if (record_next != null) false else break;
        const timestamp = if (take_row) row_next.?.timestamp else record_next.?.timestamp;
        if (timestamp > bound) break;
        if (!take_row and rows_op != null and record_next.?.op > rows_op.?) {
            cut = true;
            break;
        }
        if (take_row) {
            merged[count] = change_wide(row_next.?);
            row_index += 1;
        } else {
            merged[count] = record_next.?.*;
            record_index += 1;
        }
        count += 1;
    }
    const more = cut or row_index < rows_.len or record_index < records_.len or
        rows_end.flags.more or records_end.flags.more;
    merged[count] = .{
        .id = 0,
        .table = 0,
        .kind = .end,
        .flags = .{ .more = more },
        // Complete through the earlier of the two reads.
        .op = if (more) 0 else @min(rows_end.op, records_end.op),
        .timestamp = if (count == 0) cursor else merged[count - 1].timestamp + 1,
        .value = @splat(0),
    };
    return page_reply(arena, layouts, merged[0 .. count + 1], .ascending);
}

/// A row's change as a record's (P123b): its id and value widened.
fn change_wide(change: *const Change) nerva.RecordChange {
    var wide: nerva.RecordChange = .{
        .id = change.id,
        .table = change.table,
        .kind = change.kind,
        .flags = change.flags,
        .op = change.op,
        .timestamp = change.timestamp,
        .value = @splat(0),
    };
    wide.value[0..value_size].* = change.value;
    return wide;
}

fn history(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(
        arena,
        query,
        &.{ "table", "id", "op_max", "cursor", "limit" },
    );
    const table = try table_parse(parameters.get("table"));
    const id = try id_parse(table, parameters.get("id") orelse return bad("id is required"));
    const op_max: u64 = if (parameters.get("op_max")) |text|
        if (std.mem.eql(u8, text, "latest")) std.math.maxInt(u64) else try u64_parse(text, "op_max")
    else
        std.math.maxInt(u64);
    if (op_max == 0) return bad("op_max must be positive");
    const limit = try limit_parse(parameters.get("limit"));
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;

    const page = try arena.alloc(nerva.RecordChange, limit + 1);
    const count = if (nerva.table_is_record(table))
        try client.get_record_history(.{
            .table = table,
            .id = id,
            .limit = limit,
            .op_max = op_max,
            .timestamp_max = cursor,
        }, page)
    else count: {
        const rows_page = try arena.alloc(Change, limit + 1);
        const count = try client.get_history(.{
            .table = table,
            .id = @intCast(id),
            .limit = limit,
            .op_max = op_max,
            .timestamp_max = cursor,
        }, rows_page);
        for (rows_page[0..count], page[0..count]) |*change, *wide| wide.* = change_wide(change);
        break :count count;
    };
    if (count == 0) return bad("invalid cursor");
    return page_reply(arena, layouts, page[0..count], .descending);
}

/// A row as of an op: its last change at or before `as_of`. `as_of` must already be committed,
/// or the answer could still change.
fn row(arena: std.mem.Allocator, client: anytype, layouts: anytype, query: []const u8) !Reply {
    const parameters = try query_parse(arena, query, &.{ "table", "id", "as_of" });
    const table = try table_parse(parameters.get("table"));
    const id = try id_parse(table, parameters.get("id") orelse return bad("id is required"));
    const as_of_text = parameters.get("as_of") orelse return bad("as_of is required");
    const as_of = try u64_parse(as_of_text, "as_of");
    if (as_of == 0) return bad("as_of must be positive");

    // A lookup's own op is newer than every committed op: anything at or after it may not have
    // happened yet, so its answer could still change.
    const found = if (nerva.table_is_record(table)) found: {
        var current: [1]nerva.RecordValue = undefined;
        try client.lookup_records(&.{.{ .table = table, .id = id }}, &current);
        if (as_of >= current[0].op_read) return not_committed("as_of is not yet committed");
        break :found try record_as_of(client, table, id, as_of);
    } else found: {
        var current: [1]RowValue = undefined;
        try client.lookup_rows(&.{.{ .table = table, .id = @intCast(id) }}, &current);
        if (as_of >= current[0].op_read) return not_committed("as_of is not yet committed");
        const change = try change_as_of(client, table, @intCast(id), as_of) orelse break :found null;
        break :found change_wide(&change);
    };
    const size = nerva.table_value_size(table);

    var out = Writer.init(arena);
    try out.print("{{\"table\":{},\"id\":", .{table});
    try out.id(table, id);
    try out.raw(",\"as_of\":");
    try out.number(as_of);
    if (found) |change| {
        assert(change.op <= as_of);
        try out.print(",\"exists\":{},\"op\":", .{change.kind == .put});
        try out.number(change.op);
        try out.raw(",\"value_hex\":");
        try out.hex(change.value[0..size]);
        if (change.kind == .put) try out.fields(try layouts.get(table), change.value[0..size]);
    } else {
        try out.raw(",\"exists\":false,\"op\":\"0\",\"value_hex\":");
        try out.hex(@as([nerva.record_value_size]u8, @splat(0))[0..size]);
    }
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

/// The row's last change (a put or a delete) at or before `op`, or null if it had none.
pub fn change_as_of(client: anytype, table: u32, id: u64, op: u64) !?Change {
    assert(op != 0);
    var page: [65]Change = undefined;
    var cursor: u64 = 0;
    while (true) {
        const count = try client.get_history(.{
            .table = table,
            .id = id,
            .limit = page.len - 1,
            .op_max = op,
            .timestamp_max = cursor,
        }, &page);
        assert(count >= 1);
        const end = page[count - 1];
        assert(end.kind == .end);
        if (count > 1) {
            assert(page[0].op <= op);
            return page[0];
        }
        if (!end.flags.more) {
            assert(op < end.op);
            return null;
        }
        cursor = end.timestamp;
    }
}

/// The record's last change at or before `op`, or null if it had none (P123b).
fn record_as_of(client: anytype, table: u32, id: u128, op: u64) !?nerva.RecordChange {
    assert(op != 0);
    var page: [9]nerva.RecordChange = undefined;
    var cursor: u64 = 0;
    while (true) {
        const count = try client.get_record_history(.{
            .table = table,
            .id = id,
            .limit = page.len - 1,
            .op_max = op,
            .timestamp_max = cursor,
        }, &page);
        assert(count >= 1);
        const end = page[count - 1];
        assert(end.kind == .end);
        if (count > 1) {
            assert(page[0].op <= op);
            return page[0];
        }
        if (!end.flags.more) return null;
        cursor = end.timestamp;
    }
}

/// Rows' and records' changes, a row's as `change_wide` widens it.
fn page_reply(
    arena: std.mem.Allocator,
    layouts: anytype,
    page: []const nerva.RecordChange,
    direction: enum { ascending, descending },
) !Reply {
    assert(page.len >= 1);
    const end = page[page.len - 1];
    assert(end.kind == .end);

    var out = Writer.init(arena);
    try out.raw("{\"changes\":[");
    var written: u32 = 0;
    for (page[0 .. page.len - 1]) |*change| {
        assert(change.kind == .put or change.kind == .delete);
        // Nerva's own rows (the catalog) are not part of the application's feed.
        if (change.table >= catalog.tables_reserved_min) continue;
        if (written > 0) try out.raw(",");
        written += 1;
        try out.print("{{\"kind\":\"{s}\",\"table\":{},\"id\":", .{
            @tagName(change.kind),
            change.table,
        });
        try out.id(change.table, change.id);
        try out.raw(",\"op\":");
        try out.number(change.op);
        if (change.kind == .put) {
            const value = change.value[0..nerva.table_value_size(change.table)];
            try out.raw(",\"value_hex\":");
            try out.hex(value);
            try out.fields(try layouts.get(change.table), value);
        }
        try out.raw("}");
    }
    try out.print("],\"more\":{},\"cursor\":", .{end.flags.more});
    // Ascending: the next `cursor` always. Descending: the next `cursor` while there is more.
    if (direction == .descending and !end.flags.more) {
        try out.raw("null");
    } else {
        try out.number(end.timestamp);
    }
    // The op the answer is complete through, once there is no more.
    try out.raw(",\"op\":");
    if (end.flags.more) try out.raw("null") else try out.number(end.op);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

// ---- Indexes (P123c) ----

/// The index named `name` (one `get_index` per declared index until it is found), or null.
fn index_find(client: anytype, name: []const u8) !?nerva.Index {
    var id: u64 = 1;
    while (id <= nerva.indexes_max) : (id += 1) {
        const index = try client.get_index(id);
        if (index.id == 0) return null;
        const declared = std.mem.sliceTo(&index.definition.name, 0);
        if (std.mem.eql(u8, declared, name)) return index;
    }
    return null;
}

fn index_list(arena: std.mem.Allocator, client: anytype) !Reply {
    var out = Writer.init(arena);
    try out.raw("{\"indexes\":[");
    var id: u64 = 1;
    while (id <= nerva.indexes_max) : (id += 1) {
        const index = try client.get_index(id);
        if (index.id == 0) break;
        if (id > 1) try out.raw(",");
        try index_render(&out, &index);
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

fn index_render(out: *Writer, index: *const nerva.Index) !void {
    try out.raw("{\"name\":");
    try std.json.stringify(std.mem.sliceTo(&index.definition.name, 0), .{}, out.list.writer());
    try out.print(",\"id\":{},\"table\":{},\"state\":\"{s}\",\"declared_op\":", .{
        index.id,
        index.definition.table,
        @tagName(index.state),
    });
    try out.number(index.declared_op);
    try out.raw(",\"record_count\":");
    try out.number(index.entry_count);
    try out.raw("}");
}

const IndexDeclaration = struct {
    table: u32,
    eq: []const []const u8 = &.{},
    order: ?[]const u8 = null,
    where: []const struct { field: []const u8, op: catalog.Comparison, value: std.json.Value } = &.{},
};

fn indexes_route(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    name: []const u8,
    body: []const u8,
) !Reply {
    catalog.view_name_validate(name) catch return bad("an index name is 1 to 32 of a-z, 0-9, _");
    if (method == .get) {
        if (body.len > 0) return bad("unexpected body");
        const index = try index_find(client, name) orelse
            return error_reply(arena, .E0402, 404, "no such index", .no);
        var out = Writer.init(arena);
        try index_render(&out, &index);
        return .{ .status = 200, .body = out.items() };
    }
    assert(method == .put);
    const declaration = try json_parse(IndexDeclaration, arena, body);
    try table_check(declaration.table);
    if (!nerva.table_is_record(declaration.table)) return bad("an index is over a record table");
    const layout = try layouts.layout(arena, declaration.table) orelse
        return bad("an index needs a layout for its table (PUT /v1/tables/<t>)");
    if (declaration.eq.len > nerva.index_eq_max) return bad("an index has at most 3 eq fields");
    if (declaration.where.len > nerva.index_where_max) return bad("at most 4 where clauses");

    var definition = std.mem.zeroes(nerva.IndexDefinition);
    @memcpy(definition.name[0..name.len], name);
    definition.table = declaration.table;
    definition.eq_count = @intCast(declaration.eq.len);
    for (declaration.eq, 0..) |field_name, slot| {
        const field = layout.field(field_name) orelse return bad("unknown field in eq");
        definition.eq[slot] = catalog.field_ref(field);
    }
    if (declaration.order) |field_name| {
        const field = layout.field(field_name) orelse return bad("unknown order field");
        if (field.type == .bytes) return bad("an index orders by a number or a bool");
        definition.flags.order = true;
        definition.order = catalog.field_ref(field);
    }
    definition.where_count = @intCast(declaration.where.len);
    for (declaration.where, 0..) |clause, slot| {
        const field = layout.field(clause.field) orelse return bad("unknown field in where");
        if (field.type == .bytes) return bad("where compares numbers and bools only");
        const value: i128 = switch (clause.value) {
            .integer => |n| n,
            .bool => |b| @intFromBool(b),
            .string, .number_string => |text| std.fmt.parseInt(i128, text, 10) catch
                return bad("a where value is a number"),
            else => return bad("a where value is a number"),
        };
        definition.where[slot] = .{
            .field = catalog.field_ref(field),
            .comparison = switch (clause.op) {
                inline else => |comparison| @field(nerva.Comparison, @tagName(comparison)),
            },
            .value = std.mem.toBytes(std.mem.nativeToLittle(i128, value)),
        };
    }

    const result = try client.declare_index(&definition);
    var out = Writer.init(arena);
    switch (result.status) {
        .created, .exists => {
            try out.print("{{\"index\":\"{s}\",\"id\":{},\"declared\":\"{s}\",\"op\":", .{
                name,
                result.index_id,
                @tagName(result.status),
            });
            try out.number(result.op);
            try out.raw("}");
            return .{ .status = 200, .body = out.items() };
        },
        .different, .indexes_full, .table_indexes_full => {
            try out.print("{{\"status\":\"{s}\"}}", .{@tagName(result.status)});
            return refused_reply(&out, 409, .E0312);
        },
        .invalid => return bad("the index breaks a rule (an eq key is at most 64 bytes)"),
        .table_invalid => return bad("an index is over a record table"),
    }
}

/// A page of an index's records with one `eq` key: `{"eq": {field: value}, "min", "max",
/// "descending", "limit", "after"}`. `min` and `max` bound the order field's value (or the op,
/// for an index without one); `after` is the `next` of the page before.
fn index_scan(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    name: []const u8,
    body: []const u8,
) !Reply {
    const Request = struct {
        eq: ?std.json.Value = null,
        min: ?[]const u8 = null,
        max: ?[]const u8 = null,
        descending: bool = false,
        limit: u32 = 100,
        after: ?[]const u8 = null,
    };
    const request = try json_parse(Request, arena, body);
    if (request.limit == 0) return bad("limit must be positive");
    const index = try index_find(client, name) orelse
        return error_reply(arena, .E0402, 404, "no such index", .no);
    const definition = &index.definition;
    const layout = try layouts.get(definition.table) orelse
        return bad("the index's table has no layout");

    var query = std.mem.zeroes(nerva.IndexQuery);
    query.index_id = index.id;
    query.limit = @min(request.limit, page_limit_max);
    query.flags.descending = request.descending;
    // The eq key: the eq fields' values, encoded as the table's layout encodes them.
    if (request.eq) |eq| {
        if (eq != .object) return bad("eq is an object of the index's eq fields");
        if (eq.object.count() != definition.eq_count) return bad("eq names every eq field");
        const value = try catalog.fields_encode(layout, eq);
        query.eq_key = view_fields.fields_key(definition.eq[0..definition.eq_count], &value);
        for (eq.object.keys()) |field_name| {
            const field = layout.field(field_name).?;
            const ref = catalog.field_ref(field);
            for (definition.eq[0..definition.eq_count]) |slot| {
                if (slot.offset_of() == ref.offset_of()) break;
            } else return bad("eq names a field the index does not have");
        }
    } else if (definition.eq_count > 0) return bad("eq is required");
    const order_kind: nerva.FieldKind = if (definition.flags.order) definition.order.kind else .unsigned;
    query.order_min = if (request.min) |text| try order_parse(order_kind, text) else 0;
    query.order_max = if (request.max) |text|
        try order_parse(order_kind, text)
    else
        std.math.maxInt(u64);
    if (query.order_min > query.order_max) return bad("min is above max");
    if (request.after) |text| {
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse return bad("after is malformed");
        query.cursor_order = std.fmt.parseInt(u64, text[0..dot], 10) catch
            return bad("after is malformed");
        query.cursor_timestamp = std.fmt.parseInt(u64, text[dot + 1 ..], 10) catch
            return bad("after is malformed");
        if (query.cursor_timestamp == 0 or query.cursor_timestamp > std.math.maxInt(u63)) {
            return bad("after is malformed");
        }
    }

    const results = try arena.alloc(nerva.IndexRecord, query.limit + 1);
    const count = try client.scan_index(query, results);
    if (count == 0) return bad("the scan is malformed");
    const header = results[0];
    assert(header.kind == .header);
    switch (header.state) {
        .ready => {},
        .building => return error_reply(arena, .E0404, 503, "index building", .no),
        .missing => return error_reply(arena, .E0402, 404, "no such index", .no),
    }
    var out = Writer.init(arena);
    try out.raw("{\"index\":");
    try std.json.stringify(name, .{}, out.list.writer());
    try out.raw(",\"op\":");
    try out.number(header.op);
    try out.raw(",\"records\":[");
    for (results[1..count], 0..) |*record, position| {
        assert(record.kind == .record);
        if (position > 0) try out.raw(",");
        try out.raw("{\"id\":");
        try out.id(record.table, record.id);
        try out.raw(",\"op\":");
        try out.number(record.op);
        try out.print(",\"order\":\"{}\"", .{view_fields.integer_from_ordered(order_kind, record.order)});
        try out.raw(",\"value_hex\":");
        try out.hex(&record.value);
        try out.fields(layout, &record.value);
        try out.raw("}");
    }
    try out.raw("],\"next\":");
    if (header.flags.more) {
        try out.print("\"{}.{}\"", .{ header.order, header.timestamp });
    } else {
        try out.raw("null");
    }
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

/// An order bound as the order field's type gives it, encoded to order as the field does.
fn order_parse(kind: nerva.FieldKind, text: []const u8) error{BadRequest}!u64 {
    return switch (kind) {
        .signed => view_fields.integer_ordered(
            .signed,
            std.fmt.parseInt(i64, text, 10) catch return bad("min and max are numbers"),
        ),
        else => std.fmt.parseInt(u64, text, 10) catch return bad("min and max are numbers"),
    };
}

fn tables(
    arena: std.mem.Allocator,
    layouts: anytype,
    method: Method,
    table_text: []const u8,
    body: []const u8,
) !Reply {
    const table = try table_parse(table_text);
    var out = Writer.init(arena);
    switch (method) {
        .get => {
            const layout = try layouts.layout(arena, table) orelse
                return error_reply(arena, .E0303, 404, "no layout for this table", .no);
            try out.raw(try catalog.layout_render(arena, &layout));
            return .{ .status = 200, .body = out.items() };
        },
        .put => {
            const layout = try catalog.layout_parse(arena, body, table);
            switch (try layouts.layout_put(arena, table, &layout)) {
                .incompatible => return error_reply(
                    arena,
                    .E0302,
                    409,
                    "a layout may only be extended by appending fields",
                    .no,
                ),
                inline else => |outcome| {
                    try out.print("{{\"table\":{},\"layout\":\"{s}\"}}", .{
                        table,
                        @tagName(outcome),
                    });
                    return .{ .status = 200, .body = out.items() };
                },
            }
        },
        .post => unreachable,
    }
}

fn views(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    method: Method,
    name: []const u8,
    query: []const u8,
    body: []const u8,
) !Reply {
    try catalog.view_name_validate(name);
    var out = Writer.init(arena);
    switch (method) {
        .get => return view_answer(arena, client, layouts, name, query),
        .put => {
            const view = try catalog.view_parse(arena, body);
            try table_check(view.table);
            const layout = try layouts.layout(arena, view.table) orelse
                return bad("a view needs a layout for its table (PUT /v1/tables/<t>)");
            try catalog.view_check(&view, &layout);
            // A view declared differently is refused before the state machine sees it; one the
            // state machine refuses over a ledger's field is not written to the catalog (N75).
            var cataloged = false;
            if (try layouts.view(arena, name)) |existing| {
                const same = std.mem.eql(
                    u8,
                    try catalog.view_render(arena, &existing),
                    try catalog.view_render(arena, &view),
                );
                if (!same) return error_reply(
                    arena,
                    .E0308,
                    409,
                    "a view with this name is declared differently; views are immutable",
                    .no,
                );
                cataloged = true;
            }
            const definition = catalog.view_definition(name, &view, &layout);
            const declared = try client.declare_view(&definition);
            // Not yet in the catalog: the state machine decides the name. Another gateway may
            // have declared it, then stalled before writing its document; writing this one would
            // leave two definitions under one name for good (#70). That gateway's retry finds
            // `exists` and writes its document.
            if (!cataloged) switch (declared.status) {
                .ledger_field => return error_reply(
                    arena,
                    .E0309,
                    409,
                    "the view filters or groups by a field of a ledger",
                    .no,
                ),
                .different => return error_reply(
                    arena,
                    .E0308,
                    409,
                    "a view with this name is declared differently; views are immutable",
                    .no,
                ),
                // `view_check` refuses min and max over records first; an older gateway's
                // catalog document may still name one.
                .unsupported => return error_reply(
                    arena,
                    .E0307,
                    409,
                    "the state machine does not maintain this view",
                    .no,
                ),
                else => {},
            };
            switch (try layouts.view_put(arena, name, &view)) {
                .different => return error_reply(
                    arena,
                    .E0308,
                    409,
                    "a view with this name is declared differently; views are immutable",
                    .no,
                ),
                inline else => |outcome| {
                    // The state machine maintains it from now on (N52), unless it refused it.
                    const reason: ?[]const u8 = switch (declared.status) {
                        .created, .exists => null,
                        // Only for a document already in the catalog (as `.different`).
                        .unsupported => "min and max are not maintained over records",
                        .table_extremes_full => "the table's views have too many min and max " ++
                            "aggregates (at most 4)",
                        .views_full => "the cluster's views are full",
                        .table_views_full => "the table's views are full",
                        // Only for a document already in the catalog: one written before the
                        // state machine refused it, kept as it is (#70).
                        .different => "declared differently in the state machine",
                        .ledger_field => "the view filters or groups by a field of a ledger",
                        .invalid, .table_invalid => "refused by the state machine",
                    };
                    try out.print("{{\"view\":\"{s}\",\"declared\":\"{s}\",\"maintained\":{}", .{
                        name,
                        @tagName(outcome),
                        reason == null,
                    });
                    if (reason) |text| {
                        try out.raw(",\"reason\":");
                        try std.json.stringify(text, .{}, out.list.writer());
                    }
                    try out.raw("}");
                    return .{ .status = 200, .body = out.items() };
                },
            }
        },
        .post => unreachable,
    }
}

/// Groups of a view maintained by the state machine (N52), in storage order, with the view's
/// state, hash and group count as of the read's op.
///
///     GET /v1/views/<name>/groups?cursor=<c>&limit=<n>&as_of=<op>
///
/// With `as_of`, the view as that op left it (N62); `as_of` must already be committed, and a
/// page holds at most 128 groups.
fn view_groups(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    name: []const u8,
    query: []const u8,
) !Reply {
    try catalog.view_name_validate(name);
    const parameters = try query_parse(arena, query, &.{ "cursor", "limit", "as_of" });
    const cursor = if (parameters.get("cursor")) |text| try u64_parse(text, "cursor") else 0;
    const as_of: u64 = if (parameters.get("as_of")) |text| as_of: {
        const op = try u64_parse(text, "as_of");
        if (op == 0) return bad("as_of must be positive");
        break :as_of op;
    } else 0;
    const limit = if (parameters.get("limit")) |text|
        try limit_parse(text)
    else
        page_limit_max;

    const view = try layouts.view(arena, name) orelse return error_reply(arena, .E0402, 404, "no such view", .no);
    const layout = try layouts.layout(arena, view.table) orelse return error.Corrupt;

    var query_view: nerva.ViewQuery = .{
        .view_id = 0,
        .group_hash_min = cursor,
        .as_of = as_of,
        .limit = limit,
    };
    @memcpy(query_view.name[0..name.len], name);
    const records = try arena.alloc(nerva.ViewRecord, limit + 1);
    const count = try client.get_view(query_view, records);
    assert(count >= 1);
    const header = records[0];
    assert(header.kind == .header);
    if (as_of != 0 and as_of >= header.op) return not_committed("as_of is not yet committed");
    if (header.state == .missing) {
        if (as_of != 0) return error_reply(arena, .E0403, 404, "the view was declared after as_of", .no);
        return error_reply(arena, .E0406, 404, "this view is not maintained by the state machine", .no);
    }

    var out = Writer.init(arena);
    try out.print("{{\"view\":\"{s}\",\"id\":{},\"state\":\"{s}\",\"op\":", .{
        name,
        header.view_id,
        @tagName(header.state),
    });
    try out.number(header.op);
    try out.raw(",\"declared_op\":");
    try out.number(header.declared_op);
    if (as_of != 0) {
        try out.raw(",\"as_of\":");
        try out.number(as_of);
    }
    try out.raw(",\"view_hash\":");
    try out.hex(&header.hash);
    try out.raw(",\"group_count\":");
    try out.number(header.group_count);
    try out.raw(",\"groups\":[");
    for (records[1..count], 0..) |*record, index| {
        assert(record.kind == .group);
        if (index > 0) try out.raw(",");
        try out.raw("{");
        // The group key's fields, placed back at their offsets, render as the layout says.
        var value: [nerva.record_value_size]u8 = @splat(0);
        var key_offset: usize = 0;
        for (view.group_by) |field_name| {
            const field = layout.field(field_name).?;
            @memcpy(value[field.offset..][0..field.size], record.group_key[key_offset..][0..field.size]);
            key_offset += field.size;
            try out.print("\"{s}\":", .{field_name});
            try catalog.field_render(out.list.writer(), field, &value);
            try out.raw(",");
        }
        try out.raw("\"count\":");
        try out.number(record.count);
        for (view.aggregates, 0..) |aggregate, slot| {
            if (aggregate.function == .count) continue;
            try out.print(",\"{s}_{s}\":\"{}\"", .{
                @tagName(aggregate.function),
                aggregate.field.?,
                std.mem.readInt(i128, &record.sums[slot], .little),
            });
        }
        try out.raw("}");
    }
    try out.print("],\"more\":{},\"cursor\":", .{header.flags.more});
    if (header.flags.more) try out.number(header.cursor) else try out.raw("null");
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

// ---- Parsing ----

pub fn json_parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownField => bad("unknown field"),
        error.MissingField => bad("missing field"),
        else => bad("malformed JSON"),
    };
}

pub fn u64_parse(text: []const u8, comptime name: []const u8) error{BadRequest}!u64 {
    // Decimal digits only: no sign, no spaces, no leading `+`.
    if (text.len == 0 or text.len > 20) return bad(name ++ " must be a decimal string");
    for (text) |c| if (c < '0' or c > '9') return bad(name ++ " must be a decimal string");
    return std.fmt.parseInt(u64, text, 10) catch bad(name ++ " is out of range");
}

fn table_parse(text: ?[]const u8) error{BadRequest}!u32 {
    const value = try u64_parse(text orelse return bad("table is required"), "table");
    if (value > std.math.maxInt(u32)) return bad("table is out of range");
    try table_check(@intCast(value));
    return @intCast(value);
}

fn table_check(table: u32) error{BadRequest}!void {
    if (table == 0) return bad("table must not be zero");
    if (table >= catalog.tables_reserved_min) return bad("table is reserved");
}

/// A view's declaration (N34), as stored in the catalog.
///
///     GET /v1/views/<name>/definition
fn view_definition(arena: std.mem.Allocator, layouts: anytype, name: []const u8) !Reply {
    try catalog.view_name_validate(name);
    const view = try layouts.view(arena, name) orelse return error_reply(arena, .E0402, 404, "no such view", .no);
    return .{ .status = 200, .body = try catalog.view_render(arena, &view) };
}

/// The views the state machine maintains, in declaration order (N66).
///
///     GET /v1/views
fn view_list(arena: std.mem.Allocator, client: anytype) !Reply {
    var out = Writer.init(arena);
    try out.raw("{\"views\":[");
    var records: [2]nerva.ViewRecord = undefined;
    for (1..nerva.views_max + 1) |id| {
        const count = try client.get_view(.{ .view_id = id, .group_hash_min = 0, .limit = 1 }, &records);
        assert(count >= 1);
        const header = records[0];
        assert(header.kind == .header);
        if (header.state == .missing) break;
        if (id > 1) try out.raw(",");
        const name_size = std.mem.indexOfScalar(u8, &header.group_key, 0) orelse
            header.group_key.len;
        try out.print("{{\"name\":\"{s}\",\"id\":{},\"state\":\"{s}\",\"declared_op\":", .{
            header.group_key[0..name_size],
            id,
            @tagName(header.state),
        });
        try out.number(header.declared_op);
        try out.raw(",\"group_count\":");
        try out.number(header.group_count);
        try out.raw("}");
    }
    try out.raw("]}");
    return .{ .status = 200, .body = out.items() };
}

/// A view maintained by the state machine, whole, as `nerva view` answers it (N35, N66): the
/// groups sorted by key, and `hash`, the SHA-256 of the `groups` JSON as served, so that the two
/// can be compared byte for byte. Also `view_hash`, the replicated hash (N52), and
/// `declared_op`. Every page is read at one op: the first at the latest (or `as_of`), the rest
/// as of the first's. A view with more than `view_answer_groups_max` groups is read from
/// `/groups` instead.
///
///     GET /v1/views/<name>?min_op=<n|latest>
///     GET /v1/views/<name>?as_of=<op>
///
/// As in `nerva view`, an op not yet committed answers 504. A view still building, or failed,
/// answers 503: its groups are not yet the view's.
fn view_answer(
    arena: std.mem.Allocator,
    client: anytype,
    layouts: anytype,
    name: []const u8,
    query: []const u8,
) !Reply {
    const parameters = try query_parse(arena, query, &.{ "min_op", "as_of" });
    const min_op: ?u64 = if (parameters.get("min_op")) |text|
        if (std.mem.eql(u8, text, "latest")) null else try u64_parse(text, "min_op")
    else
        null;
    const as_of: u64 = if (parameters.get("as_of")) |text| as_of: {
        const op = try u64_parse(text, "as_of");
        if (op == 0) return bad("as_of must be positive");
        break :as_of op;
    } else 0;
    if (as_of != 0 and parameters.get("min_op") != null) return bad("min_op or as_of, not both");

    const view = try layouts.view(arena, name) orelse return error_reply(arena, .E0402, 404, "no such view", .no);
    const layout = try layouts.layout(arena, view.table) orelse return error.Corrupt;

    const records = try arena.alloc(nerva.ViewRecord, page_limit_max + 1);
    var groups: std.ArrayListUnmanaged(declared_views.Group) = .{};
    var read_op: ?u64 = null;
    var view_hash: [32]u8 = undefined;
    var declared_op: u64 = 0;
    var cursor: u64 = 0;
    while (true) {
        var query_view: nerva.ViewQuery = .{
            .view_id = 0,
            .group_hash_min = cursor,
            .limit = page_limit_max,
            // Every page after the first as of the first's op: one answer, at one op.
            .as_of = if (read_op) |op| op else as_of,
        };
        @memcpy(query_view.name[0..name.len], name);
        const count = try client.get_view(query_view, records);
        assert(count >= 1);
        const header = records[0];
        assert(header.kind == .header);
        if (read_op == null) {
            read_op = header.op;
            // Committed ops are below the read's own.
            if (as_of >= header.op) return not_committed("as_of is not yet committed");
            if (min_op) |op| {
                if (op >= header.op) return not_committed("min_op is not yet committed");
            }
            switch (header.state) {
                .ready => {},
                .missing => return if (as_of != 0)
                    error_reply(arena, .E0403, 404, "the view was declared after as_of", .no)
                else
                    error_reply(
                        arena,
                        .E0406,
                        404,
                        "this view is not maintained by the state machine",
                        .no,
                    ),
                .building => return error_reply(arena, .E0404, 503, "the view is still building", .no),
                .failed => return error_reply(
                    arena,
                    .E0405,
                    503,
                    "the view failed (a hash collision)",
                    .no,
                ),
            }
            view_hash = header.hash;
            declared_op = header.declared_op;
        } else {
            assert(header.state == .ready);
            assert(std.mem.eql(u8, &header.hash, &view_hash));
        }
        if (groups.items.len + count - 1 > view_answer_groups_max) {
            return bad("the view has more groups than one answer holds: read it from /groups");
        }
        for (records[1..count]) |*record| {
            assert(record.kind == .group);
            var group: declared_views.Group = .{
                .sample = @splat(0),
                .count = record.count,
                .values = @splat(0),
            };
            // The group key's fields, placed back at their offsets.
            var key_offset: usize = 0;
            for (view.group_by) |field_name| {
                const field = layout.field(field_name).?;
                @memcpy(
                    group.sample[field.offset..][0..field.size],
                    record.group_key[key_offset..][0..field.size],
                );
                key_offset += field.size;
            }
            for (view.aggregates, 0..) |_, slot| {
                group.values[slot] = std.mem.readInt(i128, &record.sums[slot], .little);
            }
            try groups.append(arena, group);
        }
        if (!header.flags.more) break;
        cursor = header.cursor;
    }

    const answer = try declared_views.render(arena, &view, &layout, groups.items);
    var out = Writer.init(arena);
    try out.print("{{\"view\":\"{s}\",\"op\":", .{name});
    try out.number(if (as_of != 0) as_of else read_op.?);
    try out.raw(",\"hash\":");
    try out.hex(&answer.hash);
    try out.raw(",\"view_hash\":");
    try out.hex(&view_hash);
    try out.raw(",\"declared_op\":");
    try out.number(declared_op);
    try out.raw(",\"groups\":");
    try out.raw(answer.groups);
    try out.raw("}");
    return .{ .status = 200, .body = out.items() };
}

pub fn limit_parse(text: ?[]const u8) error{BadRequest}!u32 {
    const value = try u64_parse(text orelse return bad("limit is required"), "limit");
    if (value == 0) return bad("limit must be positive");
    return @intCast(@min(value, page_limit_max));
}

/// A commit key: 16 bytes as 32 hex digits, not all zero. The bytes are the key's row value's
/// first 16 (`nerva.CommitKey`), so the key is them read little-endian.
pub fn key_parse(text: []const u8) error{BadRequest}!u128 {
    if (text.len != 32) return bad("key must be 16 bytes of hex");
    var bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return bad("key is not hex");
    const key = std.mem.readInt(u128, &bytes, .little);
    if (key == 0) return bad("key must not be zero");
    return key;
}

fn value_parse(text: []const u8) error{BadRequest}![value_size]u8 {
    return (try value_parse_sized(text, value_size))[0..value_size].*;
}

/// A row's value (`size` 80) or a record's (448, P123b), zero-padded.
fn value_parse_sized(
    text: []const u8,
    size: u16,
) error{BadRequest}![nerva.record_value_size]u8 {
    if (text.len % 2 != 0 or text.len > @as(usize, size) * 2) {
        return bad(if (size == value_size)
            "value_hex must be at most 80 bytes of hex"
        else
            "value_hex must be at most 448 bytes of hex");
    }
    var value: [nerva.record_value_size]u8 = @splat(0);
    _ = std.fmt.hexToBytes(value[0 .. text.len / 2], text) catch return bad("value_hex is not hex");
    return value;
}

/// A row's id, a decimal string; or a record's (P123b), 16 bytes as 32 hex digits, read
/// little-endian (so that `Writer.id` writes the same digits back).
pub fn id_parse(table: u32, text: []const u8) error{BadRequest}!u128 {
    if (!nerva.table_is_record(table)) return try u64_parse(text, "id");
    if (text.len != 32) return bad("a record's id is 16 bytes of hex");
    var bytes: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch return bad("a record's id is not hex");
    return std.mem.readInt(u128, &bytes, .little);
}

/// `commit`'s form of a row's entry (P123b).
fn narrow_entry(wide: *const nerva.WideEntry) Entry {
    assert(!nerva.table_is_record(wide.table));
    assert(wide.id <= std.math.maxInt(u64));
    assert(stdx.zeroed(&wide.reserved_b));
    return .{
        .id = @intCast(wide.id),
        .table = wide.table,
        .kind = wide.kind,
        .op_seen = wide.op_seen,
        .value = wide.value[0..value_size].*,
    };
}

/// Query parameters; each at most once, and only those listed.
pub fn query_parse(
    arena: std.mem.Allocator,
    query: []const u8,
    comptime allowed: []const []const u8,
) !std.StringHashMapUnmanaged([]const u8) {
    var parameters: std.StringHashMapUnmanaged([]const u8) = .{};
    if (query.len == 0) return parameters;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return bad("malformed query");
        const name = pair[0..equals];
        inline for (allowed) |allowed_name| {
            if (std.mem.eql(u8, name, allowed_name)) break;
        } else return bad("unknown query parameter");
        const entry = try parameters.getOrPut(arena, name);
        if (entry.found_existing) return bad("repeated query parameter");
        entry.value_ptr.* = pair[equals + 1 ..];
    }
    return parameters;
}

// ---- Rendering ----

/// An error reply: `{"error": reason, "applied": …, "code": …}`. The `error` text keeps its
/// spelling for the clients that match on it; `code` is registered in docs/ERRORS.md and
/// `applied` says whether the request may have changed the cluster (P168b).
pub fn error_reply(
    arena: std.mem.Allocator,
    code: Code,
    status: u16,
    reason: []const u8,
    applied: Applied,
) !Reply {
    var out = Writer.init(arena);
    try out.raw("{\"error\":");
    try std.json.stringify(reason, .{}, out.list.writer());
    try out.print(",\"applied\":{s},\"code\":\"{s}\"}}", .{ applied.json(), code.text() });
    return .{ .status = status, .body = out.items() };
}

/// Whether a request that failed may have changed the cluster, when `Client.writes_sent` was
/// `writes_before` as it began and is `writes_now` now: `unknown` if a write went out, `no` if
/// not (P168b). A count that went backwards (a client replaced meanwhile) is a change.
pub fn applied_since(writes_before: u64, writes_now: u64) Applied {
    return if (writes_now == writes_before) .no else .unknown;
}

/// Closes the `{…}` object in `out` with `"applied":false,"code":…`: the reply to a request the
/// cluster refused, which changed nothing.
pub fn refused_reply(out: *Writer, status: u16, code: Code) !Reply {
    assert(out.list.items[out.list.items.len - 1] == '}');
    _ = out.list.pop();
    try out.print(",\"applied\":false,\"code\":\"{s}\"}}", .{code.text()});
    return .{ .status = status, .body = out.items() };
}

pub const Writer = struct {
    list: std.ArrayList(u8),

    pub fn init(arena: std.mem.Allocator) Writer {
        return .{ .list = std.ArrayList(u8).init(arena) };
    }

    pub fn items(writer: *const Writer) []const u8 {
        return writer.list.items;
    }

    pub fn raw(writer: *Writer, text: []const u8) !void {
        try writer.list.appendSlice(text);
    }

    pub fn print(writer: *Writer, comptime format: []const u8, args: anytype) !void {
        try writer.list.writer().print(format, args);
    }

    /// A 64-bit number, as a decimal string.
    pub fn number(writer: *Writer, value: u64) !void {
        try writer.print("\"{}\"", .{value});
    }

    /// An add's field value, as a decimal string of its type.
    fn field_value(writer: *Writer, field: nerva.Add.AddField, bits: u64) !void {
        switch (field) {
            .u64 => try writer.number(bits),
            .i64 => try writer.print("\"{}\"", .{@as(i64, @bitCast(bits))}),
            _ => unreachable,
        }
    }

    /// A row's id as a decimal string, a record's as 32 hex digits (`id_parse`).
    pub fn id(writer: *Writer, table: u32, value: u128) !void {
        if (nerva.table_is_record(table)) {
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &bytes, value, .little);
            try writer.hex(&bytes);
        } else {
            try writer.number(@intCast(value));
        }
    }

    pub fn hex(writer: *Writer, bytes: []const u8) !void {
        try writer.print("\"{s}\"", .{std.fmt.fmtSliceHexLower(bytes)});
    }

    /// `,"fields":{…}` if the table has a layout.
    fn fields(writer: *Writer, layout: ?*const catalog.Layout, value: []const u8) !void {
        const layout_ = layout orelse return;
        try writer.raw(",\"fields\":");
        try catalog.fields_render(writer.list.writer(), layout_, value);
    }
};

// ---- Tests ----

const testing = std.testing;

/// An in-memory client with Nerva's semantics for one-transaction requests, to test the
/// translation without a cluster. `tests/api/api.py` checks the real thing.
const window_remaining_divisor = @import("../client.zig").window_remaining_divisor;

const FakeClient = struct {
    op: u64 = 0,
    rows: std.AutoArrayHashMapUnmanaged(u128, Version) = .{},
    records: std.AutoArrayHashMapUnmanaged(u128, RecordVersion) = .{},
    /// Commit keys: the op and a hash of the entries each committed.
    keys: std.AutoArrayHashMapUnmanaged(u128, struct { op: u64, hash: u64 }) = .{},
    /// Answers the key entry of a keyed transaction with this status at op 7, for the tests of
    /// the statuses a real cluster gives rarely (`key_collision`) or never (anything else).
    key_answer: ?nerva.EntryStatus = null,
    allocator: std.mem.Allocator,
    /// Answers `declare_view`, for the tests that set it; the rest are covered by
    /// `tests/views/maintained.py`.
    declared: ?nerva.DeclareStatus = null,
    /// The most events one batch takes (rows to look up, or entries of a transaction).
    lookup_max: usize = std.math.maxInt(usize),
    /// The most events all the batches of one request hold together.
    batch_events_max: usize = std.math.maxInt(usize),
    /// Cluster requests received (a batch of many is one).
    requests: u32 = 0,
    /// From this batch of a request of several on, a transaction is refused `views_busy`, as the
    /// state machine does for one that the op's views budget no longer holds. Alone it commits.
    busy_from: usize = std.math.maxInt(usize),
    /// How many transactions were refused so.
    busy: u32 = 0,
    /// The next request times out.
    timeout_next: bool = false,
    /// Requests of a write received, as `Client.writes_sent` counts them: it counts one that
    /// then times out.
    writes_sent: u64 = 0,
    /// From this write of a write on (counting from 1), a request is refused `Expired` before it
    /// is sent, as a client does once the request's window has passed.
    expire_from_write: u64 = std.math.maxInt(u64),
    /// From this write of a write on (counting from 1), a request is sent and then times out.
    timeout_from_write: u64 = std.math.maxInt(u64),
    /// The request's window, as `Client.Options` has it: `timeout_ns` is `--request-timeout`
    /// (0: no clock), `window_end_ns` the absolute end, `now_ns` the fake clock. Every cluster
    /// call, a layout read included, costs `cost_ns` of it.
    timeout_ns: u64 = 0,
    window_end_ns: u64 = 0,
    now_ns: u64 = 0,
    cost_ns: u64 = 0,

    const Version = struct { op: u64, exists: bool, value: [value_size]u8 };
    const RecordVersion = struct { op: u64, exists: bool, value: [nerva.record_value_size]u8 };

    pub const Error = error{ TooManyEvents, OutOfMemory, Timeout, Expired };

    /// Opens the request's window of `timeout_ns` at the fake clock, as the gateway does once.
    fn window_open(fake: *FakeClient, timeout_ns: u64) void {
        assert(timeout_ns >= window_remaining_divisor);
        fake.timeout_ns = timeout_ns;
        fake.window_end_ns = fake.now_ns + timeout_ns;
    }

    /// Before a call is sent: refused `Expired` when less than `timeout / 16` of the window is
    /// left, as `Client.ensure_idle` does. No clock: always sent.
    fn call_begin(fake: *const FakeClient) Error!void {
        if (fake.timeout_ns == 0) return;
        const min = fake.timeout_ns / window_remaining_divisor;
        if (fake.now_ns + min > fake.window_end_ns) return error.Expired;
    }

    /// After a call was sent: it takes `cost_ns`, and a reply past the window is a `Timeout`.
    fn call_end(fake: *FakeClient) Error!void {
        if (fake.timeout_ns == 0) return;
        fake.now_ns += fake.cost_ns;
        if (fake.now_ns > fake.window_end_ns) return error.Timeout;
    }

    /// A read of the catalog from the cluster, which one layout read of a request is. It is not
    /// counted in `requests`, which the tests of batching count.
    fn read_call(fake: *FakeClient) Error!void {
        try fake.call_begin();
        try fake.call_end();
    }

    pub fn batches_fit(fake: *const FakeClient, comptime operation: nerva.Operation, counts: []const u32) bool {
        _ = operation;
        if (counts.len == 0 or counts.len > group_max) return false;
        var total: usize = 0;
        for (counts) |count| {
            if (count == 0 or count > fake.lookup_max) return false;
            total += count;
        }
        return total <= fake.batch_events_max;
    }

    pub fn lookup_rows_batches(
        fake: *FakeClient,
        keys: []const []const RowKey,
        results: []const []RowValue,
    ) Error!void {
        var counts: [group_max]u32 = undefined;
        for (keys, counts[0..keys.len]) |batch, *count| count.* = @intCast(batch.len);
        if (!fake.batches_fit(.lookup_rows, counts[0..keys.len])) return error.TooManyEvents;
        if (fake.timeout_next) return error.Timeout;
        fake.requests += 1;
        fake.op += 1;
        for (keys, results) |batch, result| fake.lookup_rows_at(fake.op, batch, result);
    }

    pub fn commit_batches(
        fake: *FakeClient,
        transactions: []const []const Entry,
        results: []const []EntryResult,
    ) Error!void {
        var counts: [group_max]u32 = undefined;
        for (transactions, counts[0..transactions.len]) |batch, *count| count.* = @intCast(batch.len);
        if (!fake.batches_fit(.commit, counts[0..transactions.len])) return error.TooManyEvents;
        try fake.call_begin();
        if (fake.writes_sent + 1 >= fake.expire_from_write) return error.Expired;
        fake.writes_sent += 1;
        if (fake.timeout_next or fake.writes_sent >= fake.timeout_from_write) {
            return error.Timeout;
        }
        try fake.call_end();
        fake.requests += 1;
        fake.op += 1;
        for (transactions, results, 0..) |entries, result, index| {
            if (fake.refuse_busy(index, result)) continue;
            try fake.commit_at(fake.op, entries, result);
        }
    }

    pub fn commit_wide_batches(
        fake: *FakeClient,
        transactions: []const []const nerva.WideEntry,
        results: []const []EntryResult,
    ) Error!void {
        var counts: [group_max]u32 = undefined;
        for (transactions, counts[0..transactions.len]) |batch, *count| count.* = @intCast(batch.len);
        if (!fake.batches_fit(.commit_wide, counts[0..transactions.len])) return error.TooManyEvents;
        try fake.call_begin();
        if (fake.writes_sent + 1 >= fake.expire_from_write) return error.Expired;
        fake.writes_sent += 1;
        if (fake.timeout_next or fake.writes_sent >= fake.timeout_from_write) {
            return error.Timeout;
        }
        try fake.call_end();
        fake.requests += 1;
        fake.op += 1;
        for (transactions, results, 0..) |entries, result, index| {
            if (fake.refuse_busy(index, result)) continue;
            try fake.commit_wide_at(fake.op, entries, result);
        }
    }

    fn refuse_busy(fake: *FakeClient, index: usize, results: []EntryResult) bool {
        if (index < fake.busy_from) return false;
        fake.busy += 1;
        for (results, 0..) |*result, i| result.* = if (i == 0)
            .{ .status = .views_busy, .op = 0 }
        else
            .{ .status = .aborted, .op = 0 };
        return true;
    }

    pub fn lookup_rows(fake: *FakeClient, keys: []const RowKey, results: []RowValue) Error!void {
        if (keys.len > fake.lookup_max) return error.TooManyEvents;
        fake.requests += 1;
        fake.op += 1;
        fake.lookup_rows_at(fake.op, keys, results);
    }

    fn lookup_rows_at(fake: *FakeClient, op: u64, keys: []const RowKey, results: []RowValue) void {
        for (keys, results) |key, *result| {
            const found = fake.rows.get(nerva.row_key(key.table, key.id));
            result.* = .{
                .id = key.id,
                .table = key.table,
                .flags = .{ .exists = if (found) |f| f.exists else false },
                .op = if (found) |f| f.op else 0,
                .op_read = op,
                .value = if (found) |f| f.value else @splat(0),
            };
        }
    }

    pub fn commit(fake: *FakeClient, entries: []const Entry, results: []EntryResult) Error!void {
        if (entries.len > fake.lookup_max) return error.TooManyEvents;
        try fake.call_begin();
        if (fake.writes_sent + 1 >= fake.expire_from_write) return error.Expired;
        fake.writes_sent += 1;
        if (fake.writes_sent >= fake.timeout_from_write) return error.Timeout;
        try fake.call_end();
        fake.requests += 1;
        fake.op += 1;
        try fake.commit_at(fake.op, entries, results);
    }

    /// A transaction of the op `op`, which may hold others before it.
    fn commit_at(fake: *FakeClient, op: u64, entries: []const Entry, results: []EntryResult) Error!void {
        const keyed = entries[0].kind == .key;
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(entries[1..]));
        if (keyed) {
            if (fake.key_answer) |status| {
                results[0] = .{ .status = status, .op = 7 };
                @memset(results[1..], .{ .status = .aborted, .op = 0 });
                return;
            }
            if (fake.keys.get(nerva.CommitKey.entry_key(&entries[0]))) |committed| {
                results[0] = .{
                    .status = if (committed.hash == hash) .committed_before else .key_reused,
                    .op = committed.op,
                };
                @memset(results[1..], .{ .status = .aborted, .op = 0 });
                return;
            }
        }
        for (entries, 0..) |entry, index| {
            if (entry.kind != .read) continue;
            const found = fake.rows.get(nerva.row_key(entry.table, entry.id));
            const version = if (found) |f| f.op else 0;
            if (version != entry.op_seen) {
                for (results, 0..) |*result, i| result.* = if (i == index)
                    .{ .status = .conflict, .op = version }
                else
                    .{ .status = .aborted, .op = 0 };
                return;
            }
        }
        // Adds of a u64 field, without a partner, clamp or create: the amount lands, or the
        // field would cross its `min` (`out_of_bounds`), or the row is absent.
        for (entries, 0..) |entry, index| {
            if (entry.kind != .add) continue;
            const add = nerva.Add.from_entry(&entry);
            assert(add.field == .u64 and !add.flags.clamp and !add.flags.create);
            const found = fake.rows.get(nerva.row_key(entry.table, entry.id));
            const status: nerva.EntryStatus, const value: u64 = if (found == null or !found.?.exists)
                .{ .row_absent, 0 }
            else status: {
                const current = std.mem.readInt(u64, found.?.value[add.offset..][0..8], .little);
                const sum = @as(i128, current) + add.delta;
                break :status if (sum < 0 or (add.flags.min and sum < add.min))
                    .{ .out_of_bounds, current }
                else
                    .{ .ok, @intCast(sum) };
            };
            if (status == .ok) continue;
            for (results, 0..) |*result, i| result.* = if (i == index)
                .{ .status = status, .op = 0, .value = value }
            else
                .{ .status = .aborted, .op = 0 };
            return;
        }
        if (keyed) {
            try fake.keys.put(fake.allocator, nerva.CommitKey.entry_key(&entries[0]), .{
                .op = op,
                .hash = hash,
            });
        }
        @memset(results, .{ .status = .ok, .op = op });
        for (entries, results) |entry, *result| {
            if (entry.kind == .read or entry.kind == .key) continue;
            var value = entry.value;
            if (entry.kind == .add) {
                const add = nerva.Add.from_entry(&entry);
                var row_value = fake.rows.get(nerva.row_key(entry.table, entry.id)).?.value;
                const current = std.mem.readInt(u64, row_value[add.offset..][0..8], .little);
                const next: u64 = @intCast(@as(i128, current) + add.delta);
                std.mem.writeInt(u64, row_value[add.offset..][0..8], next, .little);
                value = row_value;
                result.applied = add.delta;
                result.value = next;
            }
            try fake.rows.put(fake.allocator, nerva.row_key(entry.table, entry.id), .{
                .op = op,
                .exists = entry.kind != .delete,
                .value = value,
            });
        }
    }

    pub fn commit_wide(
        fake: *FakeClient,
        entries: []const nerva.WideEntry,
        results: []EntryResult,
    ) Error!void {
        if (entries.len > fake.lookup_max) return error.TooManyEvents;
        fake.requests += 1;
        fake.op += 1;
        try fake.commit_wide_at(fake.op, entries, results);
    }

    fn commit_wide_at(
        fake: *FakeClient,
        op: u64,
        entries: []const nerva.WideEntry,
        results: []EntryResult,
    ) Error!void {
        const keyed = entries[0].kind == .key;
        const hash = std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(entries[1..]));
        if (keyed) {
            if (fake.keys.get(std.mem.readInt(u128, entries[0].value[0..16], .little))) |committed| {
                results[0] = .{
                    .status = if (committed.hash == hash) .committed_before else .key_reused,
                    .op = committed.op,
                };
                @memset(results[1..], .{ .status = .aborted, .op = 0 });
                return;
            }
        }
        for (entries, 0..) |*entry, index| {
            if (entry.kind != .read) continue;
            const version = if (fake.written(entry)) |found| found.op else 0;
            if (version != entry.op_seen) {
                for (results, 0..) |*result, i| result.* = if (i == index)
                    .{ .status = .conflict, .op = version }
                else
                    .{ .status = .aborted, .op = 0 };
                return;
            }
        }
        if (keyed) {
            try fake.keys.put(
                fake.allocator,
                std.mem.readInt(u128, entries[0].value[0..16], .little),
                .{ .op = op, .hash = hash },
            );
        }
        for (entries) |*entry| {
            if (entry.kind == .read or entry.kind == .key) continue;
            assert(entry.kind == .put or entry.kind == .delete);
            if (nerva.table_is_record(entry.table)) {
                try fake.records.put(fake.allocator, nerva.record_key(entry.table, entry.id), .{
                    .op = op,
                    .exists = entry.kind == .put,
                    .value = entry.value,
                });
            } else {
                try fake.rows.put(fake.allocator, nerva.row_key(entry.table, @intCast(entry.id)), .{
                    .op = op,
                    .exists = entry.kind == .put,
                    .value = entry.value[0..value_size].*,
                });
            }
        }
        @memset(results, .{ .status = .ok, .op = op });
    }

    fn written(fake: *FakeClient, entry: *const nerva.WideEntry) ?struct { op: u64 } {
        if (nerva.table_is_record(entry.table)) {
            const found = fake.records.get(nerva.record_key(entry.table, entry.id)) orelse
                return null;
            return .{ .op = found.op };
        }
        const found = fake.rows.get(nerva.row_key(entry.table, @intCast(entry.id))) orelse
            return null;
        return .{ .op = found.op };
    }

    pub fn lookup_records(
        fake: *FakeClient,
        keys: []const nerva.RecordKey,
        results: []nerva.RecordValue,
    ) Error!void {
        fake.op += 1;
        for (keys, results) |key, *result| {
            const found = fake.records.get(nerva.record_key(key.table, key.id));
            result.* = .{
                .id = key.id,
                .table = key.table,
                .flags = .{ .exists = if (found) |f| f.exists else false },
                .op = if (found) |f| f.op else 0,
                .op_read = fake.op,
                .value = if (found) |f| f.value else @splat(0),
            };
        }
    }

    pub fn get_changes(_: *FakeClient, _: nerva.ChangesFilter, _: []Change) Error!usize {
        unreachable; // Covered by `tests/api/api.py`.
    }

    pub fn get_record_changes(
        _: *FakeClient,
        _: nerva.ChangesFilter,
        _: []nerva.RecordChange,
    ) Error!usize {
        unreachable; // Covered by `tests/api/records.py`.
    }

    pub fn get_record_history(
        _: *FakeClient,
        _: nerva.RecordHistoryFilter,
        _: []nerva.RecordChange,
    ) Error!usize {
        unreachable; // Covered by `tests/api/records.py`.
    }

    pub fn declare_index(
        _: *FakeClient,
        _: *const nerva.IndexDefinition,
    ) Error!nerva.DeclareIndexResult {
        unreachable; // Covered by `tests/api/records.py`.
    }

    pub fn scan_index(_: *FakeClient, _: nerva.IndexQuery, _: []nerva.IndexRecord) Error!usize {
        unreachable; // Covered by `tests/api/records.py`.
    }

    /// No index is declared.
    pub fn get_index(_: *FakeClient, _: u64) Error!nerva.Index {
        return std.mem.zeroes(nerva.Index);
    }

    pub fn get_history(_: *FakeClient, _: nerva.HistoryFilter, _: []Change) Error!usize {
        unreachable; // Covered by `tests/api/api.py`.
    }

    pub fn declare_view(
        fake: *FakeClient,
        _: *const nerva.ViewDefinition,
    ) Error!nerva.DeclareResult {
        fake.op += 1;
        const status = fake.declared.?;
        const known = status == .created or status == .exists;
        return .{
            .status = status,
            .view_id = @intFromBool(known),
            .op = if (known) fake.op else 0,
        };
    }

    pub fn get_view(_: *FakeClient, _: nerva.ViewQuery, _: []nerva.ViewRecord) Error!usize {
        unreachable; // Covered by `tests/views/maintained.py`.
    }

    pub fn declare_ledger(
        _: *FakeClient,
        _: *const nerva.LedgerDefinition,
    ) Error!nerva.DeclareLedgerResult {
        unreachable; // Covered by `tests/api/ledgers.py`.
    }

    pub fn get_ledger(_: *FakeClient, _: u32) Error!nerva.Ledger {
        unreachable; // Covered by `tests/api/ledgers.py`.
    }
};

/// An in-memory catalog.
const FakeLayouts = struct {
    map: std.AutoHashMapUnmanaged(u32, catalog.Layout) = .{},
    views: std.StringHashMapUnmanaged(catalog.View) = .{},
    allocator: std.mem.Allocator,
    /// Where each layout's version is visible, as in the catalog (`layout_probe`): rows of the
    /// client, at the table's id.
    client: ?*FakeClient = null,
    cache: layout_cache.LayoutCache = .{},
    /// How many layouts were read from the log.
    reads: u32 = 0,

    pub fn layout(fake: *FakeLayouts, _: std.mem.Allocator, table: u32) !?catalog.Layout {
        return fake.map.get(table);
    }

    pub fn layout_cached(
        fake: *FakeLayouts,
        arena: std.mem.Allocator,
        table: u32,
    ) !?layout_cache.Cached {
        return fake.cache.find(arena, table);
    }

    pub fn layout_fresh(fake: *FakeLayouts, _: std.mem.Allocator, table: u32) !LayoutRead {
        fake.reads += 1;
        if (fake.client) |client| try client.read_call();
        const found = fake.map.get(table);
        const version = if (fake.client) |client|
            if (client.rows.get(nerva.row_key(catalog.table_catalog, table))) |row_| row_.op else 0
        else
            0;
        if (found) |*layout_| fake.cache.store(table, version, layout_) else fake.cache.forget(table);
        return .{ .layout = found, .version = version };
    }

    pub fn layout_probe(_: *const FakeLayouts, table: u32) RowKey {
        return .{ .id = table, .table = catalog.table_catalog };
    }

    pub fn layout_put(
        fake: *FakeLayouts,
        _: std.mem.Allocator,
        table: u32,
        new: *const catalog.Layout,
    ) !LayoutPut {
        const outcome: LayoutPut = if (fake.map.get(table)) |old| outcome: {
            if (!catalog.layout_extends(&old, new)) break :outcome .incompatible;
            break :outcome if (old.fields.len == new.fields.len) .unchanged else .extended;
        } else .created;
        if (outcome != .incompatible) {
            try fake.map.put(fake.allocator, table, new.*);
            fake.cache.forget(table);
            if (fake.client) |client| {
                client.op += 1;
                try client.rows.put(fake.allocator, nerva.row_key(catalog.table_catalog, table), .{
                    .op = client.op,
                    .exists = true,
                    .value = @splat(0),
                });
            }
        }
        return outcome;
    }

    pub fn view(fake: *FakeLayouts, _: std.mem.Allocator, name: []const u8) !?catalog.View {
        return fake.views.get(name);
    }

    pub fn view_put(
        fake: *FakeLayouts,
        arena: std.mem.Allocator,
        name: []const u8,
        new: *const catalog.View,
    ) !ViewPut {
        if (fake.views.get(name)) |old| {
            const same = std.mem.eql(
                u8,
                try catalog.view_render(arena, &old),
                try catalog.view_render(arena, new),
            );
            return if (same) .unchanged else .different;
        }
        try fake.views.put(fake.allocator, name, new.*);
        return .created;
    }
};

var no_layouts_instance: FakeLayouts = .{ .allocator = testing.failing_allocator };
const no_layouts = &no_layouts_instance;

test "api: layouts give puts and reads named fields" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const declare =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"}]}
    ;
    const created = try handle(arena, &fake, &layouts, .put, "/v1/tables/7", declare);
    try testing.expectEqualStrings(
        \\{"table":7,"layout":"created"}
    , created.body);
    const again = try handle(arena, &fake, &layouts, .put, "/v1/tables/7", declare);
    try testing.expectEqualStrings(
        \\{"table":7,"layout":"unchanged"}
    , again.body);
    const narrowed = try handle(arena, &fake, &layouts, .put, "/v1/tables/7",
        \\{"name":"seats","fields":[{"name":"section","type":"u16"}]}
    );
    try testing.expectEqual(@as(u16, 409), narrowed.status);

    const put = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2,"price":"4500"}}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":7,"id":"1"}]}
    );
    try testing.expect(std.mem.endsWith(u8, found.body,
        \\,"fields":{"section":2,"price":"4500"}}]}
    ));

    const get = try handle(arena, &fake, &layouts, .get, "/v1/tables/7", "");
    try testing.expectEqualStrings(declare, get.body);
    const missing = try handle(arena, &fake, &layouts, .get, "/v1/tables/8", "");
    try testing.expectEqual(@as(u16, 404), missing.status);

    // Fields need a layout; an unknown field, both forms, or a reserved table are refused.
    const refused = [_]struct { target: []const u8, body: []const u8 }{
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":8,"id":"1","fields":{"a":1}}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"row":1}}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{},"value_hex":"00"}]}
        },
        .{ .target = "/v1/commit", .body = 
        \\{"entries":[{"kind":"delete","table":7,"id":"1","fields":{}}]}
        },
        .{ .target = "/v1/lookup", .body = 
        \\{"rows":[{"table":4294901761,"id":"1"}]}
        },
    };
    for (refused) |case| {
        const reply = try handle(arena, &fake, &layouts, .post, case.target, case.body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    try testing.expectEqual(
        @as(u16, 400),
        (try handle(arena, &fake, &layouts, .put, "/v1/tables/4294901761", declare)).status,
    );
}

/// What another gateway does: extends the layout of `table` in the log, which this one has kept.
fn layout_extended_elsewhere(
    arena: std.mem.Allocator,
    layouts: *FakeLayouts,
    client: *FakeClient,
    table: u32,
    json: []const u8,
) !void {
    const new = try catalog.layout_parse(arena, json, table);
    try testing.expect(catalog.layout_extends(&layouts.map.get(table).?, &new));
    try layouts.map.put(arena, table, new);
    client.op += 1;
    try client.rows.put(arena, nerva.row_key(catalog.table_catalog, table), .{
        .op = client.op,
        .exists = true,
        .value = @splat(0),
    });
}

test "api: kept layouts save the log ops of a submit, and never answer for an old layout (P135)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena, .client = &fake };

    const v1 =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"}]}
    ;
    const v2 =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
    ++
        \\{"name":"tier","type":"u8"}]}
    ;
    try testing.expectEqual(
        @as(u16, 200),
        (try handle(arena, &fake, &layouts, .put, "/v1/tables/7", v1)).status,
    );
    const put = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2,"price":"4500"}}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    const reads = layouts.reads;

    // Kept: a lookup is one op and a commit is one op, and neither reads a layout.
    const ops = fake.op;
    const lookup_body =
        \\{"rows":[{"table":7,"id":"1"}]}
    ;
    const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup", lookup_body);
    try testing.expect(std.mem.endsWith(u8, found.body,
        \\,"fields":{"section":2,"price":"4500"}}]}
    ));
    const put_again = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":3,"price":"1"}}]}
    );
    try testing.expectEqual(@as(u16, 200), put_again.status);
    try testing.expectEqual(ops + 2, fake.op);
    try testing.expectEqual(reads, layouts.reads);

    // Another gateway appends a field. A lookup here shows it, in the same one op.
    try layout_extended_elsewhere(arena, &layouts, &fake, 7, v2);
    const ops_lookup = fake.op;
    const extended = try handle(arena, &fake, &layouts, .post, "/v1/lookup", lookup_body);
    try testing.expectEqual(ops_lookup + 1, fake.op);
    try testing.expectEqual(reads + 1, layouts.reads);
    try testing.expect(std.mem.endsWith(u8, extended.body,
        \\,"fields":{"section":3,"price":"1","tier":0}}]}
    ));

    // A put naming the new field, to a gateway that has not seen it, is not refused.
    try layout_extended_elsewhere(arena, &layouts, &fake, 7,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
    ++
        \\{"name":"tier","type":"u8"},{"name":"zone","type":"u8"}]}
    );
    const reads_before = layouts.reads;
    const named = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"2","fields":{"tier":4,"zone":9}}]}
    );
    try testing.expectEqual(@as(u16, 200), named.status);
    try testing.expectEqual(reads_before + 1, layouts.reads);
    const two = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":7,"id":"2"}]}
    );
    try testing.expect(std.mem.endsWith(u8, two.body,
        \\,"fields":{"section":0,"price":"0","tier":4,"zone":9}}]}
    ));

    // A field no layout has is still refused, after the log is asked.
    const unknown = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"3","fields":{"nope":1}}]}
    );
    try testing.expectEqual(@as(u16, 400), unknown.status);
}

test "api: a lookup checks kept layouts in a second op when they do not fit its batch (P135)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena, .client = &fake };

    const v1 =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"}]}
    ;
    _ = try handle(arena, &fake, &layouts, .put, "/v1/tables/7", v1);
    _ = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2}}]}
    );
    try layout_extended_elsewhere(arena, &layouts, &fake, 7,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"tier","type":"u8"}]}
    );
    fake.lookup_max = 1;
    const ops = fake.op;
    const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":7,"id":"1"}]}
    );
    try testing.expectEqual(ops + 2, fake.op);
    try testing.expect(std.mem.endsWith(u8, found.body,
        \\,"fields":{"section":2,"tier":0}}]}
    ));
    // Too many rows alone is still refused as before.
    fake.lookup_max = 0;
    const refused = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":7,"id":"1"}]}
    );
    try testing.expectEqual(@as(u16, 400), refused.status);
}

test "api: a layout that is behind the log encodes the bytes of the log's, or is refused (P135)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const old = try catalog.layout_parse(arena,
        \\{"name":"t","fields":[{"name":"a","type":"u8"},{"name":"b","type":"u64"}]}
    , 7);
    const new = try catalog.layout_parse(arena,
        \\{"name":"t","fields":[{"name":"a","type":"u8"},{"name":"b","type":"u64"},
    ++
        \\{"name":"c","type":"i64"}]}
    , 7);
    try testing.expect(catalog.layout_extends(&old, &new));
    const bodies = [_][]const u8{
        "{}",
        \\{"a":1}
        ,
        \\{"b":"18446744073709551615"}
        ,
        \\{"a":255,"b":7}
        ,
    };
    for (bodies) |body| {
        const object = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqualSlices(
            u8,
            &(try catalog.fields_encode(&old, object)),
            &(try catalog.fields_encode(&new, object)),
        );
    }
    const object = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"c":1}
    , .{});
    try testing.expectError(error.Invalid, catalog.fields_encode(&old, object));
    for (old.fields) |field| {
        const extended = new.field(field.name).?;
        try testing.expectEqual(field.offset, extended.offset);
        try testing.expectEqual(field.type, extended.type);
        try testing.expectEqual(field.size, extended.size);
    }
}

test "api: a view is cataloged only under the definition the state machine holds (#70)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const table =
        \\{"name":"t","fields":[{"name":"kind","type":"i64"},{"name":"amount","type":"i64"}]}
    ;
    const declared = try handle(arena, &fake, &layouts, .put, "/v1/tables/60", table);
    try testing.expectEqual(@as(u16, 200), declared.status);
    const by_kind =
        \\{"table":60,"group_by":["kind"],"aggregates":[{"fn":"count"}]}
    ;
    const total =
        \\{"table":60,"aggregates":[{"fn":"sum","field":"amount"}]}
    ;

    // Another gateway declared `v` as `by_kind` and has not yet written its document: this one,
    // declaring `total`, is refused and writes nothing.
    fake.declared = .different;
    const refused = try handle(arena, &fake, &layouts, .put, "/v1/views/v", total);
    try testing.expectEqual(@as(u16, 409), refused.status);
    try testing.expect(layouts.views.get("v") == null);
    // So is a view over a ledger's field.
    fake.declared = .ledger_field;
    const viewed = try handle(arena, &fake, &layouts, .put, "/v1/views/v", total);
    try testing.expectEqual(@as(u16, 409), viewed.status);
    try testing.expect(layouts.views.get("v") == null);
    // The other gateway's retry finds its view in the state machine and writes the document.
    fake.declared = .exists;
    const written = try handle(arena, &fake, &layouts, .put, "/v1/views/v", by_kind);
    try testing.expectEqual(@as(u16, 200), written.status);
    try testing.expect(layouts.views.get("v") != null);

    // A document cataloged while the table's views were full; a ledger then took its field. The
    // same PUT again answers as before, with the state machine's reason.
    fake.declared = .table_views_full;
    const cataloged = try handle(arena, &fake, &layouts, .put, "/v1/views/w", by_kind);
    try testing.expectEqual(@as(u16, 200), cataloged.status);
    try testing.expect(std.mem.indexOf(u8, cataloged.body, "\"maintained\":false") != null);
    fake.declared = .ledger_field;
    const again = try handle(arena, &fake, &layouts, .put, "/v1/views/w", by_kind);
    try testing.expectEqual(@as(u16, 200), again.status);
    try testing.expect(std.mem.indexOf(u8, again.body, "\"maintained\":false") != null);
    try testing.expect(std.mem.indexOf(u8, again.body, "a field of a ledger") != null);
}

test "api: lookup and commit translate to and from JSON" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    const lookup_5 =
        \\{"rows":[{"table":1,"id":"5"}]}
    ;

    const absent = try handle(arena, &fake, no_layouts, .post, "/v1/lookup", lookup_5);
    try testing.expectEqual(@as(u16, 200), absent.status);
    try testing.expectEqualStrings(
        \\{"op":"1","rows":[{"table":1,"id":"5","exists":false,"op":"0","value_hex":"
    ++ "00" ** 80 ++
        \\"}]}
    , absent.body);

    const put = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"read","table":1,"id":"5","op_seen":"0"},
        \\            {"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"2"}
    , put.body);

    const found = try handle(arena, &fake, no_layouts, .post, "/v1/lookup", lookup_5);
    try testing.expectEqualStrings(
        \\{"op":"3","rows":[{"table":1,"id":"5","exists":true,"op":"2","value_hex":"c0ffee
    ++ "00" ** 77 ++
        \\"}]}
    , found.body);

    // The same read again is stale: 409 with the row's current version, nothing applied.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"delete","table":1,"id":"6"},
        \\            {"kind":"read","table":1,"id":"5","op_seen":"0"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","index":1,"op":"2","applied":false,"code":"NRV-E0202"}
    , stale.body);
}

test "api: records are committed and read by 128-bit id, beside rows (P123b)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const declared = try handle(arena, &fake, &layouts, .put, "/v1/tables/2147483649",
        \\{"name":"facts","fields":[{"name":"status","type":"u8"},{"name":"note","type":"bytes","size":200}]}
    );
    try testing.expectEqual(@as(u16, 200), declared.status);

    // One transaction writes a row and a record: `commit_wide`.
    const put = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":1,"id":"5","value_hex":"01"},
        \\  {"kind":"put","table":2147483649,"id":"0123456789abcdef0123456789abcdef",
        \\   "fields":{"status":2,"note":"68656c6c6f"}}]}
    );
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1"}
    , put.body);
    try testing.expectEqual(@as(usize, 1), fake.records.count());
    try testing.expectEqual(@as(usize, 1), fake.rows.count());

    const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup",
        \\{"rows":[{"table":2147483649,"id":"0123456789abcdef0123456789abcdef"}]}
    );
    try testing.expectEqual(@as(u16, 200), found.status);
    try testing.expect(std.mem.indexOf(u8, found.body,
        \\"id":"0123456789abcdef0123456789abcdef","exists":true,"op":"1"
    ) != null);
    try testing.expect(std.mem.indexOf(u8, found.body,
        \\"fields":{"status":2,
    ) != null);

    // A record's id is exactly 32 hex digits; a row's is a decimal u64.
    const refused = [_][]const u8{
        \\{"rows":[{"table":2147483649,"id":"5"}]}
        ,
        \\{"rows":[{"table":2147483649,"id":"0123456789abcdef0123456789abcdeg"}]}
        ,
        \\{"rows":[{"table":1,"id":"0123456789abcdef0123456789abcdef"}]}
        ,
    };
    for (refused) |body| {
        const reply = try handle(arena, &fake, &layouts, .post, "/v1/lookup", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }

    // Adds are refused on record tables before reaching the cluster.
    const add = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"add","table":2147483649,"id":"0123456789abcdef0123456789abcdef","field":"status","delta":"1"}]}
    );
    try testing.expect(add.status == 400 or add.status == 409);

    // No index is declared: the list is empty and a scan is 404.
    const list = try handle(arena, &fake, &layouts, .get, "/v1/indexes", "");
    try testing.expectEqualStrings(
        \\{"indexes":[]}
    , list.body);
    const scan = try handle(arena, &fake, &layouts, .post, "/v1/indexes/open/scan", "{}");
    try testing.expectEqual(@as(u16, 404), scan.status);
}

test "api: a commit under a key commits once" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    const put =
        \\{"key":"0123456789abcdef0123456789abcdef",
        \\ "entries":[{"kind":"read","table":1,"id":"5","op_seen":"0"},
        \\            {"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
    ;

    const first = try handle(arena, &fake, no_layouts, .post, "/v1/commit", put);
    try testing.expectEqual(@as(u16, 200), first.status);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1"}
    , first.body);

    // Its resend applies nothing, and answers the op it committed at.
    const resend = try handle(arena, &fake, no_layouts, .post, "/v1/commit", put);
    try testing.expectEqual(@as(u16, 200), resend.status);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1","replayed":true,"code":"NRV-W0201"}
    , resend.body);

    // Other entries under the same key never commit.
    const reused = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"key":"0123456789abcdef0123456789abcdef",
        \\ "entries":[{"kind":"read","table":1,"id":"5","op_seen":"1"},
        \\            {"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
    );
    try testing.expectEqual(@as(u16, 409), reused.status);
    try testing.expectEqualStrings(
        \\{"status":"key_reused","op":"1","applied":false,"code":"NRV-E0207"}
    , reused.body);

    // Under another key, indices are the request's: the key entry is not counted.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"key":"00000000000000000000000000000001",
        \\ "entries":[{"kind":"read","table":1,"id":"5","op_seen":"0"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","index":0,"op":"1","applied":false,"code":"NRV-E0202"}
    , stale.body);

    const keys_bad = [_][]const u8{
        "00000000000000000000000000000000",
        "0123456789abcdef",
        "0123456789abcdef0123456789abcdef00",
        "0123456789abcdef0123456789abcdeg",
    };
    for (keys_bad) |key| {
        const body = try std.fmt.allocPrint(arena,
            \\{{"key":"{s}","entries":[{{"kind":"read","table":1,"id":"5","op_seen":"1"}}]}}
        , .{key});
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/commit", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
}

test "api: bad requests are refused before reaching the cluster" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };

    const Case = struct { method: Method, target: []const u8, body: []const u8, status: u16 };
    const lookup_bad = [_][]const u8{
        \\{"rows":[]}
        ,
        \\{"rows":[{"table":0,"id":"1"}]}
        ,
        \\{"rows":[{"table":1,"id":1}]}
        ,
        \\{"rows":[{"table":1,"id":"-1"}]}
        ,
        \\{"rows":[{"table":1,"id":"18446744073709551616"}]}
        ,
        \\{"rows":[{"table":1,"id":"1","x":1}]}
        ,
        \\not json
    };
    const commit_bad = [_][]const u8{
        \\{"entries":[{"kind":"read","table":1,"id":"1"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"0"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"
        ++ "00" ** 81 ++
            \\"}]}
        ,
        \\{"entries":[{"kind":"delete","table":1,"id":"1","op_seen":"1"}]}
        ,
        \\{"entries":[{"kind":"merge","table":1,"id":"1"}]}
    };
    const get_bad = [_][]const u8{
        "/v1/changes", // No limit.
        "/v1/changes?limit=0",
        "/v1/changes?limit=1&limit=2",
        "/v1/changes?limit=1&other=2",
        "/v1/history?table=1&limit=1",
        "/v1/history?table=1&id=1&op_max=0&limit=1",
        "/v1/row?table=1&id=1",
        "/v1/row?table=1&id=1&as_of=0",
    };

    var cases = std.ArrayList(Case).init(arena);
    try cases.append(.{ .method = .post, .target = "/v1/nope", .body = "{}", .status = 404 });
    try cases.append(.{ .method = .get, .target = "/v1/commit", .body = "", .status = 405 });
    for (lookup_bad) |body| {
        try cases.append(.{ .method = .post, .target = "/v1/lookup", .body = body, .status = 400 });
    }
    for (commit_bad) |body| {
        try cases.append(.{ .method = .post, .target = "/v1/commit", .body = body, .status = 400 });
    }
    for (get_bad) |target| {
        try cases.append(.{ .method = .get, .target = target, .body = "", .status = 400 });
    }

    for (cases.items) |case| {
        const reply = try handle(arena, &fake, no_layouts, case.method, case.target, case.body);
        testing.expectEqual(case.status, reply.status) catch |err| {
            std.debug.print("{s} {s}: {s}\n", .{ case.target, case.body, reply.body });
            return err;
        };
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"error\":"));
        try expect_coded(arena, reply, false);
    }
    try testing.expectEqual(@as(u64, 0), fake.op); // Nothing reached the cluster.
    try testing.expectEqual(@as(u64, 0), fake.writes_sent);
}

/// `reply` is a refusal: it names a code registered in `Code`, and says whether the request may
/// have been applied (`"unknown"` if `unknown`, else `false`).
fn expect_coded(arena: std.mem.Allocator, reply: Reply, unknown: bool) !void {
    const Coded = struct { code: []const u8, applied: std.json.Value };
    const parsed = try std.json.parseFromSliceLeaky(Coded, arena, reply.body, .{
        .ignore_unknown_fields = true,
    });
    try testing.expect(std.mem.startsWith(u8, parsed.code, "NRV-"));
    try testing.expect(std.meta.stringToEnum(Code, parsed.code["NRV-".len..]) != null);
    if (unknown) {
        try testing.expectEqualStrings("unknown", parsed.applied.string);
    } else {
        try testing.expectEqual(false, parsed.applied.bool);
    }
}

test "api: a refusal that is not a malformed request carries its code" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };

    // A read at the op just made, and one past it: not committed yet is 504 on every route.
    const put = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    const early = try handle(arena, &fake, no_layouts, .get, "/v1/row?table=1&id=1&as_of=99", "");
    try testing.expectEqual(@as(u16, 504), early.status);
    try expect_coded(arena, early, false);
    try testing.expect(std.mem.indexOf(u8, early.body, "NRV-E0401") != null);
    const early_document = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get",
        \\{"namespace":"7","keys":["a"],"as_of":"99"}
    );
    try testing.expectEqual(@as(u16, 504), early_document.status);

    // A transaction the cluster refuses: nothing applied, with its code.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"read","table":1,"id":"1","op_seen":"0"},
        \\ {"kind":"put","table":1,"id":"1","value_hex":"02"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try expect_coded(arena, stale, false);
    try testing.expect(std.mem.indexOf(u8, stale.body, "NRV-E0202") != null);

    // A key the cluster has seen: the replay says so.
    const keyed =
        \\{"key":"00000000000000000000000000000001","entries":[{"kind":"put","table":1,"id":"2","value_hex":"01"}]}
    ;
    _ = try handle(arena, &fake, no_layouts, .post, "/v1/commit", keyed);
    const replayed = try handle(arena, &fake, no_layouts, .post, "/v1/commit", keyed);
    try testing.expectEqual(@as(u16, 200), replayed.status);
    try testing.expect(std.mem.indexOf(u8, replayed.body, "\"code\":\"NRV-W0201\"") != null);
}

test "api: a request that sent a write and lost the cluster is unknown; one that sent none is not" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    // Two commits travel together and the cluster does not answer: a write went out.
    fake.timeout_next = true;
    const commit_bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
    };
    var commits: [2]Member = undefined;
    for (&commits, commit_bodies) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    const writes_before = fake.writes_sent;
    try testing.expectError(error.Timeout, handle_group(arena, &fake, no_layouts, &commits));
    try testing.expectEqual(Applied.unknown, applied_since(writes_before, fake.writes_sent));

    // Two lookups do the same: nothing was written.
    const lookup_bodies = [_][]const u8{
        \\{"rows":[{"table":1,"id":"1"}]}
        ,
        \\{"rows":[{"table":1,"id":"2"}]}
    };
    var lookups: [2]Member = undefined;
    for (&lookups, lookup_bodies) |*member, body| member.* = .{ .target = "/v1/lookup", .body = body };
    const reads_before = fake.writes_sent;
    try testing.expectError(error.Timeout, handle_group(arena, &fake, no_layouts, &lookups));
    try testing.expectEqual(Applied.no, applied_since(reads_before, fake.writes_sent));

    // A write refused before it was sent: the count did not move.
    fake.timeout_next = false;
    const refused_before = fake.writes_sent;
    const refused = try handle(arena, &fake, no_layouts, .post, "/v1/commit", "{");
    try testing.expectEqual(@as(u16, 400), refused.status);
    try testing.expectEqual(Applied.no, applied_since(refused_before, fake.writes_sent));
}

test "api: a documents commit under a key commits once (P123)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    const put =
        \\{"key":"0123456789abcdef0123456789abcdef","namespace":"7",
        \\ "reads":[{"key":"cart/1","version":"0"}],
        \\ "writes":[{"key":"cart/1","value_hex":"c0ffee"}]}
    ;
    const first = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit", put);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1"}
    , first.body);

    // Its resend applies nothing, and answers the op it committed at.
    const resend = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit", put);
    try testing.expectEqual(@as(u16, 200), resend.status);
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1","replayed":true,"code":"NRV-W0201"}
    , resend.body);

    // Other reads and writes under the key never commit.
    const reused = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"key":"0123456789abcdef0123456789abcdef","namespace":"7",
        \\ "writes":[{"key":"cart/1","value_hex":"01"}]}
    );
    try testing.expectEqual(@as(u16, 409), reused.status);
    try testing.expectEqualStrings(
        \\{"status":"key_reused","op":"1","applied":false,"code":"NRV-E0207"}
    , reused.body);

    // A conflict under another key names the document, not an index, and frees the key.
    // (The key is `...01`: it must commit now, not replay.)
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"key":"00000000000000000000000000000001","namespace":"7",
        \\ "reads":[{"key":"cart/1","version":"0"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","key":"cart/1","version":"1","applied":false,"code":"NRV-E0503"}
    , stale.body);

    // The conflict freed the key: resent with a read that holds, it commits, not replays.
    const freed = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"key":"00000000000000000000000000000001","namespace":"7",
        \\ "reads":[{"key":"cart/1","version":"1"}],
        \\ "writes":[{"key":"cart/1","value_hex":"01"}]}
    );
    try testing.expectEqual(@as(u16, 200), freed.status);
    try testing.expect(std.mem.startsWith(u8, freed.body, "{\"status\":\"committed\",\"op\":"));
    try testing.expect(std.mem.indexOf(u8, freed.body, "replayed") == null);

    const keys_bad = [_][]const u8{
        "00000000000000000000000000000000",
        "0123456789abcdef",
        "0123456789abcdef0123456789abcdeg",
    };
    for (keys_bad) |key| {
        const body = try std.fmt.allocPrint(arena,
            \\{{"key":"{s}","namespace":"7","writes":[{{"key":"cart/1","value_hex":"01"}}]}}
        , .{key});
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
        try testing.expect(std.mem.indexOf(u8, reply.body, "\"applied\":false") != null);
        try testing.expect(std.mem.indexOf(u8, reply.body, "\"code\":\"NRV-E0109\"") != null);
    }
}

test "api: a key the cluster answers key_collision or an impossible status (P123)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    const cases = [_]struct { target: []const u8, body: []const u8 }{
        .{ .target = "/v1/commit", .body = 
        \\{"key":"0123456789abcdef0123456789abcdef",
        \\ "entries":[{"kind":"put","table":1,"id":"5","value_hex":"c0ffee"}]}
        },
        .{ .target = "/v1/documents/commit", .body = 
        \\{"key":"0123456789abcdef0123456789abcdef","namespace":"7",
        \\ "writes":[{"key":"cart/1","value_hex":"c0ffee"}]}
        },
    };
    for (cases) |route| {
        // Proof that nothing committed under the key: pick another.
        fake.key_answer = .key_collision;
        const collision = try handle(arena, &fake, no_layouts, .post, route.target, route.body);
        try testing.expectEqual(@as(u16, 409), collision.status);
        try testing.expectEqualStrings(
            \\{"status":"key_collision","op":"7","applied":false,"code":"NRV-E0208"}
        , collision.body);

        // A status the gateway's own checks make impossible is the server's fault.
        fake.key_answer = .out_of_bounds;
        const impossible = try handle(arena, &fake, no_layouts, .post, route.target, route.body);
        try testing.expectEqual(@as(u16, 500), impossible.status);
        try testing.expect(std.mem.indexOf(u8, impossible.body, "NRV-B0002") != null);
    }
}

test "api: documents are written, read, conflict and deleted by key" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };

    // 300 bytes: four chunks.
    const value_hex = "ab" ** 300;
    const put = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/1","version":"0"}],
        \\ "writes":[{"key":"cart/1","value_hex":"
    ++ value_hex ++
        \\"}]}
    );
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"1"}
    , put.body);

    const get_body =
        \\{"namespace":"7","keys":["cart/1","cart/2"]}
    ;
    const found = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", get_body);
    try testing.expectEqualStrings(
        \\{"op":"2","documents":[{"key":"cart/1","exists":true,"version":"1","value_hex":"
    ++ value_hex ++
        \\"},{"key":"cart/2","exists":false,"version":"0","value_hex":""}]}
    , found.body);

    // Another namespace holds other documents.
    const other = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get",
        \\{"namespace":"8","keys":["cart/1"]}
    );
    try testing.expect(std.mem.indexOf(u8, other.body, "\"exists\":false") != null);

    // A read at an old version conflicts, naming the key and its version; nothing applies.
    const stale = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/2","version":"0"},
        \\                          {"key":"cart/1","version":"0"}],
        \\ "writes":[{"key":"cart/2","value_hex":"01"}]}
    );
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expectEqualStrings(
        \\{"status":"conflict","key":"cart/1","version":"1","applied":false,"code":"NRV-E0503"}
    , stale.body);

    // A delete is a write: the version moves on, and a read at it can commit.
    const deleted = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit",
        \\{"namespace":"7","reads":[{"key":"cart/1","version":"1"}],
        \\ "writes":[{"key":"cart/1","delete":true}]}
    );
    try testing.expectEqualStrings(
        \\{"status":"committed","op":"6"}
    , deleted.body);
    const gone = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", get_body);
    try testing.expectEqualStrings(
        \\{"op":"7","documents":[{"key":"cart/1","exists":false,"version":"6","value_hex":""},
    ++
        \\{"key":"cart/2","exists":false,"version":"0","value_hex":""}]}
    , gone.body);

    const refused = [_][]const u8{
        \\{"namespace":"7","keys":[]}
        ,
        \\{"namespace":"7","keys":["a","a"]}
        ,
        \\{"namespace":"7","keys":[""]}
        ,
        \\{"namespace":"-1","keys":["a"]}
        ,
        \\{"namespace":"7","keys":["a"],"as_of":"0"}
        ,
        \\{"namespace":"7","keys":["
        ++ "k" ** 1025 ++
            \\"]}
    };
    for (refused) |body| {
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    // An op not committed yet is 504 on every route (NRV-E0401).
    const early = try handle(arena, &fake, no_layouts, .post, "/v1/documents/get",
        \\{"namespace":"7","keys":["a"],"as_of":"99"}
    );
    try testing.expectEqual(@as(u16, 504), early.status);
    const commit_refused = [_][]const u8{
        \\{"namespace":"7"}
        ,
        \\{"namespace":"7","writes":[{"key":"a"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"00","delete":true}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"0"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","delete":true},{"key":"a","delete":true}]}
        ,
        \\{"namespace":"7","reads":[{"key":"a","version":"1"},{"key":"a","version":"1"}]}
        ,
        \\{"namespace":"7","writes":[{"key":"\ud800","delete":true}]}
        ,
        \\{"namespace":"7","writes":[{"key":"a","value_hex":"
        ++ "00" ** (documents.value_size_max + 1) ++
            \\"}]}
    };
    for (commit_refused) |body| {
        const reply = try handle(arena, &fake, no_layouts, .post, "/v1/documents/commit", body);
        try testing.expectEqual(@as(u16, 400), reply.status);
    }
    // Nothing above was written; only the unanswerable `as_of` reached the cluster (a lookup).
    try testing.expectEqual(@as(u64, 8), fake.op);
}

// ---- Requests answered together (P143) ----

/// Runs `bodies`, all for `target`, through `handle_group`.
fn group_run(
    arena: std.mem.Allocator,
    fake: *FakeClient,
    layouts: *FakeLayouts,
    target: []const u8,
    bodies: []const []const u8,
) ![]Member {
    const members = try arena.alloc(Member, bodies.len);
    for (members, bodies) |*member, body| member.* = .{ .target = target, .body = body };
    try handle_group(arena, fake, layouts, members);
    return members;
}

/// A reply with the ops left out: a group commits at one op, one after another at several.
fn without_ops(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8){};
    var index: usize = 0;
    while (index < body.len) {
        const key = "\"op\":";
        if (std.mem.startsWith(u8, body[index..], key)) {
            try out.appendSlice(arena, key ++ "N");
            index += key.len;
            if (body[index] == '"') index += 1;
            while (index < body.len and std.ascii.isDigit(body[index])) index += 1;
            if (body[index] == '"') index += 1;
        } else {
            try out.append(arena, body[index]);
            index += 1;
        }
    }
    return out.items;
}

const group_seed = [_][]const u8{
    \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
    ,
    \\{"entries":[{"kind":"put","table":1,"id":"5","value_hex":"0300000000000000"}]}
};

test "api: requests answered together are answered as each would be alone (P143)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var together: FakeClient = .{ .allocator = arena };
    var alone: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };
    for (group_seed) |body| {
        for ([_]*FakeClient{ &together, &alone }) |fake| {
            try testing.expectEqual(
                @as(u16, 200),
                (try handle(arena, fake, &layouts, .post, "/v1/commit", body)).status,
            );
        }
    }
    const requests_seed = together.requests;

    const bodies = [_][]const u8{
        // 0: commits.
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"aa"}]}
        ,
        // 1: a stale read conflicts.
        \\{"entries":[{"kind":"read","table":1,"id":"1","op_seen":"99"}]}
        ,
        // 2: an add past its minimum.
        \\{"entries":[{"kind":"add","table":1,"id":"5","offset":0,"type":"u64","delta":"-5","min":"0"}]}
        ,
        // 3: invalid, answered before anything is sent.
        \\{"entries":[{"kind":"delete","table":1,"id":"1","value_hex":"00"}]}
        ,
        // 4: an add that fits, after request 2 changed nothing.
        \\{"entries":[{"kind":"add","table":1,"id":"5","offset":0,"type":"u64","delta":"-2","min":"0"}]}
        ,
        // 5: an add to a row that is not there.
        \\{"entries":[{"kind":"add","table":1,"id":"6","offset":0,"type":"u64","delta":"1"}]}
        ,
        // 6: a read of what request 0 wrote in the same op.
        \\{"entries":[{"kind":"read","table":1,"id":"2","op_seen":"0"}]}
        ,
        // 7: a request that is not JSON.
        "{",
    };
    const members = try group_run(arena, &together, &layouts, "/v1/commit", &bodies);
    // One cluster request for the six that reached it.
    try testing.expectEqual(requests_seed + 1, together.requests);

    for (members, bodies) |member, body| {
        const reply = try member.result.?;
        const reference = try handle(arena, &alone, &layouts, .post, "/v1/commit", body);
        try testing.expectEqual(reference.status, reply.status);
        try testing.expectEqualStrings(
            try without_ops(arena, reference.body),
            try without_ops(arena, reply.body),
        );
    }
    try testing.expectEqual(requests_seed + 6, alone.requests);
    // Each answer says the op its own transaction was judged at.
    var expected = std.ArrayListUnmanaged(u8){};
    try expected.writer(arena).print("{{\"status\":\"committed\",\"op\":\"{}\"}}", .{together.op});
    try testing.expectEqualStrings(expected.items, (try members[0].result.?).body);
    try testing.expectEqual(@as(u16, 409), (try members[2].result.?).status);
    try testing.expectEqualStrings(
        \\{"status":"out_of_bounds","index":0,"value":"3","applied":false,"code":"NRV-E0203"}
    , (try members[2].result.?).body);
    try testing.expectEqualStrings(
        \\{"status":"row_absent","index":0,"applied":false,"code":"NRV-E0204"}
    , (try members[5].result.?).body);
}

test "api: a transaction refused views_busy is sent again alone, and the caller never sees it (P143)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena, .busy_from = 2 };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"3","value_hex":"03"}]}
        ,
        \\{"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"put","table":1,"id":"4","value_hex":"04"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"5","value_hex":"05"}]}
    };
    const members = try group_run(arena, &fake, &layouts, "/v1/commit", &bodies);
    // The cluster request, and the three refused sent again, one request each.
    try testing.expectEqual(@as(u32, 3), fake.busy);
    try testing.expectEqual(@as(u32, 1 + 3), fake.requests);
    for (members, 0..) |member, index| {
        const reply = try member.result.?;
        try testing.expectEqual(@as(u16, 200), reply.status);
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"status\":\"committed\""));
        // Committed at the op of its own request.
        const expected_op: u64 = if (index < 2) 1 else 1 + index - 1;
        var expected: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, reply.body, try std.fmt.bufPrint(
            &expected,
            "\"op\":\"{}\"",
            .{expected_op},
        )) != null);
    }
    // Everything landed.
    for (1..6) |id| {
        const found = try handle(arena, &fake, &layouts, .post, "/v1/lookup", try std.fmt.allocPrint(
            arena,
            "{{\"rows\":[{{\"table\":1,\"id\":\"{}\"}}]}}",
            .{id},
        ));
        try testing.expect(std.mem.indexOf(u8, found.body, "\"exists\":true") != null);
    }
}

test "api: a group whose send expires has sent nothing, and each member says so (P195b)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena, .expire_from_write = 1 };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const members = try arena.alloc(Member, group_seed.len);
    for (members, group_seed) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    try testing.expectError(error.Expired, handle_group(arena, &fake, &layouts, members));
    for (members) |member| {
        try testing.expect(member.result == null);
        try testing.expectEqual(Applied.no, member.applied);
    }
    try testing.expectEqual(@as(u64, 0), fake.writes_sent);
}

/// A FakeClient and catalog on one fake clock, table 7 declared, layout 7 not cached, and a
/// window of `timeout_ns` open: the state of the first commit after a reconnect (#186).
fn window_fixture(arena: std.mem.Allocator, fake: *FakeClient, layouts: *FakeLayouts, timeout_ns: u64) !void {
    fake.* = .{ .allocator = arena };
    layouts.* = .{ .allocator = arena, .client = fake };
    _ = try handle(arena, fake, layouts, .put, "/v1/tables/7", declare_seats);
    layouts.cache.forget(7);
    fake.window_open(timeout_ns);
}

const declare_seats =
    \\{"name":"seats","fields":[{"name":"section","type":"u8"}]}
;

const commit_seat =
    \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2}}]}
;

test "api: a layout read and a commit share one window: the commit is refused unsent (#186)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = undefined;
    var layouts: FakeLayouts = undefined;
    const timeout: u64 = 1600;
    // The layout read takes 95% of the window: less than a sixteenth is left for the commit.
    try window_fixture(arena, &fake, &layouts, timeout);
    fake.cost_ns = timeout * 95 / 100;
    const writes_before = fake.writes_sent;
    const refused = handle(arena, &fake, &layouts, .post, "/v1/commit", commit_seat);
    try testing.expectError(error.Expired, refused);
    try testing.expectEqual(@as(u32, 1), layouts.reads);
    try testing.expectEqual(writes_before, fake.writes_sent);
    // The reply the gateway gives: NRV-E0606, nothing written.
    const reply = try server.failure_reply(arena, error.Expired, writes_before, fake.writes_sent);
    try testing.expect(std.mem.indexOf(u8, reply.body, "\"code\":\"NRV-E0606\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.body, "\"applied\":false") != null);
    // The same commit with its layout cached has the whole window and goes out.
    try window_fixture(arena, &fake, &layouts, timeout);
    fake.cost_ns = timeout * 95 / 100;
    _ = try layouts.layout_fresh(arena, 7);
    fake.window_open(timeout);
    const cached = try handle(arena, &fake, &layouts, .post, "/v1/commit", commit_seat);
    try testing.expectEqual(@as(u16, 200), cached.status);
}

test "api: a layout read and a commit that is sent past the shared window time out (#186)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = undefined;
    var layouts: FakeLayouts = undefined;
    const timeout: u64 = 1600;
    // 60% each: the commit starts with 40% left, is sent, and its reply is past the window.
    try window_fixture(arena, &fake, &layouts, timeout);
    fake.cost_ns = timeout * 60 / 100;
    const writes_before = fake.writes_sent;
    const sent = handle(arena, &fake, &layouts, .post, "/v1/commit", commit_seat);
    try testing.expectError(error.Timeout, sent);
    try testing.expectEqual(writes_before + 1, fake.writes_sent);
    // The reply the gateway gives: NRV-E0601, and the write's outcome is unknown, never false.
    const reply = try server.failure_reply(arena, error.Timeout, writes_before, fake.writes_sent);
    try testing.expect(std.mem.indexOf(u8, reply.body, "\"code\":\"NRV-E0601\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.body, "\"applied\":\"unknown\"") != null);
    // One such call alone fits the window.
    try window_fixture(arena, &fake, &layouts, timeout);
    fake.cost_ns = timeout * 60 / 100;
    _ = try layouts.layout_fresh(arena, 7);
    fake.window_open(timeout);
    const alone = try handle(arena, &fake, &layouts, .post, "/v1/commit", commit_seat);
    try testing.expectEqual(@as(u16, 200), alone.status);
}

test "api: a views_busy send again that expires keeps the answers that came back (P195b)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Write 1 is the group's request; writes 2 on expire.
    var fake: FakeClient = .{ .allocator = arena, .busy_from = 2, .expire_from_write = 2 };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"3","value_hex":"03"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"4","value_hex":"04"}]}
    };
    const members = try arena.alloc(Member, bodies.len);
    for (members, bodies) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    try handle_group(arena, &fake, &layouts, members);
    for (members[0..2]) |member| {
        // Committed with the group: its answer is kept, not reported as not sent, and its write
        // went out, so a reply built from it says `unknown` if the request fails later.
        const reply = try member.result.?;
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"status\":\"committed\""));
        try testing.expectEqual(Applied.unknown, member.applied);
    }
    for (members[2..]) |member| {
        // Its batch went out, so it is not `no`; its send again did not.
        try testing.expectError(error.Expired, member.result.?);
        try testing.expectEqual(Applied.unknown, member.applied);
    }
    try testing.expectEqual(@as(u64, 1), fake.writes_sent);
}

test "api: a views_busy send again that times out is unknown for the whole group (P195b)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Write 1 is the group's request; write 2, the send again of the first busy member, is sent
    // and then times out.
    var fake: FakeClient = .{ .allocator = arena, .busy_from = 2, .timeout_from_write = 2 };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"3","value_hex":"03"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"4","value_hex":"04"}]}
    };
    const members = try arena.alloc(Member, bodies.len);
    for (members, bodies) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    try testing.expectError(error.Timeout, handle_group(arena, &fake, &layouts, members));
    // The send again went out: the cluster may have applied it, and every member's write is in
    // the count. Members that had an answer keep it; the rest have none.
    try testing.expectEqual(@as(u64, 2), fake.writes_sent);
    for (members[0..2]) |member| {
        const reply = try member.result.?;
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"status\":\"committed\""));
        try testing.expectEqual(Applied.unknown, member.applied);
    }
    for (members[2..]) |member| {
        try testing.expect(member.result == null);
        try testing.expectEqual(Applied.unknown, member.applied);
    }
}

test "api: a member sent alone after the group expires is not sent, and the group keeps its answers (P195b)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // Two one-entry transactions travel together; the third does not fit and runs alone.
    var fake: FakeClient = .{ .allocator = arena, .batch_events_max = 2, .expire_from_write = 2 };
    var layouts: FakeLayouts = .{ .allocator = arena };
    const bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"3","value_hex":"03"}]}
    };
    const members = try arena.alloc(Member, bodies.len);
    for (members, bodies) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    try testing.expectError(error.Expired, handle_group(arena, &fake, &layouts, members));
    for (members[0..2]) |member| {
        const reply = try member.result.?;
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"status\":\"committed\""));
    }
    try testing.expect(members[2].result == null);
    try testing.expectEqual(Applied.no, members[2].applied);
}

test "api: transactions under one key in one request answer as they would one after another (P123, P143)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const bodies = [_][]const u8{
        \\{"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"put","table":1,"id":"7","value_hex":"07"}]}
        ,
        // The same transaction again: it committed before, at the first one's op.
        \\{"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"put","table":1,"id":"7","value_hex":"07"}]}
        ,
        // The same key for other entries.
        \\{"key":"000102030405060708090a0b0c0d0e0f","entries":[{"kind":"put","table":1,"id":"8","value_hex":"08"}]}
        ,
        // Another key, then it again.
        \\{"key":"ffffffffffffffffffffffffffffffff","entries":[{"kind":"put","table":1,"id":"9","value_hex":"09"}]}
        ,
        \\{"key":"ffffffffffffffffffffffffffffffff","entries":[{"kind":"put","table":1,"id":"9","value_hex":"09"}]}
    };
    const members = try group_run(arena, &fake, &layouts, "/v1/commit", &bodies);
    try testing.expectEqual(@as(u32, 1), fake.requests);
    const op = fake.op;
    const committed = try std.fmt.allocPrint(arena, "{{\"status\":\"committed\",\"op\":\"{}\"}}", .{op});
    const replayed = try std.fmt.allocPrint(
        arena,
        "{{\"status\":\"committed\",\"op\":\"{}\",\"replayed\":true,\"code\":\"NRV-W0201\"}}",
        .{op},
    );
    const reused = try std.fmt.allocPrint(arena, "{{\"status\":\"key_reused\",\"op\":\"{}\",\"applied\":false,\"code\":\"NRV-E0207\"}}", .{op});
    const expected = [_][]const u8{ committed, replayed, reused, committed, replayed };
    const statuses = [_]u16{ 200, 200, 409, 200, 200 };
    for (members, expected, statuses) |member, body, status| {
        const reply = try member.result.?;
        try testing.expectEqual(status, reply.status);
        try testing.expectEqualStrings(body, reply.body);
    }
}

test "api: lookups answered together bring their own probes, and a layout that moved is read again (P135, P143)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena };
    var layouts: FakeLayouts = .{ .allocator = arena, .client = &fake };

    const v1 =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"}]}
    ;
    const v2 =
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
    ++
        \\{"name":"tier","type":"u8"}]}
    ;
    try testing.expectEqual(
        @as(u16, 200),
        (try handle(arena, &fake, &layouts, .put, "/v1/tables/7", v1)).status,
    );
    const put = try handle(arena, &fake, &layouts, .post, "/v1/commit",
        \\{"entries":[{"kind":"put","table":7,"id":"1","fields":{"section":2,"price":"4500"}}]}
    );
    try testing.expectEqual(@as(u16, 200), put.status);

    const lookups = [_][]const u8{
        \\{"rows":[{"table":7,"id":"1"}]}
        ,
        \\{"rows":[{"table":7,"id":"1"},{"table":7,"id":"2"}]}
        ,
        \\{"rows":[{"table":3,"id":"1"}]}
    };
    // The layout is kept: a group reads no layout from the log.
    const reads_before = layouts.reads;
    const requests_before = fake.requests;
    var members = try group_run(arena, &fake, &layouts, "/v1/lookup", &lookups);
    try testing.expectEqual(requests_before + 1, fake.requests);
    try testing.expectEqual(reads_before, layouts.reads);
    for (members, lookups) |member, body| {
        const reference = try handle(arena, &fake, &layouts, .post, "/v1/lookup", body);
        const reply = try member.result.?;
        try testing.expectEqual(reference.status, reply.status);
        try testing.expectEqualStrings(
            try without_ops(arena, reference.body),
            try without_ops(arena, reply.body),
        );
        // Each rows' op_read is the one op of the group.
        try testing.expect(std.mem.startsWith(u8, reply.body, "{\"op\":"));
    }
    try testing.expect(std.mem.indexOf(
        u8,
        (try members[0].result.?).body,
        "\"fields\":{\"section\":2,\"price\":\"4500\"}",
    ) != null);

    // Another gateway extends the layout. The group reads it again before it renders, and every
    // member shows the new field.
    try layout_extended_elsewhere(arena, &layouts, &fake, 7, v2);
    const reads_moved = layouts.reads;
    members = try group_run(arena, &fake, &layouts, "/v1/lookup", &lookups);
    try testing.expect(layouts.reads > reads_moved);
    try testing.expect(std.mem.indexOf(
        u8,
        (try members[0].result.?).body,
        "\"fields\":{\"section\":2,\"price\":\"4500\",\"tier\":0}",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        (try members[1].result.?).body,
        "\"fields\":{\"section\":2,\"price\":\"4500\",\"tier\":0}",
    ) != null);

    // A put by a field only the new layout has: refused first under the kept layout, answered
    // after one look at the log, and a truly unknown field is refused without being sent.
    try layout_extended_elsewhere(arena, &layouts, &fake, 7,
        \\{"name":"seats","fields":[{"name":"section","type":"u8"},{"name":"price","type":"u64"},
    ++
        \\{"name":"tier","type":"u8"},{"name":"row","type":"u8"}]}
    );
    const commits = [_][]const u8{
        \\{"entries":[{"kind":"put","table":7,"id":"3","fields":{"section":1,"row":9}}]}
        ,
        \\{"entries":[{"kind":"put","table":7,"id":"4","fields":{"nope":1}}]}
        ,
        \\{"entries":[{"kind":"put","table":7,"id":"5","fields":{"section":4}}]}
    };
    const requests_commits = fake.requests;
    members = try group_run(arena, &fake, &layouts, "/v1/commit", &commits);
    try testing.expectEqual(@as(u16, 200), (try members[0].result.?).status);
    try testing.expectEqual(@as(u16, 400), (try members[1].result.?).status);
    try testing.expectEqual(@as(u16, 200), (try members[2].result.?).status);
    // The two that were valid travelled together.
    try testing.expectEqual(requests_commits + 1, fake.requests);
}

test "api: what does not fit, or is of another operation, runs alone, and a lost cluster answers nobody (P143)" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var fake: FakeClient = .{ .allocator = arena, .batch_events_max = 3 };
    var layouts: FakeLayouts = .{ .allocator = arena };

    const record = "0123456789abcdef0123456789abcdef";
    const bodies = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        // A record: another operation, alone.
        \\{"entries":[{"kind":"put","table":2147483649,"id":"
        ++ record ++
            \\","value_hex":"02"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"},{"kind":"put","table":1,"id":"3","value_hex":"03"}]}
        ,
        // Does not fit the three events of the request with the two before it: alone.
        \\{"entries":[{"kind":"put","table":1,"id":"4","value_hex":"04"},{"kind":"put","table":1,"id":"5","value_hex":"05"}]}
        ,
        // Fits no request at all: refused as it is alone.
        \\{"entries":[{"kind":"put","table":1,"id":"6","value_hex":"06"},{"kind":"put","table":1,"id":"7","value_hex":"07"},{"kind":"put","table":1,"id":"8","value_hex":"08"},{"kind":"put","table":1,"id":"9","value_hex":"09"}]}
    };
    fake.lookup_max = 3;
    const members = try group_run(arena, &fake, &layouts, "/v1/commit", &bodies);
    // The batch of two (events 1 and 3 together fit), the record, the one that did not fit; the
    // last was refused by the client as it would alone.
    try testing.expectEqual(@as(u32, 3), fake.requests);
    const statuses = [_]u16{ 200, 200, 200, 200, 400 };
    for (members, statuses) |member, status| {
        try testing.expectEqual(status, (try member.result.?).status);
    }

    // A cluster that does not answer: nobody has an answer, except the request refused before.
    fake.timeout_next = true;
    const lost = [_][]const u8{
        \\{"entries":[{"kind":"put","table":1,"id":"1","value_hex":"01"}]}
        ,
        \\{"entries":[{"kind":"put","table":1,"id":"2","value_hex":"02"}]}
        ,
        "{",
    };
    const lost_members = try arena.alloc(Member, lost.len);
    for (lost_members, lost) |*member, body| member.* = .{ .target = "/v1/commit", .body = body };
    try testing.expectError(error.Timeout, handle_group(arena, &fake, &layouts, lost_members));
    try testing.expect(lost_members[0].result == null);
    try testing.expect(lost_members[1].result == null);
    try testing.expectEqual(@as(u16, 400), (try lost_members[2].result.?).status);
}
