const std = @import("std");
const voice = @import("../dsp/voice.zig");
const vm = @import("../dsp/voice_manager.zig");
const param = @import("param.zig");
const oscillator = @import("../dsp/oscillator.zig");
const filter = @import("../dsp/filter.zig");
const envelope = @import("../dsp/envelope.zig");

// ── Engine.process Core (WP-020) ──────────────────────────────────────
// Central audio engine: Voice loop with Osc→Filter→Envelope→Mix.
// MVCC snapshot at block start, filter coefficients once per block.
// ZERO heap in process(). No malloc/mutex/println/sleep.
//
// Usage:
//   var eng = try Engine.create(allocator, 44100);
//   defer eng.destroy(allocator);
//   eng.handle_midi_event(&[_]u8{ 0x90, 60, 127 });
//   eng.process(out_l, out_r, 128);

pub const BLOCK_SIZE: usize = 128;

/// Soft-clip via Padé[1,1] tanh approximation.
/// Maps any input smoothly to [-1, +1]. Zero-cost for signals already in range.
/// Used in the master output stage to guarantee bounded output regardless of voice count.
inline fn softClip(x: f32) f32 {
    const x2 = x * x;
    if (x2 > 9.0) return if (x > 0) @as(f32, 1.0) else @as(f32, -1.0);
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

pub const Engine = struct {
    voice_pool: voice.VoicePool,
    voice_manager: vm.VoiceManager,
    param_state: param.ParamState,
    envelopes: [voice.MAX_VOICES]envelope.Envelope,
    sample_rate: f32,
    voice_buf: [BLOCK_SIZE]f32,
    filter_buf: [BLOCK_SIZE]f32,
    /// Smoothed voice-count compensation factor (1/sqrt(N)).
    /// Prevents polyphonic clipping while avoiding volume pumping.
    voice_comp: f32 = 1.0,

    /// Allocate and initialize engine. Heap allocation happens here only.
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) !*Engine {
        const self = try allocator.create(Engine);
        self.voice_pool.init();
        self.voice_manager = vm.VoiceManager.init(&self.voice_pool, sample_rate);
        self.param_state.init();
        self.envelopes = [_]envelope.Envelope{.{}} ** voice.MAX_VOICES;
        self.sample_rate = sample_rate;
        self.voice_buf = [_]f32{0.0} ** BLOCK_SIZE;
        self.filter_buf = [_]f32{0.0} ** BLOCK_SIZE;
        self.voice_comp = 1.0;
        return self;
    }

    /// Free engine resources.
    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// Dispatch a MIDI event to the voice manager.
    pub fn handle_midi_event(self: *Engine, data: []const u8) void {
        self.voice_manager.handle_midi(data);
    }

    /// Process one audio block. ZERO heap, no locks, no I/O.
    pub fn process(self: *Engine, out_l: []f32, out_r: []f32, n_frames: u32) void {
        @setFloatMode(.optimized);

        const frames: usize = @min(@as(usize, n_frames), BLOCK_SIZE);

        // MVCC snapshot — atomic, lock-free
        const snap = self.param_state.read_snapshot();

        // Envelope coefficients — once per block
        const attack_s: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.env_attack)]);
        const decay_s: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.env_decay)]);
        const sustain: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.env_sustain)]);
        const release_s: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.env_release)]);

        // Filter coefficients — once per block
        const cutoff: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.filter_cutoff)]);
        const reso: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.filter_resonance)]);
        const coeffs = filter.make_coeffs(cutoff, reso, self.sample_rate);

        // Waveform selection
        const wave_val: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.osc1_waveform)]);
        const wave_int: u3 = @intFromFloat(@max(0.0, @min(5.0, wave_val)));
        const wave: oscillator.WaveType = @enumFromInt(wave_int);

        // Master volume
        const master_vol: f32 = @floatCast(snap.values[@intFromEnum(param.ParamID.master_volume)]);

        // Voice-count compensation: 1/sqrt(N) with asymmetric smoothing.
        // Prevents polyphonic clipping (64 saws at full vel would be ~32x overdrive).
        // Fast attack (snap down) prevents clipping on note-on bursts.
        // Slow release (fade up) prevents volume pumping on note-off.
        const active = self.voice_manager.active_count();
        const comp_target: f32 = if (active <= 1) 1.0 else 1.0 / @sqrt(@as(f32, @floatFromInt(active)));
        if (comp_target < self.voice_comp) {
            // More voices active — snap down immediately (prevents clipping)
            self.voice_comp = comp_target;
        } else {
            // Fewer voices active — smooth up quickly (~25ms, imperceptible transition)
            self.voice_comp += 0.3 * (comp_target - self.voice_comp);
        }

        // Zero output buffers
        @memset(out_l[0..frames], 0);
        @memset(out_r[0..frames], 0);

        // AoSoA voice loop
        for (&self.voice_pool.hot, &self.voice_pool.cold, 0..) |*hot, *cold, ci| {
            for (0..voice.CHUNK_SIZE) |si| {
                if (!hot.active[si]) continue;

                const voice_idx: usize = ci * voice.CHUNK_SIZE + si;
                const env = &self.envelopes[voice_idx];

                // Envelope transition detection:
                // VoiceManager sets hot.env_stage as trigger signal.
                // Compare with envelope's internal stage to detect changes.
                if (hot.env_stage[si] == .attack and env.stage != .attack) {
                    env.set_params(attack_s, decay_s, sustain, release_s, self.sample_rate);
                    env.note_on();
                } else if (hot.env_stage[si] == .release and env.stage != .release and env.stage != .idle) {
                    env.note_off();
                }

                // Oscillator → voice_buf
                oscillator.process_block(&hot.phase[si], hot.phase_inc[si], wave, &self.voice_buf);

                // Filter → filter_buf
                filter.process_block(&self.voice_buf, &self.filter_buf, &cold.flt_z1[si], &cold.flt_z2[si], coeffs, .lp);

                // Envelope × Amplitude → Mix into output
                const amp = hot.amplitude[si];
                for (0..frames) |i| {
                    const env_val = env.process_sample();
                    const sample = self.filter_buf[i] * amp * env_val;
                    out_l[i] += sample;
                    out_r[i] += sample;
                }

                // Sync envelope state back to VoiceHot
                hot.env_stage[si] = env.stage;
                hot.env_value[si] = env.value;

                // Deactivate voice when envelope reaches idle
                if (env.stage == .idle) {
                    hot.active[si] = false;
                }
            }
        }

        // Master output: gain + soft-limiter.
        // 1/sqrt(N) voice compensation keeps signal manageable (~2-3x peak).
        // softClip(tanh) maps residual peaks smoothly to [-1, +1].
        // Result: guaranteed bounded output for any voice count (64, 128, ...).
        const gain = master_vol * self.voice_comp;
        for (0..frames) |i| {
            out_l[i] = softClip(out_l[i] * gain);
            out_r[i] = softClip(out_r[i] * gain);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

fn create_test_engine() !*Engine {
    const eng = try std.testing.allocator.create(Engine);
    eng.voice_pool.init();
    eng.voice_manager = vm.VoiceManager.init(&eng.voice_pool, 44100.0);
    eng.param_state.init();
    eng.envelopes = [_]envelope.Envelope{.{}} ** voice.MAX_VOICES;
    eng.sample_rate = 44100.0;
    eng.voice_buf = [_]f32{0.0} ** BLOCK_SIZE;
    eng.filter_buf = [_]f32{0.0} ** BLOCK_SIZE;
    eng.voice_comp = 1.0;
    // Default waveform is sine (0), set to saw (1) for audible output
    eng.param_state.set_param(.osc1_waveform, 1.0);
    return eng;
}

fn destroy_test_engine(eng: *Engine) void {
    std.testing.allocator.destroy(eng);
}

test "AC-1: engine produces output with 1 active voice" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    eng.handle_midi_event(&[_]u8{ 0x90, 69, 127 }); // A4, max velocity

    var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_l, &out_r, BLOCK_SIZE);

    // At least one sample must be non-zero
    var has_output = false;
    for (out_l) |s| {
        if (s != 0.0) {
            has_output = true;
            break;
        }
    }
    try std.testing.expect(has_output);
}

test "AC-2: engine silence when idle (0 active voices)" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_l, &out_r, BLOCK_SIZE);

    for (out_l) |s| {
        try std.testing.expectEqual(@as(f32, 0.0), s);
    }
    for (out_r) |s| {
        try std.testing.expectEqual(@as(f32, 0.0), s);
    }
}

test "AC-4: output bounded [-1, 1] with single voice" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    eng.handle_midi_event(&[_]u8{ 0x90, 69, 127 });

    // Process several blocks to go through attack
    for (0..10) |_| {
        var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
        var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
        eng.process(&out_l, &out_r, BLOCK_SIZE);

        for (out_l) |s| {
            try std.testing.expect(s >= -1.0 and s <= 1.0);
        }
        for (out_r) |s| {
            try std.testing.expect(s >= -1.0 and s <= 1.0);
        }
    }
}

test "MIDI note on/off cycle: sound then silence" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    // Note on
    eng.handle_midi_event(&[_]u8{ 0x90, 60, 100 });

    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    // Process a few blocks to get sound
    for (0..5) |_| {
        eng.process(&out_l, &out_r, BLOCK_SIZE);
    }

    // Verify we have output
    var has_output = false;
    for (out_l) |s| {
        if (s != 0.0) {
            has_output = true;
            break;
        }
    }
    try std.testing.expect(has_output);

    // Note off
    eng.handle_midi_event(&[_]u8{ 0x80, 60, 0 });

    // Process enough blocks for release to complete (300ms release @ 44.1kHz / 128 ≈ 103 blocks)
    for (0..200) |_| {
        eng.process(&out_l, &out_r, BLOCK_SIZE);
    }

    // Voice should be inactive now (envelope reached idle)
    try std.testing.expectEqual(@as(u32, 0), eng.voice_manager.active_count());
}

test "voice stealing produces output" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    // Fill all 64 voices
    for (0..64) |i| {
        eng.handle_midi_event(&[_]u8{ 0x90, @intCast(i), 100 });
    }
    try std.testing.expectEqual(@as(u32, 64), eng.voice_manager.active_count());

    // 65th note steals oldest
    eng.handle_midi_event(&[_]u8{ 0x90, 72, 127 });

    var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_l, &out_r, BLOCK_SIZE);

    var has_output = false;
    for (out_l) |s| {
        if (s != 0.0) {
            has_output = true;
            break;
        }
    }
    try std.testing.expect(has_output);
    try std.testing.expectEqual(@as(u32, 64), eng.voice_manager.active_count());
}

test "stereo output is identical (mono sum)" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    eng.handle_midi_event(&[_]u8{ 0x90, 69, 100 });

    var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_l, &out_r, BLOCK_SIZE);

    // Without pan, L and R should be identical
    for (out_l, out_r) |l, r| {
        try std.testing.expectEqual(l, r);
    }
}

test "master volume scales output" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    eng.handle_midi_event(&[_]u8{ 0x90, 69, 127 });

    // Process one block at full volume
    var out_full: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_full, &out_r, BLOCK_SIZE);

    // Reset: create new engine at half volume
    const eng2 = try create_test_engine();
    defer destroy_test_engine(eng2);

    eng2.param_state.set_param(.master_volume, 0.5);
    eng2.handle_midi_event(&[_]u8{ 0x90, 69, 127 });

    var out_half: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r2: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng2.process(&out_half, &out_r2, BLOCK_SIZE);

    // Half volume should be approximately half of full volume
    for (out_full, out_half) |full, half| {
        if (full != 0.0) {
            const ratio = half / full;
            try std.testing.expectApproxEqAbs(@as(f32, 0.5), ratio, 0.01);
        }
    }
}

test "param change affects filter" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);

    eng.handle_midi_event(&[_]u8{ 0x90, 69, 127 });

    // Process with default cutoff (1000 Hz)
    var out_default: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r1: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng.process(&out_default, &out_r1, BLOCK_SIZE);

    // New engine with very low cutoff (50 Hz)
    const eng2 = try create_test_engine();
    defer destroy_test_engine(eng2);

    eng2.param_state.set_param(.filter_cutoff, 50.0);
    eng2.handle_midi_event(&[_]u8{ 0x90, 69, 127 });

    var out_low: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r2: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    eng2.process(&out_low, &out_r2, BLOCK_SIZE);

    // Low cutoff should attenuate more (lower RMS)
    var rms_default: f64 = 0;
    var rms_low: f64 = 0;
    for (out_default, out_low) |d, l| {
        rms_default += @as(f64, d) * @as(f64, d);
        rms_low += @as(f64, l) * @as(f64, l);
    }
    // Default cutoff 1000 Hz should pass more energy than 50 Hz for A4 (440 Hz)
    try std.testing.expect(rms_default > rms_low);
}

test "64 voices: output strictly bounded [-1, 1] with integrated limiter" {
    const eng = try create_test_engine();
    defer destroy_test_engine(eng);
    // Open filter so saw harmonics are not attenuated
    eng.param_state.set_param(.filter_cutoff, 20000.0);

    // Fill all 64 voices with different notes at max velocity
    for (0..64) |i| {
        eng.handle_midi_event(&[_]u8{ 0x90, @intCast(24 + (i % 48)), 127 });
    }
    try std.testing.expectEqual(@as(u32, 64), eng.voice_manager.active_count());

    // Process enough blocks for envelopes to reach sustain.
    // The integrated soft-limiter (1/sqrt(N) compensation + softClip) guarantees
    // output is always bounded [-1, +1] regardless of voice count.
    var peak: f32 = 0;
    for (0..200) |_| {
        var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
        var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
        eng.process(&out_l, &out_r, BLOCK_SIZE);

        for (out_l) |s| {
            try std.testing.expect(s >= -1.0 and s <= 1.0);
            if (@abs(s) > peak) peak = @abs(s);
        }
        for (out_r) |s| {
            try std.testing.expect(s >= -1.0 and s <= 1.0);
        }
    }
    std.debug.print("\n  [voice-comp] 64 voices peak: {d:.3}\n", .{peak});
    std.debug.print("    voice_comp: {d:.4}\n", .{eng.voice_comp});

    // With integrated limiter, output MUST be strictly bounded [-1, 1].
    // softClip(tanh) guarantees this mathematically.
    try std.testing.expect(peak <= 1.0);
    // Verify we actually got meaningful output (not just silence)
    try std.testing.expect(peak > 0.1);
}

// ── Benchmarks ────────────────────────────────────────────────────────

fn setup_bench_engine(n_voices: u7) !*Engine {
    const eng = try create_test_engine();
    // Set saw waveform for realistic benchmark (saw has many harmonics)
    eng.param_state.set_param(.osc1_waveform, 1.0);
    for (0..@as(usize, n_voices)) |i| {
        eng.handle_midi_event(&[_]u8{ 0x90, @intCast(36 + (i % 48)), 100 });
    }
    return eng;
}

fn bench_engine_process(eng: *Engine) u64 {
    var out_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var out_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;

    // Warmup
    for (0..100) |_| {
        eng.process(&out_l, &out_r, BLOCK_SIZE);
    }

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = std.time.Timer.start() catch {
            t.* = 0;
            continue;
        };
        eng.process(&out_l, &out_r, BLOCK_SIZE);
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    return times[runs / 2];
}

test "benchmark: engine.process 1 voice" {
    const eng = try setup_bench_engine(1);
    defer destroy_test_engine(eng);

    const median_ns = bench_engine_process(eng);
    const threshold: f64 = if (@import("builtin").mode == .Debug) 500000.0 else 5000.0;

    std.debug.print("\n  [WP-020] engine.process 1 voice, 128 samples\n", .{});
    std.debug.print("    median: {d}ns\n", .{median_ns});
    std.debug.print("    Threshold: < {d:.0}ns (Issue #22: < 5000ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(@as(f64, @floatFromInt(median_ns)) < threshold);
}

test "benchmark: engine.process 8 voices" {
    const eng = try setup_bench_engine(8);
    defer destroy_test_engine(eng);

    const median_ns = bench_engine_process(eng);
    const threshold: f64 = if (@import("builtin").mode == .Debug) 3000000.0 else 30000.0;

    std.debug.print("\n  [WP-020] engine.process 8 voices, 128 samples\n", .{});
    std.debug.print("    median: {d}ns\n", .{median_ns});
    std.debug.print("    Threshold: < {d:.0}ns (Issue #22: < 30000ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(@as(f64, @floatFromInt(median_ns)) < threshold);
}

test "benchmark: engine.process 32 voices" {
    const eng = try setup_bench_engine(32);
    defer destroy_test_engine(eng);

    const median_ns = bench_engine_process(eng);
    const threshold: f64 = if (@import("builtin").mode == .Debug) 12000000.0 else 120000.0;

    std.debug.print("\n  [WP-020] engine.process 32 voices, 128 samples\n", .{});
    std.debug.print("    median: {d}ns\n", .{median_ns});
    std.debug.print("    Threshold: < {d:.0}ns (Issue #22: < 120000ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(@as(f64, @floatFromInt(median_ns)) < threshold);
}

test "benchmark: engine.process 64 voices" {
    const eng = try setup_bench_engine(64);
    defer destroy_test_engine(eng);

    const median_ns = bench_engine_process(eng);
    const threshold: f64 = if (@import("builtin").mode == .Debug) 25000000.0 else 250000.0;

    std.debug.print("\n  [WP-020] engine.process 64 voices, 128 samples\n", .{});
    std.debug.print("    median: {d}ns\n", .{median_ns});
    std.debug.print("    Threshold: < {d:.0}ns (Issue #22: < 250000ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(@as(f64, @floatFromInt(median_ns)) < threshold);
}
