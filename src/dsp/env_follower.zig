const std = @import("std");
const builtin = @import("builtin");

// ── Envelope Follower (WP-127) ──────────────────────────────────────
// Peak follower with separate attack/release smoothing.
// Output range is clamped to 0..1 so it can be used directly as mod source.
// No heap allocation, RT-safe stateful processing.

pub const EnvFollower = struct {
    attack_ms: f32,
    release_ms: f32,
    sample_rate: f32,
    attack_coeff: f32,
    release_coeff: f32,
    current: f32 = 0.0,

    pub fn init(attack_ms: f32, release_ms: f32, sample_rate: f32) EnvFollower {
        const sr = sanitize_sample_rate(sample_rate);
        const atk_ms = sanitize_time_ms(attack_ms);
        const rel_ms = sanitize_time_ms(release_ms);

        return .{
            .attack_ms = atk_ms,
            .release_ms = rel_ms,
            .sample_rate = sr,
            .attack_coeff = ms_to_coeff(atk_ms, sr),
            .release_coeff = ms_to_coeff(rel_ms, sr),
            .current = 0.0,
        };
    }

    pub fn set_times(self: *EnvFollower, attack_ms: f32, release_ms: f32) void {
        self.attack_ms = sanitize_time_ms(attack_ms);
        self.release_ms = sanitize_time_ms(release_ms);
        self.attack_coeff = ms_to_coeff(self.attack_ms, self.sample_rate);
        self.release_coeff = ms_to_coeff(self.release_ms, self.sample_rate);
    }

    pub fn set_sample_rate(self: *EnvFollower, sample_rate: f32) void {
        self.sample_rate = sanitize_sample_rate(sample_rate);
        self.attack_coeff = ms_to_coeff(self.attack_ms, self.sample_rate);
        self.release_coeff = ms_to_coeff(self.release_ms, self.sample_rate);
    }

    pub inline fn reset(self: *EnvFollower) void {
        self.current = 0.0;
    }

    pub inline fn process_sample(self: *EnvFollower, input: f32) f32 {
        const abs_in = sanitize_input(input);
        const coeff = if (abs_in > self.current) self.attack_coeff else self.release_coeff;
        self.current = coeff * self.current + (1.0 - coeff) * abs_in;

        if (!std.math.isFinite(self.current)) {
            self.current = 0.0;
        }
        self.current = std.math.clamp(self.current, 0.0, 1.0);
        return self.current;
    }

    /// Writes envelope output into `out` for min(input.len, out.len) samples.
    pub fn process_block(self: *EnvFollower, input: []const f32, out: []f32) void {
        const n = @min(input.len, out.len);
        for (0..n) |i| {
            out[i] = self.process_sample(input[i]);
        }
    }
};

fn sanitize_sample_rate(sample_rate: f32) f32 {
    if (!std.math.isFinite(sample_rate) or sample_rate <= 0.0) return 44_100.0;
    return sample_rate;
}

fn sanitize_time_ms(ms: f32) f32 {
    if (!std.math.isFinite(ms) or ms <= 0.0) return 0.001;
    return ms;
}

fn sanitize_input(input: f32) f32 {
    if (!std.math.isFinite(input)) return 0.0;
    return std.math.clamp(@abs(input), 0.0, 1.0);
}

fn ms_to_coeff(ms: f32, sample_rate: f32) f32 {
    const denom = sanitize_time_ms(ms) * 0.001 * sanitize_sample_rate(sample_rate);
    return @exp(-1.0 / denom);
}

const bench_sine_input: [128]f32 = blk: {
    var input: [128]f32 = undefined;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(input.len));
        input[i] = @sin(phase);
    }
    break :blk input;
};

fn bench_single(attack_ms: f32, release_ms: f32, blocks: usize) !u64 {
    var follower = EnvFollower.init(attack_ms, release_ms, 44_100.0);
    var out = [_]f32{0.0} ** 128;

    var timer = try std.time.Timer.start();
    for (0..blocks) |_| {
        follower.process_block(bench_sine_input[0..], out[0..]);
    }
    std.mem.doNotOptimizeAway(out[0]);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

fn bench_eight_followers(attack_ms: f32, release_ms: f32, blocks: usize) !u64 {
    var followers: [8]EnvFollower = undefined;
    for (&followers) |*f| {
        f.* = EnvFollower.init(attack_ms, release_ms, 44_100.0);
    }
    var out = [_]f32{0.0} ** 128;

    var timer = try std.time.Timer.start();
    for (0..blocks) |_| {
        for (&followers) |*f| {
            f.process_block(bench_sine_input[0..], out[0..]);
        }
    }
    std.mem.doNotOptimizeAway(out[0]);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

fn sine_accuracy_error_percent() f32 {
    const sample_rate: f32 = 44_100.0;
    const freq: f32 = 440.0;
    var follower = EnvFollower.init(1.0, 100.0, sample_rate);

    var max_env: f32 = 0.0;
    var i: usize = 0;
    while (i < @as(usize, @intFromFloat(sample_rate))) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        const in = @sin(std.math.tau * freq * t);
        const env = follower.process_sample(in);
        if (env > max_env) max_env = env;
    }
    return @abs(1.0 - max_env) * 100.0;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: loud input drives output close to 1.0" {
    var follower = EnvFollower.init(10.0, 100.0, 44_100.0);
    for (0..44_100) |_| {
        _ = follower.process_sample(1.0);
    }
    try std.testing.expect(follower.current > 0.99);
}

test "AC-2: silence decays output to near 0.0" {
    var follower = EnvFollower.init(10.0, 100.0, 44_100.0);
    for (0..22_050) |_| {
        _ = follower.process_sample(1.0);
    }
    for (0..132_300) |_| {
        _ = follower.process_sample(0.0);
    }
    try std.testing.expect(follower.current < 0.001);
}

test "AC-3: attack responds faster than release at default settings" {
    const sample_count: usize = 256;

    var attack = EnvFollower.init(10.0, 100.0, 44_100.0);
    for (0..sample_count) |_| {
        _ = attack.process_sample(1.0);
    }
    const attack_rise = attack.current;

    var release = EnvFollower.init(10.0, 100.0, 44_100.0);
    release.current = 1.0;
    for (0..sample_count) |_| {
        _ = release.process_sample(0.0);
    }
    const release_drop = 1.0 - release.current;

    try std.testing.expect(attack_rise > release_drop);
}

test "AC-4: output remains in range 0..1" {
    var follower = EnvFollower.init(1.0, 10.0, 44_100.0);
    const input = [_]f32{ -4.0, -1.5, -1.0, -0.2, 0.0, 0.3, 1.0, 2.0, 10.0 };
    for (input) |x| {
        const out = follower.process_sample(x);
        try std.testing.expect(out >= 0.0 and out <= 1.0);
    }
}

test "AC-N1: NaN/Inf input does not crash and does not propagate NaN" {
    var follower = EnvFollower.init(10.0, 100.0, 44_100.0);
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const ninf = -std.math.inf(f32);
    const samples = [_]f32{ nan, inf, ninf, 0.5, -0.75, 0.0 };

    for (samples) |s| {
        const out = follower.process_sample(s);
        try std.testing.expect(std.math.isFinite(out));
        try std.testing.expect(out >= 0.0 and out <= 1.0);
    }
}

test "process_block writes expected number of samples" {
    var follower = EnvFollower.init(10.0, 100.0, 44_100.0);
    var input = [_]f32{0.0} ** 128;
    for (&input, 0..) |*v, i| {
        v.* = if ((i & 1) == 0) 1.0 else 0.0;
    }
    var out = [_]f32{0.0} ** 128;
    follower.process_block(input[0..], out[0..]);
    for (out) |v| {
        try std.testing.expect(v >= 0.0 and v <= 1.0);
    }
}

test "AC-B1: envelope follower benchmark thresholds" {
    const ns_default = try bench_single(10.0, 100.0, 20_000);
    const ns_fast = try bench_single(1.0, 10.0, 20_000);
    const ns_slow = try bench_single(100.0, 1000.0, 20_000);
    const ns_8 = try bench_eight_followers(10.0, 100.0, 5_000);
    const accuracy_err = sine_accuracy_error_percent();

    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    const t_block: u64 = if (strict) 1_600 else 100_000;
    const t_8: u64 = if (strict) 12_000 else 800_000;

    std.debug.print(
        \\
        \\  [WP-127] Envelope Follower Benchmark
        \\    10ms/100ms:   {} ns/block (threshold < {})
        \\    1ms/10ms:     {} ns/block (threshold < {})
        \\    100ms/1000ms: {} ns/block (threshold < {})
        \\    8 followers:  {} ns/block (threshold < {})
        \\    Sine accuracy: {d:.3}% error (threshold < 5.0%)
        \\
    , .{ ns_default, t_block, ns_fast, t_block, ns_slow, t_block, ns_8, t_8, accuracy_err });

    try std.testing.expect(ns_default < t_block);
    try std.testing.expect(ns_fast < t_block);
    try std.testing.expect(ns_slow < t_block);
    try std.testing.expect(ns_8 < t_8);
    try std.testing.expect(accuracy_err < 5.0);
}
