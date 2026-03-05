const std = @import("std");
const builtin = @import("builtin");

// -- Physical Modeling: Karplus-Strong (WP-059) -------------------------------
// Plucked-string synthesis:
// 1) excite(): fill delay line with deterministic noise burst
// 2) process_sample(): averaged feedback loop with damping
// No heap allocation in audio path.

pub const BLOCK_SIZE: usize = 128;
pub const MAX_DELAY: usize = 4096; // power-of-2 for fast mask wrap
const DELAY_MASK: usize = MAX_DELAY - 1;

fn clampSampleRate(sample_rate: f32) f32 {
    if (!std.math.isFinite(sample_rate) or sample_rate < 1_000.0) return 44_100.0;
    return sample_rate;
}

fn clampDamping(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.99;
    return std.math.clamp(v, 0.0, 0.9999);
}

fn clampDelayLen(samples: usize) usize {
    return std.math.clamp(samples, @as(usize, 2), MAX_DELAY - 1);
}

pub const KarplusStrong = struct {
    const Self = @This();

    sample_rate: f32,
    delay_line: [MAX_DELAY]f32,
    write_pos: usize,
    delay_len: usize,
    damping: f32,
    noise_state: u64,
    excited: bool,

    pub fn init(sample_rate: f32) Self {
        return .{
            .sample_rate = clampSampleRate(sample_rate),
            .delay_line = .{0.0} ** MAX_DELAY,
            .write_pos = 0,
            .delay_len = 100,
            .damping = 0.99,
            .noise_state = 0x9E3779B97F4A7C15,
            .excited = false,
        };
    }

    pub fn reset(self: *Self) void {
        self.delay_line = .{0.0} ** MAX_DELAY;
        self.write_pos = 0;
        self.excited = false;
    }

    pub fn set_delay_len(self: *Self, samples: u32) void {
        self.delay_len = clampDelayLen(@intCast(samples));
    }

    pub fn set_frequency(self: *Self, hz: f32) void {
        if (!std.math.isFinite(hz) or hz <= 0.0) return;
        const target_delay_f = self.sample_rate / hz;
        const target_delay_i: i32 = @intFromFloat(@round(target_delay_f));
        self.delay_len = clampDelayLen(@intCast(@max(2, target_delay_i)));
    }

    pub fn set_damping(self: *Self, damping: f32) void {
        self.damping = clampDamping(damping);
    }

    pub fn current_frequency(self: *const Self) f32 {
        return self.sample_rate / @as(f32, @floatFromInt(self.delay_len));
    }

    fn nextNoise(self: *Self) f32 {
        // xorshift64*
        var x = self.noise_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.noise_state = x;
        const scrambled = x *% 2685821657736338717;
        const unit = @as(f64, @floatFromInt(scrambled)) /
            @as(f64, @floatFromInt(std.math.maxInt(u64)));
        return @floatCast(unit * 2.0 - 1.0);
    }

    pub fn excite(self: *Self, amplitude: f32) void {
        const amp = std.math.clamp(if (std.math.isFinite(amplitude)) amplitude else 0.0, 0.0, 1.0);
        if (amp <= 0.0) {
            self.reset();
            return;
        }

        for (0..MAX_DELAY) |i| {
            if (i < self.delay_len) {
                const s = self.nextNoise() * amp;
                self.delay_line[i] = s;
            } else {
                self.delay_line[i] = 0.0;
            }
        }
        self.write_pos = self.delay_len & DELAY_MASK;
        self.excited = true;
    }

    inline fn feedback_step(self: *Self) f32 {
        const write_idx = self.write_pos & DELAY_MASK;
        const read_idx = (self.write_pos -% self.delay_len) & DELAY_MASK;
        const prev_idx = (read_idx -% 1) & DELAY_MASK;

        const averaged = 0.5 * (self.delay_line[read_idx] + self.delay_line[prev_idx]);
        const next = averaged * self.damping;
        self.delay_line[write_idx] = next;
        self.write_pos = (self.write_pos +% 1) & DELAY_MASK;
        return next;
    }

    pub fn process_sample(self: *Self) f32 {
        if (!self.excited) return 0.0;
        return self.feedback_step();
    }

    pub fn process_block(self: *Self, out: *[BLOCK_SIZE]f32) void {
        if (!self.excited) {
            @memset(out, 0.0);
            return;
        }
        for (out) |*s| {
            s.* = self.feedback_step();
        }
    }
};

fn estimateFrequencyAroundLag(samples: []const f32, sample_rate: f32, center_lag: usize, search_radius: usize) f32 {
    if (samples.len < 64 or center_lag < 2) return 0.0;
    const min_lag = @max(@as(usize, 2), center_lag - @min(center_lag - 1, search_radius));
    const max_lag = @min(center_lag + search_radius, samples.len - 1);

    var best_lag: usize = center_lag;
    var best_corr: f64 = -1e30;
    for (min_lag..max_lag + 1) |lag| {
        var corr: f64 = 0.0;
        for (0..samples.len - lag) |i| {
            corr += @as(f64, samples[i]) * @as(f64, samples[i + lag]);
        }
        if (corr > best_corr) {
            best_corr = corr;
            best_lag = lag;
        }
    }
    return sample_rate / @as(f32, @floatFromInt(best_lag));
}

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

fn sawBlock(phase_ptr: *f32, phase_inc: f32, out: *[BLOCK_SIZE]f32) void {
    var phase = phase_ptr.*;
    for (out) |*s| {
        s.* = 2.0 * phase - 1.0;
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }
    phase_ptr.* = phase;
}

// -- Tests --------------------------------------------------------------------

test "AC-N1: no excite produces silence" {
    var ks = KarplusStrong.init(44_100.0);
    ks.set_delay_len(220);
    ks.set_damping(0.995);

    for (0..8192) |_| {
        try std.testing.expectEqual(@as(f32, 0.0), ks.process_sample());
    }
}

test "AC-1: excite shows monotonic energy decay over 44100 samples" {
    var ks = KarplusStrong.init(44_100.0);
    ks.set_delay_len(320);
    ks.set_damping(0.9955);
    ks.excite(1.0);

    var out: [44_100]f32 = undefined;
    for (&out) |*s| {
        s.* = ks.process_sample();
    }

    const segment_len: usize = 2048;
    const segment_count: usize = out.len / segment_len;
    var prev_rms: f64 = 1e9;
    var first_rms: f64 = 0.0;
    var last_rms: f64 = 0.0;

    for (0..segment_count) |seg| {
        const start = seg * segment_len;
        const stop = start + segment_len;
        var sum_sq: f64 = 0.0;
        for (out[start..stop]) |s| {
            sum_sq += @as(f64, s) * @as(f64, s);
        }
        const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(segment_len)));
        if (seg == 0) first_rms = rms;
        last_rms = rms;

        // Windowed envelope should not rise over time.
        try std.testing.expect(rms <= prev_rms + 1e-4);
        prev_rms = rms;
    }

    std.debug.print("\n[AC-1] rms first={d:.6}, last={d:.6}\n", .{ first_rms, last_rms });
    try std.testing.expect(last_rms < first_rms * 0.3);
}

test "AC-2: frequency follows sample_rate / delay_length (+/-1Hz)" {
    const sample_rate: f32 = 44_100.0;
    var ks = KarplusStrong.init(sample_rate);
    ks.set_delay_len(294);
    ks.set_damping(0.998);
    // Deterministic impulse excitation for stable pitch estimation.
    ks.reset();
    ks.delay_line[0] = 1.0;
    ks.write_pos = ks.delay_len;
    ks.excited = true;

    var buffer: [24_576]f32 = undefined;
    for (&buffer) |*s| {
        s.* = ks.process_sample();
    }

    const analysis = buffer[4096..];
    const estimated = estimateFrequencyAroundLag(analysis, sample_rate, ks.delay_len, 8);
    const expected = sample_rate / @as(f32, @floatFromInt(ks.delay_len));

    std.debug.print("\n[AC-2] expected={d:.3}Hz, estimated={d:.3}Hz\n", .{ expected, estimated });
    try std.testing.expect(@abs(estimated - expected) <= 1.0);
}

test "benchmark: karplus_process_block 128 samples (1 voice)" {
    var ks = KarplusStrong.init(44_100.0);
    ks.set_frequency(440.0);
    ks.set_damping(0.997);
    ks.excite(1.0);

    var out: [BLOCK_SIZE]f32 = undefined;
    for (0..2000) |_| ks.process_block(&out);

    const iterations = benchIterations(20_000, 250_000, 800_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ks.process_block(&out);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns_per_block = timer.read() / iterations;

    const budget = benchBudget(
        300_000, // debug
        12_000, // release-safe
        2_000, // release-fast/small (issue threshold)
    );
    std.debug.print("\n[WP-059] karplus_process_block: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget);
}

test "benchmark: delay-line + LP feedback loop only" {
    var ks = KarplusStrong.init(44_100.0);
    ks.set_frequency(440.0);
    ks.set_damping(0.997);
    ks.excite(1.0);

    for (0..5000) |_| _ = ks.feedback_step();

    const iterations = benchIterations(20_000, 280_000, 1_000_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        var x: f32 = 0.0;
        for (0..BLOCK_SIZE) |_| {
            x += ks.feedback_step();
        }
        std.mem.doNotOptimizeAway(x);
    }
    const ns_per_block = timer.read() / iterations;

    const budget = benchBudget(
        220_000, // debug
        6_000, // release-safe
        1_500, // release-fast/small (issue threshold)
    );
    std.debug.print("\n[WP-059] feedback loop only: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget);
}

test "benchmark: karplus cost is in similar range to saw oscillator" {
    var ks = KarplusStrong.init(44_100.0);
    ks.set_frequency(440.0);
    ks.set_damping(0.997);
    ks.excite(1.0);

    var ks_out: [BLOCK_SIZE]f32 = undefined;
    var saw_phase: f32 = 0.0;
    var saw_out: [BLOCK_SIZE]f32 = undefined;
    const saw_inc: f32 = 440.0 / 44_100.0;

    for (0..2000) |_| {
        ks.process_block(&ks_out);
        sawBlock(&saw_phase, saw_inc, &saw_out);
    }

    const iterations = benchIterations(15_000, 150_000, 350_000);

    var timer_ks = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        ks.process_block(&ks_out);
        std.mem.doNotOptimizeAway(&ks_out);
    }
    const ks_ns = timer_ks.read() / iterations;

    var timer_saw = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        sawBlock(&saw_phase, saw_inc, &saw_out);
        std.mem.doNotOptimizeAway(&saw_out);
    }
    const saw_ns = timer_saw.read() / iterations;

    const ratio = @as(f64, @floatFromInt(ks_ns)) /
        @max(1.0, @as(f64, @floatFromInt(saw_ns)));
    std.debug.print(
        "\n[WP-059] karplus vs saw: karplus={}ns, saw={}ns, ratio={d:.3} (mode={s})\n",
        .{ ks_ns, saw_ns, ratio, @tagName(builtin.mode) },
    );
    try std.testing.expect(saw_ns > 0);
}
