//! What a gateway's cluster client counts, kept outside the client (R4, P168e).
//!
//! A `Client` is replaced when it breaks, and a replacement that fails leaves it uninitialized
//! (`Client.reconnect`, `Client.init`). What the gateway reports must survive that, so the
//! gateway owns a `Tally` and the client records into it through `Client.Options.tally`.

const std = @import("std");
const assert = std.debug.assert;

const nerva = @import("../nerva.zig");

/// The count, sum, least and greatest of what a window saw.
pub const Aggregate = struct {
    count: u64 = 0,
    sum: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(aggregate: *Aggregate, value: u64) void {
        aggregate.count += 1;
        aggregate.sum +|= value;
        aggregate.min = @min(aggregate.min, value);
        aggregate.max = @max(aggregate.max, value);
        assert(aggregate.min <= aggregate.max);
        assert(aggregate.count > 0);
    }
};

/// Round trips to the cluster by operation, in nanoseconds: `Client` records, the metrics emitter
/// reads and resets.
pub const OperationTimings = std.enums.EnumArray(nerva.Operation, Aggregate);

/// What a gateway reads of its cluster client across replacements.
pub const Tally = struct {
    operations: OperationTimings = OperationTimings.initFill(.{}),
    /// Requests of any operation sent, ever. A gateway compares it before and after serving, to
    /// know the cluster was asked (and, if the session is still sound, replied): the idle probe
    /// waits for quiet from the cluster, not from clients (P168d).
    requests: u64 = 0,
};

test "a tally keeps what was recorded, and an aggregate's least never passes its greatest" {
    var tally: Tally = .{};
    tally.operations.getPtr(.get_history).record(7);
    tally.operations.getPtr(.get_history).record(3);
    tally.requests += 1;
    const aggregate = tally.operations.get(.get_history);
    try std.testing.expectEqual(@as(u64, 2), aggregate.count);
    try std.testing.expectEqual(@as(u64, 10), aggregate.sum);
    try std.testing.expectEqual(@as(u64, 3), aggregate.min);
    try std.testing.expectEqual(@as(u64, 7), aggregate.max);
}
