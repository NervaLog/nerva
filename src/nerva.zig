//! Nerva's public types: the wire-level operations and persisted LSM tree identifiers.
//! Kept separate from the state machine so that the replica and tracing can reference them
//! without depending on the state machine implementation (mirrors TigerBeetle's tigerbeetle.zig).

const vsr = @import("vsr.zig");
const constants = @import("constants.zig");

/// Stable, forest-unique LSM tree identifiers. Never reuse or renumber: they are persisted.
pub const tree_ids = struct {
    pub const Thing = .{
        .timestamp = 1,
        .id = 2,
        .value = 3,
    };
};

pub const Operation = enum(u8) {
    echo = constants.vsr_operations_reserved + 0,

    pub fn EventType(comptime _: Operation) type {
        return u8; // Must be non-zero-sized for sliceAsBytes().
    }

    pub fn ResultType(comptime _: Operation) type {
        return u8; // Must be non-zero-sized for sliceAsBytes().
    }

    pub fn result_size(_: Operation) u32 {
        return @sizeOf(u8);
    }

    pub fn event_size(_: Operation) u32 {
        return @sizeOf(u8);
    }

    pub fn from_vsr(operation: vsr.Operation) ?Operation {
        if (operation.vsr_reserved()) return null;
        return vsr.Operation.to(Operation, operation);
    }

    pub fn to_vsr(operation: Operation) vsr.Operation {
        return vsr.Operation.from(Operation, operation);
    }
};
