const std = @import("std");
const builtin = @import("builtin");

// ── Pitch Follower (WP-128) ─────────────────────────────────────────
// Monophonic, autocorrelation-based pitch tracking with 3-point median
// smoothing against octave outliers.
// No heap allocations; fixed-size rolling analysis buffer.

pub const PitchResult = struct {
    freq: f32 = 0.0, // Hz
    confidence: f32 = 0.0, // 0..1
};

pub const PitchFollower = struct {
    // 512 samples @ 44.1kHz => ~11.6ms analysis window.
    // Covers ~100Hz tracking while reducing per-block cost.
    analysis: [analysis_size]f32 = [_]f32{0.0} ** analysis_size,
    filled: usize = 0,

    last_freqs: [3]f32 = .{ 0.0, 0.0, 0.0 },
    freq_idx: usize = 0,

    pub const analysis_size = 512;
    pub const min_freq_hz: f32 = 20.0;
    pub const max_freq_hz: f32 = 5000.0;
    const silence_rms_threshold: f32 = 0.0005;

    pub inline fn reset(self: *PitchFollower) void {
        self.analysis = [_]f32{0.0} ** analysis_size;
        self.filled = 0;
        self.last_freqs = .{ 0.0, 0.0, 0.0 };
        self.freq_idx = 0;
    }

    pub fn process_block(self: *PitchFollower, input: []const f32, sample_rate: f32) PitchResult {
        if (input.len == 0) return .{};
        if (!std.math.isFinite(sample_rate) or sample_rate <= 0.0) return .{};

        self.push_block(input);
        return self.detect(sample_rate);
    }

    fn push_block(self: *PitchFollower, input: []const f32) void {
        const n = @min(input.len, analysis_size);
        if (n == 0) return;

        if (input.len >= analysis_size) {
            const start = input.len - analysis_size;
            for (0..analysis_size) |i| {
                self.analysis[i] = sanitize_sample(input[start + i]);
            }
            self.filled = analysis_size;
            return;
        }

        const keep = analysis_size - n;
        std.mem.copyForwards(f32, self.analysis[0..keep], self.analysis[n..analysis_size]);
        for (0..n) |i| {
            self.analysis[keep + i] = sanitize_sample(input[i]);
        }

        self.filled = @min(analysis_size, self.filled + n);
    }

    fn detect(self: *PitchFollower, sample_rate: f32) PitchResult {
        if (self.filled < 32) return .{};
        const n = self.filled;

        const min_lag = @max(@as(usize, 1), @as(usize, @intFromFloat(sample_rate / max_freq_hz)));
        const max_lag_limit = @as(usize, @intFromFloat(sample_rate / min_freq_hz));
        const max_lag = @min(max_lag_limit, n - 2);
        if (min_lag >= max_lag) return .{};

        var total_sq: f64 = 0.0;
        for (self.analysis[analysis_size - n .. analysis_size]) |x| {
            total_sq += @as(f64, x) * @as(f64, x);
        }
        const rms = @sqrt(total_sq / @as(f64, @floatFromInt(n)));
        if (rms < silence_rms_threshold) {
            const smoothed = self.smooth_frequency(0.0);
            _ = smoothed;
            return .{};
        }

        const window = self.analysis[analysis_size - n .. analysis_size];

        var best_lag: usize = min_lag;
        var best_corr: f32 = -1.0;
        var corrs: [analysis_size]f32 = [_]f32{0.0} ** analysis_size;
        var corr_count: usize = 0;
        var lag = min_lag;
        while (lag <= max_lag) : (lag += 1) {
            const overlap = n - lag;
            var corr: f64 = 0.0;
            var e0: f64 = 0.0;
            var e1: f64 = 0.0;

            var i: usize = 0;
            while (i < overlap) : (i += 1) {
                const a = @as(f64, window[i]);
                const b = @as(f64, window[i + lag]);
                corr += a * b;
                e0 += a * a;
                e1 += b * b;
            }

            const denom = @sqrt(e0 * e1 + 1e-24);
            if (denom <= 0.0) continue;

            const norm: f32 = @floatCast(corr / denom);
            corrs[corr_count] = norm;
            corr_count += 1;
            if (norm > best_corr) {
                best_corr = norm;
                best_lag = lag;
            }
        }

        if (best_corr <= 0.0) {
            _ = self.smooth_frequency(0.0);
            return .{};
        }

        // Prefer the first strong local maximum to avoid octave/subharmonic slips.
        var selected_lag = best_lag;
        const gate = @max(@as(f32, 0.80), best_corr * 0.95);
        if (corr_count >= 3 and max_lag > min_lag + 1) {
            var cand = min_lag + 1;
            while (cand < max_lag) : (cand += 1) {
                const idx = cand - min_lag;
                const c = corrs[idx];
                if (c >= gate and c >= corrs[idx - 1] and c >= corrs[idx + 1]) {
                    selected_lag = cand;
                    break;
                }
            }
        }

        // Sub-sample lag interpolation improves cent-level accuracy.
        var lag_f = @as(f32, @floatFromInt(selected_lag));
        if (selected_lag > min_lag and selected_lag < max_lag) {
            const idx = selected_lag - min_lag;
            const y0 = corrs[idx - 1];
            const y1 = corrs[idx];
            const y2 = corrs[idx + 1];
            const denom = y0 - 2.0 * y1 + y2;
            if (@abs(denom) > 1e-12) {
                const delta = 0.5 * (y0 - y2) / denom;
                if (std.math.isFinite(delta)) {
                    lag_f += std.math.clamp(delta, -0.5, 0.5);
                }
            }
        }

        const raw_freq = sample_rate / lag_f;
        const smoothed = self.smooth_frequency(raw_freq);
        const selected_corr = corrs[selected_lag - min_lag];

        return .{
            .freq = if (smoothed >= min_freq_hz and smoothed <= max_freq_hz) smoothed else 0.0,
            .confidence = std.math.clamp(selected_corr, 0.0, 1.0),
        };
    }

    fn smooth_frequency(self: *PitchFollower, raw_freq: f32) f32 {
        const freq = if (std.math.isFinite(raw_freq) and raw_freq > 0.0) raw_freq else 0.0;
        self.last_freqs[self.freq_idx % 3] = freq;
        self.freq_idx += 1;

        if (self.freq_idx == 1) return self.last_freqs[0];
        if (self.freq_idx == 2) return 0.5 * (self.last_freqs[0] + self.last_freqs[1]);
        return median3(self.last_freqs);
    }
};

fn sanitize_sample(x: f32) f32 {
    if (!std.math.isFinite(x)) return 0.0;
    return std.math.clamp(x, -1.0, 1.0);
}

fn median3(v: [3]f32) f32 {
    var a = v[0];
    var b = v[1];
    var c = v[2];
    if (a > b) std.mem.swap(f32, &a, &b);
    if (b > c) std.mem.swap(f32, &b, &c);
    if (a > b) std.mem.swap(f32, &a, &b);
    return b;
}

fn cents_error(actual: f32, reference: f32) f32 {
    if (!(actual > 0.0) or !(reference > 0.0)) return 0.0;
    return @floatCast(1200.0 * std.math.log2(@as(f64, actual) / @as(f64, reference)));
}

fn fill_sine_block(out: []f32, freq: f32, sample_rate: f32, phase: *f32) void {
    const inc = freq / sample_rate;
    for (out) |*s| {
        s.* = @sin(phase.* * std.math.tau);
        phase.* += inc;
        if (phase.* >= 1.0) phase.* -= @floor(phase.*);
    }
}

fn fill_saw_block(out: []f32, freq: f32, sample_rate: f32, phase: *f32) void {
    const inc = freq / sample_rate;
    for (out) |*s| {
        s.* = 2.0 * phase.* - 1.0;
        phase.* += inc;
        if (phase.* >= 1.0) phase.* -= @floor(phase.*);
    }
}

fn run_follow_sine(freq: f32, blocks: usize) PitchResult {
    var follower = PitchFollower{};
    var in = [_]f32{0.0} ** 128;
    var phase: f32 = 0.0;
    var result: PitchResult = .{};

    for (0..blocks) |_| {
        fill_sine_block(in[0..], freq, 44_100.0, &phase);
        result = follower.process_block(in[0..], 44_100.0);
    }
    return result;
}

fn run_follow_saw(freq: f32, blocks: usize) PitchResult {
    var follower = PitchFollower{};
    var in = [_]f32{0.0} ** 128;
    var phase: f32 = 0.0;
    var result: PitchResult = .{};

    for (0..blocks) |_| {
        fill_saw_block(in[0..], freq, 44_100.0, &phase);
        result = follower.process_block(in[0..], 44_100.0);
    }
    return result;
}

fn bench_autocorr_ns(freq: f32, blocks: usize) !u64 {
    var follower = PitchFollower{};
    var in = [_]f32{0.0} ** 128;
    var phase: f32 = 0.0;
    fill_sine_block(in[0..], freq, 44_100.0, &phase);
    for (0..8) |_| {
        _ = follower.process_block(in[0..], 44_100.0);
    }

    var timer = try std.time.Timer.start();
    var sink: f32 = 0.0;
    for (0..blocks) |_| {
        const r = follower.process_block(in[0..], 44_100.0);
        sink += r.freq + r.confidence;
    }
    std.mem.doNotOptimizeAway(sink);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

fn bench_median_ns(iters: usize) !u64 {
    var timer = try std.time.Timer.start();
    var acc: f32 = 0.0;
    var vals = [3]f32{ 440.0, 880.0, 440.0 };
    for (0..iters) |_| {
        acc += median3(vals);
        vals[0] += 0.001;
        vals[1] -= 0.001;
    }
    std.mem.doNotOptimizeAway(acc);
    const ns = timer.read() / iters;
    return if (ns == 0) 1 else ns;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: 440Hz sine tracks to 440Hz (+/-5Hz)" {
    const r = run_follow_sine(440.0, 24);
    try std.testing.expect(r.freq > 435.0 and r.freq < 445.0);
}

test "AC-2: 220Hz sine tracks to 220Hz (+/-5Hz)" {
    const r = run_follow_sine(220.0, 24);
    try std.testing.expect(r.freq > 215.0 and r.freq < 225.0);
}

test "AC-3: confidence > 0.8 for clean sine" {
    const r = run_follow_sine(440.0, 24);
    try std.testing.expect(r.confidence > 0.8);
}

test "AC-4: median filter smooths octave jumps" {
    var follower = PitchFollower{};
    _ = follower.smooth_frequency(440.0);
    _ = follower.smooth_frequency(440.0);
    const outlier_step = follower.smooth_frequency(880.0);
    const recovered = follower.smooth_frequency(440.0);

    try std.testing.expectApproxEqAbs(@as(f32, 440.0), outlier_step, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), recovered, 0.001);
}

test "AC-N1: silence input returns near-zero freq/confidence and no crash" {
    var follower = PitchFollower{};
    var silent = [_]f32{0.0} ** 128;

    var r: PitchResult = .{};
    for (0..12) |_| {
        r = follower.process_block(silent[0..], 44_100.0);
    }

    try std.testing.expect(r.freq < 0.01);
    try std.testing.expect(r.confidence < 0.01);
}

test "NaN/Inf input does not propagate NaN" {
    var follower = PitchFollower{};
    var block = [_]f32{0.0} ** 128;
    block[0] = std.math.nan(f32);
    block[1] = std.math.inf(f32);
    block[2] = -std.math.inf(f32);
    block[3] = 0.5;

    const r = follower.process_block(block[0..], 44_100.0);
    try std.testing.expect(std.math.isFinite(r.freq));
    try std.testing.expect(std.math.isFinite(r.confidence));
}

test "AC-B1: pitch follower benchmark thresholds" {
    const ns_block = try bench_autocorr_ns(440.0, 10_000);
    const ns_median = try bench_median_ns(1_000_000);

    const sine_440 = run_follow_sine(440.0, 24);
    const saw_100 = run_follow_saw(100.0, 40);
    const err_440_c = @abs(cents_error(sine_440.freq, 440.0));
    const err_100_c = @abs(cents_error(saw_100.freq, 100.0));

    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    const t_block: u64 = if (strict) 500_000 else 2_000_000;
    const t_median: u64 = if (strict) 200 else 10_000;

    std.debug.print(
        \\
        \\  [WP-128] Pitch Follower Benchmark
        \\    process_block (128): {} ns/block (threshold < {})
        \\    median3:             {} ns/op    (threshold < {})
        \\    440Hz sine:          {d:.2} Hz, {d:.3} cent error (threshold < 1.0)
        \\    100Hz saw:           {d:.2} Hz, {d:.3} cent error (threshold < 5.0)
        \\
    , .{ ns_block, t_block, ns_median, t_median, sine_440.freq, err_440_c, saw_100.freq, err_100_c });

    try std.testing.expect(ns_block < t_block);
    try std.testing.expect(ns_median < t_median);
    try std.testing.expect(err_440_c < 1.0);
    try std.testing.expect(err_100_c < 5.0);
}
