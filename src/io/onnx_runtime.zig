const std = @import("std");
const build_options = @import("build_options");

pub const ORT_API_VERSION: u32 = 25;

// ── Opaque ONNX Runtime Types ──────────────────────────────────────

pub const OrtStatus = opaque {};
pub const OrtEnv = opaque {};
pub const OrtSession = opaque {};
pub const OrtSessionOptions = opaque {};
pub const OrtMemoryInfo = opaque {};
pub const OrtValue = opaque {};
pub const OrtRunOptions = opaque {};

pub const OrtStatusPtr = ?*OrtStatus;

pub const OrtErrorCode = enum(c_int) {
    ok = 0,
    fail = 1,
    invalid_argument = 2,
    no_such_file = 3,
    no_model = 4,
    engine_error = 5,
    runtime_exception = 6,
    invalid_protobuf = 7,
    model_loaded = 8,
    not_implemented = 9,
    invalid_graph = 10,
    ep_fail = 11,
};

pub const OrtLoggingLevel = enum(c_int) {
    verbose = 0,
    info = 1,
    warning = 2,
    err = 3,
    fatal = 4,
};

pub const OrtAllocatorType = enum(c_int) {
    device = 0,
    arena = 1,
};

pub const OrtMemType = enum(c_int) {
    cpu = 0,
};

pub const OnnxTensorElementDataType = enum(c_int) {
    undefined = 0,
    float = 1,
};

// ── ONNX Runtime API Entry Point ───────────────────────────────────

extern "onnxruntime" fn OrtGetApiBase() ?*const OrtApiBase;

pub const OrtApiBase = extern struct {
    GetApi: *const fn (version: u32) callconv(.c) ?*const OrtApi,
    GetVersionString: *const fn () callconv(.c) [*:0]const u8,
};

// NOTE: OrtApi is a large function-table. We only type fields we use directly.
// All unknown intermediate entries are represented as raw pointer slots.
pub const OrtApi = extern struct {
    // 1..11
    CreateStatus: *const fn (code: OrtErrorCode, msg: [*:0]const u8) callconv(.c) OrtStatusPtr,
    GetErrorCode: *const fn (status: *const OrtStatus) callconv(.c) OrtErrorCode,
    GetErrorMessage: *const fn (status: *const OrtStatus) callconv(.c) [*:0]const u8,
    CreateEnv: *const fn (log_severity_level: OrtLoggingLevel, logid: [*:0]const u8, out: *?*OrtEnv) callconv(.c) OrtStatusPtr,
    CreateEnvWithCustomLogger: *const anyopaque,
    EnableTelemetryEvents: *const anyopaque,
    DisableTelemetryEvents: *const anyopaque,
    CreateSession: *const fn (env: *const OrtEnv, model_path: [*:0]const u8, options: *const OrtSessionOptions, out: *?*OrtSession) callconv(.c) OrtStatusPtr,
    CreateSessionFromArray: *const anyopaque,
    Run: *const fn (
        session: *OrtSession,
        run_options: ?*const OrtRunOptions,
        input_names: [*]const [*:0]const u8,
        inputs: [*]const *const OrtValue,
        input_len: usize,
        output_names: [*]const [*:0]const u8,
        output_names_len: usize,
        outputs: [*]*OrtValue,
    ) callconv(.c) OrtStatusPtr,
    CreateSessionOptions: *const fn (options: *?*OrtSessionOptions) callconv(.c) OrtStatusPtr,

    // 12..49
    _reserved_12_49: [38]*const anyopaque,

    // 50
    CreateTensorWithDataAsOrtValue: *const fn (
        info: *const OrtMemoryInfo,
        p_data: *anyopaque,
        p_data_len: usize,
        shape: [*]const i64,
        shape_len: usize,
        element_type: c_int,
        out: *?*OrtValue,
    ) callconv(.c) OrtStatusPtr,

    // 51
    IsTensor: *const anyopaque,
    // 52
    GetTensorMutableData: *const anyopaque,

    // 53..69
    _reserved_53_69: [17]*const anyopaque,

    // 70
    CreateCpuMemoryInfo: *const fn (allocator_type: OrtAllocatorType, mem_type: OrtMemType, out: *?*OrtMemoryInfo) callconv(.c) OrtStatusPtr,

    // 71..92
    _reserved_71_92: [22]*const anyopaque,

    // 93..97
    ReleaseEnv: *const fn (env: *OrtEnv) callconv(.c) void,
    ReleaseStatus: *const fn (status: *OrtStatus) callconv(.c) void,
    ReleaseMemoryInfo: *const fn (memory_info: *OrtMemoryInfo) callconv(.c) void,
    ReleaseSession: *const fn (session: *OrtSession) callconv(.c) void,
    ReleaseValue: *const fn (value: *OrtValue) callconv(.c) void,

    // 98..100
    ReleaseRunOptions: *const anyopaque,
    ReleaseTypeInfo: *const anyopaque,
    ReleaseTensorTypeAndShapeInfo: *const anyopaque,

    // 101
    ReleaseSessionOptions: *const fn (options: *OrtSessionOptions) callconv(.c) void,
};

pub const OnnxError = error{
    NeuralDisabled,
    ApiBaseUnavailable,
    ApiUnavailable,
    RuntimeFailure,
    EmptyInput,
};

fn checkStatus(api: *const OrtApi, status: OrtStatusPtr) OnnxError!void {
    const st = status orelse return;
    defer api.ReleaseStatus(st);
    const msg = std.mem.span(api.GetErrorMessage(st));
    std.log.err("onnx runtime error: {s}", .{msg});
    return error.RuntimeFailure;
}

pub const OnnxSession = struct {
    api: *const OrtApi,
    env: *OrtEnv,
    session: *OrtSession,
    memory_info: *OrtMemoryInfo,
    input_name: [*:0]const u8 = "input",
    output_name: [*:0]const u8 = "output",

    pub fn init(model_path: [*:0]const u8) OnnxError!OnnxSession {
        if (comptime !build_options.enable_neural) return error.NeuralDisabled;

        const api_base = OrtGetApiBase() orelse return error.ApiBaseUnavailable;
        const api = api_base.GetApi(ORT_API_VERSION) orelse return error.ApiUnavailable;

        var env_ptr: ?*OrtEnv = null;
        var options_ptr: ?*OrtSessionOptions = null;
        var session_ptr: ?*OrtSession = null;
        var memory_ptr: ?*OrtMemoryInfo = null;

        errdefer if (memory_ptr) |ptr| api.ReleaseMemoryInfo(ptr);
        errdefer if (session_ptr) |ptr| api.ReleaseSession(ptr);
        errdefer if (options_ptr) |ptr| api.ReleaseSessionOptions(ptr);
        errdefer if (env_ptr) |ptr| api.ReleaseEnv(ptr);

        try checkStatus(api, api.CreateEnv(.warning, "worldsynth", &env_ptr));
        try checkStatus(api, api.CreateSessionOptions(&options_ptr));
        try checkStatus(api, api.CreateSession(env_ptr.?, model_path, options_ptr.?, &session_ptr));
        try checkStatus(api, api.CreateCpuMemoryInfo(.arena, .cpu, &memory_ptr));

        api.ReleaseSessionOptions(options_ptr.?);
        options_ptr = null;

        return .{
            .api = api,
            .env = env_ptr.?,
            .session = session_ptr.?,
            .memory_info = memory_ptr.?,
        };
    }

    pub fn run(self: *OnnxSession, input: []const f32, output: []f32) OnnxError!void {
        if (comptime !build_options.enable_neural) return error.NeuralDisabled;
        if (input.len == 0 or output.len == 0) return error.EmptyInput;
        var input_shape = [_]i64{ 1, @as(i64, @intCast(input.len)) };
        var output_shape = [_]i64{ 1, @as(i64, @intCast(output.len)) };

        var input_tensor: ?*OrtValue = null;
        var output_tensor: ?*OrtValue = null;
        defer if (input_tensor) |ptr| self.api.ReleaseValue(ptr);
        defer if (output_tensor) |ptr| self.api.ReleaseValue(ptr);

        try checkStatus(self.api, self.api.CreateTensorWithDataAsOrtValue(
            self.memory_info,
            @ptrCast(@constCast(input.ptr)),
            input.len * @sizeOf(f32),
            &input_shape,
            input_shape.len,
            @intFromEnum(OnnxTensorElementDataType.float),
            &input_tensor,
        ));
        try checkStatus(self.api, self.api.CreateTensorWithDataAsOrtValue(
            self.memory_info,
            @ptrCast(output.ptr),
            output.len * @sizeOf(f32),
            &output_shape,
            output_shape.len,
            @intFromEnum(OnnxTensorElementDataType.float),
            &output_tensor,
        ));

        const input_names = [_][*:0]const u8{self.input_name};
        const output_names = [_][*:0]const u8{self.output_name};
        const input_values = [_]*const OrtValue{input_tensor.?};
        var output_values = [_]*OrtValue{output_tensor.?};

        try checkStatus(self.api, self.api.Run(
            self.session,
            null,
            &input_names,
            &input_values,
            input_values.len,
            &output_names,
            output_values.len,
            &output_values,
        ));
    }

    pub fn deinit(self: *OnnxSession) void {
        if (comptime !build_options.enable_neural) return;
        self.api.ReleaseMemoryInfo(self.memory_info);
        self.api.ReleaseSession(self.session);
        self.api.ReleaseEnv(self.env);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "onnx opaque types are opaque" {
    try std.testing.expect(@typeInfo(OrtEnv) == .@"opaque");
    try std.testing.expect(@typeInfo(OrtSession) == .@"opaque");
    try std.testing.expect(@typeInfo(OrtMemoryInfo) == .@"opaque");
    try std.testing.expect(@typeInfo(OrtValue) == .@"opaque");
}

test "onnx init is gated by -Denable_neural" {
    if (comptime build_options.enable_neural) return error.SkipZigTest;
    try std.testing.expectError(error.NeuralDisabled, OnnxSession.init("dummy.onnx"));
}

test "onnx smoke init/deinit with model path env var" {
    if (!comptime build_options.enable_neural) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const model_path = std.process.getEnvVarOwned(alloc, "WORLDSYNTH_ONNX_MODEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(model_path);

    if (model_path.len == 0) return error.SkipZigTest;

    const model_path_z = try alloc.dupeZ(u8, model_path);
    defer alloc.free(model_path_z);

    var session = OnnxSession.init(model_path_z.ptr) catch |err| switch (err) {
        error.ApiBaseUnavailable, error.ApiUnavailable, error.RuntimeFailure => return error.SkipZigTest,
        else => return err,
    };
    defer session.deinit();
}
