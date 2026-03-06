const std = @import("std");
const builtin = @import("builtin");

/// Lock-free triple buffer for Audio→UI communication (WP-031).
///
/// Three buffers rotate: the writer (audio thread) writes into a back buffer
/// and atomically publishes it. The reader (UI thread) always gets the most
/// recently completed buffer without stalling the writer.
///
/// Memory ordering: `.release` on write (publish), `.acquire` on read (consume).
pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffers: [3]T,
        /// Index the writer is currently filling (owned by writer thread).
        write_idx: u8,
        /// Index of the most recently completed buffer (shared atomically).
        latest: std.atomic.Value(u8),
        /// Index the reader is currently consuming (owned by reader thread).
        read_idx: u8,

        pub fn init() Self {
            return .{
                .buffers = [3]T{ std.mem.zeroes(T), std.mem.zeroes(T), std.mem.zeroes(T) },
                .write_idx = 0,
                .latest = std.atomic.Value(u8).init(1),
                .read_idx = 2,
            };
        }

        /// Audio thread: copy new data into the back buffer, then publish.
        pub inline fn write(self: *Self, data: T) void {
            self.buffers[self.write_idx] = data;
            const old_latest = self.latest.swap(self.write_idx, .release);
            self.write_idx = old_latest;
        }

        /// UI thread: acquire the most recently published buffer.
        pub inline fn read(self: *Self) *const T {
            const new_read = self.latest.swap(self.read_idx, .acquire);
            self.read_idx = new_read;
            return &self.buffers[self.read_idx];
        }
    };
}

// ── Unit Tests ──────────────────────────────────────────────────────

const TestPayload = struct {
    a: u64,
    b: u64,
    c: u64,
    d: u64,
};

test "write then read returns written data" {
    var tb = TripleBuffer(TestPayload).init();
    const val = TestPayload{ .a = 1, .b = 2, .c = 3, .d = 4 };
    tb.write(val);
    const got = tb.read();
    try std.testing.expectEqual(@as(u64, 1), got.a);
    try std.testing.expectEqual(@as(u64, 2), got.b);
    try std.testing.expectEqual(@as(u64, 3), got.c);
    try std.testing.expectEqual(@as(u64, 4), got.d);
}

test "read without write returns zeroed data" {
    var tb = TripleBuffer(TestPayload).init();
    const got = tb.read();
    try std.testing.expectEqual(@as(u64, 0), got.a);
    try std.testing.expectEqual(@as(u64, 0), got.b);
    try std.testing.expectEqual(@as(u64, 0), got.c);
    try std.testing.expectEqual(@as(u64, 0), got.d);
}

test "multiple writes, read gets latest" {
    var tb = TripleBuffer(u64).init();
    tb.write(10);
    tb.write(20);
    tb.write(30);
    const got = tb.read();
    try std.testing.expectEqual(@as(u64, 30), got.*);
}

test "concurrent write/read no tearing" {
    const iterations: usize = if (builtin.mode == .Debug) 500_000 else 2_000_000;
    var tb = TripleBuffer(TestPayload).init();
    var tears = std.atomic.Value(u64).init(0);
    var reader_done = std.atomic.Value(bool).init(false);

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(buf: *TripleBuffer(TestPayload), iters: usize) void {
            for (0..iters) |i| {
                const v: u64 = @intCast(i);
                buf.write(.{ .a = v, .b = v, .c = v, .d = v });
            }
        }
    }.run, .{ &tb, iterations });

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(buf: *TripleBuffer(TestPayload), tear_count: *std.atomic.Value(u64), done: *std.atomic.Value(bool)) void {
            var reads: u64 = 0;
            while (!done.load(.acquire)) {
                const got = buf.read();
                if (got.a != got.b or got.b != got.c or got.c != got.d) {
                    _ = tear_count.fetchAdd(1, .monotonic);
                }
                reads += 1;
                if (reads % 1024 == 0) std.atomic.spinLoopHint();
            }
            // Drain remaining
            for (0..100) |_| {
                const got = buf.read();
                if (got.a != got.b or got.b != got.c or got.c != got.d) {
                    _ = tear_count.fetchAdd(1, .monotonic);
                }
            }
        }
    }.run, .{ &tb, &tears, &reader_done });

    writer.join();
    reader_done.store(true, .release);
    reader.join();

    const tear_count = tears.load(.monotonic);
    if (tear_count > 0) {
        std.debug.print("\n  TEARING DETECTED: {} tears in {} iterations\n", .{ tear_count, iterations });
    }
    try std.testing.expectEqual(@as(u64, 0), tear_count);
}

// ── Benchmarks (AC-B1) ─────────────────────────────────────────────

const benchmark_enforced = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

test "benchmark: triple-buffer write uncontended" {
    var tb = TripleBuffer(TestPayload).init();
    const warmup: usize = 10_000;
    const ops: usize = if (benchmark_enforced) 100_000 else 30_000;
    const runs = 5;

    // Warmup
    for (0..warmup) |i| {
        tb.write(.{ .a = i, .b = i, .c = i, .d = i });
    }

    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..ops) |i| {
            tb.write(.{ .a = i, .b = i, .c = i, .d = i });
            std.mem.doNotOptimizeAway(&tb);
        }
        t.* = timer.read();
    }

    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns: f64 = @as(f64, @floatFromInt(times[runs / 2])) / @as(f64, @floatFromInt(ops));

    const threshold: f64 = if (builtin.mode == .Debug) 1000.0 else 100.0;

    std.debug.print("\n  [WP-031] write uncontended — {d} ops, {d} runs\n", .{ ops, runs });
    std.debug.print("    median: {d:.1}ns/op (threshold: <{d:.0}ns)\n", .{ median_ns, threshold });

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: triple-buffer read uncontended" {
    var tb = TripleBuffer(TestPayload).init();
    const warmup: usize = 10_000;
    const ops: usize = if (benchmark_enforced) 100_000 else 30_000;
    const runs = 5;

    // Seed a value
    tb.write(.{ .a = 42, .b = 42, .c = 42, .d = 42 });

    // Warmup
    for (0..warmup) |_| {
        _ = tb.read();
    }

    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..ops) |_| {
            const r = tb.read();
            std.mem.doNotOptimizeAway(r);
        }
        t.* = timer.read();
    }

    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns: f64 = @as(f64, @floatFromInt(times[runs / 2])) / @as(f64, @floatFromInt(ops));

    const threshold: f64 = if (builtin.mode == .Debug) 1000.0 else 100.0;

    std.debug.print("\n  [WP-031] read uncontended — {d} ops, {d} runs\n", .{ ops, runs });
    std.debug.print("    median: {d:.1}ns/op (threshold: <{d:.0}ns)\n", .{ median_ns, threshold });

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: triple-buffer concurrent throughput" {
    const total_ops: usize = if (benchmark_enforced) 2_000_000 else 500_000;
    const warmup_ops: usize = if (benchmark_enforced) 100_000 else 10_000;
    var tb = TripleBuffer(TestPayload).init();

    // Warmup
    for (0..warmup_ops) |i| {
        tb.write(.{ .a = i, .b = i, .c = i, .d = i });
        _ = tb.read();
    }

    var writer_done = std.atomic.Value(bool).init(false);
    var read_count = std.atomic.Value(u64).init(0);
    var tears = std.atomic.Value(u64).init(0);

    var timer = try std.time.Timer.start();

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(buf: *TripleBuffer(TestPayload), ops: usize, done: *std.atomic.Value(bool)) void {
            for (0..ops) |i| {
                buf.write(.{ .a = i, .b = i, .c = i, .d = i });
            }
            done.store(true, .release);
        }
    }.run, .{ &tb, total_ops, &writer_done });

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(buf: *TripleBuffer(TestPayload), done: *std.atomic.Value(bool), reads: *std.atomic.Value(u64), tear_count: *std.atomic.Value(u64)) void {
            var local_reads: u64 = 0;
            while (!done.load(.acquire)) {
                const got = buf.read();
                if (got.a != got.b or got.b != got.c or got.c != got.d) {
                    _ = tear_count.fetchAdd(1, .monotonic);
                }
                local_reads += 1;
            }
            reads.store(local_reads, .release);
        }
    }.run, .{ &tb, &writer_done, &read_count, &tears });

    writer.join();
    reader.join();

    const elapsed_ns = timer.read();
    const total_combined = total_ops + read_count.load(.monotonic);
    const throughput = @as(f64, @floatFromInt(total_combined)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    const throughput_k = throughput / 1000.0;
    const tear_count = tears.load(.monotonic);

    const threshold_k: f64 = if (builtin.mode == .Debug) 10.0 else 100.0;

    std.debug.print("\n  [WP-031] concurrent throughput — {d} writes\n", .{total_ops});
    std.debug.print("    reads: {d}, tears: {d}\n", .{ read_count.load(.monotonic), tear_count });
    std.debug.print("    throughput: {d:.0}k ops/s (threshold: >{d:.0}k)\n", .{ throughput_k, threshold_k });

    try std.testing.expectEqual(@as(u64, 0), tear_count);
    try std.testing.expect(throughput_k > threshold_k);
}
