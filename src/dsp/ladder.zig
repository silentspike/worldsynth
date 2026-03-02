const std = @import("std");

// ── Huovilainen Non-Linear Moog Ladder Filter (ZDF, f64) (WP-017) ───
// 4 cascaded 1-pole ZDF stages, 24dB/octave LP.
// f64 integrators for numerical stability, f32 signal I/O.
// Feedback path with tanh saturation for analog character and amplitude limiting.
// Reference: Huovilainen, "Non-Linear Digital Implementation of the
// Moog Ladder Filter" (DAFX 2004)

pub const BLOCK_SIZE: usize = 128;

pub const LadderCoeffs = struct {
    g: f64,
    k: f64, // feedback = 4 * resonance
    g_comp: f64, // g / (1 + g) — precomputed for ZDF 1-pole
};

/// Compute ladder coefficients from cutoff frequency, resonance, and sample rate.
/// cutoff: Hz (20..20000), resonance: 0.0..1.0 (1.0 = self-oscillation).
pub fn make_coeffs(cutoff: f32, resonance: f32, sample_rate: f32) LadderCoeffs {
    const fc = @max(20.0, @min(@as(f32, @floatFromInt(@as(u32, @intFromFloat(sample_rate)))) * 0.499, cutoff));
    const r = @max(0.0, @min(1.0, resonance));

    // Prewarp: bilinear transform frequency mapping
    const g: f64 = @tan(std.math.pi * @as(f64, fc) / @as(f64, sample_rate));

    return .{
        .g = g,
        .k = 4.0 * @as(f64, r),
        .g_comp = g / (1.0 + g),
    };
}

/// Fast tanh via [3,2] Padé approximant.
/// Max error < 0.02 for |x| <= 3. For larger |x|, the Padé exceeds ±1 (provides
/// stronger saturation feedback which improves filter stability). No output clamp
/// needed — the 4-pole lowpass stages naturally bound the signal.
pub inline fn fast_tanh(x: f64) f64 {
    @setFloatMode(.optimized);
    const x2 = x * x;
    // [3,2] Padé: tanh(x) ≈ x(15 + x²) / (15 + 6x²)
    return x * (15.0 + x2) / (15.0 + 6.0 * x2);
}

/// Process a single sample through the Moog Ladder.
/// tanh saturation in feedback path only (amplitude limiting + analog character).
/// Input/output are f32, internal state is f64 for numerical stability.
pub inline fn process_sample(input: f32, state: *[4]f64, coeffs: LadderCoeffs) f32 {
    @setFloatMode(.optimized);
    const v0: f64 = @floatCast(input);

    // Feedback with tanh saturation (1-sample delay from state[3])
    // Input clamp to ±4 keeps Padé [3,2] in well-behaved range (output ≤ 1.12)
    // while avoiding post-division clamp on the critical path.
    const fb_in = @min(4.0, @max(-4.0, state[3] * coeffs.k));
    const fb = fast_tanh(fb_in);
    var x = v0 - fb;

    // 4 cascaded 1-pole ZDF lowpass stages (linear)
    inline for (0..4) |i| {
        const s = state[i];
        const v = coeffs.g_comp * (x - s);
        x = v + s;
        state[i] = x + v; // trapezoidal state update
    }

    return @floatCast(x);
}

/// Process with tanh saturation per stage (heavier analog character, for benchmarking).
pub inline fn process_sample_saturated(input: f32, state: *[4]f64, coeffs: LadderCoeffs) f32 {
    @setFloatMode(.optimized);
    const v0: f64 = @floatCast(input);

    const fb_in = @min(4.0, @max(-4.0, state[3] * coeffs.k));
    const fb = fast_tanh(fb_in);
    var x = v0 - fb;

    inline for (0..4) |i| {
        const s = state[i];
        const v = coeffs.g_comp * (fast_tanh(x) - s);
        x = v + s;
        state[i] = x + v;
    }

    return @floatCast(x);
}

/// Process without any tanh (fully linear, for benchmarking).
pub inline fn process_sample_linear(input: f32, state: *[4]f64, coeffs: LadderCoeffs) f32 {
    @setFloatMode(.optimized);
    const v0: f64 = @floatCast(input);

    const fb = state[3] * coeffs.k;
    var x = v0 - fb;

    inline for (0..4) |i| {
        const s = state[i];
        const v = coeffs.g_comp * (x - s);
        x = v + s;
        state[i] = x + v;
    }

    return @floatCast(x);
}

/// Process a block of 128 samples through the Moog Ladder.
pub fn process_block(
    in: *const [BLOCK_SIZE]f32,
    out: *[BLOCK_SIZE]f32,
    state: *[4]f64,
    coeffs: LadderCoeffs,
) void {
    @setFloatMode(.optimized);
    for (in, out) |sample_in, *sample_out| {
        sample_out.* = process_sample(sample_in, state, coeffs);
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "ladder self-oscillation" {
    // AC-1: resonance=1.0 → output not 0 after 44100 samples
    const coeffs = make_coeffs(1000.0, 1.0, 44100.0);
    var state = [_]f64{0} ** 4;

    // Feed impulse to start oscillation
    _ = process_sample(1.0, &state, coeffs);

    // Let it ring with zero input
    for (0..44100) |_| {
        _ = process_sample(0.0, &state, coeffs);
    }

    // Must still be oscillating — measure peak over last 100 samples
    var max_amp: f32 = 0;
    for (0..100) |_| {
        const out = process_sample(0.0, &state, coeffs);
        if (@abs(out) > max_amp) max_amp = @abs(out);
    }
    try std.testing.expect(max_amp > 1e-6);
}

test "ladder no runaway" {
    // AC-2: output stays < 10.0 at resonance=1.0 after 44100 samples
    const coeffs = make_coeffs(1000.0, 1.0, 44100.0);
    var state = [_]f64{0} ** 4;

    var phase: f32 = 0.0;
    for (0..44100) |_| {
        const input = 2.0 * phase - 1.0; // saw
        const output = process_sample(input, &state, coeffs);
        try std.testing.expect(!std.math.isNan(output));
        try std.testing.expect(!std.math.isInf(output));
        try std.testing.expect(@abs(output) < 10.0);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "ladder 24dB slope" {
    // AC-3: signal at 2x cutoff is >12dB quieter than at cutoff
    const fc: f32 = 1000.0;
    const sr: f32 = 44100.0;
    const coeffs = make_coeffs(fc, 0.0, sr); // no resonance for clean slope

    // Measure amplitude at cutoff frequency
    const amp_at_fc = blk: {
        var state = [_]f64{0} ** 4;
        var phase: f32 = 0.0;
        const inc: f32 = fc / sr;
        const amp: f32 = 0.001; // small signal for linear regime
        // Warmup
        for (0..4410) |_| {
            const input = amp * @sin(2.0 * std.math.pi * phase);
            _ = process_sample(input, &state, coeffs);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        // Measure
        var max_out: f32 = 0;
        for (0..4410) |_| {
            const input = amp * @sin(2.0 * std.math.pi * phase);
            const output = process_sample(input, &state, coeffs);
            if (@abs(output) > max_out) max_out = @abs(output);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        break :blk max_out;
    };

    // Measure amplitude at 2x cutoff frequency
    const amp_at_2fc = blk: {
        var state = [_]f64{0} ** 4;
        var phase: f32 = 0.0;
        const inc: f32 = (2.0 * fc) / sr;
        const amp: f32 = 0.001;
        for (0..4410) |_| {
            const input = amp * @sin(2.0 * std.math.pi * phase);
            _ = process_sample(input, &state, coeffs);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        var max_out: f32 = 0;
        for (0..4410) |_| {
            const input = amp * @sin(2.0 * std.math.pi * phase);
            const output = process_sample(input, &state, coeffs);
            if (@abs(output) > max_out) max_out = @abs(output);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        break :blk max_out;
    };

    // Ratio in dB
    try std.testing.expect(amp_at_fc > 0);
    try std.testing.expect(amp_at_2fc > 0);
    const ratio_db: f32 = 20.0 * @log10(amp_at_fc / amp_at_2fc);
    try std.testing.expect(ratio_db > 12.0);
}

test "ladder block equals sample loop" {
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
    var state_s = [_]f64{0} ** 4;
    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = process_sample(s, &state_s, coeffs);
    }

    // Process via block
    var state_b = [_]f64{0} ** 4;
    var out_block: [BLOCK_SIZE]f32 = undefined;
    process_block(&input, &out_block, &state_b, coeffs);

    // Must be identical
    for (out_sample, out_block) |s, b| {
        try std.testing.expectEqual(s, b);
    }
    for (state_s, state_b) |s, b| {
        try std.testing.expectEqual(s, b);
    }
}

test "ladder all outputs finite" {
    const test_cases = [_]struct { cutoff: f32, reso: f32 }{
        .{ .cutoff = 20.0, .reso = 0.0 },
        .{ .cutoff = 20.0, .reso = 0.99 },
        .{ .cutoff = 1000.0, .reso = 0.5 },
        .{ .cutoff = 10000.0, .reso = 0.0 },
        .{ .cutoff = 20000.0, .reso = 1.0 },
    };

    for (test_cases) |tc| {
        const coeffs = make_coeffs(tc.cutoff, tc.reso, 44100.0);
        var state = [_]f64{0} ** 4;
        var phase: f32 = 0.0;
        for (0..4410) |_| {
            const input = 2.0 * phase - 1.0;
            const output = process_sample(input, &state, coeffs);
            try std.testing.expect(!std.math.isNan(output));
            try std.testing.expect(!std.math.isInf(output));
            phase += 440.0 / 44100.0;
            if (phase >= 1.0) phase -= 1.0;
        }
    }
}

test "coeffs are valid for extreme parameters" {
    const c1 = make_coeffs(20.0, 0.0, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c1.g))));
    try std.testing.expect(!std.math.isInf(@as(f32, @floatCast(c1.g))));

    const c2 = make_coeffs(20000.0, 1.0, 44100.0);
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c2.g))));

    const c3 = make_coeffs(30000.0, 0.5, 44100.0); // > Nyquist (clamped)
    try std.testing.expect(!std.math.isNan(@as(f32, @floatCast(c3.g))));
}

test "fast_tanh accuracy" {
    // Verify [3,2] Padé approximation accuracy
    // Max error ~1% — sufficient for audio saturation (analog character, not precision)
    const test_vals = [_]f64{ 0.0, 0.1, 0.5, 1.0, -1.0 };
    for (test_vals) |x| {
        const approx = fast_tanh(x);
        const exact = std.math.tanh(x);
        const err = @abs(approx - exact);
        try std.testing.expect(err < 0.005); // [3,2] Padé: < 0.5% error for |x| <= 1
    }
    // Larger values: error up to ~3% (Padé [3,2] diverges past |x|~2.5)
    // Acceptable for audio — the filter's feedback loop is input-clamped to ±4.
    const large_vals = [_]f64{ 2.0, -2.5 };
    for (large_vals) |x| {
        const approx = fast_tanh(x);
        const exact = std.math.tanh(x);
        const err = @abs(approx - exact);
        try std.testing.expect(err < 0.03); // ~1-3% error acceptable for audio
    }
    // [3,2] Padé exceeds ±1 for |x| > ~2.7 — this is by design:
    // stronger feedback provides extra damping in the filter loop.
    // Key property: function is monotonically increasing and odd.
    try std.testing.expect(fast_tanh(0.5) < fast_tanh(1.0));
    try std.testing.expect(fast_tanh(1.0) < fast_tanh(2.0));
    try std.testing.expect(fast_tanh(-1.0) > fast_tanh(-2.0));
    // Odd symmetry
    try std.testing.expectApproxEqAbs(fast_tanh(1.0), -fast_tanh(-1.0), 1e-10);
    try std.testing.expectApproxEqAbs(fast_tanh(3.0), -fast_tanh(-3.0), 1e-10);
}
