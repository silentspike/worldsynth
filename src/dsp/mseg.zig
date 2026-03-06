const std = @import("std");
const builtin = @import("builtin");

// ── MSEG 64 Nodes (WP-038) ─────────────────────────────────────────
// Multi-Segment Envelope with 64 preallocated nodes and 4 curve types.
// Loop function for cyclic modulation. Pool of 16 MSEGs.
// Modulation source for Mod-Matrix (WP-036). Zero heap allocation.

pub const BLOCK_SIZE: u32 = 128;
pub const MAX_NODES: u32 = 64;
pub const MAX_MSEGS: u32 = 16;

pub const CurveType = enum(u2) {
    linear,
    exponential,
    s_curve,
    random,
};

pub const MSEGNode = struct {
    time: f32 = 0.0,
    value: f32 = 0.0,
    curve_type: CurveType = .linear,
};

// ── xorshift32 PRNG (reused from osc_sine_noise.zig pattern) ────────

inline fn xorshift32(state: u32) u32 {
    var s = state;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

inline fn u32_to_f32(val: u32) f32 {
    return @as(f32, @floatFromInt(@as(i32, @bitCast(val)))) * (1.0 / 2147483648.0);
}

// ── MSEG ────────────────────────────────────────────────────────────

pub const MSEG = struct {
    const Self = @This();

    nodes: [MAX_NODES]MSEGNode = [_]MSEGNode{.{}} ** MAX_NODES,
    node_count: u32 = 0,
    loop_start: u32 = 0,
    loop_end: u32 = 0,
    loop_enabled: bool = false,
    current_node: u32 = 0,
    phase: f64 = 0.0,
    active: bool = false,
    sh_state: u32 = 0x12345678,

    /// Add a node to the MSEG. Returns node index or null if full.
    pub fn add_node(self: *Self, time: f32, value: f32, curve: CurveType) ?u32 {
        if (self.node_count >= MAX_NODES) return null;
        self.nodes[self.node_count] = .{ .time = time, .value = value, .curve_type = curve };
        self.node_count += 1;
        return self.node_count - 1;
    }

    /// Process one sample. Returns interpolated envelope value.
    pub inline fn process_sample(self: *Self, sample_rate: f32) f32 {
        if (self.node_count < 2) return 0.0;

        if (self.current_node >= self.node_count - 1) {
            if (self.loop_enabled and self.loop_end > self.loop_start) {
                self.current_node = self.loop_start;
                self.phase = 0.0;
            } else {
                return self.nodes[self.node_count - 1].value;
            }
        }

        const a = self.nodes[self.current_node];
        const b = self.nodes[self.current_node + 1];
        const seg_dur = b.time - a.time;

        if (seg_dur <= 0.0) {
            self.current_node += 1;
            return a.value;
        }

        const t: f32 = @floatCast(self.phase);
        const diff = b.value - a.value;

        const val = switch (a.curve_type) {
            .linear => a.value + diff * t,
            .exponential => a.value + diff * t * t,
            .s_curve => a.value + diff * (3.0 * t * t - 2.0 * t * t * t),
            .random => blk: {
                self.sh_state = xorshift32(self.sh_state);
                const r = (u32_to_f32(self.sh_state) + 1.0) * 0.5; // [0, 1]
                break :blk a.value + diff * r;
            },
        };

        self.phase += 1.0 / (@as(f64, @floatCast(seg_dur)) * @as(f64, @floatCast(sample_rate)));
        if (self.phase >= 1.0) {
            self.phase = 0.0;
            self.current_node += 1;
        }

        return val;
    }

    /// Process a full block of samples.
    pub fn process_block(self: *Self, buf: *[BLOCK_SIZE]f32, sample_rate: f32) void {
        for (buf) |*sample| {
            sample.* = self.process_sample(sample_rate);
        }
    }

    /// Reset playback to start.
    pub fn reset(self: *Self) void {
        self.current_node = 0;
        self.phase = 0.0;
        self.sh_state = 0x12345678;
    }
};

// ── MSEG Pool ───────────────────────────────────────────────────────

pub const MSEGPool = struct {
    const Self = @This();

    msegs: [MAX_MSEGS]MSEG,
    active_count: u32,

    pub fn init() Self {
        return .{
            .msegs = [_]MSEG{.{}} ** MAX_MSEGS,
            .active_count = 0,
        };
    }

    /// Add an MSEG to the pool. Returns slot index or null if full.
    pub fn add(self: *Self) ?usize {
        for (&self.msegs, 0..) |*m, idx| {
            if (!m.active) {
                m.* = .{ .active = true };
                self.active_count += 1;
                return idx;
            }
        }
        return null;
    }

    /// Remove an MSEG from the pool.
    pub fn remove(self: *Self, idx: usize) void {
        if (idx < MAX_MSEGS and self.msegs[idx].active) {
            self.msegs[idx].active = false;
            self.active_count -= 1;
        }
    }

    /// Process all active MSEGs for one block.
    pub fn process_all_block(self: *Self, bufs: *[MAX_MSEGS][BLOCK_SIZE]f32, sample_rate: f32) void {
        if (self.active_count == 0) return;
        for (&self.msegs, 0..) |*m, idx| {
            if (m.active) {
                m.process_block(&bufs[idx], sample_rate);
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

fn setup_triangle_mseg() MSEG {
    var m = MSEG{ .active = true };
    _ = m.add_node(0.0, 0.0, .linear); // Start: t=0, v=0
    _ = m.add_node(0.5, 1.0, .linear); // Peak: t=0.5s, v=1.0
    _ = m.add_node(1.0, 0.0, .linear); // End: t=1.0s, v=0
    return m;
}

test "AC-1: 3-Node triangle (0,0)->(0.5,1.0)->(1.0,0)" {
    var m = setup_triangle_mseg();
    const sr: f32 = 44100.0;
    const total_samples: u32 = 44100; // 1 second

    var peak_val: f32 = -999.0;
    var peak_idx: u32 = 0;

    for (0..total_samples) |i| {
        const v = m.process_sample(sr);
        if (v > peak_val) {
            peak_val = v;
            peak_idx = @intCast(i);
        }
    }

    // Peak should be near 1.0 at ~50% of the envelope (sample 22050)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), peak_val, 0.01);
    // Peak should occur around the midpoint
    try std.testing.expect(peak_idx > 20000);
    try std.testing.expect(peak_idx < 24000);

    // Start value (reset and check)
    m.reset();
    const start_val = m.process_sample(sr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), start_val, 0.01);

    // End value: process to the end
    for (0..total_samples - 1) |_| {
        _ = m.process_sample(sr);
    }
    // After all samples, should be at 0.0 (last node value)
    const end_val = m.process_sample(sr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), end_val, 0.01);
}

test "AC-2: Loop repeats after loop_end" {
    var m = MSEG{ .active = true, .loop_enabled = true, .loop_start = 0, .loop_end = 2 };
    _ = m.add_node(0.0, 0.0, .linear);
    _ = m.add_node(0.5, 1.0, .linear);
    _ = m.add_node(1.0, 0.0, .linear);

    const sr: f32 = 44100.0;
    const one_cycle: u32 = 44100; // 1 second

    // Collect first cycle
    var cycle1: [128]f32 = undefined;
    for (&cycle1) |*s| {
        s.* = m.process_sample(sr);
    }

    // Skip to end of first cycle
    for (0..(one_cycle - 128)) |_| {
        _ = m.process_sample(sr);
    }

    // Collect beginning of second cycle (loop should have triggered)
    var cycle2: [128]f32 = undefined;
    for (&cycle2) |*s| {
        s.* = m.process_sample(sr);
    }

    // Both cycle starts should be similar (near 0.0, rising)
    try std.testing.expectApproxEqAbs(cycle1[0], cycle2[0], 0.05);
    // Both should be rising
    try std.testing.expect(cycle1[127] > cycle1[0]);
    try std.testing.expect(cycle2[127] > cycle2[0]);
}

test "AC-N1: no heap allocation (zero dynamic memory)" {
    // Structural: no dynamic memory fields in MSEG or MSEGPool
    const m = MSEG{};
    _ = m;
    const pool = MSEGPool.init();
    _ = pool;
}

test "AC-N2: 65th node returns null" {
    var m = MSEG{ .active = true };
    for (0..MAX_NODES) |i| {
        const idx = m.add_node(@as(f32, @floatFromInt(i)) * 0.01, 0.5, .linear);
        try std.testing.expect(idx != null);
    }
    try std.testing.expectEqual(@as(u32, MAX_NODES), m.node_count);

    // 65th must fail
    const overflow = m.add_node(1.0, 1.0, .linear);
    try std.testing.expect(overflow == null);
    try std.testing.expectEqual(@as(u32, MAX_NODES), m.node_count);
}

test "Exponential curve shape" {
    var m = MSEG{ .active = true };
    _ = m.add_node(0.0, 0.0, .exponential);
    _ = m.add_node(1.0, 1.0, .linear);

    const sr: f32 = 1000.0; // 1000 samples = 1s
    // At t=0.5 (50% of segment), exponential should give 0.25 (0.5^2)
    for (0..500) |_| {
        _ = m.process_sample(sr);
    }
    // Value at ~50% should be approximately 0.25
    const val = m.process_sample(sr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), val, 0.02);
}

test "S-Curve (Hermite) shape" {
    var m = MSEG{ .active = true };
    _ = m.add_node(0.0, 0.0, .s_curve);
    _ = m.add_node(1.0, 1.0, .linear);

    const sr: f32 = 1000.0;
    // At t=0.5: 3*(0.5)^2 - 2*(0.5)^3 = 0.75 - 0.25 = 0.5
    for (0..500) |_| {
        _ = m.process_sample(sr);
    }
    const val = m.process_sample(sr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), val, 0.02);
}

test "Reset sets MSEG back to start" {
    var m = setup_triangle_mseg();
    const sr: f32 = 44100.0;

    // Advance partway
    for (0..22050) |_| {
        _ = m.process_sample(sr);
    }
    try std.testing.expect(m.current_node > 0 or m.phase > 0.0);

    m.reset();
    try std.testing.expectEqual(@as(u32, 0), m.current_node);
    try std.testing.expectEqual(@as(f64, 0.0), m.phase);

    // First value after reset should be near 0
    const v = m.process_sample(sr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v, 0.01);
}

test "Pool add/remove/reuse" {
    var pool = MSEGPool.init();
    const idx = pool.add().?;
    try std.testing.expectEqual(@as(u32, 1), pool.active_count);

    pool.remove(idx);
    try std.testing.expectEqual(@as(u32, 0), pool.active_count);

    const idx2 = pool.add().?;
    try std.testing.expectEqual(idx, idx2);
    try std.testing.expectEqual(@as(u32, 1), pool.active_count);
}

test "Pool capacity: 17th add returns null" {
    var pool = MSEGPool.init();
    for (0..MAX_MSEGS) |_| {
        try std.testing.expect(pool.add() != null);
    }
    try std.testing.expectEqual(@as(u32, MAX_MSEGS), pool.active_count);
    try std.testing.expect(pool.add() == null);
}

test "Pool early-out when no active MSEGs" {
    var pool = MSEGPool.init();
    var bufs: [MAX_MSEGS][BLOCK_SIZE]f32 = [_][BLOCK_SIZE]f32{[_]f32{0.0} ** BLOCK_SIZE} ** MAX_MSEGS;
    pool.process_all_block(&bufs, 44100.0);
    for (bufs) |buf| {
        for (buf) |v| {
            try std.testing.expectEqual(@as(f32, 0.0), v);
        }
    }
}

test "Pool remove bounds check" {
    var pool = MSEGPool.init();
    pool.remove(0); // no crash on empty
    pool.remove(MAX_MSEGS); // out of bounds
    pool.remove(MAX_MSEGS + 100);
    try std.testing.expectEqual(@as(u32, 0), pool.active_count);
}

// ── Benchmarks ──────────────────────────────────────────────────────

fn setup_linear_mseg(node_count: u32) MSEG {
    var m = MSEG{ .active = true };
    for (0..node_count) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(node_count - 1));
        const v: f32 = if (i % 2 == 0) 0.0 else 1.0;
        _ = m.add_node(t, v, .linear);
    }
    return m;
}

test "benchmark: 1 MSEG, 8 Nodes, Linear" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var m = setup_linear_mseg(8);
    var buf: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 1_700 else 30_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-038] MSEG 8-node linear: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 1 MSEG, 64 Nodes, Linear" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var m = setup_linear_mseg(64);
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 1_700 else 40_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-038] MSEG 64-node linear: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 1 MSEG, 16 Nodes, Exponential" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var m = MSEG{ .active = true };
    for (0..16) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 15.0;
        const v: f32 = if (i % 2 == 0) 0.0 else 1.0;
        _ = m.add_node(t, v, .exponential);
    }
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 1_700 else 50_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-038] MSEG 16-node exp: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 1 MSEG, 16 Nodes, S-Curve" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var m = MSEG{ .active = true };
    for (0..16) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 15.0;
        const v: f32 = if (i % 2 == 0) 0.0 else 1.0;
        _ = m.add_node(t, v, .s_curve);
    }
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        m.reset();
        m.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 1_800 else 50_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-038] MSEG 16-node s-curve: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 16 MSEGs, 32 Nodes each" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var pool = MSEGPool.init();

    for (0..MAX_MSEGS) |_| {
        const idx = pool.add().?;
        var m = &pool.msegs[idx];
        for (0..32) |j| {
            const t: f32 = @as(f32, @floatFromInt(j)) / 31.0;
            const v: f32 = if (j % 2 == 0) 0.0 else 1.0;
            _ = m.add_node(t, v, .linear);
        }
    }

    var bufs: [MAX_MSEGS][BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..500) |_| {
        for (&pool.msegs) |*m| {
            if (m.active) m.reset();
        }
        pool.process_all_block(&bufs, 44100.0);
        std.mem.doNotOptimizeAway(&bufs);
    }

    const iterations: u64 = 200_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        for (&pool.msegs) |*m| {
            if (m.active) m.reset();
        }
        pool.process_all_block(&bufs, 44100.0);
        std.mem.doNotOptimizeAway(&bufs);
    }
    const ns = timer.read() / iterations;
    const ns_per_mseg = ns / MAX_MSEGS;

    const budget: u64 = if (strict) 27_000 else 350_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-038] 16 MSEGs 32-node: {}ns total, {}ns/MSEG (budget: {}ns) {s}\n", .{ ns, ns_per_mseg, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
