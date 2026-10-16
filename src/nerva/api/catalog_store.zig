//! The catalog as `nerva api` reads and writes it: documents in the log, in
//! `catalog.table_catalog` (`documents.zig`), keyed `table.<id>` and `view.<name>` (N34, N35).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const catalog = @import("../catalog.zig");
const documents = @import("../documents.zig");
const LayoutPut = @import("api.zig").LayoutPut;
const ViewPut = @import("api.zig").ViewPut;

/// A declaration that keeps conflicting with others is refused after this many attempts.
const attempts_max = 16;

pub const CatalogStore = struct {
    transaction: documents.Transaction,

    pub fn init(client: *Client) CatalogStore {
        return .{ .transaction = .{
            .client = client,
            .table = catalog.table_catalog,
            .namespace = 0,
        } };
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
                .committed => return outcome,
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
