const std = @import("std");
const builtin = @import("builtin");

pub const MAX_WORKERS: u8 = 14;
pub const RESERVED_CORES: u8 = 2;

pub const HwInfo = struct {
    cpu_count: u8,
    cuda_available: bool,
    recommended_workers: u8,
};

inline fn clamp_cpu_count(count: usize) u8 {
    const clamped = @max(@as(usize, 1), @min(count, std.math.maxInt(u8)));
    return @intCast(clamped);
}

fn detect_cpu_count_fallback() u8 {
    const count = std.Thread.getCpuCount() catch 1;
    return clamp_cpu_count(count);
}

pub fn detect_cpu_count() u8 {
    if (builtin.os.tag == .linux) {
        const affinity = std.posix.sched_getaffinity(0) catch return detect_cpu_count_fallback();
        var count: usize = 0;
        for (affinity) |word| {
            count += @popCount(word);
        }
        if (count > 0) return clamp_cpu_count(count);
    }
    return detect_cpu_count_fallback();
}

pub fn detect_cuda_available() bool {
    // Keep startup resilient on systems without NVIDIA drivers.
    const candidates = [_][]const u8{
        "libcuda.so",
        "libcuda.so.1",
    };
    for (candidates) |name| {
        var lib = std.DynLib.open(name) catch continue;
        lib.close();
        return true;
    }
    return false;
}

pub fn recommended_workers(cpu_count: u8) u8 {
    if (cpu_count <= RESERVED_CORES) return 1;
    return @min(cpu_count - RESERVED_CORES, MAX_WORKERS);
}

pub fn detect() HwInfo {
    const cpu_count = detect_cpu_count();
    return .{
        .cpu_count = cpu_count,
        .cuda_available = detect_cuda_available(),
        .recommended_workers = recommended_workers(cpu_count),
    };
}

test "WP-027 AC-1: detect_cpu_count returns at least 1 and at most u8 max" {
    const cpu_count = detect_cpu_count();
    try std.testing.expect(cpu_count >= 1);
    try std.testing.expect(cpu_count <= std.math.maxInt(u8));
}

test "WP-027 AC-2: recommended_workers(16) == 14" {
    try std.testing.expectEqual(@as(u8, 14), recommended_workers(16));
}

test "WP-027 AC-N1: detect_cuda_available does not crash without CUDA" {
    _ = detect_cuda_available();
    try std.testing.expect(true);
}

test "WP-027 AC-N2: recommended_workers handles cpu_count <= 2 without underflow" {
    try std.testing.expectEqual(@as(u8, 1), recommended_workers(0));
    try std.testing.expectEqual(@as(u8, 1), recommended_workers(1));
    try std.testing.expectEqual(@as(u8, 1), recommended_workers(2));
}

test "detect returns self-consistent values" {
    const hw = detect();
    try std.testing.expect(hw.cpu_count >= 1);
    try std.testing.expectEqual(recommended_workers(hw.cpu_count), hw.recommended_workers);
}
