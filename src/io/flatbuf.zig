const std = @import("std");
const builtin = @import("builtin");

// -- Preset FlatBuffers Schema (WP-069) ----------------------------------------
// Zero-copy binary serialization for presets. extern struct layout guarantees
// deterministic field placement. Serialize = header + memcpy. Deserialize =
// validate header + memcpy back. <10KB per preset.

pub const SCHEMA_VERSION: u16 = 2;
pub const HEADER_MAGIC = [4]u8{ 'W', 'S', 'P', 'R' };
pub const HEADER_SIZE: usize = 16; // magic(4) + version(2) + reserved(2) + payload_size(4) + crc32(4)

// -- Sub-Schemas (extern struct for deterministic layout) ----------------------

pub const EnvelopeSchema = extern struct {
    attack_s: f32,
    decay_s: f32,
    sustain: f32,
    release_s: f32,
};

pub const LayerSchema = extern struct {
    engine_type: u8,
    filter_type: u8,
    enabled: u8,
    engine_param_count: u8,
    volume: f32,
    pan: f32,
    engine_params: [128]f32,
    filter_params: [8]f32,
    amp_envelope: EnvelopeSchema,
    filter_envelope: EnvelopeSchema,
};

pub const ModSlotSchema = extern struct {
    source_id: u16,
    target_id: u16,
    amount: f32,
    bipolar: u8,
    active: u8,
    _pad: [2]u8,
};

pub const FxSlotSchema = extern struct {
    fx_type: u8,
    bypass: u8,
    _pad: [2]u8,
    mix: f32,
};

pub const SendSlotSchema = extern struct {
    fx_type: u8,
    active: u8,
    _pad: [2]u8,
    send_amount: f32,
};

pub const FxChainSchema = extern struct {
    inserts: [8]FxSlotSchema,
    sends: [4]SendSlotSchema,
    slot_order: [8]u8,
};

pub const PresetSchema = extern struct {
    version: u16,
    name_len: u8,
    oversampling: u8,
    quality_mode: u8,
    _pad: [3]u8,
    master_volume: f32,
    pitch_bend_range: f32,
    glide_time: f32,
    macros: [8]f32,
    name: [64]u8,
    active_mod_slots: u16,
    _pad2: [2]u8,
    layers: [4]LayerSchema,
    mod_slots: [256]ModSlotSchema,
    fx_chain: FxChainSchema,

    pub fn init() PresetSchema {
        var preset = std.mem.zeroes(PresetSchema);
        preset.version = SCHEMA_VERSION;
        preset.master_volume = 1.0;
        preset.pitch_bend_range = 2.0;
        preset.layers[0].enabled = 1;
        preset.layers[0].volume = 1.0;
        preset.layers[0].amp_envelope = .{
            .attack_s = 0.01,
            .decay_s = 0.1,
            .sustain = 0.7,
            .release_s = 0.3,
        };
        preset.layers[0].filter_envelope = .{
            .attack_s = 0.0,
            .decay_s = 0.2,
            .sustain = 1.0,
            .release_s = 0.1,
        };
        for (&preset.fx_chain.slot_order, 0..) |*s, i| s.* = @intCast(i);
        return preset;
    }
};

// Compile-time budget check.
const PAYLOAD_SIZE: usize = @sizeOf(PresetSchema);
pub const SERIALIZED_SIZE: usize = HEADER_SIZE + PAYLOAD_SIZE;
comptime {
    if (SERIALIZED_SIZE > 10240) @compileError("PresetSchema exceeds 10KB budget");
}

// -- Errors -------------------------------------------------------------------

pub const SerializeError = error{BufferTooSmall};
pub const DeserializeError = error{ InvalidMagic, InvalidSize, ChecksumMismatch, BufferTooSmall };

// -- Serialization ------------------------------------------------------------

pub fn serialize(preset: *const PresetSchema, buffer: []u8) SerializeError![]u8 {
    if (buffer.len < SERIALIZED_SIZE) return error.BufferTooSmall;

    const payload = buffer[HEADER_SIZE..][0..PAYLOAD_SIZE];

    // Copy preset struct bytes into payload region.
    const preset_bytes: *const [PAYLOAD_SIZE]u8 = @ptrCast(preset);
    @memcpy(payload, preset_bytes);

    // CRC32 over payload.
    const checksum = std.hash.Crc32.hash(payload);

    // Write header (manual byte layout — no alignment dependency).
    @memcpy(buffer[0..4], &HEADER_MAGIC);
    std.mem.writeInt(u16, buffer[4..6], SCHEMA_VERSION, .little);
    @memset(buffer[6..8], 0);
    std.mem.writeInt(u32, buffer[8..12], PAYLOAD_SIZE, .little);
    std.mem.writeInt(u32, buffer[12..16], checksum, .little);

    return buffer[0..SERIALIZED_SIZE];
}

pub fn deserialize(buffer: []const u8) DeserializeError!PresetSchema {
    if (buffer.len < HEADER_SIZE) return error.BufferTooSmall;

    // Validate magic.
    if (!std.mem.eql(u8, buffer[0..4], &HEADER_MAGIC)) return error.InvalidMagic;

    // Read header fields.
    const payload_size = std.mem.readInt(u32, buffer[8..12], .little);
    const expected_crc = std.mem.readInt(u32, buffer[12..16], .little);

    if (payload_size != PAYLOAD_SIZE) return error.InvalidSize;
    if (buffer.len < HEADER_SIZE + payload_size) return error.BufferTooSmall;

    const payload = buffer[HEADER_SIZE..][0..PAYLOAD_SIZE];

    // Validate CRC32.
    const actual_crc = std.hash.Crc32.hash(payload);
    if (actual_crc != expected_crc) return error.ChecksumMismatch;

    // Copy payload into a properly aligned PresetSchema.
    var result: PresetSchema = undefined;
    const result_bytes: *[PAYLOAD_SIZE]u8 = @ptrCast(&result);
    @memcpy(result_bytes, payload);

    return result;
}

// -- Tests (WP-069) -----------------------------------------------------------

test "WP-069 AC-1: serialize/deserialize roundtrip" {
    var preset = PresetSchema.init();

    // Populate with representative data.
    const name = "Lead Brass Pad";
    @memcpy(preset.name[0..name.len], name);
    preset.name_len = name.len;
    preset.layers[0].engine_type = 5; // physical_modeling
    preset.layers[0].engine_params[0] = 440.0;
    preset.layers[0].engine_params[1] = 0.995;
    preset.layers[0].engine_param_count = 2;
    preset.layers[1].engine_type = 7; // phase_distortion
    preset.layers[1].enabled = 1;
    preset.layers[1].volume = 0.8;
    preset.layers[1].pan = -0.3;
    preset.mod_slots[0] = .{ .source_id = 1, .target_id = 42, .amount = 0.75, .bipolar = 1, .active = 1, ._pad = .{ 0, 0 } };
    preset.active_mod_slots = 1;
    preset.fx_chain.inserts[0] = .{ .fx_type = 1, .bypass = 0, ._pad = .{ 0, 0 }, .mix = 0.5 };
    preset.macros[0] = 0.5;
    preset.macros[7] = 1.0;

    // Serialize.
    var buf: [SERIALIZED_SIZE]u8 = undefined;
    const serialized = try serialize(&preset, &buf);
    try std.testing.expectEqual(SERIALIZED_SIZE, serialized.len);

    // Deserialize.
    const restored = try deserialize(serialized);

    // Byte-wise comparison.
    const orig_bytes: *const [PAYLOAD_SIZE]u8 = @ptrCast(&preset);
    const rest_bytes: *const [PAYLOAD_SIZE]u8 = @ptrCast(&restored);
    try std.testing.expectEqualSlices(u8, orig_bytes, rest_bytes);

    std.debug.print("\n[WP-069] AC-1: roundtrip PASS ({}B)\n", .{serialized.len});
}

test "WP-069 AC-2: serialized size under 10KB" {
    try std.testing.expect(SERIALIZED_SIZE < 10240);
    std.debug.print("\n[WP-069] AC-2: size={}B < 10240B PASS\n", .{SERIALIZED_SIZE});
}

test "WP-069 AC-3: version field correctly set" {
    const preset = PresetSchema.init();
    try std.testing.expectEqual(SCHEMA_VERSION, preset.version);
    std.debug.print("\n[WP-069] AC-3: version={} PASS\n", .{preset.version});
}

test "WP-069 AC-N1: corrupt magic returns InvalidMagic" {
    var preset = PresetSchema.init();
    var buf: [SERIALIZED_SIZE]u8 = undefined;
    _ = try serialize(&preset, &buf);

    // Corrupt magic bytes.
    buf[0] = 'X';
    const result = deserialize(&buf);
    try std.testing.expectError(error.InvalidMagic, result);
    std.debug.print("\n[WP-069] AC-N1: InvalidMagic PASS\n", .{});
}

test "WP-069 AC-N2: small buffer returns BufferTooSmall" {
    var preset = PresetSchema.init();
    var small_buf: [8]u8 = undefined;
    const ser_result = serialize(&preset, &small_buf);
    try std.testing.expectError(error.BufferTooSmall, ser_result);

    // Deserialize with small buffer.
    const deser_result = deserialize(&small_buf);
    try std.testing.expectError(error.BufferTooSmall, deser_result);
    std.debug.print("\n[WP-069] AC-N2: BufferTooSmall PASS\n", .{});
}

test "WP-069 AC-N3: corrupted payload returns ChecksumMismatch" {
    var preset = PresetSchema.init();
    var buf: [SERIALIZED_SIZE]u8 = undefined;
    _ = try serialize(&preset, &buf);

    // Flip a bit in the payload.
    buf[HEADER_SIZE + 10] ^= 0xFF;
    const result = deserialize(&buf);
    try std.testing.expectError(error.ChecksumMismatch, result);
    std.debug.print("\n[WP-069] AC-N3: ChecksumMismatch PASS\n", .{});
}

test "WP-069 AC-B1: serialize/deserialize benchmark" {
    var preset = PresetSchema.init();
    preset.layers[0].engine_params[0] = 440.0;
    for (0..128) |i| preset.layers[0].engine_params[i] = @floatFromInt(i);
    preset.mod_slots[0] = .{ .source_id = 1, .target_id = 2, .amount = 0.5, .bipolar = 1, .active = 1, ._pad = .{ 0, 0 } };

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 100,
        .ReleaseSafe => 1000,
        .ReleaseFast, .ReleaseSmall => 10000,
    };

    var buf: [SERIALIZED_SIZE]u8 = undefined;

    // Warmup.
    _ = try serialize(&preset, &buf);
    _ = try deserialize(&buf);

    // Benchmark serialize.
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        _ = try serialize(&preset, &buf);
    }
    const ser_ns = timer.read() / iterations;

    // Benchmark deserialize.
    _ = try serialize(&preset, &buf);
    timer.reset();
    for (0..iterations) |_| {
        _ = try deserialize(&buf);
    }
    const deser_ns = timer.read() / iterations;

    const ser_budget: u64 = switch (builtin.mode) {
        .Debug => 10_000_000,
        .ReleaseSafe => 2_000_000,
        .ReleaseFast, .ReleaseSmall => 1_000_000,
    };

    std.debug.print("\n[WP-069] AC-B1: serialize={d}ns, deserialize={d}ns, size={}B (budget: {d}ns, mode={s})\n", .{
        ser_ns, deser_ns, SERIALIZED_SIZE, ser_budget, @tagName(builtin.mode),
    });

    try std.testing.expect(ser_ns < ser_budget);
    try std.testing.expect(deser_ns < ser_budget);
}
