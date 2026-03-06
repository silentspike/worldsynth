const std = @import("std");

// ── MIDI-Learn + Launchkey InControl (WP-132) ────────────────────────
// CC→Parameter mapping with learn mode and Novation Launchkey 61 support.
// IO-Thread only — no heap allocation, no blocking.
//
// Usage:
//   var ml = MidiLearn{};
//   ml.start_learn(42);          // enter learn mode for param 42
//   _ = ml.process_cc(1, 100);   // CC1 → assigned to param 42, returns {42, 0.787}
//   _ = ml.process_cc(1, 64);    // CC1 → dispatches to param 42, returns {42, 0.504}
//   _ = ml.process_cc(2, 64);    // CC2 → unmapped, returns null

pub const ParamId = u32;

const cc_normalized_lut: [128]f32 = blk: {
    var lut: [128]f32 = undefined;
    for (0..lut.len) |i| {
        lut[i] = @as(f32, @floatFromInt(i)) / 127.0;
    }
    break :blk lut;
};

pub const CcEvent = struct {
    param_id: ParamId,
    normalized: f32, // 0.0..1.0
};

pub const MidiLearn = struct {
    cc_map: [128]?ParamId = [_]?ParamId{null} ** 128,
    learn_mode: bool = false,
    target_param: ?ParamId = null,

    /// Enter learn mode: next CC message will be assigned to param_id.
    pub fn start_learn(self: *MidiLearn, param_id: ParamId) void {
        self.learn_mode = true;
        self.target_param = param_id;
    }

    /// Cancel learn mode without assigning.
    pub fn cancel_learn(self: *MidiLearn) void {
        self.learn_mode = false;
        self.target_param = null;
    }

    /// Process incoming CC message.
    /// In learn mode: assigns CC to target parameter, exits learn mode.
    /// Otherwise: dispatches CC value to mapped parameter.
    /// Returns null if CC is unmapped (and not in learn mode).
    pub fn process_cc(self: *MidiLearn, cc: u7, value: u7) ?CcEvent {
        if (!self.learn_mode) {
            const pid = self.cc_map[cc] orelse return null;
            return .{
                .param_id = pid,
                .normalized = normalize_cc(value),
            };
        }

        if (self.target_param) |pid| {
            self.cc_map[cc] = pid;
            self.learn_mode = false;
            self.target_param = null;
            return .{
                .param_id = pid,
                .normalized = normalize_cc(value),
            };
        }

        return null;
    }

    /// Remove mapping for a CC number.
    pub fn unmap(self: *MidiLearn, cc: u7) void {
        self.cc_map[cc] = null;
    }

    /// Remove all mappings.
    pub fn clear_all(self: *MidiLearn) void {
        self.cc_map = [_]?ParamId{null} ** 128;
        self.learn_mode = false;
        self.target_param = null;
    }

    /// Count active mappings.
    pub fn mapped_count(self: *const MidiLearn) u8 {
        var count: u8 = 0;
        for (self.cc_map) |entry| {
            if (entry != null) count += 1;
        }
        return count;
    }
};

/// Normalize CC value (0–127) to float (0.0–1.0).
pub fn normalize_cc(value: u7) f32 {
    return cc_normalized_lut[value];
}

// ── Launchkey InControl Protocol ─────────────────────────────────────
// Novation Launchkey 61 uses SysEx messages for InControl mode.
// InControl gives the DAW direct control over knobs, faders, pads, and LEDs.

pub const Launchkey = struct {
    /// SysEx to enable InControl mode on Launchkey 61 MK2.
    /// F0 00 20 29 02 0F 40 F7
    pub const incontrol_on: [8]u8 = .{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0F, 0x40, 0xF7 };

    /// SysEx to disable InControl mode (return to standard MIDI).
    /// F0 00 20 29 02 0F 00 F7
    pub const incontrol_off: [8]u8 = .{ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x0F, 0x00, 0xF7 };

    /// Launchkey 61 MK2 default knob CC numbers (InControl mode).
    /// 8 rotary encoders on top row.
    pub const knob_ccs: [8]u7 = .{ 21, 22, 23, 24, 25, 26, 27, 28 };

    /// Build LED feedback message for a knob (CC on channel 16).
    /// Launchkey uses Note On on channel 16 for LED color control.
    /// Returns 3-byte MIDI message: [status, note, velocity].
    pub fn led_feedback(knob_idx: u3, value: u7) [3]u8 {
        // Channel 16 Note On (0x9F), knob note numbers start at 0x15
        return .{ 0x9F, @as(u8, knob_idx) + 0x15, value };
    }

    /// Auto-map 8 Launchkey knobs to consecutive parameter IDs.
    pub fn auto_map_knobs(ml: *MidiLearn, start_param_id: ParamId) void {
        for (knob_ccs, 0..) |cc, i| {
            ml.cc_map[cc] = start_param_id + @as(u32, @intCast(i));
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: learn mode assigns CC1 to filter cutoff (param 42)" {
    var ml = MidiLearn{};

    // Enter learn mode for param 42 (filter cutoff)
    ml.start_learn(42);
    try std.testing.expect(ml.learn_mode);
    try std.testing.expectEqual(@as(?ParamId, 42), ml.target_param);

    // Send CC1 → should assign CC1 to param 42
    const result = ml.process_cc(1, 100);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(ParamId, 42), result.?.param_id);

    // Learn mode should be off now
    try std.testing.expect(!ml.learn_mode);
    try std.testing.expectEqual(@as(?ParamId, null), ml.target_param);

    // CC1 should be mapped to param 42
    try std.testing.expectEqual(@as(?ParamId, 42), ml.cc_map[1]);
}

test "AC-2: after learn, CC1 changes filter cutoff" {
    var ml = MidiLearn{};

    // Assign CC1 to param 42
    ml.start_learn(42);
    _ = ml.process_cc(1, 0);

    // Now send CC1 with value 100 → should dispatch to param 42
    const result = ml.process_cc(1, 100);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(ParamId, 42), result.?.param_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.787), result.?.normalized, 0.01);

    // Send CC1 with value 64 → midpoint
    const mid = ml.process_cc(1, 64);
    try std.testing.expect(mid != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.504), mid.?.normalized, 0.01);
}

test "AC-3: CC value 0-127 correctly normalized to 0.0-1.0" {
    try std.testing.expectEqual(@as(f32, 0.0), normalize_cc(0));
    try std.testing.expectEqual(@as(f32, 1.0), normalize_cc(127));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normalize_cc(64), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), normalize_cc(32), 0.01);

    // Verify full range is monotonic
    var prev: f32 = -1.0;
    for (0..128) |i| {
        const val = normalize_cc(@intCast(i));
        try std.testing.expect(val > prev);
        try std.testing.expect(val >= 0.0 and val <= 1.0);
        prev = val;
    }
}

test "AC-4: multiple CCs mapped simultaneously" {
    var ml = MidiLearn{};

    // Map CC1 → param 10 (cutoff)
    ml.start_learn(10);
    _ = ml.process_cc(1, 0);

    // Map CC7 → param 20 (volume)
    ml.start_learn(20);
    _ = ml.process_cc(7, 0);

    // Map CC74 → param 30 (resonance)
    ml.start_learn(30);
    _ = ml.process_cc(74, 0);

    try std.testing.expectEqual(@as(u8, 3), ml.mapped_count());

    // All three dispatch correctly
    const r1 = ml.process_cc(1, 127);
    try std.testing.expectEqual(@as(ParamId, 10), r1.?.param_id);
    try std.testing.expectEqual(@as(f32, 1.0), r1.?.normalized);

    const r7 = ml.process_cc(7, 64);
    try std.testing.expectEqual(@as(ParamId, 20), r7.?.param_id);

    const r74 = ml.process_cc(74, 0);
    try std.testing.expectEqual(@as(ParamId, 30), r74.?.param_id);
    try std.testing.expectEqual(@as(f32, 0.0), r74.?.normalized);
}

test "AC-N1: unmapped CC returns null, no crash" {
    var ml = MidiLearn{};

    // No mappings — all CCs return null
    for (0..128) |cc| {
        try std.testing.expectEqual(@as(?CcEvent, null), ml.process_cc(@intCast(cc), 64));
    }
}

test "cancel_learn exits without mapping" {
    var ml = MidiLearn{};
    ml.start_learn(42);
    try std.testing.expect(ml.learn_mode);

    ml.cancel_learn();
    try std.testing.expect(!ml.learn_mode);
    try std.testing.expectEqual(@as(?ParamId, null), ml.target_param);

    // CC1 should still be unmapped
    try std.testing.expectEqual(@as(?CcEvent, null), ml.process_cc(1, 64));
}

test "unmap removes single mapping" {
    var ml = MidiLearn{};
    ml.start_learn(42);
    _ = ml.process_cc(1, 0);

    try std.testing.expectEqual(@as(?ParamId, 42), ml.cc_map[1]);
    ml.unmap(1);
    try std.testing.expectEqual(@as(?ParamId, null), ml.cc_map[1]);
    try std.testing.expectEqual(@as(?CcEvent, null), ml.process_cc(1, 64));
}

test "clear_all removes all mappings" {
    var ml = MidiLearn{};
    ml.start_learn(10);
    _ = ml.process_cc(1, 0);
    ml.start_learn(20);
    _ = ml.process_cc(7, 0);

    try std.testing.expectEqual(@as(u8, 2), ml.mapped_count());
    ml.clear_all();
    try std.testing.expectEqual(@as(u8, 0), ml.mapped_count());
}

test "Launchkey InControl SysEx format" {
    // Verify InControl on message matches Novation spec
    try std.testing.expectEqual(@as(u8, 0xF0), Launchkey.incontrol_on[0]); // SysEx start
    try std.testing.expectEqual(@as(u8, 0x00), Launchkey.incontrol_on[1]); // Novation manufacturer
    try std.testing.expectEqual(@as(u8, 0x20), Launchkey.incontrol_on[2]);
    try std.testing.expectEqual(@as(u8, 0x29), Launchkey.incontrol_on[3]);
    try std.testing.expectEqual(@as(u8, 0x40), Launchkey.incontrol_on[6]); // InControl ON
    try std.testing.expectEqual(@as(u8, 0xF7), Launchkey.incontrol_on[7]); // SysEx end

    try std.testing.expectEqual(@as(u8, 0x00), Launchkey.incontrol_off[6]); // InControl OFF
}

test "Launchkey LED feedback message format" {
    const msg = Launchkey.led_feedback(0, 127);
    try std.testing.expectEqual(@as(u8, 0x9F), msg[0]); // Note On, channel 16
    try std.testing.expectEqual(@as(u8, 0x15), msg[1]); // knob 0 note
    try std.testing.expectEqual(@as(u8, 127), msg[2]); // velocity/color

    const msg2 = Launchkey.led_feedback(7, 0);
    try std.testing.expectEqual(@as(u8, 0x9F), msg2[0]);
    try std.testing.expectEqual(@as(u8, 0x1C), msg2[1]); // knob 7 note (0x15 + 7)
    try std.testing.expectEqual(@as(u8, 0), msg2[2]);
}

test "Launchkey auto_map_knobs maps 8 consecutive params" {
    var ml = MidiLearn{};
    Launchkey.auto_map_knobs(&ml, 100);

    // 8 knobs mapped to params 100..107
    try std.testing.expectEqual(@as(u8, 8), ml.mapped_count());
    for (Launchkey.knob_ccs, 0..) |cc, i| {
        try std.testing.expectEqual(@as(?ParamId, 100 + @as(u32, @intCast(i))), ml.cc_map[cc]);
    }

    // Dispatch through knob 0 (CC21) → param 100
    const r = ml.process_cc(Launchkey.knob_ccs[0], 64);
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(ParamId, 100), r.?.param_id);
}

test "reassign: learning same CC overwrites previous mapping" {
    var ml = MidiLearn{};

    // Map CC1 → param 10
    ml.start_learn(10);
    _ = ml.process_cc(1, 0);
    try std.testing.expectEqual(@as(?ParamId, 10), ml.cc_map[1]);

    // Remap CC1 → param 20
    ml.start_learn(20);
    _ = ml.process_cc(1, 0);
    try std.testing.expectEqual(@as(?ParamId, 20), ml.cc_map[1]);
    try std.testing.expectEqual(@as(u8, 1), ml.mapped_count());
}

// ── Benchmarks ───────────────────────────────────────────────────────

test "benchmark: MIDI-Learn start" {
    var ml = MidiLearn{};

    // Warmup
    for (0..1000) |i| ml.start_learn(@intCast(i % 1024));

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |i| {
            ml.start_learn(@intCast(i % 1024));
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&ml);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    std.debug.print("\n  [WP-132] MIDI-Learn start — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/op\n", .{per_op});
    std.debug.print("    Threshold: < 1000ns\n", .{});

    try std.testing.expect(per_op < 1000.0);
}

test "benchmark: CC assign (learn mode)" {
    var ml = MidiLearn{};

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var timer = try std.time.Timer.start();
        for (0..iters) |i| {
            ml.start_learn(@intCast(i % 1024));
            std.mem.doNotOptimizeAway(ml.process_cc(@intCast(i % 128), 64));
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    std.debug.print("\n  [WP-132] CC assign (learn) — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/op\n", .{per_op});
    std.debug.print("    Threshold: < 500ns\n", .{});

    try std.testing.expect(per_op < 500.0);
}

test "benchmark: CC dispatch (hot path)" {
    var ml = MidiLearn{};
    // Pre-map all 128 CCs
    for (0..128) |cc| ml.cc_map[cc] = @intCast(cc);

    // Warmup
    for (0..1000) |i| _ = ml.process_cc(@intCast(i % 128), 64);

    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var checksum: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..iters) |i| {
            const event = ml.process_cc(@intCast(i % 128), @intCast(i % 128)).?;
            checksum +%= event.param_id;
            checksum +%= @as(u64, @intFromFloat(event.normalized * 127.0));
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(checksum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    std.debug.print("\n  [WP-132] CC dispatch (hot path) — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/op\n", .{per_op});
    std.debug.print("    Threshold: < 200ns\n", .{});

    try std.testing.expect(per_op < 200.0);
}

test "benchmark: Launchkey InControl init" {
    // InControl activation is just reading a const SysEx array — effectively free.
    // Measure access time to verify no hidden cost.
    const runs = 5;
    const iters = 100_000;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var sum: u32 = 0;
        var timer = try std.time.Timer.start();
        for (0..iters) |_| {
            sum +%= Launchkey.incontrol_on[6];
            sum +%= Launchkey.led_feedback(3, 64)[2];
        }
        t.* = timer.read();
        std.mem.doNotOptimizeAway(&sum);
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_op = median_ns / @as(f64, iters);

    std.debug.print("\n  [WP-132] Launchkey InControl init — {d} ops, {d} Runs\n", .{ iters, runs });
    std.debug.print("    median: {d:.1}ns/op\n", .{per_op});
    std.debug.print("    Threshold: < 100ms (trivial — const SysEx)\n", .{});

    // Far under 100ms — this is nanoseconds
    try std.testing.expect(per_op < 1000.0);
}
