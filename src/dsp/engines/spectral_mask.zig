const std = @import("std");
const builtin = @import("builtin");
const spectral = @import("spectral.zig");

// -- Spectral Resynthesis + Masking (WP-058) ---------------------------------
// Allocation-free spectral masking on top of the FFT engine.
// Workflow:
// 1) Analyze source frame -> magnitude/phase
// 2) Apply spectral mask thresholding on magnitudes
// 3) Resynthesize via iFFT + overlap-add (128-sample hop)

pub const FFT_SIZE: usize = spectral.FFT_SIZE;
pub const HALF_SIZE: usize = spectral.HALF_SIZE;
pub const BLOCK_SIZE: usize = spectral.BLOCK_SIZE;
pub const DEFAULT_SAMPLE_RATE: f32 = spectral.DEFAULT_SAMPLE_RATE;

fn clampThreshold(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return @max(0.0, v);
}

fn makeHannWindow() [FFT_SIZE]f32 {
    var win: [FFT_SIZE]f32 = undefined;
    for (0..FFT_SIZE) |i| {
        const phase = (2.0 * std.math.pi * @as(f64, @floatFromInt(i))) / @as(f64, @floatFromInt(FFT_SIZE - 1));
        win[i] = @floatCast(0.5 - 0.5 * @cos(phase));
    }
    return win;
}

pub const SpectralMask = struct {
    const Self = @This();

    engine: spectral.SpectralEngine,
    mask_magnitude: [HALF_SIZE]f32,
    threshold: f32,
    overlap: [FFT_SIZE]f32,
    window: [FFT_SIZE]f32,
    synthesis: [FFT_SIZE]f32,

    pub fn init(sample_rate: f32) Self {
        return .{
            .engine = spectral.SpectralEngine.init(sample_rate),
            .mask_magnitude = .{0.0} ** HALF_SIZE,
            .threshold = 0.0,
            .overlap = .{0.0} ** FFT_SIZE,
            .window = makeHannWindow(),
            .synthesis = .{0.0} ** FFT_SIZE,
        };
    }

    pub fn reset(self: *Self) void {
        self.engine.reset();
        self.mask_magnitude = .{0.0} ** HALF_SIZE;
        self.threshold = 0.0;
        self.overlap = .{0.0} ** FFT_SIZE;
        self.synthesis = .{0.0} ** FFT_SIZE;
    }

    pub fn set_threshold(self: *Self, threshold: f32) void {
        self.threshold = clampThreshold(threshold);
    }

    pub fn set_mask_magnitude(self: *Self, mask_magnitude: *const [HALF_SIZE]f32) void {
        self.mask_magnitude = mask_magnitude.*;
    }

    pub fn analyze(self: *Self, input: *const [FFT_SIZE]f32, out_magnitude: *[HALF_SIZE]f32, out_phase: *[HALF_SIZE]f32) void {
        self.engine.fft(input);
        out_magnitude.* = self.engine.magnitude;
        out_phase.* = self.engine.phase;
    }

    pub fn build_mask_from_frame(self: *Self, mask_frame: *const [FFT_SIZE]f32) void {
        var mask_phase: [HALF_SIZE]f32 = undefined;
        self.analyze(mask_frame, &self.mask_magnitude, &mask_phase);
    }

    pub fn apply_mask(
        source_mag: *const [HALF_SIZE]f32,
        mask_mag: *const [HALF_SIZE]f32,
        threshold: f32,
        out_mag: *[HALF_SIZE]f32,
    ) void {
        const t = clampThreshold(threshold);
        for (0..HALF_SIZE) |i| {
            out_mag[i] = if (mask_mag[i] > t) 0.0 else source_mag[i];
        }
    }

    pub fn resynthese(self: *Self, magnitudes: *const [HALF_SIZE]f32, phases: *const [HALF_SIZE]f32, out: *[FFT_SIZE]f32) void {
        self.engine.frozen_magnitude = magnitudes.*;
        self.engine.frozen_phase = phases.*;
        self.engine.frozen = true;

        const zero_frame: [FFT_SIZE]f32 = .{0.0} ** FFT_SIZE;
        self.engine.process_block(&zero_frame, out);
        self.engine.frozen = false;
    }

    pub fn resynthese_process_block(
        self: *Self,
        magnitudes: *const [HALF_SIZE]f32,
        phases: *const [HALF_SIZE]f32,
        out_block: *[BLOCK_SIZE]f32,
    ) void {
        self.resynthese(magnitudes, phases, &self.synthesis);

        for (0..FFT_SIZE) |i| {
            self.overlap[i] += self.synthesis[i] * self.window[i];
        }

        @memcpy(out_block[0..], self.overlap[0..BLOCK_SIZE]);
        std.mem.copyForwards(f32, self.overlap[0 .. FFT_SIZE - BLOCK_SIZE], self.overlap[BLOCK_SIZE..FFT_SIZE]);
        @memset(self.overlap[FFT_SIZE - BLOCK_SIZE .. FFT_SIZE], 0.0);
    }

    pub fn process_pipeline(self: *Self, source_frame: *const [FFT_SIZE]f32, out_block: *[BLOCK_SIZE]f32) void {
        var source_mag: [HALF_SIZE]f32 = undefined;
        var source_phase: [HALF_SIZE]f32 = undefined;
        var masked_mag: [HALF_SIZE]f32 = undefined;

        self.analyze(source_frame, &source_mag, &source_phase);
        apply_mask(&source_mag, &self.mask_magnitude, self.threshold, &masked_mag);
        self.resynthese_process_block(&masked_mag, &source_phase, out_block);
    }
};

fn benchIterations(debug_iters: u64, safe_iters: u64, release_iters: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_iters,
        .ReleaseSafe => safe_iters,
        .ReleaseFast, .ReleaseSmall => release_iters,
    };
}

fn benchBudgetNs(debug_budget: u64, safe_budget: u64, release_budget: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_budget,
        .ReleaseSafe => safe_budget,
        .ReleaseFast, .ReleaseSmall => release_budget,
    };
}

fn genSineFrame(freq: f32, sample_rate: f32) [FFT_SIZE]f32 {
    var out: [FFT_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (0..FFT_SIZE) |i| {
        out[i] = @sin(2.0 * std.math.pi * phase);
        phase += freq / sample_rate;
        if (phase >= 1.0) phase -= 1.0;
    }
    return out;
}

fn genDualSineFrame(freq_a: f32, freq_b: f32, sample_rate: f32) [FFT_SIZE]f32 {
    var out: [FFT_SIZE]f32 = undefined;
    var phase_a: f32 = 0.0;
    var phase_b: f32 = 0.0;
    for (0..FFT_SIZE) |i| {
        out[i] = 0.5 * @sin(2.0 * std.math.pi * phase_a) + 0.5 * @sin(2.0 * std.math.pi * phase_b);
        phase_a += freq_a / sample_rate;
        phase_b += freq_b / sample_rate;
        if (phase_a >= 1.0) phase_a -= 1.0;
        if (phase_b >= 1.0) phase_b -= 1.0;
    }
    return out;
}

fn goertzelMagnitude(buf: []const f32, target_freq: f32, sample_rate: f32) f32 {
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

fn benchmarkHarmonicsManipulationNs(iterations: u64) u64 {
    var mags: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    for (0..HALF_SIZE) |i| {
        mags[i] = @floatFromInt(i);
    }

    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |it| {
        const gain = 0.5 + 0.5 * @sin(0.001 * @as(f32, @floatFromInt(it)));
        for (0..512) |i| {
            const src = mags[i];
            const smoothed = (src * 0.75) + (if (i > 0) mags[i - 1] else src) * 0.15 + (if (i < 511) mags[i + 1] else src) * 0.10;
            mags[i] = smoothed * gain;
        }
        std.mem.doNotOptimizeAway(&mags);
    }

    return timer.read() / iterations;
}

// -- Tests --------------------------------------------------------------------

test "AC-1: source==mask zeros all bins and yields silence" {
    var sm = SpectralMask.init(44_100.0);
    var source_mag: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    var source_phase: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    var masked_mag: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    var out_block: [BLOCK_SIZE]f32 = undefined;

    for (0..HALF_SIZE) |i| {
        source_mag[i] = 1.0 + @as(f32, @floatFromInt(i)) * 1e-4;
        source_phase[i] = 0.0;
    }

    SpectralMask.apply_mask(&source_mag, &source_mag, 0.5, &masked_mag);

    for (masked_mag) |m| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), m, 1e-7);
    }

    sm.resynthese_process_block(&masked_mag, &source_phase, &out_block);
    for (out_block) |s| {
        try std.testing.expect(@abs(s) < 1e-5);
    }
}

test "AC-2: different mask keeps only non-masked frequencies" {
    const sample_rate: f32 = 44_100.0;
    var sm = SpectralMask.init(sample_rate);

    const source = genDualSineFrame(440.0, 880.0, sample_rate);
    const mask = genSineFrame(440.0, sample_rate);

    sm.build_mask_from_frame(&mask);
    sm.set_threshold(100.0);

    var source_mag: [HALF_SIZE]f32 = undefined;
    var source_phase: [HALF_SIZE]f32 = undefined;
    var masked_mag: [HALF_SIZE]f32 = undefined;
    var out_frame: [FFT_SIZE]f32 = undefined;

    sm.analyze(&source, &source_mag, &source_phase);
    SpectralMask.apply_mask(&source_mag, &sm.mask_magnitude, sm.threshold, &masked_mag);
    sm.resynthese(&masked_mag, &source_phase, &out_frame);

    const mag_440 = goertzelMagnitude(&out_frame, 440.0, sample_rate);
    const mag_880 = goertzelMagnitude(&out_frame, 880.0, sample_rate);

    std.debug.print("\n[AC-2] out 440Hz={d:.6}, 880Hz={d:.6}\n", .{ mag_440, mag_880 });
    try std.testing.expect(mag_880 > mag_440 * 2.0);
}

test "benchmark: resynthese_process_block from harmonic editor data" {
    var sm = SpectralMask.init(48_000.0);
    var magnitudes: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    var phases: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
    var out_block: [BLOCK_SIZE]f32 = undefined;

    for (0..HALF_SIZE) |i| {
        const harmonic = @as(f32, @floatFromInt(i + 1));
        magnitudes[i] = 1.0 / harmonic;
        phases[i] = 0.01 * @as(f32, @floatFromInt(i));
    }

    for (0..128) |_| {
        sm.resynthese_process_block(&magnitudes, &phases, &out_block);
    }

    const iterations = benchIterations(900, 4_000, 20_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        sm.resynthese_process_block(&magnitudes, &phases, &out_block);
        std.mem.doNotOptimizeAway(&out_block);
    }
    const ns_per_block = timer.read() / iterations;

    const budget = benchBudgetNs(
        3_000_000, // debug
        350_000, // release-safe
        35_000, // release-fast/small (issue threshold)
    );
    std.debug.print("\n[WP-058] resynthese_process_block: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget);
}

test "benchmark: harmonics manipulation 512 bins" {
    const iterations = benchIterations(15_000, 60_000, 250_000);
    const ns_per_block = benchmarkHarmonicsManipulationNs(iterations);
    const budget = benchBudgetNs(
        350_000, // debug
        50_000, // release-safe
        5_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-058] harmonics manipulation 512 bins: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget);
}

test "AC-B1 benchmark: full pipeline analyse + mask + resynthese" {
    var sm = SpectralMask.init(44_100.0);

    const source = genDualSineFrame(330.0, 990.0, 44_100.0);
    const mask = genSineFrame(330.0, 44_100.0);
    sm.build_mask_from_frame(&mask);
    sm.set_threshold(90.0);

    var out: [BLOCK_SIZE]f32 = undefined;
    for (0..64) |_| {
        sm.process_pipeline(&source, &out);
    }

    const iterations = benchIterations(650, 3_000, 15_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        sm.process_pipeline(&source, &out);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns_per_block = timer.read() / iterations;

    const budget = benchBudgetNs(
        4_500_000, // debug
        500_000, // release-safe
        50_000, // release-fast/small (issue threshold)
    );
    std.debug.print("\n[WP-058] full pipeline: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget);
}
