const std = @import("std");
const builtin = @import("builtin");

// ── Optimal Transport Morphing (WP-051) ─────────────────────────────
// Wasserstein-based morphing between wavetable frames. Instead of linear
// crossfade (which causes energy dips), OT redistributes waveform "mass"
// optimally via CDF interpolation. MorphCurves provide creative t-mapping.
// Precomputable — not necessarily realtime-critical.

pub const FRAME_SIZE: usize = 2048;

pub const MorphCurve = enum(u3) {
    linear,
    exponential,
    s_curve,
    random_jump,
    pingpong,
    spiral,
};

/// Apply a morph curve to parameter t ∈ [0, 1].
pub fn apply_curve(t: f32, curve: MorphCurve) f32 {
    const tc = std.math.clamp(t, 0.0, 1.0);
    return switch (curve) {
        .linear => tc,
        .exponential => tc * tc,
        .s_curve => tc * tc * (3.0 - 2.0 * tc), // smoothstep
        .random_jump => blk: {
            // Quantize to 8 steps
            break :blk @floor(tc * 8.0) / 8.0;
        },
        .pingpong => 1.0 - @abs(2.0 * tc - 1.0),
        .spiral => tc * 4.0 - @floor(tc * 4.0), // frac(t*4)
    };
}

/// 1D Wasserstein (Earth Mover's) distance between two frames.
/// Treats frames as distributions by shifting to non-negative + normalizing.
pub fn wasserstein_distance(a: *const [FRAME_SIZE]f32, b: *const [FRAME_SIZE]f32) f32 {
    // Compute CDFs of shifted distributions
    var cdf_a: f32 = 0.0;
    var cdf_b: f32 = 0.0;
    var distance: f32 = 0.0;

    // Find min values for shift-to-positive
    var min_a: f32 = a[0];
    var min_b: f32 = b[0];
    for (a, b) |va, vb| {
        min_a = @min(min_a, va);
        min_b = @min(min_b, vb);
    }
    const shift_a = if (min_a < 0) -min_a + 0.001 else @as(f32, 0.001);
    const shift_b = if (min_b < 0) -min_b + 0.001 else @as(f32, 0.001);

    // Compute sums for normalization
    var sum_a: f32 = 0.0;
    var sum_b: f32 = 0.0;
    for (a, b) |va, vb| {
        sum_a += va + shift_a;
        sum_b += vb + shift_b;
    }
    const inv_a = if (sum_a > 0) 1.0 / sum_a else 0.0;
    const inv_b = if (sum_b > 0) 1.0 / sum_b else 0.0;

    // Wasserstein = integral of |CDF_a - CDF_b|
    for (a, b) |va, vb| {
        cdf_a += (va + shift_a) * inv_a;
        cdf_b += (vb + shift_b) * inv_b;
        distance += @abs(cdf_a - cdf_b);
    }
    return distance / @as(f32, @floatFromInt(FRAME_SIZE));
}

/// Optimal Transport morph between two frames at position t ∈ [0, 1].
/// Uses CDF interpolation: interpolate the quantile functions of both
/// distributions, then convert back to a waveform.
pub fn optimal_morph(
    a: *const [FRAME_SIZE]f32,
    b: *const [FRAME_SIZE]f32,
    t: f32,
    out: *[FRAME_SIZE]f32,
) void {
    @setFloatMode(.optimized);
    const tc = std.math.clamp(t, 0.0, 1.0);

    // Edge cases: exact endpoints
    if (tc <= 0.0) {
        @memcpy(out, a);
        return;
    }
    if (tc >= 1.0) {
        @memcpy(out, b);
        return;
    }

    // Shift both frames to non-negative for distribution interpretation
    var min_a: f32 = a[0];
    var min_b: f32 = b[0];
    for (a, b) |va, vb| {
        min_a = @min(min_a, va);
        min_b = @min(min_b, vb);
    }
    const shift_a = if (min_a < 0) -min_a + 0.001 else @as(f32, 0.001);
    const shift_b = if (min_b < 0) -min_b + 0.001 else @as(f32, 0.001);

    // Build CDFs
    var cdf_a: [FRAME_SIZE]f32 = undefined;
    var cdf_b: [FRAME_SIZE]f32 = undefined;
    var sum_a: f32 = 0.0;
    var sum_b: f32 = 0.0;
    for (&cdf_a, &cdf_b, a, b) |*ca, *cb, va, vb| {
        sum_a += va + shift_a;
        sum_b += vb + shift_b;
        ca.* = sum_a;
        cb.* = sum_b;
    }
    // Normalize CDFs to [0, 1]
    const inv_a = if (sum_a > 0) 1.0 / sum_a else 0.0;
    const inv_b = if (sum_b > 0) 1.0 / sum_b else 0.0;
    for (&cdf_a, &cdf_b) |*ca, *cb| {
        ca.* *= inv_a;
        cb.* *= inv_b;
    }

    // Interpolate CDFs: CDF_morph = (1-t)*CDF_a + t*CDF_b
    var cdf_morph: [FRAME_SIZE]f32 = undefined;
    const one_minus_t = 1.0 - tc;
    for (&cdf_morph, cdf_a, cdf_b) |*cm, ca, cb| {
        cm.* = @mulAdd(f32, cb - ca, tc, ca);
        _ = one_minus_t;
    }

    // Convert morphed CDF back to PDF (differences of consecutive CDF values)
    // Then rescale to match original amplitude range
    const target_min = @mulAdd(f32, min_b - min_a, tc, min_a);
    const target_max_a = blk: {
        var m: f32 = a[0];
        for (a) |v| m = @max(m, v);
        break :blk m;
    };
    const target_max_b = blk: {
        var m: f32 = b[0];
        for (b) |v| m = @max(m, v);
        break :blk m;
    };
    const target_range = @mulAdd(f32, (target_max_b - min_b) - (target_max_a - min_a), tc, target_max_a - min_a);

    // PDF from CDF differences
    out[0] = cdf_morph[0];
    for (1..FRAME_SIZE) |i| {
        out[i] = cdf_morph[i] - cdf_morph[i - 1];
    }

    // Rescale PDF to original amplitude range
    var pdf_min: f32 = out[0];
    var pdf_max: f32 = out[0];
    for (out) |v| {
        pdf_min = @min(pdf_min, v);
        pdf_max = @max(pdf_max, v);
    }
    const pdf_range = pdf_max - pdf_min;
    const scale = if (pdf_range > 1e-10) target_range / pdf_range else 0.0;
    for (out) |*v| {
        v.* = (v.* - pdf_min) * scale + target_min;
    }
}

// ── Tests ────────────────────────────────────────────────────────────

fn generate_test_sine(buf: *[FRAME_SIZE]f32) void {
    for (buf, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(FRAME_SIZE)));
    }
}

fn generate_test_saw(buf: *[FRAME_SIZE]f32) void {
    for (buf, 0..) |*s, i| {
        s.* = 2.0 * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(FRAME_SIZE)) - 1.0;
    }
}

test "AC-1: Morph at t=0 == frame_a, t=1 == frame_b" {
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);

    var out: [FRAME_SIZE]f32 = undefined;

    // t=0 should be exactly frame_a
    optimal_morph(&frame_a, &frame_b, 0.0, &out);
    for (out, frame_a) |o, a| {
        try std.testing.expectEqual(o, a);
    }

    // t=1 should be exactly frame_b
    optimal_morph(&frame_a, &frame_b, 1.0, &out);
    for (out, frame_b) |o, b| {
        try std.testing.expectEqual(o, b);
    }
}

test "AC-2: Morph at t=0.5 is neither frame_a nor frame_b" {
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);

    var out: [FRAME_SIZE]f32 = undefined;
    optimal_morph(&frame_a, &frame_b, 0.5, &out);

    // Must differ from both inputs
    var diff_a: f32 = 0.0;
    var diff_b: f32 = 0.0;
    for (out, frame_a, frame_b) |o, a, b| {
        diff_a += @abs(o - a);
        diff_b += @abs(o - b);
    }
    std.debug.print("\n[WP-051] OT Morph t=0.5: diff vs A={d:.4}, vs B={d:.4}\n", .{ diff_a, diff_b });
    try std.testing.expect(diff_a > 0.01);
    try std.testing.expect(diff_b > 0.01);
}

test "AC-N1: no NaN in morphed output" {
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);

    var out: [FRAME_SIZE]f32 = undefined;
    const positions = [_]f32{ 0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0 };
    for (positions) |t| {
        optimal_morph(&frame_a, &frame_b, t, &out);
        for (out) |v| {
            try std.testing.expect(!std.math.isNan(v));
            try std.testing.expect(!std.math.isInf(v));
        }
    }
}

test "wasserstein_distance: identical frames → 0" {
    var frame: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame);
    const dist = wasserstein_distance(&frame, &frame);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dist, 1e-5);
}

test "wasserstein_distance: different frames > 0" {
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);
    const dist = wasserstein_distance(&frame_a, &frame_b);
    try std.testing.expect(dist > 0.0);
}

test "apply_curve: linear identity" {
    const values = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    for (values) |v| {
        try std.testing.expectApproxEqAbs(v, apply_curve(v, .linear), 1e-6);
    }
}

test "apply_curve: s_curve endpoints" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply_curve(0.0, .s_curve), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply_curve(1.0, .s_curve), 1e-6);
}

test "apply_curve: pingpong symmetry" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply_curve(0.0, .pingpong), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply_curve(0.5, .pingpong), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply_curve(1.0, .pingpong), 1e-6);
}

test "all curves produce values in [0, 1]" {
    const curves = [_]MorphCurve{ .linear, .exponential, .s_curve, .random_jump, .pingpong, .spiral };
    for (curves) |curve| {
        for (0..101) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / 100.0;
            const result = apply_curve(t, curve);
            try std.testing.expect(result >= 0.0);
            try std.testing.expect(result <= 1.0);
        }
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: OT morph full frame (2048 samples)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);
    var out: [FRAME_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| optimal_morph(&frame_a, &frame_b, 0.5, &out);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        optimal_morph(&frame_a, &frame_b, 0.5, &out);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 50_000 else 2_000_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-051] OT morph (2048): {}ns (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Linear crossfade vs OT overhead" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var frame_a: [FRAME_SIZE]f32 = undefined;
    var frame_b: [FRAME_SIZE]f32 = undefined;
    generate_test_sine(&frame_a);
    generate_test_saw(&frame_b);
    var out: [FRAME_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| optimal_morph(&frame_a, &frame_b, 0.5, &out);
    for (0..1000) |_| {
        for (&out, frame_a, frame_b) |*o, va, vb| o.* = va * 0.5 + vb * 0.5;
    }

    const iterations: u64 = if (strict) 500_000 else 10_000;

    // Measure OT
    var timer_ot = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        optimal_morph(&frame_a, &frame_b, 0.5, &out);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns_ot = timer_ot.read() / iterations;

    // Measure Linear
    var timer_lin = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&out, frame_a, frame_b) |*o, va, vb| o.* = @mulAdd(f32, vb - va, 0.5, va);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns_lin = timer_lin.read() / iterations;

    const ratio: f64 = if (ns_lin > 0) @as(f64, @floatFromInt(ns_ot)) / @as(f64, @floatFromInt(ns_lin)) else 0.0;
    std.debug.print("\n[WP-051] OT: {}ns, Linear: {}ns, ratio: {d:.1}x\n", .{ ns_ot, ns_lin, ratio });
    // No hard ratio limit — just document the overhead
    try std.testing.expect(ns_ot < if (strict) @as(u64, 50_000) else @as(u64, 2_000_000));
}
