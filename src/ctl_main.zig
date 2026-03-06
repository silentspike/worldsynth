const std = @import("std");
const posix = std.posix;

// -- synth-ctl CLI (WP-135) ---------------------------------------------------
// Standalone binary that connects to WorldSynth's Unix Domain Socket
// and sends JSON Lines commands. No engine dependencies — pure std.
//
// Usage:
//   synth-ctl param <name> [value]   Set or get a parameter
//   synth-ctl metering               Read current metering levels
//   synth-ctl state                  Dump all parameters as JSON
//   synth-ctl screenshot [path]      Capture WebView screenshot
//   synth-ctl capture [path] [ms]    Capture audio to WAV

const DEFAULT_SOCKET_PATH = "/tmp/synth.sock";
const BUF_SIZE: usize = 8192;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const cmd = args.next() orelse {
        printUsage();
        std.process.exit(1);
    };

    // Build JSON request from CLI arguments
    var req_buf: [BUF_SIZE]u8 = undefined;
    const req_len = buildRequest(cmd, &args, &req_buf) catch {
        printUsage();
        std.process.exit(1);
    };

    // Connect to Unix socket
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    const path = DEFAULT_SOCKET_PATH;
    @memcpy(addr.path[0..path.len], path);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        std.debug.print("Cannot connect to {s} — is WorldSynth running?\n", .{path});
        std.process.exit(1);
    };

    // Send request + newline
    _ = try posix.write(sock, req_buf[0..req_len]);
    _ = try posix.write(sock, "\n");

    // Read response
    var resp_buf: [BUF_SIZE]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = posix.read(sock, resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, resp_buf[0..total], '\n') != null) break;
    }

    if (total == 0) {
        std.debug.print("No response from server\n", .{});
        std.process.exit(1);
    }

    // Output response to stdout
    const line_end = std.mem.indexOfScalar(u8, resp_buf[0..total], '\n') orelse total;
    _ = posix.write(posix.STDOUT_FILENO, resp_buf[0..line_end]) catch {};
    _ = posix.write(posix.STDOUT_FILENO, "\n") catch {};

    // Check ok field for exit code
    var fba_buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    if (std.json.parseFromSlice(struct { ok: bool }, fba.allocator(), resp_buf[0..line_end], .{ .ignore_unknown_fields = true })) |parsed| {
        if (!parsed.value.ok) std.process.exit(1);
    } else |_| {
        std.process.exit(1);
    }
}

fn buildRequest(cmd: []const u8, args: *std.process.ArgIterator, buf: []u8) !usize {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    if (std.mem.eql(u8, cmd, "param")) {
        const name = args.next() orelse return error.MissingArgument;
        const value_str = args.next();
        if (value_str) |vs| {
            const value = std.fmt.parseFloat(f64, vs) catch return error.InvalidValue;
            try w.print("{{\"cmd\":\"param\",\"id\":\"{s}\",\"value\":{d}}}", .{ name, value });
        } else {
            try w.print("{{\"cmd\":\"param\",\"id\":\"{s}\"}}", .{name});
        }
    } else if (std.mem.eql(u8, cmd, "metering")) {
        try w.writeAll("{\"cmd\":\"metering\"}");
    } else if (std.mem.eql(u8, cmd, "state")) {
        try w.writeAll("{\"cmd\":\"state\"}");
    } else if (std.mem.eql(u8, cmd, "screenshot")) {
        const path_arg = args.next() orelse "/tmp/worldsynth-screenshot.png";
        try w.print("{{\"cmd\":\"screenshot\",\"path\":\"{s}\"}}", .{path_arg});
    } else if (std.mem.eql(u8, cmd, "capture")) {
        const path_arg = args.next() orelse "/tmp/worldsynth-capture.wav";
        const dur_str = args.next() orelse "1000";
        const dur = std.fmt.parseInt(u32, dur_str, 10) catch return error.InvalidValue;
        try w.print("{{\"cmd\":\"capture\",\"path\":\"{s}\",\"duration_ms\":{d}}}", .{ path_arg, dur });
    } else {
        return error.UnknownCommand;
    }

    return stream.pos;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: synth-ctl <command> [args...]
        \\
        \\Commands:
        \\  param <name> [value]     Get or set a parameter
        \\  metering                 Read current metering levels
        \\  state                    Dump all parameters as JSON
        \\  screenshot [path]        Capture WebView screenshot
        \\  capture [path] [ms]      Capture audio to WAV file
        \\
        \\Examples:
        \\  synth-ctl param filter_cutoff 1000
        \\  synth-ctl param filter_cutoff
        \\  synth-ctl metering
        \\  synth-ctl state
        \\
    , .{});
}
