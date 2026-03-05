const std = @import("std");
const builtin = @import("builtin");

// ── Quality Governor DSP (WP-125) ───────────────────────────────────
// Live/Studio/Render mode policy for DSP modules.
//
// Design:
// - live: minimum latency, CPU priority
// - studio: balanced quality/cost
// - render: offline max quality (deterministic)
//
// Note:
// "No oversampling" is represented as 1x (factor=1), not 0.

pub const QualityMode = enum {
    live,
    studio,
    render,

    /// Oversampling factor for DSP stages controlled by governor.
    pub inline fn get_oversampling(self: QualityMode) u8 {
        return switch (self) {
            .live => 1,
            .studio => 2,
            .render => 4,
        };
    }

    /// Neural budget in samples per block.
    /// 0 means unlimited (render/offline).
    pub inline fn get_neural_budget(self: QualityMode) u32 {
        return switch (self) {
            .live => 128,
            .studio => 256,
            .render => 0,
        };
    }

    /// GPU usage policy.
    pub inline fn get_gpu_enabled(self: QualityMode) bool {
        return self != .live;
    }

    /// Render mode is deterministic for reproducible offline output.
    pub inline fn is_deterministic(self: QualityMode) bool {
        return self == .render;
    }
};

/// Wrapper API for call-sites that prefer free functions.
pub inline fn get_oversampling(mode: QualityMode) u8 {
    return mode.get_oversampling();
}

pub inline fn get_neural_budget(mode: QualityMode) u32 {
    return mode.get_neural_budget();
}

pub inline fn get_gpu_enabled(mode: QualityMode) bool {
    return mode.get_gpu_enabled();
}

pub inline fn is_deterministic(mode: QualityMode) bool {
    return mode.is_deterministic();
}

fn simulated_process_block(mode: QualityMode) u64 {
    const os = mode.get_oversampling();
    const budget = mode.get_neural_budget();
    const neural_work: usize = if (budget == 0) 512 else budget / 2;

    var acc: u64 = @as(u64, @intFromEnum(mode)) + 1;
    var i: usize = 0;
    while (i < @as(usize, os) * 32) : (i += 1) {
        acc = (acc *% 6364136223846793005) +% 1442695040888963407;
    }

    i = 0;
    while (i < neural_work) : (i += 1) {
        acc +%= @as(u64, @intCast(i)) ^ 0x9E3779B97F4A7C15;
    }

    if (mode.get_gpu_enabled()) {
        acc ^= 0xA5A5_A5A5_A5A5_A5A5;
    }

    return acc;
}

fn benchmark_ns_per_block(mode: QualityMode, blocks: usize) !u64 {
    var timer = try std.time.Timer.start();
    var sink: u64 = 0;

    var i: usize = 0;
    while (i < blocks) : (i += 1) {
        sink +%= simulated_process_block(mode);
    }

    std.mem.doNotOptimizeAway(sink);
    const ns = timer.read() / blocks;
    return if (ns == 0) 1 else ns;
}

test "AC-1: live mode oversampling is 1x" {
    try std.testing.expectEqual(@as(u8, 1), QualityMode.live.get_oversampling());
    try std.testing.expectEqual(@as(u8, 1), get_oversampling(.live));
}

test "AC-2: render mode oversampling is 4x" {
    try std.testing.expectEqual(@as(u8, 4), QualityMode.render.get_oversampling());
    try std.testing.expectEqual(@as(u8, 4), get_oversampling(.render));
}

test "AC-3: live mode has GPU disabled" {
    try std.testing.expectEqual(false, QualityMode.live.get_gpu_enabled());
    try std.testing.expectEqual(false, get_gpu_enabled(.live));
}

test "AC-4: studio mode neural budget is 256 samples per block" {
    try std.testing.expectEqual(@as(u32, 256), QualityMode.studio.get_neural_budget());
    try std.testing.expectEqual(@as(u32, 256), get_neural_budget(.studio));
}

test "AC-5: render mode is deterministic" {
    try std.testing.expectEqual(true, QualityMode.render.is_deterministic());
    try std.testing.expectEqual(true, is_deterministic(.render));

    try std.testing.expectEqual(false, QualityMode.live.is_deterministic());
    try std.testing.expectEqual(false, QualityMode.studio.is_deterministic());
}

test "mode matrix stays internally consistent" {
    try std.testing.expectEqual(@as(u8, 1), QualityMode.live.get_oversampling());
    try std.testing.expectEqual(@as(u8, 2), QualityMode.studio.get_oversampling());
    try std.testing.expectEqual(@as(u8, 4), QualityMode.render.get_oversampling());

    try std.testing.expectEqual(@as(u32, 128), QualityMode.live.get_neural_budget());
    try std.testing.expectEqual(@as(u32, 256), QualityMode.studio.get_neural_budget());
    try std.testing.expectEqual(@as(u32, 0), QualityMode.render.get_neural_budget());

    try std.testing.expectEqual(false, QualityMode.live.get_gpu_enabled());
    try std.testing.expectEqual(true, QualityMode.studio.get_gpu_enabled());
    try std.testing.expectEqual(true, QualityMode.render.get_gpu_enabled());
}

test "AC-B1: mode profile benchmark thresholds" {
    const blocks: usize = 20_000;
    const live_ns = try benchmark_ns_per_block(.live, blocks);
    const studio_ns = try benchmark_ns_per_block(.studio, blocks);
    const render_ns = try benchmark_ns_per_block(.render, blocks);

    std.debug.print(
        \\
        \\  [WP-125] Quality Governor DSP Benchmark
        \\    LIVE:   {} ns/block (threshold < 150000)
        \\    STUDIO: {} ns/block (threshold < 500000)
        \\    RENDER: {} ns/block (offline, no RT threshold)
        \\
    , .{ live_ns, studio_ns, render_ns });

    try std.testing.expect(live_ns < 150_000);
    try std.testing.expect(studio_ns < 500_000);

    // Cost profile should be monotonic by mode policy.
    try std.testing.expect(live_ns <= studio_ns);
    try std.testing.expect(studio_ns <= render_ns);

    if (builtin.mode == .Debug) {
        // Keep debug build resilient across very different hosts.
        try std.testing.expect(render_ns < 5_000_000);
    }
}
