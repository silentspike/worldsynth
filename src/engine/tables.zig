const std = @import("std");

// ── Sine Look-Up Table (comptime, 2048 entries) ───────────────────────
pub const SINE_LUT_SIZE: usize = 2048;
const SINE_LUT_MASK: usize = SINE_LUT_SIZE - 1;

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

// Pre-computed delta table: SINE_DELTA[i] = SINE_LUT[(i+1) & mask] - SINE_LUT[i]
// Saves one table load + one subtraction per interpolated lookup.
const SINE_DELTA: [SINE_LUT_SIZE]f32 = blk: {
    @setEvalBranchQuota(SINE_LUT_SIZE * 4);
    var table: [SINE_LUT_SIZE]f32 = undefined;
    var i: usize = 0;
    while (i < SINE_LUT_SIZE) : (i += 1) {
        table[i] = SINE_LUT[(i + 1) & SINE_LUT_MASK] - SINE_LUT[i];
    }
    break :blk table;
};

/// Fast sine lookup with linear interpolation.
/// `phase` is wrapped to [0.0, 1.0) internally, any input value is valid.
pub inline fn sine_fast(phase: f32) f32 {
    const wrapped = phase - @floor(phase);
    const idx_f = wrapped * @as(f32, SINE_LUT_SIZE);
    const idx: usize = @intFromFloat(idx_f);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    const i = idx & SINE_LUT_MASK;
    return SINE_LUT[i] + frac * SINE_DELTA[i];
}

/// Optimized sine lookup for hot audio paths. Phase MUST be in [0.0, 1.0).
/// Skips @floor wrapping — caller is responsible for phase management.
pub inline fn sine_lookup(phase: f32) f32 {
    const idx_f = phase * @as(f32, SINE_LUT_SIZE);
    const idx: usize = @intFromFloat(idx_f);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    const i = idx & SINE_LUT_MASK;
    return SINE_LUT[i] + frac * SINE_DELTA[i];
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

test "sine_lookup matches sine_fast for phases in [0, 1)" {
    const phases = [_]f32{ 0.0, 0.125, 0.25, 0.5, 0.75, 0.999 };
    for (phases) |p| {
        try std.testing.expectApproxEqAbs(sine_fast(p), sine_lookup(p), 1e-6);
    }
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
