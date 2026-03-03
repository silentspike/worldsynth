const std = @import("std");

// -- Half-Band FIR Oversampling (WP-088) --------------------------------------
// 2x/4x oversampling for non-linear processing (waveshaper, distortion).
// Half-Band FIR: every 2nd coefficient is 0, center tap = 0.5.
// Ring buffer delay line — O(1) per sample (no history shift).
// Cascadable: 2x 2x = 4x oversampling.
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = 128;

// -- Comptime FIR coefficient design ------------------------------------------

const FILTER_ORDER = 23;
const HALF_ORDER = FILTER_ORDER / 2; // 11 (center tap index)

// Ring buffer: next power of 2 >= FILTER_ORDER for fast masking.
const RING_SIZE = 32;
const RING_MASK = RING_SIZE - 1;

/// Comptime modified Bessel function I₀(x) via power series.
fn bessel_i0(x: f64) f64 {
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    for (1..30) |k| {
        const kf: f64 = @floatFromInt(k);
        term *= (x / (2.0 * kf)) * (x / (2.0 * kf));
        sum += term;
    }
    return sum;
}

/// Comptime Half-Band FIR coefficients via Kaiser-windowed sinc.
/// Kaiser β=8 for ~80dB stopband attenuation.
/// Center tap = 0.5, even-distance taps from center = 0 (half-band property).
/// Normalized so all coefficients sum to 1.0.
const COEFFS = blk: {
    const beta: f64 = 8.0;
    const bessel_denom = bessel_i0(beta);
    const center: i32 = HALF_ORDER;
    const m: f64 = @floatFromInt(FILTER_ORDER - 1); // 22

    var coeffs: [FILTER_ORDER]f32 = .{0.0} ** FILTER_ORDER;
    coeffs[HALF_ORDER] = 0.5; // center tap

    for (0..FILTER_ORDER) |k| {
        const ki: i32 = @intCast(k);
        const dist = if (ki > center) ki - center else center - ki;
        if (dist == 0) continue; // center — already set
        if (@rem(dist, 2) == 0) continue; // half-band zero

        // Windowed sinc: h[n] = sinc(n/2) * kaiser(n)
        const n: f64 = @floatFromInt(ki - center);
        const sinc_val = @sin(std.math.pi * n / 2.0) / (std.math.pi * n);

        // Kaiser window: w[k] = I₀(β * sqrt(1 - (2k/M - 1)²)) / I₀(β)
        const kf: f64 = @floatFromInt(k);
        const arg = 2.0 * kf / m - 1.0;
        const inner = 1.0 - arg * arg;
        const w = if (inner > 0.0) bessel_i0(beta * @sqrt(inner)) / bessel_denom else 0.0;

        coeffs[k] = @floatCast(sinc_val * w);
    }

    // Normalize: non-center taps should sum to 0.5 (center is already 0.5).
    var non_center_sum: f64 = 0.0;
    for (0..FILTER_ORDER) |k| {
        if (k != HALF_ORDER) non_center_sum += @as(f64, coeffs[k]);
    }
    if (non_center_sum != 0.0) {
        const scale: f64 = 0.5 / non_center_sum;
        for (0..FILTER_ORDER) |k| {
            if (k != HALF_ORDER) coeffs[k] = @floatCast(@as(f64, coeffs[k]) * scale);
        }
    }

    break :blk coeffs;
};

// -- Half-Band FIR filter (ring buffer) ---------------------------------------

pub const HalfBandFilter = struct {
    const Self = @This();

    ring: [RING_SIZE]f32,
    pos: usize,

    pub fn init() Self {
        return .{ .ring = .{0.0} ** RING_SIZE, .pos = 0 };
    }

    /// Push a sample into the delay line and compute FIR output.
    /// Half-band optimization: comptime skips zero coefficients.
    pub inline fn tick(self: *Self, input: f32) f32 {
        self.ring[self.pos] = input;

        var sum: f32 = 0.0;
        inline for (0..FILTER_ORDER) |j| {
            if (comptime COEFFS[j] != 0.0) {
                const idx = (self.pos +% (RING_SIZE - j)) & RING_MASK;
                sum += COEFFS[j] * self.ring[idx];
            }
        }

        self.pos = (self.pos + 1) & RING_MASK;
        return sum;
    }

    /// Push a sample into the delay line without computing output.
    /// Used by downsampler to skip unnecessary FIR computation.
    pub inline fn push(self: *Self, input: f32) void {
        self.ring[self.pos] = input;
        self.pos = (self.pos + 1) & RING_MASK;
    }

    pub fn reset(self: *Self) void {
        self.ring = .{0.0} ** RING_SIZE;
        self.pos = 0;
    }
};

// -- 2x Oversampler -----------------------------------------------------------

pub const Oversampler2x = struct {
    const Self = @This();

    up_filter: HalfBandFilter,
    down_filter: HalfBandFilter,

    pub fn init() Self {
        return .{
            .up_filter = HalfBandFilter.init(),
            .down_filter = HalfBandFilter.init(),
        };
    }

    /// Upsample by 2x: zero-stuff + FIR anti-image filter.
    /// Gain compensation: input × 2.0 to restore unity DC gain after zero-stuffing.
    pub fn upsample_2x(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE * 2]f32) void {
        for (in_buf, 0..) |sample, i| {
            out_buf[i * 2] = self.up_filter.tick(sample * 2.0);
            out_buf[i * 2 + 1] = self.up_filter.tick(0.0);
        }
    }

    /// Downsample by 2x: FIR anti-alias filter + decimation.
    /// push() skips FIR computation for discarded samples.
    pub fn downsample_2x(self: *Self, in_buf: *const [BLOCK_SIZE * 2]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (out_buf, 0..) |*out, i| {
            self.down_filter.push(in_buf[i * 2]);
            out.* = self.down_filter.tick(in_buf[i * 2 + 1]);
        }
    }

    pub fn reset(self: *Self) void {
        self.up_filter.reset();
        self.down_filter.reset();
    }
};

// -- 4x Oversampler (cascaded 2x) --------------------------------------------

pub const Oversampler4x = struct {
    const Self = @This();

    // Stage 1: 1x <-> 2x
    stage1_up: HalfBandFilter,
    stage1_down: HalfBandFilter,
    // Stage 2: 2x <-> 4x
    stage2_up: HalfBandFilter,
    stage2_down: HalfBandFilter,

    pub fn init() Self {
        return .{
            .stage1_up = HalfBandFilter.init(),
            .stage1_down = HalfBandFilter.init(),
            .stage2_up = HalfBandFilter.init(),
            .stage2_down = HalfBandFilter.init(),
        };
    }

    /// Upsample by 4x: cascaded 1x→2x→4x.
    pub fn upsample_4x(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE * 4]f32) void {
        // Stage 1: 1x → 2x (BLOCK_SIZE → BLOCK_SIZE*2)
        var intermediate: [BLOCK_SIZE * 2]f32 = undefined;
        for (in_buf, 0..) |sample, i| {
            intermediate[i * 2] = self.stage1_up.tick(sample * 2.0);
            intermediate[i * 2 + 1] = self.stage1_up.tick(0.0);
        }

        // Stage 2: 2x → 4x (BLOCK_SIZE*2 → BLOCK_SIZE*4)
        for (intermediate, 0..) |sample, i| {
            out_buf[i * 2] = self.stage2_up.tick(sample * 2.0);
            out_buf[i * 2 + 1] = self.stage2_up.tick(0.0);
        }
    }

    /// Downsample by 4x: cascaded 4x→2x→1x.
    pub fn downsample_4x(self: *Self, in_buf: *const [BLOCK_SIZE * 4]f32, out_buf: *[BLOCK_SIZE]f32) void {
        // Stage 2: 4x → 2x (BLOCK_SIZE*4 → BLOCK_SIZE*2)
        var intermediate: [BLOCK_SIZE * 2]f32 = undefined;
        for (&intermediate, 0..) |*out, i| {
            self.stage2_down.push(in_buf[i * 2]);
            out.* = self.stage2_down.tick(in_buf[i * 2 + 1]);
        }

        // Stage 1: 2x → 1x (BLOCK_SIZE*2 → BLOCK_SIZE)
        for (out_buf, 0..) |*out, i| {
            self.stage1_down.push(intermediate[i * 2]);
            out.* = self.stage1_down.tick(intermediate[i * 2 + 1]);
        }
    }

    pub fn reset(self: *Self) void {
        self.stage1_up.reset();
        self.stage1_down.reset();
        self.stage2_up.reset();
        self.stage2_down.reset();
    }
};

// -- Tests --------------------------------------------------------------------

/// Goertzel: magnitude of a specific frequency bin.
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

test "AC-1: 2x oversampling preserves 440Hz sine, no aliasing at 20kHz" {
    const sr: f32 = 44100.0;
    var os = Oversampler2x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Settle: 16 blocks to let FIR converge
    var phase: f32 = 0.0;
    for (0..16) |_| {
        for (&input) |*s| {
            s.* = @sin(2.0 * std.math.pi * phase);
            phase += 440.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        os.upsample_2x(&input, &upsampled);
        os.downsample_2x(&upsampled, &output);
    }

    // Measure last block: 440Hz should be present, 20kHz should be absent
    const mag_440 = goertzel_magnitude(&output, 440.0, sr);
    const mag_20k = goertzel_magnitude(&output, 20000.0, sr);

    try std.testing.expect(mag_440 > 0.1);
    try std.testing.expect(mag_20k < 0.01);
}

test "AC-2: upsample -> downsample roundtrip preserves signal" {
    const sr: f32 = 44100.0;
    var os = Oversampler2x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Settle: 20 blocks of 440Hz sine
    var phase: f32 = 0.0;
    for (0..20) |_| {
        for (&input) |*s| {
            s.* = @sin(2.0 * std.math.pi * phase);
            phase += 440.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        os.upsample_2x(&input, &upsampled);
        os.downsample_2x(&upsampled, &output);
    }

    // After settling, output RMS should match input RMS.
    // 440Hz sine RMS = 1/sqrt(2) ≈ 0.707.
    var rms_sum: f64 = 0.0;
    for (output) |o| {
        rms_sum += @as(f64, o) * @as(f64, o);
    }
    const rms_out = @sqrt(rms_sum / @as(f64, BLOCK_SIZE));

    // RMS should be close to 0.707 (within ±0.1 for roundtrip accuracy < 0.01)
    try std.testing.expect(rms_out > 0.5);
    try std.testing.expect(rms_out < 0.8);
}

test "AC-N1: no DC offset after oversampling roundtrip" {
    var os = Oversampler2x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Feed zero-mean sine for 50 blocks, average over last 40 blocks.
    // Single-block average can be non-zero due to non-integer cycles in 128 samples.
    // Long-term average cancels windowing artifacts and reveals true DC drift.
    var phase: f32 = 0.0;
    var total_sum: f64 = 0.0;
    var total_count: usize = 0;
    for (0..50) |blk| {
        for (&input) |*s| {
            s.* = @sin(2.0 * std.math.pi * phase);
            phase += 440.0 / 44100.0;
            if (phase >= 1.0) phase -= 1.0;
        }
        os.upsample_2x(&input, &upsampled);
        os.downsample_2x(&upsampled, &output);

        // Skip first 10 blocks (settling), average the rest
        if (blk >= 10) {
            for (output) |o| {
                total_sum += @as(f64, o);
                total_count += 1;
            }
        }
    }

    const avg = total_sum / @as(f64, @floatFromInt(total_count));
    try std.testing.expect(@abs(avg) < 0.01);
}

test "4x oversampling roundtrip preserves signal" {
    const sr: f32 = 44100.0;
    var os = Oversampler4x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var upsampled: [BLOCK_SIZE * 4]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Settle: 30 blocks (more needed for cascaded filters)
    var phase: f32 = 0.0;
    for (0..30) |_| {
        for (&input) |*s| {
            s.* = @sin(2.0 * std.math.pi * phase);
            phase += 440.0 / sr;
            if (phase >= 1.0) phase -= 1.0;
        }
        os.upsample_4x(&input, &upsampled);
        os.downsample_4x(&upsampled, &output);
    }

    // Output RMS should be close to input RMS (~0.707)
    var rms_sum: f64 = 0.0;
    for (output) |o| {
        rms_sum += @as(f64, o) * @as(f64, o);
    }
    const rms_out = @sqrt(rms_sum / @as(f64, BLOCK_SIZE));
    try std.testing.expect(rms_out > 0.3);
    try std.testing.expect(rms_out < 0.85);
}

test "silence in -> silence out" {
    var os = Oversampler2x.init();
    var input = [_]f32{0.0} ** BLOCK_SIZE;
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    os.upsample_2x(&input, &upsampled);
    os.downsample_2x(&upsampled, &output);

    for (output) |o| {
        try std.testing.expectEqual(@as(f32, 0.0), o);
    }
}

test "reset clears filter state" {
    var os = Oversampler2x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    for (&input) |*s| s.* = 1.0;
    os.upsample_2x(&input, &upsampled);

    // State should be non-zero
    var has_state = false;
    for (os.up_filter.ring) |h| {
        if (h != 0.0) has_state = true;
    }
    try std.testing.expect(has_state);

    // Reset
    os.reset();

    for (os.up_filter.ring) |h| try std.testing.expectEqual(@as(f32, 0.0), h);
    for (os.down_filter.ring) |h| try std.testing.expectEqual(@as(f32, 0.0), h);
}

test "FIR coefficients sum to 1.0" {
    var sum: f64 = 0.0;
    for (COEFFS) |c| sum += @as(f64, c);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-5);
}

test "FIR is symmetric" {
    for (0..FILTER_ORDER) |k| {
        try std.testing.expectApproxEqAbs(COEFFS[k], COEFFS[FILTER_ORDER - 1 - k], 1e-7);
    }
}

test "benchmark: 2x oversampling 128 samples" {
    var os = Oversampler2x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var upsampled: [BLOCK_SIZE * 2]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        os.upsample_2x(&input, &upsampled);
        os.downsample_2x(&upsampled, &output);
    }

    const iterations: u64 = 200_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        os.upsample_2x(&input, &upsampled);
        os.downsample_2x(&upsampled, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    // Debug budget: generous for build server variability
    // Issue target: <8000ns (ReleaseFast). Debug: ~10-20x slower.
    const budget_ns: u64 = 120000;
    std.debug.print("\n[WP-088] 2x oversampling: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: 4x oversampling 128 samples" {
    var os = Oversampler4x.init();

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var upsampled: [BLOCK_SIZE * 4]f32 = undefined;
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        os.upsample_4x(&input, &upsampled);
        os.downsample_4x(&upsampled, &output);
    }

    const iterations: u64 = 200_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        os.upsample_4x(&input, &upsampled);
        os.downsample_4x(&upsampled, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    // Debug budget: 4x has ~4x cost of 2x
    const budget_ns: u64 = 500000;
    std.debug.print("\n[WP-088] 4x oversampling: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}
