const std = @import("std");

// ── ADAA Saw Antiderivative LUT (comptime, 4096 entries) ──────────────
// F(x) = x²/2 for x in [-1, +1], used by ADAA (Antiderivative Anti-Aliasing).
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
