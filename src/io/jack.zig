const std = @import("std");

// ── JACK Audio + MIDI Client (WP-009, WP-010) ───────────────────────
// Hand-written JACK C-Bindings fuer Audio-Output (Stereo) + MIDI-Input.
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
pub const JACK_DEFAULT_MIDI_TYPE = "8 bit raw midi";

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
) *anyopaque;

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

// ── MIDI Extern Declarations (WP-010) ───────────────────────────────

/// JACK MIDI event as returned by jack_midi_event_get.
/// Layout matches jack_midi_event_t from the C API.
pub const JackMidiEvent = extern struct {
    time: JackNframes,
    size: usize,
    buffer: [*]const u8,
};

extern "jack" fn jack_midi_get_event_count(port_buffer: *anyopaque) JackNframes;

extern "jack" fn jack_midi_event_get(
    event: *JackMidiEvent,
    port_buffer: *anyopaque,
    event_index: u32,
) c_int;

// ── MIDI Event Parsing (WP-010) ──────────────────────────────────────

pub const MidiStatus = enum(u4) {
    note_off = 0x8,
    note_on = 0x9,
    poly_aftertouch = 0xA,
    control_change = 0xB,
    program_change = 0xC,
    channel_aftertouch = 0xD,
    pitch_bend = 0xE,
    system = 0xF,
};

/// Parsed MIDI event — zero-alloc, suitable for RT audio thread.
pub const MidiEvent = struct {
    time: JackNframes,
    status: MidiStatus,
    channel: u4,
    data1: u7,
    data2: u7,

    /// Parse raw MIDI bytes into a MidiEvent.
    /// Returns null for malformed or system-exclusive messages.
    pub fn parse(time: JackNframes, data: []const u8) ?MidiEvent {
        if (data.len < 1) return null;
        const status_byte = data[0];
        // System messages (0xF0-0xFF) — skip
        if (status_byte >= 0xF0) return null;
        // Channel voice messages need at least 2 bytes
        if (data.len < 2) return null;

        const status_nibble: u4 = @truncate(status_byte >> 4);
        const channel: u4 = @truncate(status_byte);
        const data1: u7 = @truncate(data[1] & 0x7F);

        const status = std.meta.intToEnum(MidiStatus, status_nibble) catch return null;

        // Program Change (0xC) and Channel Aftertouch (0xD) have 1 data byte
        const data2: u7 = if (data.len >= 3) @truncate(data[2] & 0x7F) else 0;

        return MidiEvent{
            .time = time,
            .status = status,
            .channel = channel,
            .data1 = data1,
            .data2 = data2,
        };
    }
};

// ── JackAudioClient ──────────────────────────────────────────────────

pub const ProcessFn = *const fn ([*]f32, [*]f32, JackNframes) void;
pub const MidiEventFn = *const fn (MidiEvent) void;

pub const JackAudioClient = struct {
    client: *JackClient,
    out_l: *JackPort,
    out_r: *JackPort,
    midi_in: *JackPort,
    process_fn: ?ProcessFn,
    midi_fn: ?MidiEventFn,

    /// Open a JACK client with stereo output ports and MIDI input.
    /// Does NOT activate — call start() to begin processing.
    pub fn init(process_fn: ?ProcessFn, midi_fn: ?MidiEventFn) !JackAudioClient {
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

        const midi_in = jack_port_register(
            client,
            "midi_in",
            JACK_DEFAULT_MIDI_TYPE,
            @intFromEnum(JackPortFlags.is_input),
            0,
        ) orelse {
            _ = jack_client_close(client);
            return error.JackPortRegisterFailed;
        };

        return JackAudioClient{
            .client = client,
            .out_l = out_l,
            .out_r = out_r,
            .midi_in = midi_in,
            .process_fn = process_fn,
            .midi_fn = midi_fn,
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
    /// Only: read/write audio buffers, parse MIDI, call DSP functions.
    fn processCallback(nframes: JackNframes, arg: ?*anyopaque) callconv(.c) c_int {
        const self: *JackAudioClient = @ptrCast(@alignCast(arg orelse return 0));

        // ── MIDI input ──────────────────────────────────────────
        if (self.midi_fn) |midi_handler| {
            const midi_buf = jack_port_get_buffer(self.midi_in, nframes);
            const event_count = jack_midi_get_event_count(midi_buf);
            var i: u32 = 0;
            while (i < event_count) : (i += 1) {
                var raw_event: JackMidiEvent = undefined;
                if (jack_midi_event_get(&raw_event, midi_buf, i) == 0) {
                    if (MidiEvent.parse(raw_event.time, raw_event.buffer[0..raw_event.size])) |midi_event| {
                        midi_handler(midi_event);
                    }
                }
            }
        }

        // ── Audio output ────────────────────────────────────────
        const out_l: [*]f32 = @ptrCast(@alignCast(jack_port_get_buffer(self.out_l, nframes)));
        const out_r: [*]f32 = @ptrCast(@alignCast(jack_port_get_buffer(self.out_r, nframes)));

        if (self.process_fn) |process| {
            process(out_l, out_r, nframes);
        } else {
            for (0..nframes) |i| {
                out_l[i] = 0.0;
                out_r[i] = 0.0;
            }
        }
        return 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// Note: Integration tests (AC-1, AC-2) require a running JACK server.
// Unit tests below verify structural properties and MIDI parsing.

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

test "JACK_DEFAULT_MIDI_TYPE is correct string" {
    try std.testing.expectEqualStrings("8 bit raw midi", JACK_DEFAULT_MIDI_TYPE);
}

test "JackNframes is u32" {
    try std.testing.expectEqual(@sizeOf(JackNframes), @sizeOf(u32));
}

test "JackProcessCallback has C calling convention" {
    const info = @typeInfo(JackProcessCallback);
    const fn_info = @typeInfo(info.pointer.child);
    try std.testing.expect(fn_info.@"fn".calling_convention.eql(std.builtin.CallingConvention.c));
}

test "JackMidiEvent layout matches C jack_midi_event_t" {
    // C struct: uint32_t time (4) + padding (4) + size_t size (8) + pointer (8) = 24
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(JackMidiEvent));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(JackMidiEvent, "time"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(JackMidiEvent, "size"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(JackMidiEvent, "buffer"));
}

// ── MIDI Parsing Tests (WP-010, AC-3) ───────────────────────────────

test "parse Note-On" {
    const data = [_]u8{ 0x90, 0x3C, 0x7F }; // Ch0, C4, vel=127
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(MidiStatus.note_on, event.status);
    try std.testing.expectEqual(@as(u4, 0), event.channel);
    try std.testing.expectEqual(@as(u7, 60), event.data1); // C4
    try std.testing.expectEqual(@as(u7, 127), event.data2); // velocity
}

test "parse Note-Off" {
    const data = [_]u8{ 0x80, 0x3C, 0x40 }; // Ch0, C4, vel=64
    const event = MidiEvent.parse(42, &data).?;
    try std.testing.expectEqual(MidiStatus.note_off, event.status);
    try std.testing.expectEqual(@as(u4, 0), event.channel);
    try std.testing.expectEqual(@as(u7, 60), event.data1);
    try std.testing.expectEqual(@as(u7, 64), event.data2);
    try std.testing.expectEqual(@as(JackNframes, 42), event.time);
}

test "parse CC" {
    const data = [_]u8{ 0xB3, 0x01, 0x50 }; // Ch3, CC1 (ModWheel), value=80
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(MidiStatus.control_change, event.status);
    try std.testing.expectEqual(@as(u4, 3), event.channel);
    try std.testing.expectEqual(@as(u7, 1), event.data1); // CC number
    try std.testing.expectEqual(@as(u7, 80), event.data2); // CC value
}

test "parse Note-On channel 15" {
    const data = [_]u8{ 0x9F, 0x40, 0x60 }; // Ch15, note=64, vel=96
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(MidiStatus.note_on, event.status);
    try std.testing.expectEqual(@as(u4, 15), event.channel);
    try std.testing.expectEqual(@as(u7, 64), event.data1);
    try std.testing.expectEqual(@as(u7, 96), event.data2);
}

test "parse Program Change (1 data byte)" {
    const data = [_]u8{ 0xC0, 0x05 }; // Ch0, program 5
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(MidiStatus.program_change, event.status);
    try std.testing.expectEqual(@as(u7, 5), event.data1);
    try std.testing.expectEqual(@as(u7, 0), event.data2); // no data2
}

test "parse Pitch Bend" {
    const data = [_]u8{ 0xE0, 0x00, 0x40 }; // Ch0, center
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(MidiStatus.pitch_bend, event.status);
    try std.testing.expectEqual(@as(u7, 0), event.data1); // LSB
    try std.testing.expectEqual(@as(u7, 64), event.data2); // MSB
}

test "reject empty data" {
    const data = [_]u8{};
    try std.testing.expectEqual(@as(?MidiEvent, null), MidiEvent.parse(0, &data));
}

test "reject too short data" {
    const data = [_]u8{0x90}; // Note-On needs 3 bytes
    try std.testing.expectEqual(@as(?MidiEvent, null), MidiEvent.parse(0, &data));
}

test "reject system exclusive" {
    const data = [_]u8{ 0xF0, 0x7E, 0x7F, 0xF7 };
    try std.testing.expectEqual(@as(?MidiEvent, null), MidiEvent.parse(0, &data));
}

test "reject system realtime" {
    const data = [_]u8{0xFE}; // Active Sensing
    try std.testing.expectEqual(@as(?MidiEvent, null), MidiEvent.parse(0, &data));
}

test "data bytes masked to 7 bits" {
    const data = [_]u8{ 0x90, 0xFF, 0xFF }; // invalid high bits
    const event = MidiEvent.parse(0, &data).?;
    try std.testing.expectEqual(@as(u7, 127), event.data1);
    try std.testing.expectEqual(@as(u7, 127), event.data2);
}

// ── MIDI Parsing Benchmark (WP-010, AC-B1) ──────────────────────────

test "bench: MIDI Note-On parse throughput" {
    const RUNS = 5;
    const ITERS = 10_000;
    const note_on = [_]u8{ 0x90, 0x3C, 0x7F };

    var times: [RUNS]u64 = undefined;
    for (&times) |*t| {
        const start = std.time.nanoTimestamp();
        for (0..ITERS) |i| {
            const event = MidiEvent.parse(@intCast(i % 128), &note_on);
            std.mem.doNotOptimizeAway(&event);
        }
        const end = std.time.nanoTimestamp();
        t.* = @intCast(end - start);
    }

    // Sort for median
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[RUNS / 2];
    var sum: u64 = 0;
    for (times) |t| sum += t;
    const avg = sum / RUNS;
    const ns_per_event = avg / ITERS;

    std.debug.print(
        "\n  [WP-010] MIDI Note-On parse — {d} events, {d} Runs\n" ++
            "    median: {d}ns/event | avg: {d}ns | min: {d}ns | max: {d}ns\n" ++
            "    Schwelle: < 100ns/event (Issue #12)\n\n",
        .{
            ITERS,
            RUNS,
            times[RUNS / 2] / ITERS,
            ns_per_event,
            times[0] / ITERS,
            times[RUNS - 1] / ITERS,
        },
    );

    // Enforce only in ReleaseFast — Debug has no inlining, overhead per call
    const enforce = @import("builtin").mode == .ReleaseFast;
    if (enforce) {
        if (median / ITERS > 100) {
            std.debug.print("  FAIL: {d}ns/event > 100ns\n", .{median / ITERS});
            return error.BenchmarkFailed;
        }
    }
}

test "bench: MIDI CC parse throughput" {
    const RUNS = 5;
    const ITERS = 10_000;
    const cc = [_]u8{ 0xB0, 0x01, 0x40 };

    var times: [RUNS]u64 = undefined;
    for (&times) |*t| {
        const start = std.time.nanoTimestamp();
        for (0..ITERS) |i| {
            const event = MidiEvent.parse(@intCast(i % 128), &cc);
            std.mem.doNotOptimizeAway(&event);
        }
        const end = std.time.nanoTimestamp();
        t.* = @intCast(end - start);
    }

    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[RUNS / 2];
    const ns_per_event = median / ITERS;

    std.debug.print(
        "\n  [WP-010] MIDI CC parse — {d} events, {d} Runs\n" ++
            "    median: {d}ns/event\n" ++
            "    Schwelle: < 100ns/event (Issue #12)\n\n",
        .{ ITERS, RUNS, ns_per_event },
    );

    const enforce = @import("builtin").mode == .ReleaseFast;
    if (enforce) {
        if (median / ITERS > 100) {
            std.debug.print("  FAIL: {d}ns/event > 100ns\n", .{median / ITERS});
            return error.BenchmarkFailed;
        }
    }
}

test "bench: MIDI burst 128 events" {
    const RUNS = 5;
    const EVENTS = 128;

    // Pre-build 128 raw MIDI messages (alternating Note-On/Off)
    var raw_data: [EVENTS][3]u8 = undefined;
    for (0..EVENTS) |i| {
        if (i % 2 == 0) {
            raw_data[i] = .{ 0x90, @intCast(i % 128), 0x7F }; // Note-On
        } else {
            raw_data[i] = .{ 0x80, @intCast(i % 128), 0x40 }; // Note-Off
        }
    }

    var times: [RUNS]u64 = undefined;
    for (&times) |*t| {
        const start = std.time.nanoTimestamp();
        for (0..EVENTS) |i| {
            const event = MidiEvent.parse(@intCast(i), &raw_data[i]);
            std.mem.doNotOptimizeAway(&event);
        }
        const end = std.time.nanoTimestamp();
        t.* = @intCast(end - start);
    }

    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[RUNS / 2];

    std.debug.print(
        "\n  [WP-010] MIDI burst — {d} events/block, {d} Runs\n" ++
            "    median: {d}ns total | {d}ns/event\n" ++
            "    Budget: {d:.4}% von 2.9ms\n" ++
            "    Schwelle: >= 128 events/block (Issue #12)\n\n",
        .{
            EVENTS,
            RUNS,
            median,
            median / EVENTS,
            @as(f64, @floatFromInt(median)) / 2_900_000.0 * 100.0,
        },
    );

    // 128 events in a block must complete in << 2.9ms
    if (median > 100_000) { // 100us sanity check
        std.debug.print("  FAIL: {d}ns > 100us for 128 events\n", .{median});
        return error.BenchmarkFailed;
    }
}
