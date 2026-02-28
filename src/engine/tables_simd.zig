const std = @import("std");
const builtin = @import("builtin");

// ── SIMD Kernel: Comptime CPU-Feature-Erkennung + Basis-Operationen ──
// Definiert SIMD_WIDTH basierend auf CPU-Features (AVX2=8, SSE4.1=4, Scalar=1).
// Alle Operationen sind pub inline fn fuer den Audio-Hot-Path.
// Keine Runtime-Feature-Detection — alles comptime.

/// SIMD lane count: 8 (AVX2), 4 (SSE4.1), or 1 (scalar fallback).
pub const SIMD_WIDTH: comptime_int = if (std.Target.x86.featureSetHas(
    builtin.cpu.features,
    .avx2,
)) 8 else if (std.Target.x86.featureSetHas(
    builtin.cpu.features,
    .sse4_1,
)) 4 else 1;

/// SIMD f32 vector type: @Vector(SIMD_WIDTH, f32).
pub const SimdF32 = @Vector(SIMD_WIDTH, f32);

/// Elementwise addition.
pub inline fn simd_add(a: SimdF32, b: SimdF32) SimdF32 {
    return a + b;
}

/// Elementwise multiplication.
pub inline fn simd_mul(a: SimdF32, b: SimdF32) SimdF32 {
    return a * b;
}

/// Horizontal sum (reduce all lanes to scalar).
pub inline fn simd_reduce_add(v: SimdF32) f32 {
    return @reduce(.Add, v);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "SIMD_WIDTH >= 1 on any target" {
    try std.testing.expect(SIMD_WIDTH >= 1);
    std.debug.print("\n  SIMD_WIDTH = {} (", .{SIMD_WIDTH});
    if (SIMD_WIDTH == 8) {
        std.debug.print("AVX2)\n", .{});
    } else if (SIMD_WIDTH == 4) {
        std.debug.print("SSE4.1)\n", .{});
    } else {
        std.debug.print("Scalar)\n", .{});
    }
}

test "SIMD_WIDTH == 8 on AVX2 target" {
    // Ryzen 9 5900HS = Zen 3 = AVX2
    if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        try std.testing.expectEqual(@as(comptime_int, 8), SIMD_WIDTH);
    }
}

test "simd_add produces correct results" {
    const a: SimdF32 = @splat(3.0);
    const b: SimdF32 = @splat(4.0);
    const result = simd_add(a, b);
    const expected: SimdF32 = @splat(7.0);
    try std.testing.expectEqual(expected, result);
}

test "simd_mul produces correct results" {
    const a: SimdF32 = @splat(3.0);
    const b: SimdF32 = @splat(4.0);
    const result = simd_mul(a, b);
    const expected: SimdF32 = @splat(12.0);
    try std.testing.expectEqual(expected, result);
}

test "simd_reduce_add(@splat(1.0)) == SIMD_WIDTH" {
    const ones: SimdF32 = @splat(1.0);
    const sum = simd_reduce_add(ones);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(SIMD_WIDTH)), sum, 1e-6);
}

test "simd_reduce_add with varying values" {
    var v: SimdF32 = undefined;
    var expected_sum: f32 = 0;
    for (0..SIMD_WIDTH) |i| {
        const val: f32 = @as(f32, @floatFromInt(i)) + 1.0;
        v[i] = val;
        expected_sum += val;
    }
    const sum = simd_reduce_add(v);
    try std.testing.expectApproxEqAbs(expected_sum, sum, 1e-4);
}

test "simd_mul with mixed values" {
    var a: SimdF32 = undefined;
    var b: SimdF32 = undefined;
    for (0..SIMD_WIDTH) |i| {
        a[i] = @as(f32, @floatFromInt(i)) + 1.0;
        b[i] = 2.0;
    }
    const result = simd_mul(a, b);
    for (0..SIMD_WIDTH) |i| {
        const expected = (@as(f32, @floatFromInt(i)) + 1.0) * 2.0;
        try std.testing.expectApproxEqAbs(expected, result[i], 1e-6);
    }
}

test "simd_add associativity" {
    const a: SimdF32 = @splat(1.0);
    const b: SimdF32 = @splat(2.0);
    const c: SimdF32 = @splat(3.0);
    const ab_c = simd_add(simd_add(a, b), c);
    const a_bc = simd_add(a, simd_add(b, c));
    const expected: SimdF32 = @splat(6.0);
    try std.testing.expectEqual(expected, ab_c);
    try std.testing.expectEqual(expected, a_bc);
}
