const std = @import("std");
const builtin = @import("builtin");

// ── Chaos-Modulatoren (WP-039) ─────────────────────────────────────
// Audio-rate chaos oscillators: Lorenz, Roessler, Henon, Random Walk.
// Deterministic, non-periodic signals in [-1, 1]. Zero heap allocation.

pub const BLOCK_SIZE: u32 = 128;

pub const ChaosType = enum(u2) {
    lorenz,
    roessler,
    henon,
    random_walk,
};

// ── xorshift32 PRNG (reused from lfo.zig pattern) ──────────────────

inline fn xorshift32(state: u32) u32 {
    var s = state;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

inline fn u32_to_bipolar(val: u32) f64 {
    return @as(f64, @floatFromInt(@as(i32, @bitCast(val)))) * (1.0 / 2147483648.0);
}

// ── ChaosOsc ────────────────────────────────────────────────────────

pub const ChaosOsc = struct {
    const Self = @This();

    x: f64 = 0.1,
    y: f64 = 0.0,
    z: f64 = 0.0,
    dt: f64 = 0.001,
    chaos_type: ChaosType = .lorenz,
    sh_state: u32 = 0x12345678,

    pub fn init(chaos_type: ChaosType) Self {
        return switch (chaos_type) {
            .lorenz => .{ .chaos_type = .lorenz, .x = 0.1, .y = 0.0, .z = 0.0 },
            .roessler => .{ .chaos_type = .roessler, .x = 0.1, .y = 0.0, .z = 0.0 },
            .henon => .{ .chaos_type = .henon, .x = 0.1, .y = 0.0, .z = 0.0 },
            .random_walk => .{ .chaos_type = .random_walk, .x = 0.0, .y = 0.0, .z = 0.0 },
        };
    }

    /// Process one sample. Returns normalized chaos value in [-1, 1].
    pub inline fn process_sample(self: *Self) f32 {
        switch (self.chaos_type) {
            .lorenz => {
                const sigma: f64 = 10.0;
                const rho: f64 = 28.0;
                const beta: f64 = 8.0 / 3.0;
                const dx = sigma * (self.y - self.x) * self.dt;
                const dy = (self.x * (rho - self.z) - self.y) * self.dt;
                const dz = (self.x * self.y - beta * self.z) * self.dt;
                self.x += dx;
                self.y += dy;
                self.z += dz;
                return @floatCast(std.math.clamp(self.x / 20.0, -1.0, 1.0));
            },
            .roessler => {
                const a: f64 = 0.2;
                const b: f64 = 0.2;
                const c: f64 = 5.7;
                const dx = -(self.y + self.z) * self.dt;
                const dy = (self.x + a * self.y) * self.dt;
                const dz = (b + self.z * (self.x - c)) * self.dt;
                self.x += dx;
                self.y += dy;
                self.z += dz;
                return @floatCast(std.math.clamp(self.x / 10.0, -1.0, 1.0));
            },
            .henon => {
                const a: f64 = 1.4;
                const bh: f64 = 0.3;
                const x_new = 1.0 - a * self.x * self.x + self.y;
                const y_new = bh * self.x;
                self.x = x_new;
                self.y = y_new;
                return @floatCast(std.math.clamp(self.x, -1.0, 1.0));
            },
            .random_walk => {
                self.sh_state = xorshift32(self.sh_state);
                const step = u32_to_bipolar(self.sh_state) * self.dt;
                self.x = std.math.clamp(self.x + step, -1.0, 1.0);
                return @floatCast(self.x);
            },
        }
    }

    /// Process a full block of samples.
    pub fn process_block(self: *Self, buf: *[BLOCK_SIZE]f32) void {
        for (buf) |*sample| {
            sample.* = self.process_sample();
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: Lorenz deterministic (same seed = same output)" {
    var osc1 = ChaosOsc.init(.lorenz);
    var osc2 = ChaosOsc.init(.lorenz);

    for (0..1000) |_| {
        const v1 = osc1.process_sample();
        const v2 = osc2.process_sample();
        try std.testing.expectEqual(v1, v2);
    }
}

test "AC-2: Output stays in [-1, 1] for all 4 types after 44100 samples" {
    const types = [_]ChaosType{ .lorenz, .roessler, .henon, .random_walk };
    for (types) |ct| {
        var osc = ChaosOsc.init(ct);
        for (0..44100) |_| {
            const v = osc.process_sample();
            try std.testing.expect(v >= -1.0);
            try std.testing.expect(v <= 1.0);
            try std.testing.expect(!std.math.isNan(v));
            try std.testing.expect(!std.math.isInf(v));
        }
    }
}

test "AC-N1: No NaN/Inf after 100000 samples" {
    const types = [_]ChaosType{ .lorenz, .roessler, .henon, .random_walk };
    for (types) |ct| {
        var osc = ChaosOsc.init(ct);
        for (0..100_000) |_| {
            const v = osc.process_sample();
            try std.testing.expect(!std.math.isNan(v));
            try std.testing.expect(!std.math.isInf(v));
        }
    }
}

test "Roessler deterministic" {
    var osc1 = ChaosOsc.init(.roessler);
    var osc2 = ChaosOsc.init(.roessler);
    for (0..1000) |_| {
        try std.testing.expectEqual(osc1.process_sample(), osc2.process_sample());
    }
}

test "Henon deterministic" {
    var osc1 = ChaosOsc.init(.henon);
    var osc2 = ChaosOsc.init(.henon);
    for (0..1000) |_| {
        try std.testing.expectEqual(osc1.process_sample(), osc2.process_sample());
    }
}

test "Random Walk deterministic (same PRNG seed)" {
    var osc1 = ChaosOsc.init(.random_walk);
    var osc2 = ChaosOsc.init(.random_walk);
    for (0..1000) |_| {
        try std.testing.expectEqual(osc1.process_sample(), osc2.process_sample());
    }
}

test "Lorenz output varies (non-periodic)" {
    var osc = ChaosOsc.init(.lorenz);
    var buf1: [BLOCK_SIZE]f32 = undefined;
    osc.process_block(&buf1);

    // Process 10 more blocks, then compare — should differ
    for (0..10) |_| {
        var tmp: [BLOCK_SIZE]f32 = undefined;
        osc.process_block(&tmp);
    }
    var buf2: [BLOCK_SIZE]f32 = undefined;
    osc.process_block(&buf2);

    var differs = false;
    for (buf1, buf2) |a, b| {
        if (a != b) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "process_block produces valid output" {
    const types = [_]ChaosType{ .lorenz, .roessler, .henon, .random_walk };
    for (types) |ct| {
        var osc = ChaosOsc.init(ct);
        var buf: [BLOCK_SIZE]f32 = undefined;
        osc.process_block(&buf);
        for (buf) |v| {
            try std.testing.expect(v >= -1.0);
            try std.testing.expect(v <= 1.0);
        }
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: Lorenz 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var osc = ChaosOsc.init(.lorenz);
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 3_200 else 20_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-039] Lorenz: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Roessler 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var osc = ChaosOsc.init(.roessler);
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 3_500 else 20_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-039] Roessler: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Henon 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var osc = ChaosOsc.init(.henon);
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 2_800 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-039] Henon: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Random Walk 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var osc = ChaosOsc.init(.random_walk);
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        osc.process_block(&buf);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 1_900 else 7_500;
    const pass = ns < budget;
    std.debug.print("\n[WP-039] Random Walk: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
