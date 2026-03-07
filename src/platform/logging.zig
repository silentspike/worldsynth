const std = @import("std");
const builtin = @import("builtin");
const ring_buffer = @import("ring_buffer.zig");

// ── Lock-free Logging (WP-138) ──────────────────────────────────────
// RT-safe structured logging via SPSC ring buffer.
// Producer (audio thread): log_rt() — no mutex, no alloc, no syscall.
// Consumer (IO thread): drain() — reads all entries, writes formatted text.
// Timestamp via vDSO (std.time.Instant), ~20-40ns, no kernel transition.

pub const LogLevel = enum(u2) { debug, info, warn, err };

pub const LogEntry = struct {
    timestamp_ns: u64 = 0,
    level: LogLevel = .info,
    msg: [128]u8 = .{0} ** 128,
    msg_len: u8 = 0,
};

pub const RING_SIZE: usize = 4096;

pub const LogRingBuffer = struct {
    ring: ring_buffer.RingBuffer(LogEntry, RING_SIZE) = .{},
    drop_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// RT-safe log write. No mutex, no allocation, no syscall (vDSO timestamp).
    /// On full buffer the entry is silently dropped (drop_count incremented).
    pub inline fn log_rt(self: *LogRingBuffer, level: LogLevel, msg: []const u8) void {
        var entry: LogEntry = .{};
        entry.timestamp_ns = getTimestampNs();
        entry.level = level;
        const copy_len: u8 = @intCast(@min(msg.len, 128));
        entry.msg_len = copy_len;
        @memcpy(entry.msg[0..copy_len], msg[0..copy_len]);
        if (!self.ring.write(entry)) {
            _ = self.drop_count.fetchAdd(1, .monotonic);
        }
    }

    /// IO-thread consumer: reads all pending entries and writes formatted text.
    /// Returns the number of entries drained.
    pub fn drain(self: *LogRingBuffer, writer: anytype) !usize {
        var count: usize = 0;
        while (self.ring.read()) |entry| {
            try writer.print("[{d}] [{s}] {s}\n", .{
                entry.timestamp_ns,
                @tagName(entry.level),
                entry.msg[0..entry.msg_len],
            });
            count += 1;
        }
        return count;
    }

    /// Number of entries dropped due to full buffer (monotonic counter).
    pub fn dropped(self: *const LogRingBuffer) u64 {
        return self.drop_count.load(.monotonic);
    }
};

/// Free-function wrapper for log_rt (Issue-spec compatibility).
pub inline fn log_rt(buf: *LogRingBuffer, level: LogLevel, msg: []const u8) void {
    buf.log_rt(level, msg);
}

// ── Timestamp ────────────────────────────────────────────────────────

inline fn getTimestampNs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    // Instant stores a duration since an arbitrary epoch.
    // On Linux this is CLOCK_BOOTTIME via vDSO — no syscall.
    // Zig 0.15.2 linux timespec uses .sec/.nsec (not .tv_sec/.tv_nsec).
    const sec: u64 = @intCast(instant.timestamp.sec);
    const nsec: u64 = @intCast(instant.timestamp.nsec);
    return sec * 1_000_000_000 + nsec;
}

// ── Tests ────────────────────────────────────────────────────────────

const benchmark_enforced = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

test "AC-1: 1000 log entries without blocking" {
    var buf: LogRingBuffer = .{};
    var timer = try std.time.Timer.start();

    for (0..1000) |_| {
        buf.log_rt(.info, "test message");
    }

    const elapsed_ns = timer.read();

    // Drain and verify count
    var output_buf: [256 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    const count = try buf.drain(fbs.writer());
    try std.testing.expectEqual(@as(usize, 1000), count);

    // 1000 writes must complete in < 1ms
    const threshold_ns: u64 = 1_000_000;
    std.debug.print("\n  [WP-138] AC-1: 1000 log_rt writes in {d}ns (threshold: <{d}ns)\n", .{ elapsed_ns, threshold_ns });
    try std.testing.expect(elapsed_ns < threshold_ns);
}

test "AC-2: log_rt contains no mutex or alloc" {
    // Verify LogRingBuffer has exactly 2 fields (ring + drop_count),
    // and neither is a Mutex or Allocator.
    const fields = @typeInfo(LogRingBuffer).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);

    inline for (fields) |f| {
        // Must not contain "Mutex" or "Allocator" in type name
        const name = @typeName(f.type);
        const has_mutex = comptime std.mem.indexOf(u8, name, "Mutex") != null;
        const has_alloc = comptime std.mem.indexOf(u8, name, "Allocator") != null;
        try std.testing.expect(!has_mutex);
        try std.testing.expect(!has_alloc);
    }
    std.debug.print("\n  [WP-138] AC-2: LogRingBuffer has no Mutex/Allocator fields\n", .{});
}

test "AC-3: drain reads all entries correctly" {
    var buf: LogRingBuffer = .{};

    const messages = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };
    const levels = [_]LogLevel{ .debug, .info, .warn, .err, .info };

    for (messages, levels) |msg, lvl| {
        buf.log_rt(lvl, msg);
    }

    var output_buf: [256 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    const count = try buf.drain(fbs.writer());
    try std.testing.expectEqual(@as(usize, 5), count);

    const text = fbs.getWritten();
    // Verify each message appears in output
    for (messages) |msg| {
        try std.testing.expect(std.mem.indexOf(u8, text, msg) != null);
    }
    // Verify level tags appear
    try std.testing.expect(std.mem.indexOf(u8, text, "[debug]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[warn]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[err]") != null);

    std.debug.print("\n  [WP-138] AC-3: drain read 5 entries with correct messages and levels\n", .{});
}

test "AC-4: buffer overflow drops entry, no crash" {
    var buf: LogRingBuffer = .{};
    const cap = buf.ring.capacity(); // 4095

    // Fill to capacity
    for (0..cap) |_| {
        buf.log_rt(.info, "fill");
    }
    try std.testing.expectEqual(@as(u64, 0), buf.dropped());

    // One more should be dropped
    buf.log_rt(.err, "overflow");
    try std.testing.expectEqual(@as(u64, 1), buf.dropped());

    // Existing entries are still readable
    var output_buf: [256 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    const count = try buf.drain(fbs.writer());
    try std.testing.expectEqual(cap, count);

    std.debug.print("\n  [WP-138] AC-4: overflow dropped 1, {d} entries still readable\n", .{cap});
}

test "AC-N1: empty buffer drain returns 0" {
    var buf: LogRingBuffer = .{};
    var output_buf: [256 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    const count = try buf.drain(fbs.writer());
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
    std.debug.print("\n  [WP-138] AC-N1: empty drain returned 0\n", .{});
}

test "LogEntry is fixed-size" {
    const size = @sizeOf(LogEntry);
    try std.testing.expect(size > 0);
    // msg: 128 + msg_len: 1 + level: 1 + timestamp: 8 + padding
    try std.testing.expect(size <= 256);
    std.debug.print("\n  [WP-138] LogEntry size: {d} bytes (fixed, comptime-known)\n", .{size});
}

test "message truncation at 128 bytes" {
    var buf: LogRingBuffer = .{};
    const long_msg = "A" ** 256;
    buf.log_rt(.warn, long_msg);

    const entry = buf.ring.read().?;
    try std.testing.expectEqual(@as(u8, 128), entry.msg_len);
    // First 128 bytes are 'A'
    for (entry.msg[0..128]) |c| {
        try std.testing.expectEqual(@as(u8, 'A'), c);
    }
    std.debug.print("\n  [WP-138] Message truncation: 256 bytes → msg_len=128\n", .{});
}

test "multi-thread: producer/consumer no data loss" {
    const N: usize = if (benchmark_enforced) 100_000 else 20_000;
    var buf: LogRingBuffer = .{};

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(b: *LogRingBuffer) void {
            for (0..N) |_| {
                // Spin until write succeeds (don't drop — we verify count)
                while (true) {
                    var entry: LogEntry = .{};
                    entry.level = .info;
                    const msg = "thread-msg";
                    entry.msg_len = msg.len;
                    @memcpy(entry.msg[0..msg.len], msg);
                    if (b.ring.write(entry)) break;
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{&buf});

    // Consumer: count all entries
    var received: usize = 0;
    while (received < N) {
        if (buf.ring.read()) |_| {
            received += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    producer.join();

    try std.testing.expectEqual(N, received);
    try std.testing.expectEqual(@as(u64, 0), buf.dropped());
    std.debug.print("\n  [WP-138] Multi-thread: {d} entries, 0 lost\n", .{N});
}

test "drop_count tracks overflow accurately" {
    var buf: LogRingBuffer = .{};
    const cap = buf.ring.capacity();

    // Fill completely
    for (0..cap) |_| {
        buf.log_rt(.info, "fill");
    }

    // Write M more — all should be dropped
    const M: usize = 50;
    for (0..M) |_| {
        buf.log_rt(.err, "overflow");
    }
    try std.testing.expectEqual(@as(u64, M), buf.dropped());

    std.debug.print("\n  [WP-138] drop_count: {d} overflows tracked correctly\n", .{M});
}

// ── Benchmarks ───────────────────────────────────────────────────────

test "benchmark: WP-138 lock-free logging" {
    const is_debug = builtin.mode == .Debug;

    // ── 1. Single log_rt latency (write-only, no read in hot loop) ──
    {
        var buf: LogRingBuffer = .{};
        // Write up to capacity (4095), measure only writes — no read overhead.
        const ops: usize = buf.ring.capacity();

        // Warmup: fill + drain once
        for (0..ops) |_| buf.log_rt(.info, "warmup");
        while (buf.ring.read()) |_| {}

        const runs = 5;
        var times: [runs]u64 = undefined;

        for (&times) |*t| {
            var timer = try std.time.Timer.start();
            for (0..ops) |_| {
                buf.log_rt(.info, "bench msg");
            }
            t.* = timer.read();
            // Drain for next run
            while (buf.ring.read()) |_| {}
        }

        std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
        const median_ns: f64 = @as(f64, @floatFromInt(times[runs / 2])) / @as(f64, @floatFromInt(ops));
        // Debug mode: 144-byte struct copy + vDSO + safety checks → ~8-10x slower
        const threshold: f64 = if (is_debug) 2000.0 else 200.0;

        std.debug.print("\n  [WP-138] log_rt latency — {d} ops (write-only), {d} runs\n", .{ ops, runs });
        std.debug.print("    median: {d:.1}ns/op (threshold: <{d:.0}ns)\n", .{ median_ns, threshold });
        try std.testing.expect(median_ns < threshold);
    }

    // ── 2. Throughput: 2-thread producer/consumer ──
    {
        const items: usize = if (benchmark_enforced) 1_000_000 else 100_000;
        var buf: LogRingBuffer = .{};

        const producer = try std.Thread.spawn(.{}, struct {
            fn run(b: *LogRingBuffer) void {
                for (0..items) |_| {
                    while (true) {
                        var entry: LogEntry = .{};
                        entry.level = .info;
                        const msg = "throughput";
                        entry.msg_len = msg.len;
                        @memcpy(entry.msg[0..msg.len], msg);
                        if (b.ring.write(entry)) break;
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{&buf});

        var timer = try std.time.Timer.start();
        var count: usize = 0;
        while (count < items) {
            if (buf.ring.read()) |_| {
                count += 1;
            } else {
                std.atomic.spinLoopHint();
            }
        }
        const elapsed_ns = timer.read();
        producer.join();

        const ops_per_sec: f64 = @as(f64, @floatFromInt(items)) * 1e9 / @as(f64, @floatFromInt(elapsed_ns));
        // Debug: 144-byte struct + safety checks + atomics → ~10-50x slower
        const threshold: f64 = if (is_debug) 10_000.0 else 100_000.0;

        std.debug.print("  [WP-138] throughput — {d} LogEntry items, 2 threads\n", .{items});
        std.debug.print("    {d:.0} logs/s (threshold: >{d:.0})\n", .{ ops_per_sec, threshold });
        try std.testing.expect(ops_per_sec > threshold);
    }

    // ── 3. Audio block overhead (write-only, drain excluded from timing) ──
    {
        var buf: LogRingBuffer = .{};
        const cap = buf.ring.capacity();
        const batches: usize = if (benchmark_enforced) 100 else 10;
        const total_ops = batches * cap;

        // Warmup
        for (0..cap) |_| buf.log_rt(.debug, "warmup");
        while (buf.ring.read()) |_| {}

        var total_ns: u64 = 0;
        for (0..batches) |_| {
            var timer = try std.time.Timer.start();
            for (0..cap) |_| {
                buf.log_rt(.debug, "block");
            }
            total_ns += timer.read();
            // Drain between batches (NOT timed)
            while (buf.ring.read()) |_| {}
        }

        const ns_per_block: f64 = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(total_ops));
        const threshold: f64 = if (is_debug) 2000.0 else 50.0;

        std.debug.print("  [WP-138] audio block overhead — {d} ops ({d} batches x {d})\n", .{ total_ops, batches, cap });
        std.debug.print("    {d:.1}ns/block (threshold: <{d:.0}ns)\n", .{ ns_per_block, threshold });
        try std.testing.expect(ns_per_block < threshold);
    }

    // ── 4. Drain throughput ──
    {
        var buf: LogRingBuffer = .{};
        const cap = buf.ring.capacity();

        // Fill buffer
        for (0..cap) |_| {
            buf.log_rt(.info, "drain-bench");
        }

        var output_buf: [1024 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&output_buf);

        var timer = try std.time.Timer.start();
        const count = try buf.drain(fbs.writer());
        const elapsed_ns = timer.read();

        const ns_per_entry: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(count));

        std.debug.print("  [WP-138] drain throughput — {d} entries batch\n", .{count});
        std.debug.print("    {d:.1}ns/entry\n", .{ns_per_entry});
    }
}
