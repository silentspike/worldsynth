const std = @import("std");
const builtin = @import("builtin");

// ── Distortion Waveshaper (WP-045) ──────────────────────────────
// Post-filter distortion effect with 4 saturation modes: Tube
// (warm asymmetric), Fuzz (wavefold), Hard-Clip, Soft-Clip.
// Stateless pure functions, no heap, no internal state.
// Drive parameter controls saturation intensity.

pub const BLOCK_SIZE: u32 = 128;

pub const DistortionMode = enum(u2) {
    tube,
    fuzz,
    hard_clip,
    soft_clip,
};

/// Process a single sample through distortion.
/// Stateless: no internal state, pure function.
pub inline fn process_sample(input: f32, drive: f32, mode: DistortionMode) f32 {
    @setFloatMode(.optimized);
    const x = input * drive;
    return switch (mode) {
        .tube => tube_shape(x),
        .fuzz => fuzz_shape(x),
        .hard_clip => std.math.clamp(x, -1.0, 1.0),
        .soft_clip => soft_clip_shape(x),
    };
}

/// Process a block of samples.
pub fn process_block(
    out: *[BLOCK_SIZE]f32,
    in_buf: *const [BLOCK_SIZE]f32,
    drive: f32,
    mode: DistortionMode,
) void {
    for (out, in_buf) |*o, *i| {
        o.* = process_sample(i.*, drive, mode);
    }
}

// ── Shaping Algorithms ──────────────────────────────────────────────

/// Tube: asymmetric saturation (even + odd harmonics).
/// Positive half: exponential saturation (1 - exp(-x)).
/// Negative half: tanh via Padé [3,2] (softer compression).
inline fn tube_shape(x: f32) f32 {
    if (x >= 0) {
        return @min(1.0, 1.0 - @exp(-x));
    } else {
        const x2 = x * x;
        return @max(-1.0, x * (27.0 + x2) / (27.0 + 9.0 * x2));
    }
}

/// Fuzz: hard-clip + wavefold mix for aggressive harmonics.
inline fn fuzz_shape(x: f32) f32 {
    const clipped = std.math.clamp(x, -1.0, 1.0);
    return std.math.clamp(clipped + 0.3 * @sin(x * std.math.pi), -1.0, 1.0);
}

/// Soft-clip: cubic saturation for smooth limiting.
inline fn soft_clip_shape(x: f32) f32 {
    if (@abs(x) >= 1.0) return std.math.sign(x);
    return x * (1.5 - 0.5 * x * x);
}

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: Tube harmonics — output differs from input" {
    const out = process_sample(0.5, 2.0, .tube);
    try std.testing.expect(out != 0.5);
    try std.testing.expect(out != 1.0);
    try std.testing.expect(out > 0.0);
    try std.testing.expect(out <= 1.0);
}

test "AC-2: Hard-clip output always in [-1, 1]" {
    const drives = [_]f32{ 1.0, 10.0, 100.0, 1000.0 };
    const inputs = [_]f32{ -10.0, -1.0, -0.5, 0.0, 0.5, 1.0, 10.0 };
    for (drives) |drive| {
        for (inputs) |input| {
            const out = process_sample(input, drive, .hard_clip);
            try std.testing.expect(out >= -1.0);
            try std.testing.expect(out <= 1.0);
        }
    }
}

test "AC-N1: Tube asymmetric — positive and negative differ" {
    const pos = process_sample(0.5, 2.0, .tube);
    const neg = process_sample(-0.5, 2.0, .tube);
    // Asymmetric: |f(0.5)| != |f(-0.5)|
    try std.testing.expect(@abs(pos) != @abs(neg));
}

test "AC-N2: no NaN/Inf with extreme values" {
    const modes = [_]DistortionMode{ .tube, .fuzz, .hard_clip, .soft_clip };
    const extremes = [_]f32{ 0.0, 0.001, 1.0, 10.0, 1000.0, -1000.0, std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (modes) |mode| {
        for (extremes) |input| {
            const out = process_sample(input, 100.0, mode);
            try std.testing.expect(!std.math.isNan(out));
            try std.testing.expect(!std.math.isInf(out));
        }
    }
}

test "all modes bounded to [-1, 1]" {
    const modes = [_]DistortionMode{ .tube, .fuzz, .hard_clip, .soft_clip };
    for (modes) |mode| {
        for (0..1000) |i| {
            const input = @as(f32, @floatFromInt(@as(i32, @intCast(i)) - 500)) * 0.01;
            const out = process_sample(input, 5.0, mode);
            try std.testing.expect(out >= -1.0);
            try std.testing.expect(out <= 1.0);
        }
    }
}

test "soft-clip identity for small signals" {
    // For very small x, soft_clip(x) ≈ 1.5x (gain ~1.5)
    const out = process_sample(0.01, 1.0, .soft_clip);
    try std.testing.expectApproxEqAbs(0.01 * 1.5, out, 0.001);
}

test "fuzz wavefold differs from hard-clip" {
    // Fuzz adds sin(x*pi) wavefold on top of clipping — output differs from pure hard-clip
    var diff_count: u32 = 0;
    for (0..BLOCK_SIZE) |i| {
        const input = @as(f32, @floatFromInt(i)) * 0.01 - 0.5;
        const fuzz_out = process_sample(input, 5.0, .fuzz);
        const clip_out = process_sample(input, 5.0, .hard_clip);
        if (@abs(fuzz_out - clip_out) > 0.001) diff_count += 1;
    }
    // Wavefold creates measurable difference from pure clipping
    try std.testing.expect(diff_count > BLOCK_SIZE / 4);
}

test "process_block matches sequential process_sample" {
    var in_buf: [BLOCK_SIZE]f32 = undefined;
    for (&in_buf, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
    }

    var block_out: [BLOCK_SIZE]f32 = undefined;
    process_block(&block_out, &in_buf, 3.0, .tube);

    for (block_out, in_buf) |b, inp| {
        const s = process_sample(inp, 3.0, .tube);
        try std.testing.expectApproxEqAbs(b, s, 0.0001);
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: Tube" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var in_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| process_block(&out_buf, &in_buf, 0.5, .tube);

    const iterations: u64 = if (strict) 1_000_000 else 50_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        process_block(&out_buf, &in_buf, 0.5, .tube);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 300 else 20_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-045] Tube: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Fuzz" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var in_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| process_block(&out_buf, &in_buf, 0.5, .fuzz);

    const iterations: u64 = if (strict) 1_000_000 else 50_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        process_block(&out_buf, &in_buf, 0.5, .fuzz);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 350 else 20_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-045] Fuzz: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Hard-Clip" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var in_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| process_block(&out_buf, &in_buf, 0.5, .hard_clip);

    const iterations: u64 = if (strict) 1_000_000 else 50_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        process_block(&out_buf, &in_buf, 0.5, .hard_clip);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 150 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-045] Hard-Clip: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Soft-Clip" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var in_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| process_block(&out_buf, &in_buf, 0.5, .soft_clip);

    const iterations: u64 = if (strict) 1_000_000 else 50_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        process_block(&out_buf, &in_buf, 0.5, .soft_clip);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 200 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-045] Soft-Clip: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
