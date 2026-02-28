const std = @import("std");

// ── Sine Look-Up Table (comptime, 2048 entries) ───────────────────────
pub const SINE_LUT_SIZE: usize = 2048;

pub const SINE_LUT: [SINE_LUT_SIZE]f32 = blk: {
    @setEvalBranchQuota(SINE_LUT_SIZE * 4);
    var table: [SINE_LUT_SIZE]f32 = undefined;
    var i: usize = 0;
    while (i < SINE_LUT_SIZE) : (i += 1) {
        const phase: f64 = @as(f64, @floatFromInt(i)) / @as(f64, SINE_LUT_SIZE);
        table[i] = @floatCast(@sin(phase * 2.0 * std.math.pi));
    }
    break :blk table;
};

/// Fast sine lookup with linear interpolation.
/// `phase` must be in [0.0, 1.0).
pub inline fn sine_fast(phase: f32) f32 {
    const wrapped = phase - @floor(phase);
    const idx_f = wrapped * @as(f32, SINE_LUT_SIZE);
    const idx: usize = @intFromFloat(idx_f);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    const cur = idx % SINE_LUT_SIZE;
    const next = (idx + 1) % SINE_LUT_SIZE;
    return SINE_LUT[cur] + frac * (SINE_LUT[next] - SINE_LUT[cur]);
}

// ── MIDI Note to Frequency Table (comptime, 128 entries) ──────────────
pub const MIDI_FREQ: [128]f32 = blk: {
    var table: [128]f32 = undefined;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        table[i] = @floatCast(440.0 * @exp2((@as(f64, @floatFromInt(i)) - 69.0) / 12.0));
    }
    break :blk table;
};

// ── Tests ─────────────────────────────────────────────────────────────
test "sine_fast(0.25) approximates 1.0" {
    const result = sine_fast(0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 1e-4);
}

test "MIDI_FREQ[69] approximates 440.0" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), MIDI_FREQ[69], 0.01);
}

test "SINE_LUT[0] approximates 0.0" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), SINE_LUT[0], 1e-6);
}

test "all 2048 LUT entries in range [-1.0, 1.0]" {
    for (SINE_LUT) |val| {
        try std.testing.expect(val >= -1.0 and val <= 1.0);
    }
}

test "sine_fast wraps phase correctly" {
    const a = sine_fast(0.0);
    const b = sine_fast(1.0);
    try std.testing.expectApproxEqAbs(a, b, 1e-4);
}

test "MIDI_FREQ covers expected range" {
    // MIDI 0 = ~8.18 Hz, MIDI 127 = ~12543 Hz
    try std.testing.expect(MIDI_FREQ[0] > 8.0 and MIDI_FREQ[0] < 8.5);
    try std.testing.expect(MIDI_FREQ[127] > 12500.0 and MIDI_FREQ[127] < 12600.0);
}

test "MIDI_FREQ octave relationship" {
    // Note 69 (A4) = 440 Hz, Note 81 (A5) = 880 Hz
    const ratio = MIDI_FREQ[81] / MIDI_FREQ[69];
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), ratio, 0.01);
}
