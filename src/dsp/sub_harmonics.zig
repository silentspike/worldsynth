const std = @import("std");
const builtin = @import("builtin");

// ── Sub-Harmonics Generator (WP-126) ────────────────────────────────
// 1-2 octave sub oscillator with sine/square waveform.
// Mixed into output buffer via level (0..1).
// No heap allocation, stateful phase accumulator.

pub const SubHarmonics = struct {
    phase: f32 = 0.0,
    sub_octave: SubOctave = .one,
    level: f32 = 0.5,
    waveform: Waveform = .sine,

    pub const SubOctave = enum { one, two };
    pub const Waveform = enum { sine, square };

    /// Returns tracked sub-frequency based on octave mode.
    pub inline fn get_sub_frequency(self: *const SubHarmonics, input_freq: f32) f32 {
        if (!(input_freq > 0.0) or !std.math.isFinite(input_freq)) return 0.0;
        const div: f32 = switch (self.sub_octave) {
            .one => 2.0,
            .two => 4.0,
        };
        return input_freq / div;
    }

    pub inline fn process_block(
        self: *SubHarmonics,
        input_freq: f32,
        sample_rate: f32,
        out: []f32,
    ) void {
        if (out.len == 0) return;
        if (!(sample_rate > 0.0) or !std.math.isFinite(sample_rate)) return;

        const gain = std.math.clamp(self.level, 0.0, 1.0);
        if (gain == 0.0) return;

        const sub_freq = self.get_sub_frequency(input_freq);
        if (sub_freq == 0.0) return;

        const phase_inc = sub_freq / sample_rate;
        if (!(phase_inc > 0.0) or !std.math.isFinite(phase_inc)) return;

        for (out) |*sample_out| {
            const wave: f32 = switch (self.waveform) {
                .sine => @sin(self.phase * std.math.tau),
                .square => if (self.phase < 0.5) 1.0 else -1.0,
            };

            sample_out.* += wave * gain;

            self.phase += phase_inc;
            if (self.phase >= 1.0) {
                self.phase -= @floor(self.phase);
            }
        }
    }
};

fn estimate_freq_zero_crossings(samples: []const f32, sample_rate: f32) f32 {
    if (samples.len < 2 or sample_rate <= 0.0) return 0.0;

    var crossings: usize = 0;
    var i: usize = 1;
    while (i < samples.len) : (i += 1) {
        if (samples[i - 1] <= 0.0 and samples[i] > 0.0) {
            crossings += 1;
        }
    }

    const duration_s = @as(f32, @floatFromInt(samples.len)) / sample_rate;
    if (!(duration_s > 0.0)) return 0.0;
    return @as(f32, @floatFromInt(crossings)) / duration_s;
}

fn cents_error(actual: f32, expected: f32) f32 {
    if (!(actual > 0.0) or !(expected > 0.0)) return 0.0;
    return @floatCast(1200.0 * std.math.log2(@as(f64, actual) / @as(f64, expected)));
}

fn bench_one_voice(mode: SubHarmonics.SubOctave, waveform: SubHarmonics.Waveform, blocks: usize) !u64 {
    var sub = SubHarmonics{
        .sub_octave = mode,
        .waveform = waveform,
        .level = 0.75,
    };
    var out = [_]f32{0.0} ** 128;
    const sample_rate: f32 = 44_100.0;
    const input_freq: f32 = 440.0;

    var timer = try std.time.Timer.start();
    for (0..blocks) |_| {
        sub.process_block(input_freq, sample_rate, out[0..]);
    }
    std.mem.doNotOptimizeAway(out[0]);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

fn bench_64_voices(blocks: usize) !u64 {
    var subs: [64]SubHarmonics = undefined;
    for (&subs, 0..) |*s, i| {
        s.* = .{
            .sub_octave = if ((i & 1) == 0) .one else .two,
            .waveform = if ((i & 3) == 0) .square else .sine,
            .level = 0.6,
        };
    }

    var out = [_]f32{0.0} ** 128;
    const sample_rate: f32 = 44_100.0;
    var timer = try std.time.Timer.start();

    for (0..blocks) |_| {
        for (&subs, 0..) |*sub, v| {
            const f = 110.0 + @as(f32, @floatFromInt(v)) * 5.0;
            sub.process_block(f, sample_rate, out[0..]);
        }
    }

    std.mem.doNotOptimizeAway(out[0]);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: 440Hz input tracks to 220Hz sub (one octave down)" {
    const sample_rate: f32 = 44_100.0;
    var out = [_]f32{0.0} ** 44_100; // 1 second
    var sub = SubHarmonics{
        .sub_octave = .one,
        .waveform = .sine,
        .level = 1.0,
    };

    sub.process_block(440.0, sample_rate, out[0..]);
    const measured = estimate_freq_zero_crossings(out[0..], sample_rate);
    try std.testing.expectApproxEqAbs(@as(f32, 220.0), measured, 1.0);
}

test "AC-2: 440Hz input tracks to 110Hz sub (two octaves down)" {
    const sample_rate: f32 = 44_100.0;
    var out = [_]f32{0.0} ** 44_100; // 1 second
    var sub = SubHarmonics{
        .sub_octave = .two,
        .waveform = .sine,
        .level = 1.0,
    };

    sub.process_block(440.0, sample_rate, out[0..]);
    const measured = estimate_freq_zero_crossings(out[0..], sample_rate);
    try std.testing.expectApproxEqAbs(@as(f32, 110.0), measured, 1.0);
}

test "AC-3: level=0 produces no sub signal in output" {
    const sample_rate: f32 = 44_100.0;
    var out = [_]f32{0.25} ** 512;
    const before = out;
    var sub = SubHarmonics{
        .sub_octave = .one,
        .waveform = .sine,
        .level = 0.0,
    };

    sub.process_block(440.0, sample_rate, out[0..]);
    for (out, before) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "AC-4: square waveform outputs rectangle at sub frequency" {
    const sample_rate: f32 = 44_100.0;
    var out = [_]f32{0.0} ** 44_100;
    const level: f32 = 0.7;
    var sub = SubHarmonics{
        .sub_octave = .one,
        .waveform = .square,
        .level = level,
    };

    sub.process_block(440.0, sample_rate, out[0..]);
    for (out) |s| {
        try std.testing.expectApproxEqAbs(level, @abs(s), 0.0001);
    }

    const measured = estimate_freq_zero_crossings(out[0..], sample_rate);
    try std.testing.expectApproxEqAbs(@as(f32, 220.0), measured, 1.0);
}

test "AC-N1: input_freq=0 is silent and stable" {
    const sample_rate: f32 = 44_100.0;
    var out = [_]f32{0.0} ** 1024;
    var sub = SubHarmonics{
        .phase = 0.37,
        .sub_octave = .one,
        .waveform = .sine,
        .level = 0.9,
    };

    sub.process_block(0.0, sample_rate, out[0..]);

    for (out) |s| try std.testing.expectEqual(@as(f32, 0.0), s);
    try std.testing.expectApproxEqAbs(@as(f32, 0.37), sub.phase, 0.000001);
}

test "AC-B1: sub-harmonics benchmark thresholds" {
    const blocks: usize = 20_000;

    const ns_oct1 = try bench_one_voice(.one, .sine, blocks);
    const ns_oct2 = try bench_one_voice(.two, .sine, blocks);
    const ns_square = try bench_one_voice(.one, .square, blocks);
    const ns_64 = try bench_64_voices(2_000);
    const ns_per_voice = @as(f64, @floatFromInt(ns_64)) / 64.0;

    // Pitch-tracking accuracy check in cents.
    const s1 = SubHarmonics{ .sub_octave = .one };
    const s2 = SubHarmonics{ .sub_octave = .two };
    const e1 = @abs(cents_error(s1.get_sub_frequency(440.0), 220.0));
    const e2 = @abs(cents_error(s2.get_sub_frequency(440.0), 110.0));
    const track_err = @max(e1, e2);

    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    // Release thresholds: max(remote, local) × 2x headroom
    const t_oct: u64 = if (strict) 6_000 else 100_000;
    const t_square: u64 = if (strict) 3_000 else 100_000;
    const t_64: u64 = if (strict) 300_000 else 6_000_000;

    std.debug.print(
        \\
        \\  [WP-126] Sub-Harmonics Benchmark
        \\    -1 octave sine:   {} ns/block (threshold < {})
        \\    -2 octave sine:   {} ns/block (threshold < {})
        \\    -1 octave square: {} ns/block (threshold < {})
        \\    64 voices total:  {} ns/block, {d:.1} ns/voice (threshold < {} total)
        \\    Tracking error:   {d:.5} cents (threshold < 0.1)
        \\
    , .{ ns_oct1, t_oct, ns_oct2, t_oct, ns_square, t_square, ns_64, ns_per_voice, t_64, track_err });

    try std.testing.expect(ns_oct1 < t_oct);
    try std.testing.expect(ns_oct2 < t_oct);
    try std.testing.expect(ns_square < t_square);
    try std.testing.expect(ns_64 < t_64);
    try std.testing.expect(track_err < 0.1);
}
