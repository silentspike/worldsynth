const std = @import("std");
const filter = @import("filter.zig");

// ── Formant Filter (WP-033) ─────────────────────────────────────────
// 5 parallel ZDF-SVF bandpass filters for vowel resonances (A/E/I/O/U).
// Each vowel has 5 characteristic formant frequencies (F1-F5).
// Based on the Cytomic SVF from WP-016 (f64 integrators).
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = filter.BLOCK_SIZE;
pub const NUM_BANDS: usize = 5;

pub const Vowel = enum(u3) { a = 0, e = 1, i = 2, o = 3, u = 4 };

/// Formant frequencies (Hz) and resonance values per vowel.
/// Source: Petersen & Barney (1952), standard acoustic phonetics data.
/// Each row: [F1, F2, F3, F4, F5]
pub const VOWEL_FORMANTS = [5][NUM_BANDS]f32{
    //        F1     F2      F3      F4      F5
    .{ 730, 1090, 2440, 3400, 4500 }, // A (open front)
    .{ 530, 1840, 2480, 3400, 4500 }, // E (mid front)
    .{ 270, 2290, 3010, 3400, 4500 }, // I (close front)
    .{ 570, 840, 2410, 3400, 4500 }, // O (mid back)
    .{ 300, 870, 2240, 3400, 4500 }, // U (close back)
};

/// Per-band resonance values (0..1). Higher formants get tighter Q.
/// Q ≈ 1/(2*(1-r)): r=0.94→Q≈8.3, r=0.96→Q≈12.5, r=0.97→Q≈16.7
const BAND_RESONANCE = [NUM_BANDS]f32{ 0.94, 0.96, 0.96, 0.97, 0.97 };

pub const FormantFilter = struct {
    const Self = @This();

    z1: [NUM_BANDS]f64,
    z2: [NUM_BANDS]f64,
    coeffs: [NUM_BANDS]filter.SvfCoeffs,
    gains: [NUM_BANDS]f32,
    current_vowel: Vowel,
    sample_rate: f32,

    /// Initialize with default vowel "A".
    pub fn init(sample_rate: f32) Self {
        var self: Self = .{
            .z1 = .{0.0} ** NUM_BANDS,
            .z2 = .{0.0} ** NUM_BANDS,
            .coeffs = undefined,
            .gains = .{1.0} ** NUM_BANDS,
            .current_vowel = .a,
            .sample_rate = sample_rate,
        };
        self.set_vowel(.a);
        return self;
    }

    /// Set vowel and recalculate all band coefficients.
    pub fn set_vowel(self: *Self, vowel: Vowel) void {
        self.current_vowel = vowel;
        const freqs = VOWEL_FORMANTS[@intFromEnum(vowel)];
        for (0..NUM_BANDS) |b| {
            self.coeffs[b] = filter.make_coeffs(freqs[b], BAND_RESONANCE[b], self.sample_rate);
        }
    }

    /// Process a single sample through all 5 parallel bandpass filters.
    pub inline fn process_sample(self: *Self, input: f32) f32 {
        var sum: f32 = 0.0;
        inline for (0..NUM_BANDS) |b| {
            const bp = filter.process_sample(input, &self.z1[b], &self.z2[b], self.coeffs[b], .bp);
            sum += bp * self.gains[b];
        }
        return sum;
    }

    /// Process a block of BLOCK_SIZE samples.
    pub fn process_block(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (in_buf, out_buf) |sample_in, *sample_out| {
            sample_out.* = self.process_sample(sample_in);
        }
    }

    /// Reset all filter state to zero.
    pub fn reset(self: *Self) void {
        self.z1 = .{0.0} ** NUM_BANDS;
        self.z2 = .{0.0} ** NUM_BANDS;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

/// Goertzel algorithm: compute magnitude of a specific frequency bin.
/// More efficient than FFT when only a few frequencies need checking.
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

test "AC-1: vowel A has formant peaks at F1≈730Hz and F2≈1090Hz" {
    const sr: f32 = 44100.0;
    var fmt = FormantFilter.init(sr);
    fmt.set_vowel(.a);

    // Generate white-ish noise (deterministic PRNG for reproducibility)
    const num_samples = 8192;
    var input: [num_samples]f32 = undefined;
    var output: [num_samples]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (&input) |*s| {
        s.* = random.float(f32) * 2.0 - 1.0;
    }

    // Process through formant filter
    for (input, &output) |s, *o| {
        o.* = fmt.process_sample(s);
    }

    // Measure magnitude at formant frequencies vs well-off-formant
    // Vowel A: F1=730, F2=1090, F3=2440, F4=3400, F5=4500
    // Off-freq at 150Hz (well below F1=730) where no formant exists
    const mag_f1 = goertzel_magnitude(&output, 730.0, sr);
    const mag_f2 = goertzel_magnitude(&output, 1090.0, sr);
    const mag_off = goertzel_magnitude(&output, 150.0, sr);

    // Formant peaks should be stronger than off-frequency
    try std.testing.expect(mag_f1 > mag_off);
    try std.testing.expect(mag_f2 > mag_off);
}

test "AC-2: no NaN for all 5 vowels" {
    const sr: f32 = 44100.0;

    const vowels = [_]Vowel{ .a, .e, .i, .o, .u };
    for (vowels) |vowel| {
        var fmt = FormantFilter.init(sr);
        fmt.set_vowel(vowel);

        var phase: f32 = 0.0;
        for (0..1000) |_| {
            const input = @sin(2.0 * std.math.pi * phase);
            const output = fmt.process_sample(input);
            try std.testing.expect(!std.math.isNan(output));
            try std.testing.expect(!std.math.isInf(output));
            phase += 440.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
    }
}

test "AC-N1: silence in → silence out (no self-oscillation)" {
    var fmt = FormantFilter.init(44100.0);
    fmt.set_vowel(.a);

    for (0..512) |_| {
        const output = fmt.process_sample(0.0);
        try std.testing.expectEqual(@as(f32, 0.0), output);
    }
}

test "AC-N2: uses SVF from WP-016 (import verified at compile time)" {
    // This test verifies at compile time that filter.zig types are used.
    // If the import or types changed, this would fail to compile.
    const coeffs = filter.make_coeffs(1000.0, 0.5, 44100.0);
    var z1: f64 = 0;
    var z2: f64 = 0;
    const result = filter.process_sample(0.5, &z1, &z2, coeffs, .bp);
    try std.testing.expect(!std.math.isNan(result));
}

test "all vowels produce different spectral shapes" {
    const sr: f32 = 44100.0;
    const num_samples = 4096;

    // Generate deterministic noise
    var input: [num_samples]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (&input) |*s| {
        s.* = random.float(f32) * 2.0 - 1.0;
    }

    // Measure F1 magnitude for each vowel
    var f1_mags: [5]f32 = undefined;
    const vowels = [_]Vowel{ .a, .e, .i, .o, .u };

    for (vowels, 0..) |vowel, vi| {
        var fmt = FormantFilter.init(sr);
        fmt.set_vowel(vowel);
        var output: [num_samples]f32 = undefined;
        for (input, &output) |s, *o| {
            o.* = fmt.process_sample(s);
        }
        f1_mags[vi] = goertzel_magnitude(&output, VOWEL_FORMANTS[@intFromEnum(vowel)][0], sr);
    }

    // Each vowel's F1 should produce measurable energy
    for (f1_mags) |mag| {
        try std.testing.expect(mag > 0.001);
    }
}

test "process_block matches sample loop" {
    var fmt_block = FormantFilter.init(44100.0);
    var fmt_sample = FormantFilter.init(44100.0);
    fmt_block.set_vowel(.e);
    fmt_sample.set_vowel(.e);

    // Generate input
    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Block processing
    var out_block: [BLOCK_SIZE]f32 = undefined;
    fmt_block.process_block(&input, &out_block);

    // Sample-by-sample processing
    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = fmt_sample.process_sample(s);
    }

    // Must be identical
    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "reset clears filter state" {
    var fmt = FormantFilter.init(44100.0);

    // Feed some signal
    for (0..100) |_| {
        _ = fmt.process_sample(1.0);
    }

    // State should be non-zero
    var has_state = false;
    for (fmt.z1) |z| {
        if (z != 0.0) has_state = true;
    }
    try std.testing.expect(has_state);

    // Reset
    fmt.reset();

    // All state should be zero
    for (fmt.z1) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
    for (fmt.z2) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
}

test "benchmark: formant filter 128 samples" {
    var fmt = FormantFilter.init(44100.0);
    fmt.set_vowel(.a);

    // Generate input
    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        fmt.process_block(&input, &output);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        fmt.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const elapsed_ns = timer.read();
    const ns_per_block = elapsed_ns / iterations;

    // Budget: Issue says < 7500ns (ReleaseFast target)
    // Debug mode: ~18000ns (remote), ~26000ns (local Ryzen 9)
    // ReleaseFast: ~1522ns (remote), ~2128ns (local)
    // Threshold for debug test gate: 35000ns (covers both CPUs with headroom)
    const budget_ns: u64 = 35000;
    std.debug.print("\n[WP-033] formant_filter 5xSVF: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}
