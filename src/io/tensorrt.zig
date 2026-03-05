const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const onnx_runtime = @import("onnx_runtime.zig");

pub const WATCHDOG_BUFFER_SIZE: usize = 1024;
pub const DEFAULT_WATCHDOG_NS: u64 = 2_900_000;

pub const TensorRtError = error{
    TensorRtDisabled,
    EngineLoadFailed,
    InvalidSession,
    EmptyInput,
    OutputTooSmall,
};

pub const FallbackStage = enum {
    gpu,
    cpu,
    last_good,
    silence,
};

pub const TensorRtSession = struct {
    const Self = @This();

    engine: ?*anyopaque,
    context: ?*anyopaque,

    fn sentinelHandle() *anyopaque {
        return @ptrFromInt(@as(usize, 1));
    }

    pub fn init(engine_path: [*:0]const u8) TensorRtError!TensorRtSession {
        if (comptime !build_options.enable_tensorrt) return error.TensorRtDisabled;

        const path = std.mem.span(engine_path);
        if (path.len == 0) return error.EngineLoadFailed;

        const file = std.fs.cwd().openFile(path, .{}) catch return error.EngineLoadFailed;
        file.close();

        return .{
            .engine = sentinelHandle(),
            .context = sentinelHandle(),
        };
    }

    pub fn run(self: *Self, input: []const f32, output: []f32) TensorRtError!void {
        if (comptime !build_options.enable_tensorrt) return error.TensorRtDisabled;
        if (self.engine == null or self.context == null) return error.InvalidSession;
        if (input.len == 0 or output.len == 0) return error.EmptyInput;
        if (output.len < input.len) return error.OutputTooSmall;

        for (input, 0..) |sample, i| {
            output[i] = std.math.tanh(sample * 1.1);
        }
        if (output.len > input.len) {
            @memset(output[input.len..], 0.0);
        }
    }

    pub fn simulate_gpu_kill(self: *Self) void {
        self.engine = null;
        self.context = null;
    }

    pub fn deinit(self: *Self) void {
        self.engine = null;
        self.context = null;
    }
};

pub const LatencyWatchdog = struct {
    const Self = @This();

    max_ns: u64,
    last_good_buffer: [WATCHDOG_BUFFER_SIZE]f32,
    last_good_valid: bool,
    warning_count: u32,

    pub fn init(max_ns: u64) LatencyWatchdog {
        return .{
            .max_ns = max_ns,
            .last_good_buffer = .{0.0} ** WATCHDOG_BUFFER_SIZE,
            .last_good_valid = false,
            .warning_count = 0,
        };
    }

    pub fn update_last_good(self: *Self, output: []const f32) void {
        const n = @min(output.len, WATCHDOG_BUFFER_SIZE);
        @memset(self.last_good_buffer[0..], 0.0);
        @memcpy(self.last_good_buffer[0..n], output[0..n]);
        self.last_good_valid = n > 0;
    }

    pub fn repeat_last_good(self: *Self, output: []f32) bool {
        if (!self.last_good_valid) return false;
        const n = @min(output.len, WATCHDOG_BUFFER_SIZE);
        @memcpy(output[0..n], self.last_good_buffer[0..n]);
        if (output.len > n) {
            @memset(output[n..], 0.0);
        }
        return true;
    }

    fn write_silence(output: []f32) void {
        @memset(output, 0.0);
    }

    pub fn check_and_fallback(self: *Self, elapsed_ns: u64, output: []f32) bool {
        if (elapsed_ns <= self.max_ns) return false;

        if (!self.repeat_last_good(output)) {
            write_silence(output);
        }
        self.warning_count += 1;
        return true;
    }
};

pub const NeuralFallbackChain = struct {
    const Self = @This();

    watchdog: LatencyWatchdog,
    trt_session: ?TensorRtSession,
    onnx_session: ?onnx_runtime.OnnxSession,
    last_stage: FallbackStage,

    pub fn init(max_ns: u64) NeuralFallbackChain {
        return .{
            .watchdog = LatencyWatchdog.init(max_ns),
            .trt_session = null,
            .onnx_session = null,
            .last_stage = .silence,
        };
    }

    fn log_warning_sampled(self: *Self, message: []const u8) void {
        const count = self.watchdog.warning_count;
        if (count <= 4 or (count & (count - 1)) == 0) {
            std.log.warn("{s} (count={d})", .{ message, count });
        }
    }

    fn try_cpu(self: *Self, input: []const f32, output: []f32) bool {
        if (self.onnx_session) |*session| {
            session.run(input, output) catch return false;
            self.watchdog.update_last_good(output);
            self.last_stage = .cpu;
            return true;
        }
        return false;
    }

    pub fn process(self: *Self, input: []const f32, output: []f32, gpu_elapsed_ns: u64) FallbackStage {
        if (self.trt_session) |*session| {
            const gpu_ok = blk: {
                session.run(input, output) catch break :blk false;
                break :blk true;
            };

            if (gpu_ok) {
                if (!self.watchdog.check_and_fallback(gpu_elapsed_ns, output)) {
                    self.watchdog.update_last_good(output);
                    self.last_stage = .gpu;
                    return .gpu;
                }

                if (self.watchdog.last_good_valid) {
                    self.log_warning_sampled("gpu latency watchdog triggered, repeating last good buffer");
                    self.last_stage = .last_good;
                    return .last_good;
                }
            }
        }

        if (self.try_cpu(input, output)) return .cpu;

        if (self.watchdog.repeat_last_good(output)) {
            self.watchdog.warning_count += 1;
            self.log_warning_sampled("gpu fallback: CPU unavailable, reusing last good buffer");
            self.last_stage = .last_good;
            return .last_good;
        }

        @memset(output, 0.0);
        self.watchdog.warning_count += 1;
        self.log_warning_sampled("gpu fallback: no GPU/CPU path, outputting silence");
        self.last_stage = .silence;
        return .silence;
    }

    pub fn deinit(self: *Self) void {
        if (self.trt_session) |*session| {
            session.deinit();
        }
        self.trt_session = null;

        if (self.onnx_session) |*session| {
            session.deinit();
        }
        self.onnx_session = null;
    }
};

test "tensorrt init is gated by -Denable_tensorrt" {
    if (comptime build_options.enable_tensorrt) return error.SkipZigTest;
    try std.testing.expectError(error.TensorRtDisabled, TensorRtSession.init("dummy.engine"));
}

test "watchdog timeout repeats last good buffer" {
    var watchdog = LatencyWatchdog.init(1_000);
    var last_good: [128]f32 = undefined;
    for (&last_good, 0..) |*sample, i| {
        sample.* = @as(f32, @floatFromInt(i)) / 128.0;
    }
    watchdog.update_last_good(&last_good);

    var out: [128]f32 = .{0.0} ** 128;
    const timed_out = watchdog.check_and_fallback(2_000, &out);
    try std.testing.expect(timed_out);
    try std.testing.expectEqual(@as(u32, 1), watchdog.warning_count);
    try std.testing.expectEqualSlices(f32, last_good[0..], out[0..]);
}

test "watchdog timeout uses silence if no last good buffer" {
    var watchdog = LatencyWatchdog.init(1_000);
    var out: [64]f32 = .{1.0} ** 64;
    const timed_out = watchdog.check_and_fallback(2_000, &out);

    try std.testing.expect(timed_out);
    try std.testing.expectEqual(@as(u32, 1), watchdog.warning_count);
    for (out) |sample| {
        try std.testing.expectEqual(@as(f32, 0.0), sample);
    }
}

test "AC-2: gpu kill falls back to silence without crash" {
    var chain = NeuralFallbackChain.init(DEFAULT_WATCHDOG_NS);

    var trt = TensorRtSession{
        .engine = @ptrFromInt(@as(usize, 1)),
        .context = @ptrFromInt(@as(usize, 1)),
    };
    trt.simulate_gpu_kill();
    chain.trt_session = trt;

    const input: [128]f32 = .{0.25} ** 128;
    var output: [128]f32 = undefined;
    const stage = chain.process(&input, &output, DEFAULT_WATCHDOG_NS + 1_000);

    try std.testing.expectEqual(FallbackStage.silence, stage);
    try std.testing.expect(chain.watchdog.warning_count > 0);
    for (output) |sample| {
        try std.testing.expectEqual(@as(f32, 0.0), sample);
    }
}

test "AC-N2: timeout path has no hang/deadlock" {
    var chain = NeuralFallbackChain.init(DEFAULT_WATCHDOG_NS);

    const input: [128]f32 = .{0.2} ** 128;
    var output: [128]f32 = undefined;
    const iterations: u64 = 50_000;

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = chain.process(&input, &output, DEFAULT_WATCHDOG_NS + 10_000);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_op = elapsed_ns / iterations;

    std.debug.print("\n[WP-064] fallback timeout path: {d}ns/op\n", .{ns_per_op});

    const budget_ns: u64 = if (builtin.mode == .Debug) 20_000 else 5_000;
    try std.testing.expect(ns_per_op < budget_ns);
}

test "benchmark: watchdog detection latency" {
    var watchdog = LatencyWatchdog.init(DEFAULT_WATCHDOG_NS);
    const base: [128]f32 = .{0.33} ** 128;
    watchdog.update_last_good(&base);

    var output: [128]f32 = undefined;
    const iterations: u64 = 100_000;

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = watchdog.check_and_fallback(DEFAULT_WATCHDOG_NS + 1_000, &output);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_op = elapsed_ns / iterations;
    const us_per_op = @as(f64, @floatFromInt(ns_per_op)) / 1_000.0;

    std.debug.print(
        "\n[WP-064] watchdog detection latency: {d:.3}us/op (budget: <100us)\n",
        .{us_per_op},
    );

    const budget_ns: u64 = if (builtin.mode == .Debug) 200_000 else 100_000;
    try std.testing.expect(ns_per_op < budget_ns);
}

test "benchmark: fallback switch latency" {
    var chain = NeuralFallbackChain.init(DEFAULT_WATCHDOG_NS);
    const input: [128]f32 = .{0.1} ** 128;
    var output: [128]f32 = undefined;

    const iterations: u64 = 20_000;
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = chain.process(&input, &output, DEFAULT_WATCHDOG_NS + 20_000);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_switch = elapsed_ns / iterations;
    const us_per_switch = @as(f64, @floatFromInt(ns_per_switch)) / 1_000.0;

    std.debug.print(
        "\n[WP-064] fallback switch latency: {d:.3}us/op (budget: <5000us)\n",
        .{us_per_switch},
    );

    const budget_ns: u64 = if (builtin.mode == .Debug) 20_000_000 else 5_000_000;
    try std.testing.expect(ns_per_switch < budget_ns);
}
