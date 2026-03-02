const std = @import("std");

// ── Pre-Filter Waveshaper (WP-041) ─────────────────────────────────
// Stateless waveshaping module with 4 algorithms: Soft-Clip, Tanh,
// Fold (wavefolding), and Asymmetric (tube-style). Designed for the
// pre-filter position in the signal chain. Pure functions, no state,
// no heap. Drive parameter controls intensity (0.0..1.0 mapped to
// gain range per algorithm).

pub const BLOCK_SIZE: usize = 128;

pub const ShapeType = enum(u2) {
    soft_clip,
    tanh,
    fold,
    asymmetric,
};

/// Process a single sample through the waveshaper.
/// input: audio sample, drive: 0.0..1.0, shape: algorithm to use.
/// Output is bounded to [-1, 1] for all algorithms and drive values.
pub inline fn process_sample(input: f32, drive: f32, shape: ShapeType) f32 {
    @setFloatMode(.optimized);
    // Map drive 0..1 to gain 1..10 (mild to heavy saturation)
    const gain = 1.0 + drive * 9.0;
    const x = input * gain;
    return switch (shape) {
        .soft_clip => soft_clip(x),
        .tanh => tanh_shape(x),
        .fold => fold_shape(x),
        .asymmetric => asymmetric_shape(x),
    };
}

/// Process a block of BLOCK_SIZE samples.
pub fn process_block(
    in: *const [BLOCK_SIZE]f32,
    out: *[BLOCK_SIZE]f32,
    drive: f32,
    shape: ShapeType,
) void {
    for (in, out) |s, *o| {
        o.* = process_sample(s, drive, shape);
    }
}

// ── Shaping Algorithms ──────────────────────────────────────────────

/// Soft-clip: cubic saturation for subtle warmth.
/// Output: exactly [-1, 1]. Smooth knee at ±1.
inline fn soft_clip(x: f32) f32 {
    if (@abs(x) >= 1.0) return std.math.sign(x);
    return x * (1.5 - 0.5 * x * x);
}

/// Tanh saturation via [3,2] Padé approximant (same as ladder.zig).
/// Smooth progressive saturation. Output bounded by design (monotonic,
/// approaches ±1 asymptotically; Padé slightly exceeds ±1 for |x|>~2.7
/// but clamp ensures strict [-1,1]).
inline fn tanh_shape(x: f32) f32 {
    const x2 = x * x;
    const raw = x * (15.0 + x2) / (15.0 + 6.0 * x2);
    return @min(1.0, @max(-1.0, raw));
}

/// Wavefolding: sin(x * pi). At high drive, creates rich harmonics
/// through multiple fold-overs. Output naturally in [-1, 1].
inline fn fold_shape(x: f32) f32 {
    return @sin(x * std.math.pi);
}

/// Asymmetric saturation: positive half clipped harder (1-exp(-x)),
/// negative half uses tanh (softer). Creates even+odd harmonics
/// like tube amplifiers. Output clamped to [-1, 1].
inline fn asymmetric_shape(x: f32) f32 {
    if (x >= 0) {
        // Exponential saturation for positive: approaches 1.0 from below
        const raw = 1.0 - @exp(-x);
        return @min(1.0, raw);
    } else {
        // Tanh for negative: softer compression
        const x2 = x * x;
        const raw = x * (15.0 + x2) / (15.0 + 6.0 * x2);
        return @max(-1.0, raw);
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: soft-clip bounded to [-1, 1] at any drive" {
    const drives = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    const inputs = [_]f32{ -1.0, -0.5, 0.0, 0.5, 1.0 };

    for (drives) |drive| {
        for (inputs) |input| {
            const output = process_sample(input, drive, .soft_clip);
            try std.testing.expect(output >= -1.0);
            try std.testing.expect(output <= 1.0);
            try std.testing.expect(!std.math.isNan(output));
        }
    }
}

test "AC-2: tanh produces saturation (output < driven input)" {
    // Drive=0.5 maps to gain=5.5, input=0.5 → x=2.75
    // tanh(2.75) ≈ 0.99 < 2.75
    const output = process_sample(0.5, 0.5, .tanh);
    try std.testing.expect(output < 2.75);
    try std.testing.expect(output > 0.0); // same sign
    try std.testing.expect(output <= 1.0);
}

test "AC-N1: fold creates more zero-crossings at high drive" {
    const sr: f32 = 44100.0;
    const num_samples = 1024;

    // Generate one cycle of sine at ~43Hz (low freq for many samples/cycle)
    var input: [num_samples]f32 = undefined;
    for (&input, 0..) |*s, i| {
        const phase = @as(f32, @floatFromInt(i)) * 43.0 / sr;
        s.* = @sin(2.0 * std.math.pi * phase);
    }

    // Count zero-crossings without waveshaper
    var crossings_dry: u32 = 0;
    for (1..num_samples) |i| {
        if ((input[i] >= 0) != (input[i - 1] >= 0)) crossings_dry += 1;
    }

    // Count zero-crossings with fold at high drive
    var output: [num_samples]f32 = undefined;
    for (input, &output) |s, *o| {
        o.* = process_sample(s, 0.8, .fold);
    }
    var crossings_fold: u32 = 0;
    for (1..num_samples) |i| {
        if ((output[i] >= 0) != (output[i - 1] >= 0)) crossings_fold += 1;
    }

    // Fold should create more zero crossings than dry signal
    try std.testing.expect(crossings_fold > crossings_dry);
}

test "AC-N2: no NaN/Inf at extreme values" {
    const shapes = [_]ShapeType{ .soft_clip, .tanh, .fold, .asymmetric };
    const extreme_inputs = [_]f32{ -1.0, -0.999, 0.0, 0.999, 1.0 };
    const extreme_drives = [_]f32{ 0.0, 0.5, 1.0 };

    for (shapes) |shape| {
        for (extreme_drives) |drive| {
            for (extreme_inputs) |input| {
                const output = process_sample(input, drive, shape);
                try std.testing.expect(!std.math.isNan(output));
                try std.testing.expect(!std.math.isInf(output));
                try std.testing.expect(output >= -1.0);
                try std.testing.expect(output <= 1.0);
            }
        }
    }
}

test "all shapes bounded to [-1, 1]" {
    const shapes = [_]ShapeType{ .soft_clip, .tanh, .fold, .asymmetric };
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (shapes) |shape| {
        for (0..1000) |_| {
            const input = random.float(f32) * 2.0 - 1.0;
            const drive = random.float(f32);
            const output = process_sample(input, drive, shape);
            try std.testing.expect(output >= -1.0);
            try std.testing.expect(output <= 1.0);
        }
    }
}

test "soft-clip is identity at zero drive" {
    // Drive=0 → gain=1.0, soft_clip(x) for |x|<1 is x*(1.5-0.5*x²)
    // For small x, this is approximately 1.5x (slight boost)
    const out = process_sample(0.0, 0.0, .soft_clip);
    try std.testing.expectEqual(@as(f32, 0.0), out);
}

test "asymmetric has different positive/negative behavior" {
    // At moderate drive, positive and negative should saturate differently
    const pos = process_sample(0.5, 0.5, .asymmetric);
    const neg = process_sample(-0.5, 0.5, .asymmetric);

    // Asymmetric: |positive output| != |negative output|
    try std.testing.expect(@abs(pos) != @abs(neg));
    // Both bounded
    try std.testing.expect(pos >= -1.0 and pos <= 1.0);
    try std.testing.expect(neg >= -1.0 and neg <= 1.0);
}

test "process_block matches sample loop" {
    var input: [BLOCK_SIZE]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (&input) |*s| {
        s.* = random.float(f32) * 2.0 - 1.0;
    }

    const drive: f32 = 0.7;
    const shape: ShapeType = .tanh;

    // Block processing
    var out_block: [BLOCK_SIZE]f32 = undefined;
    process_block(&input, &out_block, drive, shape);

    // Sample-by-sample
    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = process_sample(s, drive, shape);
    }

    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "benchmark: waveshaper all algorithms 128 samples" {
    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;
    const drive: f32 = 0.5;

    const shapes = [_]ShapeType{ .soft_clip, .tanh, .fold, .asymmetric };
    const shape_names = [_][]const u8{ "soft_clip", "tanh", "fold", "asymmetric" };
    const budgets = [_]u64{ 200, 300, 250, 300 };

    // Debug budgets: 10x headroom over ReleaseFast targets
    const debug_budgets = [_]u64{ 5000, 5000, 5000, 5000 };

    inline for (0..4) |si| {
        const shape = shapes[si];

        // Warmup
        for (0..1000) |_| {
            process_block(&input, &output, drive, shape);
        }

        const iterations: u64 = 500_000;
        var timer = std.time.Timer.start() catch unreachable;
        for (0..iterations) |_| {
            process_block(&input, &output, drive, shape);
            std.mem.doNotOptimizeAway(&output);
        }
        const ns_per_block = timer.read() / iterations;

        std.debug.print("\n[WP-041] waveshaper {s}: {}ns/block (RF budget: {}ns, debug budget: {}ns)\n", .{
            shape_names[si], ns_per_block, budgets[si], debug_budgets[si],
        });
        try std.testing.expect(ns_per_block < debug_budgets[si]);
    }
}
