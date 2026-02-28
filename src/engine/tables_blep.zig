const std = @import("std");

// ── PolyBLEP Correction Table (comptime, 128 entries) ─────────────────
// 64 pre-transition + 64 post-transition values for band-limited step
// discontinuity correction (Square, PWM, Hard-Sync).
// Pre  (t < 0): t² + 2t + 1
// Post (t >= 0): -t² + 2t - 1
pub const BLEP_SIZE: usize = 64;

pub const BLEP_TABLE: [BLEP_SIZE * 2]f32 = blk: {
    var table: [BLEP_SIZE * 2]f32 = undefined;
    var i: usize = 0;
    while (i < BLEP_SIZE * 2) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, BLEP_SIZE) - 1.0;
        if (t < 0.0) {
            table[i] = @floatCast(t * t + 2.0 * t + 1.0);
        } else {
            table[i] = @floatCast(-t * t + 2.0 * t - 1.0);
        }
    }
    break :blk table;
};

/// BLEP correction lookup with linear interpolation.
/// `t` is the fractional phase offset in [0, 1] where the discontinuity occurs.
/// Values outside [0, 1] are clamped.
pub inline fn blep_correction(t: f32) f32 {
    const clamped = @max(0.0, @min(1.0, t));
    const idx_f = clamped * @as(f32, BLEP_SIZE * 2 - 1);
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), BLEP_SIZE * 2 - 2);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    return @mulAdd(f32, frac, BLEP_TABLE[idx + 1] - BLEP_TABLE[idx], BLEP_TABLE[idx]);
}

// ── Tests ─────────────────────────────────────────────────────────────
test "blep_correction(0.5) returns finite value" {
    const result = blep_correction(0.5);
    try std.testing.expect(!std.math.isNan(result));
    try std.testing.expect(!std.math.isInf(result));
}

test "BLEP table anti-symmetry: first + last entry ≈ 0" {
    // Discretization means last entry t=127/64-1=0.984 (not exactly 1.0)
    const sum = BLEP_TABLE[0] + BLEP_TABLE[BLEP_SIZE * 2 - 1];
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sum, 1e-3);
}

test "all 128 BLEP table entries are finite" {
    for (BLEP_TABLE) |val| {
        try std.testing.expect(!std.math.isNan(val));
        try std.testing.expect(!std.math.isInf(val));
    }
}

test "blep_correction clamping: out-of-range inputs" {
    const below = blep_correction(-1.0);
    const above = blep_correction(2.0);
    try std.testing.expect(!std.math.isNan(below));
    try std.testing.expect(!std.math.isInf(below));
    try std.testing.expect(!std.math.isNan(above));
    try std.testing.expect(!std.math.isInf(above));
}

test "BLEP boundary: t=0 is pre-transition start" {
    // At t=0 (index 0), t_norm = -1.0, formula: (-1)² + 2*(-1) + 1 = 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), BLEP_TABLE[0], 1e-6);
}

test "BLEP boundary: t=1 is post-transition end" {
    // Last index t_norm=0.984 (not exactly 1.0), so value approaches but != 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), BLEP_TABLE[BLEP_SIZE * 2 - 1], 1e-3);
}

test "BLEP mid-point: maximum correction at transition" {
    // At index 64 (t_norm=0.0), post formula: -0 + 0 - 1 = -1
    // At index 63 (t_norm just below 0), pre formula: 0 + 0 + 1 ≈ 1
    // Transition region should have largest absolute values
    const pre_peak = BLEP_TABLE[BLEP_SIZE - 1];
    const post_start = BLEP_TABLE[BLEP_SIZE];
    try std.testing.expect(@abs(pre_peak) > 0.9);
    try std.testing.expect(@abs(post_start) > 0.9);
}
