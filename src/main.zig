const std = @import("std");

pub const engine = struct {
    pub const tables = @import("engine/tables.zig");
    pub const tables_adaa = @import("engine/tables_adaa.zig");
    pub const tables_blep = @import("engine/tables_blep.zig");
    pub const tables_approx = @import("engine/tables_approx.zig");
    pub const tables_simd = @import("engine/tables_simd.zig");
    pub const bench = @import("engine/bench.zig");
};

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});
}

test {
    _ = engine.tables;
    _ = engine.tables_adaa;
    _ = engine.tables_blep;
    _ = engine.tables_approx;
    _ = engine.tables_simd;
    _ = engine.bench;
}
