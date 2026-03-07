const std = @import("std");
const builtin = @import("builtin");
const voice = @import("voice.zig");

// ── Layer-System (WP-040) ─────────────────────────────────────────
// 1-4 independent synthesizer layers with dynamic voice budget.
// Total voice budget: 64 (MAX_VOICES), distributed evenly across
// active layers with remainder to layer 0.
// Zero heap allocation — all state is preallocated inline.

pub const BLOCK_SIZE: u32 = 128;

pub const Layer = struct {
    engine_type: voice.EngineType = .virtual_analog,
    filter_type: voice.FilterType = .low_pass,
    voice_budget: u32 = 0,
    volume: f32 = 1.0,
    pan: f32 = 0.0,
    active: bool = false,
};

pub const LayerManager = struct {
    const Self = @This();

    layers: [voice.MAX_LAYERS]Layer,
    active_count: u32,

    pub fn init() Self {
        var self: Self = .{
            .layers = [_]Layer{.{}} ** voice.MAX_LAYERS,
            .active_count = 1,
        };
        self.layers[0].active = true;
        self.layers[0].voice_budget = @intCast(voice.MAX_VOICES);
        return self;
    }

    /// Set number of active layers (clamped to 1-4).
    /// Distributes voice budget evenly; remainder goes to layer 0.
    pub fn set_layer_count(self: *Self, count: u32) void {
        const n = std.math.clamp(count, 1, @as(u32, voice.MAX_LAYERS));
        const total: u32 = @intCast(voice.MAX_VOICES);
        const per_layer = total / n;
        const remainder = total % n;

        for (&self.layers, 0..) |*layer, idx| {
            if (idx < n) {
                layer.active = true;
                layer.voice_budget = per_layer + if (idx == 0) remainder else 0;
            } else {
                layer.active = false;
                layer.voice_budget = 0;
            }
        }
        self.active_count = n;
    }

    /// Sum of all voice budgets. Invariant: always equals MAX_VOICES.
    pub fn get_voice_budget_sum(self: *const Self) u32 {
        var sum: u32 = 0;
        for (self.layers) |layer| {
            sum += layer.voice_budget;
        }
        return sum;
    }

    /// Set engine type for a specific layer.
    pub fn set_engine_type(self: *Self, layer_idx: usize, engine_type: voice.EngineType) void {
        if (layer_idx < voice.MAX_LAYERS) {
            self.layers[layer_idx].engine_type = engine_type;
        }
    }

    /// Set volume for a specific layer (clamped to 0.0-1.0).
    pub fn set_volume(self: *Self, layer_idx: usize, vol: f32) void {
        if (layer_idx < voice.MAX_LAYERS) {
            self.layers[layer_idx].volume = std.math.clamp(vol, 0.0, 1.0);
        }
    }

    /// Set pan for a specific layer (clamped to -1.0 to 1.0).
    pub fn set_pan(self: *Self, layer_idx: usize, p: f32) void {
        if (layer_idx < voice.MAX_LAYERS) {
            self.layers[layer_idx].pan = std.math.clamp(p, -1.0, 1.0);
        }
    }

    /// Mix multiple layer buffers into stereo output with volume and pan.
    /// Uses constant-power panning: L = cos(angle), R = sin(angle).
    pub fn mix_layers(self: *const Self, layer_bufs: []const [BLOCK_SIZE]f32, out_left: *[BLOCK_SIZE]f32, out_right: *[BLOCK_SIZE]f32) void {
        @memset(out_left, 0.0);
        @memset(out_right, 0.0);

        for (self.layers, 0..) |layer, idx| {
            if (!layer.active or idx >= layer_bufs.len) continue;

            // Constant-power pan: angle = (pan + 1) * pi/4
            const angle = (layer.pan + 1.0) * (std.math.pi / 4.0);
            const gain_l = layer.volume * @cos(angle);
            const gain_r = layer.volume * @sin(angle);

            const buf = &layer_bufs[idx];
            for (out_left, out_right, buf) |*ol, *or_, *s| {
                ol.* += s.* * gain_l;
                or_.* += s.* * gain_r;
            }
        }
    }

    /// Crossfade between two layers over a block. factor: 0.0 = layer A, 1.0 = layer B.
    pub fn crossfade(buf_a: *const [BLOCK_SIZE]f32, buf_b: *const [BLOCK_SIZE]f32, factor: f32, out: *[BLOCK_SIZE]f32) void {
        const f_clamped = std.math.clamp(factor, 0.0, 1.0);
        const inv = 1.0 - f_clamped;
        for (out, buf_a, buf_b) |*o, *a, *b| {
            o.* = a.* * inv + b.* * f_clamped;
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: 4 layers with 16 voices each = 64 total" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(4);

    try std.testing.expectEqual(@as(u32, 4), mgr.active_count);
    for (mgr.layers, 0..) |layer, idx| {
        if (idx < 4) {
            try std.testing.expect(layer.active);
            try std.testing.expectEqual(@as(u32, 16), layer.voice_budget);
        }
    }
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
}

test "AC-2: 1 layer with 64 voices" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(1);

    try std.testing.expectEqual(@as(u32, 1), mgr.active_count);
    try std.testing.expect(mgr.layers[0].active);
    try std.testing.expectEqual(@as(u32, 64), mgr.layers[0].voice_budget);
    try std.testing.expect(!mgr.layers[1].active);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
}

test "AC-3: 2 layers with 32 voices each" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(2);

    try std.testing.expectEqual(@as(u32, 2), mgr.active_count);
    try std.testing.expectEqual(@as(u32, 32), mgr.layers[0].voice_budget);
    try std.testing.expectEqual(@as(u32, 32), mgr.layers[1].voice_budget);
    try std.testing.expect(!mgr.layers[2].active);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
}

test "AC-N1: set_layer_count(0) clamps to 1, set_layer_count(5) clamps to 4" {
    var mgr = LayerManager.init();

    mgr.set_layer_count(0);
    try std.testing.expectEqual(@as(u32, 1), mgr.active_count);
    try std.testing.expectEqual(@as(u32, 64), mgr.layers[0].voice_budget);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());

    mgr.set_layer_count(5);
    try std.testing.expectEqual(@as(u32, 4), mgr.active_count);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());

    mgr.set_layer_count(100);
    try std.testing.expectEqual(@as(u32, 4), mgr.active_count);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
}

test "3 layers: 22+21+21 = 64 (remainder to layer 0)" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(3);

    try std.testing.expectEqual(@as(u32, 3), mgr.active_count);
    try std.testing.expectEqual(@as(u32, 22), mgr.layers[0].voice_budget);
    try std.testing.expectEqual(@as(u32, 21), mgr.layers[1].voice_budget);
    try std.testing.expectEqual(@as(u32, 21), mgr.layers[2].voice_budget);
    try std.testing.expect(!mgr.layers[3].active);
    try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
}

test "init defaults: 1 layer, 64 voices, virtual_analog" {
    const mgr = LayerManager.init();
    try std.testing.expectEqual(@as(u32, 1), mgr.active_count);
    try std.testing.expect(mgr.layers[0].active);
    try std.testing.expectEqual(@as(u32, 64), mgr.layers[0].voice_budget);
    try std.testing.expectEqual(voice.EngineType.virtual_analog, mgr.layers[0].engine_type);
    try std.testing.expectEqual(@as(f32, 1.0), mgr.layers[0].volume);
    try std.testing.expectEqual(@as(f32, 0.0), mgr.layers[0].pan);
}

test "set_engine_type changes engine per layer" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(2);
    mgr.set_engine_type(0, .fm);
    mgr.set_engine_type(1, .wavetable);
    try std.testing.expectEqual(voice.EngineType.fm, mgr.layers[0].engine_type);
    try std.testing.expectEqual(voice.EngineType.wavetable, mgr.layers[1].engine_type);
}

test "set_volume and set_pan clamp correctly" {
    var mgr = LayerManager.init();
    mgr.set_volume(0, 1.5);
    try std.testing.expectEqual(@as(f32, 1.0), mgr.layers[0].volume);
    mgr.set_volume(0, -0.5);
    try std.testing.expectEqual(@as(f32, 0.0), mgr.layers[0].volume);
    mgr.set_pan(0, 2.0);
    try std.testing.expectEqual(@as(f32, 1.0), mgr.layers[0].pan);
    mgr.set_pan(0, -3.0);
    try std.testing.expectEqual(@as(f32, -1.0), mgr.layers[0].pan);
}

test "mix_layers produces stereo output" {
    var mgr = LayerManager.init();
    mgr.set_layer_count(2);
    mgr.set_volume(0, 1.0);
    mgr.set_pan(0, 0.0); // center
    mgr.set_volume(1, 1.0);
    mgr.set_pan(1, 0.0); // center

    var buf0: [BLOCK_SIZE]f32 = undefined;
    var buf1: [BLOCK_SIZE]f32 = undefined;
    @memset(&buf0, 0.5);
    @memset(&buf1, 0.3);

    const bufs = [_][BLOCK_SIZE]f32{ buf0, buf1 };
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;
    mgr.mix_layers(&bufs, &out_l, &out_r);

    // Center pan: L and R should be equal
    const expected = (0.5 + 0.3) * @cos(std.math.pi / 4.0);
    try std.testing.expectApproxEqAbs(expected, out_l[0], 0.001);
    try std.testing.expectApproxEqAbs(expected, out_r[0], 0.001);
}

test "crossfade blends two buffers" {
    var buf_a: [BLOCK_SIZE]f32 = undefined;
    var buf_b: [BLOCK_SIZE]f32 = undefined;
    @memset(&buf_a, 1.0);
    @memset(&buf_b, 0.0);

    var out: [BLOCK_SIZE]f32 = undefined;
    LayerManager.crossfade(&buf_a, &buf_b, 0.5, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);

    LayerManager.crossfade(&buf_a, &buf_b, 0.0, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.001);

    LayerManager.crossfade(&buf_a, &buf_b, 1.0, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 0.001);
}

test "switching layer count preserves budget invariant" {
    var mgr = LayerManager.init();
    const counts = [_]u32{ 1, 2, 3, 4, 3, 2, 1, 4, 1 };
    for (counts) |c| {
        mgr.set_layer_count(c);
        try std.testing.expectEqual(@as(u32, 64), mgr.get_voice_budget_sum());
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: 1 layer dispatch" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var mgr = LayerManager.init();
    mgr.set_layer_count(1);

    var buf: [1][BLOCK_SIZE]f32 = undefined;
    @memset(&buf[0], 0.5);
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        mgr.mix_layers(&buf, &out_l, &out_r);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        mgr.mix_layers(&buf, &out_l, &out_r);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 500 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-040] 1 layer dispatch: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 4 layer dispatch" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var mgr = LayerManager.init();
    mgr.set_layer_count(4);

    var bufs: [4][BLOCK_SIZE]f32 = undefined;
    for (&bufs) |*b| @memset(b, 0.5);
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        mgr.mix_layers(&bufs, &out_l, &out_r);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        mgr.mix_layers(&bufs, &out_l, &out_r);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 2_000 else 40_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-040] 4 layer dispatch: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 4 layer mix to stereo" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var mgr = LayerManager.init();
    mgr.set_layer_count(4);
    mgr.set_pan(0, -1.0);
    mgr.set_pan(1, -0.3);
    mgr.set_pan(2, 0.3);
    mgr.set_pan(3, 1.0);

    var bufs: [4][BLOCK_SIZE]f32 = undefined;
    for (&bufs, 0..) |*b, i| {
        const val: f32 = @as(f32, @floatFromInt(i + 1)) * 0.2;
        @memset(b, val);
    }
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        mgr.mix_layers(&bufs, &out_l, &out_r);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        mgr.mix_layers(&bufs, &out_l, &out_r);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 2_000 else 40_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-040] 4 layer mix stereo: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: layer crossfade" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var buf_a: [BLOCK_SIZE]f32 = undefined;
    var buf_b: [BLOCK_SIZE]f32 = undefined;
    @memset(&buf_a, 0.7);
    @memset(&buf_b, 0.3);
    var out: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        LayerManager.crossfade(&buf_a, &buf_b, 0.5, &out);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        LayerManager.crossfade(&buf_a, &buf_b, 0.5, &out);
        std.mem.doNotOptimizeAway(&out);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 500 else 10_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-040] layer crossfade: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: voice rebalance" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var mgr = LayerManager.init();

    // Warmup
    for (0..1000) |_| {
        mgr.set_layer_count(1);
        mgr.set_layer_count(4);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        mgr.set_layer_count(4);
        std.mem.doNotOptimizeAway(&mgr);
        mgr.set_layer_count(1);
        std.mem.doNotOptimizeAway(&mgr);
    }
    const ns = timer.read() / (iterations * 2); // 2 rebalances per iteration

    const budget: u64 = if (strict) 200 else 5_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-040] voice rebalance: {}ns/call (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
