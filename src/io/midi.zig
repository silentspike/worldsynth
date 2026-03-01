const std = @import("std");

// ── MIDI 2.0 UMP Parser (WP-133) ────────────────────────────────────
// Universal MIDI Packet parsing with 32-bit controller resolution
// and 16-bit velocity. Backward compatible with MIDI 1.0 via Type 2.
//
// UMP Packet Layout:
//   Type 2 (MIDI 1.0 CV, 32-bit): [msg_type:4][group:4][status:8][data1:8][data2:8]
//   Type 4 (MIDI 2.0 CV, 64-bit): [msg_type:4][group:4][status:4][channel:4][note:8][attr_type:8]
//                                  [velocity/value:32]
//
// References: MIDI 2.0 Specification (MMA/AMEI), USB MIDI 2.0

pub const UmpError = error{
    UnsupportedType,
    InvalidStatus,
};

pub const MidiVersion = enum { midi1, midi2 };

/// MIDI status nibble (upper 4 bits of status byte)
pub const Status = enum(u4) {
    note_off = 0x8,
    note_on = 0x9,
    poly_pressure = 0xA,
    control_change = 0xB,
    program_change = 0xC,
    channel_pressure = 0xD,
    pitch_bend = 0xE,
    _,
};

pub const UmpMessage = struct {
    version: MidiVersion,
    group: u4 = 0,
    status: Status,
    channel: u4 = 0,
    // Note fields
    note: u7 = 0,
    // MIDI 2.0: 16-bit velocity (NoteOn/Off), MIDI 1.0: 7-bit in low bits
    velocity_16: u16 = 0,
    // MIDI 2.0: per-note attribute
    attribute_type: u8 = 0,
    attribute: u16 = 0,
    // Controller fields (CC, PitchBend, Pressure)
    controller: u7 = 0,
    value_32: u32 = 0,
    // MIDI 1.0 raw 7-bit values
    data1: u7 = 0,
    data2: u7 = 0,
};

/// Parse a UMP packet (1 or 2 words depending on type).
/// Type 2 = MIDI 1.0 Channel Voice (1 word, 32-bit)
/// Type 4 = MIDI 2.0 Channel Voice (2 words, 64-bit)
pub fn parse_ump(words: []const u32) UmpError!UmpMessage {
    if (words.len == 0) return error.UnsupportedType;

    const w0 = words[0];
    const msg_type: u4 = @truncate(w0 >> 28);

    return switch (msg_type) {
        0x2 => parse_midi1_cv(w0),
        0x4 => blk: {
            if (words.len < 2) break :blk error.UnsupportedType;
            break :blk parse_midi2_cv(w0, words[1]);
        },
        else => error.UnsupportedType,
    };
}

/// Parse Type 2: MIDI 1.0 Channel Voice in UMP wrapper.
/// Layout: [type:4][group:4][status_byte:8][data1:8][data2:8]
fn parse_midi1_cv(w0: u32) UmpError!UmpMessage {
    const group: u4 = @truncate(w0 >> 24);
    const status_byte: u8 = @truncate(w0 >> 16);
    const data1: u7 = @truncate(w0 >> 8);
    const data2: u7 = @truncate(w0);

    const status_nibble: u4 = @truncate(status_byte >> 4);
    const channel: u4 = @truncate(status_byte);

    const status: Status = @enumFromInt(status_nibble);

    var msg = UmpMessage{
        .version = .midi1,
        .group = group,
        .status = status,
        .channel = channel,
        .data1 = data1,
        .data2 = data2,
    };

    switch (status) {
        .note_on, .note_off => {
            msg.note = data1;
            // MIDI 1.0: 7-bit velocity → scale to 16-bit for uniform API
            msg.velocity_16 = @as(u16, data2) << 9;
        },
        .control_change => {
            msg.controller = data1;
            // MIDI 1.0: 7-bit CC → scale to 32-bit
            msg.value_32 = @as(u32, data2) << 25;
        },
        .pitch_bend => {
            // MIDI 1.0: 14-bit pitch bend (data1=LSB, data2=MSB)
            const pb14: u14 = @as(u14, data2) << 7 | @as(u14, data1);
            msg.value_32 = @as(u32, pb14) << 18;
        },
        .channel_pressure => {
            msg.value_32 = @as(u32, data1) << 25;
        },
        .poly_pressure => {
            msg.note = data1;
            msg.value_32 = @as(u32, data2) << 25;
        },
        else => {},
    }

    return msg;
}

/// Parse Type 4: MIDI 2.0 Channel Voice.
/// Word 0: [type:4][group:4][status:4][channel:4][note/ctrl:8][attr_type/index:8]
/// Word 1: [velocity:16][attribute:16]  (NoteOn/Off)
///      or [value:32]                   (CC, PitchBend, Pressure)
fn parse_midi2_cv(w0: u32, w1: u32) UmpError!UmpMessage {
    const group: u4 = @truncate(w0 >> 24);
    const status_nibble: u4 = @truncate(w0 >> 20);
    const channel: u4 = @truncate(w0 >> 16);
    const byte2: u8 = @truncate(w0 >> 8);
    const byte3: u8 = @truncate(w0);

    const status: Status = @enumFromInt(status_nibble);

    var msg = UmpMessage{
        .version = .midi2,
        .group = group,
        .status = status,
        .channel = channel,
    };

    switch (status) {
        .note_on, .note_off => {
            msg.note = @truncate(byte2);
            msg.attribute_type = byte3;
            msg.velocity_16 = @truncate(w1 >> 16);
            msg.attribute = @truncate(w1);
        },
        .control_change => {
            msg.controller = @truncate(byte2);
            msg.value_32 = w1;
        },
        .pitch_bend => {
            msg.value_32 = w1;
        },
        .channel_pressure => {
            msg.value_32 = w1;
        },
        .poly_pressure => {
            msg.note = @truncate(byte2);
            msg.value_32 = w1;
        },
        else => {},
    }

    return msg;
}

// ── Normalization helpers ────────────────────────────────────────────

/// Normalize 32-bit controller value to float (0.0–1.0).
pub fn value32_to_float(val: u32) f32 {
    return @as(f32, @floatFromInt(val)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

/// Normalize 16-bit velocity to float (0.0–1.0).
pub fn velocity16_to_float(vel: u16) f32 {
    return @as(f32, @floatFromInt(vel)) / @as(f32, @floatFromInt(std.math.maxInt(u16)));
}

/// Normalize 7-bit MIDI 1.0 value to float (0.0–1.0).
pub fn value7_to_float(val: u7) f32 {
    return @as(f32, @floatFromInt(val)) / 127.0;
}

// ── UMP Builder (for testing) ────────────────────────────────────────

/// Build a Type 2 (MIDI 1.0) UMP word.
pub fn build_midi1(group: u4, status: u4, channel: u4, data1: u7, data2: u7) u32 {
    return @as(u32, 0x2) << 28 |
        @as(u32, group) << 24 |
        @as(u32, status) << 20 |
        @as(u32, channel) << 16 |
        @as(u32, data1) << 8 |
        @as(u32, data2);
}

/// Build Type 4 (MIDI 2.0) UMP words for NoteOn.
pub fn build_midi2_note_on(group: u4, channel: u4, note: u7, velocity: u16, attr: u16) [2]u32 {
    return .{
        @as(u32, 0x4) << 28 |
            @as(u32, group) << 24 |
            @as(u32, 0x9) << 20 |
            @as(u32, channel) << 16 |
            @as(u32, note) << 8,
        @as(u32, velocity) << 16 | @as(u32, attr),
    };
}

/// Build Type 4 (MIDI 2.0) UMP words for CC.
pub fn build_midi2_cc(group: u4, channel: u4, controller: u7, value: u32) [2]u32 {
    return .{
        @as(u32, 0x4) << 28 |
            @as(u32, group) << 24 |
            @as(u32, 0xB) << 20 |
            @as(u32, channel) << 16 |
            @as(u32, controller) << 8,
        value,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: MIDI 2.0 NoteOn parsed correctly (Type 4)" {
    const words = build_midi2_note_on(0, 0, 60, 0xC000, 0);
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(MidiVersion.midi2, msg.version);
    try std.testing.expectEqual(Status.note_on, msg.status);
    try std.testing.expectEqual(@as(u7, 60), msg.note);
    try std.testing.expectEqual(@as(u16, 0xC000), msg.velocity_16);
    try std.testing.expectEqual(@as(u4, 0), msg.channel);
}

test "AC-1: MIDI 2.0 NoteOn with attribute" {
    const words = build_midi2_note_on(1, 5, 72, 0xFFFF, 0x1234);
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(@as(u4, 1), msg.group);
    try std.testing.expectEqual(@as(u4, 5), msg.channel);
    try std.testing.expectEqual(@as(u7, 72), msg.note);
    try std.testing.expectEqual(@as(u16, 0xFFFF), msg.velocity_16);
    try std.testing.expectEqual(@as(u16, 0x1234), msg.attribute);
}

test "AC-2: 32-bit velocity normalized to f32" {
    // Full velocity (16-bit max)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), velocity16_to_float(0xFFFF), 0.0001);
    // Zero
    try std.testing.expectEqual(@as(f32, 0.0), velocity16_to_float(0));
    // Midpoint
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), velocity16_to_float(0x8000), 0.01);

    // 32-bit CC value
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), value32_to_float(0xFFFFFFFF), 0.0001);
    try std.testing.expectEqual(@as(f32, 0.0), value32_to_float(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), value32_to_float(0x80000000), 0.01);
}

test "AC-2: 32-bit precision preserved" {
    // f32 has 24-bit mantissa → ~16M distinct values in [0,1].
    // Adjacent 32-bit values (step=1) map to same f32, but values
    // separated by ≥256 must be distinguishable — proving >16-bit
    // effective resolution vs MIDI 1.0's 7-bit (128 steps).
    const a = value32_to_float(0x80000000);
    const b = value32_to_float(0x80000400); // +1024 apart
    try std.testing.expect(a != b);

    // 7-bit equivalent values are much coarser
    const c = value7_to_float(64);
    const d = value7_to_float(65);
    const step_7bit = d - c;
    const step_32bit = b - a;
    // 32-bit step (1024 apart) should still be ≪ 7-bit step (~1/127)
    try std.testing.expect(step_32bit < step_7bit / 100.0);
}

test "AC-3: MIDI 1.0 in UMP (Type 2) works" {
    // NoteOn: channel 0, note 60, velocity 100
    const w0 = build_midi1(0, 0x9, 0, 60, 100);
    const words = [_]u32{w0};
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(MidiVersion.midi1, msg.version);
    try std.testing.expectEqual(Status.note_on, msg.status);
    try std.testing.expectEqual(@as(u7, 60), msg.note);
    try std.testing.expectEqual(@as(u7, 100), msg.data2);
    // 7-bit velocity scaled to 16-bit: 100 << 9 = 51200
    try std.testing.expectEqual(@as(u16, 100 << 9), msg.velocity_16);
}

test "AC-3: MIDI 1.0 CC in UMP" {
    // CC1 (mod wheel), value 64
    const w0 = build_midi1(0, 0xB, 0, 1, 64);
    const words = [_]u32{w0};
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(MidiVersion.midi1, msg.version);
    try std.testing.expectEqual(Status.control_change, msg.status);
    try std.testing.expectEqual(@as(u7, 1), msg.controller);
    // 7-bit CC scaled to 32-bit: 64 << 25
    try std.testing.expectEqual(@as(u32, 64 << 25), msg.value_32);
}

test "AC-3: MIDI 1.0 Pitch Bend in UMP" {
    // Pitch bend center: LSB=0, MSB=64 → 14-bit value 8192
    const w0 = build_midi1(0, 0xE, 0, 0, 64);
    const words = [_]u32{w0};
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(Status.pitch_bend, msg.status);
    // 14-bit center (8192) scaled to 32-bit
    const pb14: u14 = 64 << 7 | 0;
    try std.testing.expectEqual(@as(u32, @as(u32, pb14) << 18), msg.value_32);
}

test "AC-4: Per-Note Controller parsed correctly" {
    // MIDI 2.0 Poly Pressure (per-note)
    const w0: u32 = @as(u32, 0x4) << 28 | // Type 4
        @as(u32, 0xA) << 20 | // Poly Pressure
        @as(u32, 60) << 8; // Note 60
    const w1: u32 = 0x80000000; // 50% pressure
    const words = [_]u32{ w0, w1 };
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(Status.poly_pressure, msg.status);
    try std.testing.expectEqual(@as(u7, 60), msg.note);
    try std.testing.expectEqual(@as(u32, 0x80000000), msg.value_32);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), value32_to_float(msg.value_32), 0.01);
}

test "AC-4: MIDI 2.0 CC with 32-bit value" {
    const words = build_midi2_cc(0, 0, 74, 0xDEADBEEF);
    const msg = try parse_ump(&words);

    try std.testing.expectEqual(Status.control_change, msg.status);
    try std.testing.expectEqual(@as(u7, 74), msg.controller);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), msg.value_32);
}

test "AC-N1: invalid UMP type returns error" {
    // Type 0 (Utility) — not supported
    const w0: u32 = @as(u32, 0x0) << 28;
    const words = [_]u32{w0};
    try std.testing.expectError(error.UnsupportedType, parse_ump(&words));

    // Type 3 (Data/SysEx) — not supported
    const w1: u32 = @as(u32, 0x3) << 28;
    const words2 = [_]u32{w1};
    try std.testing.expectError(error.UnsupportedType, parse_ump(&words2));

    // Type 4 with only 1 word — insufficient data
    const w2: u32 = @as(u32, 0x4) << 28;
    const words3 = [_]u32{w2};
    try std.testing.expectError(error.UnsupportedType, parse_ump(&words3));

    // Empty
    try std.testing.expectError(error.UnsupportedType, parse_ump(&[_]u32{}));
}

// ── Benchmarks ───────────────────────────────────────────────────────

test "benchmark: MIDI 2.0 UMP parse" {
    const words = build_midi2_note_on(0, 0, 60, 0xC000, 0);

    // Warmup
    for (0..1000) |_| std.mem.doNotOptimizeAway(parse_ump(&words) catch unreachable);

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            std.mem.doNotOptimizeAway(parse_ump(&words) catch unreachable);
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    const threshold = if (@import("builtin").mode == .Debug) 5000.0 else 200.0;

    std.debug.print("\n  [WP-133] MIDI 2.0 UMP parse — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/event\n", .{per_op});
    std.debug.print("    Threshold: < {d:.0}ns\n", .{threshold});

    try std.testing.expect(per_op < threshold);
}

test "benchmark: 32-bit CC resolution" {
    const words = build_midi2_cc(0, 0, 74, 0x80000000);

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            const msg = parse_ump(&words) catch unreachable;
            std.mem.doNotOptimizeAway(value32_to_float(msg.value_32));
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    const threshold = if (@import("builtin").mode == .Debug) 5000.0 else 100.0;

    std.debug.print("\n  [WP-133] 32-bit CC → f32 — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/event\n", .{per_op});
    std.debug.print("    Threshold: < {d:.0}ns\n", .{threshold});

    try std.testing.expect(per_op < threshold);
}

test "benchmark: 256 UMP burst" {
    var ump_buf: [512]u32 = undefined;
    for (0..256) |i| {
        const w = build_midi2_note_on(0, 0, @intCast(i % 128), @intCast(i * 256), 0);
        ump_buf[i * 2] = w[0];
        ump_buf[i * 2 + 1] = w[1];
    }

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var sum: f32 = 0;
        var timer = try std.time.Timer.start();
        for (0..256) |i| {
            const words = ump_buf[i * 2 ..][0..2];
            const msg = parse_ump(words) catch unreachable;
            sum += velocity16_to_float(msg.velocity_16);
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));

    const threshold = if (@import("builtin").mode == .Debug) 500000.0 else 20000.0;

    std.debug.print("\n  [WP-133] 256 UMP burst — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.0}ns total, {d:.1}ns/event\n", .{ median_ns, median_ns / 256.0 });
    std.debug.print("    Threshold: < {d:.0}ns total\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: MIDI 1.0 compat (Type 2)" {
    const w0 = build_midi1(0, 0x9, 0, 60, 100);
    const words = [_]u32{w0};

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            std.mem.doNotOptimizeAway(parse_ump(&words) catch unreachable);
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    const threshold = if (@import("builtin").mode == .Debug) 5000.0 else 200.0;

    std.debug.print("\n  [WP-133] MIDI 1.0 compat parse — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/event\n", .{per_op});
    std.debug.print("    Threshold: < {d:.0}ns (same as MIDI 2.0)\n", .{threshold});

    try std.testing.expect(per_op < threshold);
}
