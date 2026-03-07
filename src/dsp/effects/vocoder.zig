const std = @import("std");
const builtin = @import("builtin");
const filter = @import("../filter.zig");

// -- Vocoder + Talk-Box (WP-048) ------------------------------------------
// 16-band vocoder with envelope followers. Analysis bandpass bank extracts
// spectral envelope from modulator, synthesis bank applies it to carrier.
// Talk-Box mode: 8 bands with higher resonance for tube character.
// Log-spaced bands 100Hz..10kHz. Zero heap allocation.

pub const BLOCK_SIZE: usize = filter.BLOCK_SIZE;
pub const MAX_BANDS: u32 = 16;

pub const VocoderMode = enum(u1) {
    vocoder,
    talk_box,
};

pub const Vocoder = struct {
    const Self = @This();

    // Filter states: analysis (modulator) + synthesis (carrier)
    analysis_z1: [MAX_BANDS]f64,
    analysis_z2: [MAX_BANDS]f64,
    synthesis_z1: [MAX_BANDS]f64,
    synthesis_z2: [MAX_BANDS]f64,
    coeffs: [MAX_BANDS]filter.SvfCoeffs,
    envelopes: [MAX_BANDS]f32,

    attack_coeff: f32,
    release_coeff: f32,
    mode: VocoderMode,
    active_bands: u32,

    pub fn init(sample_rate: f32) Self {
        var self: Self = .{
            .analysis_z1 = .{0.0} ** MAX_BANDS,
            .analysis_z2 = .{0.0} ** MAX_BANDS,
            .synthesis_z1 = .{0.0} ** MAX_BANDS,
            .synthesis_z2 = .{0.0} ** MAX_BANDS,
            .coeffs = undefined,
            .envelopes = .{0.0} ** MAX_BANDS,
            .attack_coeff = compute_coeff(0.005, sample_rate),
            .release_coeff = compute_coeff(0.020, sample_rate),
            .mode = .vocoder,
            .active_bands = MAX_BANDS,
        };
        self.compute_band_coeffs(MAX_BANDS, 0.875, sample_rate);
        return self;
    }

    /// Switch between vocoder (16 bands, Q~8) and talk_box (8 bands, Q~12).
    pub fn set_mode(self: *Self, mode: VocoderMode, sample_rate: f32) void {
        self.mode = mode;
        switch (mode) {
            .vocoder => {
                self.active_bands = 16;
                self.compute_band_coeffs(16, 0.875, sample_rate);
            },
            .talk_box => {
                self.active_bands = 8;
                self.compute_band_coeffs(8, 0.917, sample_rate);
            },
        }
        self.reset();
    }

    /// Process one sample pair (carrier + modulator) through the vocoder.
    pub inline fn process_sample(self: *Self, carrier: f32, modulator: f32) f32 {
        @setFloatMode(.optimized);
        var output: f32 = 0.0;
        const bands = self.active_bands;
        for (0..bands) |i| {
            const bp_mod = filter.process_sample(
                modulator,
                &self.analysis_z1[i],
                &self.analysis_z2[i],
                self.coeffs[i],
                .bp,
            );
            const rectified = @abs(bp_mod);
            const coeff = if (rectified > self.envelopes[i]) self.attack_coeff else self.release_coeff;
            self.envelopes[i] = coeff * self.envelopes[i] + (1.0 - coeff) * rectified;

            const bp_car = filter.process_sample(
                carrier,
                &self.synthesis_z1[i],
                &self.synthesis_z2[i],
                self.coeffs[i],
                .bp,
            );
            output += bp_car * self.envelopes[i];
        }
        return output;
    }

    /// Process a block of samples. Band-at-a-time for cache locality:
    /// each band's filter state stays in registers for the full block.
    pub fn process_block(
        self: *Self,
        out: *[BLOCK_SIZE]f32,
        carrier_buf: *const [BLOCK_SIZE]f32,
        modulator_buf: *const [BLOCK_SIZE]f32,
    ) void {
        @setFloatMode(.optimized);
        @memset(out, 0.0);
        const bands = self.active_bands;
        for (0..bands) |i| {
            self.process_band_block(i, out, carrier_buf, modulator_buf);
        }
    }

    /// Process one band across the full block.
    inline fn process_band_block(
        self: *Self,
        band: usize,
        out: *[BLOCK_SIZE]f32,
        carrier_buf: *const [BLOCK_SIZE]f32,
        modulator_buf: *const [BLOCK_SIZE]f32,
    ) void {
        // Load band state into locals for register promotion
        var az1 = self.analysis_z1[band];
        var az2 = self.analysis_z2[band];
        var sz1 = self.synthesis_z1[band];
        var sz2 = self.synthesis_z2[band];
        var env = self.envelopes[band];
        const coeffs = self.coeffs[band];
        const atk = self.attack_coeff;
        const rel = self.release_coeff;

        for (out, carrier_buf, modulator_buf) |*o, *c, *m| {
            const bp_mod = filter.process_sample(m.*, &az1, &az2, coeffs, .bp);
            const rectified = @abs(bp_mod);
            const coeff = if (rectified > env) atk else rel;
            env = coeff * env + (1.0 - coeff) * rectified;

            const bp_car = filter.process_sample(c.*, &sz1, &sz2, coeffs, .bp);
            o.* += bp_car * env;
        }

        // Write back
        self.analysis_z1[band] = az1;
        self.analysis_z2[band] = az2;
        self.synthesis_z1[band] = sz1;
        self.synthesis_z2[band] = sz2;
        self.envelopes[band] = env;
    }

    /// Clear all filter and envelope state.
    pub fn reset(self: *Self) void {
        self.analysis_z1 = .{0.0} ** MAX_BANDS;
        self.analysis_z2 = .{0.0} ** MAX_BANDS;
        self.synthesis_z1 = .{0.0} ** MAX_BANDS;
        self.synthesis_z2 = .{0.0} ** MAX_BANDS;
        self.envelopes = .{0.0} ** MAX_BANDS;
    }

    // -- Internal helpers --

    fn compute_band_coeffs(self: *Self, num_bands: u32, resonance: f32, sample_rate: f32) void {
        for (0..num_bands) |i| {
            const freq = band_frequency(i, num_bands);
            self.coeffs[i] = filter.make_coeffs(freq, resonance, sample_rate);
        }
    }
};

/// Log-spaced band frequency: 100Hz..10kHz.
fn band_frequency(index: usize, num_bands: u32) f32 {
    if (num_bands <= 1) return 1000.0;
    const t: f32 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(num_bands - 1));
    return 100.0 * std.math.pow(f32, 100.0, t);
}

/// 1-pole exponential smoothing coefficient from time constant in seconds.
fn compute_coeff(time_s: f32, sample_rate: f32) f32 {
    return @exp(-1.0 / (time_s * sample_rate));
}

// -- Tests ----------------------------------------------------------------

test "AC-1: Carrier=Saw + Modulator=Silence -> output < 0.001" {
    var voc = Vocoder.init(44100.0);

    var max_abs: f32 = 0.0;
    var phase: f32 = 0.0;
    for (0..1024) |_| {
        // Carrier: naive saw, Modulator: silence
        const carrier = 2.0 * phase - 1.0;
        const out = voc.process_sample(carrier, 0.0);
        if (@abs(out) > max_abs) max_abs = @abs(out);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    try std.testing.expect(max_abs < 0.001);
}

test "AC-2: Carrier=Saw + Modulator=WhiteNoise -> RMS > 0.01" {
    var voc = Vocoder.init(44100.0);

    var sum_sq: f64 = 0.0;
    var phase: f32 = 0.0;
    // Simple PRNG for white noise
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    for (0..1024) |_| {
        const carrier = 2.0 * phase - 1.0;
        const noise = random.float(f32) * 2.0 - 1.0;
        const out = voc.process_sample(carrier, noise);
        sum_sq += @as(f64, out) * @as(f64, out);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    const rms: f64 = @sqrt(sum_sq / 1024.0);
    try std.testing.expect(rms > 0.01);
}

test "AC-N1: no NaN/Inf after 44100 samples" {
    var voc = Vocoder.init(44100.0);
    var rng = std.Random.DefaultPrng.init(123);
    const random = rng.random();

    var phase: f32 = 0.0;
    for (0..44100) |_| {
        const carrier = 2.0 * phase - 1.0;
        const noise = random.float(f32) * 2.0 - 1.0;
        const out = voc.process_sample(carrier, noise);
        try std.testing.expect(!std.math.isNan(out));
        try std.testing.expect(!std.math.isInf(out));
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "process_block produces correct output" {
    // Band-at-a-time block processing produces equivalent results to
    // sample-at-a-time, but float accumulation order differs slightly.
    var voc1 = Vocoder.init(44100.0);
    var voc2 = Vocoder.init(44100.0);

    var carrier_buf: [BLOCK_SIZE]f32 = undefined;
    var mod_buf: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    var rng = std.Random.DefaultPrng.init(99);
    const random = rng.random();

    for (&carrier_buf, &mod_buf) |*c, *m| {
        c.* = 2.0 * phase - 1.0;
        m.* = random.float(f32) * 2.0 - 1.0;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var block_out: [BLOCK_SIZE]f32 = undefined;
    voc1.process_block(&block_out, &carrier_buf, &mod_buf);

    var sample_out: [BLOCK_SIZE]f32 = undefined;
    for (&sample_out, carrier_buf, mod_buf) |*o, c, m| {
        o.* = voc2.process_sample(c, m);
    }

    // Both paths should produce very similar output
    for (block_out, sample_out) |b, s| {
        try std.testing.expectApproxEqAbs(b, s, 0.001);
    }

    // Verify envelopes converged to same values
    for (voc1.envelopes, voc2.envelopes) |e1, e2| {
        try std.testing.expectApproxEqAbs(e1, e2, 0.0001);
    }
}

test "talk_box mode produces output" {
    var voc = Vocoder.init(44100.0);
    voc.set_mode(.talk_box, 44100.0);

    var max_abs: f32 = 0.0;
    var phase: f32 = 0.0;
    var rng = std.Random.DefaultPrng.init(77);
    const random = rng.random();

    for (0..1024) |_| {
        const carrier = 2.0 * phase - 1.0;
        const noise = random.float(f32) * 2.0 - 1.0;
        const out = voc.process_sample(carrier, noise);
        if (@abs(out) > max_abs) max_abs = @abs(out);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    try std.testing.expect(max_abs > 0.001);
}

test "reset clears envelopes" {
    var voc = Vocoder.init(44100.0);
    var rng = std.Random.DefaultPrng.init(55);
    const random = rng.random();

    var phase: f32 = 0.0;
    for (0..512) |_| {
        const carrier = 2.0 * phase - 1.0;
        const noise = random.float(f32) * 2.0 - 1.0;
        _ = voc.process_sample(carrier, noise);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    // Envelopes should be non-zero
    var has_energy = false;
    for (voc.envelopes) |e| {
        if (e > 0.0) has_energy = true;
    }
    try std.testing.expect(has_energy);

    voc.reset();
    for (voc.envelopes) |e| {
        try std.testing.expectEqual(@as(f32, 0.0), e);
    }
}

test "vocoder vs talk_box differ" {
    var voc_v = Vocoder.init(44100.0);
    var voc_t = Vocoder.init(44100.0);
    voc_t.set_mode(.talk_box, 44100.0);

    var rng_v = std.Random.DefaultPrng.init(42);
    var rng_t = std.Random.DefaultPrng.init(42);
    const rand_v = rng_v.random();
    const rand_t = rng_t.random();

    var diff_count: u32 = 0;
    var phase: f32 = 0.0;
    for (0..512) |_| {
        const carrier = 2.0 * phase - 1.0;
        const noise_v = rand_v.float(f32) * 2.0 - 1.0;
        const noise_t = rand_t.float(f32) * 2.0 - 1.0;
        const out_v = voc_v.process_sample(carrier, noise_v);
        const out_t = voc_t.process_sample(carrier, noise_t);
        if (@abs(out_v - out_t) > 0.001) diff_count += 1;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    try std.testing.expect(diff_count > 100);
}

test "band_frequency log spacing" {
    const f0 = band_frequency(0, 16);
    const f15 = band_frequency(15, 16);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), f0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10000.0), f15, 1.0);

    // Monotonically increasing
    var prev: f32 = 0.0;
    for (0..16) |i| {
        const f = band_frequency(i, 16);
        try std.testing.expect(f > prev);
        prev = f;
    }
}

// -- Benchmarks -----------------------------------------------------------

test "benchmark: vocoder 16 bands process_block" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var voc = Vocoder.init(44100.0);

    var carrier_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var mod_buf = [_]f32{0.2} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| voc.process_block(&out_buf, &carrier_buf, &mod_buf);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        voc.process_block(&out_buf, &carrier_buf, &mod_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    // 16 bands × 2 SVFs × 128 samples = 4096 f64 SVF calls.
    // ZDF SVF with f64 feedback prevents SIMD vectorization.
    const budget: u64 = if (strict) 55_000 else 500_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-048] Vocoder 16-band: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: band analysis 16x BP + envelope" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var voc = Vocoder.init(44100.0);

    // Only modulator processing (carrier = 0)
    var mod_buf = [_]f32{0.2} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;
    var carrier_buf = [_]f32{0.0} ** BLOCK_SIZE;

    for (0..1000) |_| voc.process_block(&out_buf, &carrier_buf, &mod_buf);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        voc.process_block(&out_buf, &carrier_buf, &mod_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    // Carrier=0 doesn't skip SVFs, so cost matches full vocoder.
    const budget: u64 = if (strict) 55_000 else 300_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-048] Band analysis: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: talk_box 8 bands" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var voc = Vocoder.init(44100.0);
    voc.set_mode(.talk_box, 44100.0);

    var carrier_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var mod_buf = [_]f32{0.2} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| voc.process_block(&out_buf, &carrier_buf, &mod_buf);

    const iterations: u64 = if (strict) 500_000 else 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        voc.process_block(&out_buf, &carrier_buf, &mod_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 12_000 else 250_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-048] Talk-Box 8-band: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: scaling 8/16 bands" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var voc = Vocoder.init(44100.0);

    var carrier_buf = [_]f32{0.3} ** BLOCK_SIZE;
    var mod_buf = [_]f32{0.2} ** BLOCK_SIZE;
    var out_buf: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| voc.process_block(&out_buf, &carrier_buf, &mod_buf);

    const iterations: u64 = if (strict) 500_000 else 10_000;

    // Measure 16 bands
    voc.set_mode(.vocoder, 44100.0);
    var timer_16 = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        voc.process_block(&out_buf, &carrier_buf, &mod_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns_16 = timer_16.read() / iterations;

    // Measure 8 bands
    voc.set_mode(.talk_box, 44100.0);
    for (0..1000) |_| voc.process_block(&out_buf, &carrier_buf, &mod_buf);
    var timer_8 = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        voc.process_block(&out_buf, &carrier_buf, &mod_buf);
        std.mem.doNotOptimizeAway(&out_buf);
    }
    const ns_8 = timer_8.read() / iterations;

    // 16 bands should scale roughly linearly from 8 bands.
    // Superlinear scaling is expected due to cache/branch effects.
    const ratio: f64 = @as(f64, @floatFromInt(ns_16)) / @as(f64, @floatFromInt(@max(ns_8, 1)));
    const pass = ratio > 1.3 and ratio < 8.0;
    std.debug.print("\n[WP-048] Scaling: 8-band={}ns, 16-band={}ns, ratio={d:.2} {s}\n", .{ ns_8, ns_16, ratio, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
