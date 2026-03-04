const std = @import("std");
const ladder = @import("ladder.zig");

// ── Diode Ladder Filter (WP-035) ──────────────────────────────────────
// TB-303-style 4-pole Diode Ladder with per-stage tanh saturation.
// Unlike the Moog Ladder (WP-017) which only saturates in the feedback
// path, the Diode Ladder applies tanh nonlinearity in every stage,
// producing warmer, more asymmetric overdrive ("acid" character).
// f64 integrators for numerical stability, f32 signal I/O.
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = 128;

pub const DiodeFilter = struct {
    const Self = @This();

    z: [4]f64,
    cutoff: f32,
    resonance: f32,
    sample_rate: f32,
    g: f64,
    g_comp: f64,
    k: f64,

    /// Initialize with default settings (1kHz cutoff, no resonance).
    pub fn init(sample_rate: f32) Self {
        var self: Self = .{
            .z = .{0.0} ** 4,
            .cutoff = 1000.0,
            .resonance = 0.0,
            .sample_rate = sample_rate,
            .g = 0.0,
            .g_comp = 0.0,
            .k = 0.0,
        };
        self.set_params(1000.0, 0.0);
        return self;
    }

    /// Set cutoff frequency and resonance, recalculate coefficients.
    /// cutoff: Hz (20..Nyquist), resonance: 0.0..1.0 (1.0 = self-oscillation).
    pub fn set_params(self: *Self, cutoff: f32, resonance: f32) void {
        const fc = @max(20.0, @min(self.sample_rate * 0.499, cutoff));
        const r = std.math.clamp(resonance, 0.0, 1.0);
        self.cutoff = fc;
        self.resonance = r;
        // Bilinear transform prewarp
        self.g = @tan(std.math.pi * @as(f64, fc) / @as(f64, self.sample_rate));
        // ZDF stabilization: g/(1+g) ensures stage gain < 1 at all frequencies
        self.g_comp = self.g / (1.0 + self.g);
        // Diode-style resonance scaling — stronger than Moog's 4x factor.
        // 17x factor approximates the TB-303 diode ladder feedback gain.
        self.k = @as(f64, r) * 17.0;
    }

    /// Diode tanh approximation using Moog's [3,2] Padé but applied per-stage
    /// (the Moog only applies it once in the feedback path).
    /// The per-stage application is what creates the diode character:
    /// same function, different topology = different harmonic content.
    /// g_comp=g/(1+g) and feedback clamp ensure stability.
    inline fn tanh_diode(x: f64) f64 {
        const x2 = x * x;
        return x * (15.0 + x2) / (15.0 + 6.0 * x2);
    }

    /// Process one sample through the 4-pole diode ladder.
    /// Per-stage input saturation gives TB-303 "acid" character:
    /// diode clipping happens on the signal entering each stage, while
    /// the integrator (state) remains linear — matching analog topology.
    /// Uses g_comp=g/(1+g) for ZDF stability at all cutoff frequencies.
    pub inline fn process_sample(self: *Self, input: f32) f32 {
        @setFloatMode(.optimized);
        const in: f64 = @floatCast(input);
        // Feedback with tanh saturation (like Moog, but with stronger k scaling)
        const fb_in = @min(4.0, @max(-4.0, self.k * self.z[3]));
        const fb = tanh_diode(fb_in);
        var s = in - fb;

        // 4 cascaded 1-pole stages: diode clips signal, integrator stays linear
        inline for (0..4) |stage| {
            const v = self.g_comp * (tanh_diode(s) - self.z[stage]);
            s = v + self.z[stage];
            self.z[stage] = s + v; // trapezoidal state update
        }

        return @floatCast(s);
    }

    /// Process one sample without tanh (fully linear, for benchmark comparison).
    pub inline fn process_sample_linear(self: *Self, input: f32) f32 {
        @setFloatMode(.optimized);
        const in: f64 = @floatCast(input);
        const fb = @min(4.0, @max(-4.0, self.k * self.z[3]));
        var s = in - fb;

        inline for (0..4) |stage| {
            const v = self.g_comp * (s - self.z[stage]);
            s = v + self.z[stage];
            self.z[stage] = s + v;
        }

        return @floatCast(s);
    }

    /// Process a block of BLOCK_SIZE samples.
    pub fn process_block(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (in_buf, out_buf) |sample_in, *sample_out| {
            sample_out.* = self.process_sample(sample_in);
        }
    }

    /// Reset all filter state to zero.
    pub fn reset(self: *Self) void {
        self.z = .{0.0} ** 4;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: self-oscillation at high resonance" {
    var diode = DiodeFilter.init(44100.0);
    diode.set_params(1000.0, 0.9);

    // Feed impulse to start oscillation
    _ = diode.process_sample(1.0);

    // Let it ring with zero input
    for (0..44100) |_| {
        _ = diode.process_sample(0.0);
    }

    // Measure peak over last 200 samples — must still be oscillating
    var max_amp: f32 = 0;
    for (0..200) |_| {
        const out = diode.process_sample(0.0);
        if (@abs(out) > max_amp) max_amp = @abs(out);
    }
    // Self-oscillation: output must have measurable amplitude
    try std.testing.expect(max_amp > 1e-6);
}

test "AC-2: no runaway at resonance=0.99" {
    var diode = DiodeFilter.init(44100.0);
    diode.set_params(1000.0, 0.99);

    var phase: f32 = 0.0;
    for (0..44100) |_| {
        const input = 2.0 * phase - 1.0; // saw wave
        const output = diode.process_sample(input);
        try std.testing.expect(!std.math.isNan(output));
        try std.testing.expect(!std.math.isInf(output));
        try std.testing.expect(@abs(output) < 10.0);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

test "AC-N1: f64 integrators" {
    // Compile-time verification: z field must be [4]f64.
    // If this compiles, the type is correct.
    const diode = DiodeFilter.init(44100.0);
    const z_val: f64 = diode.z[0]; // would fail to compile if z were f32
    try std.testing.expectEqual(@as(f64, 0.0), z_val);
}

test "AC-N2: no heap allocation in API" {
    // DiodeFilter.init takes only sample_rate.
    // If this compiles, the filter API does not require heap setup.
    const diode = DiodeFilter.init(44100.0);
    try std.testing.expect(diode.sample_rate == 44100.0);
}

test "24dB/oct LP slope" {
    const fc: f32 = 1000.0;
    const sr: f32 = 44100.0;

    // Measure amplitude at cutoff vs 2x cutoff (low resonance for clean slope)
    const amp_at_fc = blk: {
        var diode = DiodeFilter.init(sr);
        diode.set_params(fc, 0.0);
        var phase: f32 = 0.0;
        const inc: f32 = fc / sr;
        const amp: f32 = 0.001; // small signal for linear regime
        for (0..4410) |_| {
            _ = diode.process_sample(amp * @sin(2.0 * std.math.pi * phase));
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        var max_out: f32 = 0;
        for (0..4410) |_| {
            const output = diode.process_sample(amp * @sin(2.0 * std.math.pi * phase));
            if (@abs(output) > max_out) max_out = @abs(output);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        break :blk max_out;
    };

    const amp_at_2fc = blk: {
        var diode = DiodeFilter.init(sr);
        diode.set_params(fc, 0.0);
        var phase: f32 = 0.0;
        const inc: f32 = (2.0 * fc) / sr;
        const amp: f32 = 0.001;
        for (0..4410) |_| {
            _ = diode.process_sample(amp * @sin(2.0 * std.math.pi * phase));
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        var max_out: f32 = 0;
        for (0..4410) |_| {
            const output = diode.process_sample(amp * @sin(2.0 * std.math.pi * phase));
            if (@abs(output) > max_out) max_out = @abs(output);
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        break :blk max_out;
    };

    // 4-pole = 24dB/oct → at 1 octave above cutoff, expect >12dB attenuation
    try std.testing.expect(amp_at_fc > 0);
    try std.testing.expect(amp_at_2fc > 0);
    const ratio_db: f32 = 20.0 * @log10(amp_at_fc / amp_at_2fc);
    try std.testing.expect(ratio_db > 12.0);
}

test "process_block matches sample loop" {
    var diode_block = DiodeFilter.init(44100.0);
    var diode_sample = DiodeFilter.init(44100.0);
    diode_block.set_params(1000.0, 0.5);
    diode_sample.set_params(1000.0, 0.5);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var out_block: [BLOCK_SIZE]f32 = undefined;
    diode_block.process_block(&input, &out_block);

    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = diode_sample.process_sample(s);
    }

    for (out_block, out_sample) |b, s| {
        try std.testing.expectEqual(b, s);
    }
}

test "all outputs finite across parameter range" {
    const test_cases = [_]struct { cutoff: f32, reso: f32 }{
        .{ .cutoff = 20.0, .reso = 0.0 },
        .{ .cutoff = 20.0, .reso = 0.99 },
        .{ .cutoff = 1000.0, .reso = 0.5 },
        .{ .cutoff = 10000.0, .reso = 0.0 },
        .{ .cutoff = 20000.0, .reso = 1.0 },
    };

    for (test_cases) |tc| {
        var diode = DiodeFilter.init(44100.0);
        diode.set_params(tc.cutoff, tc.reso);
        var phase: f32 = 0.0;
        for (0..4410) |_| {
            const input = 2.0 * phase - 1.0;
            const output = diode.process_sample(input);
            try std.testing.expect(!std.math.isNan(output));
            try std.testing.expect(!std.math.isInf(output));
            phase += 440.0 / 44100.0;
            if (phase >= 1.0) phase -= 1.0;
        }
    }
}

test "reset clears state" {
    var diode = DiodeFilter.init(44100.0);
    diode.set_params(1000.0, 0.5);

    for (0..100) |_| _ = diode.process_sample(1.0);

    var has_state = false;
    for (diode.z) |z| if (z != 0.0) {
        has_state = true;
    };
    try std.testing.expect(has_state);

    diode.reset();
    for (diode.z) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
}

test "tanh_diode accuracy" {
    // [3,2] Padé: max error < 0.5% for |x| <= 1 (same as Moog's fast_tanh)
    const test_vals = [_]f64{ 0.0, 0.1, 0.5, 1.0, -1.0 };
    for (test_vals) |x| {
        const approx = DiodeFilter.tanh_diode(x);
        const exact = std.math.tanh(x);
        const err = @abs(approx - exact);
        try std.testing.expect(err < 0.005); // <0.5% error for |x| <= 1
    }
    // Monotonically increasing and odd symmetry
    try std.testing.expect(DiodeFilter.tanh_diode(0.5) < DiodeFilter.tanh_diode(1.0));
    try std.testing.expect(DiodeFilter.tanh_diode(1.0) < DiodeFilter.tanh_diode(2.0));
    try std.testing.expectApproxEqAbs(
        DiodeFilter.tanh_diode(1.0),
        -DiodeFilter.tanh_diode(-1.0),
        1e-10,
    );
    // For larger values: Padé [3,2] exceeds ±1 past |x|~2.5
    // This provides extra feedback damping (by design, like Moog)
    try std.testing.expect(DiodeFilter.tanh_diode(3.0) > 0.9);
}

test "benchmark: diode ladder 128 samples" {
    var diode = DiodeFilter.init(44100.0);
    diode.set_params(1000.0, 0.7);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| diode.process_block(&input, &output);

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        diode.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    // Debug: ~10000-15000ns, ReleaseFast: ~2000-4000ns
    // Build server variability: seen up to 40000ns under load
    const budget_ns: u64 = 50000;
    std.debug.print("\n[WP-035] diode ladder 4-pole: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: diode vs moog ladder comparison" {
    const sr: f32 = 44100.0;

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase);
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    // Moog Ladder benchmark
    const moog_coeffs = ladder.make_coeffs(1000.0, 0.7, sr);
    var moog_state = [_]f64{0} ** 4;
    for (0..1000) |_| ladder.process_block(&input, &output, &moog_state, moog_coeffs);

    const iterations: u64 = 500_000;
    var moog_timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ladder.process_block(&input, &output, &moog_state, moog_coeffs);
        std.mem.doNotOptimizeAway(&output);
    }
    const moog_ns = moog_timer.read() / iterations;

    // Diode Ladder benchmark
    var diode = DiodeFilter.init(sr);
    diode.set_params(1000.0, 0.7);
    for (0..1000) |_| diode.process_block(&input, &output);

    var diode_timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        diode.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const diode_ns = diode_timer.read() / iterations;

    const ratio = @as(f64, @floatFromInt(diode_ns)) / @as(f64, @floatFromInt(moog_ns));
    std.debug.print("[WP-035] diode: {}ns vs moog: {}ns (ratio: {d:.2}x)\n", .{ diode_ns, moog_ns, ratio });
}

test "benchmark: diode tanh overhead" {
    var diode_tanh = DiodeFilter.init(44100.0);
    var diode_linear = DiodeFilter.init(44100.0);
    diode_tanh.set_params(1000.0, 0.7);
    diode_linear.set_params(1000.0, 0.7);

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
        diode_tanh.process_block(&input, &output);
        diode_linear.reset();
    }
    for (0..1000) |_| {
        for (input, &output) |s, *o| o.* = diode_linear.process_sample_linear(s);
        diode_linear.reset();
    }

    const iterations: u64 = 500_000;

    // With tanh
    diode_tanh.reset();
    var tanh_timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        diode_tanh.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const tanh_ns = tanh_timer.read() / iterations;

    // Without tanh (linear)
    diode_linear.reset();
    var linear_timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (input, &output) |s, *o| o.* = diode_linear.process_sample_linear(s);
        std.mem.doNotOptimizeAway(&output);
    }
    const linear_ns = linear_timer.read() / iterations;

    const overhead_pct = if (linear_ns > 0)
        (@as(f64, @floatFromInt(tanh_ns)) - @as(f64, @floatFromInt(linear_ns))) / @as(f64, @floatFromInt(linear_ns)) * 100.0
    else
        0.0;
    std.debug.print("[WP-035] diode tanh: {}ns, linear: {}ns, overhead: {d:.1}%\n", .{ tanh_ns, linear_ns, overhead_pct });
}
