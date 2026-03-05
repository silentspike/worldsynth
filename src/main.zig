const std = @import("std");

pub const engine = struct {
    pub const tables = @import("engine/tables.zig");
    pub const tables_adaa = @import("engine/tables_adaa.zig");
    pub const tables_blep = @import("engine/tables_blep.zig");
    pub const tables_approx = @import("engine/tables_approx.zig");
    pub const tables_simd = @import("engine/tables_simd.zig");
    pub const param = @import("engine/param.zig");
    pub const param_smooth = @import("engine/param_smooth.zig");
    pub const undo = @import("engine/undo.zig");
    pub const quality_governor = @import("engine/quality_governor.zig");
    pub const microtuning = @import("engine/microtuning.zig");
    pub const bench = @import("engine/bench.zig");
};

pub const dsp = struct {
    pub const voice = @import("dsp/voice.zig");
    pub const drift = @import("dsp/drift.zig");
    pub const sub_harmonics = @import("dsp/sub_harmonics.zig");
    pub const env_follower = @import("dsp/env_follower.zig");
    pub const pitch_follower = @import("dsp/pitch_follower.zig");
};

pub const io = struct {
    pub const jack = @import("io/jack.zig");
    pub const osc = @import("io/osc.zig");
    pub const midi_learn = @import("io/midi_learn.zig");
    pub const midi = @import("io/midi.zig");
    pub const ableton_link = @import("io/ableton_link.zig");
};

const build_options = @import("build_options");

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});

    if (comptime build_options.enable_jack) {
        var jack = io.jack.JackAudioClient.init(null, null) catch |err| {
            std.debug.print("JACK init failed: {}\n", .{err});
            return;
        };
        jack.start() catch |err| {
            std.debug.print("JACK start failed: {}\n", .{err});
            jack.deinit();
            return;
        };
        std.debug.print("JACK client active. Press Ctrl+C to quit.\n", .{});
        // Block until signal
        while (true) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

test {
    _ = engine.tables;
    _ = engine.tables_adaa;
    _ = engine.tables_blep;
    _ = engine.tables_approx;
    _ = engine.tables_simd;
    _ = engine.param;
    _ = engine.param_smooth;
    _ = engine.undo;
    _ = engine.quality_governor;
    _ = engine.microtuning;
    _ = engine.bench;
    _ = io.jack;
    _ = dsp.voice;
    _ = dsp.drift;
    _ = dsp.sub_harmonics;
    _ = dsp.env_follower;
    _ = dsp.pitch_follower;
    _ = io.osc;
    _ = io.midi_learn;
    _ = io.midi;
    _ = io.ableton_link;
}
