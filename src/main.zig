const std = @import("std");

pub const engine = struct {
    pub const tables = @import("engine/tables.zig");
    pub const tables_adaa = @import("engine/tables_adaa.zig");
    pub const tables_blep = @import("engine/tables_blep.zig");
    pub const tables_approx = @import("engine/tables_approx.zig");
    pub const tables_simd = @import("engine/tables_simd.zig");
    pub const param = @import("engine/param.zig");
    pub const undo = @import("engine/undo.zig");
    pub const microtuning = @import("engine/microtuning.zig");
    pub const bench = @import("engine/bench.zig");
};

pub const dsp = struct {
    pub const voice = @import("dsp/voice.zig");
    pub const drift = @import("dsp/drift.zig");
};

pub const io = struct {
    pub const osc = @import("io/osc.zig");
    pub const midi_learn = @import("io/midi_learn.zig");
    pub const midi = @import("io/midi.zig");
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
    _ = engine.param;
    _ = engine.undo;
    _ = engine.microtuning;
    _ = engine.bench;
    _ = dsp.voice;
    _ = dsp.drift;
    _ = io.osc;
    _ = io.midi_learn;
    _ = io.midi;
}
