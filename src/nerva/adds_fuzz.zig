//! Fuzzes adds' arithmetic (docs/DECISIONS.md N42, N46): `nerva.add_amount` and `nerva.add_apply`
//! against a reference written independently from N42's text, plus properties any applied amount
//! must have, and `entry_validate` on arbitrary add parameters.
//!
//! The VOPR model resolves adds with the same `add_amount` as the state machine, so it cannot
//! catch a mistake in it; this fuzzer is the arithmetic's independent check.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.fuzz_nerva_adds);

const stdx = @import("stdx");
const fuzz = @import("../testing/fuzz.zig");
const nerva = @import("../nerva.zig");

const Add = nerva.Add;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;
    var prng = stdx.PRNG.from_seed(args.seed);
    const events_max = args.events_max orelse 1_000_000;

    var counts: struct { full: u64 = 0, clamped: u64 = 0, refused: u64 = 0, invalid: u64 = 0 } =
        .{};
    for (0..events_max) |_| {
        if (prng.chance(stdx.PRNG.ratio(1, 10))) {
            if (!validate_random(&prng)) counts.invalid += 1;
            continue;
        }

        const add = add_random(&prng);
        const old = value_random(&prng, &add);
        const delta = delta_random(&prng, &add, old);
        const applied = nerva.add_amount(&add, old, delta);
        const expected = amount_reference(&add, old, delta);
        if (applied != expected) {
            std.debug.panic("add_amount: {?} != reference {?}: add={} old={} delta={}", .{
                applied,
                expected,
                add,
                old,
                delta,
            });
        }
        if (applied) |amount| {
            amount_check(&add, old, delta, amount);
            if (amount == delta) counts.full += 1 else counts.clamped += 1;
        } else {
            assert(!add.flags.clamp);
            counts.refused += 1;
        }
    }
    log.info("{} adds: {} applied whole, {} clamped, {} refused; {} invalid parameters", .{
        events_max,
        counts.full,
        counts.clamped,
        counts.refused,
        counts.invalid,
    });
    // The generators reach every outcome (else they have rotted).
    if (events_max >= 10_000) {
        assert(counts.full > 0 and counts.clamped > 0 and counts.refused > 0);
        assert(counts.invalid > 0);
    }
}

/// The field's value, as its type.
fn value_of(add: *const Add, bits: u64) i128 {
    return switch (add.field) {
        .u64 => bits,
        .i64 => @as(i64, @bitCast(bits)),
        _ => unreachable,
    };
}

fn bits_of(add: *const Add, value: i128) u64 {
    assert(value >= type_min(add) and value <= type_max(add));
    return switch (add.field) {
        .u64 => @intCast(value),
        .i64 => @bitCast(@as(i64, @intCast(value))),
        _ => unreachable,
    };
}

fn type_min(add: *const Add) i128 {
    return switch (add.field) {
        .u64 => 0,
        .i64 => std.math.minInt(i64),
        _ => unreachable,
    };
}

fn type_max(add: *const Add) i128 {
    return switch (add.field) {
        .u64 => std.math.maxInt(u64),
        .i64 => std.math.maxInt(i64),
        _ => unreachable,
    };
}

/// Whether moving the field from `old` by `magnitude` in `delta`'s direction stays within the
/// type and does not pass the bound in that direction (N42: "an add never moves the field past
/// `min` (delta negative) or `max` (positive), nor out of the type's range").
fn fits(add: *const Add, old: u64, delta: i64, magnitude: u64) bool {
    if (magnitude == 0) return true;
    const new = if (delta > 0)
        value_of(add, old) + magnitude
    else
        value_of(add, old) - magnitude;
    if (new < type_min(add) or new > type_max(add)) return false;
    if (delta > 0 and add.flags.max and new > value_of(add, add.max)) return false;
    if (delta < 0 and add.flags.min and new < value_of(add, add.min)) return false;
    return true;
}

/// The amount an add applies, from N42's text: all of `delta` if it fits; otherwise, with `clamp`,
/// the largest amount in its direction that fits (found by binary search, as `fits` only shrinks
/// as the amount grows), and without `clamp` none (null).
fn amount_reference(add: *const Add, old: u64, delta: i64) ?i64 {
    assert(delta != std.math.minInt(i64));
    const magnitude: u64 = @abs(delta);
    if (fits(add, old, delta, magnitude)) return delta;
    if (!add.flags.clamp) return null;

    // Invariant: `fits(low)`, and not `fits(high)`.
    var low: u64 = 0;
    var high: u64 = magnitude;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (fits(add, old, delta, middle)) low = middle else high = middle;
    }
    const amount: i64 = @intCast(low);
    return if (delta > 0) amount else -amount;
}

/// Properties of an applied amount, beyond agreeing with the reference.
fn amount_check(add: *const Add, old: u64, delta: i64, applied: i64) void {
    // In `delta`'s direction, and no more than it.
    assert(applied == 0 or (applied > 0) == (delta > 0));
    assert(@abs(applied) <= @abs(delta));
    if (!add.flags.clamp) assert(applied == delta);

    // `add_apply` adds exactly `applied`, within the type.
    const new = nerva.add_apply(add, old, applied);
    assert(value_of(add, new) == value_of(add, old) + applied);

    // Not past the bound in the direction of the move.
    if (applied > 0 and add.flags.max) assert(value_of(add, new) <= value_of(add, add.max));
    if (applied < 0 and add.flags.min) assert(value_of(add, new) >= value_of(add, add.min));

    // Clamped: as much as fits, so one more unit would not.
    if (applied != delta) {
        assert(add.flags.clamp);
        assert(!fits(add, old, delta, @abs(applied) + 1));
    }

    // `delta_from` moves the negated amount back: an unbounded add of `-applied` restores `old`.
    var back = add.*;
    back.flags = .{};
    back.min = 0;
    back.max = 0;
    assert(nerva.add_amount(&back, new, -applied) == -applied);
    assert(nerva.add_apply(&back, new, -applied) == old);
}

/// A valid add (as `entry_validate` checks), with bounds near interesting values.
fn add_random(prng: *stdx.PRNG) Add {
    var add: Add = .{
        .delta = 0,
        .min = 0,
        .max = 0,
        .delta_from = 0,
        .offset = @intCast(prng.int_inclusive(u8, nerva.value_size - 8)),
        .field = if (prng.boolean()) .u64 else .i64,
        .flags = .{
            .min = prng.boolean(),
            .max = prng.boolean(),
            .clamp = prng.boolean(),
            .create = prng.boolean(),
        },
    };
    if (add.flags.min) add.min = value_random(prng, &add);
    if (add.flags.max) add.max = value_random(prng, &add);
    if (add.flags.min and add.flags.max and
        value_of(&add, add.min) > value_of(&add, add.max))
    {
        std.mem.swap(u64, &add.min, &add.max);
    }
    assert(nerva.entry_validate(&entry_of(&add)) == null);
    return add;
}

fn entry_of(add: *const Add) nerva.Entry {
    return .{ .id = 1, .table = 1, .kind = .add, .op_seen = 0, .value = add.value() };
}

/// A value of the add's field type: often an end of the type, a bound, or next to one.
fn value_random(prng: *stdx.PRNG, add: *const Add) u64 {
    if (prng.chance(stdx.PRNG.ratio(1, 4))) return prng.int(u64);
    const anchors = [_]i128{
        type_min(add),
        type_max(add),
        0,
        if (add.flags.min) value_of(add, add.min) else 0,
        if (add.flags.max) value_of(add, add.max) else 0,
        @as(i128, prng.int(u16)) - std.math.maxInt(u15),
    };
    const anchor = anchors[prng.index(&anchors)];
    const offset: i128 = @as(i128, prng.int_inclusive(u8, 4)) - 2;
    return bits_of(add, std.math.clamp(anchor + offset, type_min(add), type_max(add)));
}

/// A delta (never `minInt(i64)`): often the distance to a bound or an end of the type, ±1.
fn delta_random(prng: *stdx.PRNG, add: *const Add, old: u64) i64 {
    const old_value = value_of(add, old);
    const targets = [_]i128{
        type_min(add),
        type_max(add),
        if (add.flags.min) value_of(add, add.min) else 0,
        if (add.flags.max) value_of(add, add.max) else 0,
        old_value,
    };
    const delta: i128 = switch (prng.int_inclusive(u8, 3)) {
        0 => @as(i64, @bitCast(prng.int(u64))),
        1 => @as(i128, prng.int(u16)) - std.math.maxInt(u15),
        else => targets[prng.index(&targets)] - old_value +
            (@as(i128, prng.int_inclusive(u8, 4)) - 2),
    };
    return @intCast(std.math.clamp(delta, -std.math.maxInt(i64), std.math.maxInt(i64)));
}

/// Arbitrary add parameters through `entry_validate`; whatever it accepts can be resolved.
/// Returns whether they were valid.
fn validate_random(prng: *stdx.PRNG) bool {
    var entry: nerva.Entry = .{
        .id = 1,
        .table = 1,
        .kind = .add,
        .op_seen = 0,
        .value = undefined,
    };
    prng.fill(&entry.value);
    // Mostly zero the reserved bytes, to reach the checks behind them.
    if (prng.chance(stdx.PRNG.ratio(3, 4))) {
        var add = Add.from_entry(&entry);
        add.reserved_a = 0;
        add.reserved_b = @splat(0);
        add.flags.padding = 0;
        if (prng.boolean()) add.field = if (prng.boolean()) .u64 else .i64;
        if (prng.boolean()) add.offset %= nerva.value_size - 7;
        if (prng.boolean()) {
            if (!add.flags.min) add.min = 0;
            if (!add.flags.max) add.max = 0;
        }
        if (prng.boolean()) {
            if (add.flags.delta_from) add.delta = 0 else add.delta_from = 0;
        }
        entry.value = add.value();
    }
    if (nerva.entry_validate(&entry) != null) return false;

    // What `add_amount` and the state machine rely on.
    const add = Add.from_entry(&entry);
    assert(add.field == .u64 or add.field == .i64);
    assert(add.offset <= nerva.value_size - 8);
    assert(add.delta != std.math.minInt(i64));
    if (add.flags.min and add.flags.max) {
        assert(value_of(&add, add.min) <= value_of(&add, add.max));
    }
    if (add.flags.delta_from) assert(add.delta == 0);
    const old = value_random(prng, &add);
    if (nerva.add_amount(&add, old, add.delta)) |applied| amount_check(&add, old, add.delta, applied);
    return true;
}
