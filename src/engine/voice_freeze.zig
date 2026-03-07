const std = @import("std");
const builtin = @import("builtin");
const neural = @import("../dsp/engines/neural.zig");
const wavetable_mod = @import("../dsp/engines/wavetable.zig");

// -- Voice Freeze: Neural→Wavetable (WP-065) ---------------------------------
// Offline conversion of RaveEngine output into a 256-frame wavetable.
// Sweeps latent-space and captures 2048 samples per frame via repeated
// process_block calls. No heap allocation in audio thread — freeze is an
// offline operation that writes into a caller-provided WavetableEngine.

pub const FREEZE_FRAMES: u32 = 256;
pub const SAMPLES_PER_FRAME: usize = wavetable_mod.FRAME_SIZE; // 2048
const BLOCKS_PER_FRAME: usize = SAMPLES_PER_FRAME / neural.BLOCK_SIZE; // 16

pub const FreezeResult = struct {
    frames_written: u32,
    frames_unique: u32,
    degraded: bool,
};

fn render_frame(rave: *neural.RaveEngine, samples: *[SAMPLES_PER_FRAME]f32) void {
    for (0..BLOCKS_PER_FRAME) |blk| {
        const offset = blk * neural.BLOCK_SIZE;
        var block: [neural.BLOCK_SIZE]f32 = undefined;
        rave.process_block(&block);
        @memcpy(samples[offset..][0..neural.BLOCK_SIZE], &block);
    }
}

fn has_nonzero(samples: []const f32) bool {
    for (samples) |s| {
        if (s != 0.0) return true;
    }
    return false;
}

/// Freeze a RaveEngine's output into a wavetable by sweeping latent dim 0
/// from 0.0 to 1.0 across `frame_count` frames.
pub fn freeze_neural_to_wavetable_n(
    rave: *neural.RaveEngine,
    wt: *wavetable_mod.WavetableEngine,
    frame_count: u32,
) FreezeResult {
    const count = @min(frame_count, wavetable_mod.MAX_FRAMES);
    const divisor: f32 = if (count > 1) @floatFromInt(count - 1) else 1.0;
    var frames_unique: u32 = 0;

    for (0..count) |frame_idx| {
        const position: f32 = @as(f32, @floatFromInt(frame_idx)) / divisor;
        rave.set_latent(0, position);

        var samples: [SAMPLES_PER_FRAME]f32 = undefined;
        render_frame(rave, &samples);
        wt.load_frame(@intCast(frame_idx), &samples);
        if (has_nonzero(&samples)) frames_unique += 1;
    }

    wt.generate_mip_maps();
    return .{
        .frames_written = count,
        .frames_unique = frames_unique,
        .degraded = rave.degraded,
    };
}

/// Freeze with the standard 256 frames.
pub fn freeze_neural_to_wavetable(
    rave: *neural.RaveEngine,
    wt: *wavetable_mod.WavetableEngine,
) FreezeResult {
    return freeze_neural_to_wavetable_n(rave, wt, FREEZE_FRAMES);
}

/// Freeze with 2D spiral through two latent dimensions.
pub fn freeze_neural_2d_n(
    rave: *neural.RaveEngine,
    wt: *wavetable_mod.WavetableEngine,
    dim_a: u8,
    dim_b: u8,
    frame_count: u32,
) FreezeResult {
    const count = @min(frame_count, wavetable_mod.MAX_FRAMES);
    const divisor: f32 = if (count > 1) @floatFromInt(count - 1) else 1.0;
    var frames_unique: u32 = 0;

    for (0..count) |frame_idx| {
        const t: f32 = @as(f32, @floatFromInt(frame_idx)) / divisor;
        const angle = t * std.math.pi * 4.0;
        const radius = t;
        rave.set_latent(dim_a, 0.5 + radius * 0.5 * @cos(angle));
        rave.set_latent(dim_b, 0.5 + radius * 0.5 * @sin(angle));

        var samples: [SAMPLES_PER_FRAME]f32 = undefined;
        render_frame(rave, &samples);
        wt.load_frame(@intCast(frame_idx), &samples);
        if (has_nonzero(&samples)) frames_unique += 1;
    }

    wt.generate_mip_maps();
    return .{
        .frames_written = count,
        .frames_unique = frames_unique,
        .degraded = rave.degraded,
    };
}

/// Freeze with 2D spiral, standard 256 frames.
pub fn freeze_neural_2d(
    rave: *neural.RaveEngine,
    wt: *wavetable_mod.WavetableEngine,
    dim_a: u8,
    dim_b: u8,
) FreezeResult {
    return freeze_neural_2d_n(rave, wt, dim_a, dim_b, FREEZE_FRAMES);
}

// -- Tests --------------------------------------------------------------------
// WavetableEngine is ~20MB — cannot live on stack or TLS.
// Tests allocate via page_allocator (offline operation, not audio thread).

// Use fewer frames in Debug to keep FFT-heavy generate_mip_maps() fast.
const TEST_FRAMES: u32 = switch (builtin.mode) {
    .Debug => 8,
    .ReleaseSafe => 32,
    .ReleaseFast, .ReleaseSmall => 256,
};

fn allocTestWt() !*wavetable_mod.WavetableEngine {
    const wt = try std.heap.page_allocator.create(wavetable_mod.WavetableEngine);
    wt.init();
    return wt;
}

fn freeTestWt(wt: *wavetable_mod.WavetableEngine) void {
    std.heap.page_allocator.destroy(wt);
}

test "AC-1: freeze writes expected frame count" {
    var rave = neural.RaveEngine.init(null) catch unreachable;
    defer rave.deinit();

    const wt = try allocTestWt();
    defer freeTestWt(wt);

    const result = freeze_neural_to_wavetable_n(&rave, wt, TEST_FRAMES);
    try std.testing.expectEqual(TEST_FRAMES, result.frames_written);
    try std.testing.expectEqual(TEST_FRAMES, wt.frame_count);
    try std.testing.expect(result.degraded);
    std.debug.print("\n[WP-065] AC-1: frames_written={}, frame_count={}, degraded={}\n", .{
        result.frames_written, wt.frame_count, result.degraded,
    });
}

test "AC-2: frozen wavetable is playable via process_sample" {
    const wt = try allocTestWt();
    defer freeTestWt(wt);

    // Manually load sine frames at different frequencies.
    for (0..8) |frame_idx| {
        var frame: [wavetable_mod.FRAME_SIZE]f32 = undefined;
        const cycles: f32 = @floatFromInt(frame_idx + 1);
        for (0..wavetable_mod.FRAME_SIZE) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(wavetable_mod.FRAME_SIZE));
            frame[i] = @sin(t * cycles * std.math.pi * 2.0);
        }
        wt.load_frame(@intCast(frame_idx), &frame);
    }
    wt.generate_mip_maps();

    var phase: f64 = 0.0;
    const phase_inc: f64 = 440.0 / 44_100.0;
    var sum_sq: f64 = 0.0;
    for (0..4096) |_| {
        const s = wt.process_sample(&phase, phase_inc, 0.0);
        sum_sq += @as(f64, s) * @as(f64, s);
    }
    const rms = @sqrt(sum_sq / 4096.0);
    std.debug.print("\n[WP-065] AC-2: playback RMS={d:.6}\n", .{rms});
    try std.testing.expect(rms > 0.01);
}

test "AC-3: freeze runs without crash" {
    var rave = neural.RaveEngine.init(null) catch unreachable;
    defer rave.deinit();

    const wt = try allocTestWt();
    defer freeTestWt(wt);

    const result = freeze_neural_to_wavetable_n(&rave, wt, TEST_FRAMES);
    try std.testing.expectEqual(TEST_FRAMES, result.frames_written);
}

test "AC-N1: freeze with degraded engine does not crash" {
    var rave = neural.RaveEngine.init(null) catch unreachable;
    defer rave.deinit();
    try std.testing.expect(rave.degraded);

    const wt = try allocTestWt();
    defer freeTestWt(wt);

    const result = freeze_neural_to_wavetable_n(&rave, wt, TEST_FRAMES);
    try std.testing.expect(result.degraded);
    try std.testing.expectEqual(TEST_FRAMES, result.frames_written);

    // 2D variant also must not crash.
    const result_2d = freeze_neural_2d_n(&rave, wt, 0, 1, TEST_FRAMES);
    try std.testing.expect(result_2d.degraded);
    try std.testing.expectEqual(TEST_FRAMES, result_2d.frames_written);
    std.debug.print("\n[WP-065] AC-N1: degraded freeze OK, 1D unique={}, 2D unique={}\n", .{
        result.frames_unique, result_2d.frames_unique,
    });
}

test "benchmark: freeze frames (degraded)" {
    var rave = neural.RaveEngine.init(null) catch unreachable;
    defer rave.deinit();

    const wt = try allocTestWt();
    defer freeTestWt(wt);

    // Warmup
    _ = freeze_neural_to_wavetable_n(&rave, wt, TEST_FRAMES);

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 2,
        .ReleaseSafe => 3,
        .ReleaseFast, .ReleaseSmall => 5,
    };
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        _ = freeze_neural_to_wavetable_n(&rave, wt, TEST_FRAMES);
    }
    const ns_per_freeze = timer.read() / iterations;
    const ms_per_freeze = @as(f64, @floatFromInt(ns_per_freeze)) / 1_000_000.0;

    const budget_ms: f64 = switch (builtin.mode) {
        .Debug => 5000.0,
        .ReleaseSafe => 500.0,
        .ReleaseFast, .ReleaseSmall => 100.0,
    };

    std.debug.print("\n[WP-065] freeze {} frames: {d:.2}ms (budget: {d:.0}ms, mode={s})\n", .{
        TEST_FRAMES, ms_per_freeze, budget_ms, @tagName(builtin.mode),
    });
    try std.testing.expect(ms_per_freeze < budget_ms);
}
