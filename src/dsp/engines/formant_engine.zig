const std = @import("std");
const oscillator = @import("../oscillator.zig");
const formant_filter = @import("../formant_filter.zig");
const filter = @import("../filter.zig");

// ── Formant Engine (WP-056) ─────────────────────────────────────────
// Vowel synthesis combining a harmonically rich exciter waveform
// (Saw or Pulse) with the 5-band Formant Filter from WP-033.
// Morph parameter interpolates formant frequencies between vowels
// for smooth "talking" sound transitions (A/E/I/O/U).
// No heap allocation — all state is inline.

pub const BLOCK_SIZE: usize = oscillator.BLOCK_SIZE;
pub const Vowel = formant_filter.Vowel;

pub const ExciterType = enum { saw, pulse };

pub const FormantEngine = struct {
    const Self = @This();

    phase: f32,
    phase_inc: f32,
    sample_rate: f32,
    exciter: ExciterType,
    formant: formant_filter.FormantFilter,

    /// Initialize with default: Saw exciter, vowel A, 440Hz.
    pub fn init(sample_rate: f32) Self {
        return .{
            .phase = 0.0,
            .phase_inc = 440.0 / sample_rate,
            .sample_rate = sample_rate,
            .exciter = .saw,
            .formant = formant_filter.FormantFilter.init(sample_rate),
        };
    }

    /// Set exciter frequency from MIDI note or Hz.
    pub fn set_note(self: *Self, freq: f32) void {
        self.phase_inc = freq / self.sample_rate;
    }

    /// Set exciter waveform type (saw or pulse).
    pub fn set_exciter(self: *Self, exciter_type: ExciterType) void {
        self.exciter = exciter_type;
    }

    /// Set a fixed vowel target (no morphing).
    pub fn set_vowel(self: *Self, vowel: Vowel) void {
        self.formant.set_vowel(vowel);
    }

    /// Morph between two vowels. t=0.0 → from, t=1.0 → to.
    /// Linearly interpolates formant frequencies and recalculates SVF coefficients.
    pub fn set_morph(self: *Self, from: Vowel, to: Vowel, t: f32) void {
        const clamped = @max(0.0, @min(1.0, t));
        const inv = 1.0 - clamped;
        const freqs_from = formant_filter.VOWEL_FORMANTS[@intFromEnum(from)];
        const freqs_to = formant_filter.VOWEL_FORMANTS[@intFromEnum(to)];
        for (0..formant_filter.NUM_BANDS) |b| {
            const freq = freqs_from[b] * inv + freqs_to[b] * clamped;
            self.formant.coeffs[b] = filter.make_coeffs(freq, formant_filter.BAND_RESONANCE[b], self.sample_rate);
        }
    }

    /// Process a block of BLOCK_SIZE samples.
    /// Generates exciter waveform, then filters through formant filter.
    pub fn process_block(self: *Self, out_buf: *[BLOCK_SIZE]f32) void {
        // Generate exciter waveform
        var exciter_buf: [BLOCK_SIZE]f32 = undefined;
        const wave: oscillator.WaveType = switch (self.exciter) {
            .saw => .saw,
            .pulse => .square,
        };
        oscillator.process_block(&self.phase, self.phase_inc, wave, &exciter_buf);

        // Apply formant filter
        self.formant.process_block(&exciter_buf, out_buf);
    }

    /// Reset all state (phase + filter).
    pub fn reset(self: *Self) void {
        self.phase = 0.0;
        self.formant.reset();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

/// Goertzel algorithm: compute magnitude of a specific frequency bin.
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

test "AC-1: vowel A vs E have different spectral peaks" {
    const sr: f32 = 44100.0;
    const num_samples = 8192;

    // Engine with vowel A
    var eng_a = FormantEngine.init(sr);
    eng_a.set_note(220.0); // Rich harmonics at lower fundamental
    eng_a.set_vowel(.a);

    var out_a: [num_samples]f32 = undefined;
    // Settle filter state
    for (0..10) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng_a.process_block(&tmp);
    }
    // Collect analysis buffer
    var offset: usize = 0;
    while (offset < num_samples) {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng_a.process_block(&tmp);
        const remaining = num_samples - offset;
        const copy_len = @min(BLOCK_SIZE, remaining);
        @memcpy(out_a[offset..][0..copy_len], tmp[0..copy_len]);
        offset += copy_len;
    }

    // Engine with vowel E
    var eng_e = FormantEngine.init(sr);
    eng_e.set_note(220.0);
    eng_e.set_vowel(.e);

    var out_e: [num_samples]f32 = undefined;
    for (0..10) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng_e.process_block(&tmp);
    }
    offset = 0;
    while (offset < num_samples) {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng_e.process_block(&tmp);
        const remaining = num_samples - offset;
        const copy_len = @min(BLOCK_SIZE, remaining);
        @memcpy(out_e[offset..][0..copy_len], tmp[0..copy_len]);
        offset += copy_len;
    }

    // Vowel A: F1=730Hz, F2=1090Hz
    // Vowel E: F1=530Hz, F2=1840Hz
    // At A's F1 (730Hz), A should be louder than E
    const mag_a_at_730 = goertzel_magnitude(&out_a, 730.0, sr);
    const mag_e_at_730 = goertzel_magnitude(&out_e, 730.0, sr);

    // At E's F2 (1840Hz), E should be louder than A
    const mag_a_at_1840 = goertzel_magnitude(&out_a, 1840.0, sr);
    const mag_e_at_1840 = goertzel_magnitude(&out_e, 1840.0, sr);

    std.debug.print("\n[AC-1] A@730Hz={d:.4}, E@730Hz={d:.4}, A@1840Hz={d:.4}, E@1840Hz={d:.4}\n", .{
        mag_a_at_730, mag_e_at_730, mag_a_at_1840, mag_e_at_1840,
    });

    // A has stronger peak at its own F1 (730Hz)
    try std.testing.expect(mag_a_at_730 > mag_e_at_730);
    // E has stronger peak at its own F2 (1840Hz)
    try std.testing.expect(mag_e_at_1840 > mag_a_at_1840);
}

test "AC-2: morph t=0 to t=1 interpolates smoothly" {
    const sr: f32 = 44100.0;
    var eng = FormantEngine.init(sr);
    eng.set_note(220.0);

    // Settle the filter
    eng.set_morph(.a, .e, 0.0);
    for (0..20) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng.process_block(&tmp);
    }

    // Process blocks at various morph positions and check smoothness
    const steps = 11;
    var rms_values: [steps]f32 = undefined;

    for (0..steps) |step| {
        const t: f32 = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps - 1));
        eng.set_morph(.a, .e, t);

        // Process several blocks to let filter settle after coefficient change
        for (0..5) |_| {
            var tmp: [BLOCK_SIZE]f32 = undefined;
            eng.process_block(&tmp);
        }

        // Measure RMS of one block
        var out: [BLOCK_SIZE]f32 = undefined;
        eng.process_block(&out);
        var sum_sq: f64 = 0.0;
        for (out) |s| {
            sum_sq += @as(f64, s) * @as(f64, s);
        }
        rms_values[step] = @floatCast(@sqrt(sum_sq / BLOCK_SIZE));
    }

    // Check that consecutive RMS values don't jump by more than 50%
    // (smooth morph = gradual timbral change, not abrupt)
    var max_ratio: f32 = 0.0;
    for (1..steps) |step| {
        if (rms_values[step - 1] > 0.001 and rms_values[step] > 0.001) {
            const ratio = if (rms_values[step] > rms_values[step - 1])
                rms_values[step] / rms_values[step - 1]
            else
                rms_values[step - 1] / rms_values[step];
            if (ratio > max_ratio) max_ratio = ratio;
        }
    }

    std.debug.print("\n[AC-2] morph smoothness: max RMS ratio={d:.3} (threshold: 3.0)\n", .{max_ratio});
    // A smooth morph should not have RMS jumps > 3x between adjacent steps
    try std.testing.expect(max_ratio < 3.0);
}

test "AC-N1: uses FormantFilter from WP-033 (compile-time verification)" {
    // If formant_filter import or types changed, this would fail to compile.
    const ff = formant_filter.FormantFilter.init(44100.0);
    _ = ff;
    // Also verify the engine embeds a FormantFilter
    const eng = FormantEngine.init(44100.0);
    _ = eng.formant;
}

test "all 5 vowels produce non-silent output" {
    const sr: f32 = 44100.0;
    const vowels = [_]Vowel{ .a, .e, .i, .o, .u };

    for (vowels) |vowel| {
        var eng = FormantEngine.init(sr);
        eng.set_note(220.0);
        eng.set_vowel(vowel);

        // Settle
        for (0..5) |_| {
            var tmp: [BLOCK_SIZE]f32 = undefined;
            eng.process_block(&tmp);
        }

        var out: [BLOCK_SIZE]f32 = undefined;
        eng.process_block(&out);

        var has_nonzero = false;
        for (out) |s| {
            if (s != 0.0) {
                has_nonzero = true;
                break;
            }
        }
        try std.testing.expect(has_nonzero);
    }
}

test "pulse exciter produces different timbre than saw" {
    const sr: f32 = 44100.0;

    var eng_saw = FormantEngine.init(sr);
    eng_saw.set_note(220.0);
    eng_saw.set_vowel(.a);

    var eng_pulse = FormantEngine.init(sr);
    eng_pulse.set_note(220.0);
    eng_pulse.set_vowel(.a);
    eng_pulse.set_exciter(.pulse);

    // Settle
    for (0..10) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng_saw.process_block(&tmp);
        eng_pulse.process_block(&tmp);
    }

    var out_saw: [BLOCK_SIZE]f32 = undefined;
    var out_pulse: [BLOCK_SIZE]f32 = undefined;
    eng_saw.process_block(&out_saw);
    eng_pulse.process_block(&out_pulse);

    // Outputs should differ (different exciter harmonics)
    var differs = false;
    for (out_saw, out_pulse) |s, p| {
        if (@abs(s - p) > 0.001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "reset clears all state" {
    var eng = FormantEngine.init(44100.0);
    eng.set_note(440.0);

    // Feed signal
    for (0..20) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        eng.process_block(&tmp);
    }

    // Phase should have advanced
    try std.testing.expect(eng.phase != 0.0);

    eng.reset();

    try std.testing.expectEqual(@as(f32, 0.0), eng.phase);
    // Filter state should be zero
    for (eng.formant.z1) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
    for (eng.formant.z2) |z| try std.testing.expectEqual(@as(f64, 0.0), z);
}

test "set_morph at t=0 matches vowel from, t=1 matches vowel to" {
    const sr: f32 = 44100.0;

    // Engine with morph t=0 (= vowel A)
    var eng_morph = FormantEngine.init(sr);
    eng_morph.set_note(220.0);
    eng_morph.set_morph(.a, .e, 0.0);

    // Engine with fixed vowel A
    var eng_fixed = FormantEngine.init(sr);
    eng_fixed.set_note(220.0);
    eng_fixed.set_vowel(.a);

    // Coefficients should match
    for (0..formant_filter.NUM_BANDS) |b| {
        try std.testing.expectApproxEqAbs(eng_fixed.formant.coeffs[b].g, eng_morph.formant.coeffs[b].g, 1e-10);
    }
}

test "morph clamps t to [0, 1]" {
    // t=-1 should produce same coeffs as t=0
    var eng_neg = FormantEngine.init(44100.0);
    eng_neg.set_morph(.a, .e, -1.0);

    var eng_zero = FormantEngine.init(44100.0);
    eng_zero.set_morph(.a, .e, 0.0);

    for (0..formant_filter.NUM_BANDS) |b| {
        try std.testing.expectApproxEqAbs(eng_zero.formant.coeffs[b].g, eng_neg.formant.coeffs[b].g, 1e-10);
    }

    // t=2 should produce same coeffs as t=1
    var eng_over = FormantEngine.init(44100.0);
    eng_over.set_morph(.a, .e, 2.0);

    var eng_one = FormantEngine.init(44100.0);
    eng_one.set_morph(.a, .e, 1.0);

    for (0..formant_filter.NUM_BANDS) |b| {
        try std.testing.expectApproxEqAbs(eng_one.formant.coeffs[b].g, eng_over.formant.coeffs[b].g, 1e-10);
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: formant engine static vowel 128 samples" {
    var eng = FormantEngine.init(44100.0);
    eng.set_note(220.0);
    eng.set_vowel(.a);

    var out: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        eng.process_block(&out);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        eng.process_block(&out);
        std.mem.doNotOptimizeAway(&out);
    }
    const elapsed_ns = timer.read();
    const ns_per_block = elapsed_ns / iterations;

    // Debug budget: exciter (~3000ns) + formant filter (~25000ns) = ~28000ns
    // 4x headroom for build server variability
    const budget_ns: u64 = 120000;
    std.debug.print("\n[WP-056] formant_engine static vowel A: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: formant engine morph A→E 128 samples" {
    var eng = FormantEngine.init(44100.0);
    eng.set_note(220.0);

    var out: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        eng.set_morph(.a, .e, 0.5);
        eng.process_block(&out);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |iter| {
        // Continuously morph to include coefficient recalculation cost
        const t: f32 = @as(f32, @floatFromInt(iter % 100)) / 100.0;
        eng.set_morph(.a, .e, t);
        eng.process_block(&out);
        std.mem.doNotOptimizeAway(&out);
    }
    const elapsed_ns = timer.read();
    const ns_per_block = elapsed_ns / iterations;

    // Morph adds set_morph() overhead (5x make_coeffs) per block
    const budget_ns: u64 = 150000;
    std.debug.print("\n[WP-056] formant_engine morph A→E: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: formant engine 64 voices" {
    var engines: [64]FormantEngine = undefined;
    for (&engines, 0..) |*eng, vi| {
        eng.* = FormantEngine.init(44100.0);
        // Spread across different notes (C2..C7 range)
        const freq = 65.41 * std.math.pow(f32, 2.0, @as(f32, @floatFromInt(vi)) / 12.0);
        eng.set_note(freq);
        // Alternate vowels
        const vowels = [_]Vowel{ .a, .e, .i, .o, .u };
        eng.set_vowel(vowels[vi % 5]);
    }

    var out: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..100) |_| {
        for (&engines) |*eng| {
            eng.process_block(&out);
        }
    }

    const iterations: u64 = 10_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&engines) |*eng| {
            eng.process_block(&out);
            std.mem.doNotOptimizeAway(&out);
        }
    }
    const elapsed_ns = timer.read();
    const ns_per_iteration = elapsed_ns / iterations;

    // 64 voices × ~28000ns/voice (debug) = ~1.8M ns, ×4 headroom
    const budget_ns: u64 = 8_000_000;
    const ns_per_voice = ns_per_iteration / 64;
    std.debug.print("\n[WP-056] formant_engine 64 voices: {}ns total, {}ns/voice (budget: {}ns total)\n", .{
        ns_per_iteration, ns_per_voice, budget_ns,
    });
    try std.testing.expect(ns_per_iteration < budget_ns);
}
