const std = @import("std");
const builtin = @import("builtin");

// -- Comb Filter (WP-032) ----------------------------------------------------
// Delay-based feedback comb filter for resonant/metallic timbres.
// No heap allocation in audio path: delay line is fully preallocated.
// Buffer size is power-of-2 so read/write wrap uses a cheap bit mask.

pub const MAX_DELAY: u32 = 4096; // Power-of-2 for fast modulo via mask.
pub const BLOCK_SIZE: usize = 128;

pub const CombFilter = struct {
    const Self = @This();

    delay_line: [MAX_DELAY]f32,
    write_pos: u32,
    delay_samples: u32,
    feedback: f32,
    max_delay: u32,

    /// max_delay is clamped into [1, MAX_DELAY-1].
    pub fn init(max_delay: u32) Self {
        const clamped_max = std.math.clamp(max_delay, @as(u32, 1), MAX_DELAY - 1);
        return .{
            .delay_line = [_]f32{0.0} ** MAX_DELAY,
            .write_pos = 0,
            .delay_samples = @min(@as(u32, 256), clamped_max),
            .feedback = 0.5,
            .max_delay = clamped_max,
        };
    }

    pub fn reset(self: *Self) void {
        self.delay_line = [_]f32{0.0} ** MAX_DELAY;
        self.write_pos = 0;
    }

    pub fn set_delay(self: *Self, samples: u32) void {
        self.delay_samples = @min(samples, self.max_delay);
    }

    pub fn set_feedback(self: *Self, fb: f32) void {
        self.feedback = std.math.clamp(fb, -1.0, 1.0);
    }

    pub inline fn process_sample(self: *Self, input: f32) f32 {
        const mask: u32 = MAX_DELAY - 1;
        const write_idx = self.write_pos & mask;
        const read_idx = (self.write_pos -% self.delay_samples) & mask;

        const delayed = self.delay_line[read_idx];
        const output = input + delayed * self.feedback;

        self.delay_line[write_idx] = output;
        self.write_pos = (self.write_pos +% 1) & mask;
        return output;
    }

    pub fn process_block(self: *Self, in_buf: *const [BLOCK_SIZE]f32, out_buf: *[BLOCK_SIZE]f32) void {
        for (in_buf, out_buf) |sample, *out| {
            out.* = self.process_sample(sample);
        }
    }
};

// -- Tests --------------------------------------------------------------------

test "AC-1: impulse echoes exactly at delay_samples" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(32);
    comb.set_feedback(0.75);
    comb.reset();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), comb.process_sample(1.0), 1e-6);

    for (0..31) |_| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), comb.process_sample(0.0), 1e-6);
    }

    const echo = comb.process_sample(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), echo, 1e-6);
}

test "AC-2: feedback=0 produces no echo" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(48);
    comb.set_feedback(0.0);
    comb.reset();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), comb.process_sample(1.0), 1e-6);
    for (0..200) |_| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), comb.process_sample(0.0), 1e-6);
    }
}

test "AC-N1: feedback is clamped to [-1.0, 1.0]" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_feedback(5.0);
    try std.testing.expectEqual(@as(f32, 1.0), comb.feedback);

    comb.set_feedback(-5.0);
    try std.testing.expectEqual(@as(f32, -1.0), comb.feedback);
}

test "AC-N2: no NaN/Inf with high feedback over long run" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(64);
    comb.set_feedback(0.99);
    comb.reset();

    for (0..10_000) |i| {
        const input: f32 = if (i == 0) 1.0 else 0.0;
        const out = comb.process_sample(input);
        try std.testing.expect(!std.math.isNan(out));
        try std.testing.expect(!std.math.isInf(out));
    }
}

test "process_block matches process_sample loop" {
    var comb_block = CombFilter.init(MAX_DELAY - 1);
    var comb_sample = CombFilter.init(MAX_DELAY - 1);
    comb_block.set_delay(37);
    comb_sample.set_delay(37);
    comb_block.set_feedback(0.62);
    comb_sample.set_feedback(0.62);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 0.25;
        phase += 440.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var out_block: [BLOCK_SIZE]f32 = undefined;
    comb_block.process_block(&input, &out_block);

    var out_sample: [BLOCK_SIZE]f32 = undefined;
    for (input, &out_sample) |s, *o| {
        o.* = comb_sample.process_sample(s);
    }

    for (out_block, out_sample) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-6);
    }
}

test "benchmark: comb fixed delay 128 samples" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(240);
    comb.set_feedback(0.7);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 0.4;
        phase += 220.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |_| comb.process_block(&input, &output);

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 80_000,
        .ReleaseSafe => 150_000,
        .ReleaseFast, .ReleaseSmall => 300_000,
    };
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        comb.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    const budget_ns: u64 = switch (builtin.mode) {
        .Debug => 80_000,
        .ReleaseSafe => 10_000,
        .ReleaseFast, .ReleaseSmall => 400,
    };
    std.debug.print("\n[WP-032] comb fixed delay: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget_ns,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: comb modulated delay 128 samples" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(240);
    comb.set_feedback(0.5);

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 0.35;
        phase += 330.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;
    }
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |i| {
        comb.set_delay(80 + @as(u32, @intCast(i & 255)));
        comb.process_block(&input, &output);
    }

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 70_000,
        .ReleaseSafe => 120_000,
        .ReleaseFast, .ReleaseSmall => 250_000,
    };
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |i| {
        comb.set_delay(80 + @as(u32, @intCast(i & 255)));
        comb.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    const budget_ns: u64 = switch (builtin.mode) {
        .Debug => 120_000,
        .ReleaseSafe => 15_000,
        .ReleaseFast, .ReleaseSmall => 600,
    };
    std.debug.print("\n[WP-032] comb modulated delay: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget_ns,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: comb feedback 0.99 128 samples" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(200);
    comb.set_feedback(0.99);

    var input: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    input[0] = 1.0;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..2000) |_| comb.process_block(&input, &output);

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 70_000,
        .ReleaseSafe => 120_000,
        .ReleaseFast, .ReleaseSmall => 250_000,
    };
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        comb.process_block(&input, &output);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_per_block = timer.read() / iterations;

    const budget_ns: u64 = switch (builtin.mode) {
        .Debug => 120_000,
        .ReleaseSafe => 12_000,
        .ReleaseFast, .ReleaseSmall => 500,
    };
    std.debug.print("\n[WP-032] comb feedback 0.99: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_per_block,
        budget_ns,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: comb 64 voices scaling" {
    const voice_count: usize = 64;
    var voices: [voice_count]CombFilter = undefined;
    for (&voices, 0..) |*v, i| {
        v.* = CombFilter.init(MAX_DELAY - 1);
        v.set_delay(120 + @as(u32, @intCast(i)));
        v.set_feedback(0.6);
    }

    var input: [BLOCK_SIZE]f32 = undefined;
    var phase: f32 = 0.0;
    for (&input) |*s| {
        s.* = @sin(2.0 * std.math.pi * phase) * 0.2;
        phase += 110.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;
    }

    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..500) |_| {
        for (&voices) |*v| v.process_block(&input, &output);
    }

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 600,
        .ReleaseSafe => 1_500,
        .ReleaseFast, .ReleaseSmall => 4_000,
    };
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&voices) |*v| {
            v.process_block(&input, &output);
        }
        std.mem.doNotOptimizeAway(&output);
    }
    const ns_total = timer.read() / iterations;

    const budget_ns: u64 = switch (builtin.mode) {
        .Debug => 3_000_000,
        .ReleaseSafe => 400_000,
        .ReleaseFast, .ReleaseSmall => 25_000,
    };
    std.debug.print("\n[WP-032] comb 64 voices: {}ns/block (budget: {}ns, mode={s})\n", .{
        ns_total,
        budget_ns,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_total < budget_ns);
}

test "benchmark: comb delay modulation discontinuities" {
    var comb = CombFilter.init(MAX_DELAY - 1);
    comb.set_delay(32);
    comb.set_feedback(0.35);
    comb.reset();

    var phase: f32 = 0.0;
    var prev = comb.process_sample(0.0);
    var discontinuities: u32 = 0;
    var delay: u32 = 32;
    var direction: i32 = 1;

    // 1 second at 48kHz
    for (0..48_000) |i| {
        if ((i % 256) == 0) {
            if (delay >= 40) direction = -1;
            if (delay <= 24) direction = 1;
            delay = @as(u32, @intCast(@as(i32, @intCast(delay)) + direction));
            comb.set_delay(delay);
        }

        const input = @sin(2.0 * std.math.pi * phase) * 0.2;
        phase += 440.0 / 48000.0;
        if (phase >= 1.0) phase -= 1.0;

        const out = comb.process_sample(input);
        const jump = @abs(out - prev);
        if (jump > 0.8) discontinuities += 1;
        prev = out;
    }

    std.debug.print("\n[WP-032] comb modulation discontinuities: {}\n", .{discontinuities});
    try std.testing.expectEqual(@as(u32, 0), discontinuities);
}
