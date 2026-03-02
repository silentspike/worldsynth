const std = @import("std");

// ── Noise PRNG (WP-015) ─────────────────────────────────────────────
// xorshift32 — minimal, fast, deterministic PRNG for white noise.
// State is stored in the voice's phase variable (bitcast f32 <-> u32).
// Period: 2^32 - 1. Zero-state guard ensures non-degenerate output.

/// xorshift32 step. Produces next pseudo-random u32.
/// Must not be called with state = 0 (guard in noise_block).
pub inline fn xorshift32(state: u32) u32 {
    var s = state;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

/// Convert u32 PRNG state to f32 in [-1, 1].
/// Maps full u32 range uniformly: u32 / 2^31 - 1.
pub inline fn u32_to_f32(val: u32) f32 {
    return @as(f32, @floatFromInt(@as(i32, @bitCast(val)))) * (1.0 / 2147483648.0);
}

/// Process a block of noise samples. State is stored as u32 in the phase f32.
/// If state is 0 (e.g. from phase=0.0), it is seeded with a fixed non-zero value.
pub fn noise_block(phase_ptr: *f32, out_buf: *[128]f32) void {
    var state: u32 = @bitCast(phase_ptr.*);
    // Guard: xorshift32 degenerates to 0 with zero state
    if (state == 0) state = 0x12345678;
    for (out_buf) |*sample| {
        state = xorshift32(state);
        sample.* = u32_to_f32(state);
    }
    phase_ptr.* = @bitCast(state);
}

// ── Tests ────────────────────────────────────────────────────────────

test "xorshift32 produces non-zero sequence" {
    var state: u32 = 1;
    for (0..1000) |_| {
        state = xorshift32(state);
        try std.testing.expect(state != 0);
    }
}

test "xorshift32 period check (no immediate cycle)" {
    var state: u32 = 42;
    const initial = state;
    var found_cycle = false;
    for (0..10000) |_| {
        state = xorshift32(state);
        if (state == initial) {
            found_cycle = true;
            break;
        }
    }
    try std.testing.expect(!found_cycle);
}

test "u32_to_f32 range [-1, 1]" {
    // Test boundary values
    try std.testing.expect(u32_to_f32(0) >= -1.0 and u32_to_f32(0) <= 1.0);
    try std.testing.expect(u32_to_f32(0x7FFFFFFF) >= -1.0 and u32_to_f32(0x7FFFFFFF) <= 1.0);
    try std.testing.expect(u32_to_f32(0x80000000) >= -1.0 and u32_to_f32(0x80000000) <= 1.0);
    try std.testing.expect(u32_to_f32(0xFFFFFFFF) >= -1.0 and u32_to_f32(0xFFFFFFFF) <= 1.0);
}

test "noise_block produces varying output" {
    var phase: f32 = 0.0;
    var buf: [128]f32 = undefined;
    noise_block(&phase, &buf);

    var all_same = true;
    for (buf[1..]) |sample| {
        if (sample != buf[0]) {
            all_same = false;
            break;
        }
    }
    try std.testing.expect(!all_same);
}

test "noise_block output bounded [-1, 1]" {
    var phase: f32 = 0.0;
    var buf: [128]f32 = undefined;
    for (0..100) |_| {
        noise_block(&phase, &buf);
        for (buf) |sample| {
            try std.testing.expect(sample >= -1.0 and sample <= 1.0);
            try std.testing.expect(!std.math.isNan(sample));
            try std.testing.expect(!std.math.isInf(sample));
        }
    }
}

test "noise_block deterministic (same seed = same output)" {
    var phase1: f32 = 0.0;
    var phase2: f32 = 0.0;
    var buf1: [128]f32 = undefined;
    var buf2: [128]f32 = undefined;
    noise_block(&phase1, &buf1);
    noise_block(&phase2, &buf2);
    for (buf1, buf2) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "noise_block zero-state guard" {
    // phase=0.0 bitcasts to u32(0) — must not degenerate
    var phase: f32 = @bitCast(@as(u32, 0));
    var buf: [128]f32 = undefined;
    noise_block(&phase, &buf);
    // State must have advanced (not stuck at 0)
    try std.testing.expect(@as(u32, @bitCast(phase)) != 0);
    // Output must vary
    var has_nonzero = false;
    for (buf) |s| {
        if (s != 0.0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}
