const std = @import("std");
const builtin = @import("builtin");

// -- Spectral Engine FFT (WP-057) ---------------------------------------------
// Allocation-free spectral processor with in-place radix-2 FFT/IFFT.
// Includes Freeze / Blur / Shift operators on magnitude+phase bins.

pub const FFT_SIZE: usize = 2048;
pub const HALF_SIZE: usize = FFT_SIZE / 2;
pub const BLOCK_SIZE: usize = 128;
pub const DEFAULT_SAMPLE_RATE: f32 = 44_100.0;

const FFT_1024: usize = 1024;
const FFT_4096: usize = 4096;

fn isPowerOfTwo(comptime n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

fn bitReverseIndex(value: usize, bits: usize) usize {
    var src = value;
    var reversed: usize = 0;
    for (0..bits) |_| {
        reversed = (reversed << 1) | (src & 1);
        src >>= 1;
    }
    return reversed;
}

fn fillBitReverseTable(comptime N: usize, table: *[N]u16) void {
    comptime {
        if (!isPowerOfTwo(N)) {
            @compileError("FFT size must be a power of 2");
        }
        if (N > std.math.maxInt(u16)) {
            @compileError("bit-reverse table type too small");
        }
    }

    const bits: usize = @ctz(@as(usize, N));
    for (0..N) |i| {
        table[i] = @intCast(bitReverseIndex(i, bits));
    }
}

fn fillTwiddleTables(comptime N: usize, re: *[N / 2]f32, im: *[N / 2]f32) void {
    comptime {
        if (!isPowerOfTwo(N)) {
            @compileError("FFT size must be a power of 2");
        }
    }

    for (0..N / 2) |k| {
        const angle = (2.0 * std.math.pi * @as(f64, @floatFromInt(k))) / @as(f64, @floatFromInt(N));
        re[k] = @floatCast(@cos(angle));
        im[k] = @floatCast(-@sin(angle)); // Forward FFT twiddle: e^(-j*angle)
    }
}

fn fillHannWindow(comptime N: usize, win: *[N]f32) void {
    for (0..N) |i| {
        const phase = (2.0 * std.math.pi * @as(f64, @floatFromInt(i))) / @as(f64, @floatFromInt(N - 1));
        win[i] = @floatCast(0.5 - 0.5 * @cos(phase));
    }
}

fn fftInPlace(
    comptime N: usize,
    re: *[N]f32,
    im: *[N]f32,
    bitrev: *const [N]u16,
    tw_re: *const [N / 2]f32,
    tw_im: *const [N / 2]f32,
    inverse: bool,
) void {
    // Bit-reversal permutation.
    for (0..N) |i| {
        const j: usize = bitrev[i];
        if (j > i) {
            const tmp_re = re[i];
            const tmp_im = im[i];
            re[i] = re[j];
            im[i] = im[j];
            re[j] = tmp_re;
            im[j] = tmp_im;
        }
    }

    // Radix-2 decimation-in-time butterfly stages.
    var len: usize = 2;
    while (len <= N) : (len <<= 1) {
        const half = len >> 1;
        const tw_stride = N / len;
        var base: usize = 0;
        while (base < N) : (base += len) {
            for (0..half) |j| {
                const tw_idx = j * tw_stride;
                const wr = tw_re[tw_idx];
                const wi = if (inverse) -tw_im[tw_idx] else tw_im[tw_idx];

                const even = base + j;
                const odd = even + half;

                const odd_re = re[odd];
                const odd_im = im[odd];
                const tr = wr * odd_re - wi * odd_im;
                const ti = wr * odd_im + wi * odd_re;

                const even_re = re[even];
                const even_im = im[even];
                re[odd] = even_re - tr;
                im[odd] = even_im - ti;
                re[even] = even_re + tr;
                im[even] = even_im + ti;
            }
        }
    }

    if (inverse) {
        const inv_n = 1.0 / @as(f32, @floatFromInt(N));
        for (0..N) |i| {
            re[i] *= inv_n;
            im[i] *= inv_n;
        }
    }
}

fn sanitizeSampleRate(sample_rate: f32) f32 {
    if (!std.math.isFinite(sample_rate) or sample_rate < 1_000.0) {
        return DEFAULT_SAMPLE_RATE;
    }
    return sample_rate;
}

fn clamp01(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return std.math.clamp(v, 0.0, 1.0);
}

pub const SpectralEngine = struct {
    const Self = @This();

    sample_rate: f32,
    bitrev: [FFT_SIZE]u16,
    twiddle_re: [HALF_SIZE]f32,
    twiddle_im: [HALF_SIZE]f32,
    fft_buffer_re: [FFT_SIZE]f32,
    fft_buffer_im: [FFT_SIZE]f32,
    magnitude: [HALF_SIZE]f32,
    phase: [HALF_SIZE]f32,
    frozen_magnitude: [HALF_SIZE]f32,
    frozen_phase: [HALF_SIZE]f32,
    frozen: bool,

    pub fn init(sample_rate: f32) Self {
        var self = Self{
            .sample_rate = sanitizeSampleRate(sample_rate),
            .bitrev = undefined,
            .twiddle_re = undefined,
            .twiddle_im = undefined,
            .fft_buffer_re = .{0.0} ** FFT_SIZE,
            .fft_buffer_im = .{0.0} ** FFT_SIZE,
            .magnitude = .{0.0} ** HALF_SIZE,
            .phase = .{0.0} ** HALF_SIZE,
            .frozen_magnitude = .{0.0} ** HALF_SIZE,
            .frozen_phase = .{0.0} ** HALF_SIZE,
            .frozen = false,
        };

        fillBitReverseTable(FFT_SIZE, &self.bitrev);
        fillTwiddleTables(FFT_SIZE, &self.twiddle_re, &self.twiddle_im);
        return self;
    }

    pub fn reset(self: *Self) void {
        self.fft_buffer_re = .{0.0} ** FFT_SIZE;
        self.fft_buffer_im = .{0.0} ** FFT_SIZE;
        self.magnitude = .{0.0} ** HALF_SIZE;
        self.phase = .{0.0} ** HALF_SIZE;
        self.frozen_magnitude = .{0.0} ** HALF_SIZE;
        self.frozen_phase = .{0.0} ** HALF_SIZE;
        self.frozen = false;
    }

    pub fn fft(self: *Self, input: *const [FFT_SIZE]f32) void {
        for (0..FFT_SIZE) |i| {
            self.fft_buffer_re[i] = input[i];
            self.fft_buffer_im[i] = 0.0;
        }

        fftInPlace(
            FFT_SIZE,
            &self.fft_buffer_re,
            &self.fft_buffer_im,
            &self.bitrev,
            &self.twiddle_re,
            &self.twiddle_im,
            false,
        );
        self.capturePolarFromComplex();
    }

    pub fn ifft(self: *Self, output: *[FFT_SIZE]f32) void {
        fftInPlace(
            FFT_SIZE,
            &self.fft_buffer_re,
            &self.fft_buffer_im,
            &self.bitrev,
            &self.twiddle_re,
            &self.twiddle_im,
            true,
        );
        for (0..FFT_SIZE) |i| {
            output[i] = self.fft_buffer_re[i];
        }
    }

    fn capturePolarFromComplex(self: *Self) void {
        for (0..HALF_SIZE) |k| {
            const real = self.fft_buffer_re[k];
            const imag = self.fft_buffer_im[k];
            self.magnitude[k] = @sqrt(real * real + imag * imag);
            self.phase[k] = std.math.atan2(imag, real);
        }
    }

    fn rebuildComplexFromPolar(
        self: *Self,
        mag: *const [HALF_SIZE]f32,
        ph: *const [HALF_SIZE]f32,
    ) void {
        @memset(self.fft_buffer_re[0..], 0.0);
        @memset(self.fft_buffer_im[0..], 0.0);

        // DC bin (real-only).
        self.fft_buffer_re[0] = mag[0] * @cos(ph[0]);
        self.fft_buffer_im[0] = 0.0;

        // Positive frequencies and mirrored negative frequencies.
        for (1..HALF_SIZE) |k| {
            const real = mag[k] * @cos(ph[k]);
            const imag = mag[k] * @sin(ph[k]);
            self.fft_buffer_re[k] = real;
            self.fft_buffer_im[k] = imag;

            const mirror = FFT_SIZE - k;
            self.fft_buffer_re[mirror] = real;
            self.fft_buffer_im[mirror] = -imag;
        }

        // Nyquist (real-only) is not tracked in HALF_SIZE arrays.
        self.fft_buffer_re[HALF_SIZE] = 0.0;
        self.fft_buffer_im[HALF_SIZE] = 0.0;
    }

    pub fn freeze(self: *Self) void {
        self.frozen = true;
        self.frozen_magnitude = self.magnitude;
        self.frozen_phase = self.phase;
    }

    pub fn unfreeze(self: *Self) void {
        self.frozen = false;
    }

    pub fn blur(self: *Self, amount: f32) void {
        const clamped = clamp01(amount);
        const radius: usize = @intFromFloat(@round(clamped * 16.0));
        if (radius == 0) return;

        var blurred = self.magnitude;
        for (0..HALF_SIZE) |k| {
            const start = if (k > radius) k - radius else 0;
            const stop = @min(HALF_SIZE - 1, k + radius);
            var sum: f32 = 0.0;
            var count: usize = 0;
            var idx = start;
            while (idx <= stop) : (idx += 1) {
                sum += self.magnitude[idx];
                count += 1;
            }
            blurred[k] = sum / @as(f32, @floatFromInt(count));
        }

        self.magnitude = blurred;
        if (self.frozen) self.frozen_magnitude = self.magnitude;
    }

    pub fn shift(self: *Self, semitones: f32) void {
        if (!std.math.isFinite(semitones)) return;
        const ratio = std.math.pow(f32, 2.0, semitones / 12.0);
        if (!std.math.isFinite(ratio) or ratio <= 0.0) return;

        var shifted_mag: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;
        var shifted_phase: [HALF_SIZE]f32 = .{0.0} ** HALF_SIZE;

        shifted_mag[0] = self.magnitude[0];
        shifted_phase[0] = self.phase[0];

        for (1..HALF_SIZE) |k| {
            const dst_f = @as(f32, @floatFromInt(k)) * ratio;
            const dst_i: i32 = @intFromFloat(@round(dst_f));
            if (dst_i <= 0 or dst_i >= HALF_SIZE) continue;

            const dst: usize = @intCast(dst_i);
            if (self.magnitude[k] > shifted_mag[dst]) {
                shifted_mag[dst] = self.magnitude[k];
                shifted_phase[dst] = self.phase[k];
            }
        }

        self.magnitude = shifted_mag;
        self.phase = shifted_phase;
        if (self.frozen) {
            self.frozen_magnitude = self.magnitude;
            self.frozen_phase = self.phase;
        }
    }

    pub fn process_block(self: *Self, input: *const [FFT_SIZE]f32, output: *[FFT_SIZE]f32) void {
        if (self.frozen) {
            self.rebuildComplexFromPolar(&self.frozen_magnitude, &self.frozen_phase);
        } else {
            self.fft(input);
            self.rebuildComplexFromPolar(&self.magnitude, &self.phase);
        }
        self.ifft(output);
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

fn genSine(comptime N: usize, freq: f32, sample_rate: f32) [N]f32 {
    var out: [N]f32 = undefined;
    var phase: f32 = 0.0;
    for (0..N) |i| {
        out[i] = @sin(2.0 * std.math.pi * phase);
        phase += freq / sample_rate;
        if (phase >= 1.0) phase -= 1.0;
    }
    return out;
}

fn benchForwardFftNs(comptime N: usize, iterations: u64) u64 {
    const input = genSine(N, 440.0, 44_100.0);
    var bitrev: [N]u16 = undefined;
    var tw_re: [N / 2]f32 = undefined;
    var tw_im: [N / 2]f32 = undefined;
    var re = input;
    var im: [N]f32 = .{0.0} ** N;

    fillBitReverseTable(N, &bitrev);
    fillTwiddleTables(N, &tw_re, &tw_im);

    for (0..128) |_| {
        fftInPlace(N, &re, &im, &bitrev, &tw_re, &tw_im, false);
    }

    const inv_n = 1.0 / @as(f32, @floatFromInt(N));
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |i| {
        fftInPlace(N, &re, &im, &bitrev, &tw_re, &tw_im, false);
        if ((i & 63) == 63) {
            for (0..N) |idx| {
                re[idx] *= inv_n;
                im[idx] *= inv_n;
            }
        }
        std.mem.doNotOptimizeAway(&re);
        std.mem.doNotOptimizeAway(&im);
    }

    return timer.read() / iterations;
}

fn overlapAdd1024Step(
    frame: *[FFT_1024]f32,
    overlap: *[FFT_1024]f32,
    phase: *f32,
    hann: *const [FFT_1024]f32,
    bitrev: *const [FFT_1024]u16,
    tw_re: *const [FFT_1024 / 2]f32,
    tw_im: *const [FFT_1024 / 2]f32,
) [BLOCK_SIZE]f32 {
    var block: [BLOCK_SIZE]f32 = undefined;
    for (&block) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase.*) * 0.5;
        phase.* += 220.0 / 44_100.0;
        if (phase.* >= 1.0) phase.* -= 1.0;
    }

    std.mem.copyForwards(f32, frame[0 .. FFT_1024 - BLOCK_SIZE], frame[BLOCK_SIZE..FFT_1024]);
    @memcpy(frame[FFT_1024 - BLOCK_SIZE .. FFT_1024], block[0..]);

    var re: [FFT_1024]f32 = undefined;
    var im: [FFT_1024]f32 = .{0.0} ** FFT_1024;
    for (0..FFT_1024) |i| {
        re[i] = frame[i] * hann[i];
    }

    fftInPlace(FFT_1024, &re, &im, bitrev, tw_re, tw_im, false);

    // Minimal spectral operation (freeze-like pass-through: keep bins as-is).
    fftInPlace(FFT_1024, &re, &im, bitrev, tw_re, tw_im, true);

    for (0..FFT_1024) |i| {
        overlap[i] += re[i] * hann[i];
    }

    var out: [BLOCK_SIZE]f32 = undefined;
    @memcpy(out[0..], overlap[0..BLOCK_SIZE]);
    std.mem.copyForwards(f32, overlap[0 .. FFT_1024 - BLOCK_SIZE], overlap[BLOCK_SIZE..FFT_1024]);
    @memset(overlap[FFT_1024 - BLOCK_SIZE .. FFT_1024], 0.0);
    return out;
}

fn benchOverlapAddNs(iterations: u64) u64 {
    var frame: [FFT_1024]f32 = .{0.0} ** FFT_1024;
    var overlap: [FFT_1024]f32 = .{0.0} ** FFT_1024;
    var hann: [FFT_1024]f32 = undefined;
    var bitrev: [FFT_1024]u16 = undefined;
    var tw_re: [FFT_1024 / 2]f32 = undefined;
    var tw_im: [FFT_1024 / 2]f32 = undefined;
    var phase: f32 = 0.0;

    fillHannWindow(FFT_1024, &hann);
    fillBitReverseTable(FFT_1024, &bitrev);
    fillTwiddleTables(FFT_1024, &tw_re, &tw_im);

    for (0..64) |_| {
        _ = overlapAdd1024Step(&frame, &overlap, &phase, &hann, &bitrev, &tw_re, &tw_im);
    }

    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        var out = overlapAdd1024Step(&frame, &overlap, &phase, &hann, &bitrev, &tw_re, &tw_im);
        std.mem.doNotOptimizeAway(&out);
    }
    return timer.read() / iterations;
}

fn benchSpectralFreezeNs(iterations: u64) u64 {
    var engine = SpectralEngine.init(44_100.0);
    const base = genSine(FFT_SIZE, 440.0, 44_100.0);
    var output: [FFT_SIZE]f32 = undefined;

    engine.process_block(&base, &output);
    engine.freeze();

    var input = genSine(FFT_SIZE, 880.0, 44_100.0);
    for (0..64) |_| {
        engine.process_block(&input, &output);
    }

    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        engine.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }

    return timer.read() / iterations;
}

// -- Tests --------------------------------------------------------------------

test "AC-1: 440Hz sine peak appears near expected FFT bin" {
    var engine = SpectralEngine.init(44_100.0);
    const input = genSine(FFT_SIZE, 440.0, 44_100.0);
    engine.fft(&input);

    var max_bin: usize = 0;
    var max_mag: f32 = 0.0;
    for (0..HALF_SIZE) |k| {
        if (engine.magnitude[k] > max_mag) {
            max_mag = engine.magnitude[k];
            max_bin = k;
        }
    }

    const expected_bin = @as(f32, 440.0 * @as(f32, @floatFromInt(FFT_SIZE)) / 44_100.0);
    const expected_rounded: i32 = @intFromFloat(@round(expected_bin));
    const observed: i32 = @intCast(max_bin);
    const diff = @abs(observed - expected_rounded);

    std.debug.print("\n[AC-1] expected_bin~{d:.2}, observed_bin={}, diff={}\n", .{
        expected_bin,
        max_bin,
        diff,
    });

    try std.testing.expect(diff <= 1);
}

test "AC-2: freeze keeps spectral output constant across different inputs" {
    var engine = SpectralEngine.init(44_100.0);

    const input_a = genSine(FFT_SIZE, 330.0, 44_100.0);
    const input_b = genSine(FFT_SIZE, 987.0, 44_100.0);
    var input_c = genSine(FFT_SIZE, 1234.0, 44_100.0);
    for (0..FFT_SIZE) |i| {
        input_c[i] += 0.15 * @sin(0.07 * @as(f32, @floatFromInt(i)));
    }

    var out_a: [FFT_SIZE]f32 = undefined;
    var out_b: [FFT_SIZE]f32 = undefined;
    var out_c: [FFT_SIZE]f32 = undefined;

    engine.process_block(&input_a, &out_a);
    engine.freeze();
    engine.process_block(&input_b, &out_b);
    engine.process_block(&input_c, &out_c);

    var max_diff: f32 = 0.0;
    for (0..FFT_SIZE) |i| {
        const d = @abs(out_b[i] - out_c[i]);
        if (d > max_diff) max_diff = d;
    }

    std.debug.print("\n[AC-2] freeze max abs diff between frozen blocks: {d:.8}\n", .{max_diff});
    try std.testing.expect(max_diff < 1e-5);
}

test "AC-N1: FFT->IFFT roundtrip error is below 1e-5" {
    var engine = SpectralEngine.init(48_000.0);

    var input: [FFT_SIZE]f32 = undefined;
    for (0..FFT_SIZE) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48_000.0;
        input[i] = 0.55 * @sin(std.math.tau * 220.0 * t) +
            0.27 * @sin(std.math.tau * 659.255 * t) +
            0.13 * @sin(std.math.tau * 1760.0 * t);
    }

    var output: [FFT_SIZE]f32 = undefined;
    engine.fft(&input);
    engine.ifft(&output);

    var max_err: f32 = 0.0;
    for (0..FFT_SIZE) |i| {
        const err = @abs(output[i] - input[i]);
        if (err > max_err) max_err = err;
    }

    std.debug.print("\n[AC-N1] roundtrip max_err={d:.8}\n", .{max_err});
    try std.testing.expect(max_err < 1e-5);
}

test "blur smooths neighboring magnitudes and shift moves peaks up" {
    var engine = SpectralEngine.init(44_100.0);
    const input = genSine(FFT_SIZE, 220.0, 44_100.0);
    engine.fft(&input);

    const before = engine.magnitude[10];
    engine.blur(0.5);
    const after = engine.magnitude[10];
    try std.testing.expect(after != before);

    var peak_before: usize = 0;
    var peak_mag_before: f32 = 0.0;
    for (0..HALF_SIZE) |k| {
        if (engine.magnitude[k] > peak_mag_before) {
            peak_mag_before = engine.magnitude[k];
            peak_before = k;
        }
    }

    engine.shift(12.0);

    var peak_after: usize = 0;
    var peak_mag_after: f32 = 0.0;
    for (0..HALF_SIZE) |k| {
        if (engine.magnitude[k] > peak_mag_after) {
            peak_mag_after = engine.magnitude[k];
            peak_after = k;
        }
    }

    try std.testing.expect(peak_after > peak_before);
}

test "benchmark: FFT 1024 forward under threshold" {
    const iters = benchIterations(2_000, 8_000, 40_000);
    const ns = benchForwardFftNs(FFT_1024, iters);
    const budget = benchBudgetNs(
        120_000, // debug
        25_000, // release-safe
        10_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-057] fft1024: {}ns (budget: {}ns, mode={s})\n", .{
        ns,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns < budget);
}

test "benchmark: FFT 2048 forward under threshold" {
    const iters = benchIterations(1_200, 5_000, 25_000);
    const ns = benchForwardFftNs(FFT_SIZE, iters);
    const budget = benchBudgetNs(
        240_000, // debug
        50_000, // release-safe
        22_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-057] fft2048: {}ns (budget: {}ns, mode={s})\n", .{
        ns,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns < budget);
}

test "benchmark: FFT 4096 forward under threshold" {
    const iters = benchIterations(600, 2_500, 12_000);
    const ns = benchForwardFftNs(FFT_4096, iters);
    const budget = benchBudgetNs(
        500_000, // debug
        95_000, // release-safe
        50_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-057] fft4096: {}ns (budget: {}ns, mode={s})\n", .{
        ns,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns < budget);
}

test "benchmark: overlap-add pipeline 128->1024 under threshold" {
    const iters = benchIterations(900, 4_000, 20_000);
    const ns = benchOverlapAddNs(iters);
    const budget = benchBudgetNs(
        500_000, // debug
        60_000, // release-safe
        30_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-057] overlap-add 128->1024: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns < budget);
}

test "AC-B1 benchmark: spectral freeze under threshold" {
    const iters = benchIterations(700, 3_000, 14_000);
    const ns = benchSpectralFreezeNs(iters);
    const budget = benchBudgetNs(
        1_300_000, // debug
        140_000, // release-safe
        40_000, // release-fast/small (issue threshold)
    );

    std.debug.print("\n[WP-057] spectral freeze: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns < budget);
}
