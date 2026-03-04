const std = @import("std");
const tp_mod = @import("thread_pool.zig");

pub const CLAP_EXT_THREAD_POOL: [*:0]const u8 = "clap.thread-pool";
pub const CLAP_EXT_THREAD_CHECK: [*:0]const u8 = "clap.thread-check";

pub const VoiceChunkJob = tp_mod.VoiceChunkJob;

pub const ClapHost = extern struct {
    host_data: ?*anyopaque = null,
    get_extension: ?*const fn (host: *const ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque = null,
};

pub const HostTaskExecFn = *const fn (task_ctx: *anyopaque, task_index: u32) callconv(.c) void;

pub const ClapHostThreadPool = extern struct {
    request_exec: ?*const fn (
        host: *const ClapHost,
        task_count: u32,
        task_fn: HostTaskExecFn,
        task_ctx: *anyopaque,
    ) callconv(.c) bool = null,
};

pub const ClapHostThreadCheck = extern struct {
    is_audio_thread: ?*const fn (host: *const ClapHost) callconv(.c) bool = null,
};

pub const ClapThreadPoolAdapter = struct {
    const Self = @This();

    host: ?*const ClapHost = null,
    host_tp: ?*const ClapHostThreadPool = null,
    host_tc: ?*const ClapHostThreadCheck = null,

    pub fn init(self: *Self, host: ?*const ClapHost) void {
        self.shutdown();
        self.host = host;

        const h = host orelse return;
        const get_ext = h.get_extension orelse return;

        if (get_ext(h, CLAP_EXT_THREAD_POOL)) |ptr| {
            self.host_tp = @ptrCast(@alignCast(ptr));
        }
        if (get_ext(h, CLAP_EXT_THREAD_CHECK)) |ptr| {
            self.host_tc = @ptrCast(@alignCast(ptr));
        }
    }

    pub fn shutdown(self: *Self) void {
        self.host = null;
        self.host_tp = null;
        self.host_tc = null;
    }

    pub inline fn wait(_: *Self) void {}

    pub inline fn has_thread_pool(self: *const Self) bool {
        return self.host != null and self.host_tp != null and self.host_tp.?.request_exec != null;
    }

    pub inline fn is_audio_thread(self: *const Self) bool {
        if (self.host) |h| {
            if (self.host_tc) |tc| {
                if (tc.is_audio_thread) |check_fn| return check_fn(h);
            }
        }
        return true;
    }

    pub fn exec(self: *const Self, n_tasks: u32, task_fn: HostTaskExecFn, task_ctx: *anyopaque) bool {
        if (n_tasks == 0) return true;
        const h = self.host orelse return false;
        const tp = self.host_tp orelse return false;
        const request_exec = tp.request_exec orelse return false;
        return request_exec(h, n_tasks, task_fn, task_ctx);
    }

    // Same scheduling signature as ThreadPool.dispatch_chunk_jobs().
    pub fn dispatch_chunk_jobs(self: *Self, n_chunks: u8, prototype: VoiceChunkJob) u32 {
        if (n_chunks == 0) return 0;

        var state = DispatchState{
            .prototype = prototype,
        };

        const ok = self.exec(n_chunks, dispatchTask, &state);
        if (!ok) return 0;
        return n_chunks;
    }

    pub fn dispatch_chunk_jobs_skewed(self: *Self, n_chunks: u8, target_worker: u8, prototype: VoiceChunkJob) u32 {
        _ = target_worker;
        return self.dispatch_chunk_jobs(n_chunks, prototype);
    }

    const DispatchState = struct {
        prototype: VoiceChunkJob,
    };

    fn dispatchTask(task_ctx: *anyopaque, task_index: u32) callconv(.c) void {
        const state: *DispatchState = @ptrCast(@alignCast(task_ctx));
        var job = state.prototype;
        job.chunk_idx = @intCast(task_index);
        job.chunk_count = 1;
        processVoiceChunk(job);
    }

    fn processVoiceChunk(job: VoiceChunkJob) void {
        if (job.run) |run| {
            if (job.ctx) |ctx| {
                run(ctx, job.chunk_idx, job.work_cycles);
                return;
            }
        }

        const work_cycles = if (job.work_cycles == 0) @as(u16, 64) else job.work_cycles;
        var spins: u16 = 0;
        while (spins < work_cycles) : (spins += 1) {
            std.atomic.spinLoopHint();
        }
    }
};

fn dummyTask(_: *anyopaque, _: u32) callconv(.c) void {}

test "WP-026 AC-1: adapter compiles and resolves host thread-pool extension" {
    const Env = struct {
        fn requestExec(_: *const ClapHost, task_count: u32, task_fn: HostTaskExecFn, task_ctx: *anyopaque) callconv(.c) bool {
            var i: u32 = 0;
            while (i < task_count) : (i += 1) {
                task_fn(task_ctx, i);
            }
            return true;
        }

        fn getExtension(_: *const ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            if (std.mem.eql(u8, std.mem.span(id), std.mem.span(CLAP_EXT_THREAD_POOL))) {
                return @ptrCast(&pool);
            }
            return null;
        }

        var pool = ClapHostThreadPool{
            .request_exec = requestExec,
        };
    };

    var adapter = ClapThreadPoolAdapter{};
    const host = ClapHost{
        .host_data = null,
        .get_extension = Env.getExtension,
    };
    adapter.init(&host);

    try std.testing.expect(adapter.has_thread_pool());
    try std.testing.expect(adapter.exec(1, dummyTask, @ptrCast(&adapter)));
}

test "WP-026 AC-2: dispatch interface is signature-compatible with ThreadPool" {
    const threadpool_dispatch = @typeInfo(@TypeOf(tp_mod.ThreadPool.dispatch_chunk_jobs)).@"fn";
    const clap_dispatch = @typeInfo(@TypeOf(ClapThreadPoolAdapter.dispatch_chunk_jobs)).@"fn";

    try std.testing.expectEqual(threadpool_dispatch.params.len, clap_dispatch.params.len);
    try std.testing.expectEqual(threadpool_dispatch.return_type, clap_dispatch.return_type);
    try std.testing.expectEqual(threadpool_dispatch.params[1].type, clap_dispatch.params[1].type);
    try std.testing.expectEqual(threadpool_dispatch.params[2].type, clap_dispatch.params[2].type);
}

test "WP-026 AC-N1: adapter owns no worker thread fields" {
    comptime {
        const fields = @typeInfo(ClapThreadPoolAdapter).@"struct".fields;
        for (fields) |field| {
            if (field.type == std.Thread or field.type == ?std.Thread) {
                @compileError("ClapThreadPoolAdapter must not own spawned worker threads");
            }
        }
    }

    try std.testing.expect(true);
}

test "WP-026 AC-N2: graceful fallback if host has no thread-pool" {
    const Env = struct {
        fn getExtension(_: *const ClapHost, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
            return null;
        }
    };

    var adapter = ClapThreadPoolAdapter{};
    const host = ClapHost{
        .host_data = null,
        .get_extension = Env.getExtension,
    };
    adapter.init(&host);

    try std.testing.expect(!adapter.exec(1, dummyTask, @ptrCast(&adapter)));
    const dispatched = adapter.dispatch_chunk_jobs(4, .{
        .chunk_idx = 0,
        .chunk_count = 1,
        .work_cycles = 32,
        .ctx = null,
        .run = null,
    });
    try std.testing.expectEqual(@as(u32, 0), dispatched);
}

test "dispatch executes all chunk jobs through host thread-pool" {
    const Ctx = struct {
        seen: [8]u8 = [_]u8{0} ** 8,
        processed: u8 = 0,
    };

    const Env = struct {
        fn requestExec(_: *const ClapHost, task_count: u32, task_fn: HostTaskExecFn, task_ctx: *anyopaque) callconv(.c) bool {
            var i: u32 = 0;
            while (i < task_count) : (i += 1) {
                task_fn(task_ctx, i);
            }
            return true;
        }

        fn getExtension(_: *const ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            if (std.mem.eql(u8, std.mem.span(id), std.mem.span(CLAP_EXT_THREAD_POOL))) {
                return @ptrCast(&pool);
            }
            return null;
        }

        fn onChunk(ctx_ptr: *anyopaque, chunk_idx: u8, _: u16) void {
            const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
            if (chunk_idx < ctx.seen.len and ctx.seen[chunk_idx] == 0) {
                ctx.seen[chunk_idx] = 1;
                ctx.processed += 1;
            }
        }

        var pool = ClapHostThreadPool{
            .request_exec = requestExec,
        };
    };

    var ctx = Ctx{};
    const host = ClapHost{
        .host_data = null,
        .get_extension = Env.getExtension,
    };
    var adapter = ClapThreadPoolAdapter{};
    adapter.init(&host);

    const dispatched = adapter.dispatch_chunk_jobs(8, .{
        .chunk_idx = 0,
        .chunk_count = 1,
        .work_cycles = 0,
        .ctx = &ctx,
        .run = Env.onChunk,
    });
    try std.testing.expectEqual(@as(u32, 8), dispatched);
    try std.testing.expectEqual(@as(u8, 8), ctx.processed);
    for (ctx.seen) |v| {
        try std.testing.expectEqual(@as(u8, 1), v);
    }
}

test "thread-check integration returns host state when available" {
    const Env = struct {
        fn isAudioThreadTrue(_: *const ClapHost) callconv(.c) bool {
            return true;
        }

        fn isAudioThreadFalse(_: *const ClapHost) callconv(.c) bool {
            return false;
        }

        fn getExtensionTrue(_: *const ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            if (std.mem.eql(u8, std.mem.span(id), std.mem.span(CLAP_EXT_THREAD_CHECK))) {
                return @ptrCast(&check_true);
            }
            return null;
        }

        fn getExtensionFalse(_: *const ClapHost, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            if (std.mem.eql(u8, std.mem.span(id), std.mem.span(CLAP_EXT_THREAD_CHECK))) {
                return @ptrCast(&check_false);
            }
            return null;
        }

        var check_true = ClapHostThreadCheck{
            .is_audio_thread = isAudioThreadTrue,
        };
        var check_false = ClapHostThreadCheck{
            .is_audio_thread = isAudioThreadFalse,
        };
    };

    var adapter_true = ClapThreadPoolAdapter{};
    const host_true = ClapHost{
        .host_data = null,
        .get_extension = Env.getExtensionTrue,
    };
    adapter_true.init(&host_true);
    try std.testing.expect(adapter_true.is_audio_thread());

    var adapter_false = ClapThreadPoolAdapter{};
    const host_false = ClapHost{
        .host_data = null,
        .get_extension = Env.getExtensionFalse,
    };
    adapter_false.init(&host_false);
    try std.testing.expect(!adapter_false.is_audio_thread());
}
