const std = @import("std");
const builtin = @import("builtin");

const benchmark_enforced = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
const benchmark_runs = 7;

// ── Chase-Lev Work-Stealing Deque (WP-024) ───────────────────────────
// Single-owner, multi-stealer deque after Chase & Lev (2005).
// Owner pushes/pops at bottom (LIFO, cache-local). Stealers take from top
// (FIFO, oldest work first). Fixed-size, zero-allocation implementation.

pub fn ChaseLevDeque(comptime T: type, comptime LOG2_SIZE: u5) type {
    comptime {
        if (LOG2_SIZE == 0) @compileError("LOG2_SIZE must be at least 1");
    }

    const SIZE: usize = 1 << LOG2_SIZE;
    const MASK: usize = SIZE - 1;
    const SIZE_ISIZE: isize = @intCast(SIZE);

    return struct {
        const Self = @This();

        buffer: [SIZE]T = undefined,
        bottom: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
        top: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),

        inline fn indexFor(pos: isize) usize {
            return @as(usize, @bitCast(pos)) & MASK;
        }

        /// Owner-only push at bottom. Returns false if the fixed buffer is full.
        pub inline fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b - t >= SIZE_ISIZE) return false;

            self.buffer[indexFor(b)] = item;
            self.bottom.store(b + 1, .release);
            return true;
        }

        /// Owner-only pop from bottom (LIFO).
        pub inline fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) - 1;
            self.bottom.store(b, .seq_cst);

            const t = self.top.load(.seq_cst);
            if (t <= b) {
                const item = self.buffer[indexFor(b)];
                if (t == b) {
                    // Last item: race with a concurrent stealer.
                    if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .seq_cst) != null) {
                        self.bottom.store(t + 1, .seq_cst);
                        return null;
                    }
                    self.bottom.store(t + 1, .seq_cst);
                }
                return item;
            }

            self.bottom.store(t, .seq_cst);
            return null;
        }

        /// Multi-stealer pop from top (FIFO).
        pub inline fn steal(self: *Self) ?T {
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.seq_cst);
            if (t >= b) return null;

            const item = self.buffer[indexFor(t)];
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .seq_cst) != null) {
                return null;
            }
            return item;
        }

        pub inline fn capacity(_: *const Self) usize {
            return SIZE;
        }

        pub inline fn approx_len(self: *const Self) usize {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            if (b <= t) return 0;
            return @intCast(b - t);
        }
    };
}

const StressMetrics = struct {
    elapsed_ns: u64,
};

const ContentionMetrics = struct {
    push_mops: f64,
    steal_mops_per: f64,
    success_pct: f64,
};

fn median(samples_in: [benchmark_runs]u64) u64 {
    var samples = samples_in;
    std.mem.sortUnstable(u64, &samples, {}, std.sort.asc(u64));
    return samples[benchmark_runs / 2];
}

fn initSeen(comptime ITEMS: usize, seen: *[ITEMS]std.atomic.Value(u8)) void {
    for (seen) |*slot| {
        slot.* = std.atomic.Value(u8).init(0);
    }
}

fn claimItem(
    comptime ITEMS: usize,
    seen: *[ITEMS]std.atomic.Value(u8),
    duplicate_flag: *std.atomic.Value(bool),
    total_claimed: *std.atomic.Value(usize),
    item: usize,
) void {
    if (item >= ITEMS) {
        duplicate_flag.store(true, .release);
        return;
    }

    if (seen[item].cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        duplicate_flag.store(true, .release);
    }
    _ = total_claimed.fetchAdd(1, .acq_rel);
}

fn runOwnerStealerStress(comptime ITEMS: usize) !StressMetrics {
    const Deque = ChaseLevDeque(usize, 12);

    var deque: Deque = .{};
    var seen: [ITEMS]std.atomic.Value(u8) = undefined;
    initSeen(ITEMS, &seen);

    var total_claimed = std.atomic.Value(usize).init(0);
    var duplicate_flag = std.atomic.Value(bool).init(false);
    var start_flag = std.atomic.Value(bool).init(false);
    var pushing_done = std.atomic.Value(bool).init(false);

    var threads: [2]std.Thread = undefined;
    for (0..threads.len) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(
                start: *std.atomic.Value(bool),
                done: *std.atomic.Value(bool),
                dq: *Deque,
                seen_slots: *[ITEMS]std.atomic.Value(u8),
                total: *std.atomic.Value(usize),
                duplicate: *std.atomic.Value(bool),
            ) void {
                while (!start.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }

                while (true) {
                    if (total.load(.acquire) >= ITEMS) break;

                    if (dq.steal()) |item| {
                        claimItem(ITEMS, seen_slots, duplicate, total, item);
                    } else if (done.load(.acquire)) {
                        if (total.load(.acquire) >= ITEMS) break;
                        std.atomic.spinLoopHint();
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{ &start_flag, &pushing_done, &deque, &seen, &total_claimed, &duplicate_flag });
    }
    defer for (threads) |thread| thread.join();

    var timer = try std.time.Timer.start();
    start_flag.store(true, .release);

    var next_item: usize = 0;
    while (next_item < ITEMS) {
        if (deque.push(next_item)) {
            next_item += 1;

            // Give the owner real pop/steal races instead of pure producer mode.
            if ((next_item & 7) == 0) {
                if (deque.pop()) |item| {
                    claimItem(ITEMS, &seen, &duplicate_flag, &total_claimed, item);
                }
            }
        } else if (deque.pop()) |item| {
            claimItem(ITEMS, &seen, &duplicate_flag, &total_claimed, item);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    pushing_done.store(true, .release);

    while (total_claimed.load(.acquire) < ITEMS) {
        if (deque.pop()) |item| {
            claimItem(ITEMS, &seen, &duplicate_flag, &total_claimed, item);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    const elapsed_ns = timer.read();

    try std.testing.expect(!duplicate_flag.load(.acquire));
    try std.testing.expectEqual(@as(usize, ITEMS), total_claimed.load(.acquire));

    for (seen) |slot| {
        try std.testing.expectEqual(@as(u8, 1), slot.load(.acquire));
    }

    return .{ .elapsed_ns = elapsed_ns };
}

fn benchPushThroughputMops() !f64 {
    const Deque = ChaseLevDeque(u64, 12);
    const BATCH: usize = 1 << 12;
    const BATCHES: usize = 256;
    const OPS: usize = BATCH * BATCHES;

    var deque: Deque = .{};
    var samples: [benchmark_runs]u64 = undefined;

    for (&samples) |*sample| {
        var total_ns: u64 = 0;
        var value: u64 = 0;

        for (0..BATCHES) |_| {
            deque.top.store(0, .monotonic);
            deque.bottom.store(0, .monotonic);

            var timer = try std.time.Timer.start();
            for (0..BATCH) |_| {
                std.debug.assert(deque.push(value));
                value += 1;
            }
            total_ns += timer.read();
        }

        sample.* = total_ns;
    }

    const median_ns = median(samples);
    return @as(f64, @floatFromInt(OPS)) * 1e9 / @as(f64, @floatFromInt(median_ns)) / 1e6;
}

fn benchStealThroughputMops() !f64 {
    const Deque = ChaseLevDeque(u64, 12);
    const BATCH: usize = 1 << 12;
    const BATCHES: usize = 256;
    const OPS: usize = BATCH * BATCHES;

    var deque: Deque = .{};
    var samples: [benchmark_runs]u64 = undefined;

    for (&samples) |*sample| {
        var total_ns: u64 = 0;
        var value: u64 = 0;

        for (0..BATCHES) |_| {
            deque.top.store(0, .monotonic);
            deque.bottom.store(0, .monotonic);
            for (0..BATCH) |_| {
                std.debug.assert(deque.push(value));
                value += 1;
            }

            var timer = try std.time.Timer.start();
            for (0..BATCH) |_| {
                _ = deque.steal().?;
            }
            total_ns += timer.read();
        }

        sample.* = total_ns;
    }

    const median_ns = median(samples);
    return @as(f64, @floatFromInt(OPS)) * 1e9 / @as(f64, @floatFromInt(median_ns)) / 1e6;
}

fn benchContention(comptime STEALERS: usize) !ContentionMetrics {
    const ITEMS: usize = 200_000;
    const Deque = ChaseLevDeque(usize, 12);
    const refill_watermark: usize = 1 << 10;
    const refill_target: usize = 1 << 11;

    var deque: Deque = .{};
    var start_flag = std.atomic.Value(bool).init(false);
    var pushing_done = std.atomic.Value(bool).init(false);
    var total_stolen = std.atomic.Value(usize).init(0);

    var attempt_counts: [STEALERS]usize = [_]usize{0} ** STEALERS;
    var success_counts: [STEALERS]usize = [_]usize{0} ** STEALERS;
    var threads: [STEALERS]std.Thread = undefined;

    for (0..STEALERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(
                start: *std.atomic.Value(bool),
                done: *std.atomic.Value(bool),
                dq: *Deque,
                total: *std.atomic.Value(usize),
                attempts: *usize,
                successes: *usize,
            ) void {
                while (!start.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }

                while (total.load(.acquire) < ITEMS) {
                    if (dq.approx_len() == 0) {
                        if (done.load(.acquire) and total.load(.acquire) >= ITEMS) break;
                        std.atomic.spinLoopHint();
                        continue;
                    }

                    attempts.* += 1;
                    if (dq.steal()) |_| {
                        successes.* += 1;
                        _ = total.fetchAdd(1, .acq_rel);
                    } else if (done.load(.acquire) and total.load(.acquire) >= ITEMS) {
                        break;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{
            &start_flag,
            &pushing_done,
            &deque,
            &total_stolen,
            &attempt_counts[i],
            &success_counts[i],
        });
    }
    defer for (threads) |thread| thread.join();

    var next_item: usize = 0;
    while (next_item < refill_target and deque.push(next_item)) {
        next_item += 1;
    }

    var timer = try std.time.Timer.start();
    start_flag.store(true, .release);

    while (next_item < ITEMS) {
        if (deque.approx_len() <= refill_watermark) {
            while (next_item < ITEMS and deque.approx_len() < refill_target) {
                if (!deque.push(next_item)) break;
                next_item += 1;
            }
        } else {
            std.atomic.spinLoopHint();
        }
    }
    pushing_done.store(true, .release);

    while (total_stolen.load(.acquire) < ITEMS) {
        std.atomic.spinLoopHint();
    }

    const elapsed_ns = timer.read();

    var attempts_total: usize = 0;
    for (attempt_counts) |count| attempts_total += count;

    const push_mops = @as(f64, @floatFromInt(ITEMS)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns)) / 1e6;
    const steal_mops_per = push_mops / @as(f64, @floatFromInt(STEALERS));
    const success_pct = if (attempts_total == 0)
        100.0
    else
        @as(f64, @floatFromInt(ITEMS)) * 100.0 / @as(f64, @floatFromInt(attempts_total));

    return .{
        .push_mops = push_mops,
        .steal_mops_per = steal_mops_per,
        .success_pct = success_pct,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: push(1,2,3), pop() returns 3 (LIFO)" {
    var deque: ChaseLevDeque(u32, 3) = .{};

    try std.testing.expect(deque.push(1));
    try std.testing.expect(deque.push(2));
    try std.testing.expect(deque.push(3));

    try std.testing.expectEqual(@as(?u32, 3), deque.pop());
    try std.testing.expectEqual(@as(?u32, 2), deque.pop());
    try std.testing.expectEqual(@as(?u32, 1), deque.pop());
    try std.testing.expectEqual(@as(?u32, null), deque.pop());
}

test "AC-2: push(1,2,3), steal() returns 1 (FIFO)" {
    var deque: ChaseLevDeque(u32, 3) = .{};

    try std.testing.expect(deque.push(1));
    try std.testing.expect(deque.push(2));
    try std.testing.expect(deque.push(3));

    try std.testing.expectEqual(@as(?u32, 1), deque.steal());
    try std.testing.expectEqual(@as(?u32, 3), deque.pop());
    try std.testing.expectEqual(@as(?u32, 2), deque.pop());
    try std.testing.expectEqual(@as(?u32, null), deque.steal());
}

test "last item race: pop and steal claim a single element exactly once" {
    const iterations = 2_000;

    for (0..iterations) |_| {
        var deque: ChaseLevDeque(u32, 2) = .{};
        try std.testing.expect(deque.push(42));

        var start_flag = std.atomic.Value(bool).init(false);
        var stolen = std.atomic.Value(u8).init(0);

        const stealer = try std.Thread.spawn(.{}, struct {
            fn run(start: *std.atomic.Value(bool), dq: *ChaseLevDeque(u32, 2), slot: *std.atomic.Value(u8)) void {
                while (!start.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
                if (dq.steal()) |_| {
                    slot.store(1, .release);
                }
            }
        }.run, .{ &start_flag, &deque, &stolen });

        start_flag.store(true, .release);
        const popped = deque.pop();
        stealer.join();

        const total_claims: u8 = @intFromBool(popped != null) + stolen.load(.acquire);
        try std.testing.expectEqual(@as(u8, 1), total_claims);
    }
}

test "AC-3: multi-thread owner + 2 stealers — no duplicates, no loss" {
    const metrics = try runOwnerStealerStress(10_000);
    try std.testing.expect(metrics.elapsed_ns > 0);
}

test "AC-N1: concurrent push/pop/steal stress terminates within 5s" {
    const metrics = try runOwnerStealerStress(50_000);
    try std.testing.expect(metrics.elapsed_ns < 5 * std.time.ns_per_s);
}

test "AC-N2: no heap — sizeOf and field layout are compile-time fixed" {
    const Deque = ChaseLevDeque(u64, 10);
    const fields = @typeInfo(Deque).@"struct".fields;
    var deque: Deque = .{};

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expect(std.mem.eql(u8, fields[0].name, "buffer"));
    try std.testing.expect(std.mem.eql(u8, fields[1].name, "bottom"));
    try std.testing.expect(std.mem.eql(u8, fields[2].name, "top"));
    try std.testing.expectEqual(@as(usize, 1024), deque.capacity());
    try std.testing.expect(@sizeOf(Deque) >= 1024 * @sizeOf(u64));
}

// ── Benchmarks ────────────────────────────────────────────────────────

test "AC-B1: Chase-Lev benchmarks" {
    const push_mops = try benchPushThroughputMops();
    const steal_mops = try benchStealThroughputMops();
    const contention_1 = try benchContention(1);
    const contention_2 = try benchContention(2);
    const contention_4 = try benchContention(4);
    const contention_8 = try benchContention(8);

    // Dual-system thresholds from measured ReleaseFast baselines:
    // Remote (i5 build server): push 2189.4M, steal 132.0M, success {1:100, 2:100, 4:100, 8:100}
    // Local  (Ryzen 9 znver3):  push  892.1M, steal 210.9M, success {1:100, 2:73.9, 4:54.1, 8:33.2}
    // Throughput uses the slower system / 2 (2x headroom). Success rate uses the
    // lower observed success / 2 for each contention level.
    const push_threshold_mops: f64 = if (benchmark_enforced) 400.0 else 1.0;
    const steal_threshold_mops: f64 = if (benchmark_enforced) 60.0 else 0.5;
    const success_threshold_1_pct: f64 = if (benchmark_enforced) 50.0 else 0.5;
    const success_threshold_2_pct: f64 = if (benchmark_enforced) 35.0 else 0.5;
    const success_threshold_4_pct: f64 = if (benchmark_enforced) 25.0 else 0.5;
    const success_threshold_8_pct: f64 = if (benchmark_enforced) 15.0 else 0.5;

    std.debug.print(
        "\n  [WP-024] Chase-Lev throughput\n" ++
            "    push (owner only): {d:.1}M ops/s\n" ++
            "    steal (1 stealer): {d:.1}M ops/s\n" ++
            "    Thresholds: push>{d:.1}M steal>{d:.1}M\n",
        .{ push_mops, steal_mops, push_threshold_mops, steal_threshold_mops },
    );

    std.debug.print("  [WP-024] Contention scaling (1 pusher + N stealers)\n", .{});
    std.debug.print("    | Stealers | Push (M ops/s) | Steal (M ops/s/stealer) | Steal-Erfolgsrate |\n", .{});
    std.debug.print("    |----------|----------------|-------------------------|-------------------|\n", .{});
    inline for (.{
        .{ 1, contention_1 },
        .{ 2, contention_2 },
        .{ 4, contention_4 },
        .{ 8, contention_8 },
    }) |entry| {
        std.debug.print("    | {d:8} | {d:14.1} | {d:23.1} | {d:17.1}% |\n", .{
            entry[0],
            entry[1].push_mops,
            entry[1].steal_mops_per,
            entry[1].success_pct,
        });
    }

    try std.testing.expect(push_mops > push_threshold_mops);
    try std.testing.expect(steal_mops > steal_threshold_mops);
    try std.testing.expect(contention_1.success_pct > success_threshold_1_pct);
    try std.testing.expect(contention_2.success_pct > success_threshold_2_pct);
    try std.testing.expect(contention_4.success_pct > success_threshold_4_pct);
    try std.testing.expect(contention_8.success_pct > success_threshold_8_pct);
}
