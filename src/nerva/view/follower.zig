//! Follows Nerva's change feed and hands complete ops to a view (docs/DECISIONS.md N22).
//!
//! `get_changes` pages by timestamp; a page can end in the middle of an op. The follower buffers
//! the changes of the op it is in, hands an op to the view only once it is complete, and keeps
//! the watermark: the op through which every change has been applied.

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../../constants.zig");
const nerva = @import("../../nerva.zig");
const Client = @import("../client.zig").Client;

const Change = nerva.Change;

/// Changes per `get_changes` call.
pub const page_limit = 1024;

pub fn FollowerType(comptime View: type) type {
    return struct {
        const Follower = @This();

        client: *Client,
        view: *View,
        /// The next `get_changes` cursor.
        cursor: u64 = 0,
        /// Every change of every op ≤ watermark has been applied.
        watermark: u64 = 0,
        /// Changes of the op not yet known to be complete.
        pending: std.ArrayListUnmanaged(Change) = .{},
        page: []Change,

        pub fn init(allocator: std.mem.Allocator, client: *Client, view: *View) !Follower {
            const page = try allocator.alloc(Change, page_limit + 1);
            errdefer allocator.free(page);
            var pending: std.ArrayListUnmanaged(Change) = .{};
            // One op holds at most one commit request's writes.
            try pending.ensureTotalCapacity(
                allocator,
                nerva.Operation.commit.event_max(constants.message_body_size_max),
            );
            return .{ .client = client, .view = view, .page = page, .pending = pending };
        }

        pub fn deinit(follower: *Follower, allocator: std.mem.Allocator) void {
            follower.pending.deinit(allocator);
            allocator.free(follower.page);
        }

        /// Reads one page of the feed and applies every op it completes. Returns true if the
        /// feed was read to its end (so the watermark is the op of this read).
        pub fn poll(follower: *Follower) !bool {
            const count = try follower.client.get_changes(.{
                .timestamp_min = follower.cursor,
                .limit = page_limit,
            }, follower.page);
            assert(count >= 1);
            const changes = follower.page[0 .. count - 1];
            const end = follower.page[count - 1];
            assert(end.kind == .end);

            for (changes) |*change| {
                assert(change.kind == .put or change.kind == .delete);
                assert(change.op > follower.watermark);
                if (follower.pending.items.len > 0 and
                    follower.pending.items[0].op != change.op)
                {
                    try follower.flush();
                }
                follower.pending.appendAssumeCapacity(change.*);
            }
            follower.cursor = end.timestamp;

            if (end.flags.more) {
                // Every op before the last one seen is complete.
                if (follower.pending.items.len > 0) {
                    const op_last = follower.pending.items[0].op;
                    follower.watermark = @max(follower.watermark, op_last - 1);
                }
                return false;
            }
            try follower.flush();
            assert(end.op >= follower.watermark);
            follower.watermark = end.op;
            return true;
        }

        /// Pages until the feed is read to its end: afterwards the watermark is at or past every
        /// op committed before this call began.
        pub fn catch_up(follower: *Follower) !void {
            while (!try follower.poll()) {}
        }

        fn flush(follower: *Follower) !void {
            if (follower.pending.items.len == 0) return;
            const op = follower.pending.items[0].op;
            try follower.view.apply(op, follower.pending.items);
            follower.watermark = @max(follower.watermark, op);
            follower.pending.clearRetainingCapacity();
        }
    };
}
