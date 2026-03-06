const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Engine = @import("../engine/engine.zig").Engine;
const param = @import("../engine/param.zig");

// ── WebKitGTK UserMessage IPC (WP-029) ───────────────────────────────
// Hand-written bindings only. WebKitGTK 4.1 does not expose the simplified
// "new_with_payload" helper from the issue sketch, so binary payloads are
// wrapped as GVariant byte arrays ("ay") backed by GBytes.

pub const WebKitWebView = opaque {};
pub const WebKitUserContentManager = opaque {};
pub const WebKitUserMessage = opaque {};
pub const GBytes = opaque {};
pub const GVariant = opaque {};
pub const GVariantType = opaque {};
pub const GUnixFDList = opaque {};
pub const GCancellable = opaque {};
pub const GAsyncResult = opaque {};
pub const GError = opaque {};
pub const GObject = opaque {};

pub const GAsyncReadyCallback = *const fn (?*GObject, ?*GAsyncResult, ?*anyopaque) callconv(.c) void;

extern "webkit2gtk-4.1" fn webkit_web_view_send_message_to_page(
    web_view: *WebKitWebView,
    message: *WebKitUserMessage,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

extern "webkit2gtk-4.1" fn webkit_web_view_send_message_to_page_finish(
    web_view: *WebKitWebView,
    result: *GAsyncResult,
    err: ?*?*GError,
) ?*WebKitUserMessage;

extern "webkit2gtk-4.1" fn webkit_user_message_new(
    name: [*:0]const u8,
    parameters: ?*GVariant,
) ?*WebKitUserMessage;

extern "webkit2gtk-4.1" fn webkit_user_message_new_with_fd_list(
    name: [*:0]const u8,
    parameters: ?*GVariant,
    fd_list: ?*GUnixFDList,
) ?*WebKitUserMessage;

extern "webkit2gtk-4.1" fn webkit_user_message_get_name(message: *WebKitUserMessage) [*:0]const u8;
extern "webkit2gtk-4.1" fn webkit_user_message_get_parameters(message: *WebKitUserMessage) ?*GVariant;
extern "webkit2gtk-4.1" fn webkit_user_message_get_fd_list(message: *WebKitUserMessage) ?*GUnixFDList;
extern "webkit2gtk-4.1" fn webkit_user_message_send_reply(message: *WebKitUserMessage, reply: *WebKitUserMessage) void;

extern "glib-2.0" fn g_bytes_new(data: ?*const anyopaque, size: usize) ?*GBytes;
extern "glib-2.0" fn g_bytes_unref(bytes: *GBytes) void;
extern "glib-2.0" fn g_bytes_get_data(bytes: *GBytes, size: ?*usize) ?*const anyopaque;
extern "glib-2.0" fn g_bytes_get_size(bytes: *GBytes) usize;
extern "glib-2.0" fn g_variant_new_from_bytes(
    type_: *const GVariantType,
    bytes: *GBytes,
    trusted: c_int,
) ?*GVariant;
extern "glib-2.0" fn g_variant_get_data_as_bytes(value: *GVariant) ?*GBytes;

extern "gobject-2.0" fn g_object_ref_sink(object: *anyopaque) *anyopaque;
extern "gobject-2.0" fn g_object_unref(object: *anyopaque) void;

pub const metering_message_name: [*:0]const u8 = "metering";
pub const param_command_message_name: [*:0]const u8 = "param-command";
pub const param_ack_message_name: [*:0]const u8 = "param-ack";

pub const UserMessageError = error{
    WebKitDisabled,
    BytesCreateFailed,
    VariantCreateFailed,
    MessageCreateFailed,
    MissingParameters,
    InvalidPayload,
    InvalidPayloadSize,
    UnexpectedMessage,
    InvalidParamId,
};

pub const MeteringData = extern struct {
    level_l: f32,
    level_r: f32,
    peak_l: f32,
    peak_r: f32,
    fft_bins: [512]f32,
    waveform: [512]f32,
    cpu_total: f32,
};

pub const ParamCommand = extern struct {
    param_id: u32,
    value: f32,
};

pub const ParamAck = extern struct {
    param_id: u32,
    applied: u32,
    value: f32,
};

const BorrowedPayload = struct {
    bytes: *GBytes,
    slice: []const u8,

    fn deinit(self: BorrowedPayload) void {
        g_bytes_unref(self.bytes);
    }
};

const bench_enforce = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
const bench_runs: usize = if (bench_enforce) 5 else 3;
const bench_warmup: usize = if (bench_enforce) 128 else 16;
const bench_small_iters: usize = if (bench_enforce) 2_048 else 256;
const bench_large_iters: usize = if (bench_enforce) 256 else 32;
const bench_roundtrip_iters: usize = if (bench_enforce) 1_024 else 128;

const BenchStats = struct {
    avg_ns: u64,
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

pub const BenchmarkMetrics = struct {
    send_1kb: BenchStats,
    send_64kb: BenchStats,
    roundtrip: BenchStats,
    metering: BenchStats,
    direct_1kb: BenchStats,
    metering_msgs_per_s: f64,
    overhead_ratio: f64,
};

const bench_payload_1kb = filledBytes(1024, 0x11);
const bench_payload_64kb = filledBytes(64 * 1024, 0x42);
const byte_array_variant_type: *const GVariantType = @ptrCast(@as([*:0]const u8, "ay"));

fn requireWebKit() UserMessageError!void {
    if (comptime !build_options.enable_webkit) return error.WebKitDisabled;
}

pub fn messageName(message: *WebKitUserMessage) []const u8 {
    return std.mem.span(webkit_user_message_get_name(message));
}

pub fn refSinkMessage(message: *WebKitUserMessage) *WebKitUserMessage {
    _ = g_object_ref_sink(@ptrCast(message));
    return message;
}

pub fn unrefMessage(message: *WebKitUserMessage) void {
    g_object_unref(@ptrCast(message));
}

fn newPayloadBytes(payload: []const u8) UserMessageError!*GBytes {
    const data_ptr: ?*const anyopaque = if (payload.len == 0) null else @ptrCast(payload.ptr);
    return g_bytes_new(data_ptr, payload.len) orelse error.BytesCreateFailed;
}

fn newPayloadVariant(payload: []const u8) UserMessageError!*GVariant {
    const bytes = try newPayloadBytes(payload);
    defer g_bytes_unref(bytes);

    return g_variant_new_from_bytes(byte_array_variant_type, bytes, 0) orelse error.VariantCreateFailed;
}

pub fn initMessageFromBytes(name: [*:0]const u8, payload: []const u8) UserMessageError!*WebKitUserMessage {
    try requireWebKit();

    const parameters = try newPayloadVariant(payload);
    return webkit_user_message_new(name, parameters) orelse error.MessageCreateFailed;
}

pub fn initMessageFromStruct(comptime T: type, name: [*:0]const u8, value: *const T) UserMessageError!*WebKitUserMessage {
    return initMessageFromBytes(name, std.mem.asBytes(value));
}

pub fn initMeteringMessage(data: *const MeteringData) UserMessageError!*WebKitUserMessage {
    return initMessageFromStruct(MeteringData, metering_message_name, data);
}

pub fn initParamCommandMessage(command: *const ParamCommand) UserMessageError!*WebKitUserMessage {
    return initMessageFromStruct(ParamCommand, param_command_message_name, command);
}

pub fn initParamAckMessage(ack: *const ParamAck) UserMessageError!*WebKitUserMessage {
    return initMessageFromStruct(ParamAck, param_ack_message_name, ack);
}

pub inline fn send_metering(web_view: *WebKitWebView, data: *const MeteringData) UserMessageError!void {
    try requireWebKit();
    const message = try initMeteringMessage(data);
    webkit_web_view_send_message_to_page(web_view, message, null, null, null);
}

pub fn sendParamAck(message: *WebKitUserMessage, ack: *const ParamAck) UserMessageError!void {
    try requireWebKit();
    const reply = try initParamAckMessage(ack);
    webkit_user_message_send_reply(message, reply);
}

fn borrowedPayload(message: *WebKitUserMessage) UserMessageError!BorrowedPayload {
    const parameters = webkit_user_message_get_parameters(message) orelse return error.MissingParameters;
    const bytes = g_variant_get_data_as_bytes(parameters) orelse return error.InvalidPayload;

    const size = g_bytes_get_size(bytes);
    const data_ptr = g_bytes_get_data(bytes, null) orelse {
        g_bytes_unref(bytes);
        return error.InvalidPayload;
    };

    return .{
        .bytes = bytes,
        .slice = @as([*]const u8, @ptrCast(data_ptr))[0..size],
    };
}

pub fn decodeStructFromMessage(comptime T: type, message: *WebKitUserMessage) UserMessageError!T {
    var payload = try borrowedPayload(message);
    defer payload.deinit();

    if (payload.slice.len != @sizeOf(T)) return error.InvalidPayloadSize;

    var value: T = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&value), payload.slice);
    return value;
}

fn decodeParamId(raw_id: u32) UserMessageError!param.ParamID {
    const narrowed = std.math.cast(u16, raw_id) orelse return error.InvalidParamId;
    if (narrowed > @intFromEnum(param.ParamID.quality_mode)) return error.InvalidParamId;
    return @enumFromInt(narrowed);
}

pub fn handle_user_message(message: *WebKitUserMessage, engine: *Engine) UserMessageError!ParamAck {
    try requireWebKit();

    if (!std.mem.eql(u8, messageName(message), std.mem.span(param_command_message_name))) {
        return error.UnexpectedMessage;
    }

    const command = try decodeStructFromMessage(ParamCommand, message);
    const param_id = try decodeParamId(command.param_id);
    engine.param_state.set_param(param_id, command.value);

    return .{
        .param_id = command.param_id,
        .applied = 1,
        .value = command.value,
    };
}

pub fn measureBenchmarks() UserMessageError!BenchmarkMetrics {
    try requireWebKit();

    const send_1kb = try measurePayloadMessageCreate(bench_payload_1kb[0..], bench_small_iters);
    const send_64kb = try measurePayloadMessageCreate(bench_payload_64kb[0..], bench_large_iters);
    const roundtrip = try measureRoundtrip(bench_roundtrip_iters);
    const metering = try measureMetering(bench_small_iters);
    const direct_1kb = measureDirectCopy1kb(bench_small_iters);

    const direct_ns = @max(direct_1kb.median_ns, @as(u64, 1));

    return .{
        .send_1kb = send_1kb,
        .send_64kb = send_64kb,
        .roundtrip = roundtrip,
        .metering = metering,
        .direct_1kb = direct_1kb,
        .metering_msgs_per_s = 1_000_000_000.0 / @as(f64, @floatFromInt(@max(metering.median_ns, @as(u64, 1)))),
        .overhead_ratio = @as(f64, @floatFromInt(send_1kb.median_ns)) / @as(f64, @floatFromInt(direct_ns)),
    };
}

pub fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000.0;
}

fn measurePayloadMessageCreate(payload: []const u8, iterations: usize) UserMessageError!BenchStats {
    var samples: [bench_runs]u64 = undefined;
    for (&samples) |*sample| {
        var warmup: usize = 0;
        while (warmup < bench_warmup) : (warmup += 1) {
            const message = try initMessageFromBytes("bench-payload", payload);
            unrefMessage(refSinkMessage(message));
        }

        var timer = std.time.Timer.start() catch unreachable;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const message = try initMessageFromBytes("bench-payload", payload);
            unrefMessage(refSinkMessage(message));
        }
        sample.* = timer.read() / iterations;
    }
    return aggregateBench(samples);
}

fn measureMetering(iterations: usize) UserMessageError!BenchStats {
    var samples: [bench_runs]u64 = undefined;
    const metering = sampleMeteringData(0.25);

    for (&samples) |*sample| {
        var warmup: usize = 0;
        while (warmup < bench_warmup) : (warmup += 1) {
            const message = try initMeteringMessage(&metering);
            unrefMessage(refSinkMessage(message));
        }

        var timer = std.time.Timer.start() catch unreachable;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const message = try initMeteringMessage(&metering);
            unrefMessage(refSinkMessage(message));
        }
        sample.* = timer.read() / iterations;
    }
    return aggregateBench(samples);
}

fn measureRoundtrip(iterations: usize) UserMessageError!BenchStats {
    var samples: [bench_runs]u64 = undefined;
    const allocator = std.heap.page_allocator;

    for (&samples) |*sample| {
        const engine = Engine.create(allocator, 48_000.0) catch unreachable;
        defer engine.destroy(allocator);

        var warmup: usize = 0;
        while (warmup < bench_warmup) : (warmup += 1) {
            const value = @as(f32, @floatFromInt(warmup & 0xFF)) * 0.5;
            try benchRoundtripIteration(engine, value);
        }

        var timer = std.time.Timer.start() catch unreachable;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const value = @as(f32, @floatFromInt(i & 0xFF)) * 0.5;
            try benchRoundtripIteration(engine, value);
        }
        sample.* = timer.read() / iterations;
    }
    return aggregateBench(samples);
}

fn benchRoundtripIteration(engine: *Engine, value: f32) UserMessageError!void {
    const command = ParamCommand{
        .param_id = @intFromEnum(param.ParamID.filter_cutoff),
        .value = value,
    };
    const message = try initParamCommandMessage(&command);
    _ = refSinkMessage(message);
    defer unrefMessage(message);

    const ack = try handle_user_message(message, engine);
    const reply = try initParamAckMessage(&ack);
    _ = refSinkMessage(reply);
    defer unrefMessage(reply);

    const decoded = try decodeStructFromMessage(ParamAck, reply);
    std.mem.doNotOptimizeAway(decoded);
}

fn measureDirectCopy1kb(iterations: usize) BenchStats {
    var samples: [bench_runs]u64 = undefined;
    var scratch: [bench_payload_1kb.len]u8 = undefined;

    for (&samples) |*sample| {
        var warmup: usize = 0;
        while (warmup < bench_warmup) : (warmup += 1) {
            std.mem.copyForwards(u8, scratch[0..], bench_payload_1kb[0..]);
            std.mem.doNotOptimizeAway(scratch[warmup % scratch.len]);
        }

        var timer = std.time.Timer.start() catch unreachable;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            std.mem.copyForwards(u8, scratch[0..], bench_payload_1kb[0..]);
            std.mem.doNotOptimizeAway(scratch[i % scratch.len]);
        }
        sample.* = timer.read() / iterations;
    }

    return aggregateBench(samples);
}

fn aggregateBench(samples_in: [bench_runs]u64) BenchStats {
    var sorted = samples_in;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));

    var sum: u64 = 0;
    for (sorted) |sample| sum += sample;

    return .{
        .avg_ns = sum / sorted.len,
        .median_ns = sorted[sorted.len / 2],
        .min_ns = sorted[0],
        .max_ns = sorted[sorted.len - 1],
    };
}

fn filledBytes(comptime len: usize, comptime salt: u8) [len]u8 {
    @setEvalBranchQuota(len * 2);
    var bytes: [len]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = @truncate((i * 17) + salt);
    }
    return bytes;
}

fn sampleMeteringData(seed: f32) MeteringData {
    var data = std.mem.zeroInit(MeteringData, .{});
    data.level_l = seed;
    data.level_r = seed * 0.5;
    data.peak_l = seed * 1.5;
    data.peak_r = seed * 1.75;
    data.cpu_total = seed * 20.0;

    for (0..data.fft_bins.len) |i| {
        data.fft_bins[i] = seed + @as(f32, @floatFromInt(i)) * 0.001;
    }
    for (0..data.waveform.len) |i| {
        data.waveform[i] = -seed + @as(f32, @floatFromInt(i)) * 0.002;
    }

    return data;
}

test "opaque WebKit types stay opaque" {
    try std.testing.expect(@typeInfo(WebKitWebView) == .@"opaque");
    try std.testing.expect(@typeInfo(WebKitUserMessage) == .@"opaque");
    try std.testing.expect(@typeInfo(GBytes) == .@"opaque");
    try std.testing.expect(@typeInfo(GVariant) == .@"opaque");
}

test "metering data roundtrip preserves binary payload" {
    if (comptime !build_options.enable_webkit) return error.SkipZigTest;

    const expected = sampleMeteringData(0.75);
    const message = try initMeteringMessage(&expected);
    _ = refSinkMessage(message);
    defer unrefMessage(message);

    try std.testing.expect(std.mem.eql(u8, messageName(message), std.mem.span(metering_message_name)));

    const decoded = try decodeStructFromMessage(MeteringData, message);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&expected), std.mem.asBytes(&decoded)));
}

test "handle_user_message applies ParamCommand to engine state" {
    if (comptime !build_options.enable_webkit) return error.SkipZigTest;

    const engine = try Engine.create(std.testing.allocator, 44_100.0);
    defer engine.destroy(std.testing.allocator);

    const command = ParamCommand{
        .param_id = @intFromEnum(param.ParamID.filter_cutoff),
        .value = 4_321.5,
    };
    const message = try initParamCommandMessage(&command);
    _ = refSinkMessage(message);
    defer unrefMessage(message);

    const ack = try handle_user_message(message, engine);
    const snap = engine.param_state.read_snapshot();

    try std.testing.expectEqual(command.param_id, ack.param_id);
    try std.testing.expectEqual(@as(u32, 1), ack.applied);
    try std.testing.expectEqual(command.value, ack.value);
    try std.testing.expectEqual(@as(f64, 4_321.5), snap.values[@intFromEnum(param.ParamID.filter_cutoff)]);
}

test "handle_user_message rejects invalid param ids" {
    if (comptime !build_options.enable_webkit) return error.SkipZigTest;

    const engine = try Engine.create(std.testing.allocator, 44_100.0);
    defer engine.destroy(std.testing.allocator);

    const command = ParamCommand{
        .param_id = 9999,
        .value = 1.0,
    };
    const message = try initParamCommandMessage(&command);
    _ = refSinkMessage(message);
    defer unrefMessage(message);

    try std.testing.expectError(error.InvalidParamId, handle_user_message(message, engine));
}

test "handle_user_message rejects unexpected message names" {
    if (comptime !build_options.enable_webkit) return error.SkipZigTest;

    const engine = try Engine.create(std.testing.allocator, 44_100.0);
    defer engine.destroy(std.testing.allocator);

    const unexpected = try initMessageFromBytes("not-a-command", bench_payload_1kb[0..32]);
    _ = refSinkMessage(unexpected);
    defer unrefMessage(unexpected);

    try std.testing.expectError(error.UnexpectedMessage, handle_user_message(unexpected, engine));
}

test "benchmark: WP-029 user-message transport" {
    if (comptime !build_options.enable_webkit) return error.SkipZigTest;

    const metrics = try measureBenchmarks();

    std.debug.print(
        \\
        \\  [WP-029] send 1KB: {d:.2}us/message (median, avg {d:.2}us, max {d:.2}us)
        \\  [WP-029] send 64KB: {d:.2}us/message (median, avg {d:.2}us, max {d:.2}us)
        \\  [WP-029] roundtrip: {d:.2}us/roundtrip (median, avg {d:.2}us)
        \\  [WP-029] metering: {d:.2}us/message (median) | {d:.2} msg/s
        \\  [WP-029] overhead: {d:.2}x vs direct 1KB copy
        \\    Schwellwerte: 1KB < 500us | 64KB < 2000us | roundtrip < 1000us | >= 60 msg/s | overhead < 10x
        \\
    , .{
        nsToUs(metrics.send_1kb.median_ns),
        nsToUs(metrics.send_1kb.avg_ns),
        nsToUs(metrics.send_1kb.max_ns),
        nsToUs(metrics.send_64kb.median_ns),
        nsToUs(metrics.send_64kb.avg_ns),
        nsToUs(metrics.send_64kb.max_ns),
        nsToUs(metrics.roundtrip.median_ns),
        nsToUs(metrics.roundtrip.avg_ns),
        nsToUs(metrics.metering.median_ns),
        metrics.metering_msgs_per_s,
        metrics.overhead_ratio,
    });

    if (bench_enforce) {
        try std.testing.expect(metrics.send_1kb.median_ns < 500_000);
        try std.testing.expect(metrics.send_64kb.median_ns < 2_000_000);
        try std.testing.expect(metrics.roundtrip.median_ns < 1_000_000);
        try std.testing.expect(metrics.metering_msgs_per_s >= 60.0);
        try std.testing.expect(metrics.overhead_ratio < 10.0);
    }
}
