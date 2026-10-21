//! The catalog as `nerva api` reads and writes it: documents in the log, in
//! `catalog.table_catalog` (`documents.zig`), keyed `table.<id>` and `view.<name>` (N34, N35).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const nerva = @import("../../nerva.zig");
const catalog = @import("../catalog.zig");
const documents = @import("../documents.zig");
const LayoutPut = @import("api.zig").LayoutPut;
const LayoutRead = @import("api.zig").LayoutRead;
const LayoutCache = @import("layout_cache.zig").LayoutCache;
const Cached = @import("layout_cache.zig").Cached;
const ViewPut = @import("api.zig").ViewPut;

/// A declaration that keeps conflicting with others is refused after this many attempts.
const attempts_max = 16;

pub const CatalogStore = struct {
    transaction: documents.Transaction,
    /// Layouts kept between requests (P135); see `api.zig`, "Layouts".
    cache: LayoutCache = .{},

    pub fn init(client: *Client) CatalogStore {
        return .{ .transaction = .{
            .client = client,
            .table = catalog.table_catalog,
            .namespace = 0,
        } };
    }

    /// The layout of `table` as kept from an earlier read, a copy in `arena`.
    pub fn layout_cached(self: *CatalogStore, arena: std.mem.Allocator, table: u32) !?Cached {
        return self.cache.find(arena, table);
    }

    /// Reads the layout of `table` from the log, and keeps it if there is one.
    pub fn layout_fresh(self: *CatalogStore, arena: std.mem.Allocator, table: u32) !LayoutRead {
        self.transaction.begin(arena);
        const layout_ = try layout_read(&self.transaction, arena, table);
        const version = self.transaction.version(try layout_key(arena, table));
        if (layout_) |*found| self.cache.store(table, version, found) else self.cache.forget(table);
        return .{ .layout = layout_, .version = version };
    }

    /// The row of the catalog whose op is the version of `table`'s layout.
    pub fn layout_probe(_: *const CatalogStore, table: u32) nerva.RowKey {
        assert(table != 0 and table < catalog.tables_reserved_min);
        var key: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&key, "table.{}", .{table}) catch unreachable;
        return .{ .id = documents.row_id(0, text), .table = catalog.table_catalog };
    }

    /// Forgets everything kept: the cluster client was replaced.
    pub fn cache_clear(self: *CatalogStore) void {
        self.cache.clear();
    }

    pub fn layout(self: *CatalogStore, arena: std.mem.Allocator, table: u32) !?catalog.Layout {
        self.transaction.begin(arena);
        return layout_read(&self.transaction, arena, table);
    }

    pub fn layout_put(
        self: *CatalogStore,
        arena: std.mem.Allocator,
        table: u32,
        new: *const catalog.Layout,
    ) !LayoutPut {
        const key = try layout_key(arena, table);
        const document = try catalog.layout_render(arena, new);
        for (0..attempts_max) |_| {
            self.transaction.begin(arena);
            const old = try layout_read(&self.transaction, arena, table);
            const outcome: LayoutPut = if (old == null)
                .created
            else if (!catalog.layout_extends(&old.?, new))
                .incompatible
            else if (old.?.fields.len == new.fields.len)
                .unchanged
            else
                .extended;
            if (outcome == .incompatible or outcome == .unchanged) return outcome;

            try self.transaction.put(key, document);
            switch (try self.transaction.commit()) {
                .committed => {
                    self.cache.forget(table);
                    return outcome;
                },
                .conflict => log.info("table {}: layout conflict, retrying", .{table}),
            }
        }
        return error.Timeout;
    }

    pub fn view(self: *CatalogStore, arena: std.mem.Allocator, name: []const u8) !?catalog.View {
        self.transaction.begin(arena);
        return view_read(&self.transaction, arena, name);
    }

    pub fn view_put(
        self: *CatalogStore,
        arena: std.mem.Allocator,
        name: []const u8,
        new: *const catalog.View,
    ) !ViewPut {
        const key = try std.fmt.allocPrint(arena, "view.{s}", .{name});
        const document = try catalog.view_render(arena, new);
        for (0..attempts_max) |_| {
            self.transaction.begin(arena);
            if (try view_read(&self.transaction, arena, name)) |old| {
                const same = std.mem.eql(u8, try catalog.view_render(arena, &old), document);
                return if (same) .unchanged else .different;
            }
            try self.transaction.put(key, document);
            switch (try self.transaction.commit()) {
                .committed => return .created,
                .conflict => log.info("view {s}: conflict, retrying", .{name}),
            }
        }
        return error.Timeout;
    }
};

fn view_read(
    transaction: *documents.Transaction,
    arena: std.mem.Allocator,
    name: []const u8,
) !?catalog.View {
    const key = try std.fmt.allocPrint(arena, "view.{s}", .{name});
    const document = try transaction.get(key) orelse return null;
    return catalog.view_parse(arena, document) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Corrupt,
    };
}

fn layout_key(arena: std.mem.Allocator, table: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "table.{}", .{table});
}

fn layout_read(
    transaction: *documents.Transaction,
    arena: std.mem.Allocator,
    table: u32,
) !?catalog.Layout {
    assert(table != 0 and table < catalog.tables_reserved_min);
    const document = try transaction.get(try layout_key(arena, table)) orelse return null;
    // Written by `layout_put`, from a layout that parsed: anything else is corruption.
    return catalog.layout_parse(arena, document, table) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Corrupt,
    };
}
