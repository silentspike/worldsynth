const std = @import("std");
const builtin = @import("builtin");
const barrier_mod = @import("barrier.zig");

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

pub const MAX_WORKERS: usize = 14;
pub const WORK_DEQUE_LOG2_SIZE: u5 = 8; // 256 jobs per worker.

pub const JobFn = *const fn (ctx: *anyopaque, chunk_idx: u8, work_cycles: u16) void;

pub const VoiceChunkJob = struct {
    chunk_idx: u8,
    chunk_count: u8 = 1,
    work_cycles: u16 = 0,
    ctx: ?*anyopaque = null,
    run: ?JobFn = null,
};

pub const ThreadPool = struct {
    const Self = @This();
    const WorkerDeque = ChaseLevDeque(VoiceChunkJob, WORK_DEQUE_LOG2_SIZE);

    deques: [MAX_WORKERS]WorkerDeque = undefined,
    barrier: barrier_mod.Barrier = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    threads: [MAX_WORKERS]?std.Thread = [_]?std.Thread{null} ** MAX_WORKERS,
    n_workers: u8 = 0,
    next_owner: u8 = 0,
    steal_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    steal_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(self: *Self, requested_workers: u8) !void {
        self.shutdown();

        for (0..MAX_WORKERS) |i| {
            self.deques[i] = .{};
            self.threads[i] = null;
        }

        const clamped: usize = @min(@as(usize, requested_workers), MAX_WORKERS);
        if (clamped == 0) {
            self.n_workers = 0;
            self.barrier.reset(0);
            return;
        }

        self.n_workers = @intCast(clamped);
        self.next_owner = 0;
        self.steal_events.store(0, .release);
        self.steal_enabled.store(false, .release);
        self.barrier.reset(0);
        self.running.store(true, .release);

        var started: usize = 0;
        errdefer {
            self.running.store(false, .release);
            for (self.threads[0..started]) |*maybe_thread| {
                if (maybe_thread.*) |thread| thread.join();
                maybe_thread.* = null;
            }
            self.n_workers = 0;
            self.barrier.reset(0);
        }

        for (0..clamped) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, struct {
                fn run(pool: *Self, worker_id: u8) void {
                    pool.workerLoop(worker_id);
                }
            }.run, .{ self, @as(u8, @intCast(i)) });
            started += 1;
        }
    }

    pub fn shutdown(self: *Self) void {
        _ = self.running.swap(false, .acq_rel);

        const count: usize = self.n_workers;
        for (self.threads[0..count]) |*maybe_thread| {
            if (maybe_thread.*) |thread| thread.join();
            maybe_thread.* = null;
        }

        self.n_workers = 0;
        self.next_owner = 0;
        self.barrier.reset(0);
        self.steal_enabled.store(false, .release);
    }

    pub inline fn wait(self: *Self) void {
        self.barrier.wait();
    }

    pub inline fn worker_count(self: *const Self) u8 {
        return self.n_workers;
    }

    pub inline fn current_steal_events(self: *const Self) u32 {
        return self.steal_events.load(.acquire);
    }

    pub fn dispatch_chunk_jobs(self: *Self, n_chunks: u8, prototype: VoiceChunkJob) u32 {
        if (self.n_workers == 0 or n_chunks == 0) {
            self.steal_events.store(0, .release);
            self.barrier.reset(0);
            return 0;
        }

        const n_workers: usize = self.n_workers;
        const requested: usize = n_chunks;
        const workers_used: usize = @min(n_workers, requested);
        const base_chunks: usize = requested / workers_used;
        const remainder_chunks: usize = requested % workers_used;
        self.steal_events.store(0, .release);
        self.steal_enabled.store(false, .release);
        self.barrier.reset(@intCast(workers_used));

        const owner_start: usize = self.next_owner;
        var enqueued_jobs: usize = 0;
        var enqueued_chunks: usize = 0;
        var next_chunk: usize = 0;
        for (0..workers_used) |i| {
            const chunks_for_worker = base_chunks + @intFromBool(i < remainder_chunks);
            std.debug.assert(chunks_for_worker > 0);

            var job = prototype;
            job.chunk_idx = @intCast(next_chunk);
            job.chunk_count = @intCast(chunks_for_worker);
            next_chunk += chunks_for_worker;

            const preferred: u8 = @intCast((owner_start + i) % n_workers);
            if (!self.pushToWorker(preferred, job)) break;
            enqueued_jobs += 1;
            enqueued_chunks += chunks_for_worker;
        }

        self.next_owner = @intCast((owner_start + enqueued_jobs) % n_workers);

        if (enqueued_jobs < workers_used) {
            var missing = workers_used - enqueued_jobs;
            while (missing > 0) : (missing -= 1) {
                self.barrier.worker_done();
            }
        }

        return @intCast(enqueued_chunks);
    }

    pub fn dispatch_chunk_jobs_skewed(self: *Self, n_chunks: u8, target_worker: u8, prototype: VoiceChunkJob) u32 {
        if (self.n_workers == 0 or n_chunks == 0) {
            self.steal_events.store(0, .release);
            self.barrier.reset(0);
            return 0;
        }

        const n_workers: usize = self.n_workers;
        const target: u8 = @intCast(@as(usize, target_worker) % n_workers);
        const requested: usize = n_chunks;
        self.steal_events.store(0, .release);
        self.steal_enabled.store(true, .release);
        self.barrier.reset(@intCast(requested));

        var enqueued: usize = 0;
        for (0..requested) |i| {
            var job = prototype;
            job.chunk_idx = @intCast(i);
            job.chunk_count = 1;
            if (!self.pushToWorker(target, job)) break;
            enqueued += 1;
        }

        if (enqueued < requested) {
            var missing = requested - enqueued;
            while (missing > 0) : (missing -= 1) {
                self.barrier.worker_done();
            }
        }

        return @intCast(enqueued);
    }

    fn pushToWorker(self: *Self, preferred_worker: u8, job: VoiceChunkJob) bool {
        if (self.n_workers == 0) return false;

        const n_workers: usize = self.n_workers;
        const start: usize = preferred_worker;
        for (0..n_workers) |offset| {
            const idx: usize = (start + offset) % n_workers;
            if (self.deques[idx].push(job)) return true;
        }
        return false;
    }

    fn workerLoop(self: *Self, my_id: u8) void {
        const my_idx: usize = my_id;
        var steal_cursor: usize = my_idx;
        var idle_spins: u32 = 0;

        while (self.running.load(.acquire)) {
            // Dispatch thread is the single owner/writer of `bottom` (push side).
            // Workers consume via `steal` (top side): own queue first, then others.
            if (self.deques[my_idx].steal()) |job| {
                process_voice_chunk(job);
                self.barrier.worker_done();
                idle_spins = 0;
                continue;
            }

            var stolen = false;
            const n_workers: usize = self.n_workers;
            const can_steal = self.steal_enabled.load(.acquire);
            if (can_steal and n_workers > 1 and (idle_spins & 3) == 0) {
                var offset: usize = 1;
                while (offset < n_workers) : (offset += 1) {
                    const victim: usize = (steal_cursor + offset) % n_workers;

                    // Keep single remaining jobs local to reduce thrash under skewed loads.
                    if (self.deques[victim].approx_len() <= 1) continue;

                    if (self.deques[victim].steal()) |job| {
                        _ = self.steal_events.fetchAdd(1, .acq_rel);
                        process_voice_chunk(job);
                        self.barrier.worker_done();
                        idle_spins = 0;
                        steal_cursor = victim;
                        stolen = true;
                        break;
                    }
                }
            }

            if (!stolen) {
                idle_spins +%= 1;
                if (idle_spins >= 256 and (idle_spins & 31) == 0) {
                    std.Thread.yield() catch {};
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }

    fn process_voice_chunk(job: VoiceChunkJob) void {
        const chunk_count: u8 = if (job.chunk_count == 0) 1 else job.chunk_count;

        if (job.run) |run| {
            if (job.ctx) |ctx| {
                var idx: u8 = 0;
                while (idx < chunk_count) : (idx += 1) {
                    run(ctx, job.chunk_idx + idx, job.work_cycles);
                }
                return;
            }
        }

        const work_cycles: u16 = if (job.work_cycles == 0) 64 else job.work_cycles;
        var sink: u32 = 0;
        var chunk: u8 = 0;
        while (chunk < chunk_count) : (chunk += 1) {
            const absolute_chunk = @as(u32, job.chunk_idx) + @as(u32, chunk);
            sink = syntheticWork(sink ^ absolute_chunk, work_cycles);
        }
        std.mem.doNotOptimizeAway(&sink);
    }
};

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
    const BATCHES: usize = if (benchmark_enforced) 256 else 96;
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
    const BATCHES: usize = if (benchmark_enforced) 256 else 96;
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
    const ITEMS: usize = if (benchmark_enforced) 200_000 else 50_000;
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

const PoolVerifyCtx = struct {
    seen: []std.atomic.Value(u8),
    processed: *std.atomic.Value(u32),
    duplicates: *std.atomic.Value(bool),
};

fn initSeenSlice(seen: []std.atomic.Value(u8)) void {
    for (seen) |*slot| {
        slot.* = std.atomic.Value(u8).init(0);
    }
}

fn recordChunkCallback(ctx_ptr: *anyopaque, chunk_idx: u8, work_cycles: u16) void {
    const ctx: *PoolVerifyCtx = @ptrCast(@alignCast(ctx_ptr));

    var spins: u16 = 0;
    while (spins < work_cycles) : (spins += 1) {
        std.atomic.spinLoopHint();
    }

    const idx: usize = chunk_idx;
    if (idx >= ctx.seen.len) {
        ctx.duplicates.store(true, .release);
        return;
    }

    if (ctx.seen[idx].cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        ctx.duplicates.store(true, .release);
    }
    _ = ctx.processed.fetchAdd(1, .acq_rel);
}

const PoolBenchPoint = struct {
    workers: u8,
    ns_per_block: u64,
    speedup: f64,
    efficiency: f64,
    steal_rate: f64,
};

inline fn syntheticWork(seed: u32, work_cycles: u16) u32 {
    var state = seed *% 1664525 +% 1013904223;
    var i: u16 = 0;
    while (i < work_cycles) : (i += 1) {
        state = state *% 1664525 +% 1013904223;
        state ^= state >> 13;
    }
    return state;
}

fn runSequentialSynthetic(blocks: usize, n_chunks: usize, work_cycles: u16) !u64 {
    var sink: u32 = 0;
    var timer = try std.time.Timer.start();
    for (0..blocks) |_| {
        for (0..n_chunks) |chunk_idx| {
            sink = syntheticWork(sink ^ @as(u32, @intCast(chunk_idx)), work_cycles);
        }
    }
    std.mem.doNotOptimizeAway(&sink);
    return timer.read() / blocks;
}

fn benchThreadPoolPoint(workers: u8, blocks: usize, n_chunks: u8, work_cycles: u16, baseline_ns: u64) !PoolBenchPoint {
    var pool: ThreadPool = .{};
    try pool.init(workers);
    defer pool.shutdown();

    const prototype = VoiceChunkJob{
        .chunk_idx = 0,
        .work_cycles = work_cycles,
        .ctx = null,
        .run = null,
    };

    for (0..12) |_| {
        _ = pool.dispatch_chunk_jobs(n_chunks, prototype);
        pool.wait();
    }

    var total_ns: u64 = 0;
    var total_steals: u64 = 0;
    var total_jobs: u64 = 0;
    for (0..blocks) |_| {
        var timer = try std.time.Timer.start();
        const dispatched = pool.dispatch_chunk_jobs(n_chunks, prototype);
        pool.wait();
        total_ns += timer.read();
        total_steals += pool.current_steal_events();
        total_jobs += dispatched;
    }

    const ns_per_block = total_ns / blocks;
    const speedup = @as(f64, @floatFromInt(baseline_ns)) / @as(f64, @floatFromInt(ns_per_block));
    const efficiency = speedup / @as(f64, @floatFromInt(workers));
    const steal_rate = if (total_jobs == 0)
        0.0
    else
        @as(f64, @floatFromInt(total_steals)) * 100.0 / @as(f64, @floatFromInt(total_jobs));

    return .{
        .workers = workers,
        .ns_per_block = ns_per_block,
        .speedup = speedup,
        .efficiency = efficiency,
        .steal_rate = steal_rate,
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

test "WP-025 AC-1: dispatch 8 chunks, barrier.wait returns, all chunks processed" {
    var pool: ThreadPool = .{};
    try pool.init(4);
    defer pool.shutdown();

    var seen: [8]std.atomic.Value(u8) = undefined;
    initSeenSlice(&seen);

    var processed = std.atomic.Value(u32).init(0);
    var duplicates = std.atomic.Value(bool).init(false);
    var ctx = PoolVerifyCtx{
        .seen = seen[0..],
        .processed = &processed,
        .duplicates = &duplicates,
    };

    const dispatched = pool.dispatch_chunk_jobs(8, .{
        .chunk_idx = 0,
        .work_cycles = 128,
        .ctx = &ctx,
        .run = recordChunkCallback,
    });
    try std.testing.expectEqual(@as(u32, 8), dispatched);

    pool.wait();

    try std.testing.expectEqual(@as(u32, 8), processed.load(.acquire));
    try std.testing.expect(!duplicates.load(.acquire));
    for (seen) |slot| {
        try std.testing.expectEqual(@as(u8, 1), slot.load(.acquire));
    }
}

test "WP-025 AC-2: work-stealing finishes skewed 7-job load on 2 workers" {
    var pool: ThreadPool = .{};
    try pool.init(2);
    defer pool.shutdown();

    var steal_events_total: u32 = 0;
    const rounds: usize = if (benchmark_enforced) 32 else 8;
    for (0..rounds) |_| {
        var seen: [7]std.atomic.Value(u8) = undefined;
        initSeenSlice(&seen);

        var processed = std.atomic.Value(u32).init(0);
        var duplicates = std.atomic.Value(bool).init(false);
        var ctx = PoolVerifyCtx{
            .seen = seen[0..],
            .processed = &processed,
            .duplicates = &duplicates,
        };

        const dispatched = pool.dispatch_chunk_jobs_skewed(7, 0, .{
            .chunk_idx = 0,
            .work_cycles = 4096,
            .ctx = &ctx,
            .run = recordChunkCallback,
        });
        try std.testing.expectEqual(@as(u32, 7), dispatched);

        pool.wait();

        try std.testing.expectEqual(@as(u32, 7), processed.load(.acquire));
        try std.testing.expect(!duplicates.load(.acquire));
        for (seen) |slot| {
            try std.testing.expectEqual(@as(u8, 1), slot.load(.acquire));
        }

        steal_events_total += pool.current_steal_events();
    }
    try std.testing.expect(steal_events_total > 0);
}

test "WP-025 AC-N1: shutdown terminates without deadlock within 5s" {
    var pool: ThreadPool = .{};
    try pool.init(4);

    _ = pool.dispatch_chunk_jobs(64, .{
        .chunk_idx = 0,
        .work_cycles = 512,
        .ctx = null,
        .run = null,
    });

    var timer = try std.time.Timer.start();
    pool.shutdown();
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
}

test "WP-025 AC-N2: thread pool has fixed-size storage and no allocator field" {
    comptime {
        const fields = @typeInfo(ThreadPool).@"struct".fields;
        for (fields) |field| {
            if (std.mem.indexOf(u8, field.name, "alloc") != null) {
                @compileError("ThreadPool must not contain allocator fields");
            }
        }
    }

    try std.testing.expect(true);
    try std.testing.expectEqual(@as(usize, MAX_WORKERS), @typeInfo(@TypeOf((@as(ThreadPool, .{})).deques)).array.len);
}

test "WP-025 AC-B1: thread-pool scaling benchmark" {
    const blocks: usize = if (benchmark_enforced) 180 else 6;
    const n_chunks: u8 = if (benchmark_enforced) 64 else 16;
    const work_cycles: u16 = if (benchmark_enforced) 3072 else 24;

    const baseline_ns = try runSequentialSynthetic(blocks, n_chunks, work_cycles);
    const points = [_]PoolBenchPoint{
        try benchThreadPoolPoint(1, blocks, n_chunks, work_cycles, baseline_ns),
        try benchThreadPoolPoint(2, blocks, n_chunks, work_cycles, baseline_ns),
        try benchThreadPoolPoint(4, blocks, n_chunks, work_cycles, baseline_ns),
        try benchThreadPoolPoint(8, blocks, n_chunks, work_cycles, baseline_ns),
    };

    std.debug.print(
        "\n  [WP-025] Thread-pool scaling ({d} chunks, work_cycles={d}, blocks={d})\n" ++
            "    baseline (single-thread synthetic): {d}ns/block\n",
        .{ n_chunks, work_cycles, blocks, baseline_ns },
    );
    std.debug.print("    | Workers | ns/block | Speedup | Efficiency | Steal-Rate |\n", .{});
    std.debug.print("    |---------|----------|---------|------------|------------|\n", .{});
    for (points) |point| {
        std.debug.print("    | {d:7} | {d:8} | {d:7.2}x | {d:9.1}% | {d:9.1}% |\n", .{
            point.workers,
            point.ns_per_block,
            point.speedup,
            point.efficiency * 100.0,
            point.steal_rate,
        });
    }

    const p1 = points[0];
    const p4 = points[2];
    const p8 = points[3];
    const p4_pool_speedup = @as(f64, @floatFromInt(p1.ns_per_block)) / @as(f64, @floatFromInt(p4.ns_per_block));
    const p4_pool_efficiency = p4_pool_speedup / 4.0;

    std.debug.print("    pool-baseline speedup (1->4 workers): {d:.2}x | efficiency: {d:.1}%\n", .{
        p4_pool_speedup,
        p4_pool_efficiency * 100.0,
    });

    if (benchmark_enforced) {
        // Dual-system thresholds from measured ReleaseFast baselines (WP-025):
        // TODO: fill after first full baseline run (remote + local znver3).
        // Initial guard-rails keep AC-B1 meaningful in CI while avoiding flaky oversubscription gates.
        const ns_threshold: u64 = 550_000;
        const speedup_threshold: f64 = 1.20;
        const efficiency_threshold: f64 = 0.25;
        const steal_rate_max_pct: f64 = 20.0;

        // Gate on 4-worker point for stable CI on a 4-core build host.
        try std.testing.expect(p4.ns_per_block < ns_threshold);
        try std.testing.expect(p4_pool_speedup > speedup_threshold);
        try std.testing.expect(p4_pool_efficiency > efficiency_threshold);
        try std.testing.expect(p8.steal_rate < steal_rate_max_pct);
    } else {
        // Debug mode: keep this benchmark informative and lightweight only.
        try std.testing.expect(points[0].ns_per_block > 0);
    }
}
