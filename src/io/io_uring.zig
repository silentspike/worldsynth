const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

// ── io_uring File I/O (WP-137) ──────────────────────────────────────
// Non-blocking File I/O via io_uring (Linux 5.1+).
// Use cases: Preset/Sample/IR loading without blocking the audio thread.
// No heap allocation — all state lives in the kernel-mapped ring buffers.

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("io_uring requires Linux");
    }
}

/// Async File I/O context wrapping Linux io_uring.
/// Queue depth is configurable (must be power-of-two, max 32768).
/// Operations are queued with async_read/async_write, then submitted
/// in batch with submit(). Completions are polled with poll_completions()
/// or waited for with wait_completion().
pub const IoUringContext = struct {
    ring: linux.IoUring,

    /// Initialize io_uring with the given queue depth.
    /// `entries` must be a power of two (e.g. 32, 64, 128).
    pub fn init(entries: u16) !IoUringContext {
        return .{ .ring = try linux.IoUring.init(entries, 0) };
    }

    /// Release all io_uring resources.
    pub fn deinit(self: *IoUringContext) void {
        self.ring.deinit();
    }

    /// Queue a non-blocking read. Does NOT submit — call submit() after batching.
    /// `user_data` is returned in the completion entry to identify this operation.
    pub fn async_read(self: *IoUringContext, user_data: u64, fd: posix.fd_t, buf: []u8, offset: u64) !void {
        _ = try self.ring.read(user_data, fd, .{ .buffer = buf }, offset);
    }

    /// Queue a non-blocking write. Does NOT submit — call submit() after batching.
    /// `user_data` is returned in the completion entry to identify this operation.
    pub fn async_write(self: *IoUringContext, user_data: u64, fd: posix.fd_t, buf: []const u8, offset: u64) !void {
        _ = try self.ring.write(user_data, fd, buf, offset);
    }

    /// Submit all pending SQEs to the kernel. Returns the number submitted.
    pub fn submit(self: *IoUringContext) !u32 {
        return try self.ring.submit();
    }

    /// Non-blocking poll for completed operations. Returns the number of
    /// completions copied into `out`. Returns 0 if none are ready.
    pub fn poll_completions(self: *IoUringContext, out: []linux.io_uring_cqe) !u32 {
        return try self.ring.copy_cqes(out, 0);
    }

    /// Block until one completion is available and return it.
    pub fn wait_completion(self: *IoUringContext) !linux.io_uring_cqe {
        return try self.ring.copy_cqe();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Atomic counter for unique temp file names within a test run.
var tmp_counter: u32 = 0;

/// Helper: create a temp file with known content, return fd and sentinel path.
fn createTempFile(content: []const u8) !struct { fd: posix.fd_t, path: [48:0]u8 } {
    const id = @atomicRmw(u32, &tmp_counter, .Add, 1, .monotonic);
    var path: [48:0]u8 = @splat(0);
    const prefix = "/tmp/ws-uring-test-";
    @memcpy(path[0..prefix.len], prefix);
    // Append decimal id
    const suffix = std.fmt.bufPrint(path[prefix.len..], "{d}", .{id}) catch unreachable;
    path[prefix.len + suffix.len] = 0;

    const fd = try posix.open(
        path[0 .. prefix.len + suffix.len :0],
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        0o600,
    );
    if (content.len > 0) {
        var total: usize = 0;
        while (total < content.len) {
            total += try posix.write(fd, content[total..]);
        }
        try posix.lseek_SET(fd, 0);
    }
    return .{ .fd = fd, .path = path };
}

fn unlinkTemp(path: [:0]const u8) void {
    // Pass the slice up to (and excluding) the null terminator.
    posix.unlink(std.mem.sliceTo(path, 0)) catch {};
}

test "init and deinit" {
    var ctx = try IoUringContext.init(32);
    defer ctx.deinit();
    // If we got here, init succeeded and ring is valid.
}

test "async read file" {
    const expected = "Hello io_uring from WorldSynth!";
    const tmp = try createTempFile(expected);
    defer posix.close(tmp.fd);
    defer unlinkTemp(&tmp.path);

    var ctx = try IoUringContext.init(4);
    defer ctx.deinit();

    var buf: [64]u8 = undefined;
    try ctx.async_read(42, tmp.fd, &buf, 0);
    const submitted = try ctx.submit();
    try testing.expect(submitted >= 1);

    const cqe = try ctx.wait_completion();
    try testing.expectEqual(@as(u64, 42), cqe.user_data);
    try testing.expect(cqe.res > 0);

    const bytes_read: usize = @intCast(cqe.res);
    try testing.expectEqualSlices(u8, expected, buf[0..bytes_read]);
}

test "async write file" {
    const payload = "io_uring write test payload!";

    // Create empty temp file
    const tmp = try createTempFile("");
    defer posix.close(tmp.fd);
    defer unlinkTemp(&tmp.path);

    var ctx = try IoUringContext.init(4);
    defer ctx.deinit();

    try ctx.async_write(99, tmp.fd, payload, 0);
    const submitted = try ctx.submit();
    try testing.expect(submitted >= 1);

    const cqe = try ctx.wait_completion();
    try testing.expectEqual(@as(u64, 99), cqe.user_data);
    try testing.expect(cqe.res > 0);

    const bytes_written: usize = @intCast(cqe.res);
    try testing.expectEqual(payload.len, bytes_written);

    // Verify by reading back with posix.read
    try posix.lseek_SET(tmp.fd, 0);
    var verify_buf: [64]u8 = undefined;
    const read_len = try posix.read(tmp.fd, &verify_buf);
    try testing.expectEqualSlices(u8, payload, verify_buf[0..read_len]);
}

test "poll completions returns completed ops" {
    const content = "poll test data";
    const tmp = try createTempFile(content);
    defer posix.close(tmp.fd);
    defer unlinkTemp(&tmp.path);

    var ctx = try IoUringContext.init(8);
    defer ctx.deinit();

    // Queue 3 reads of the same file
    var bufs: [3][32]u8 = undefined;
    for (0..3) |i| {
        try posix.lseek_SET(tmp.fd, 0);
        try ctx.async_read(@intCast(i), tmp.fd, &bufs[i], 0);
    }
    const submitted = try ctx.submit();
    try testing.expect(submitted >= 3);

    // Wait and collect all completions
    var cqes: [8]linux.io_uring_cqe = undefined;
    var total: u32 = 0;
    while (total < 3) {
        const count = try ctx.poll_completions(cqes[total..]);
        if (count == 0) {
            // Spin briefly if nothing ready yet
            std.Thread.sleep(100_000); // 100us
            continue;
        }
        total += count;
    }
    try testing.expect(total >= 3);

    // All completions should have positive res
    for (cqes[0..total]) |cqe| {
        try testing.expect(cqe.res > 0);
    }
}

test "non-existent file returns error on open" {
    // io_uring operates on fds — the error happens at posix.open(), not in the ring.
    const result = posix.open("/tmp/worldsynth-nonexistent-file-12345", .{ .ACCMODE = .RDONLY }, 0);
    try testing.expectError(error.FileNotFound, result);
}

test "batch read 16 files" {
    const file_count = 16;
    const content = "batch-read-test-data-1234567890";

    // Create 16 temp files
    var fds: [file_count]posix.fd_t = undefined;
    var paths: [file_count][48:0]u8 = undefined;

    for (0..file_count) |i| {
        const tmp = try createTempFile(content);
        fds[i] = tmp.fd;
        paths[i] = tmp.path;
    }
    defer for (0..file_count) |i| {
        posix.close(fds[i]);
        unlinkTemp(&paths[i]);
    };

    var ctx = try IoUringContext.init(32);
    defer ctx.deinit();

    // Queue all 16 reads, then 1 submit
    var bufs: [file_count][64]u8 = undefined;
    for (0..file_count) |i| {
        try ctx.async_read(@intCast(i), fds[i], &bufs[i], 0);
    }
    const submitted = try ctx.submit();
    try testing.expect(submitted >= file_count);

    // Collect all completions
    var completed: u32 = 0;
    var cqes: [file_count]linux.io_uring_cqe = undefined;
    while (completed < file_count) {
        const count = try ctx.poll_completions(cqes[completed..]);
        if (count == 0) {
            std.Thread.sleep(100_000);
            continue;
        }
        completed += count;
    }
    try testing.expectEqual(@as(u32, file_count), completed);

    // Verify all reads succeeded with correct content
    for (cqes[0..completed]) |cqe| {
        try testing.expect(cqe.res > 0);
        const n: usize = @intCast(cqe.res);
        try testing.expectEqual(content.len, n);
    }
}

// ── Benchmarks ───────────────────────────────────────────────────────

const bench_enforce = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
const bench_runs: usize = if (bench_enforce) 5 else 3;
const bench_warmup: usize = if (bench_enforce) 32 else 4;
const bench_iters: usize = if (bench_enforce) 256 else 16;

const BenchStats = struct {
    avg_ns: u64,
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn aggregateBench(samples_in: anytype) BenchStats {
    var sorted: @TypeOf(samples_in) = samples_in;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));

    var sum: u64 = 0;
    for (sorted) |s| sum += s;

    return .{
        .avg_ns = sum / sorted.len,
        .median_ns = sorted[sorted.len / 2],
        .min_ns = sorted[0],
        .max_ns = sorted[sorted.len - 1],
    };
}

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000.0;
}

test "benchmark: WP-137 io_uring" {
    // --- Setup: create test files ---
    const small_size = 4096;
    const large_size: usize = if (bench_enforce) 10 * 1024 * 1024 else 512 * 1024; // 10MB release, 512KB debug

    // Small file (4KB)
    var small_content: [small_size]u8 = undefined;
    for (&small_content, 0..) |*b, i| b.* = @truncate(i *% 17 +% 0x42);
    const small_tmp = try createTempFile(&small_content);
    defer posix.close(small_tmp.fd);
    defer unlinkTemp(&small_tmp.path);

    // Large file (10MB) - create via helper then write additional data
    const large_tmp = try createTempFile("");
    const large_fd = large_tmp.fd;
    defer posix.close(large_fd);
    defer {
        var lp = large_tmp.path;
        unlinkTemp(&lp);
    }
    {
        var chunk: [small_size]u8 = undefined;
        for (&chunk, 0..) |*b, i| b.* = @truncate(i *% 31 +% 0xAB);
        var written: usize = 0;
        while (written < large_size) {
            const w = try posix.write(large_fd, &chunk);
            written += w;
        }
    }

    // --- Benchmark 1: Single Read (4KB) ---
    var single_samples: [bench_runs]u64 = undefined;
    {
        var ctx = try IoUringContext.init(4);
        defer ctx.deinit();
        var read_buf: [small_size]u8 = undefined;
        // Warmup
        for (0..bench_warmup) |_| {
            try ctx.async_read(0, small_tmp.fd, &read_buf, 0);
            _ = try ctx.submit();
            _ = try ctx.wait_completion();
        }
        for (&single_samples) |*sample| {
            var total_ns: u64 = 0;
            for (0..bench_iters) |_| {
                try ctx.async_read(0, small_tmp.fd, &read_buf, 0);
                var timer = try std.time.Timer.start();
                _ = try ctx.submit();
                _ = try ctx.wait_completion();
                total_ns += timer.read();
            }
            sample.* = total_ns / bench_iters;
        }
    }
    const single_stats = aggregateBench(single_samples);

    // --- Benchmark 2: Batch Read (16x 4KB) ---
    const batch_count = 16;
    var batch_fds: [batch_count]posix.fd_t = undefined;
    var batch_paths: [batch_count][48:0]u8 = undefined;
    for (0..batch_count) |i| {
        const tmp = try createTempFile(&small_content);
        batch_fds[i] = tmp.fd;
        batch_paths[i] = tmp.path;
    }
    defer for (0..batch_count) |i| {
        posix.close(batch_fds[i]);
        unlinkTemp(&batch_paths[i]);
    };

    var batch_samples: [bench_runs]u64 = undefined;
    {
        var batch_bufs: [batch_count][small_size]u8 = undefined;
        var ctx = try IoUringContext.init(32);
        defer ctx.deinit();
        // Warmup
        for (0..bench_warmup) |_| {
            for (0..batch_count) |i| {
                try ctx.async_read(@intCast(i), batch_fds[i], &batch_bufs[i], 0);
            }
            _ = try ctx.submit();
            for (0..batch_count) |_| _ = try ctx.wait_completion();
        }
        const batch_iters_count: usize = if (bench_enforce) 64 else 8;
        for (&batch_samples) |*sample| {
            var total_ns: u64 = 0;
            for (0..batch_iters_count) |_| {
                for (0..batch_count) |i| {
                    try ctx.async_read(@intCast(i), batch_fds[i], &batch_bufs[i], 0);
                }
                var timer = try std.time.Timer.start();
                _ = try ctx.submit();
                for (0..batch_count) |_| _ = try ctx.wait_completion();
                total_ns += timer.read();
            }
            sample.* = total_ns / batch_iters_count;
        }
    }
    const batch_stats = aggregateBench(batch_samples);

    // --- Benchmark 3: Large File (10MB) Throughput ---
    var large_samples: [bench_runs]u64 = undefined;
    {
        const chunk_size = 64 * 1024; // 64KB reads
        const chunks = large_size / chunk_size;
        var large_buf: [chunk_size]u8 = undefined;
        var ctx = try IoUringContext.init(4);
        defer ctx.deinit();
        // Warmup
        for (0..@min(bench_warmup, 2)) |_| {
            for (0..chunks) |c| {
                try ctx.async_read(0, large_fd, &large_buf, @intCast(c * chunk_size));
                _ = try ctx.submit();
                _ = try ctx.wait_completion();
            }
        }
        for (&large_samples) |*sample| {
            var timer = try std.time.Timer.start();
            for (0..chunks) |c| {
                try ctx.async_read(0, large_fd, &large_buf, @intCast(c * chunk_size));
                _ = try ctx.submit();
                _ = try ctx.wait_completion();
            }
            sample.* = timer.read();
        }
    }
    const large_stats = aggregateBench(large_samples);
    const large_mb_per_s = @as(f64, @floatFromInt(large_size)) / (@as(f64, @floatFromInt(@max(large_stats.median_ns, 1))) / 1_000_000_000.0) / (1024.0 * 1024.0);

    // --- Benchmark 4: Batch io_uring vs 16x blocking read() ---
    // Fair comparison: io_uring batch (1 submit for 16 reads) vs 16 sequential read()
    var blocking_batch_samples: [bench_runs]u64 = undefined;
    {
        var bb_bufs: [batch_count][small_size]u8 = undefined;
        for (0..bench_warmup) |_| {
            for (0..batch_count) |i| {
                try posix.lseek_SET(batch_fds[i], 0);
                _ = try posix.read(batch_fds[i], &bb_bufs[i]);
            }
        }
        const bb_iters: usize = if (bench_enforce) 64 else 8;
        for (&blocking_batch_samples) |*sample| {
            var total_ns: u64 = 0;
            for (0..bb_iters) |_| {
                var timer = try std.time.Timer.start();
                for (0..batch_count) |i| {
                    try posix.lseek_SET(batch_fds[i], 0);
                    _ = try posix.read(batch_fds[i], &bb_bufs[i]);
                }
                total_ns += timer.read();
            }
            sample.* = total_ns / bb_iters;
        }
    }
    const blocking_batch_stats = aggregateBench(blocking_batch_samples);
    const overhead_ratio = @as(f64, @floatFromInt(@max(batch_stats.median_ns, 1))) / @as(f64, @floatFromInt(@max(blocking_batch_stats.median_ns, 1)));

    // --- Print results ---
    std.debug.print(
        \\
        \\  [WP-137] single read 4KB:  {d:.2}us (median, avg {d:.2}us, min {d:.2}us, max {d:.2}us)
        \\  [WP-137] batch 16x4KB:     {d:.2}us (median, avg {d:.2}us)
        \\  [WP-137] large 10MB:       {d:.2} MB/s (median {d:.2}ms)
        \\  [WP-137] 16x blocking read(): {d:.2}us (median)
        \\  [WP-137] overhead ratio:   {d:.2}x (io_uring batch / blocking batch)
        \\    Schwellwerte: single < 100us | batch < 200us | large > 500 MB/s | overhead < 2x
        \\
    , .{
        nsToUs(single_stats.median_ns),
        nsToUs(single_stats.avg_ns),
        nsToUs(single_stats.min_ns),
        nsToUs(single_stats.max_ns),
        nsToUs(batch_stats.median_ns),
        nsToUs(batch_stats.avg_ns),
        large_mb_per_s,
        @as(f64, @floatFromInt(large_stats.median_ns)) / 1_000_000.0,
        nsToUs(blocking_batch_stats.median_ns),
        overhead_ratio,
    });

    // --- Enforce thresholds in release builds ---
    if (bench_enforce) {
        // Single submit+complete < 100us (issue says 50+100, we measure combined)
        try testing.expect(single_stats.median_ns < 100_000);
        // Batch 16 reads < 200us
        try testing.expect(batch_stats.median_ns < 200_000);
        // Large file > 500 MB/s
        try testing.expect(large_mb_per_s > 500.0);
        // Overhead < 2x vs blocking
        try testing.expect(overhead_ratio < 2.0);
    }
}
