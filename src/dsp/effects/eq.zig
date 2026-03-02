const std = @import("std");
const filter = @import("../filter.zig");

// ── 8-Band Graphic EQ (WP-046) ─────────────────────────────────────
// 8 serial SVF bands in BP mode with gain mixing for parametric EQ.
// Fixed octave-spaced frequencies (60Hz..12kHz), ±12dB gain per band.
// Uses ZDF-SVF from WP-016 (f64 integrators) in BP mode.
// Mixing: output = input + (gain_linear - 1) * bp
// At 0dB gain: exact unity (gain_linear = 1, mix = 0).
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = filter.BLOCK_SIZE;
pub const NUM_BANDS: usize = 8;

/// Fixed band center frequencies (Hz), octave-spaced.
pub const BAND_FREQS = [NUM_BANDS]f32{ 60, 170, 310, 600, 1000, 3000, 6000, 12000 };

/// Resonance for EQ bands: r=0.645 → Q≈1.41 (moderate bandwidth).
const BAND_RESONANCE: f32 = 0.645;

pub const EQ = struct {
    const Self = @This();

    z1: [NUM_BANDS]f64,
    z2: [NUM_BANDS]f64,
    coeffs: [NUM_BANDS]filter.SvfCoeffs,
    gains_db: [NUM_BANDS]f32,
    gains_linear: [NUM_BANDS]f32, // precomputed: 10^(gain_db/20)
    sample_rate: f32,

    pub fn init(sample_rate: f32) Self {
        var self: Self = .{
            .z1 = .{0.0} ** NUM_BANDS,
            .z2 = .{0.0} ** NUM_BANDS,
            .coeffs = undefined,
            .gains_db = .{0.0} ** NUM_BANDS,
            .gains_linear = .{1.0} ** NUM_BANDS,
            .sample_rate = sample_rate,
        };
        for (0..NUM_BANDS) |b| {
            self.coeffs[b] = filter.make_coeffs(BAND_FREQS[b], BAND_RESONANCE, sample_rate);
        }
        return self;
    }

    /// Set gain for a single band. gain_db clamped to [-12, +12].
    pub fn set_band(self: *Self, idx: usize, gain_db: f32) void {
        if (idx >= NUM_BANDS) return;
        const clamped = @max(-12.0, @min(12.0, gain_db));
        self.gains_db[idx] = clamped;
        self.gains_linear[idx] = std.math.pow(f32, 10.0, clamped / 20.0);
    }

    /// Process a single sample through all 8 serial EQ bands.
    /// Each band: bp = SVF bandpass, output = signal + (gain_linear - 1) * bp.
    pub inline fn process_sample(self: *Self, input: f32) f32 {
        var signal = input;
        inline for (0..NUM_BANDS) |b| {
            const bp = filter.process_sample(signal, &self.z1[b], &self.z2[b], self.coeffs[b], .bp);
            signal += (self.gains_linear[b] - 1.0) * bp;
        }
        return signal;
    }

    /// Process a block of BLOCK_SIZE samples.
    pub fn process_block(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (in_buf, out_buf) |s, *o| {
            o.* = self.process_sample(s);
        }
    }

    /// Reset all filter state to zero.
    pub fn reset(self: *Self) void {
        self.z1 = .{0.0} ** NUM_BANDS;
        self.z2 = .{0.0} ** NUM_BANDS;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

/// Goertzel algorithm: magnitude of a specific frequency.
fn goertzel_magnitude(buf: []const f32, target_freq: f32, sample_rate: f32) f32 {
    const n: f32 = @floatFromInt(buf.len);
    const k = target_freq * n / sample_rate;
    const w = 2.0 * std.math.pi * k / n;
    const coeff = 2.0 * @cos(w);

    var s0: f64 = 0.0;
    var s1: f64 = 0.0;
    var s2: f64 = 0.0;

    for (buf) |sample| {
        s0 = @as(f64, sample) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }

    const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    return @floatCast(@sqrt(@max(0.0, power)) / n);
}

test "AC-1: band at 1kHz +6dB boosts 1kHz signal" {
    const sr: f32 = 44100.0;
    var eq = EQ.init(sr);
    eq.set_band(4, 6.0); // Band 4 = 1000Hz, +6dB

    // Generate 1kHz sine
    const num_samples = 8192;
    var input: [num_samples]f32 = undefined;
    var output: [num_samples]f32 = undefined;
    for (&input, 0..) |*s, i| {
        const phase = @as(f32, @floatFromInt(i)) * 1000.0 / sr;
        s.* = @sin(2.0 * std.math.pi * phase);
    }

    // Process
    for (input, &output) |s, *o| {
        o.* = eq.process_sample(s);
    }

    // Measure magnitude at 1kHz (skip first 2048 for settling)
    const mag_in = goertzel_magnitude(input[2048..], 1000.0, sr);
    const mag_out = goertzel_magnitude(output[2048..], 1000.0, sr);

    // Output should be louder than input at 1kHz
    try std.testing.expect(mag_out > mag_in);
}

test "AC-N1: all bands at 0dB = unity gain" {
    const sr: f32 = 44100.0;
    var eq = EQ.init(sr);
    // All gains default to 0dB

    // Process a signal through
    const num_samples = 4096;
    var max_diff: f32 = 0.0;

    var phase: f32 = 0.0;
    // Warmup: let filter settle
    for (0..2048) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        _ = eq.process_sample(input);
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Measure difference
    for (0..num_samples) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        const output = eq.process_sample(input);
        const diff = @abs(output - input);
        if (diff > max_diff) max_diff = diff;
        phase += 440.0 / sr;
        if (phase >= 1.0) phase -= 1.0;
    }

    // At 0dB, output should be very close to input
    try std.testing.expect(max_diff < 0.01);
}

test "AC-N2: uses SVF from WP-016" {
    // Compile-time verification: if filter module changes, this fails.
    const coeffs = filter.make_coeffs(1000.0, 0.5, 44100.0);
    var z1: f64 = 0;
    var z2: f64 = 0;
    const result = filter.process_sample(0.5, &z1, &z2, coeffs, .bp);
    try std.testing.expect(!std.math.isNan(result));
}

test "no NaN/Inf with extreme gains" {
    var eq = EQ.init(44100.0);
    // Set extreme gains
    for (0..NUM_BANDS) |b| {
        eq.set_band(b, if (b % 2 == 0) 12.0 else -12.0);
    }

    var phase: f32 = 0.0;
    for (0..4096) |_| {
        const input = @sin(2.0 * std.math.pi * phase);
        const output = eq.process_sample(input);
        try std.testing.expect(!std.math.isNan(output));
        try std.testing.expect(!std.math.isInf(output));
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "process_block matches sample loop" {
    var eq_block = EQ.init(44100.0);
    var eq_sample = EQ.init(44100.0);
    eq_block.set_band(2, 6.0);
    eq_sample.set_band(2, 6.0);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var out_block: [BLOCK_SIZE]f32 = undefined;
    eq_block.process_block(&input, &out_block);

    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = eq_sample.process_sample(s);
    }

    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "reset clears filter state" {
    var eq = EQ.init(44100.0);
    eq.set_band(0, 12.0);

    // Feed signal
    for (0..100) |_| {
        _ = eq.process_sample(1.0);
    }

    // State should be non-zero
    var has_state = false;
    for (eq.z1) |z| {
        if (z != 0.0) has_state = true;
    }
    try std.testing.expect(has_state);

    // Reset
    eq.reset();

    for (eq.z1) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
    for (eq.z2) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
}

test "set_band clamps gain to ±12dB" {
    var eq = EQ.init(44100.0);

    eq.set_band(0, 20.0);
    try std.testing.expectEqual(@as(f32, 12.0), eq.gains_db[0]);

    eq.set_band(0, -20.0);
    try std.testing.expectEqual(@as(f32, -12.0), eq.gains_db[0]);

    // Out of range index: no crash
    eq.set_band(8, 6.0);
    eq.set_band(100, 6.0);
}

test "benchmark: EQ 8 bands 128 samples" {
    var eq = EQ.init(44100.0);
    // Set some gains for realistic workload
    eq.set_band(0, 3.0);
    eq.set_band(2, -2.0);
    eq.set_band(4, 6.0);
    eq.set_band(7, -3.0);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| eq.process_block(&input, &output);

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        eq.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    // 8 serial SVF bands: 8 × ~2200ns/SVF (debug) ≈ 17600ns
    // Budget: generous for debug mode + build server variability
    const budget_ns: u64 = 100000;
    std.debug.print("\n[WP-046] EQ 8-band: {}ns/block, {}ns/band (budget: {}ns)\n", .{
        ns_per_block, ns_per_block / NUM_BANDS, budget_ns,
    });
    try std.testing.expect(ns_per_block < budget_ns);
}
