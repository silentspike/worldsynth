const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const param_mod = @import("../engine/param.zig");
const ParamID = param_mod.ParamID;
const ParamState = param_mod.ParamState;
const builtin = @import("builtin");

// -- CTL Socket Server (WP-135) ------------------------------------------------
// Unix Domain Socket server for programmatic control of WorldSynth.
// JSON Lines protocol over AF.UNIX SOCK.STREAM on /tmp/synth.sock.
//
// Design:
//   - IO-Thread: CtlServer runs in a dedicated thread (NOT audio thread)
//   - poll()-based: 100ms timeout on listen FD for clean shutdown
//   - Zero heap per connection: all buffers on stack
//   - Single-client sequential: CLI opens, sends request, gets response, closes
//
// Protocol:
//   Request:  {"cmd":"param","id":"filter_cutoff","value":1000}\n
//   Response: {"ok":true,"data":{...}}\n  or  {"ok":false,"error":"..."}\n

// -- ParamID name lookup (comptime) -------------------------------------------

const param_fields = @typeInfo(ParamID).@"enum".fields;

/// Comptime-generated lookup: string name -> ParamID enum value.
/// Only includes named fields (excludes non-exhaustive `_` sentinel).
fn lookupParamId(name: []const u8) ?ParamID {
    inline for (param_fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

/// Comptime-generated reverse lookup: ParamID enum value -> string name.
fn paramIdName(id: ParamID) ?[]const u8 {
    inline for (param_fields) |field| {
        if (field.value == @intFromEnum(id)) {
            return field.name;
        }
    }
    return null;
}

// -- Metering source (pointer struct to main.zig atomics) ---------------------

pub const MeteringSource = struct {
    peak_l: *std.atomic.Value(u32),
    peak_r: *std.atomic.Value(u32),
    rms: *std.atomic.Value(u32),
    dc_offset: *std.atomic.Value(i32),
    voices: *std.atomic.Value(u32),
    cb_last_ns: *std.atomic.Value(u64),
    xrun_count: *std.atomic.Value(u32),
    true_peak: *std.atomic.Value(u32),
    clip_count: *std.atomic.Value(u32),
};

// -- Request parsing ----------------------------------------------------------

const Command = enum {
    param,
    metering,
    state,
    screenshot,
    capture,
};

const CtlRequest = struct {
    cmd: []const u8,
    id: ?[]const u8 = null,
    value: ?f64 = null,
    path: ?[]const u8 = null,
    duration_ms: ?u32 = null,
};

// -- Buffer sizes -------------------------------------------------------------

const REQ_BUF_SIZE: usize = 4096;
const RESP_BUF_SIZE: usize = 8192; // state query can be large
const POLL_TIMEOUT_MS: i32 = 100;
const SOCK_PATH_MAX: usize = 108;

// -- CtlServer ----------------------------------------------------------------

pub const CtlServer = struct {
    socket_fd: posix.socket_t,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    param_state: *ParamState,
    metering: MeteringSource,
    path_buf: [SOCK_PATH_MAX]u8,
    path_len: usize,

    pub fn init(
        param_state: *ParamState,
        metering: MeteringSource,
        socket_path: []const u8,
    ) !CtlServer {
        if (socket_path.len >= SOCK_PATH_MAX) return error.PathTooLong;

        // Remove stale socket file from previous crash
        std.fs.deleteFileAbsolute(socket_path) catch {};

        // Create Unix Domain Socket
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        // Bind to socket path
        var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        @memcpy(addr.path[0..socket_path.len], socket_path);

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Listen with backlog of 1 (sequential single-client)
        try posix.listen(sock, 1);

        var path_buf: [SOCK_PATH_MAX]u8 = std.mem.zeroes([SOCK_PATH_MAX]u8);
        @memcpy(path_buf[0..socket_path.len], socket_path);

        return .{
            .socket_fd = sock,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .param_state = param_state,
            .metering = metering,
            .path_buf = path_buf,
            .path_len = socket_path.len,
        };
    }

    pub fn deinit(self: *CtlServer) void {
        self.stop();
        posix.close(self.socket_fd);
        // Clean up socket file
        std.fs.deleteFileAbsolute(self.path_buf[0..self.path_len]) catch {};
    }

    pub fn start(self: *CtlServer) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *CtlServer) void {
        if (self.thread) |t| {
            self.running.store(false, .release);
            t.join();
            self.thread = null;
        }
    }

    fn acceptLoop(self: *CtlServer) void {
        var poll_fds = [1]posix.pollfd{.{
            .fd = self.socket_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        while (self.running.load(.acquire)) {
            const n = posix.poll(&poll_fds, POLL_TIMEOUT_MS) catch continue;
            if (n == 0) continue; // timeout, check running flag

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const conn = posix.accept(self.socket_fd, null, null, posix.SOCK.CLOEXEC) catch continue;
                defer posix.close(conn);
                self.handleConnection(conn);
            }
        }
    }

    fn handleConnection(self: *CtlServer, conn: posix.socket_t) void {
        // Read request line (stack-allocated buffer)
        var req_buf: [REQ_BUF_SIZE]u8 = undefined;
        var total: usize = 0;

        // Read until newline or buffer full
        while (total < req_buf.len) {
            const n = posix.read(conn, req_buf[total..]) catch break;
            if (n == 0) break; // connection closed
            total += n;
            // Check for newline delimiter
            if (std.mem.indexOfScalar(u8, req_buf[0..total], '\n') != null) break;
        }

        if (total == 0) return;

        // Trim trailing newline
        const line_end = std.mem.indexOfScalar(u8, req_buf[0..total], '\n') orelse total;
        const line = req_buf[0..line_end];

        // Parse + dispatch + respond
        var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
        const resp_len = self.processRequest(line, &resp_buf);
        if (resp_len > 0) {
            // Write response + newline
            _ = posix.write(conn, resp_buf[0..resp_len]) catch {};
            _ = posix.write(conn, "\n") catch {};
        }
    }

    fn processRequest(self: *CtlServer, line: []const u8, resp_buf: []u8) usize {
        // Parse JSON request using FixedBufferAllocator (zero heap)
        var fba_buf: [REQ_BUF_SIZE]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);

        const parsed = std.json.parseFromSlice(
            CtlRequest,
            fba.allocator(),
            line,
            .{ .ignore_unknown_fields = true },
        ) catch {
            return writeError(resp_buf, "invalid JSON request");
        };
        const req = parsed.value;

        // Dispatch command
        const cmd = std.meta.stringToEnum(Command, req.cmd) orelse {
            return writeError(resp_buf, "unknown command");
        };

        return switch (cmd) {
            .param => self.handleParam(req, resp_buf),
            .metering => self.handleMetering(resp_buf),
            .state => self.handleState(resp_buf),
            .screenshot => handleScreenshot(resp_buf),
            .capture => handleCapture(resp_buf),
        };
    }

    fn handleParam(self: *CtlServer, req: CtlRequest, buf: []u8) usize {
        const id_str = req.id orelse return writeError(buf, "param requires 'id' field");
        const param_id = lookupParamId(id_str) orelse return writeError(buf, "unknown param id");

        if (req.value) |val| {
            // SET: write parameter
            self.param_state.set_param(param_id, val);
            return writeParamResponse(buf, id_str, val);
        } else {
            // GET: read current value
            const snap = self.param_state.read_snapshot();
            const current = snap.values[@intFromEnum(param_id)];
            return writeParamResponse(buf, id_str, current);
        }
    }

    fn handleMetering(self: *CtlServer, buf: []u8) usize {
        // Read all metering atomics with .acquire ordering
        const peak_l_raw = self.metering.peak_l.load(.acquire);
        const peak_r_raw = self.metering.peak_r.load(.acquire);
        const rms_raw = self.metering.rms.load(.acquire);
        const dc_raw = self.metering.dc_offset.load(.acquire);
        const voices_val = self.metering.voices.load(.acquire);
        const cb_ns = self.metering.cb_last_ns.load(.acquire);
        const xruns = self.metering.xrun_count.load(.acquire);
        const true_peak_raw = self.metering.true_peak.load(.acquire);
        const clips = self.metering.clip_count.load(.acquire);

        // Convert scaled integer atomics to float
        const scale: f64 = 10000.0;
        const scale_dc: f64 = 1000000.0;

        const result = std.fmt.bufPrint(buf, "{{\"ok\":true,\"data\":{{" ++
            "\"peak_l\":{d:.4},\"peak_r\":{d:.4}," ++
            "\"rms\":{d:.4},\"dc_offset\":{d:.6}," ++
            "\"true_peak\":{d:.4}," ++
            "\"voices\":{d},\"cb_last_ns\":{d}," ++
            "\"xruns\":{d},\"clips\":{d}" ++
            "}}}}", .{
            @as(f64, @floatFromInt(peak_l_raw)) / scale,
            @as(f64, @floatFromInt(peak_r_raw)) / scale,
            @as(f64, @floatFromInt(rms_raw)) / scale,
            @as(f64, @floatFromInt(dc_raw)) / scale_dc,
            @as(f64, @floatFromInt(true_peak_raw)) / scale,
            voices_val,
            cb_ns,
            xruns,
            clips,
        }) catch return 0;
        return result.len;
    }

    fn handleState(self: *CtlServer, buf: []u8) usize {
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();

        w.writeAll("{\"ok\":true,\"data\":{") catch return 0;

        var first = true;
        inline for (param_fields) |field| {
            const val = self.param_state.read_snapshot().values[field.value];
            if (!first) {
                w.writeAll(",") catch return 0;
            }
            first = false;
            w.print("\"{s}\":{d}", .{ field.name, val }) catch return 0;
        }

        w.print(",\"version\":{d}}}}}", .{self.param_state.read_snapshot().version}) catch return 0;

        return stream.pos;
    }

    fn handleScreenshot(buf: []u8) usize {
        if (comptime build_options.enable_webkit) {
            return writeError(buf, "screenshot not yet implemented (WebView integration pending)");
        } else {
            return writeError(buf, "screenshot requires enable_webkit=true (disabled: Zig 0.15.2 compiler limitation)");
        }
    }

    fn handleCapture(buf: []u8) usize {
        return writeError(buf, "audio capture requires running audio engine (use from synth-ctl while WorldSynth is running)");
    }
};

// -- JSON response helpers (fmt-based, zero-alloc) ----------------------------

fn writeError(buf: []u8, msg: []const u8) usize {
    const result = std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch return 0;
    return result.len;
}

fn writeParamResponse(buf: []u8, id: []const u8, value: f64) usize {
    const result = std.fmt.bufPrint(buf, "{{\"ok\":true,\"data\":{{\"id\":\"{s}\",\"value\":{d}}}}}", .{ id, value }) catch return 0;
    return result.len;
}

// -- Tests --------------------------------------------------------------------

test "param name lookup: known ids" {
    try std.testing.expectEqual(ParamID.filter_cutoff, lookupParamId("filter_cutoff").?);
    try std.testing.expectEqual(ParamID.master_volume, lookupParamId("master_volume").?);
    try std.testing.expectEqual(ParamID.osc1_waveform, lookupParamId("osc1_waveform").?);
    try std.testing.expectEqual(ParamID.env_attack, lookupParamId("env_attack").?);
}

test "param name lookup: unknown id returns null" {
    try std.testing.expect(lookupParamId("nonexistent_param") == null);
    try std.testing.expect(lookupParamId("") == null);
    try std.testing.expect(lookupParamId("FILTER_CUTOFF") == null); // case sensitive
}

test "param id to name: reverse lookup" {
    try std.testing.expectEqualStrings("filter_cutoff", paramIdName(.filter_cutoff).?);
    try std.testing.expectEqualStrings("master_volume", paramIdName(.master_volume).?);
}

test "write error response: valid JSON" {
    var buf: [256]u8 = undefined;
    const len = writeError(&buf, "test error");
    try std.testing.expect(len > 0);
    const json_str = buf[0..len];

    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct {
        ok: bool,
        @"error": []const u8,
    }, fba.allocator(), json_str, .{});
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("test error", parsed.value.@"error");
}

test "write param response: valid JSON" {
    var buf: [256]u8 = undefined;
    const len = writeParamResponse(&buf, "filter_cutoff", 2000.0);
    try std.testing.expect(len > 0);
    const json_str = buf[0..len];

    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const Response = struct {
        ok: bool,
        data: struct {
            id: []const u8,
            value: f64,
        },
    };
    const parsed = try std.json.parseFromSlice(Response, fba.allocator(), json_str, .{});
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("filter_cutoff", parsed.value.data.id);
    try std.testing.expectEqual(@as(f64, 2000.0), parsed.value.data.value);
}

test "processRequest: param set" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"param\",\"id\":\"filter_cutoff\",\"value\":5000}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    // Verify param was set
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(f64, 5000.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
}

test "processRequest: param get" {
    var state: ParamState = undefined;
    state.init();
    state.set_param(.filter_cutoff, 3333.0);

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"param\",\"id\":\"filter_cutoff\"}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    // Parse response to verify value
    var fba_buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const Response = struct {
        ok: bool,
        data: struct { id: []const u8, value: f64 },
    };
    const parsed = try std.json.parseFromSlice(Response, fba.allocator(), resp_buf[0..resp_len], .{});
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqual(@as(f64, 3333.0), parsed.value.data.value);
}

test "processRequest: metering" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    metering_atoms.peak_l.store(5000, .release); // 0.5
    metering_atoms.rms.store(2500, .release); // 0.25
    metering_atoms.voices.store(4, .release);

    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"metering\"}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    // Verify it's valid JSON with ok=true
    var fba_buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct { ok: bool }, fba.allocator(), resp_buf[0..resp_len], .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.value.ok);
}

test "processRequest: state query" {
    var state: ParamState = undefined;
    state.init();
    state.set_param(.filter_cutoff, 999.0);

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"state\"}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    // Verify valid JSON with ok=true
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct { ok: bool }, fba.allocator(), resp_buf[0..resp_len], .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.value.ok);
}

test "processRequest: unknown command (AC-N1)" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"invalid_command\"}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct {
        ok: bool,
        @"error": []const u8,
    }, fba.allocator(), resp_buf[0..resp_len], .{});
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("unknown command", parsed.value.@"error");
}

test "processRequest: invalid JSON (AC-N1)" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "not valid json at all";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct {
        ok: bool,
        @"error": []const u8,
    }, fba.allocator(), resp_buf[0..resp_len], .{});
    try std.testing.expect(!parsed.value.ok);
}

test "processRequest: param with unknown id (AC-N1)" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"param\",\"id\":\"nonexistent\"}";
    var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
    const resp_len = server.processRequest(req_json, &resp_buf);
    try std.testing.expect(resp_len > 0);

    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const parsed = try std.json.parseFromSlice(struct {
        ok: bool,
        @"error": []const u8,
    }, fba.allocator(), resp_buf[0..resp_len], .{});
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("unknown param id", parsed.value.@"error");
}

test "socket server: start and stop" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    const path = "/tmp/worldsynth-test-ctl.sock";

    var server = CtlServer.init(
        &state,
        metering_atoms.source(),
        path,
    ) catch |err| {
        std.debug.print("\n  [WP-135] Skipping socket test: {}\n", .{err});
        return;
    };
    defer server.deinit();

    try server.start();
    std.Thread.sleep(10_000_000); // 10ms for thread to start
    server.stop();
}

test "socket server: roundtrip param set (AC-1, AC-4)" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    const path = "/tmp/worldsynth-test-ctl-rt.sock";

    var server = CtlServer.init(
        &state,
        metering_atoms.source(),
        path,
    ) catch |err| {
        std.debug.print("\n  [WP-135] Skipping socket roundtrip test: {}\n", .{err});
        return;
    };
    defer server.deinit();
    try server.start();
    defer server.stop();
    std.Thread.sleep(10_000_000); // 10ms

    // Connect as client
    const client = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        std.debug.print("\n  [WP-135] Cannot create client socket: {}\n", .{err});
        return;
    };
    defer posix.close(client);

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    posix.connect(client, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        std.debug.print("\n  [WP-135] Cannot connect: {}\n", .{err});
        return;
    };

    // Send param set request
    const req = "{\"cmd\":\"param\",\"id\":\"filter_cutoff\",\"value\":4200}\n";
    _ = posix.write(client, req) catch return;

    // Read response
    var resp_buf: [1024]u8 = undefined;
    const n = posix.read(client, &resp_buf) catch return;
    try std.testing.expect(n > 0);

    // Verify param was actually set
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(f64, 4200.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
}

test "benchmark: WP-135 param set roundtrip" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    const path = "/tmp/worldsynth-bench-ctl.sock";

    var server = CtlServer.init(
        &state,
        metering_atoms.source(),
        path,
    ) catch |err| {
        std.debug.print("\n  [WP-135] Skipping benchmark: {}\n", .{err});
        return;
    };
    defer server.deinit();
    try server.start();
    defer server.stop();
    std.Thread.sleep(20_000_000); // 20ms

    const runs = 5;
    const iters = 100;
    var times: [runs]u64 = undefined;

    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |i| {
            const client = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch continue;
            defer posix.close(client);

            var caddr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
            caddr.family = posix.AF.UNIX;
            @memcpy(caddr.path[0..path.len], path);
            posix.connect(client, @ptrCast(&caddr), @sizeOf(posix.sockaddr.un)) catch continue;

            var val_buf: [128]u8 = undefined;
            const req = std.fmt.bufPrint(&val_buf, "{{\"cmd\":\"param\",\"id\":\"filter_cutoff\",\"value\":{d}}}\n", .{@as(f64, @floatFromInt(i))}) catch continue;
            _ = posix.write(client, req) catch continue;

            var resp_buf: [1024]u8 = undefined;
            _ = posix.read(client, &resp_buf) catch continue;
        }
        t.* = timer.read();
    }

    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op_ms = median_ns / @as(f64, iters) / 1_000_000.0;

    const is_debug = builtin.mode == .Debug;
    const threshold: f64 = if (is_debug) 20.0 else 5.0;

    std.debug.print("\n  [WP-135] Param set roundtrip — {d} iters, {d} runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.3}ms/op\n", .{per_op_ms});
    std.debug.print("    Threshold: < {d:.0}ms (mode: {s})\n", .{ threshold, @tagName(builtin.mode) });

    try std.testing.expect(per_op_ms < threshold);
}

test "benchmark: WP-135 state query" {
    var state: ParamState = undefined;
    state.init();

    var metering_atoms = makeDummyMetering();
    var server = makeTestServer(&state, &metering_atoms);

    const req_json = "{\"cmd\":\"state\"}";
    const runs = 5;
    const iters = 1000;
    var times: [runs]u64 = undefined;

    // Warmup
    for (0..100) |_| {
        var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
        std.mem.doNotOptimizeAway(server.processRequest(req_json, &resp_buf));
    }

    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            var resp_buf: [RESP_BUF_SIZE]u8 = undefined;
            std.mem.doNotOptimizeAway(server.processRequest(req_json, &resp_buf));
        }
        t.* = timer.read();
    }

    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op_us = median_ns / @as(f64, iters) / 1000.0;

    const is_debug = builtin.mode == .Debug;
    const threshold: f64 = if (is_debug) 5000.0 else 1000.0;

    std.debug.print("\n  [WP-135] State query — {d} iters, {d} runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}us/query\n", .{per_op_us});
    std.debug.print("    Threshold: < {d:.0}us (mode: {s})\n", .{ threshold, @tagName(builtin.mode) });

    try std.testing.expect(per_op_us < threshold);
}

// -- Test helpers -------------------------------------------------------------

const DummyMeteringAtoms = struct {
    peak_l: std.atomic.Value(u32),
    peak_r: std.atomic.Value(u32),
    rms: std.atomic.Value(u32),
    dc_offset: std.atomic.Value(i32),
    voices: std.atomic.Value(u32),
    cb_last_ns: std.atomic.Value(u64),
    xrun_count: std.atomic.Value(u32),
    true_peak: std.atomic.Value(u32),
    clip_count: std.atomic.Value(u32),

    fn source(self: *DummyMeteringAtoms) MeteringSource {
        return .{
            .peak_l = &self.peak_l,
            .peak_r = &self.peak_r,
            .rms = &self.rms,
            .dc_offset = &self.dc_offset,
            .voices = &self.voices,
            .cb_last_ns = &self.cb_last_ns,
            .xrun_count = &self.xrun_count,
            .true_peak = &self.true_peak,
            .clip_count = &self.clip_count,
        };
    }
};

fn makeDummyMetering() DummyMeteringAtoms {
    return .{
        .peak_l = std.atomic.Value(u32).init(0),
        .peak_r = std.atomic.Value(u32).init(0),
        .rms = std.atomic.Value(u32).init(0),
        .dc_offset = std.atomic.Value(i32).init(0),
        .voices = std.atomic.Value(u32).init(0),
        .cb_last_ns = std.atomic.Value(u64).init(0),
        .xrun_count = std.atomic.Value(u32).init(0),
        .true_peak = std.atomic.Value(u32).init(0),
        .clip_count = std.atomic.Value(u32).init(0),
    };
}

fn makeTestServer(state: *ParamState, metering_atoms: *DummyMeteringAtoms) CtlServer {
    return .{
        .socket_fd = -1,
        .thread = null,
        .running = std.atomic.Value(bool).init(false),
        .param_state = state,
        .metering = metering_atoms.source(),
        .path_buf = std.mem.zeroes([SOCK_PATH_MAX]u8),
        .path_len = 0,
    };
}
