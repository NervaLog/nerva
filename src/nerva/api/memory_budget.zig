//! The memory `nerva api` may hold for one request (#31).
//!
//! A request's JSON is parsed into the request's arena, and `std.json.Value` costs many times the
//! body's size for nested or long arrays: a 4 MiB body could take about 0.8 GB. A request
//! allocates through this budget, over its arena: it counts the bytes the request asks for,
//! refuses (as out of memory) any allocation past `limit`, and remembers that it did, so the
//! gateway answers 413 rather than growing. It sits above the arena, not below: the arena sizes
//! each new block from the last one, so below it the budget would count several times what the
//! request asked for (#60). The arena keeps at most `retain_max` between requests.

const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

const MemoryBudget = @This();

parent_allocator: std.mem.Allocator,
limit: usize,
/// Bytes the request has allocated through the budget and not freed.
used: usize = 0,
/// Whether an allocation was refused since the last `request_start`.
exceeded: bool = false,

/// What the request arena keeps between requests.
pub const retain_max = 8 * 1024 * 1024;
/// The most a request may allocate: the largest valid request, a `documents/get` of 256
/// documents of 64 KiB, asks for about 100 MB (its rows, chunks, values and hex reply; #60).
pub const limit_default = 128 * 1024 * 1024;

pub fn init(parent_allocator: std.mem.Allocator, limit: usize) MemoryBudget {
    assert(limit > 0);
    return .{ .parent_allocator = parent_allocator, .limit = limit };
}

pub fn allocator(self: *MemoryBudget) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Starts a request: the arena was reset, so everything allocated before is gone.
pub fn request_start(self: *MemoryBudget) void {
    self.used = 0;
    self.exceeded = false;
}

fn fits(self: *MemoryBudget, grow: usize) bool {
    if (grow <= self.limit - self.used) return true;
    self.exceeded = true;
    return false;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    if (!self.fits(len)) return null;
    const result = self.parent_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
    self.used += len;
    return result;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and !self.fits(new_len - memory.len)) return false;
    if (!self.parent_allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;
    self.used = self.used - memory.len + new_len;
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and !self.fits(new_len - memory.len)) return null;
    const result = self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse
        return null;
    self.used = self.used - memory.len + new_len;
    return result;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *MemoryBudget = @ptrCast(@alignCast(ctx));
    assert(memory.len <= self.used);
    self.used -= memory.len;
    self.parent_allocator.rawFree(memory, alignment, ret_addr);
}

test "MemoryBudget: refuses past its limit, says so, and counts frees" {
    var budget = MemoryBudget.init(std.testing.allocator, 1024);
    const gpa = budget.allocator();

    const a = try gpa.alloc(u8, 600);
    try std.testing.expectEqual(@as(usize, 600), budget.used);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 600));
    try std.testing.expect(budget.exceeded);
    try std.testing.expectEqual(@as(usize, 600), budget.used);

    gpa.free(a);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    budget.request_start();
    try std.testing.expect(!budget.exceeded);
    const b = try gpa.alloc(u8, 1024);
    gpa.free(b);
    try std.testing.expect(!budget.exceeded);
}

test "MemoryBudget: a request over an arena past its budget fails, and the next fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var budget = MemoryBudget.init(arena.allocator(), 4 * 1024 * 1024);

    // Deeply nested JSON costs far more than its bytes once parsed.
    const depth = 200_000;
    const body = try std.testing.allocator.alloc(u8, 2 * depth);
    defer std.testing.allocator.free(body);
    @memset(body[0..depth], '[');
    @memset(body[depth..], ']');
    try std.testing.expectError(
        error.OutOfMemory,
        std.json.parseFromSliceLeaky(std.json.Value, budget.allocator(), body, .{}),
    );
    try std.testing.expect(budget.exceeded);

    // The arena keeps one buffer of the limit, plus its node's header.
    _ = arena.reset(.{ .retain_with_limit = 64 * 1024 });
    try std.testing.expect(arena.queryCapacity() <= 64 * 1024);
    budget.request_start();
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    const small = try std.json.parseFromSliceLeaky(std.json.Value, budget.allocator(), "[1]", .{});
    try std.testing.expectEqual(@as(usize, 1), small.array.items.len);
    try std.testing.expect(!budget.exceeded);
}
