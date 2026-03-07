const std = @import("std");
const builtin = @import("builtin");
const tables = @import("../../engine/tables.zig");

// ── Phase Distortion Engine (WP-055) ─────────────────────────────────
// Casio CZ-style phase distortion synthesis.
// Phase is nonlinearly warped before feeding into cosine lookup.
// distortion=0 → pure cosine, distortion=1 → maximum harmonic content.

pub const BLOCK_SIZE: usize = 128;

/// CZ-style phase mapping: interpolates between linear phase and
/// doubled-rate-per-half phase. At amount=1 each half of the period
/// traverses the full cosine cycle → frequency doubling with steep
/// transitions, producing rich harmonics.
inline fn phase_distort(p: f32, amount: f32) f32 {
    const a = std.math.clamp(amount, 0.0, 1.0);
    const distorted = if (p < 0.5)
        2.0 * p
    else
        1.0 - 2.0 * (1.0 - p);
    return @mulAdd(f32, a, distorted - p, p);
}

/// Cosine via sine LUT: cos(2*pi*x) = sin(2*pi*(x + 0.25))
inline fn cos_lut(phase: f32) f32 {
    return tables.sine_fast(phase + 0.25);
}

pub const PdEngine = struct {
    const Self = @This();

    phase: f64,
    sample_rate: f32,
    note_freq: f32,

    pub fn init(sample_rate: f32) Self {
        const sr = if (!std.math.isFinite(sample_rate) or sample_rate < 1_000.0) 44_100.0 else sample_rate;
        return .{
            .phase = 0.0,
            .sample_rate = sr,
            .note_freq = 440.0,
        };
    }

    pub fn reset(self: *Self) void {
        self.phase = 0.0;
    }

    pub fn set_note(self: *Self, freq: f32) void {
        if (!std.math.isFinite(freq) or freq <= 0.0) return;
        self.note_freq = freq;
    }

    pub inline fn process_sample(self: *Self, distortion: f32) f32 {
        @setFloatMode(.optimized);
        const p: f32 = @floatCast(self.phase);
        const distorted = phase_distort(p, distortion);
        const output = cos_lut(distorted);

        const phase_inc: f64 = @as(f64, self.note_freq) / @as(f64, self.sample_rate);
        self.phase += phase_inc;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return output;
    }

    pub fn process_block(self: *Self, out: *[BLOCK_SIZE]f32, distortion: f32) void {
        for (out) |*s| {
            s.* = self.process_sample(distortion);
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: distortion=0 produces pure cosine (error < 1e-6)" {
    var pd = PdEngine.init(44_100.0);
    pd.set_note(440.0);

    const phase_inc: f64 = 440.0 / 44_100.0;
    var ref_phase: f64 = 0.0;
    var max_err: f32 = 0.0;

    for (0..BLOCK_SIZE) |_| {
        const sample = pd.process_sample(0.0);
        const reference = cos_lut(@floatCast(ref_phase));
        const err = @abs(sample - reference);
        if (err > max_err) max_err = err;
        ref_phase += phase_inc;
        if (ref_phase >= 1.0) ref_phase -= 1.0;
    }

    std.debug.print("\n[WP-055] AC-1: max error at distortion=0: {d:.9}\n", .{max_err});
    try std.testing.expect(max_err < 1e-6);
}

test "AC-2: distortion=1 differs from pure cosine" {
    var pd_clean = PdEngine.init(44_100.0);
    pd_clean.set_note(440.0);
    var pd_dirty = PdEngine.init(44_100.0);
    pd_dirty.set_note(440.0);

    var diff_sum: f32 = 0.0;
    for (0..BLOCK_SIZE) |_| {
        const clean = pd_clean.process_sample(0.0);
        const dirty = pd_dirty.process_sample(1.0);
        diff_sum += @abs(clean - dirty);
    }

    std.debug.print("\n[WP-055] AC-2: diff_sum at distortion=1: {d:.4}\n", .{diff_sum});
    try std.testing.expect(diff_sum > 1.0);
}

test "AC-N1: no NaN/Inf at all distortion levels over 44100 samples" {
    const amounts = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    for (amounts) |amount| {
        var pd = PdEngine.init(44_100.0);
        pd.set_note(440.0);
        for (0..44_100) |_| {
            const s = pd.process_sample(amount);
            try std.testing.expect(!std.math.isNan(s));
            try std.testing.expect(!std.math.isInf(s));
        }
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

fn benchIterations(debug_iters: u64, safe_iters: u64, release_iters: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_iters,
        .ReleaseSafe => safe_iters,
        .ReleaseFast, .ReleaseSmall => release_iters,
    };
}

fn benchBudget(debug_budget: u64, safe_budget: u64, release_budget: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_budget,
        .ReleaseSafe => safe_budget,
        .ReleaseFast, .ReleaseSmall => release_budget,
    };
}

test "benchmark: PD 1 Voice amount=0.5" {
    var pd = PdEngine.init(44_100.0);
    pd.set_note(440.0);
    var out: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |_| pd.process_block(&out, 0.5);

    const iterations = benchIterations(20_000, 200_000, 1_000_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        pd.process_block(&out, 0.5);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget = benchBudget(150_000, 15_000, 1_200);
    const pass = ns < budget;
    std.debug.print("\n[WP-055] PD 1V amount=0.5: {}ns/block (budget: {}ns, mode={s}) {s}\n", .{
        ns, budget, @tagName(builtin.mode), if (pass) "PASS" else "<<< FAIL >>>",
    });
    try std.testing.expect(pass);
}

test "benchmark: PD 1 Voice amount=1.0" {
    var pd = PdEngine.init(44_100.0);
    pd.set_note(440.0);
    var out: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |_| pd.process_block(&out, 1.0);

    const iterations = benchIterations(20_000, 200_000, 1_000_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        pd.process_block(&out, 1.0);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget = benchBudget(175_000, 17_500, 1_200);
    const pass = ns < budget;
    std.debug.print("\n[WP-055] PD 1V amount=1.0: {}ns/block (budget: {}ns, mode={s}) {s}\n", .{
        ns, budget, @tagName(builtin.mode), if (pass) "PASS" else "<<< FAIL >>>",
    });
    try std.testing.expect(pass);
}

test "benchmark: PD LUT vs @cos speedup" {
    var pd = PdEngine.init(44_100.0);
    pd.set_note(440.0);

    // Warmup
    var sink: f32 = 0.0;
    for (0..5000) |i| {
        sink += cos_lut(@as(f32, @floatFromInt(i)) * 0.001);
    }
    std.mem.doNotOptimizeAway(&sink);

    const iterations = benchIterations(50_000, 500_000, 2_000_000);

    // LUT path
    pd.reset();
    var timer_lut = std.time.Timer.start() catch unreachable;
    var out_lut: [BLOCK_SIZE]f32 = undefined;
    for (0..iterations) |_| {
        pd.process_block(&out_lut, 0.5);
        std.mem.doNotOptimizeAway(&out_lut);
    }
    const ns_lut = timer_lut.read() / iterations;

    // @cos path
    var phase: f64 = 0.0;
    const phase_inc: f64 = 440.0 / 44_100.0;
    var out_cos: [BLOCK_SIZE]f32 = undefined;
    var timer_cos = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&out_cos) |*s| {
            const p: f32 = @floatCast(phase);
            const distorted = phase_distort(p, 0.5);
            s.* = @cos(2.0 * std.math.pi * @as(f32, distorted));
            phase += phase_inc;
            if (phase >= 1.0) phase -= 1.0;
        }
        std.mem.doNotOptimizeAway(&out_cos);
    }
    const ns_cos = timer_cos.read() / iterations;

    const speedup = @as(f64, @floatFromInt(ns_cos)) / @max(1.0, @as(f64, @floatFromInt(ns_lut)));
    std.debug.print("\n[WP-055] LUT vs @cos: LUT={}ns, @cos={}ns, speedup={d:.1}x (mode={s})\n", .{
        ns_lut, ns_cos, speedup, @tagName(builtin.mode),
    });

    // LUT should be at least as fast as @cos (on modern CPUs hardware cos can be fast)
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    if (strict) {
        try std.testing.expect(speedup >= 1.0);
    }
}

test "benchmark: PD 64 Voices parallel" {
    var engines: [64]PdEngine = undefined;
    for (&engines, 0..) |*e, i| {
        e.* = PdEngine.init(44_100.0);
        e.set_note(220.0 + @as(f32, @floatFromInt(i)) * 10.0);
    }
    var out: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        for (&engines) |*e| e.process_block(&out, 0.5);
    }

    const iterations = benchIterations(5_000, 50_000, 200_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&engines) |*e| {
            e.process_block(&out, 0.5);
        }
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget = benchBudget(900_000, 90_000, 90_000);
    const pass = ns < budget;
    const ns_per_voice = ns / 64;
    std.debug.print("\n[WP-055] PD 64V: {}ns total ({}ns/voice, budget: {}ns, mode={s}) {s}\n", .{
        ns, ns_per_voice, budget, @tagName(builtin.mode), if (pass) "PASS" else "<<< FAIL >>>",
    });
    try std.testing.expect(pass);
}

test "benchmark: PD amount modulated per sample" {
    var pd = PdEngine.init(44_100.0);
    pd.set_note(440.0);
    var out: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |_| {
        for (&out, 0..) |*s, i| {
            const amount: f32 = @as(f32, @floatFromInt(i)) / @as(f32, BLOCK_SIZE);
            s.* = pd.process_sample(amount);
        }
    }

    const iterations = benchIterations(20_000, 200_000, 1_000_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&out, 0..) |*s, i| {
            const amount: f32 = @as(f32, @floatFromInt(i)) / @as(f32, BLOCK_SIZE);
            s.* = pd.process_sample(amount);
        }
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget = benchBudget(200_000, 20_000, 1_600);
    const pass = ns < budget;
    std.debug.print("\n[WP-055] PD modulated: {}ns/block (budget: {}ns, mode={s}) {s}\n", .{
        ns, budget, @tagName(builtin.mode), if (pass) "PASS" else "<<< FAIL >>>",
    });
    try std.testing.expect(pass);
}
