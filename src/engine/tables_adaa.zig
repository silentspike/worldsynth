const std = @import("std");

// ── ADAA Antiderivative LUT (comptime, 4096 entries) ─────────────────
// F(x) = x²/2 for x in [-1, +1], used by ADAA (Antiderivative Anti-Aliasing).
// PURPOSE: Waveshaping anti-aliasing (WP-041 Pre-Filter, WP-045 Distortion).
// NOT for oscillators — oscillators use Band-Limited Wavetables (WP-013).
// See ADR: Anti-Aliasing Architektur (2026-03) in GitHub Issues.
pub const ADAA_TABLE_SIZE: usize = 4096;

pub const ADAA_SAW_ANTI: [ADAA_TABLE_SIZE]f32 = blk: {
    @setEvalBranchQuota(ADAA_TABLE_SIZE * 4);
    var table: [ADAA_TABLE_SIZE]f32 = undefined;
    var i: usize = 0;
    while (i < ADAA_TABLE_SIZE) : (i += 1) {
        // Map index to x in [-1, +1]
        const x: f64 = -1.0 + 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, ADAA_TABLE_SIZE - 1);
        table[i] = @floatCast(x * x / 2.0);
    }
    break :blk table;
};

/// Interpolated ADAA antiderivative lookup. Input clamped to [-1, 1].
pub inline fn adaa_lookup(x: f32) f32 {
    const clamped = @max(-1.0, @min(1.0, x));
    // Map [-1, 1] -> [0, ADAA_TABLE_SIZE - 1]
    const normalized = (clamped + 1.0) * 0.5;
    const idx_f = normalized * @as(f32, ADAA_TABLE_SIZE - 1);
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), ADAA_TABLE_SIZE - 2);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    // FMA: val + frac * (next - val) = val + frac * delta
    return @mulAdd(f32, frac, ADAA_SAW_ANTI[idx + 1] - ADAA_SAW_ANTI[idx], ADAA_SAW_ANTI[idx]);
}

/// ADAA saw evaluation: (F(x2) - F(x1)) / (x2 - x1) with division-by-zero guard.
pub inline fn adaa_saw(x1: f32, x2: f32) f32 {
    if (@abs(x2 - x1) < 1e-6) return (x1 + x2) * 0.5;
    return (adaa_lookup(x2) - adaa_lookup(x1)) / (x2 - x1);
}

// ── 2nd-order ADAA (F₂(x) = x³/6) ────────────────────────────────────
// Esqueda et al. (2016): 2nd-order provides ~60-80dB alias suppression
// vs ~30-40dB for 1st-order. Requires 3 consecutive x values.

pub const ADAA2_SAW_ANTI: [ADAA_TABLE_SIZE]f32 = blk: {
    @setEvalBranchQuota(ADAA_TABLE_SIZE * 4);
    var table: [ADAA_TABLE_SIZE]f32 = undefined;
    var i: usize = 0;
    while (i < ADAA_TABLE_SIZE) : (i += 1) {
        const x: f64 = -1.0 + 2.0 * @as(f64, @floatFromInt(i)) / @as(f64, ADAA_TABLE_SIZE - 1);
        table[i] = @floatCast(x * x * x / 6.0);
    }
    break :blk table;
};

/// Interpolated 2nd antiderivative lookup F₂(x) = x³/6. Input clamped to [-1, 1].
pub inline fn adaa2_lookup(x: f32) f32 {
    const clamped = @max(-1.0, @min(1.0, x));
    const normalized = (clamped + 1.0) * 0.5;
    const idx_f = normalized * @as(f32, ADAA_TABLE_SIZE - 1);
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), ADAA_TABLE_SIZE - 2);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    return @mulAdd(f32, frac, ADAA2_SAW_ANTI[idx + 1] - ADAA2_SAW_ANTI[idx], ADAA2_SAW_ANTI[idx]);
}

/// Divided difference of F₂: D(a,b) = [F₂(b)-F₂(a)]/(b-a), or F₁(midpoint) when b≈a.
inline fn adaa_d1(a: f32, b: f32) f32 {
    if (@abs(b - a) < 1e-6) return adaa_lookup(0.5 * (a + b));
    return (adaa2_lookup(b) - adaa2_lookup(a)) / (b - a);
}

/// 2nd-order ADAA saw: y[n] = 2/(x[n]-x[n-2]) * [D(x[n-1],x[n]) - D(x[n-2],x[n-1])].
/// Requires 3 consecutive phase-mapped values. Falls back to 1st-order when x2≈x_prev.
pub inline fn adaa2_saw(x_prev: f32, x1: f32, x2: f32) f32 {
    if (@abs(x2 - x_prev) < 1e-6) return adaa_saw(x1, x2);
    return 2.0 / (x2 - x_prev) * (adaa_d1(x1, x2) - adaa_d1(x_prev, x1));
}

// ── Tests ─────────────────────────────────────────────────────────────
test "adaa_saw division-by-zero guard (identical inputs)" {
    const result = adaa_saw(0.5, 0.5);
    try std.testing.expect(!std.math.isNan(result));
    try std.testing.expect(!std.math.isInf(result));
}

test "adaa_saw(-1.0, 1.0) integral symmetry approximates 0.0" {
    const result = adaa_saw(-1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 1e-4);
}

test "adaa_lookup(0.0) equals 0.0" {
    const result = adaa_lookup(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 1e-4);
}

test "all 4096 LUT entries are finite" {
    for (ADAA_SAW_ANTI) |val| {
        try std.testing.expect(!std.math.isNan(val));
        try std.testing.expect(!std.math.isInf(val));
    }
}

test "adaa_lookup clamping: out-of-range equals boundary" {
    const at_one = adaa_lookup(1.0);
    const beyond = adaa_lookup(5.0);
    try std.testing.expectApproxEqAbs(at_one, beyond, 1e-6);
}

test "adaa_lookup clamping: negative out-of-range" {
    const at_neg_one = adaa_lookup(-1.0);
    const beyond = adaa_lookup(-10.0);
    try std.testing.expectApproxEqAbs(at_neg_one, beyond, 1e-6);
}

test "adaa_saw robustness: no NaN/Inf for edge cases" {
    const cases = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ -0.0, 0.0 },
        .{ 1e-7, 2e-7 },
        .{ -1.0, -1.0 },
        .{ 1.0, 1.0 },
        .{ -1.0, 1.0 },
        .{ 0.999, 1.0 },
    };
    for (cases) |c| {
        const result = adaa_saw(c[0], c[1]);
        try std.testing.expect(!std.math.isNan(result));
        try std.testing.expect(!std.math.isInf(result));
    }
}

test "adaa_lookup boundary values: F(-1)=0.5, F(1)=0.5" {
    // F(x) = x²/2, so F(-1) = 0.5, F(1) = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), adaa_lookup(-1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), adaa_lookup(1.0), 1e-4);
}

// ── 2nd-order ADAA Tests ──────────────────────────────────────────────

test "adaa2_lookup(0.0) equals 0.0" {
    // F₂(0) = 0³/6 = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), adaa2_lookup(0.0), 1e-4);
}

test "adaa2_lookup boundary values: F₂(-1)=-1/6, F₂(1)=1/6" {
    try std.testing.expectApproxEqAbs(@as(f32, -1.0 / 6.0), adaa2_lookup(-1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 6.0), adaa2_lookup(1.0), 1e-4);
}

test "all 4096 F₂ LUT entries are finite" {
    for (ADAA2_SAW_ANTI) |val| {
        try std.testing.expect(!std.math.isNan(val));
        try std.testing.expect(!std.math.isInf(val));
    }
}

test "adaa2_lookup accuracy [max error < 1e-5]" {
    var max_err: f64 = 0;
    var j: usize = 0;
    while (j < ADAA_TABLE_SIZE) : (j += 1) {
        const x: f64 = -1.0 + 2.0 * @as(f64, @floatFromInt(j)) / @as(f64, ADAA_TABLE_SIZE - 1);
        const expected: f64 = x * x * x / 6.0;
        const actual: f64 = @as(f64, adaa2_lookup(@as(f32, @floatCast(x))));
        const err = @abs(expected - actual);
        if (err > max_err) max_err = err;
    }
    try std.testing.expect(max_err < 1e-5);
}

test "adaa2_saw robustness: no NaN/Inf for edge cases" {
    const cases = [_][3]f32{
        .{ 0.0, 0.0, 0.0 },
        .{ -0.5, 0.0, 0.5 },
        .{ 0.98, 1.0, -0.98 }, // phase wrap
        .{ -1.0, -1.0, -1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ -1.0, 0.0, 1.0 },
        .{ 0.999, 1.0, -0.999 },
    };
    for (cases) |c| {
        const result = adaa2_saw(c[0], c[1], c[2]);
        try std.testing.expect(!std.math.isNan(result));
        try std.testing.expect(!std.math.isInf(result));
    }
}

test "adaa2_saw continuous region approximates saw value" {
    // In continuous region (no wrap), 2nd-order ADAA should approximate x
    // For x_prev=0.0, x1=0.02, x2=0.04 → expected output ≈ 0.02 (the midpoint)
    const result = adaa2_saw(0.0, 0.02, 0.04);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), result, 0.01);
}
