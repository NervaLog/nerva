//! The layouts `nerva api` keeps between requests (P135), so that a request does not read them
//! from the log.
//!
//! An entry is a table's layout and the version of its catalog document: the op of chunk 0
//! (`documents.zig`), which every write of the document rewrites together with the other chunks
//! (N48). A layout only grows by appending fields (`catalog.layout_extends`), so a cached layout
//! that is behind the log differs from it only by fields it lacks. `api.zig` rules out answers
//! that depend on those: see "Layouts" there.
//!
//! The cache is plain data of fixed capacity: no allocation, nothing that points into itself. A
//! layout leaves it as a copy in the caller's arena, so a later `store` cannot invalidate one a
//! request is still using. Only present layouts are stored.

const std = @import("std");
const assert = std.debug.assert;

const catalog = @import("../catalog.zig");

/// Tables whose layouts are kept. When full, the oldest entry stored is replaced.
pub const entries_max = 64;

pub const Cached = struct {
    layout: catalog.Layout,
    /// The op of the layout document's chunk 0 when it was read.
    version: u64,
};

pub const LayoutCache = struct {
    entries: [entries_max]Entry = @splat(.{}),
    /// The entry to replace next when none is free.
    next: u32 = 0,

    const Entry = struct {
        /// 0 (never a table): free.
        table: u32 = 0,
        version: u64 = 0,
        name: [64]u8 = undefined,
        name_size: u8 = 0,
        field_count: u8 = 0,
        fields: [catalog.fields_max]Field = undefined,
    };

    const Field = struct {
        name: [catalog.name_size_max]u8,
        name_size: u8,
        type: catalog.FieldType,
        size: u8,
        offset: u16,
    };

    /// How many tables are cached.
    pub fn count(cache: *const LayoutCache) u32 {
        var result: u32 = 0;
        for (&cache.entries) |*entry| result += @intFromBool(entry.table != 0);
        assert(result <= entries_max);
        return result;
    }

    /// A copy in `arena` of the layout of `table`, or null if it is not cached.
    pub fn find(
        cache: *const LayoutCache,
        arena: std.mem.Allocator,
        table: u32,
    ) error{OutOfMemory}!?Cached {
        assert(table != 0);
        const entry = for (&cache.entries) |*entry| {
            if (entry.table == table) break entry;
        } else return null;

        const fields = try arena.alloc(catalog.Field, entry.field_count);
        for (fields, entry.fields[0..entry.field_count]) |*field, stored| {
            field.* = .{
                .name = try arena.dupe(u8, stored.name[0..stored.name_size]),
                .type = stored.type,
                .size = stored.size,
                .offset = stored.offset,
            };
        }
        return .{
            .layout = .{
                .name = try arena.dupe(u8, entry.name[0..entry.name_size]),
                .fields = fields,
            },
            .version = entry.version,
        };
    }

    /// Keeps `layout` of `table`, read at `version`, in place of what was kept for it.
    pub fn store(
        cache: *LayoutCache,
        table: u32,
        version: u64,
        layout: *const catalog.Layout,
    ) void {
        assert(table != 0);
        assert(layout.fields.len > 0 and layout.fields.len <= catalog.fields_max);
        assert(layout.name.len <= 64);

        const slot: *Entry = for (&cache.entries) |*entry| {
            if (entry.table == table) break entry;
        } else for (&cache.entries) |*entry| {
            if (entry.table == 0) break entry;
        } else slot: {
            const entry = &cache.entries[cache.next];
            cache.next = (cache.next + 1) % entries_max;
            break :slot entry;
        };
        slot.table = table;
        slot.version = version;
        slot.name_size = @intCast(layout.name.len);
        @memcpy(slot.name[0..layout.name.len], layout.name);
        slot.field_count = @intCast(layout.fields.len);
        for (layout.fields, slot.fields[0..layout.fields.len]) |field, *stored| {
            assert(field.name.len > 0 and field.name.len <= catalog.name_size_max);
            stored.* = .{
                .name = undefined,
                .name_size = @intCast(field.name.len),
                .type = field.type,
                .size = field.size,
                .offset = field.offset,
            };
            @memcpy(stored.name[0..field.name.len], field.name);
        }
    }

    /// Drops what is kept for `table`, if anything.
    pub fn forget(cache: *LayoutCache, table: u32) void {
        assert(table != 0);
        for (&cache.entries) |*entry| {
            if (entry.table == table) entry.table = 0;
        }
    }

    /// Drops everything: the cluster may not be the one the layouts were read from.
    pub fn clear(cache: *LayoutCache) void {
        for (&cache.entries) |*entry| entry.table = 0;
        cache.next = 0;
    }
};

const testing = std.testing;

fn layout_of(fields: []const catalog.Field) catalog.Layout {
    return .{ .name = "accounts", .fields = fields };
}

const fields_two = [_]catalog.Field{
    .{ .name = "available", .type = .i64, .size = 8, .offset = 0 },
    .{ .name = "flag", .type = .bool, .size = 1, .offset = 8 },
};

test "layout cache: a miss, a hit that is a copy, and a replacement" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var cache: LayoutCache = .{};
    try testing.expectEqual(null, try cache.find(arena, 7));

    cache.store(7, 40, &layout_of(fields_two[0..1]));
    const first = (try cache.find(arena, 7)).?;
    try testing.expectEqual(@as(u64, 40), first.version);
    try testing.expectEqualStrings("accounts", first.layout.name);
    try testing.expectEqual(@as(usize, 1), first.layout.fields.len);

    // Extended: the same table's entry is replaced, and a copy taken earlier is unchanged.
    cache.store(7, 52, &layout_of(&fields_two));
    try testing.expectEqual(@as(u32, 1), cache.count());
    const second = (try cache.find(arena, 7)).?;
    try testing.expectEqual(@as(u64, 52), second.version);
    try testing.expectEqual(@as(usize, 2), second.layout.fields.len);
    try testing.expectEqualStrings("flag", second.layout.field("flag").?.name);
    try testing.expectEqual(@as(u16, 8), second.layout.field("flag").?.offset);
    try testing.expectEqual(@as(usize, 1), first.layout.fields.len);
    try testing.expectEqual(null, try cache.find(arena, 8));
}

test "layout cache: forget and clear drop entries" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var cache: LayoutCache = .{};
    cache.store(1, 1, &layout_of(&fields_two));
    cache.store(2, 2, &layout_of(&fields_two));
    cache.forget(1);
    cache.forget(99);
    try testing.expectEqual(null, try cache.find(arena, 1));
    try testing.expect((try cache.find(arena, 2)) != null);
    cache.clear();
    try testing.expectEqual(@as(u32, 0), cache.count());
    try testing.expectEqual(null, try cache.find(arena, 2));
}

test "layout cache: holds at most entries_max, replacing the oldest" {
    var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var cache: LayoutCache = .{};
    const total = entries_max * 2 + 5;
    for (1..total + 1) |table| {
        cache.store(@intCast(table), table, &layout_of(&fields_two));
        try testing.expect(cache.count() <= entries_max);
    }
    try testing.expectEqual(@as(u32, entries_max), cache.count());
    // The newest `entries_max` stay; the older ones are gone.
    for (1..total + 1) |table| {
        const found = try cache.find(arena, @intCast(table));
        try testing.expectEqual(table > total - entries_max, found != null);
    }
}
