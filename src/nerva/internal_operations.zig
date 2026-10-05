//! Requests a client may not send (#33).
//!
//! `vsr.Operation.pulse` maps to a state machine operation (Nerva's `Operation.pulse`, N52) that
//! the replica sends itself, with `client == 0`. `Request.invalid_header` refuses `.pulse` from a
//! client, but the state machine operation also has a raw value of its own (134), which
//! `vsr.Operation.valid` accepts and `from_vsr` maps to the same operation. The replica evicts a
//! client that sends it (patched into `vsr/replica.zig`, UPSTREAM.md).

const std = @import("std");

const vsr = @import("../vsr.zig");

/// Whether a request from `client` with `operation` names the state machine's pulse operation by
/// its raw value.
pub fn pulse_from_client(
    comptime StateMachineOperation: type,
    client: u128,
    operation: vsr.Operation,
) bool {
    if (client == 0) return false; // The replica's own request.
    if (operation == .pulse) return false; // `Request.invalid_header` refuses it from a client.
    const pulse = StateMachineOperation.from_vsr(.pulse) orelse return false;
    return StateMachineOperation.from_vsr(operation) == pulse;
}

test "internal_operations: a client may not send pulse by its raw value" {
    const Operation = @import("../nerva.zig").Operation;
    const raw_pulse = Operation.pulse.to_vsr();
    try std.testing.expectEqual(vsr.Operation.pulse, raw_pulse);

    const raw_134: vsr.Operation = @enumFromInt(@intFromEnum(Operation.pulse));
    try std.testing.expect(raw_134 != .pulse);
    try std.testing.expect(pulse_from_client(Operation, 7, raw_134));
    // The replica's own pulse, and the replica sending the raw value, pass.
    try std.testing.expect(!pulse_from_client(Operation, 0, .pulse));
    try std.testing.expect(!pulse_from_client(Operation, 0, raw_134));
    // `.pulse` itself from a client is refused earlier, by the header check.
    try std.testing.expect(!pulse_from_client(Operation, 7, .pulse));
    // Every other operation a client may send passes.
    inline for (comptime std.enums.values(Operation)) |operation| {
        if (operation != .pulse) {
            try std.testing.expect(!pulse_from_client(Operation, 7, operation.to_vsr()));
        }
    }
    try std.testing.expect(!pulse_from_client(Operation, 7, .register));
}
