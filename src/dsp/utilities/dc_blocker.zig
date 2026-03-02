const std = @import("std");

// -- DC-Blocker + Soft-Clip (WP-089) -----------------------------------------
// DC-Blocker: 1-pole HPF at ~5Hz removing DC offset from audio signals.
// Transfer function: H(z) = (1 - z^-1) / (1 - R*z^-1)
// R = exp(-2*pi*fc/fs) where fc = cutoff frequency (~5Hz).
// Soft-Clip: tanh-based limiter bounding output to [-1, 1].
// Both are designed for master-bus use: transparent on clean audio,
// protective against DC drift and overs.
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = 128;

/// Cutoff frequency for the DC-blocker HPF.
const DC_CUTOFF_HZ: f32 = 5.0;

// -- DC-Blocker ---------------------------------------------------------------

pub const DcBlocker = struct {
    const Self = @This();

    x_prev: f32,
    y_prev: f32,
    r: f32,

    /// Create a DC-blocker with ~5Hz cutoff for the given sample rate.
    /// R = exp(-2*pi*fc/fs) — higher sample rates get R closer to 1.
    pub fn init(sample_rate: f32) Self {
        const r: f32 = @floatCast(@exp(-2.0 * std.math.pi * @as(f64, DC_CUTOFF_HZ) / @as(f64, sample_rate)));
        return .{ .x_prev = 0, .y_prev = 0, .r = r };
    }

    /// Process a single sample: y[n] = x[n] - x[n-1] + R * y[n-1]
    pub inline fn process_sample(self: *Self, x: f32) f32 {
        const y = x - self.x_prev + self.r * self.y_prev;
        self.x_prev = x;
        self.y_prev = y;
        return y;
    }

    /// Process a block of BLOCK_SIZE samples.
    pub fn process_block(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (in_buf, out_buf) |s, *o| {
            o.* = self.process_sample(s);
        }
    }

    /// Reset filter state to zero.
    pub fn reset(self: *Self) void {
        self.x_prev = 0;
        self.y_prev = 0;
    }
};

// -- Soft-Clip ----------------------------------------------------------------

/// Soft-clip via Pade [3,2] tanh approximant.
/// Smooth limiting to [-1, 1] without hard clipping artifacts.
/// Same formula as ladder.zig fast_tanh and waveshaper.zig tanh_shape.
pub inline fn soft_clip(x: f32) f32 {
    const x2 = x * x;
    const raw = x * (15.0 + x2) / (15.0 + 6.0 * x2);
    return @min(1.0, @max(-1.0, raw));
}

/// Process a block of BLOCK_SIZE samples through soft-clip.
pub fn soft_clip_block(in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
    for (in_buf, out_buf) |s, *o| {
        o.* = soft_clip(s);
    }
}

// -- Tests --------------------------------------------------------------------

test "AC-1: DC-offset 0.5 removed after settling" {
    const sr: f32 = 44100.0;
    var dc = DcBlocker.init(sr);

    // R = exp(-2*pi*5/44100) ≈ 0.99929
    // Time constant = 1/(1-R) ≈ 1402 samples
    // For -60dB attenuation: ~6.9 time constants ≈ 9674 samples
    // Use 10000 samples for reliable convergence.
    var last_output: f32 = 0;
    for (0..10000) |_| {
        last_output = dc.process_sample(0.5);
    }

    // After 10000 samples (~7 time constants), DC should be fully removed
    try std.testing.expect(@abs(last_output) < 0.001);
}

test "AC-2: soft_clip limits output below 1.0" {
    // Input 2.0 should be clipped below 1.0
    const result = soft_clip(2.0);
    try std.testing.expect(result < 1.0);
    try std.testing.expect(result > 0.0);

    // Input -2.0 should be clipped above -1.0
    const neg_result = soft_clip(-2.0);
    try std.testing.expect(neg_result > -1.0);
    try std.testing.expect(neg_result < 0.0);
}

test "AC-3: audio signal passes DC-blocker unchanged" {
    const sr: f32 = 44100.0;
    var dc = DcBlocker.init(sr);

    // Warmup: let filter settle (8 time constants)
    var phase: f32 = 0.0;
    for (0..12000) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        _ = dc.process_sample(input);
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Measure difference: 440Hz sine should pass through nearly unchanged
    var max_diff: f32 = 0.0;
    for (0..4096) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        const output = dc.process_sample(input);
        const diff = @abs(output - input);
        if (diff > max_diff) max_diff = diff;
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Audio signal should pass through with minimal change.
    // 5Hz HPF introduces ~0.011 rad phase shift at 440Hz → max_diff ≈ 0.011.
    try std.testing.expect(max_diff < 0.02);
}

test "AC-N1: no NaN/Inf at extreme values" {
    var dc = DcBlocker.init(44100.0);

    const extremes = [_]f32{ 0.0, 1.0, -1.0, 1e6, -1e6, 1e-30, -1e-30 };

    // DC-Blocker extreme values
    for (extremes) |x| {
        const out = dc.process_sample(x);
        try std.testing.expect(!std.math.isNan(out));
        try std.testing.expect(!std.math.isInf(out));
    }

    // Soft-clip extreme values
    for (extremes) |x| {
        const out = soft_clip(x);
        try std.testing.expect(!std.math.isNan(out));
        try std.testing.expect(!std.math.isInf(out));
        try std.testing.expect(out >= -1.0);
        try std.testing.expect(out <= 1.0);
    }
}

test "soft_clip output always in [-1, 1]" {
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (0..1000) |_| {
        // Random values in wide range [-10, 10]
        const x = (random.float(f32) * 2.0 - 1.0) * 10.0;
        const out = soft_clip(x);
        try std.testing.expect(out >= -1.0);
        try std.testing.expect(out <= 1.0);
    }
}

test "soft_clip is identity near zero" {
    // For small x, tanh(x) ≈ x
    try std.testing.expectEqual(@as(f32, 0.0), soft_clip(0.0));

    const small = soft_clip(0.01);
    try std.testing.expect(@abs(small - 0.01) < 0.001);
}

test "DC-blocker removes varying DC" {
    const sr: f32 = 44100.0;
    var dc = DcBlocker.init(sr);

    // Add a 440Hz sine with DC offset of 0.3
    var phase: f32 = 0.0;

    // Settle: 8 time constants (TC ≈ 1402 samples → 11216 samples)
    for (0..12000) |_| {
        const input = @sin(2.0 * std.math.pi * phase) + 0.3;
        _ = dc.process_sample(input);
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Measure average of output (should be near 0, not 0.3)
    var sum: f64 = 0.0;
    const n: usize = 4096;
    for (0..n) |_| {
        const input = @sin(2.0 * std.math.pi * phase) + 0.3;
        const output = dc.process_sample(input);
        sum += @as(f64, output);
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }
    const avg = sum / @as(f64, @floatFromInt(n));

    // Average should be close to 0 (DC removed)
    try std.testing.expect(@abs(avg) < 0.01);
}

test "process_block matches sample loop" {
    var dc_block = DcBlocker.init(44100.0);
    var dc_sample = DcBlocker.init(44100.0);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) + 0.2;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var out_block: [BLOCK_SIZE]f32 = undefined;
    dc_block.process_block(&input, &out_block);

    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = dc_sample.process_sample(s);
    }

    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "soft_clip_block matches sample loop" {
    var input: [BLOCK_SIZE]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (&input) |*s| {
        s.* = (random.float(f32) * 2.0 - 1.0) * 3.0;
    }

    var out_block: [BLOCK_SIZE]f32 = undefined;
    soft_clip_block(&input, &out_block);

    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = soft_clip(s);
    }

    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "reset clears DC-blocker state" {
    var dc = DcBlocker.init(44100.0);

    // Feed signal
    for (0..100) |_| {
        _ = dc.process_sample(1.0);
    }

    // State should be non-zero
    try std.testing.expect(dc.x_prev != 0.0 or dc.y_prev != 0.0);

    // Reset
    dc.reset();
    try std.testing.expectEqual(@as(f32, 0.0), dc.x_prev);
    try std.testing.expectEqual(@as(f32, 0.0), dc.y_prev);
}

test "benchmark: DC-blocker 128 samples" {
    var dc = DcBlocker.init(44100.0);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) + 0.1;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| dc.process_block(&input, &output);

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        dc.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_dc = timer.read() / iterations;

    // Debug budget: generous (1-pole HPF is minimal computation)
    const budget_dc: u64 = 5000;
    std.debug.print("\n[WP-089] DC-blocker: {}ns/block (budget: {}ns)\n", .{ ns_dc, budget_dc });
    try std.testing.expect(ns_dc < budget_dc);
}

test "benchmark: soft-clip 128 samples" {
    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 1.5;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| soft_clip_block(&input, &output);

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        soft_clip_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_clip = timer.read() / iterations;

    // Debug budget: Pade approximant is cheap
    const budget_clip: u64 = 5000;
    std.debug.print("\n[WP-089] soft-clip: {}ns/block (budget: {}ns)\n", .{ ns_clip, budget_clip });
    try std.testing.expect(ns_clip < budget_clip);
}

test "benchmark: DC-blocker + soft-clip combined 128 samples" {
    var dc = DcBlocker.init(44100.0);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 1.5 + 0.1;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var temp: [BLOCK_SIZE]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        dc.process_block(&input, &temp);
        soft_clip_block(&temp, &output);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        dc.process_block(&input, &temp);
        soft_clip_block(&temp, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_combined = timer.read() / iterations;

    // Debug budget: combined pipeline
    const budget_combined: u64 = 10000;
    std.debug.print("\n[WP-089] DC-block + soft-clip: {}ns/block (budget: {}ns)\n", .{ ns_combined, budget_combined });
    try std.testing.expect(ns_combined < budget_combined);
}
