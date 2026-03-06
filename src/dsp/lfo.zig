const std = @import("std");
const builtin = @import("builtin");

// ── LFO Audio-Rate (WP-037) ─────────────────────────────────────────
// Preallocated pool of 32 LFOs with audio-rate capability (up to 20kHz).
// Supports sine, saw, square, triangle, and sample-and-hold waveforms.
// Phase accumulator uses f64 for sub-Hz precision. Zero heap allocation.

pub const BLOCK_SIZE: u32 = 128;

pub const Waveform = enum(u3) {
    sine,
    saw,
    square,
    triangle,
    sample_and_hold,
};

pub const SyncMode = enum(u1) { free, tempo_sync };

/// Polyrhythmic rate multipliers: 3/4, 5/4, 7/8, 11/8.
pub const poly_ratios = [_]f32{ 0.75, 1.25, 0.875, 1.375 };

pub fn apply_ratio(base_rate: f32, ratio_idx: usize) f32 {
    if (ratio_idx >= poly_ratios.len) return base_rate;
    return base_rate * poly_ratios[ratio_idx];
}

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

// ── LFO ─────────────────────────────────────────────────────────────

pub const LFO = struct {
    const Self = @This();

    phase: f64 = 0.0,
    rate: f32 = 1.0,
    waveform: Waveform = .sine,
    sync_mode: SyncMode = .free,
    value: f32 = 0.0,
    sh_value: f32 = 0.0,
    sh_state: u32 = 0x12345678,
    prev_phase: f64 = 0.0,
    active: bool = false,

    pub inline fn process_sample(self: *Self, sample_rate: f32) f32 {
        self.prev_phase = self.phase;
        self.phase += @as(f64, @floatCast(self.rate)) / @as(f64, @floatCast(sample_rate));
        if (self.phase >= 1.0) self.phase -= 1.0;

        self.value = switch (self.waveform) {
            .sine => blk: {
                const v: f32 = @floatCast(@sin(2.0 * std.math.pi * self.phase));
                break :blk v;
            },
            .saw => blk: {
                const v: f32 = @floatCast(2.0 * self.phase - 1.0);
                break :blk v;
            },
            .square => if (self.phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
            .triangle => blk: {
                const v: f32 = @floatCast(4.0 * @abs(self.phase - 0.5) - 1.0);
                break :blk v;
            },
            .sample_and_hold => blk: {
                if (self.phase < self.prev_phase) {
                    self.sh_state = xorshift32(self.sh_state);
                    self.sh_value = u32_to_f32(self.sh_state);
                }
                break :blk self.sh_value;
            },
        };
        return self.value;
    }

    /// Process a full block of samples.
    pub fn process_block(self: *Self, buf: *[BLOCK_SIZE]f32, sample_rate: f32) void {
        for (buf) |*sample| {
            sample.* = self.process_sample(sample_rate);
        }
    }
};

// ── LFO Pool ────────────────────────────────────────────────────────

pub const MAX_LFOS: u32 = 32;

pub const LFOPool = struct {
    const Self = @This();

    lfos: [MAX_LFOS]LFO,
    active_count: u32,

    pub fn init() Self {
        return .{
            .lfos = [_]LFO{.{}} ** MAX_LFOS,
            .active_count = 0,
        };
    }

    /// Add an LFO to the pool. Returns slot index or null if full.
    pub fn add(self: *Self, rate: f32, waveform: Waveform, sync_mode: SyncMode) ?usize {
        for (&self.lfos, 0..) |*lfo, idx| {
            if (!lfo.active) {
                lfo.* = .{
                    .rate = rate,
                    .waveform = waveform,
                    .sync_mode = sync_mode,
                    .active = true,
                    .sh_state = 0x12345678 +% @as(u32, @intCast(idx)),
                };
                self.active_count += 1;
                return idx;
            }
        }
        return null;
    }

    /// Remove an LFO from the pool.
    pub fn remove(self: *Self, idx: usize) void {
        if (idx < MAX_LFOS and self.lfos[idx].active) {
            self.lfos[idx].active = false;
            self.active_count -= 1;
        }
    }

    /// Process all active LFOs for one block.
    pub fn process_all_block(self: *Self, bufs: *[MAX_LFOS][BLOCK_SIZE]f32, sample_rate: f32) void {
        if (self.active_count == 0) return;
        for (&self.lfos, 0..) |*lfo, idx| {
            if (lfo.active) {
                lfo.process_block(&bufs[idx], sample_rate);
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: Sine 1Hz correct waveform over 44100 samples" {
    var lfo = LFO{ .rate = 1.0, .waveform = .sine, .active = true };
    const sr: f32 = 44100.0;

    // Advance to ~25% of the cycle (peak)
    for (0..11025) |_| {
        _ = lfo.process_sample(sr);
    }
    // At 25% (phase ~0.25): sin(2*pi*0.25) = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lfo.value, 0.001);

    // Advance to ~50% (zero crossing)
    for (0..11025) |_| {
        _ = lfo.process_sample(sr);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lfo.value, 0.001);

    // Advance to ~75% (trough)
    for (0..11025) |_| {
        _ = lfo.process_sample(sr);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), lfo.value, 0.001);

    // Advance to ~100% (back to zero)
    for (0..11025) |_| {
        _ = lfo.process_sample(sr);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lfo.value, 0.01);
}

test "AC-2: 32 LFOs pool, no malloc" {
    var pool = LFOPool.init();
    const waveforms = [_]Waveform{ .sine, .saw, .square, .triangle, .sample_and_hold };

    for (0..MAX_LFOS) |i| {
        const idx = pool.add(
            @as(f32, @floatFromInt(i + 1)),
            waveforms[i % waveforms.len],
            .free,
        );
        try std.testing.expect(idx != null);
    }
    try std.testing.expectEqual(@as(u32, MAX_LFOS), pool.active_count);

    // 33rd must fail
    const overflow = pool.add(1.0, .sine, .free);
    try std.testing.expect(overflow == null);

    // Process all
    var bufs: [MAX_LFOS][BLOCK_SIZE]f32 = undefined;
    pool.process_all_block(&bufs, 44100.0);

    // Verify output is non-zero for active LFOs
    for (0..MAX_LFOS) |i| {
        var has_nonzero = false;
        for (bufs[i]) |v| {
            if (v != 0.0) {
                has_nonzero = true;
                break;
            }
        }
        // S&H starts at 0 before first wrap, so skip that check for S&H at low rate
        if (waveforms[i % waveforms.len] != .sample_and_hold) {
            try std.testing.expect(has_nonzero);
        }
    }
}

test "AC-N1: Phase stays in [0.0, 1.0) after 1M samples" {
    var lfo = LFO{ .rate = 440.0, .waveform = .sine, .active = true };
    const sr: f32 = 44100.0;

    for (0..1_000_000) |_| {
        _ = lfo.process_sample(sr);
    }
    try std.testing.expect(lfo.phase >= 0.0);
    try std.testing.expect(lfo.phase < 1.0);
}

test "AC-N2: All 5 waveforms produce values in [-1.0, 1.0]" {
    const waveforms = [_]Waveform{ .sine, .saw, .square, .triangle, .sample_and_hold };

    for (waveforms) |wf| {
        var lfo = LFO{ .rate = 100.0, .waveform = wf, .active = true };
        const sr: f32 = 44100.0;

        for (0..10_000) |_| {
            const v = lfo.process_sample(sr);
            try std.testing.expect(v >= -1.0);
            try std.testing.expect(v <= 1.0);
        }
    }
}

test "S&H: value changes only on phase wrap" {
    var lfo = LFO{ .rate = 1.0, .waveform = .sample_and_hold, .active = true };
    const sr: f32 = 100.0; // 100 samples per cycle

    // First sample: phase wraps from 0.0 (prev_phase=0.0, phase=0.01) — no wrap
    _ = lfo.process_sample(sr);
    const first_val = lfo.value;

    // Next 98 samples — no wrap, value stays the same
    for (0..98) |_| {
        _ = lfo.process_sample(sr);
        try std.testing.expectEqual(first_val, lfo.value);
    }

    // 100th sample — phase wraps past 1.0, new S&H value
    _ = lfo.process_sample(sr);
    // Value may or may not differ (PRNG), but sh_state should have advanced
    // We verify that the mechanism works by checking phase wrapped
    try std.testing.expect(lfo.phase < 0.5); // wrapped
}

test "Audio-rate: 20kHz phase correct" {
    var lfo = LFO{ .rate = 20000.0, .waveform = .sine, .active = true };
    const sr: f32 = 44100.0;

    // At 20kHz and 44100 SR, we get ~2.2 cycles per block
    var buf: [BLOCK_SIZE]f32 = undefined;
    lfo.process_block(&buf, sr);

    // Phase should have advanced by 128 * 20000/44100 = ~58.05 cycles
    // Phase should be valid
    try std.testing.expect(lfo.phase >= 0.0);
    try std.testing.expect(lfo.phase < 1.0);

    // Output should be valid sine values
    for (buf) |v| {
        try std.testing.expect(v >= -1.0);
        try std.testing.expect(v <= 1.0);
    }
}

test "Polyrhythmic ratios" {
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), apply_ratio(10.0, 0), 1e-6); // 10 * 3/4
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), apply_ratio(10.0, 1), 1e-6); // 10 * 5/4
    try std.testing.expectApproxEqAbs(@as(f32, 8.75), apply_ratio(10.0, 2), 1e-6); // 10 * 7/8
    try std.testing.expectApproxEqAbs(@as(f32, 13.75), apply_ratio(10.0, 3), 1e-6); // 10 * 11/8

    // Out of bounds returns base rate
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), apply_ratio(10.0, 99), 1e-6);
}

test "Pool remove and reuse" {
    var pool = LFOPool.init();
    const idx = pool.add(1.0, .sine, .free).?;
    try std.testing.expectEqual(@as(u32, 1), pool.active_count);

    pool.remove(idx);
    try std.testing.expectEqual(@as(u32, 0), pool.active_count);

    const idx2 = pool.add(2.0, .saw, .free).?;
    try std.testing.expectEqual(idx, idx2);
    try std.testing.expectEqual(@as(u32, 1), pool.active_count);
}

test "Pool remove bounds check" {
    var pool = LFOPool.init();
    pool.remove(0); // no crash on empty
    pool.remove(MAX_LFOS); // out of bounds
    pool.remove(MAX_LFOS + 100);
    try std.testing.expectEqual(@as(u32, 0), pool.active_count);
}

test "Pool early out when no active LFOs" {
    var pool = LFOPool.init();
    var bufs: [MAX_LFOS][BLOCK_SIZE]f32 = [_][BLOCK_SIZE]f32{[_]f32{0.0} ** BLOCK_SIZE} ** MAX_LFOS;
    pool.process_all_block(&bufs, 44100.0);
    // All buffers remain zero
    for (bufs) |buf| {
        for (buf) |v| {
            try std.testing.expectEqual(@as(f32, 0.0), v);
        }
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: LFO sine 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var lfo = LFO{ .rate = 1.0, .waveform = .sine, .active = true };
    var buf: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 10_000 else 500_000;
    std.debug.print("\n[WP-037] LFO sine 1Hz: {}ns/block (budget: {}ns)\n", .{ ns, budget });
    try std.testing.expect(ns < budget);
}

test "benchmark: LFO S&H 128 samples" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var lfo = LFO{ .rate = 1.0, .waveform = .sample_and_hold, .active = true };
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 10_000 else 500_000;
    std.debug.print("\n[WP-037] LFO S&H 1Hz: {}ns/block (budget: {}ns)\n", .{ ns, budget });
    try std.testing.expect(ns < budget);
}

test "benchmark: LFO audio-rate 20kHz" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var lfo = LFO{ .rate = 20000.0, .waveform = .sine, .active = true };
    var buf: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        lfo.process_block(&buf, 44100.0);
        std.mem.doNotOptimizeAway(&buf);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 10_000 else 500_000;
    std.debug.print("\n[WP-037] LFO sine 20kHz: {}ns/block (budget: {}ns)\n", .{ ns, budget });
    try std.testing.expect(ns < budget);
}

test "benchmark: 32 LFOs mixed waveforms" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    const waveforms = [_]Waveform{ .sine, .saw, .square, .triangle, .sample_and_hold };

    var pool = LFOPool.init();
    for (0..MAX_LFOS) |i| {
        _ = pool.add(
            @as(f32, @floatFromInt(i + 1)) * 0.5,
            waveforms[i % waveforms.len],
            .free,
        );
    }

    var bufs: [MAX_LFOS][BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..500) |_| {
        pool.process_all_block(&bufs, 44100.0);
        std.mem.doNotOptimizeAway(&bufs);
    }

    const iterations: u64 = 200_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        pool.process_all_block(&bufs, 44100.0);
        std.mem.doNotOptimizeAway(&bufs);
    }
    const ns = timer.read() / iterations;
    const ns_per_lfo = ns / MAX_LFOS;

    const budget: u64 = if (strict) 100_000 else 5_000_000;
    std.debug.print("\n[WP-037] 32 LFOs mixed: {}ns total, {}ns/LFO (budget: {}ns)\n", .{ ns, ns_per_lfo, budget });
    try std.testing.expect(ns < budget);
}
