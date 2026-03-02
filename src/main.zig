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
    pub const engine_core = @import("engine/engine.zig");
};

pub const dsp = struct {
    pub const voice = @import("dsp/voice.zig");
    pub const drift = @import("dsp/drift.zig");
    pub const oscillator = @import("dsp/oscillator.zig");
    pub const osc_sine_noise = @import("dsp/osc_sine_noise.zig");
    pub const filter = @import("dsp/filter.zig");
    pub const ladder = @import("dsp/ladder.zig");
    pub const envelope = @import("dsp/envelope.zig");
    pub const voice_manager = @import("dsp/voice_manager.zig");
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
const Engine = @import("engine/engine.zig").Engine;
const jack_mod = @import("io/jack.zig");

// ── Global Engine reference for RT callbacks ─────────────────────────
// JACK/PipeWire callbacks are plain function pointers without context.
// Set BEFORE backend.start(), cleared AFTER backend.stop().
var global_engine: ?*Engine = null;

// ── Global backend reference for signal handler ──────────────────────
// PipeWire blocks in pw_main_loop_run — signal handler must call quit().
var global_backend: ?*io.audio_backend.AudioBackend = null;

// ── Signal handler for clean shutdown ────────────────────────────────
var running = std.atomic.Value(bool).init(true);

fn sighandler(_: c_int) callconv(.c) void {
    running.store(false, .release);
    // Unblock PipeWire's pw_main_loop_run (signal-safe)
    if (global_backend) |b| b.quit();
}

// ── Audio callback: Engine.process wrapper ───────────────────────────
fn audioCallback(out_l: [*]f32, out_r: [*]f32, n_frames: u32) void {
    if (global_engine) |eng| {
        eng.process(out_l[0..n_frames], out_r[0..n_frames], n_frames);
    } else {
        @memset(out_l[0..n_frames], 0);
        @memset(out_r[0..n_frames], 0);
    }
}

// ── MIDI callback: MidiEvent → raw bytes → Engine ────────────────────
fn midiCallback(event: jack_mod.MidiEvent) void {
    if (global_engine) |eng| {
        var buf: [3]u8 = undefined;
        buf[0] = (@as(u8, @intFromEnum(event.status)) << 4) | event.channel;
        buf[1] = event.data1;
        buf[2] = event.data2;
        eng.handle_midi_event(&buf);
    }
}

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});

    // Signal handlers for graceful shutdown (SIGINT, SIGTERM)
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // Audio backend detection (PipeWire first, JACK fallback)
    var backend = io.audio_backend.AudioBackend.detect_and_init(audioCallback, midiCallback) catch |err| {
        std.debug.print("Audio backend init failed: {}\n", .{err});
        return;
    };

    const sample_rate = backend.get_sample_rate();

    switch (backend) {
        .pipewire => std.debug.print("Backend: PipeWire @ {d}Hz\n", .{sample_rate}),
        .jack => std.debug.print("Backend: JACK @ {d}Hz\n", .{sample_rate}),
    }

    // Engine creation (heap alloc here only, never in audio thread)
    const eng = Engine.create(std.heap.page_allocator, @floatFromInt(sample_rate)) catch |err| {
        std.debug.print("Engine init failed: {}\n", .{err});
        backend.stop();
        return;
    };

    // Set saw waveform as default (audible, harmonically rich)
    eng.param_state.set_param(.osc1_waveform, 1.0);

    // Publish engine + backend to RT callbacks / signal handler BEFORE start
    global_engine = eng;
    global_backend = &backend;

    std.debug.print("WorldSynth active. Press Ctrl+C to quit.\n", .{});

    // PipeWire: start() blocks in pw_main_loop_run until quit() is called.
    // JACK: start() returns immediately — spin-wait on running flag.
    backend.start() catch |err| {
        std.debug.print("Audio backend start failed: {}\n", .{err});
        global_backend = null;
        global_engine = null;
        eng.destroy(std.heap.page_allocator);
        backend.stop();
        return;
    };

    // JACK: wait for shutdown signal (PipeWire already exited via quit())
    switch (backend) {
        .jack => while (running.load(.acquire)) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        },
        .pipewire => {},
    }

    std.debug.print("\nShutting down...\n", .{});

    // Cleanup: stop backend first, then release engine
    global_backend = null;
    backend.stop();
    global_engine = null;
    eng.destroy(std.heap.page_allocator);
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
    _ = engine.engine_core;
    _ = io.jack;
    _ = io.pipewire;
    _ = io.audio_backend;
    _ = dsp.voice;
    _ = dsp.drift;
    _ = dsp.oscillator;
    _ = dsp.osc_sine_noise;
    _ = dsp.filter;
    _ = dsp.ladder;
    _ = dsp.envelope;
    _ = dsp.voice_manager;
    _ = io.osc;
    _ = io.midi_learn;
    _ = io.midi;
}
