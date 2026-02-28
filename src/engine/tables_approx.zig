const std = @import("std");

// ── Polynomial Sine Approximation (9th-order, range-reduced) ────────
// Range-Reduction: [-pi, pi] → [-pi/2, pi/2] via sin(pi-x) = sin(x).
// Dann 9th-order Taylor via Horner's Method.
// Max error < 1e-4 ueber [-pi, pi]. Kein @sin im Runtime-Pfad.

/// Fast sine via 9th-order polynomial with range reduction.
/// Input x in [-pi, pi]. Error < 1e-4 over full range.
pub inline fn sin_fast_poly(x: f32) f32 {
    // Range reduction: fold [-pi, pi] to [-pi/2, pi/2]
    const half_pi = std.math.pi / 2.0;
    var y = x;
    if (y > half_pi) {
        y = std.math.pi - y;
    } else if (y < -half_pi) {
        y = -std.math.pi - y;
    }
    // 9th-order Taylor: x*(1 - x²/6 + x⁴/120 - x⁶/5040 + x⁸/362880)
    const y2 = y * y;
    const p4 = @mulAdd(f32, 2.7557319e-6, y2, -0.0001984127);
    const p3 = @mulAdd(f32, p4, y2, 0.008333333);
    const p2 = @mulAdd(f32, p3, y2, -0.16666667);
    const p1 = @mulAdd(f32, p2, y2, 1.0);
    return y * p1;
}

// ── Fast Exponential Approximation (range-reduced + IEEE 754) ───────
// Range-Reduction: exp(x) = 2^n * exp(f), n = round(x/ln2), |f| < ln2/2.
// 4th-order Taylor fuer exp(f), Bit-Manipulation fuer 2^n.
// Relativer Fehler < 1% fuer x in [-87, 87]. Kein @exp im Runtime-Pfad.

/// Fast exp(x) via range reduction + 4th-order polynomial + IEEE 754 scaling.
/// Relative error < 1% for x in [-87, 87].
pub inline fn exp_fast(x: f32) f32 {
    const log2e: f32 = 1.44269504;
    const ln2: f32 = 0.6931472;
    // Clamp to safe range (avoids Inf/denorm)
    const cx = @max(-87.0, @min(87.0, x));
    const n_f = @round(cx * log2e);
    const f = @mulAdd(f32, -n_f, ln2, cx);
    // 4th-order Taylor: exp(f) ≈ 1 + f + f²/2 + f³/6 + f⁴/24
    // Horner form: ((f/24 + 1/6)*f + 1/2)*f + 1)*f + 1
    const c3 = @mulAdd(f32, 0.041666668, f, 0.16666667);
    const c2 = @mulAdd(f32, c3, f, 0.5);
    const c1 = @mulAdd(f32, c2, f, 1.0);
    const p = @mulAdd(f32, c1, f, 1.0);
    // 2^n via IEEE 754 exponent manipulation
    const n_i: i32 = @intFromFloat(n_f);
    const exp_bits = @as(u32, @intCast(n_i + 127)) << 23;
    const scale: f32 = @bitCast(exp_bits);
    return p * scale;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "sin_fast_poly(pi/2) approximates 1.0" {
    const result = sin_fast_poly(std.math.pi / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 1e-4);
}

test "sin_fast_poly(0) equals 0.0" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sin_fast_poly(0.0), 1e-6);
}

test "sin_fast_poly(-pi/2) approximates -1.0" {
    const result = sin_fast_poly(-std.math.pi / 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result, 1e-4);
}

test "sin_fast_poly(pi) approximates 0.0" {
    const result = sin_fast_poly(std.math.pi);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 1e-3);
}

test "sin_fast_poly max error < 1e-4 over [-pi, pi]" {
    var max_err: f64 = 0;
    const steps: usize = 10_000;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const x: f64 = -std.math.pi + 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const expected = @sin(x);
        const actual: f64 = @as(f64, sin_fast_poly(@as(f32, @floatCast(x))));
        const err = @abs(expected - actual);
        if (err > max_err) max_err = err;
    }
    try std.testing.expect(max_err < 1e-4);
}

test "exp_fast(0) approximates 1.0" {
    const result = exp_fast(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.01);
}

test "exp_fast(1) approximates e" {
    const result = exp_fast(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.e), result, 0.1);
}

test "exp_fast(-1) approximates 1/e" {
    const result = exp_fast(-1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / std.math.e), result, 0.05);
}

test "exp_fast relative error < 1% over [-10, 10]" {
    var max_rel_err: f64 = 0;
    const steps: usize = 10_000;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const x: f64 = -10.0 + 20.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const expected = @exp(x);
        const actual: f64 = @as(f64, exp_fast(@as(f32, @floatCast(x))));
        if (expected > 1e-10) {
            const rel_err = @abs(actual - expected) / expected;
            if (rel_err > max_rel_err) max_rel_err = rel_err;
        }
    }
    try std.testing.expect(max_rel_err < 0.01);
}

test "exp_fast no NaN/Inf for edge cases" {
    const cases = [_]f32{ -20.0, -10.0, 0.0, 10.0, 20.0 };
    for (cases) |x| {
        const result = exp_fast(x);
        try std.testing.expect(!std.math.isNan(result));
        try std.testing.expect(!std.math.isInf(result));
    }
}
