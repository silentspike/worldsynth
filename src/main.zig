const std = @import("std");

pub const engine = struct {
    pub const tables = @import("engine/tables.zig");
    pub const tables_adaa = @import("engine/tables_adaa.zig");
};

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
