const std = @import("std");

// ── Analog Drift (WP-129) ──────────────────────────────────────────
// Per-voice pitch/phase/cutoff drift for analog character.
// Slow random walk (<1Hz rate), intensity 0–100% controllable.
// SoA-compatible layout, deterministic seeding per voice.
//
// Design: Block-based update — PRNG runs once per block (not per sample).
// process_sample() returns precomputed offsets (zero-overhead per sample).
// At 128 samples/block @ 44.1kHz → 345 updates/sec — perfectly fine for
// sub-Hz drift that changes slowly over seconds.
//
// Usage:
//   var drift: Drift = undefined;
//   drift.init();
//   drift.set_intensity(0.5);
//   drift.update_block(); // once per 128-sample block
//   for (0..128) |_| {
//       const offsets = drift.get_offsets(voice_idx);
//       // offsets.pitch_offset is in cents, etc.
//   }

pub const MAX_VOICES: usize = 64;

// Maximum drift amplitudes at intensity=1.0
pub const max_pitch_drift: f32 = 50.0; // ±50 cents
pub const max_phase_drift: f32 = 0.1; // ±0.1 radians
pub const max_cutoff_drift: f32 = 2.0; // ±2 semitones

// Random walk step size — controls drift rate.
// At 345 blocks/sec (44.1kHz / 128): RMS displacement after 1s ≈ step * sqrt(345) ≈ 0.019
// → full range traversal ~minutes → effective frequency ≪ 1Hz.
const walk_step: f32 = 0.001;

pub const DriftOffsets = struct {
    pitch_offset: f32 = 0.0, // cents
    phase_offset: f32 = 0.0, // radians
    cutoff_offset: f32 = 0.0, // semitones
};

pub const DriftState = struct {
    value: f32 = 0.0,
    rng: u32 = 1,

    /// Advance the random walk by one block step.
    pub inline fn step(self: *DriftState) void {
        // LCG PRNG (Numerical Recipes, period 2^32)
        self.rng = self.rng *% 1664525 +% 1013904223;

        // Bit-hack float: top 23 bits as mantissa → [1.0, 2.0), shift to [-0.5, 0.5)
        const bits = @as(u32, 0x3f800000) | (self.rng >> 9);
        const unit = @as(f32, @bitCast(bits)) - 1.5;

        // Random walk: accumulate step, branchless clamp (minss/maxss)
        self.value = @min(@as(f32, 1.0), @max(@as(f32, -1.0), self.value + unit * (2.0 * walk_step)));
    }
};

pub const Drift = struct {
    states: [MAX_VOICES]DriftState = [_]DriftState{.{}} ** MAX_VOICES,
    offsets: [MAX_VOICES]DriftOffsets = [_]DriftOffsets{.{}} ** MAX_VOICES,
    intensity: f32 = 0.0,
    // Pre-scaled intensity * max_drift (set via set_intensity)
    pitch_scale: f32 = 0.0,
    phase_scale: f32 = 0.0,
    cutoff_scale: f32 = 0.0,

    /// Initialize all voice drift states with deterministic per-voice seeds.
    pub fn init(self: *Drift) void {
        for (0..MAX_VOICES) |i| {
            const seed: u32 = @truncate((@as(u64, i) +% 1) *% 2654435761);
            self.states[i] = .{ .value = 0.0, .rng = seed | 1 };
            self.offsets[i] = .{};
        }
        self.intensity = 0.0;
        self.pitch_scale = 0.0;
        self.phase_scale = 0.0;
        self.cutoff_scale = 0.0;
    }

    /// Set drift intensity (0..1). Pre-computes scaling factors.
    pub fn set_intensity(self: *Drift, intensity: f32) void {
        self.intensity = intensity;
        self.pitch_scale = intensity * max_pitch_drift;
        self.phase_scale = intensity * max_phase_drift;
        self.cutoff_scale = intensity * max_cutoff_drift;
    }

    /// Update drift for all voices. Call once per audio block.
    /// Runs PRNG + random walk for each voice, precomputes offsets.
    pub fn update_block(self: *Drift) void {
        if (self.intensity == 0.0) {
            for (&self.offsets) |*o| o.* = .{};
            return;
        }
        for (0..MAX_VOICES) |i| {
            self.states[i].step();
            const v = self.states[i].value;
            self.offsets[i] = .{
                .pitch_offset = v * self.pitch_scale,
                .phase_offset = v * self.phase_scale,
                .cutoff_offset = v * self.cutoff_scale,
            };
        }
    }

    /// Get precomputed drift offsets for a voice. Zero-overhead per sample.
    /// Call update_block() once before processing the block.
    pub inline fn get_offsets(self: *const Drift, voice_idx: u6) DriftOffsets {
        return self.offsets[voice_idx];
    }

    /// Convenience: process_sample compatible API (delegates to get_offsets).
    pub inline fn process_sample(self: *const Drift, voice_idx: u6) DriftOffsets {
        return self.offsets[voice_idx];
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

fn run_drift_blocks(drift: *Drift, blocks: usize) void {
    for (0..blocks) |_| drift.update_block();
}

test "AC-1: 16 voices with drift produce different pitches" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(0.5);

    // Run 1000 blocks to let random walks diverge
    run_drift_blocks(&drift, 1000);

    var pitches: [16]f32 = undefined;
    for (0..16) |v| {
        pitches[v] = drift.get_offsets(@intCast(v)).pitch_offset;
    }

    var all_same = true;
    for (1..16) |v| {
        if (pitches[v] != pitches[0]) {
            all_same = false;
            break;
        }
    }
    try std.testing.expect(!all_same);
}

test "AC-2: intensity=0 produces all offsets exactly 0.0" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(0.0);

    for (0..128) |_| {
        drift.update_block();
        for (0..MAX_VOICES) |v| {
            const o = drift.get_offsets(@intCast(v));
            try std.testing.expectEqual(@as(f32, 0.0), o.pitch_offset);
            try std.testing.expectEqual(@as(f32, 0.0), o.phase_offset);
            try std.testing.expectEqual(@as(f32, 0.0), o.cutoff_offset);
        }
    }
}

test "AC-3: intensity=1 offsets within defined ranges" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(1.0);

    for (0..50000) |_| {
        drift.update_block();
        for (0..MAX_VOICES) |v| {
            const o = drift.get_offsets(@intCast(v));
            try std.testing.expect(o.pitch_offset >= -max_pitch_drift and
                o.pitch_offset <= max_pitch_drift);
            try std.testing.expect(o.phase_offset >= -max_phase_drift and
                o.phase_offset <= max_phase_drift);
            try std.testing.expect(o.cutoff_offset >= -max_cutoff_drift and
                o.cutoff_offset <= max_cutoff_drift);
        }
    }
}

test "AC-4: drift rate < 1Hz (slow change)" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(1.0);

    // Verify drift is slow: average change per block is tiny.
    // At 345 blocks/sec, max step per block = walk_step * max_pitch_drift ≈ 0.05 cents.
    const blocks_per_sec: usize = 345;
    var prev_offset = blk: {
        drift.update_block();
        break :blk drift.get_offsets(0).pitch_offset;
    };
    var total_change: f64 = 0.0;

    for (0..blocks_per_sec) |_| {
        drift.update_block();
        const curr = drift.get_offsets(0).pitch_offset;
        total_change += @abs(@as(f64, curr) - @as(f64, prev_offset));
        prev_offset = curr;
    }

    const avg_change = total_change / @as(f64, blocks_per_sec);
    // Sub-Hz drift: average change per block should be ≪ total range (±50 cents)
    try std.testing.expect(avg_change < 0.1);
    try std.testing.expect(total_change < 100.0);
}

test "AC-N1: voice_idx=63 (max) no out-of-bounds" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(1.0);

    for (0..1000) |_| {
        drift.update_block();
        const o = drift.get_offsets(63);
        try std.testing.expect(o.pitch_offset >= -max_pitch_drift and
            o.pitch_offset <= max_pitch_drift);
    }
}

test "deterministic: same seed produces same sequence" {
    var d1: Drift = undefined;
    d1.init();
    d1.set_intensity(0.8);

    var d2: Drift = undefined;
    d2.init();
    d2.set_intensity(0.8);

    for (0..500) |_| {
        d1.update_block();
        d2.update_block();
        const a = d1.get_offsets(7);
        const b = d2.get_offsets(7);
        try std.testing.expectEqual(a.pitch_offset, b.pitch_offset);
        try std.testing.expectEqual(a.phase_offset, b.phase_offset);
        try std.testing.expectEqual(a.cutoff_offset, b.cutoff_offset);
    }
}

test "PRNG distribution: values spread across range" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(1.0);

    var min_val: f32 = 1.0;
    var max_val: f32 = -1.0;
    for (0..200_000) |_| {
        drift.update_block();
        const v = drift.get_offsets(0).pitch_offset / max_pitch_drift;
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }

    const range = max_val - min_val;
    try std.testing.expect(range > 0.15);
}

test "benchmark: drift 128 samples, 1 voice, all offsets" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(0.75);

    // Warmup
    run_drift_blocks(&drift, 100);

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        drift.update_block();
        var sum: f32 = 0;
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            const o = drift.process_sample(0);
            sum += o.pitch_offset + o.phase_offset + o.cutoff_offset;
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));

    const threshold = if (@import("builtin").mode == .Debug) 50000.0 else 150.0;

    std.debug.print("\n  [WP-129] Drift 128 samples, 1 voice, all offsets — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.2}ns/sample\n", .{ median_ns, median_ns / 128.0 });
    std.debug.print("    Threshold: < {d:.0}ns\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: drift 128 samples, 1 voice, pitch only" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(0.75);

    run_drift_blocks(&drift, 100);

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        drift.update_block();
        var sum: f32 = 0;
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            sum += drift.process_sample(0).pitch_offset;
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));

    const threshold = if (@import("builtin").mode == .Debug) 30000.0 else 80.0;

    std.debug.print("\n  [WP-129] Drift 128 samples, 1 voice, pitch only — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.2}ns/sample\n", .{ median_ns, median_ns / 128.0 });
    std.debug.print("    Threshold: < {d:.0}ns\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: drift 64 voices, 128 samples each" {
    var drift: Drift = undefined;
    drift.init();
    drift.set_intensity(0.75);

    run_drift_blocks(&drift, 100);

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        drift.update_block();
        var sum: f32 = 0;
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            for (0..MAX_VOICES) |v| {
                sum += drift.process_sample(@intCast(v)).pitch_offset;
            }
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_voice = median_ns / @as(f64, MAX_VOICES);

    const threshold = if (@import("builtin").mode == .Debug) 2000000.0 else 8000.0;

    std.debug.print("\n  [WP-129] Drift 64 voices x 128 samples — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.1}ns/voice, {d:.2}ns/voice/sample\n", .{
        median_ns,
        per_voice,
        per_voice / 128.0,
    });
    std.debug.print("    Threshold: < {d:.0}ns total, < 125ns/voice\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
    try std.testing.expect(per_voice < if (@import("builtin").mode == .Debug) 30000.0 else 125.0);
}
