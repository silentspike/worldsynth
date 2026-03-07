const std = @import("std");
const builtin = @import("builtin");

// ── Stereo Widener Mid/Side (WP-047) ────────────────────────────
// Mid/Side encoding/decoding for stereo width control. Width 0 = mono,
// 1 = unity (passthrough), 2 = extra wide. Stateless, zero heap.

pub const BLOCK_SIZE: u32 = 128;

pub const StereoWidener = struct {
    const Self = @This();

    width: f32 = 1.0,

    pub fn init() Self {
        return .{};
    }

    pub fn set_width(self: *Self, w: f32) void {
        self.width = std.math.clamp(w, 0.0, 2.0);
    }

    /// Process one stereo sample pair. Returns [L, R].
    pub inline fn process_sample(self: *const Self, l: f32, r: f32) [2]f32 {
        const mid = (l + r) * 0.5;
        const side = (l - r) * 0.5 * self.width;
        return .{ mid + side, mid - side };
    }

    /// Process a block of stereo samples.
    pub fn process_block(
        self: *const Self,
        out_l: *[BLOCK_SIZE]f32,
        out_r: *[BLOCK_SIZE]f32,
        in_l: *const [BLOCK_SIZE]f32,
        in_r: *const [BLOCK_SIZE]f32,
    ) void {
        for (out_l, out_r, in_l, in_r) |*ol, *or_, *il, *ir| {
            const result = self.process_sample(il.*, ir.*);
            ol.* = result[0];
            or_.* = result[1];
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: width=0 produces mono (L == R)" {
    var sw = StereoWidener.init();
    sw.width = 0.0;

    const result = sw.process_sample(0.8, 0.2);
    try std.testing.expectEqual(result[0], result[1]);

    // Also test with varying input
    for (0..100) |i| {
        const l: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.5;
        const r: f32 = @sin(@as(f32, @floatFromInt(i)) * 0.13) * 0.5;
        const res = sw.process_sample(l, r);
        try std.testing.expectEqual(res[0], res[1]);
    }
}

test "AC-2: width=1 passes input unchanged" {
    const sw = StereoWidener.init();
    const l: f32 = 0.7;
    const r: f32 = 0.3;

    const result = sw.process_sample(l, r);
    try std.testing.expectApproxEqAbs(l, result[0], 0.0001);
    try std.testing.expectApproxEqAbs(r, result[1], 0.0001);
}

test "AC-N1: width=2 widens stereo (side amplitude doubled)" {
    var sw1 = StereoWidener.init();
    sw1.width = 1.0;
    var sw2 = StereoWidener.init();
    sw2.width = 2.0;

    const l: f32 = 0.8;
    const r: f32 = 0.2;

    const r1 = sw1.process_sample(l, r);
    const r2 = sw2.process_sample(l, r);

    const spread1 = @abs(r1[0] - r1[1]);
    const spread2 = @abs(r2[0] - r2[1]);

    try std.testing.expect(spread2 > spread1);
}

test "M/S roundtrip: encode then decode preserves signal" {
    // Width=1 is identity, so encode→decode should be lossless
    const sw = StereoWidener.init();
    const inputs = [_][2]f32{
        .{ 0.5, 0.3 },
        .{ -0.7, 0.4 },
        .{ 1.0, -1.0 },
        .{ 0.0, 0.0 },
    };
    for (inputs) |pair| {
        const result = sw.process_sample(pair[0], pair[1]);
        try std.testing.expectApproxEqAbs(pair[0], result[0], 0.0001);
        try std.testing.expectApproxEqAbs(pair[1], result[1], 0.0001);
    }
}

test "mono input stays mono at any width" {
    // Mono input (L == R) → side = 0 → output is always mono
    var sw = StereoWidener.init();
    const widths = [_]f32{ 0.0, 0.5, 1.0, 1.5, 2.0 };
    for (widths) |w| {
        sw.width = w;
        const result = sw.process_sample(0.5, 0.5);
        try std.testing.expectApproxEqAbs(result[0], result[1], 0.0001);
    }
}

test "process_block matches sequential process_sample" {
    const sw = StereoWidener{ .width = 1.5 };

    var in_l: [BLOCK_SIZE]f32 = undefined;
    var in_r: [BLOCK_SIZE]f32 = undefined;
    for (&in_l, &in_r, 0..) |*l, *r, i| {
        l.* = @sin(@as(f32, @floatFromInt(i)) * 0.1) * 0.4;
        r.* = @sin(@as(f32, @floatFromInt(i)) * 0.13) * 0.3;
    }

    var block_l: [BLOCK_SIZE]f32 = undefined;
    var block_r: [BLOCK_SIZE]f32 = undefined;
    sw.process_block(&block_l, &block_r, &in_l, &in_r);

    for (0..BLOCK_SIZE) |i| {
        const result = sw.process_sample(in_l[i], in_r[i]);
        try std.testing.expectApproxEqAbs(block_l[i], result[0], 0.0001);
        try std.testing.expectApproxEqAbs(block_r[i], result[1], 0.0001);
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: Stereo Widener process_block" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    const sw = StereoWidener{ .width = 1.5 };

    var in_l = [_]f32{0.3} ** BLOCK_SIZE;
    var in_r = [_]f32{0.2} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| sw.process_block(&out_l, &out_r, &in_l, &in_r);

    const iterations: u64 = if (strict) 2_000_000 else 100_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        sw.process_block(&out_l, &out_r, &in_l, &in_r);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 150 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-047] Stereo Widener: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
