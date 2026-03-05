const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const cudaSuccess: c_int = 0;
const CudaDevicePtr = usize;

extern "cuda" fn cuInit(flags: c_uint) c_int;
extern "cuda" fn cuDeviceGet(device: *c_int, ordinal: c_int) c_int;
extern "cuda" fn cuCtxCreate(context: *?*anyopaque, flags: c_uint, device: c_int) c_int;
extern "cuda" fn cuCtxDestroy(context: ?*anyopaque) c_int;
extern "cuda" fn cuStreamCreate(stream: *?*anyopaque, flags: c_uint) c_int;
extern "cuda" fn cuStreamDestroy(stream: ?*anyopaque) c_int;
extern "cuda" fn cuMemAlloc(device_ptr: *CudaDevicePtr, size: usize) c_int;
extern "cuda" fn cuMemFree(device_ptr: CudaDevicePtr) c_int;
extern "cuda" fn cuMemcpyHtoDAsync(
    dst_device: CudaDevicePtr,
    src_host: *const anyopaque,
    size: usize,
    stream: ?*anyopaque,
) c_int;
extern "cuda" fn cuMemcpyDtoHAsync(
    dst_host: *anyopaque,
    src_device: CudaDevicePtr,
    size: usize,
    stream: ?*anyopaque,
) c_int;
extern "cuda" fn cuStreamSynchronize(stream: ?*anyopaque) c_int;

pub const CudaError = error{
    CudaDisabled,
    RuntimeUnavailable,
    InvalidDevice,
    AllocationFailed,
    TransferFailed,
};

fn mapCudaStatus(status: c_int) CudaError {
    return switch (status) {
        2 => error.AllocationFailed,
        100, 101 => error.InvalidDevice,
        else => error.RuntimeUnavailable,
    };
}

fn checkCuda(status: c_int) CudaError!void {
    if (status == cudaSuccess) return;
    return mapCudaStatus(status);
}

pub const CudaBuffer = struct {
    ptr: ?*anyopaque,
    size: usize,
};

pub const CudaContext = struct {
    const Self = @This();

    device: c_int,
    context: ?*anyopaque,
    stream: ?*anyopaque,

    pub fn init(device_id: c_int) CudaError!CudaContext {
        if (comptime !build_options.enable_cuda) return error.CudaDisabled;

        var device: c_int = 0;
        var context: ?*anyopaque = null;
        var stream: ?*anyopaque = null;
        try checkCuda(cuInit(0));
        try checkCuda(cuDeviceGet(&device, device_id));
        try checkCuda(cuCtxCreate(&context, 0, device));
        errdefer if (context) |ctx| {
            _ = cuCtxDestroy(ctx);
        };
        try checkCuda(cuStreamCreate(&stream, 0));

        return .{
            .device = device,
            .context = context,
            .stream = stream,
        };
    }

    pub fn alloc_device(self: *Self, size: usize) CudaError!CudaBuffer {
        _ = self;
        if (comptime !build_options.enable_cuda) return error.CudaDisabled;

        var device_ptr: CudaDevicePtr = 0;
        try checkCuda(cuMemAlloc(&device_ptr, size));
        return .{
            .ptr = if (device_ptr == 0) null else @ptrFromInt(device_ptr),
            .size = size,
        };
    }

    pub fn free_device(self: *Self, buffer: *CudaBuffer) CudaError!void {
        _ = self;
        if (comptime !build_options.enable_cuda) return error.CudaDisabled;
        if (buffer.ptr == null) return;

        const device_ptr: CudaDevicePtr = @intFromPtr(buffer.ptr.?);
        const status = cuMemFree(device_ptr);
        if (status != cudaSuccess) return error.RuntimeUnavailable;
        buffer.ptr = null;
        buffer.size = 0;
    }

    pub fn memcpy_host_to_device(self: *Self, dst: *anyopaque, src: *const anyopaque, size: usize) CudaError!void {
        if (comptime !build_options.enable_cuda) return error.CudaDisabled;
        if (size == 0) return;
        if (self.stream == null) return error.RuntimeUnavailable;

        const stream = self.stream.?;
        const dst_device: CudaDevicePtr = @intFromPtr(dst);
        const copy_status = cuMemcpyHtoDAsync(dst_device, src, size, stream);
        if (copy_status != cudaSuccess) return error.TransferFailed;

        const sync_status = cuStreamSynchronize(stream);
        if (sync_status != cudaSuccess) return error.TransferFailed;
    }

    pub fn memcpy_device_to_host(self: *Self, dst: *anyopaque, src: *const anyopaque, size: usize) CudaError!void {
        if (comptime !build_options.enable_cuda) return error.CudaDisabled;
        if (size == 0) return;
        if (self.stream == null) return error.RuntimeUnavailable;

        const stream = self.stream.?;
        const src_device: CudaDevicePtr = @intFromPtr(src);
        const copy_status = cuMemcpyDtoHAsync(dst, src_device, size, stream);
        if (copy_status != cudaSuccess) return error.TransferFailed;

        const sync_status = cuStreamSynchronize(stream);
        if (sync_status != cudaSuccess) return error.TransferFailed;
    }

    pub fn deinit(self: *Self) void {
        if (comptime !build_options.enable_cuda) return;
        if (self.stream) |stream| {
            _ = cuStreamDestroy(stream);
        }
        self.stream = null;
        if (self.context) |ctx| {
            _ = cuCtxDestroy(ctx);
        }
        self.context = null;
    }
};

test "cuda init is gated by -Denable_cuda" {
    if (comptime build_options.enable_cuda) return error.SkipZigTest;
    try std.testing.expectError(error.CudaDisabled, CudaContext.init(0));
}

test "cuda memcpy calls are gated by -Denable_cuda" {
    if (comptime build_options.enable_cuda) return error.SkipZigTest;

    var ctx = CudaContext{
        .device = 0,
        .context = null,
        .stream = null,
    };
    var host_dst: [16]u8 = .{0} ** 16;
    const host_src: [16]u8 = .{1} ** 16;

    try std.testing.expectError(
        error.CudaDisabled,
        ctx.memcpy_host_to_device(
            @ptrCast(&host_dst),
            @ptrCast(&host_src),
            host_src.len,
        ),
    );
}

test "cuda smoke init/deinit on enabled builds" {
    if (!comptime build_options.enable_cuda) return error.SkipZigTest;

    var ctx = CudaContext.init(0) catch |err| switch (err) {
        error.RuntimeUnavailable, error.InvalidDevice => return error.SkipZigTest,
        else => return err,
    };
    defer ctx.deinit();
}

test "benchmark: cuda transfer overhead 128f32" {
    if (!comptime build_options.enable_cuda) return error.SkipZigTest;

    var ctx = CudaContext.init(0) catch |err| switch (err) {
        error.RuntimeUnavailable, error.InvalidDevice => return error.SkipZigTest,
        else => return err,
    };
    defer ctx.deinit();

    var host_in: [128]f32 = .{0.0} ** 128;
    var host_out: [128]f32 = .{0.0} ** 128;
    for (&host_in, 0..) |*sample, i| {
        sample.* = @as(f32, @floatFromInt(i)) / 128.0;
    }

    var device_buf = ctx.alloc_device(host_in.len * @sizeOf(f32)) catch |err| switch (err) {
        error.RuntimeUnavailable, error.AllocationFailed => return error.SkipZigTest,
        else => return err,
    };
    defer ctx.free_device(&device_buf) catch {};

    const iterations: u64 = 200;

    for (0..10) |_| {
        try ctx.memcpy_host_to_device(
            device_buf.ptr.?,
            @ptrCast(&host_in),
            host_in.len * @sizeOf(f32),
        );
        try ctx.memcpy_device_to_host(
            @ptrCast(&host_out),
            device_buf.ptr.?,
            host_out.len * @sizeOf(f32),
        );
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try ctx.memcpy_host_to_device(
            device_buf.ptr.?,
            @ptrCast(&host_in),
            host_in.len * @sizeOf(f32),
        );
        try ctx.memcpy_device_to_host(
            @ptrCast(&host_out),
            device_buf.ptr.?,
            host_out.len * @sizeOf(f32),
        );
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_roundtrip = elapsed_ns / iterations;
    const us_per_roundtrip = @as(f64, @floatFromInt(ns_per_roundtrip)) / 1_000.0;

    std.debug.print(
        "\n[WP-064] cuda host<->device 128f32: {d:.3}us/roundtrip (budget: <500us)\n",
        .{us_per_roundtrip},
    );

    const budget_ns: u64 = if (builtin.mode == .Debug) 5_000_000 else 500_000;
    try std.testing.expect(ns_per_roundtrip < budget_ns);
}
