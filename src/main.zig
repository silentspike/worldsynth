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
    pub const microtuning = @import("engine/microtuning.zig");
    pub const bench = @import("engine/bench.zig");
};

pub const dsp = struct {
    pub const voice = @import("dsp/voice.zig");
    pub const drift = @import("dsp/drift.zig");
    pub const oscillator = @import("dsp/oscillator.zig");
    pub const osc_sine_noise = @import("dsp/osc_sine_noise.zig");
    pub const filter = @import("dsp/filter.zig");
    pub const ladder = @import("dsp/ladder.zig");
};

pub const io = struct {
    pub const jack = @import("io/jack.zig");
    pub const pipewire = @import("io/pipewire.zig");
    pub const audio_backend = @import("io/audio_backend.zig");
    pub const osc = @import("io/osc.zig");
    pub const midi_learn = @import("io/midi_learn.zig");
    pub const midi = @import("io/midi.zig");
};

const build_options = @import("build_options");

// 440Hz test sine for audio output verification
var test_phase: f32 = 0.0;
fn testSine(out_l: [*]f32, out_r: [*]f32, n_frames: u32) void {
    const freq: f32 = 440.0;
    const sr: f32 = 44100.0;
    const inc: f32 = freq / sr;
    const amp: f32 = 0.25;
    for (0..n_frames) |i| {
        const sample = amp * @sin(test_phase * 2.0 * std.math.pi);
        out_l[i] = sample;
        out_r[i] = sample;
        test_phase += inc;
        if (test_phase >= 1.0) test_phase -= 1.0;
    }
}

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});

    var backend = io.audio_backend.AudioBackend.detect_and_init(testSine, null) catch |err| {
        std.debug.print("Audio backend init failed: {}\n", .{err});
        return;
    };

    switch (backend) {
        .pipewire => std.debug.print("Backend: PipeWire\n", .{}),
        .jack => std.debug.print("Backend: JACK\n", .{}),
    }

    backend.start() catch |err| {
        std.debug.print("Audio backend start failed: {}\n", .{err});
        backend.stop();
        return;
    };

    // JACK start() returns immediately — spin-wait until signal
    switch (backend) {
        .jack => {
            std.debug.print("JACK client active. Press Ctrl+C to quit.\n", .{});
            while (true) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        },
        .pipewire => {},
    }

    // PipeWire: main loop returned — cleanup
    backend.stop();
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
    _ = engine.microtuning;
    _ = engine.bench;
    _ = io.jack;
    _ = io.pipewire;
    _ = io.audio_backend;
    _ = dsp.voice;
    _ = dsp.drift;
    _ = dsp.oscillator;
    _ = dsp.osc_sine_noise;
    _ = dsp.filter;
    _ = dsp.ladder;
    _ = io.osc;
    _ = io.midi_learn;
    _ = io.midi;
}
