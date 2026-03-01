const std = @import("std");

// ── JACK Audio Client (WP-009) ───────────────────────────────────────
// Hand-written JACK C-Bindings fuer Audio-Output (Stereo).
// Kein @cImport — Zig extern Deklarationen direkt auf die JACK C-API.
// process_callback ist callconv(.c), KEIN malloc/mutex/print erlaubt.

// ── Opaque Types ─────────────────────────────────────────────────────

pub const JackClient = opaque {};
pub const JackPort = opaque {};
pub const JackNframes = u32;
pub const JackPortId = u32;

// ── JACK Constants ───────────────────────────────────────────────────

pub const JackPortFlags = enum(c_ulong) {
    is_input = 0x1,
    is_output = 0x2,
    is_physical = 0x4,
    can_monitor = 0x8,
    is_terminal = 0x10,
};

pub const JackOptions = enum(c_int) {
    no_start_server = 0x01,
    use_exact_name = 0x02,
    server_name = 0x04,
    session_id = 0x20,
};

pub const JackStatus = c_int;

pub const JACK_DEFAULT_AUDIO_TYPE = "32 bit float mono audio";

// ── Callback Types ───────────────────────────────────────────────────

pub const JackProcessCallback = *const fn (JackNframes, ?*anyopaque) callconv(.c) c_int;
pub const JackShutdownCallback = *const fn (?*anyopaque) callconv(.c) void;

// ── Extern Declarations (hand-written, NO @cImport) ──────────────────

extern "jack" fn jack_client_open(
    client_name: [*:0]const u8,
    options: c_int,
    status: ?*JackStatus,
) ?*JackClient;

extern "jack" fn jack_client_close(client: *JackClient) c_int;

extern "jack" fn jack_port_register(
    client: *JackClient,
    port_name: [*:0]const u8,
    port_type: [*:0]const u8,
    flags: c_ulong,
    buffer_size: c_ulong,
) ?*JackPort;

extern "jack" fn jack_port_get_buffer(
    port: *JackPort,
    nframes: JackNframes,
) [*]f32;

extern "jack" fn jack_set_process_callback(
    client: *JackClient,
    process_callback: JackProcessCallback,
    arg: ?*anyopaque,
) c_int;

extern "jack" fn jack_on_shutdown(
    client: *JackClient,
    shutdown_callback: JackShutdownCallback,
    arg: ?*anyopaque,
) void;

extern "jack" fn jack_activate(client: *JackClient) c_int;
extern "jack" fn jack_deactivate(client: *JackClient) c_int;

extern "jack" fn jack_connect(
    client: *JackClient,
    source_port: [*:0]const u8,
    destination_port: [*:0]const u8,
) c_int;

extern "jack" fn jack_get_sample_rate(client: *JackClient) JackNframes;
extern "jack" fn jack_get_buffer_size(client: *JackClient) JackNframes;

extern "jack" fn jack_get_ports(
    client: *JackClient,
    port_name_pattern: ?[*:0]const u8,
    type_name_pattern: ?[*:0]const u8,
    flags: c_ulong,
) ?[*:null]?[*:0]const u8;

extern "jack" fn jack_free(ptr: ?*anyopaque) void;

// ── JackAudioClient ──────────────────────────────────────────────────

pub const ProcessFn = *const fn ([*]f32, [*]f32, JackNframes) void;

pub const JackAudioClient = struct {
    client: *JackClient,
    out_l: *JackPort,
    out_r: *JackPort,
    process_fn: ?ProcessFn,

    /// Open a JACK client with stereo output ports.
    /// Does NOT activate — call start() to begin processing.
    pub fn init(process_fn: ?ProcessFn) !JackAudioClient {
        var status: JackStatus = 0;
        const client = jack_client_open(
            "worldsynth",
            @intFromEnum(JackOptions.no_start_server),
            &status,
        ) orelse return error.JackClientOpenFailed;

        const out_l = jack_port_register(
            client,
            "out_l",
            JACK_DEFAULT_AUDIO_TYPE,
            @intFromEnum(JackPortFlags.is_output),
            0,
        ) orelse {
            _ = jack_client_close(client);
            return error.JackPortRegisterFailed;
        };

        const out_r = jack_port_register(
            client,
            "out_r",
            JACK_DEFAULT_AUDIO_TYPE,
            @intFromEnum(JackPortFlags.is_output),
            0,
        ) orelse {
            _ = jack_client_close(client);
            return error.JackPortRegisterFailed;
        };

        return JackAudioClient{
            .client = client,
            .out_l = out_l,
            .out_r = out_r,
            .process_fn = process_fn,
        };
    }

    /// Register process callback, activate the JACK client, and auto-connect
    /// to system playback ports. self must be at a stable address (not on a
    /// temporary stack frame) since the callback uses a pointer to self.
    pub fn start(self: *JackAudioClient) !void {
        if (jack_set_process_callback(self.client, processCallback, @ptrCast(self)) != 0) {
            return error.JackSetCallbackFailed;
        }
        if (jack_activate(self.client) != 0) {
            return error.JackActivateFailed;
        }
        // Auto-connect to system playback (best effort, ignore errors)
        self.autoConnect();
    }

    /// Deactivate and close the JACK client.
    pub fn deinit(self: *JackAudioClient) void {
        _ = jack_deactivate(self.client);
        _ = jack_client_close(self.client);
    }

    /// Get the sample rate reported by JACK.
    pub fn getSampleRate(self: *JackAudioClient) u32 {
        return jack_get_sample_rate(self.client);
    }

    /// Get the buffer size reported by JACK.
    pub fn getBufferSize(self: *JackAudioClient) u32 {
        return jack_get_buffer_size(self.client);
    }

    /// Auto-connect output ports to system playback (best effort).
    fn autoConnect(self: *JackAudioClient) void {
        const ports = jack_get_ports(
            self.client,
            null,
            JACK_DEFAULT_AUDIO_TYPE,
            @intFromEnum(JackPortFlags.is_input) | @intFromEnum(JackPortFlags.is_physical),
        ) orelse return;
        defer jack_free(@ptrCast(ports));

        if (ports[0]) |p0| {
            _ = jack_connect(self.client, "worldsynth:out_l", p0);
        }
        if (ports[0] != null) {
            if (ports[1]) |p1| {
                _ = jack_connect(self.client, "worldsynth:out_r", p1);
            }
        }
    }

    /// JACK process callback — called from the RT audio thread.
    /// MUST NOT: malloc, free, lock mutex, print, syscall.
    /// Only: read/write audio buffers, call DSP functions.
    fn processCallback(nframes: JackNframes, arg: ?*anyopaque) callconv(.c) c_int {
        const self: *JackAudioClient = @ptrCast(@alignCast(arg orelse return 0));
        const out_l = jack_port_get_buffer(self.out_l, nframes);
        const out_r = jack_port_get_buffer(self.out_r, nframes);

        if (self.process_fn) |process| {
            process(out_l, out_r, nframes);
        } else {
            // Silence if no process function set
            for (0..nframes) |i| {
                out_l[i] = 0.0;
                out_r[i] = 0.0;
            }
        }
        return 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// Note: Integration tests (AC-2, AC-B1) require a running JACK server.
// Unit tests below verify structural properties only.

test "JackPortFlags values match JACK C API" {
    try std.testing.expectEqual(@as(c_ulong, 0x1), @intFromEnum(JackPortFlags.is_input));
    try std.testing.expectEqual(@as(c_ulong, 0x2), @intFromEnum(JackPortFlags.is_output));
    try std.testing.expectEqual(@as(c_ulong, 0x4), @intFromEnum(JackPortFlags.is_physical));
}

test "JackOptions values match JACK C API" {
    try std.testing.expectEqual(@as(c_int, 0x01), @intFromEnum(JackOptions.no_start_server));
    try std.testing.expectEqual(@as(c_int, 0x02), @intFromEnum(JackOptions.use_exact_name));
}

test "JACK_DEFAULT_AUDIO_TYPE is correct string" {
    try std.testing.expectEqualStrings("32 bit float mono audio", JACK_DEFAULT_AUDIO_TYPE);
}

test "JackNframes is u32" {
    try std.testing.expectEqual(@sizeOf(JackNframes), @sizeOf(u32));
}

test "JackProcessCallback has C calling convention" {
    // Structural: verify callback type uses C calling convention.
    // processCallback matching this type is enforced by Zig's type system.
    const info = @typeInfo(JackProcessCallback);
    const fn_info = @typeInfo(info.pointer.child);
    try std.testing.expect(fn_info.@"fn".calling_convention.eql(std.builtin.CallingConvention.c));
}
