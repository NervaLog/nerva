//! A fixed-size log-linear latency histogram, as HdrHistogram does it: values below
//! `sub_bucket_count` µs are exact, and above that each power of two is split into
//! `sub_bucket_count` equal buckets, so a percentile is within 1/`sub_bucket_count` of the truth.
//! No allocation; `merge` combines the histograms of several threads.

const std = @import("std");
const assert = std.debug.assert;

pub const LatencyHistogram = struct {
    /// Buckets per power of two; the relative error is at most 1/`sub_bucket_count`.
    pub const sub_bucket_count = 16;
    const sub_bucket_bits = std.math.log2_int(u64, sub_bucket_count);
    /// The largest recordable value, in µs: about 4.6 hours, far past any request deadline.
    pub const value_max_us: u64 = (1 << 34) - 1;
    const bucket_count = (64 - @as(usize, @clz(value_max_us)) - sub_bucket_bits + 1) * sub_bucket_count;

    counts: [bucket_count]u64 = @splat(0),
    count: u64 = 0,
    max_us: u64 = 0,

    comptime {
        assert(std.math.isPowerOfTwo(sub_bucket_count));
        assert(index_of(value_max_us) == bucket_count - 1);
    }

    pub fn record(histogram: *LatencyHistogram, duration_ns: u64) void {
        const value_us = @min(duration_ns / std.time.ns_per_us, value_max_us);
        histogram.counts[index_of(value_us)] += 1;
        histogram.count += 1;
        histogram.max_us = @max(histogram.max_us, value_us);
    }

    pub fn merge(histogram: *LatencyHistogram, other: *const LatencyHistogram) void {
        for (&histogram.counts, &other.counts) |*count, other_count| count.* += other_count;
        histogram.count += other.count;
        histogram.max_us = @max(histogram.max_us, other.max_us);
    }

    /// The smallest value (µs) at or below which at least `fraction` of the samples lie,
    /// reported as its bucket's upper bound (never below the truth). Zero if empty.
    pub fn percentile_us(histogram: *const LatencyHistogram, fraction: f64) u64 {
        assert(fraction > 0 and fraction <= 1);
        if (histogram.count == 0) return 0;
        const rank: u64 = @intFromFloat(@ceil(fraction * @as(f64, @floatFromInt(histogram.count))));
        var seen: u64 = 0;
        for (histogram.counts, 0..) |count, index| {
            seen += count;
            if (seen >= rank) return @min(upper_bound_of(index), histogram.max_us);
        }
        unreachable;
    }

    fn index_of(value_us: u64) usize {
        assert(value_us <= value_max_us);
        if (value_us < sub_bucket_count) return @intCast(value_us);
        const magnitude: usize = 63 - @as(usize, @clz(value_us)); // >= sub_bucket_bits
        const shift: u6 = @intCast(magnitude - sub_bucket_bits);
        const sub_bucket = (value_us >> shift) - sub_bucket_count; // 0 .. sub_bucket_count - 1
        return @intCast((magnitude - sub_bucket_bits + 1) * sub_bucket_count + sub_bucket);
    }

    /// The largest value (µs) that `index_of` maps to `index`.
    fn upper_bound_of(index: usize) u64 {
        if (index < sub_bucket_count) return index;
        const group: u6 = @intCast(index / sub_bucket_count - 1); // 0 for [16, 32), ...
        const sub_bucket: u64 = index % sub_bucket_count;
        const width = @as(u64, 1) << group;
        return ((sub_bucket_count + sub_bucket) << group) + width - 1;
    }
};

const testing = std.testing;

test "LatencyHistogram: buckets cover every value, in order" {
    var value: u64 = 0;
    var index_previous: usize = 0;
    while (value <= LatencyHistogram.value_max_us) : (value = if (value < 4096) value + 1 else value * 3 / 2) {
        const index = LatencyHistogram.index_of(value);
        try testing.expect(index >= index_previous);
        try testing.expect(value <= LatencyHistogram.upper_bound_of(index));
        if (index > 0) try testing.expect(value > LatencyHistogram.upper_bound_of(index - 1));
        index_previous = index;
    }
}

test "LatencyHistogram: percentiles within the error bound of a sorted array" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var histogram: LatencyHistogram = .{};
    var values: [10_000]u64 = undefined;
    for (&values) |*value| {
        // Log-uniform from 1 µs to about 10 s, like real latencies.
        const exponent = random.float(f64) * 23;
        value.* = @intFromFloat(@exp2(exponent));
        histogram.record(value.* * std.time.ns_per_us);
    }
    std.mem.sortUnstable(u64, &values, {}, std.sort.asc(u64));
    for ([_]f64{ 0.01, 0.5, 0.9, 0.99, 0.999, 1.0 }) |fraction| {
        const rank: usize = @intFromFloat(@ceil(fraction * values.len));
        const exact = values[rank - 1];
        const estimate = histogram.percentile_us(fraction);
        try testing.expect(estimate >= exact);
        try testing.expect(estimate - exact <= exact / LatencyHistogram.sub_bucket_count + 1);
    }
    try testing.expectEqual(values[values.len - 1], histogram.percentile_us(1.0));
}

test "LatencyHistogram: merge, empty, clamp" {
    var a: LatencyHistogram = .{};
    var b: LatencyHistogram = .{};
    try testing.expectEqual(@as(u64, 0), a.percentile_us(0.5));
    for (0..100) |i| a.record(i * std.time.ns_per_us);
    for (100..200) |i| b.record(i * std.time.ns_per_us);
    a.merge(&b);
    try testing.expectEqual(@as(u64, 200), a.count);
    try testing.expectEqual(@as(u64, 199), a.percentile_us(1.0));
    const median = a.percentile_us(0.5);
    try testing.expect(median >= 99 and median <= 99 + 99 / LatencyHistogram.sub_bucket_count + 1);

    var huge: LatencyHistogram = .{};
    huge.record(std.math.maxInt(u64));
    try testing.expectEqual(LatencyHistogram.value_max_us, huge.percentile_us(1.0));
}
