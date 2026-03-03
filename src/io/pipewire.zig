const std = @import("std");

// ── PipeWire Native Audio Client (WP-011) ───────────────────────────
// Hand-written PipeWire C-Bindings fuer Audio-Output (Stereo).
// Kein @cImport — Zig extern Deklarationen direkt auf die PipeWire C-API.
// process_callback ist RT-safe: KEIN malloc/mutex/print erlaubt.

// ── SPA Types ────────────────────────────────────────────────────────

pub const spa_list = extern struct {
    next: *spa_list,
    prev: *spa_list,
};

pub const spa_callbacks = extern struct {
    funcs: ?*const anyopaque,
    data: ?*anyopaque,
};

pub const spa_hook = extern struct {
    link: spa_list,
    cb: spa_callbacks,
    removed: ?*const fn (*spa_hook) callconv(.c) void,
    priv: ?*anyopaque,
};

pub const spa_dict_item = extern struct {
    key: [*:0]const u8,
    value: [*:0]const u8,
};

pub const spa_dict = extern struct {
    flags: u32,
    n_items: u32,
    items: ?[*]const spa_dict_item,
};

pub const spa_pod = extern struct {
    size: u32,
    type: u32,
};

pub const spa_chunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const spa_data = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*spa_chunk,
};

pub const spa_meta = extern struct {
    type: u32,
    size: u32,
    data: ?*anyopaque,
};

pub const spa_buffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?[*]spa_meta,
    datas: ?[*]spa_data,
};

// ── SPA Constants ────────────────────────────────────────────────────

const SPA_TYPE_Id: u32 = 3;
const SPA_TYPE_Int: u32 = 4;
const SPA_TYPE_Object: u32 = 15;

const SPA_PARAM_EnumFormat: u32 = 3;
const SPA_TYPE_OBJECT_Format: u32 = 0x40003;

const SPA_FORMAT_mediaType: u32 = 1;
const SPA_FORMAT_mediaSubtype: u32 = 2;
const SPA_FORMAT_AUDIO_format: u32 = 0x10001;
const SPA_FORMAT_AUDIO_rate: u32 = 0x10003;
const SPA_FORMAT_AUDIO_channels: u32 = 0x10004;

const SPA_MEDIA_TYPE_audio: u32 = 1;
const SPA_MEDIA_SUBTYPE_raw: u32 = 1;
pub const SPA_AUDIO_FORMAT_F32_LE: u32 = 283;
pub const SPA_AUDIO_FORMAT_F32P: u32 = 518;

const SPA_FORMAT_AUDIO_position: u32 = 0x10005;

const SPA_AUDIO_CHANNEL_FL: u32 = 3;
const SPA_AUDIO_CHANNEL_FR: u32 = 4;

const SPA_TYPE_Array: u32 = 13;

// ── PipeWire Opaque Types ────────────────────────────────────────────

pub const pw_main_loop = opaque {};
pub const pw_loop = opaque {};
pub const pw_stream = opaque {};
pub const pw_properties = opaque {};

// ── PipeWire Types ───────────────────────────────────────────────────

pub const pw_buffer = extern struct {
    buffer: *spa_buffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

pub const pw_stream_state = enum(i32) {
    ERROR = -1,
    UNCONNECTED = 0,
    CONNECTING = 1,
    PAUSED = 2,
    STREAMING = 3,
};

pub const pw_direction = enum(u32) {
    INPUT = 0,
    OUTPUT = 1,
};

pub const PW_ID_ANY: u32 = 0xffffffff;

pub const PW_STREAM_FLAG_AUTOCONNECT: u32 = 1 << 0;
pub const PW_STREAM_FLAG_MAP_BUFFERS: u32 = 1 << 2;
pub const PW_STREAM_FLAG_RT_PROCESS: u32 = 1 << 4;

pub const PW_VERSION_STREAM_EVENTS: u32 = 2;

// pw_stream_events: callback vtable for stream events.
// Only `version` and `process` are required; all others are optional.
pub const pw_stream_events = extern struct {
    version: u32,
    _pad: u32 = 0,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, pw_stream_state, pw_stream_state, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const fn (?*anyopaque, u32, ?*anyopaque) callconv(.c) void = null,
    io_changed: ?*const fn (?*anyopaque, u32, ?*anyopaque, u32) callconv(.c) void = null,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const spa_pod) callconv(.c) void = null,
    add_buffer: ?*const fn (?*anyopaque, ?*pw_buffer) callconv(.c) void = null,
    remove_buffer: ?*const fn (?*anyopaque, ?*pw_buffer) callconv(.c) void = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const fn (?*anyopaque) callconv(.c) void = null,
    command: ?*const fn (?*anyopaque, ?*const spa_pod) callconv(.c) void = null,
    trigger_done: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

// ── PipeWire Key Constants ───────────────────────────────────────────

pub const PW_KEY_MEDIA_TYPE = "media.type";
pub const PW_KEY_MEDIA_CATEGORY = "media.category";
pub const PW_KEY_MEDIA_ROLE = "media.role";
pub const PW_KEY_NODE_NAME = "node.name";
pub const PW_KEY_APP_NAME = "application.name";

// ── Extern Declarations (hand-written, NO @cImport) ─────────────────

// PipeWire init/deinit
extern "pipewire-0.3" fn pw_init(argc: ?*c_int, argv: ?*?[*]?[*:0]u8) void;
extern "pipewire-0.3" fn pw_deinit() void;

// Main loop
extern "pipewire-0.3" fn pw_main_loop_new(props: ?*const spa_dict) ?*pw_main_loop;
extern "pipewire-0.3" fn pw_main_loop_destroy(loop: *pw_main_loop) void;
extern "pipewire-0.3" fn pw_main_loop_get_loop(loop: *pw_main_loop) *pw_loop;
extern "pipewire-0.3" fn pw_main_loop_run(loop: *pw_main_loop) c_int;
extern "pipewire-0.3" fn pw_main_loop_quit(loop: *pw_main_loop) c_int;

// Stream (pw_stream_new_simple handles listener setup internally)
extern "pipewire-0.3" fn pw_stream_new_simple(
    loop: *pw_loop,
    name: [*:0]const u8,
    props: *pw_properties,
    events: *const pw_stream_events,
    data: ?*anyopaque,
) ?*pw_stream;

extern "pipewire-0.3" fn pw_stream_destroy(stream: *pw_stream) void;

extern "pipewire-0.3" fn pw_stream_connect(
    stream: *pw_stream,
    direction: pw_direction,
    target_id: u32,
    flags: u32,
    params: [*]const *const spa_pod,
    n_params: u32,
) c_int;

extern "pipewire-0.3" fn pw_stream_disconnect(stream: *pw_stream) c_int;
extern "pipewire-0.3" fn pw_stream_dequeue_buffer(stream: *pw_stream) ?*pw_buffer;
extern "pipewire-0.3" fn pw_stream_queue_buffer(stream: *pw_stream, buffer: *pw_buffer) c_int;
extern "pipewire-0.3" fn pw_stream_get_node_id(stream: *pw_stream) u32;

// Properties
extern "pipewire-0.3" fn pw_properties_new(
    key: ?[*:0]const u8,
    ...,
) ?*pw_properties;
extern "pipewire-0.3" fn pw_properties_free(properties: *pw_properties) void;

// ── SPA Audio Format Pod Builder (comptime) ──────────────────────────
// Build a static SPA pod for F32_LE stereo audio at a given sample rate.
// This replaces the C spa_format_audio_raw_build() which is inline-only.

const AudioFormatPod = struct {
    // Object header
    pod: spa_pod,
    body_type: u32,
    body_id: u32,
    // Property 1: mediaType = audio
    p1_key: u32,
    p1_flags: u32,
    p1_pod: spa_pod,
    p1_value: u32,
    p1_pad: u32,
    // Property 2: mediaSubtype = raw
    p2_key: u32,
    p2_flags: u32,
    p2_pod: spa_pod,
    p2_value: u32,
    p2_pad: u32,
    // Property 3: audio.format = F32_LE
    p3_key: u32,
    p3_flags: u32,
    p3_pod: spa_pod,
    p3_value: u32,
    p3_pad: u32,
    // Property 4: audio.rate
    p4_key: u32,
    p4_flags: u32,
    p4_pod: spa_pod,
    p4_value: u32,
    p4_pad: u32,
    // Property 5: audio.channels = 2
    p5_key: u32,
    p5_flags: u32,
    p5_pod: spa_pod,
    p5_value: u32,
    p5_pad: u32,
    // Property 6: audio.position = [FL, FR]
    // SPA Array: pod header + child type descriptor + elements
    p6_key: u32,
    p6_flags: u32,
    p6_pod: spa_pod, // Array pod: size = child(8) + 2*4 = 16
    p6_child: spa_pod, // Element type: Id, size 4
    p6_fl: u32, // SPA_AUDIO_CHANNEL_FL
    p6_fr: u32, // SPA_AUDIO_CHANNEL_FR

    fn build(sample_rate: u32) AudioFormatPod {
        const body_size = @sizeOf(AudioFormatPod) - @sizeOf(spa_pod);
        return .{
            .pod = .{ .size = body_size, .type = SPA_TYPE_Object },
            .body_type = SPA_TYPE_OBJECT_Format,
            .body_id = SPA_PARAM_EnumFormat,
            // mediaType = audio (enum value 1, NOT 0)
            .p1_key = SPA_FORMAT_mediaType,
            .p1_flags = 0,
            .p1_pod = .{ .size = 4, .type = SPA_TYPE_Id },
            .p1_value = SPA_MEDIA_TYPE_audio,
            .p1_pad = 0,
            // mediaSubtype = raw
            .p2_key = SPA_FORMAT_mediaSubtype,
            .p2_flags = 0,
            .p2_pod = .{ .size = 4, .type = SPA_TYPE_Id },
            .p2_value = SPA_MEDIA_SUBTYPE_raw,
            .p2_pad = 0,
            // audio.format = F32P (planar float — one port per channel)
            .p3_key = SPA_FORMAT_AUDIO_format,
            .p3_flags = 0,
            .p3_pod = .{ .size = 4, .type = SPA_TYPE_Id },
            .p3_value = SPA_AUDIO_FORMAT_F32P,
            .p3_pad = 0,
            // audio.rate
            .p4_key = SPA_FORMAT_AUDIO_rate,
            .p4_flags = 0,
            .p4_pod = .{ .size = 4, .type = SPA_TYPE_Int },
            .p4_value = sample_rate,
            .p4_pad = 0,
            // audio.channels = 2
            .p5_key = SPA_FORMAT_AUDIO_channels,
            .p5_flags = 0,
            .p5_pod = .{ .size = 4, .type = SPA_TYPE_Int },
            .p5_value = 2,
            .p5_pad = 0,
            // audio.position = [FL, FR]
            .p6_key = SPA_FORMAT_AUDIO_position,
            .p6_flags = 0,
            .p6_pod = .{ .size = 16, .type = SPA_TYPE_Array },
            .p6_child = .{ .size = 4, .type = SPA_TYPE_Id },
            .p6_fl = SPA_AUDIO_CHANNEL_FL,
            .p6_fr = SPA_AUDIO_CHANNEL_FR,
        };
    }
};

// ── PipeWireClient ───────────────────────────────────────────────────

const jack = @import("jack.zig");

pub const ProcessFn = jack.ProcessFn;

pub const PipeWireClient = struct {
    main_loop: *pw_main_loop,
    stream: ?*pw_stream = null,
    process_fn: ?ProcessFn,
    sample_rate: u32,

    // Stream events vtable — must live as long as the stream
    stream_events: pw_stream_events,
    // Format pod — must live until stream is connected
    format_pod: AudioFormatPod,

    /// Check if PipeWire daemon is reachable by probing stream connect.
    /// Initializes and deinitializes PipeWire — call before init().
    pub fn probe() bool {
        pw_init(null, null);
        const loop = pw_main_loop_new(null) orelse {
            pw_deinit();
            return false;
        };
        const props = pw_properties_new(
            PW_KEY_NODE_NAME,
            "probe",
            @as(?[*:0]const u8, null),
        ) orelse {
            pw_main_loop_destroy(loop);
            pw_deinit();
            return false;
        };
        var events = pw_stream_events{ .version = PW_VERSION_STREAM_EVENTS };
        const stream = pw_stream_new_simple(
            pw_main_loop_get_loop(loop),
            "probe",
            props,
            &events,
            null,
        ) orelse {
            pw_main_loop_destroy(loop);
            pw_deinit();
            return false;
        };
        var pod = AudioFormatPod.build(44100);
        const params = [_]*const spa_pod{@ptrCast(&pod)};
        const ok = pw_stream_connect(
            stream,
            .OUTPUT,
            PW_ID_ANY,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
            &params,
            1,
        ) >= 0;
        _ = pw_stream_disconnect(stream);
        pw_stream_destroy(stream);
        pw_main_loop_destroy(loop);
        pw_deinit();
        return ok;
    }

    /// Initialize PipeWire and create main loop.
    /// Stream is created lazily in start() to ensure stable self pointer.
    /// Default sample rate 48000 matches the PipeWire daemon default — no resampling.
    pub fn init(process_fn: ?ProcessFn) !PipeWireClient {
        pw_init(null, null);

        const main_loop = pw_main_loop_new(null) orelse {
            pw_deinit();
            return error.PipeWireMainLoopFailed;
        };

        const rate: u32 = 48000;
        return .{
            .main_loop = main_loop,
            .stream = null,
            .process_fn = process_fn,
            .sample_rate = rate,
            .stream_events = .{
                .version = PW_VERSION_STREAM_EVENTS,
                .process = processCallback,
            },
            .format_pod = AudioFormatPod.build(rate),
        };
    }

    /// Create stream, connect, and run the main loop (blocks).
    /// self must be at a stable address (not on a temporary stack frame).
    pub fn start(self: *PipeWireClient) !void {
        const props = pw_properties_new(
            PW_KEY_NODE_NAME,
            "worldsynth",
            PW_KEY_MEDIA_TYPE,
            "Audio",
            PW_KEY_MEDIA_CATEGORY,
            "Playback",
            PW_KEY_MEDIA_ROLE,
            "Music",
            @as(?[*:0]const u8, null),
        ) orelse return error.PipeWirePropertiesFailed;

        self.stream = pw_stream_new_simple(
            pw_main_loop_get_loop(self.main_loop),
            "worldsynth",
            props,
            &self.stream_events,
            @ptrCast(self),
        ) orelse return error.PipeWireStreamFailed;

        self.format_pod = AudioFormatPod.build(self.sample_rate);
        const params = [_]*const spa_pod{@ptrCast(&self.format_pod)};

        if (pw_stream_connect(
            self.stream.?,
            .OUTPUT,
            PW_ID_ANY,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
            &params,
            1,
        ) < 0) {
            return error.PipeWireConnectFailed;
        }

        // pw_main_loop_run blocks — run in a thread or use signal to quit
        _ = pw_main_loop_run(self.main_loop);
    }

    /// Destroy stream (if created), main loop, and deinit PipeWire.
    pub fn deinit(self: *PipeWireClient) void {
        if (self.stream) |s| {
            pw_stream_destroy(s);
        }
        pw_main_loop_destroy(self.main_loop);
        pw_deinit();
    }

    /// Signal the main loop to stop (call from another thread or signal handler).
    pub fn quit(self: *PipeWireClient) void {
        _ = pw_main_loop_quit(self.main_loop);
    }

    /// PipeWire process callback — called from the RT audio thread.
    /// MUST NOT: malloc, free, lock mutex, print, syscall.
    /// F32P planar format: datas[0] = FL channel, datas[1] = FR channel.
    fn processCallback(userdata: ?*anyopaque) callconv(.c) void {
        const self: *PipeWireClient = @ptrCast(@alignCast(userdata orelse return));
        const stream = self.stream orelse return;
        const buf = pw_stream_dequeue_buffer(stream) orelse return;
        const spa_buf = buf.buffer;

        // F32P stereo requires at least 2 data planes (FL, FR)
        if (spa_buf.n_datas < 2) {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        }

        const datas = spa_buf.datas orelse {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        };

        const d_fl = &datas[0];
        const d_fr = &datas[1];
        const chunk_fl = d_fl.chunk orelse {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        };
        const chunk_fr = d_fr.chunk orelse {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        };

        const n_frames: u32 = if (buf.requested > 0)
            @intCast(@min(buf.requested, d_fl.maxsize / @sizeOf(f32)))
        else
            d_fl.maxsize / @sizeOf(f32);

        // Planar F32P: separate buffer per channel
        const out_fl: [*]f32 = @ptrCast(@alignCast(d_fl.data orelse {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        }));
        const out_fr: [*]f32 = @ptrCast(@alignCast(d_fr.data orelse {
            _ = pw_stream_queue_buffer(stream, buf);
            return;
        }));

        if (self.process_fn) |process| {
            process(out_fl, out_fr, n_frames);
        } else {
            for (0..n_frames) |i| {
                out_fl[i] = 0.0;
                out_fr[i] = 0.0;
            }
        }

        const byte_size = n_frames * @sizeOf(f32);
        chunk_fl.offset = 0;
        chunk_fl.stride = @sizeOf(f32);
        chunk_fl.size = byte_size;
        chunk_fr.offset = 0;
        chunk_fr.stride = @sizeOf(f32);
        chunk_fr.size = byte_size;
        _ = pw_stream_queue_buffer(stream, buf);
    }
};

// ── Tests ────────────────────────────────────────────────────────────
// Note: Integration tests (AC-2, AC-3) require a running PipeWire server.
// Unit tests below verify structural properties and pod format.

test "spa_chunk layout matches C ABI" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(spa_chunk));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(spa_chunk, "offset"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(spa_chunk, "size"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(spa_chunk, "stride"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(spa_chunk, "flags"));
}

test "spa_data layout matches C ABI" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(spa_data));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(spa_data, "type"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(spa_data, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(spa_data, "fd"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(spa_data, "mapoffset"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(spa_data, "maxsize"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(spa_data, "data"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(spa_data, "chunk"));
}

test "spa_buffer layout matches C ABI" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(spa_buffer));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(spa_buffer, "n_metas"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(spa_buffer, "n_datas"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(spa_buffer, "metas"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(spa_buffer, "datas"));
}

test "pw_buffer layout matches C ABI" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(pw_buffer));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(pw_buffer, "buffer"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(pw_buffer, "user_data"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(pw_buffer, "size"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(pw_buffer, "requested"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(pw_buffer, "time"));
}

test "spa_hook layout matches C ABI" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(spa_hook));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(spa_hook, "link"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(spa_hook, "cb"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(spa_hook, "removed"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(spa_hook, "priv"));
}

test "AudioFormatPod builds valid F32P stereo pod" {
    const pod = AudioFormatPod.build(44100);
    // Object header
    try std.testing.expectEqual(SPA_TYPE_Object, pod.pod.type);
    try std.testing.expectEqual(SPA_TYPE_OBJECT_Format, pod.body_type);
    try std.testing.expectEqual(SPA_PARAM_EnumFormat, pod.body_id);
    // mediaType = audio
    try std.testing.expectEqual(SPA_FORMAT_mediaType, pod.p1_key);
    try std.testing.expectEqual(SPA_MEDIA_TYPE_audio, pod.p1_value);
    // mediaSubtype = raw
    try std.testing.expectEqual(SPA_FORMAT_mediaSubtype, pod.p2_key);
    try std.testing.expectEqual(SPA_MEDIA_SUBTYPE_raw, pod.p2_value);
    // audio.format = F32P (planar)
    try std.testing.expectEqual(SPA_FORMAT_AUDIO_format, pod.p3_key);
    try std.testing.expectEqual(SPA_AUDIO_FORMAT_F32P, pod.p3_value);
    // audio.rate = 44100
    try std.testing.expectEqual(SPA_FORMAT_AUDIO_rate, pod.p4_key);
    try std.testing.expectEqual(@as(u32, 44100), pod.p4_value);
    // audio.channels = 2
    try std.testing.expectEqual(SPA_FORMAT_AUDIO_channels, pod.p5_key);
    try std.testing.expectEqual(@as(u32, 2), pod.p5_value);
    // audio.position = [FL, FR]
    try std.testing.expectEqual(SPA_FORMAT_AUDIO_position, pod.p6_key);
    try std.testing.expectEqual(SPA_TYPE_Array, pod.p6_pod.type);
    try std.testing.expectEqual(SPA_AUDIO_CHANNEL_FL, pod.p6_fl);
    try std.testing.expectEqual(SPA_AUDIO_CHANNEL_FR, pod.p6_fr);
    // Body size = total - header
    const expected_body_size = @sizeOf(AudioFormatPod) - @sizeOf(spa_pod);
    try std.testing.expectEqual(@as(u32, expected_body_size), pod.pod.size);
}

test "AudioFormatPod custom sample rate" {
    const pod = AudioFormatPod.build(48000);
    try std.testing.expectEqual(@as(u32, 48000), pod.p4_value);
}

test "pw_stream_events has correct version" {
    const events = pw_stream_events{
        .version = PW_VERSION_STREAM_EVENTS,
    };
    try std.testing.expectEqual(@as(u32, 2), events.version);
    // All optional callbacks should be null
    try std.testing.expectEqual(@as(?*const fn (?*anyopaque) callconv(.c) void, null), events.destroy);
    try std.testing.expectEqual(@as(?*const fn (?*anyopaque) callconv(.c) void, null), events.process);
}

test "PipeWire key strings are correct" {
    try std.testing.expectEqualStrings("node.name", PW_KEY_NODE_NAME);
    try std.testing.expectEqualStrings("media.type", PW_KEY_MEDIA_TYPE);
    try std.testing.expectEqualStrings("media.category", PW_KEY_MEDIA_CATEGORY);
    try std.testing.expectEqualStrings("media.role", PW_KEY_MEDIA_ROLE);
}
