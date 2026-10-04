//! The catalog as `nerva api` reads and writes it: layout documents in the log, in
//! `catalog.table_catalog`, chunked by `ledgerd/store.zig` and keyed `table.<id>` (N34).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.api);

const Client = @import("../client.zig").Client;
const catalog = @import("../catalog.zig");
const Store = @import("../ledgerd/store.zig").Store;
const LayoutPut = @import("api.zig").LayoutPut;

/// A declaration that keeps conflicting with others is refused after this many attempts.
const attempts_max = 16;

pub const CatalogStore = struct {
    store: Store,

    pub fn init(client: *Client) CatalogStore {
        return .{ .store = .{ .client = client, .ledger = 0, .table = catalog.table_catalog } };
    }

    pub fn layout(self: *CatalogStore, arena: std.mem.Allocator, table: u32) !?catalog.Layout {
        try self.store.begin(arena);
        return layout_read(&self.store, arena, table);
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
            try self.store.begin(arena);
            const old = try layout_read(&self.store, arena, table);
            const outcome: LayoutPut = if (old == null)
                .created
            else if (!catalog.layout_extends(&old.?, new))
                .incompatible
            else if (old.?.fields.len == new.fields.len)
                .unchanged
            else
                .extended;
            if (outcome == .incompatible or outcome == .unchanged) return outcome;

            try self.store.put(key, document);
            switch (try self.store.commit()) {
                .committed => return outcome,
                .conflict => log.info("table {}: layout conflict, retrying", .{table}),
            }
        }
        return error.Timeout;
    }
};

fn layout_key(arena: std.mem.Allocator, table: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "table.{}", .{table});
}

fn layout_read(store: *Store, arena: std.mem.Allocator, table: u32) !?catalog.Layout {
    assert(table != 0 and table < catalog.tables_reserved_min);
    const document = try store.get(try layout_key(arena, table)) orelse return null;
    // Written by `layout_put`, from a layout that parsed: anything else is corruption.
    return catalog.layout_parse(arena, document) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Corrupt,
    };
}
