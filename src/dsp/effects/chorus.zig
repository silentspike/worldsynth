const std = @import("std");
const builtin = @import("builtin");

// ── Chorus/Phaser/Flanger (WP-044) ───────────────────────────────
// Modulated delay effects in one module. Chorus: 2-4 LFO-modulated
// delay voices for stereo widening. Phaser: N-stage allpass chain
// for swept notch pattern. Flanger: short feedback delay for metallic
// comb filter. Stereo output, internal LFO per voice, zero heap.

pub const BLOCK_SIZE: u32 = 128;
const MAX_DELAY: u32 = 4096; // ~93ms @ 44.1kHz, power of 2
const MASK: u32 = MAX_DELAY - 1;
const MAX_VOICES: u32 = 4;
const MAX_STAGES: u32 = 8;

pub const ChorusMode = enum(u2) {
    chorus,
    phaser,
    flanger,
};

/// Fast polynomial sine approximation for phase in [0, 1).
/// Parabolic with correction term, max error ~0.06%. Avoids expensive @sin.
inline fn fast_sin(phase: f64) f32 {
    var p: f32 = @floatCast(phase - @floor(phase));
    p = p * 2.0 - 1.0; // map [0,1) → [-1,1)
    const y = 4.0 * p * (1.0 - @abs(p));
    return 0.225 * (y * @abs(y) - y) + y;
}

pub const Chorus = struct {
    const Self = @This();

    delay_line: [MAX_DELAY]f32,
    write_pos: u32,
    lfo_phase: [MAX_VOICES]f64,
    // 1st-order allpass state for phaser
    ap_z: [MAX_STAGES]f32,
    ap_stages: u32,
    rate: f32,
    depth: f32,
    feedback: f32,
    mix: f32,
    mode: ChorusMode,
    voices: u32,
    fb_state: f32,

    pub fn init(mode: ChorusMode) Self {
        return .{
            .delay_line = [_]f32{0.0} ** MAX_DELAY,
            .write_pos = 0,
            .lfo_phase = .{ 0.0, 0.25, 0.5, 0.75 },
            .ap_z = [_]f32{0.0} ** MAX_STAGES,
            .ap_stages = if (mode == .phaser) 4 else 0,
            .rate = 0.5,
            .depth = switch (mode) {
                .chorus => 20.0, // ~0.45ms @ 44.1kHz
                .flanger => 5.0, // ~0.11ms
                .phaser => 0.8,
            },
            .feedback = switch (mode) {
                .chorus => 0.0,
                .flanger => 0.7,
                .phaser => 0.5,
            },
            .mix = 0.5,
            .mode = mode,
            .voices = switch (mode) {
                .chorus => 4,
                .flanger => 2,
                .phaser => 2,
            },
            .fb_state = 0.0,
        };
    }

    pub fn set_rate(self: *Self, hz: f32) void {
        self.rate = std.math.clamp(hz, 0.01, 20.0);
    }

    pub fn set_depth(self: *Self, d: f32) void {
        self.depth = switch (self.mode) {
            .chorus, .flanger => std.math.clamp(d, 0.1, @as(f32, MAX_DELAY / 4)),
            .phaser => std.math.clamp(d, 0.0, 1.0),
        };
    }

    pub fn set_feedback(self: *Self, fb: f32) void {
        self.feedback = std.math.clamp(fb, -0.95, 0.95);
    }

    pub fn set_mix(self: *Self, m: f32) void {
        self.mix = std.math.clamp(m, 0.0, 1.0);
    }

    pub fn set_voices(self: *Self, v: u32) void {
        self.voices = std.math.clamp(v, 2, MAX_VOICES);
    }

    pub fn set_phaser_stages(self: *Self, stages: u32) void {
        self.ap_stages = std.math.clamp(stages, 2, MAX_STAGES);
    }

    /// Linear interpolation at fractional delay position.
    inline fn linear_read(self: *const Self, pos: f32) f32 {
        const idx: u32 = @intFromFloat(pos);
        const frac = pos - @as(f32, @floatFromInt(idx));
        const y0 = self.delay_line[idx & MASK];
        const y1 = self.delay_line[(idx +% 1) & MASK];
        return y0 + frac * (y1 - y0);
    }

    /// Advance LFO for given voice using fast polynomial sine.
    inline fn advance_lfo(self: *Self, voice: usize, phase_inc: f64) f32 {
        const lfo = fast_sin(self.lfo_phase[voice]);
        self.lfo_phase[voice] += phase_inc;
        if (self.lfo_phase[voice] >= 1.0) self.lfo_phase[voice] -= 1.0;
        return lfo;
    }

    /// Process one sample. Returns stereo [L, R].
    pub inline fn process_sample(self: *Self, input: f32, sample_rate: f32) [2]f32 {
        const phase_inc: f64 = @as(f64, self.rate) / @as(f64, sample_rate);
        return switch (self.mode) {
            .chorus => self.process_chorus(input, phase_inc),
            .phaser => self.process_phaser(input, phase_inc, sample_rate),
            .flanger => self.process_flanger(input, phase_inc),
        };
    }

    inline fn process_chorus(self: *Self, input: f32, phase_inc: f64) [2]f32 {
        self.delay_line[self.write_pos & MASK] = input;

        var out_l: f32 = 0.0;
        var out_r: f32 = 0.0;
        const base: f32 = self.depth * 2.0;
        const wp_f: f32 = @floatFromInt(self.write_pos);

        for (0..self.voices) |v| {
            const lfo = self.advance_lfo(v, phase_inc);
            const delay_samp = std.math.clamp(base + self.depth * lfo, 1.0, @as(f32, MAX_DELAY - 2));
            const read_pos = wp_f - delay_samp;
            const wrapped = if (read_pos < 0) read_pos + @as(f32, MAX_DELAY) else read_pos;
            const delayed = self.linear_read(wrapped);

            if (v % 2 == 0) out_l += delayed else out_r += delayed;
        }

        const l_count: f32 = @floatFromInt((self.voices + 1) / 2);
        const r_count: f32 = @floatFromInt(self.voices / 2);
        if (l_count > 0) out_l /= l_count;
        if (r_count > 0) out_r /= r_count;

        self.write_pos +%= 1;
        const dry = 1.0 - self.mix;
        return .{ input * dry + out_l * self.mix, input * dry + out_r * self.mix };
    }

    inline fn process_flanger(self: *Self, input: f32, phase_inc: f64) [2]f32 {
        self.delay_line[self.write_pos & MASK] = input + self.fb_state * self.feedback;

        const lfo_l = self.advance_lfo(0, phase_inc);
        const lfo_r = self.advance_lfo(1, phase_inc);
        const base: f32 = self.depth * 2.0;
        const wp_f: f32 = @floatFromInt(self.write_pos);

        const delay_l = std.math.clamp(base + self.depth * lfo_l, 1.0, @as(f32, MAX_DELAY - 2));
        const delay_r = std.math.clamp(base + self.depth * lfo_r, 1.0, @as(f32, MAX_DELAY - 2));

        const pos_l = wp_f - delay_l;
        const pos_r = wp_f - delay_r;
        const wrapped_l = if (pos_l < 0) pos_l + @as(f32, MAX_DELAY) else pos_l;
        const wrapped_r = if (pos_r < 0) pos_r + @as(f32, MAX_DELAY) else pos_r;

        const wet_l = self.linear_read(wrapped_l);
        const wet_r = self.linear_read(wrapped_r);

        self.fb_state = (wet_l + wet_r) * 0.5;
        self.write_pos +%= 1;

        const dry = 1.0 - self.mix;
        return .{ input * dry + wet_l * self.mix, input * dry + wet_r * self.mix };
    }

    inline fn process_phaser(self: *Self, input: f32, phase_inc: f64, sample_rate: f32) [2]f32 {
        const lfo = self.advance_lfo(0, phase_inc);

        // Sweep allpass frequency between 200-4000 Hz via LFO
        const mod = 0.5 + 0.5 * lfo * self.depth;
        const freq = 200.0 + 3800.0 * mod;

        // 1st-order allpass coefficient (bilinear approximation: tan(w) ≈ w)
        const w = @as(f32, @floatCast(std.math.pi)) * freq / sample_rate;
        const a = (1.0 - w) / (1.0 + w);

        var x = input + self.fb_state * self.feedback;

        for (0..self.ap_stages) |s| {
            const y = a * x + self.ap_z[s];
            self.ap_z[s] = x - a * y;
            x = y;
        }

        self.fb_state = x;
        const dry = 1.0 - self.mix;
        // Stereo spread: L adds wet, R subtracts (opposite phase notches)
        return .{ input * dry + x * self.mix, input * dry - x * self.mix };
    }

    /// Process a block of samples with stereo output.
    pub fn process_block(
        self: *Self,
        out_l: *[BLOCK_SIZE]f32,
        out_r: *[BLOCK_SIZE]f32,
        in_buf: *const [BLOCK_SIZE]f32,
        sample_rate: f32,
    ) void {
        for (out_l, out_r, in_buf) |*ol, *or_, *i| {
            const result = self.process_sample(i.*, sample_rate);
            ol.* = result[0];
            or_.* = result[1];
        }
    }

    /// Clear all internal state.
    pub fn clear(self: *Self) void {
        @memset(&self.delay_line, 0.0);
        @memset(&self.ap_z, 0.0);
        self.fb_state = 0.0;
        self.write_pos = 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: Chorus stereo widening — L != R for mono input" {
    var ch = Chorus.init(.chorus);
    ch.mix = 1.0;
    const sr: f32 = 44100.0;

    // Fill delay line with sine first
    for (0..200) |i| {
        const t: f32 = @floatFromInt(i);
        const input = @sin(t * 440.0 * std.math.pi * 2.0 / sr) * 0.5;
        _ = ch.process_sample(input, sr);
    }

    // Now check that L and R differ
    var diff_count: u32 = 0;
    for (0..BLOCK_SIZE) |i| {
        const t: f32 = @as(f32, @floatFromInt(i + 200));
        const input = @sin(t * 440.0 * std.math.pi * 2.0 / sr) * 0.5;
        const result = ch.process_sample(input, sr);
        if (@abs(result[0] - result[1]) > 0.001) diff_count += 1;
    }
    // Majority of samples must have L != R
    try std.testing.expect(diff_count > BLOCK_SIZE / 2);
}

test "AC-2: Flanger comb filter — regular echoes from impulse" {
    // Comb filter = feedback delay: impulse produces echoes at regular intervals
    var ch = Chorus.init(.flanger);
    ch.rate = 0.001; // Freeze LFO
    ch.feedback = 0.8;
    ch.mix = 1.0;
    ch.depth = 5.0; // Base delay = 10 samples
    const sr: f32 = 44100.0;

    // Feed impulse
    _ = ch.process_sample(1.0, sr);

    // Count echo peaks: comb filter produces repeating echoes
    var peaks: u32 = 0;
    var was_quiet = true;
    for (0..200) |_| {
        const result = ch.process_sample(0.0, sr);
        const amp = @abs(result[0]);
        if (amp > 0.05 and was_quiet) {
            peaks += 1;
            was_quiet = false;
        } else if (amp < 0.01) {
            was_quiet = true;
        }
    }
    // Comb filter: at least 3 regularly-spaced echoes
    try std.testing.expect(peaks >= 3);
}

test "AC-N1: no NaN/Inf with extreme parameters" {
    const modes = [_]ChorusMode{ .chorus, .phaser, .flanger };
    for (modes) |mode| {
        var ch = Chorus.init(mode);
        ch.rate = 20.0;
        ch.feedback = 0.95;
        ch.mix = 1.0;
        if (mode == .chorus or mode == .flanger) ch.depth = 100.0;
        if (mode == .phaser) ch.ap_stages = MAX_STAGES;

        for (0..100_000) |i| {
            const input: f32 = if (i % 1000 == 0) 1.0 else 0.0;
            const result = ch.process_sample(input, 44100.0);
            try std.testing.expect(!std.math.isNan(result[0]));
            try std.testing.expect(!std.math.isNan(result[1]));
            try std.testing.expect(!std.math.isInf(result[0]));
            try std.testing.expect(!std.math.isInf(result[1]));
        }
    }
}

test "Chorus deterministic (same init = same output)" {
    var ch1 = Chorus.init(.chorus);
    var ch2 = Chorus.init(.chorus);

    for (0..500) |i| {
        const input: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
        const r1 = ch1.process_sample(input, 44100.0);
        const r2 = ch2.process_sample(input, 44100.0);
        try std.testing.expectEqual(r1[0], r2[0]);
        try std.testing.expectEqual(r1[1], r2[1]);
    }
}

test "Phaser deterministic" {
    var ch1 = Chorus.init(.phaser);
    var ch2 = Chorus.init(.phaser);

    for (0..500) |i| {
        const input: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
        const r1 = ch1.process_sample(input, 44100.0);
        const r2 = ch2.process_sample(input, 44100.0);
        try std.testing.expectEqual(r1[0], r2[0]);
        try std.testing.expectEqual(r1[1], r2[1]);
    }
}

test "Flanger deterministic" {
    var ch1 = Chorus.init(.flanger);
    var ch2 = Chorus.init(.flanger);

    for (0..500) |i| {
        const input: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
        const r1 = ch1.process_sample(input, 44100.0);
        const r2 = ch2.process_sample(input, 44100.0);
        try std.testing.expectEqual(r1[0], r2[0]);
        try std.testing.expectEqual(r1[1], r2[1]);
    }
}

test "mix=0 passes dry signal unchanged" {
    const modes = [_]ChorusMode{ .chorus, .phaser, .flanger };
    for (modes) |mode| {
        var ch = Chorus.init(mode);
        ch.mix = 0.0;
        const input: f32 = 0.42;
        const result = ch.process_sample(input, 44100.0);
        try std.testing.expectApproxEqAbs(input, result[0], 0.0001);
        try std.testing.expectApproxEqAbs(input, result[1], 0.0001);
    }
}

test "clear resets state" {
    var ch = Chorus.init(.flanger);
    ch.feedback = 0.8;
    ch.mix = 1.0;
    _ = ch.process_sample(1.0, 44100.0);
    for (0..100) |_| _ = ch.process_sample(0.0, 44100.0);

    ch.clear();
    const result = ch.process_sample(0.0, 44100.0);
    try std.testing.expectEqual(@as(f32, 0.0), result[0]);
    try std.testing.expectEqual(@as(f32, 0.0), result[1]);
}

test "Phaser stereo — L != R" {
    var ch = Chorus.init(.phaser);
    ch.mix = 0.8;
    const sr: f32 = 44100.0;

    var diff_count: u32 = 0;
    for (0..256) |i| {
        const input = @sin(@as(f32, @floatFromInt(i)) * 440.0 * std.math.pi * 2.0 / sr) * 0.5;
        const result = ch.process_sample(input, sr);
        if (@abs(result[0] - result[1]) > 0.001) diff_count += 1;
    }
    try std.testing.expect(diff_count > 128);
}

test "process_block matches sequential process_sample" {
    var ch1 = Chorus.init(.chorus);
    var ch2 = Chorus.init(.chorus);
    const sr: f32 = 44100.0;

    var in_buf: [BLOCK_SIZE]f32 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
    }

    var block_l: [BLOCK_SIZE]f32 = undefined;
    var block_r: [BLOCK_SIZE]f32 = undefined;
    ch1.process_block(&block_l, &block_r, &in_buf, sr);

    for (0..BLOCK_SIZE) |i| {
        const result = ch2.process_sample(in_buf[i], sr);
        try std.testing.expectApproxEqAbs(block_l[i], result[0], 0.0001);
        try std.testing.expectApproxEqAbs(block_r[i], result[1], 0.0001);
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: Chorus 2 Voices" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.chorus);
    ch.voices = 2;
    const sr: f32 = 44100.0;

    var in_buf = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 5_000 else 1_000_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Chorus 2V: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Chorus 4 Voices" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.chorus);
    ch.voices = 4;
    const sr: f32 = 44100.0;

    var in_buf = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 9_000 else 2_000_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Chorus 4V: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Phaser 4 Stages" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.phaser);
    ch.ap_stages = 4;
    const sr: f32 = 44100.0;

    var in_buf = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 3_500 else 100_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Phaser 4S: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Phaser 8 Stages" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.phaser);
    ch.ap_stages = 8;
    const sr: f32 = 44100.0;

    var in_buf = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 5_500 else 100_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Phaser 8S: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Flanger" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.flanger);
    const sr: f32 = 44100.0;

    var in_buf = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 4_000 else 1_000_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Flanger: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Chorus Stereo 4V block" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var ch = Chorus.init(.chorus);
    ch.voices = 4;
    const sr: f32 = 44100.0;

    var in_buf: [BLOCK_SIZE]f32 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
    }
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| ch.process_block(&out_l, &out_r, &in_buf, sr);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ch.process_block(&out_l, &out_r, &in_buf, sr);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 9_000 else 2_000_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-044] Chorus Stereo 4V: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
