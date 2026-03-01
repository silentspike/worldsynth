const std = @import("std");
const posix = std.posix;

// ── OSC Server (WP-130) ───────────────────────────────────────────────
// Open Sound Control 1.0 over UDP — bidirectional parameter control.
// Compatible with TouchOSC, Max/MSP, SuperCollider.
//
// Design:
//   - IO-Thread: OscServer runs in IO thread, not audio thread
//   - Non-blocking: poll() uses SOCK_NONBLOCK, returns null on no data
//   - Address format: /worldsynth/param/{id} with f32 value
//   - Metering: /worldsynth/meter/{name} at configurable rate
//
// OSC 1.0 wire format:
//   | address (null-term, 4-byte aligned) |
//   | type tag string ",f" (4-byte aligned) |
//   | arguments (big-endian) |

pub const max_args = 8;
pub const max_buf = 1024;

// ── OSC Message Format ────────────────────────────────────────────────

pub const OscType = enum { float, int, string };

pub const OscArg = union(OscType) {
    float: f32,
    int: i32,
    string: []const u8,
};

pub const OscMessage = struct {
    address: []const u8,
    args: [max_args]OscArg,
    arg_count: u8,
};

pub const OscError = error{
    MessageTooShort,
    InvalidAddress,
    InvalidTypeTag,
    BufferOverflow,
    TruncatedArg,
};

/// Align to 4-byte boundary (OSC padding rule).
fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// Parse an OSC message from a raw buffer.
pub fn parse(buf: []const u8) OscError!OscMessage {
    if (buf.len < 8) return error.MessageTooShort;

    // Address: null-terminated, starts with '/'
    const addr_end = std.mem.indexOfScalar(u8, buf, 0) orelse return error.InvalidAddress;
    const address = buf[0..addr_end];
    if (address.len == 0 or address[0] != '/') return error.InvalidAddress;
    const type_start = align4(addr_end + 1);
    if (type_start >= buf.len) return error.MessageTooShort;

    // Type tag string: starts with ','
    if (buf[type_start] != ',') return error.InvalidTypeTag;
    const type_end = std.mem.indexOfScalarPos(u8, buf, type_start, 0) orelse
        return error.InvalidTypeTag;
    const type_tags = buf[type_start + 1 .. type_end]; // skip ','
    var arg_pos = align4(type_end + 1);

    // Parse arguments based on type tags
    var msg = OscMessage{
        .address = address,
        .args = undefined,
        .arg_count = 0,
    };

    for (type_tags) |tag| {
        if (msg.arg_count >= max_args) break;
        switch (tag) {
            'f' => {
                if (arg_pos + 4 > buf.len) return error.TruncatedArg;
                const bits = std.mem.readInt(u32, buf[arg_pos..][0..4], .big);
                msg.args[msg.arg_count] = .{ .float = @bitCast(bits) };
                arg_pos += 4;
            },
            'i' => {
                if (arg_pos + 4 > buf.len) return error.TruncatedArg;
                const bits = std.mem.readInt(u32, buf[arg_pos..][0..4], .big);
                msg.args[msg.arg_count] = .{ .int = @as(i32, @bitCast(bits)) };
                arg_pos += 4;
            },
            's' => {
                const s_end = std.mem.indexOfScalarPos(u8, buf, arg_pos, 0) orelse
                    return error.TruncatedArg;
                msg.args[msg.arg_count] = .{ .string = buf[arg_pos..s_end] };
                arg_pos = align4(s_end + 1);
            },
            else => return error.InvalidTypeTag,
        }
        msg.arg_count += 1;
    }

    return msg;
}

/// Build an OSC message with a single float argument.
pub fn build_float(buf: []u8, address: []const u8, value: f32) OscError!usize {
    var pos: usize = 0;

    // Address string (null-terminated, 4-byte padded)
    const addr_padded = align4(address.len + 1);
    if (addr_padded + 8 > buf.len) return error.BufferOverflow;
    @memcpy(buf[pos..][0..address.len], address);
    pos += address.len;
    // Null-terminate + pad
    while (pos < addr_padded) : (pos += 1) buf[pos] = 0;

    // Type tag ",f\0\0" (always 4 bytes for single float)
    buf[pos] = ',';
    buf[pos + 1] = 'f';
    buf[pos + 2] = 0;
    buf[pos + 3] = 0;
    pos += 4;

    // Float argument (big-endian)
    if (pos + 4 > buf.len) return error.BufferOverflow;
    std.mem.writeInt(u32, buf[pos..][0..4], @bitCast(value), .big);
    pos += 4;

    return pos;
}

/// Build an OSC message with a single int argument.
pub fn build_int(buf: []u8, address: []const u8, value: i32) OscError!usize {
    var pos: usize = 0;

    const addr_padded = align4(address.len + 1);
    if (addr_padded + 8 > buf.len) return error.BufferOverflow;
    @memcpy(buf[pos..][0..address.len], address);
    pos += address.len;
    while (pos < addr_padded) : (pos += 1) buf[pos] = 0;

    buf[pos] = ',';
    buf[pos + 1] = 'i';
    buf[pos + 2] = 0;
    buf[pos + 3] = 0;
    pos += 4;

    if (pos + 4 > buf.len) return error.BufferOverflow;
    std.mem.writeInt(u32, buf[pos..][0..4], @bitCast(value), .big);
    pos += 4;

    return pos;
}

/// Extract param_id from OSC address "/worldsynth/param/{id}".
/// Returns null if address does not match the expected pattern.
pub fn extract_param_id(address: []const u8) ?u16 {
    const prefix = "/worldsynth/param/";
    if (!std.mem.startsWith(u8, address, prefix)) return null;
    const id_str = address[prefix.len..];
    return std.fmt.parseInt(u16, id_str, 10) catch null;
}

// ── OscServer (UDP Socket) ────────────────────────────────────────────

pub const OscServer = struct {
    socket: posix.socket_t,
    port: u16,
    recv_buf: [max_buf]u8 = undefined,
    send_buf: [max_buf]u8 = undefined,

    pub fn init(port: u16) !OscServer {
        const sock = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            0,
        );
        errdefer posix.close(sock);

        // Allow port reuse for quick restart
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        var addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        try posix.bind(sock, &addr.any, addr.getOsSockLen());

        return .{ .socket = sock, .port = port };
    }

    pub fn deinit(self: *OscServer) void {
        posix.close(self.socket);
    }

    /// Non-blocking poll for incoming OSC messages.
    /// Returns parsed message or null if no data available.
    pub fn poll(self: *OscServer) ?OscMessage {
        var src_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const n = posix.recvfrom(
            self.socket,
            &self.recv_buf,
            0,
            &src_addr,
            &addr_len,
        ) catch return null; // EAGAIN/EWOULDBLOCK → no data
        if (n == 0) return null;
        return parse(self.recv_buf[0..n]) catch null;
    }

    /// Send a metering float value to a target address.
    pub fn send_metering(
        self: *OscServer,
        osc_addr: []const u8,
        value: f32,
        target: std.net.Address,
    ) !void {
        const len = try build_float(&self.send_buf, osc_addr, value);
        _ = try posix.sendto(
            self.socket,
            self.send_buf[0..len],
            0,
            &target.any,
            target.getOsSockLen(),
        );
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-3: OSC address format correctly parsed" {
    // Build a message: /worldsynth/param/42 ,f <0.75>
    var buf: [64]u8 = undefined;
    const len = try build_float(&buf, "/worldsynth/param/42", 0.75);

    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings("/worldsynth/param/42", msg.address);
    try std.testing.expectEqual(@as(u8, 1), msg.arg_count);
    try std.testing.expectEqual(@as(f32, 0.75), msg.args[0].float);
}

test "AC-3: extract_param_id" {
    try std.testing.expectEqual(@as(?u16, 42), extract_param_id("/worldsynth/param/42"));
    try std.testing.expectEqual(@as(?u16, 0), extract_param_id("/worldsynth/param/0"));
    try std.testing.expectEqual(@as(?u16, 1023), extract_param_id("/worldsynth/param/1023"));
    try std.testing.expectEqual(@as(?u16, null), extract_param_id("/other/address"));
    try std.testing.expectEqual(@as(?u16, null), extract_param_id("/worldsynth/param/notanum"));
    try std.testing.expectEqual(@as(?u16, null), extract_param_id("/worldsynth/param/"));
}

test "parse float message" {
    var buf: [64]u8 = undefined;
    const len = try build_float(&buf, "/test/value", 3.14);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings("/test/value", msg.address);
    try std.testing.expectEqual(@as(u8, 1), msg.arg_count);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), msg.args[0].float, 0.001);
}

test "parse int message" {
    var buf: [64]u8 = undefined;
    const len = try build_int(&buf, "/test/int", 42);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings("/test/int", msg.address);
    try std.testing.expectEqual(@as(u8, 1), msg.arg_count);
    try std.testing.expectEqual(@as(i32, 42), msg.args[0].int);
}

test "parse negative int" {
    var buf: [64]u8 = undefined;
    const len = try build_int(&buf, "/neg", -100);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqual(@as(i32, -100), msg.args[0].int);
}

test "address padding: length 1 (/) pads to 4" {
    var buf: [32]u8 = undefined;
    const len = try build_float(&buf, "/a", 1.0);
    // /a\0 → 3 bytes → padded to 4
    // ,f\0\0 → 4 bytes
    // float → 4 bytes = total 12
    try std.testing.expectEqual(@as(usize, 12), len);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings("/a", msg.address);
}

test "address padding: length 4 pads to 8" {
    var buf: [32]u8 = undefined;
    const len = try build_float(&buf, "/abc", 1.0);
    // /abc\0 → 5 bytes → padded to 8
    // ,f\0\0 → 4 bytes
    // float → 4 bytes = total 16
    try std.testing.expectEqual(@as(usize, 16), len);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings("/abc", msg.address);
}

test "AC-N1: invalid messages return error, no crash" {
    // Empty buffer
    try std.testing.expectError(error.MessageTooShort, parse(&[_]u8{}));
    // Too short
    try std.testing.expectError(error.MessageTooShort, parse(&[_]u8{ '/', 'a', 0, 0 }));
    // No leading /
    try std.testing.expectError(error.InvalidAddress, parse(&[_]u8{ 'n', 'o', 0, 0, ',', 0, 0, 0 }));
    // Missing type tag comma
    try std.testing.expectError(error.InvalidTypeTag, parse(&[_]u8{ '/', 'a', 0, 0, 'f', 0, 0, 0 }));
    // Unknown type tag
    try std.testing.expectError(error.InvalidTypeTag, parse(&[_]u8{ '/', 'a', 0, 0, ',', 'z', 0, 0 }));
    // Truncated float arg
    try std.testing.expectError(error.TruncatedArg, parse(&[_]u8{ '/', 'a', 0, 0, ',', 'f', 0, 0 }));
}

test "AC-N1: build with tiny buffer returns BufferOverflow" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferOverflow, build_float(&buf, "/long/address/path", 1.0));
}

test "build-parse roundtrip preserves data" {
    var buf: [128]u8 = undefined;
    const addr = "/worldsynth/param/512";
    const val: f32 = -0.333;
    const len = try build_float(&buf, addr, val);
    const msg = try parse(buf[0..len]);
    try std.testing.expectEqualStrings(addr, msg.address);
    try std.testing.expectEqual(val, msg.args[0].float);
}

test "AC-1+AC-2: UDP send and receive OSC messages" {
    // Create server on random high port
    const port: u16 = 19742;
    var server = OscServer.init(port) catch |err| {
        // Skip if port unavailable (CI environment)
        std.debug.print("\n  [WP-130] Skipping UDP test: {}\n", .{err});
        return;
    };
    defer server.deinit();

    // Create client socket
    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);

    const target = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

    // AC-1: Send OSC param message → server receives it
    var send_buf: [128]u8 = undefined;
    const msg_len = try build_float(&send_buf, "/worldsynth/param/7", 0.42);
    _ = try posix.sendto(client, send_buf[0..msg_len], 0, &target.any, target.getOsSockLen());

    // Small delay for loopback delivery
    std.Thread.sleep(1_000_000); // 1ms

    const msg = server.poll();
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("/worldsynth/param/7", msg.?.address);
    try std.testing.expectApproxEqAbs(@as(f32, 0.42), msg.?.args[0].float, 0.001);

    const param_id = extract_param_id(msg.?.address);
    try std.testing.expectEqual(@as(?u16, 7), param_id);

    // AC-2: Server sends metering → client receives it
    const recv_sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(recv_sock);

    const meter_port: u16 = 19743;
    var recv_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, meter_port);
    try posix.bind(recv_sock, &recv_addr.any, recv_addr.getOsSockLen());

    const meter_target = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, meter_port);
    try server.send_metering("/worldsynth/meter/level_l", -12.5, meter_target);

    std.Thread.sleep(1_000_000); // 1ms

    var meter_buf: [128]u8 = undefined;
    const n = posix.recvfrom(recv_sock, &meter_buf, posix.MSG.DONTWAIT, null, null) catch 0;
    try std.testing.expect(n > 0);

    const meter_msg = try parse(meter_buf[0..n]);
    try std.testing.expectEqualStrings("/worldsynth/meter/level_l", meter_msg.address);
    try std.testing.expectEqual(@as(f32, -12.5), meter_msg.args[0].float);
}

test "poll returns null when no data" {
    const port: u16 = 19744;
    var server = OscServer.init(port) catch return;
    defer server.deinit();

    // No data sent → poll returns null
    try std.testing.expect(server.poll() == null);
}

test "benchmark: OSC parse" {
    var buf: [128]u8 = undefined;
    const len = try build_float(&buf, "/worldsynth/param/42", 0.5);

    // Warmup
    for (0..1000) |_| _ = parse(buf[0..len]) catch unreachable;

    const runs = 5;
    const iters = 10000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            std.mem.doNotOptimizeAway(parse(buf[0..len]) catch unreachable);
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_msg_us = median_ns / @as(f64, iters) / 1000.0;

    std.debug.print("\n  [WP-130] OSC parse — {d} msgs, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns total, {d:.3}us/msg\n", .{ median_ns, per_msg_us });
    std.debug.print("    Threshold: < 100us/msg\n", .{});

    try std.testing.expect(per_msg_us < 100.0);
}

test "benchmark: OSC build" {
    var buf: [128]u8 = undefined;

    // Warmup
    for (0..1000) |_| _ = build_float(&buf, "/worldsynth/param/42", 0.5) catch unreachable;

    const runs = 5;
    const iters = 10000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            std.mem.doNotOptimizeAway(build_float(&buf, "/worldsynth/param/42", 0.5) catch unreachable);
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_msg_us = median_ns / @as(f64, iters) / 1000.0;

    std.debug.print("\n  [WP-130] OSC build — {d} msgs, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns total, {d:.3}us/msg\n", .{ median_ns, per_msg_us });
    std.debug.print("    Threshold: < 100us/msg\n", .{});

    try std.testing.expect(per_msg_us < 100.0);
}

test "benchmark: OSC UDP roundtrip" {
    const port: u16 = 19745;
    var server = OscServer.init(port) catch |err| {
        std.debug.print("\n  [WP-130] Skipping UDP benchmark: {}\n", .{err});
        return;
    };
    defer server.deinit();

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(client);
    const target = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

    var send_buf: [128]u8 = undefined;
    const msg_len = try build_float(&send_buf, "/worldsynth/param/1", 0.5);

    // Warmup
    for (0..10) |_| {
        _ = try posix.sendto(client, send_buf[0..msg_len], 0, &target.any, target.getOsSockLen());
        std.Thread.sleep(100_000);
        _ = server.poll();
    }

    const runs = 5;
    const iters = 100;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            _ = try posix.sendto(client, send_buf[0..msg_len], 0, &target.any, target.getOsSockLen());
            // Spin-poll for message (loopback is near-instant)
            var attempts: usize = 0;
            while (server.poll() == null and attempts < 10000) : (attempts += 1) {}
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_msg_us = median_ns / @as(f64, iters) / 1000.0;
    const msg_per_sec = @as(f64, iters) / (median_ns / 1_000_000_000.0);

    std.debug.print("\n  [WP-130] OSC UDP roundtrip — {d} msgs, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}us/msg, {d:.0} msg/s\n", .{ per_msg_us, msg_per_sec });
    std.debug.print("    Threshold: < 500us/roundtrip, >= 100 msg/s\n", .{});

    try std.testing.expect(per_msg_us < 500.0);
    try std.testing.expect(msg_per_sec >= 100.0);
}
