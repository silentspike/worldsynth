const std = @import("std");
const builtin = @import("builtin");

const benchmark_enforced = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
const benchmark_runs = 7;

pub const Barrier = struct {
    remaining: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub inline fn reset(self: *Barrier, n: u32) void {
        self.remaining.store(n, .release);
    }

    pub inline fn worker_done(self: *Barrier) void {
        _ = self.remaining.fetchSub(1, .acq_rel);
    }

    pub inline fn wait(self: *Barrier) void {
        while (self.remaining.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
    }
};

const WaitMetrics = struct {
    median_ns: u64,
    median_spins: u64,
};

fn median(samples_in: [benchmark_runs]u64) u64 {
    var samples = samples_in;
    std.mem.sortUnstable(u64, &samples, {}, std.sort.asc(u64));
    return samples[benchmark_runs / 2];
}

fn wait_counting(barrier: *Barrier) u64 {
    var spins: u64 = 0;
    while (barrier.remaining.load(.acquire) != 0) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    return spins;
}

fn bench_wait_ready(worker_count: u32) !u64 {
    std.debug.assert(worker_count > 0);
    const iterations: usize = 100_000;
    var barrier: Barrier = .{};

    for (0..10_000) |_| {
        barrier.reset(worker_count);
        var ready: u32 = 0;
        while (ready < worker_count) : (ready += 1) {
            barrier.worker_done();
        }
        barrier.wait();
    }

    var samples: [benchmark_runs]u64 = undefined;
    for (&samples) |*sample| {
        var total_ns: u64 = 0;

        for (0..iterations) |_| {
            barrier.reset(worker_count);
            var ready: u32 = 0;
            while (ready < worker_count) : (ready += 1) {
                barrier.worker_done();
            }

            var timer = try std.time.Timer.start();
            barrier.wait();
            total_ns += timer.read();
        }

        sample.* = total_ns / iterations;
        std.mem.doNotOptimizeAway(&barrier);
    }

    return median(samples);
}

fn bench_wait_delayed(worker_count: u32, delay_spins: u32) !WaitMetrics {
    std.debug.assert(worker_count > 0);
    const iterations: usize = 50_000;
    var barrier: Barrier = .{};

    for (0..5_000) |_| {
        barrier.reset(worker_count);
        var ready: u32 = 1;
        while (ready < worker_count) : (ready += 1) {
            barrier.worker_done();
        }
        var spins = wait_counting_with_release(&barrier, delay_spins);
        std.mem.doNotOptimizeAway(&spins);
    }

    var times: [benchmark_runs]u64 = undefined;
    var spins: [benchmark_runs]u64 = undefined;
    for (&times, &spins) |*time_slot, *spin_slot| {
        var total_ns: u64 = 0;
        var total_spins: u64 = 0;

        for (0..iterations) |_| {
            barrier.reset(worker_count);
            var ready: u32 = 1;
            while (ready < worker_count) : (ready += 1) {
                barrier.worker_done();
            }

            var timer = try std.time.Timer.start();
            total_spins += wait_counting_with_release(&barrier, delay_spins);
            total_ns += timer.read();
        }

        time_slot.* = total_ns / iterations;
        spin_slot.* = total_spins / iterations;
    }

    return .{
        .median_ns = median(times),
        .median_spins = median(spins),
    };
}

fn wait_counting_with_release(barrier: *Barrier, release_after_spins: u32) u64 {
    var spins: u64 = 0;
    while (barrier.remaining.load(.acquire) != 0) : (spins += 1) {
        if (spins == release_after_spins) {
            barrier.worker_done();
        }
        std.atomic.spinLoopHint();
    }
    return spins;
}

fn bench_reset_ns() !u64 {
    var barrier: Barrier = .{};
    const iterations: usize = 100_000;

    for (0..10_000) |i| {
        barrier.reset(@intCast(i & 15));
    }

    var samples: [benchmark_runs]u64 = undefined;
    for (&samples) |*sample| {
        var timer = try std.time.Timer.start();
        for (0..iterations) |i| {
            barrier.reset(@intCast(i & 15));
        }
        sample.* = timer.read() / iterations;
        std.mem.doNotOptimizeAway(&barrier);
    }

    return median(samples);
}

fn bench_full_cycle_ns(job_count: u32) !u64 {
    var barrier: Barrier = .{};
    const iterations: usize = 50_000;

    for (0..5_000) |_| {
        barrier.reset(job_count);
        var i: u32 = 0;
        while (i < job_count) : (i += 1) {
            barrier.worker_done();
        }
        barrier.wait();
    }

    var samples: [benchmark_runs]u64 = undefined;
    for (&samples) |*sample| {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            barrier.reset(job_count);
            var i: u32 = 0;
            while (i < job_count) : (i += 1) {
                barrier.worker_done();
            }
            barrier.wait();
        }
        sample.* = timer.read() / iterations;
        std.mem.doNotOptimizeAway(&barrier);
    }

    return median(samples);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: reset(4), 4x worker_done(), wait returns" {
    var barrier: Barrier = .{};
    barrier.reset(4);

    inline for (0..4) |_| {
        barrier.worker_done();
    }

    barrier.wait();
    try std.testing.expectEqual(@as(u32, 0), barrier.remaining.load(.acquire));
}

test "AC-2: reset(0), wait returns immediately" {
    var barrier: Barrier = .{};
    barrier.reset(0);

    var timer = try std.time.Timer.start();
    barrier.wait();

    try std.testing.expectEqual(@as(u32, 0), barrier.remaining.load(.acquire));
    try std.testing.expect(timer.read() < std.time.ns_per_ms);
}

test "dynamic reset: barrier can be reused with variable job counts" {
    var barrier: Barrier = .{};
    const counts = [_]u32{ 1, 2, 8, 3, 0, 5 };

    for (counts) |count| {
        barrier.reset(count);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            barrier.worker_done();
        }
        barrier.wait();
        try std.testing.expectEqual(@as(u32, 0), barrier.remaining.load(.acquire));
    }
}

test "AC-N1: multi-thread use with 4 workers does not deadlock" {
    var barrier: Barrier = .{};
    var start_flag = std.atomic.Value(bool).init(false);

    var threads: [4]std.Thread = undefined;
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(flag: *std.atomic.Value(bool), b: *Barrier, worker_index: usize) void {
                while (!flag.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }

                var spins: usize = 0;
                const target_spins = 64 + worker_index * 16;
                while (spins < target_spins) : (spins += 1) {
                    std.atomic.spinLoopHint();
                }

                b.worker_done();
            }
        }.run, .{ &start_flag, &barrier, i });
    }
    defer for (threads) |thread| thread.join();

    barrier.reset(4);

    var timer = try std.time.Timer.start();
    start_flag.store(true, .release);
    barrier.wait();

    try std.testing.expectEqual(@as(u32, 0), barrier.remaining.load(.acquire));
    try std.testing.expect(timer.read() < std.time.ns_per_s);
}

test "AC-N2: barrier struct contains only the atomic counter" {
    const fields = @typeInfo(Barrier).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expect(std.mem.eql(u8, fields[0].name, "remaining"));
    try std.testing.expectEqual(@sizeOf(Barrier), @sizeOf(std.atomic.Value(u32)));
}

test "AC-B1: barrier benchmarks" {
    const wait_4_ns = try bench_wait_ready(4);
    const wait_8 = try bench_wait_delayed(8, 8);
    const reset_ns = try bench_reset_ns();
    const full_cycle_ns = try bench_full_cycle_ns(8);

    const wait_4_threshold: u64 = if (benchmark_enforced) 200 else 20_000;
    const wait_8_threshold: u64 = if (benchmark_enforced) 500 else 50_000;
    const reset_threshold: u64 = if (benchmark_enforced) 50 else 500;
    const full_cycle_threshold: u64 = if (benchmark_enforced) 1_000 else 5_000;
    const spin_threshold: u64 = if (benchmark_enforced) 100 else 2_000;

    std.debug.print(
        "\n  [WP-023] Barrier benchmarks\n" ++
            "    wait(4 workers, simultaneous): {d}ns, spins=0\n" ++
            "    wait(8 workers, staggered):    {d}ns, spins={d}\n" ++
            "    reset():                       {d}ns\n" ++
            "    full cycle (reset + 8 done):   {d}ns\n" ++
            "    Thresholds: wait4<{d}ns wait8<{d}ns reset<{d}ns cycle<{d}ns spins<{d}\n",
        .{
            wait_4_ns,
            wait_8.median_ns,
            wait_8.median_spins,
            reset_ns,
            full_cycle_ns,
            wait_4_threshold,
            wait_8_threshold,
            reset_threshold,
            full_cycle_threshold,
            spin_threshold,
        },
    );

    try std.testing.expect(wait_4_ns < wait_4_threshold);
    try std.testing.expect(wait_8.median_ns < wait_8_threshold);
    try std.testing.expect(reset_ns < reset_threshold);
    try std.testing.expect(full_cycle_ns < full_cycle_threshold);
    try std.testing.expect(wait_8.median_spins < spin_threshold);
}
