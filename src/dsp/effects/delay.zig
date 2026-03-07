const std = @import("std");
const builtin = @import("builtin");

// ── Delay BPM-Sync with Hermite Interpolation (WP-043) ───────────
// BPM-synchronized delay with 4-point cubic Hermite interpolation
// for artifact-free delay time changes. Computes delay from host BPM
// and note division. Circular buffer with power-of-2 masking.
// Zero heap allocation — delay line preallocated inline.

pub const BLOCK_SIZE: u32 = 128;
pub const MAX_DELAY: u32 = 262144; // ~5.9s @ 44.1kHz, must be power of 2
const MASK: u32 = MAX_DELAY - 1;

pub const NoteDivision = enum(u3) {
    whole, // 4 beats
    half, // 2 beats
    quarter, // 1 beat
    eighth, // 1/2 beat
    sixteenth, // 1/4 beat
    dotted_eighth, // 3/4 beat
    triplet_quarter, // 2/3 beat

    pub fn factor(self: NoteDivision) f32 {
        return switch (self) {
            .whole => 4.0,
            .half => 2.0,
            .quarter => 1.0,
            .eighth => 0.5,
            .sixteenth => 0.25,
            .dotted_eighth => 0.75,
            .triplet_quarter => 2.0 / 3.0,
        };
    }
};

pub const Delay = struct {
    const Self = @This();

    delay_line: [MAX_DELAY]f32,
    write_pos: u32,
    delay_samples: f32,
    feedback: f32,
    mix: f32,

    pub fn init() Self {
        return .{
            .delay_line = [_]f32{0.0} ** MAX_DELAY,
            .write_pos = 0,
            .delay_samples = 22050.0, // default: 120 BPM, 1/4 @ 44.1kHz
            .feedback = 0.5,
            .mix = 0.5,
        };
    }

    /// Compute delay time from BPM and note division.
    pub fn set_bpm(self: *Self, bpm: f32, div: NoteDivision, sample_rate: f32) void {
        const clamped_bpm = std.math.clamp(bpm, 20.0, 300.0);
        self.delay_samples = (60.0 / clamped_bpm) * div.factor() * sample_rate;
    }

    /// Set delay time directly in samples.
    pub fn set_delay_samples(self: *Self, samples: f32) void {
        self.delay_samples = std.math.clamp(samples, 1.0, @as(f32, MAX_DELAY - 4));
    }

    /// Set feedback amount (clamped to 0.0-0.95 for stability).
    pub fn set_feedback(self: *Self, fb: f32) void {
        self.feedback = std.math.clamp(fb, 0.0, 0.95);
    }

    /// Set dry/wet mix (0.0 = dry, 1.0 = fully wet).
    pub fn set_mix(self: *Self, m: f32) void {
        self.mix = std.math.clamp(m, 0.0, 1.0);
    }

    /// 4-point cubic Hermite interpolation at fractional position.
    inline fn hermite_read(self: *const Self, pos: f32) f32 {
        const idx: u32 = @intFromFloat(pos);
        const frac = pos - @as(f32, @floatFromInt(idx));

        const y0 = self.delay_line[(idx -% 1) & MASK];
        const y1 = self.delay_line[idx & MASK];
        const y2 = self.delay_line[(idx +% 1) & MASK];
        const y3 = self.delay_line[(idx +% 2) & MASK];

        const c0 = y1;
        const c1 = 0.5 * (y2 - y0);
        const c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
        const c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);

        return ((c3 * frac + c2) * frac + c1) * frac + c0;
    }

    /// Process one sample through the delay.
    pub inline fn process_sample(self: *Self, input: f32) f32 {
        const read_pos = @as(f32, @floatFromInt(self.write_pos)) - self.delay_samples;
        const wrapped = if (read_pos < 0) read_pos + @as(f32, MAX_DELAY) else read_pos;
        const delayed = self.hermite_read(wrapped);

        // Write input + feedback to delay line
        self.delay_line[self.write_pos & MASK] = input + delayed * self.feedback;
        self.write_pos +%= 1;

        return input * (1.0 - self.mix) + delayed * self.mix;
    }

    /// Process a block of samples.
    pub fn process_block(self: *Self, out: *[BLOCK_SIZE]f32, in_buf: *const [BLOCK_SIZE]f32) void {
        for (out, in_buf) |*o, *i| {
            o.* = self.process_sample(i.*);
        }
    }

    /// Clear delay line state.
    pub fn clear(self: *Self) void {
        @memset(&self.delay_line, 0.0);
        self.write_pos = 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: 120 BPM quarter note = 22050 samples at 44100 Hz" {
    var dly = Delay.init();
    dly.set_bpm(120.0, .quarter, 44100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 22050.0), dly.delay_samples, 0.01);
}

test "AC-1: BPM sync all divisions" {
    var dly = Delay.init();
    const sr: f32 = 44100.0;
    const bpm: f32 = 120.0;
    const beat_sec = 60.0 / bpm; // 0.5s

    dly.set_bpm(bpm, .whole, sr);
    try std.testing.expectApproxEqAbs(beat_sec * 4.0 * sr, dly.delay_samples, 0.01);

    dly.set_bpm(bpm, .half, sr);
    try std.testing.expectApproxEqAbs(beat_sec * 2.0 * sr, dly.delay_samples, 0.01);

    dly.set_bpm(bpm, .eighth, sr);
    try std.testing.expectApproxEqAbs(beat_sec * 0.5 * sr, dly.delay_samples, 0.01);

    dly.set_bpm(bpm, .sixteenth, sr);
    try std.testing.expectApproxEqAbs(beat_sec * 0.25 * sr, dly.delay_samples, 0.01);

    dly.set_bpm(bpm, .dotted_eighth, sr);
    try std.testing.expectApproxEqAbs(beat_sec * 0.75 * sr, dly.delay_samples, 0.01);

    dly.set_bpm(bpm, .triplet_quarter, sr);
    try std.testing.expectApproxEqAbs(beat_sec * (2.0 / 3.0) * sr, dly.delay_samples, 1.0);
}

test "AC-2: Hermite interpolation smooth for fractional delay" {
    // Test that Hermite produces smooth output by comparing integer vs fractional delay.
    // Feed a sine wave, then read back: fractional delay should produce smooth output
    // (no clicks/pops that would appear with truncation).
    var dly = Delay.init();
    dly.delay_samples = 500.3; // fractional
    dly.feedback = 0.0;
    dly.mix = 1.0;

    // Feed a sine wave into the delay
    const freq: f32 = 440.0;
    const sr: f32 = 44100.0;
    for (0..1000) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / sr;
        const input = @sin(t * freq * std.math.pi * 2.0) * 0.5;
        _ = dly.process_sample(input);
    }

    // Now read back silence — output should be smooth delayed sine
    var prev: f32 = dly.process_sample(0.0);
    var max_diff: f32 = 0.0;
    for (0..BLOCK_SIZE) |_| {
        const cur = dly.process_sample(0.0);
        const diff = @abs(cur - prev);
        if (diff > max_diff) max_diff = diff;
        prev = cur;
    }

    // 440Hz sine at 44100Hz: max inter-sample diff ~= 2*pi*440/44100 * 0.5 ≈ 0.031
    // Hermite should keep it smooth — no clicks (which would cause diffs > 0.5)
    try std.testing.expect(max_diff < 0.2);
}

test "AC-N1: feedback=0 produces single echo" {
    var dly = Delay.init();
    dly.delay_samples = 10.0;
    dly.feedback = 0.0;
    dly.mix = 1.0;

    // Feed impulse
    _ = dly.process_sample(1.0);

    // Process until echo appears
    var echo_count: u32 = 0;
    for (0..100) |_| {
        const out = dly.process_sample(0.0);
        if (@abs(out) > 0.01) echo_count += 1;
    }

    // With feedback=0, only the initial echo should appear (within ~4 samples due to Hermite)
    try std.testing.expect(echo_count <= 4);
}

test "feedback creates repeating echoes" {
    var dly = Delay.init();
    dly.delay_samples = 50.0;
    dly.feedback = 0.7;
    dly.mix = 1.0;

    _ = dly.process_sample(1.0);

    // Count echo peaks
    var peaks: u32 = 0;
    var was_quiet = true;
    for (0..500) |_| {
        const out = dly.process_sample(0.0);
        if (@abs(out) > 0.01 and was_quiet) {
            peaks += 1;
            was_quiet = false;
        } else if (@abs(out) < 0.001) {
            was_quiet = true;
        }
    }

    // Multiple echoes with feedback
    try std.testing.expect(peaks >= 3);
}

test "mix=0 passes dry signal unchanged" {
    var dly = Delay.init();
    dly.mix = 0.0;
    dly.feedback = 0.0;

    const input: f32 = 0.42;
    const out = dly.process_sample(input);
    try std.testing.expectApproxEqAbs(input, out, 0.0001);
}

test "clear resets all state" {
    var dly = Delay.init();
    dly.feedback = 0.8;
    dly.mix = 1.0;

    _ = dly.process_sample(1.0);
    for (0..100) |_| _ = dly.process_sample(0.0);

    dly.clear();
    const out = dly.process_sample(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), out);
}

test "no NaN/Inf after 100000 samples" {
    var dly = Delay.init();
    dly.set_bpm(120.0, .quarter, 44100.0);
    dly.feedback = 0.9;
    dly.mix = 0.5;

    for (0..100_000) |i| {
        const input: f32 = if (i % 1000 == 0) 0.5 else 0.0;
        const out = dly.process_sample(input);
        try std.testing.expect(!std.math.isNan(out));
        try std.testing.expect(!std.math.isInf(out));
    }
}

test "process_block matches sequential process_sample" {
    var dly1 = Delay.init();
    var dly2 = Delay.init();
    dly1.set_bpm(140.0, .eighth, 44100.0);
    dly2.set_bpm(140.0, .eighth, 44100.0);

    var in_buf: [BLOCK_SIZE]f32 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.3;
    }

    var block_out: [BLOCK_SIZE]f32 = undefined;
    dly1.process_block(&block_out, &in_buf);

    var sample_out: [BLOCK_SIZE]f32 = undefined;
    for (&sample_out, in_buf) |*o, inp| {
        o.* = dly2.process_sample(inp);
    }

    for (block_out, sample_out) |b, s| {
        try std.testing.expectApproxEqAbs(b, s, 0.0001);
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: delay 128 samples fixed Hermite" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var dly = Delay.init();
    dly.set_bpm(120.0, .quarter, 44100.0);
    dly.feedback = 0.7;
    dly.mix = 0.5;

    var in_buf: [BLOCK_SIZE]f32 = [_]f32{0.1} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        dly.process_block(&out_buf, &in_buf);
    }

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        dly.process_block(&out_buf, &in_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 6_000 else 500_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-043] delay fixed Hermite: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: BPM sync calculation" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var dly = Delay.init();

    for (0..1000) |_| {
        dly.set_bpm(120.0, .quarter, 44100.0);
    }

    const iterations: u64 = if (strict) 5_000_000 else 100_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        dly.set_bpm(120.0, .quarter, 44100.0);
        std.mem.doNotOptimizeAway(&dly.delay_samples);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 50 else 5_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-043] BPM sync calc: {}ns/call (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
