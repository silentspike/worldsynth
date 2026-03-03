const std = @import("std");

// ── Cytomic SVF Zero-Delay-Feedback Filter (WP-016) ─────────────────
// Andrew Simper's State Variable Filter with zero-delay feedback.
// f64 integrators for numerical stability at low cutoff frequencies.
// 7 modes: LP, HP, BP, Notch, Peak, Shelf, Allpass.
// Block-processing: f32 → f64 → f32 per sample.
// Reference: Cytomic Technical Paper, "Solving the continuous SVF
// equations using trapezoidal integration and equivalent currents"

pub const BLOCK_SIZE: usize = 128;

pub const Mode = enum { lp, hp, bp, notch, peak, shelf, allpass };

pub const SvfCoeffs = struct {
    a1: f64,
    a2: f64,
    a3: f64,
    k: f64,
    g: f64,
};

/// Compute SVF coefficients from cutoff frequency, resonance, and sample rate.
/// cutoff: Hz (20..20000), resonance: 0.0..1.0 (0=no reso, 1=self-oscillation).
pub fn make_coeffs(cutoff: f32, resonance: f32, sample_rate: f32) SvfCoeffs {
    // Clamp to valid ranges
    const fc = @max(20.0, @min(@as(f32, @floatFromInt(@as(u32, @intFromFloat(sample_rate)))) * 0.499, cutoff));
    const r = @max(0.0, @min(1.0, resonance));

    // Prewarp: bilinear transform frequency mapping
    const g: f64 = @tan(std.math.pi * @as(f64, fc) / @as(f64, sample_rate));

    // Damping: resonance 0→k=2 (no resonance), resonance 1→k≈0 (self-oscillation)
    const k: f64 = 2.0 - 2.0 * @as(f64, r);

    // Cytomic SVF coefficients
    const a1 = 1.0 / (1.0 + g * (g + k));
    const a2 = g * a1;
    const a3 = g * a2;

    return .{ .a1 = a1, .a2 = a2, .a3 = a3, .k = k, .g = g };
}

/// Process a single sample through the SVF.
/// Input/output are f32, internal state is f64 for numerical stability.
pub inline fn process_sample(input: f32, z1: *f64, z2: *f64, coeffs: SvfCoeffs, mode: Mode) f32 {
    @setFloatMode(.optimized);
    const v0: f64 = @floatCast(input);
    const v3 = v0 - z2.*;
    const v1 = coeffs.a1 * z1.* + coeffs.a2 * v3;
    const v2 = z2.* + coeffs.a2 * z1.* + coeffs.a3 * v3;

    // State update (trapezoidal integration)
    z1.* = 2.0 * v1 - z1.*;
    z2.* = 2.0 * v2 - z2.*;

    const output: f64 = switch (mode) {
        .lp => v2,
        .hp => v0 - coeffs.k * v1 - v2,
        .bp => v1,
        .notch => v0 - coeffs.k * v1,
        .peak => 2.0 * v2 - v0 + coeffs.k * v1,
        .shelf => v0 + coeffs.k * v1,
        .allpass => v0 - 2.0 * coeffs.k * v1,
    };

    return @floatCast(output);
}

/// Process a block of 128 samples through the SVF.
pub fn process_block(
    in: *const [BLOCK_SIZE]f32,
    out: *[BLOCK_SIZE]f32,
    z1: *f64,
    z2: *f64,
    coeffs: SvfCoeffs,
    mode: Mode,
) void {
    @setFloatMode(.optimized);
    for (in, out) |sample_in, *sample_out| {
        sample_out.* = process_sample(sample_in, z1, z2, coeffs, mode);
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "svf lp 20Hz stable" {
    var z1: f64 = 0;
    var z2: f64 = 0;
    const coeffs = make_coeffs(20.0, 0.5, 44100.0);

    // Feed 44100 samples (1 second) of white-ish signal
    var phase: f32 = 0.0;
    for (0..44100) |_| {
        const input = 2.0 * phase - 1.0; // naive saw
        const output = process_sample(input, &z1, &z2, coeffs, .lp);
        try std.testing.expect(!std.math.isNan(output));
        try std.testing.expect(!std.math.isInf(output));
        try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(z1))));
        try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(z2))));
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "svf hp passes high freq" {
    var z1: f64 = 0;
    var z2: f64 = 0;
    const coeffs = make_coeffs(10000.0, 0.5, 44100.0);

    // Feed 15kHz sine through HP @ 10kHz — should pass
    var phase: f32 = 0.0;
    const phase_inc: f32 = 15000.0 / 44100.0;
    var max_output: f32 = 0.0;

    // Warmup: let filter settle
    for (0..4410) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        _ = process_sample(input, &z1, &z2, coeffs, .hp);
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Measure
    for (0..4410) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        const output = process_sample(input, &z1, &z2, coeffs, .hp);
        if (@abs(output) > max_output) max_output = @abs(output);
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }
    try std.testing.expect(max_output > 0.5);
}

test "svf high reso stable" {
    var z1: f64 = 0;
    var z2: f64 = 0;
    const coeffs = make_coeffs(1000.0, 0.99, 44100.0);

    // Feed 44100 samples at high resonance
    var phase: f32 = 0.0;
    for (0..44100) |_| {
        const input = 2.0 * phase - 1.0;
        const output = process_sample(input, &z1, &z2, coeffs, .lp);
        try std.testing.expect(!std.math.isNan(output));
        try std.testing.expect(!std.math.isInf(output));
        try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(z1))));
        try std.testing.expect(!std.math.isInf(@as(f32, @floatCast(z1))));
        try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(z2))));
        try std.testing.expect(!std.math.isInf(@as(f32, @floatCast(z2))));
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "block equals sample loop" {
    const coeffs = make_coeffs(1000.0, 0.5, 44100.0);

    // Generate input
    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = 2.0 * phase - 1.0;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Process via sample loop
    var z1_s: f64 = 0;
    var z2_s: f64 = 0;
    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = process_sample(s, &z1_s, &z2_s, coeffs, .lp);
    }

    // Process via block
    var z1_b: f64 = 0;
    var z2_b: f64 = 0;
    var out_block: [BLOCK_SIZE]f32 = undefined;
    process_block(&input, &out_block, &z1_b, &z2_b, coeffs, .lp);

    // Must be identical
    for (out_sample, out_block) |s, b| {
        try std.testing.expectEqual(s, b);
    }
    try std.testing.expectEqual(z1_s, z1_b);
    try std.testing.expectEqual(z2_s, z2_b);
}

test "all 7 modes produce finite output" {
    const modes = [_]Mode{ .lp, .hp, .bp, .notch, .peak, .shelf, .allpass };
    const coeffs = make_coeffs(1000.0, 0.5, 44100.0);

    for (modes) |mode| {
        var z1: f64 = 0;
        var z2: f64 = 0;
        var phase: f32 = 0.0;
        for (0..1000) |_| {
            const input = 2.0 * phase - 1.0;
            const output = process_sample(input, &z1, &z2, coeffs, mode);
            try std.testing.expect(!std.math.isNan(output));
            try std.testing.expect(!std.math.isInf(output));
            phase += 440.0 / 44100.0;
            if (phase >= 1.0) phase -= 1.0;
        }
    }
}

test "lp attenuates high frequencies" {
    var z1: f64 = 0;
    var z2: f64 = 0;
    const coeffs = make_coeffs(500.0, 0.5, 44100.0);

    // Feed 10kHz sine through LP @ 500Hz — should attenuate significantly
    var phase: f32 = 0.0;
    const phase_inc: f32 = 10000.0 / 44100.0;

    // Warmup
    for (0..4410) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        _ = process_sample(input, &z1, &z2, coeffs, .lp);
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Measure
    var max_output: f32 = 0.0;
    for (0..4410) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        const output = process_sample(input, &z1, &z2, coeffs, .lp);
        if (@abs(output) > max_output) max_output = @abs(output);
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }
    // 10kHz through 500Hz LP should be heavily attenuated (< 0.05)
    try std.testing.expect(max_output < 0.05);
}

test "coeffs are valid for extreme parameters" {
    // Very low cutoff
    const c1 = make_coeffs(20.0, 0.0, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c1.a1))));
    try std.testing.expect(!std.math.isInf(@as(f32, @floatCast(c1.a1))));

    // Very high cutoff
    const c2 = make_coeffs(20000.0, 0.0, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c2.a1))));

    // Max resonance
    const c3 = make_coeffs(1000.0, 1.0, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c3.a1))));

    // Edge: cutoff > Nyquist (clamped)
    const c4 = make_coeffs(30000.0, 0.5, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c4.a1))));
}
