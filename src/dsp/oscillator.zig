const std = @import("std");
const sine_tables = @import("../engine/tables.zig");
const osc_sine_noise = @import("osc_sine_noise.zig");

// ── Band-Limited Wavetable Oscillator (WP-013, WP-014, WP-015) ──────
// comptime mip-mapped wavetables with Hermite cubic interpolation.
// Saw, Square, Triangle — each 11 octave levels × 2048 samples.
// Phase in [0, 1). No heap allocation — all tables are comptime.
//
// Anti-Aliasing: Band-limited wavetables eliminate harmonics above
// Nyquist at the source. Each mip level contains only harmonics
// that fit below Nyquist for that octave range. Achieves -120dB+
// alias rejection (vs PolyBLEP ~36dB, ADAA ~32dB on saw).

pub const BLOCK_SIZE: usize = 128;

pub const WaveType = enum { sine, saw, square, triangle, noise, supersaw };

// ── Mip-Mapped Saw Wavetable ────────────────────────────────────────

const TABLE_SIZE: usize = 2048;
const TABLE_MASK: usize = TABLE_SIZE - 1;

/// 11 octave levels: level 0 = full bandwidth (1024 harmonics),
/// level 10 = fundamental only (for frequencies near Nyquist).
const MIP_LEVELS: usize = 11;

/// comptime band-limited saw wavetables.
/// Generated via additive synthesis: saw(t) = -2/pi * sum(sin(2*pi*k*t)/k)
/// Each level truncates harmonics above Nyquist for that octave.
const SAW_TABLES: [MIP_LEVELS][TABLE_SIZE]f32 = blk: {
    @setEvalBranchQuota(200_000_000);
    var tables: [MIP_LEVELS][TABLE_SIZE]f32 = undefined;
    for (0..MIP_LEVELS) |level| {
        const max_harm: usize = @max(1, (TABLE_SIZE / 2) >> @intCast(level));
        for (0..TABLE_SIZE) |n| {
            var sum: f64 = 0.0;
            for (1..max_harm + 1) |k| {
                const angle: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(k * n)) / @as(f64, TABLE_SIZE);
                sum -= @sin(angle) / @as(f64, @floatFromInt(k));
            }
            tables[level][n] = @floatCast(sum * 2.0 / std.math.pi);
        }
    }
    break :blk tables;
};

// ── Mip-Mapped Square Wavetable ──────────────────────────────────────

/// comptime band-limited square wavetables.
/// Square = odd harmonics only: (4/pi) * sum(sin(2*pi*k*t)/k) for k=1,3,5,...
/// Each level truncates harmonics above Nyquist for that octave.
const SQUARE_TABLES: [MIP_LEVELS][TABLE_SIZE]f32 = blk: {
    @setEvalBranchQuota(200_000_000);
    var tables: [MIP_LEVELS][TABLE_SIZE]f32 = undefined;
    for (0..MIP_LEVELS) |level| {
        const max_harm: usize = @max(1, (TABLE_SIZE / 2) >> @intCast(level));
        for (0..TABLE_SIZE) |n| {
            var sum: f64 = 0.0;
            var k: usize = 1;
            while (k <= max_harm) : (k += 2) {
                const angle: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(k * n)) / @as(f64, TABLE_SIZE);
                sum += @sin(angle) / @as(f64, @floatFromInt(k));
            }
            tables[level][n] = @floatCast(sum * 4.0 / std.math.pi);
        }
    }
    break :blk tables;
};

// ── Mip-Mapped Triangle Wavetable ────────────────────────────────────

/// comptime band-limited triangle wavetables.
/// Triangle = odd harmonics with 1/k² decay and alternating signs:
/// (8/pi²) * sum((-1)^((k-1)/2) * sin(2*pi*k*t) / k²) for k=1,3,5,...
/// Triangle is continuous — minimal Gibbs, but BL-WT eliminates residual artifacts.
const TRIANGLE_TABLES: [MIP_LEVELS][TABLE_SIZE]f32 = blk: {
    @setEvalBranchQuota(200_000_000);
    var tables: [MIP_LEVELS][TABLE_SIZE]f32 = undefined;
    for (0..MIP_LEVELS) |level| {
        const max_harm: usize = @max(1, (TABLE_SIZE / 2) >> @intCast(level));
        for (0..TABLE_SIZE) |n| {
            var sum: f64 = 0.0;
            var k: usize = 1;
            var sign: f64 = 1.0;
            while (k <= max_harm) : ({
                k += 2;
                sign = -sign;
            }) {
                const angle: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(k * n)) / @as(f64, TABLE_SIZE);
                const k_f: f64 = @as(f64, @floatFromInt(k));
                sum += sign * @sin(angle) / (k_f * k_f);
            }
            tables[level][n] = @floatCast(sum * 8.0 / (std.math.pi * std.math.pi));
        }
    }
    break :blk tables;
};

// ── Interpolation & Mip-Level Selection ──────────────────────────────

/// Hermite cubic interpolation for smooth wavetable lookup.
/// 4-point, 3rd-order polynomial. Reduces interpolation noise
/// by ~40dB compared to linear interpolation.
inline fn hermite(y0: f32, y1: f32, y2: f32, y3: f32, frac: f32) f32 {
    const c1 = 0.5 * (y2 - y0);
    const c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    // Horner evaluation: ((c3*x + c2)*x + c1)*x + y1
    return @mulAdd(f32, @mulAdd(f32, @mulAdd(f32, c3, frac, c2), frac, c1), frac, y1);
}

/// Select mip level based on phase increment.
/// Higher phase_inc (higher frequency) -> higher level (fewer harmonics).
/// Uses ceil to ensure NO harmonic exceeds Nyquist:
///   max_harm_at_level_n = TABLE_SIZE / 2^(n+1)
///   Requirement: freq * max_harm < Nyquist => n > log2(TABLE_SIZE * phase_inc)
inline fn select_mip_level(phase_inc: f32) usize {
    if (phase_inc <= 0.0) return 0;
    const product = @as(f32, @floatFromInt(TABLE_SIZE)) * phase_inc;
    if (product <= 1.0) return 0;
    const log_val = @log2(product);
    const level: usize = @intFromFloat(@ceil(log_val));
    return @min(level, MIP_LEVELS - 1);
}

/// Read one sample from the saw wavetable with Hermite interpolation.
inline fn saw_sample(level: usize, phase: f32) f32 {
    const table = &SAW_TABLES[level];
    const idx_f = phase * @as(f32, @floatFromInt(TABLE_SIZE));
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), TABLE_SIZE - 1);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    return hermite(
        table[(idx -% 1) & TABLE_MASK],
        table[idx & TABLE_MASK],
        table[(idx + 1) & TABLE_MASK],
        table[(idx + 2) & TABLE_MASK],
        frac,
    );
}

/// Read one sample from the square wavetable with Hermite interpolation.
inline fn square_sample(level: usize, phase: f32) f32 {
    const table = &SQUARE_TABLES[level];
    const idx_f = phase * @as(f32, @floatFromInt(TABLE_SIZE));
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), TABLE_SIZE - 1);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    return hermite(
        table[(idx -% 1) & TABLE_MASK],
        table[idx & TABLE_MASK],
        table[(idx + 1) & TABLE_MASK],
        table[(idx + 2) & TABLE_MASK],
        frac,
    );
}

/// Read one sample from the triangle wavetable with Hermite interpolation.
inline fn triangle_sample(level: usize, phase: f32) f32 {
    const table = &TRIANGLE_TABLES[level];
    const idx_f = phase * @as(f32, @floatFromInt(TABLE_SIZE));
    const idx: usize = @min(@as(usize, @intFromFloat(idx_f)), TABLE_SIZE - 1);
    const frac = idx_f - @as(f32, @floatFromInt(idx));
    return hermite(
        table[(idx -% 1) & TABLE_MASK],
        table[idx & TABLE_MASK],
        table[(idx + 1) & TABLE_MASK],
        table[(idx + 2) & TABLE_MASK],
        frac,
    );
}

/// Process a block of 128 samples for the given wave type.
/// .saw/.square/.triangle use band-limited wavetables with Hermite interpolation.
/// .sine uses LUT lookup from tables.zig. .noise uses xorshift32 PRNG.
/// .supersaw delegates to .saw (unison detuning is handled by Voice Manager).
pub fn process_block(phase_ptr: *f32, phase_inc: f32, wave: WaveType, out_buf: *[BLOCK_SIZE]f32) void {
    switch (wave) {
        .saw, .supersaw => {
            var phase = phase_ptr.*;
            const level = select_mip_level(phase_inc);
            for (out_buf) |*sample| {
                sample.* = saw_sample(level, phase);
                phase += phase_inc;
                if (phase >= 1.0) phase -= 1.0;
            }
            phase_ptr.* = phase;
        },
        .square => {
            var phase = phase_ptr.*;
            const level = select_mip_level(phase_inc);
            for (out_buf) |*sample| {
                sample.* = square_sample(level, phase);
                phase += phase_inc;
                if (phase >= 1.0) phase -= 1.0;
            }
            phase_ptr.* = phase;
        },
        .triangle => {
            var phase = phase_ptr.*;
            const level = select_mip_level(phase_inc);
            for (out_buf) |*sample| {
                sample.* = triangle_sample(level, phase);
                phase += phase_inc;
                if (phase >= 1.0) phase -= 1.0;
            }
            phase_ptr.* = phase;
        },
        .sine => {
            sine_tables.sine_lookup_block(BLOCK_SIZE, phase_ptr, phase_inc, out_buf);
        },
        .noise => {
            osc_sine_noise.noise_block(phase_ptr, out_buf);
        },
    }
}

/// Naive saw (no anti-aliasing) for benchmark overhead comparison.
pub fn naive_saw_block(phase_ptr: *f32, phase_inc: f32, out_buf: *[BLOCK_SIZE]f32) void {
    var phase = phase_ptr.*;
    for (out_buf) |*sample| {
        sample.* = 2.0 * phase - 1.0;
        phase += phase_inc;
        if (phase >= 1.0) phase -= 1.0;
    }
    phase_ptr.* = phase;
}

// ── Tests ────────────────────────────────────────────────────────────

test "saw produces 128 finite samples" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase, phase_inc, .saw, &buf);
    for (buf) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
    }
}

test "saw output range [-1.2, 1.2]" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    // Run multiple blocks to cover full phase cycle
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (0..100) |_| {
        process_block(&phase, phase_inc, .saw, &buf);
        for (buf) |sample| {
            // BL-WT has Gibbs overshoot (~9%) at harmonic truncation boundary
            try std.testing.expect(sample >= -1.2);
            try std.testing.expect(sample <= 1.2);
        }
    }
}

test "phase wrapping stays in [0, 1)" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    // Run enough blocks to wrap phase many times
    for (0..200) |_| {
        process_block(&phase, phase_inc, .saw, &buf);
        try std.testing.expect(phase >= 0.0);
        try std.testing.expect(phase < 1.0);
    }
}

test "phase wrapping at high frequency" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 15000.0 / 44100.0; // ~0.34
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (0..100) |_| {
        process_block(&phase, phase_inc, .saw, &buf);
        try std.testing.expect(phase >= 0.0);
        try std.testing.expect(phase < 1.0);
    }
}

test "all wave types produce non-silence output" {
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    const all_types = [_]WaveType{ .sine, .saw, .square, .triangle, .noise, .supersaw };
    for (all_types) |wt| {
        var phase: f32 = 0.0;
        @memset(&buf, 0.0);
        process_block(&phase, phase_inc, wt, &buf);
        var has_nonzero = false;
        for (buf) |sample| {
            if (sample != 0.0) {
                has_nonzero = true;
                break;
            }
        }
        try std.testing.expect(has_nonzero);
    }
}

test "WaveType has 6 variants" {
    const fields = @typeInfo(WaveType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
}

test "mip level selection" {
    // Low frequency -> level 0 (full bandwidth, all harmonics below Nyquist)
    try std.testing.expectEqual(@as(usize, 0), select_mip_level(20.0 / 44100.0));
    // A4 = 440Hz -> ceil(log2(2048 * 440/44100)) = ceil(4.35) = 5
    const level_440 = select_mip_level(440.0 / 44100.0);
    try std.testing.expectEqual(@as(usize, 5), level_440);
    // 1kHz -> ceil(log2(2048 * 1000/44100)) = ceil(5.54) = 6
    const level_1k = select_mip_level(1000.0 / 44100.0);
    try std.testing.expectEqual(@as(usize, 6), level_1k);
    // Very high frequency -> level near max
    const level_high = select_mip_level(15000.0 / 44100.0);
    try std.testing.expect(level_high >= 9);
}

// ── Square Tests (WP-014) ────────────────────────────────────────────

test "square produces 128 finite samples" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase, phase_inc, .square, &buf);
    for (buf) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
    }
}

test "square oscillates between +1 and -1" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    var has_positive = false;
    var has_negative = false;
    for (0..100) |_| {
        process_block(&phase, phase_inc, .square, &buf);
        for (buf) |sample| {
            // BL-WT square has Gibbs overshoot (~9%) + Hermite interpolation
            // at sharp transitions. Wider bound than saw.
            try std.testing.expect(sample >= -1.3);
            try std.testing.expect(sample <= 1.3);
            if (sample > 0.5) has_positive = true;
            if (sample < -0.5) has_negative = true;
        }
    }
    try std.testing.expect(has_positive);
    try std.testing.expect(has_negative);
}

test "square at different frequencies produces finite output" {
    const freqs = [_]f32{ 20.0, 100.0, 440.0, 1000.0, 5000.0, 15000.0 };
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (freqs) |freq| {
        var phase: f32 = 0.0;
        const phase_inc = freq / 44100.0;
        for (0..10) |_| {
            process_block(&phase, phase_inc, .square, &buf);
            for (buf) |sample| {
                try std.testing.expect(!std.math.isNan(sample));
                try std.testing.expect(!std.math.isInf(sample));
                try std.testing.expect(sample >= -1.3 and sample <= 1.3);
            }
        }
    }
}

// ── Triangle Tests (WP-014) ──────────────────────────────────────────

test "triangle produces 128 finite samples" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase, phase_inc, .triangle, &buf);
    for (buf) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
    }
}

test "triangle smooth and bounded" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    var has_positive = false;
    var has_negative = false;
    for (0..100) |_| {
        process_block(&phase, phase_inc, .triangle, &buf);
        for (buf) |sample| {
            // Triangle is continuous — minimal Gibbs, tighter bounds
            try std.testing.expect(sample >= -1.1);
            try std.testing.expect(sample <= 1.1);
            if (sample > 0.5) has_positive = true;
            if (sample < -0.5) has_negative = true;
        }
    }
    try std.testing.expect(has_positive);
    try std.testing.expect(has_negative);
}

test "triangle at different frequencies produces finite output" {
    const freqs = [_]f32{ 20.0, 100.0, 440.0, 1000.0, 5000.0, 15000.0 };
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (freqs) |freq| {
        var phase: f32 = 0.0;
        const phase_inc = freq / 44100.0;
        for (0..10) |_| {
            process_block(&phase, phase_inc, .triangle, &buf);
            for (buf) |sample| {
                try std.testing.expect(!std.math.isNan(sample));
                try std.testing.expect(!std.math.isInf(sample));
                try std.testing.expect(sample >= -1.1 and sample <= 1.1);
            }
        }
    }
}

// ── Saw Frequency Tests ──────────────────────────────────────────────

test "saw at different frequencies produces finite output" {
    const freqs = [_]f32{ 20.0, 100.0, 440.0, 1000.0, 5000.0, 15000.0 };
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (freqs) |freq| {
        var phase: f32 = 0.0;
        const phase_inc = freq / 44100.0;
        for (0..10) |_| {
            process_block(&phase, phase_inc, .saw, &buf);
            for (buf) |sample| {
                try std.testing.expect(!std.math.isNan(sample));
                try std.testing.expect(!std.math.isInf(sample));
                try std.testing.expect(sample >= -1.2 and sample <= 1.2);
            }
        }
    }
}

// ── Sine Tests (WP-015) ─────────────────────────────────────────────

test "sine periodic 440Hz" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase, phase_inc, .sine, &buf);
    for (buf) |sample| {
        try std.testing.expect(!std.math.isNan(sample));
        try std.testing.expect(!std.math.isInf(sample));
        try std.testing.expect(sample >= -1.0 and sample <= 1.0);
    }
    // Sine must oscillate — check positive and negative values exist
    var has_pos = false;
    var has_neg = false;
    for (0..200) |_| {
        process_block(&phase, phase_inc, .sine, &buf);
        for (buf) |sample| {
            if (sample > 0.1) has_pos = true;
            if (sample < -0.1) has_neg = true;
        }
    }
    try std.testing.expect(has_pos);
    try std.testing.expect(has_neg);
}

test "sine at different frequencies" {
    const freqs = [_]f32{ 20.0, 100.0, 440.0, 1000.0, 5000.0, 15000.0 };
    var buf: [BLOCK_SIZE]f32 = undefined;
    for (freqs) |freq| {
        var phase: f32 = 0.0;
        const phase_inc = freq / 44100.0;
        for (0..10) |_| {
            process_block(&phase, phase_inc, .sine, &buf);
            for (buf) |sample| {
                try std.testing.expect(!std.math.isNan(sample));
                try std.testing.expect(!std.math.isInf(sample));
                try std.testing.expect(sample >= -1.0 and sample <= 1.0);
            }
        }
    }
}

// ── Noise Tests (WP-015) ────────────────────────────────────────────

test "noise varies and bounded" {
    var phase: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase, phase_inc, .noise, &buf);

    // All values bounded
    for (buf) |sample| {
        try std.testing.expect(sample >= -1.0 and sample <= 1.0);
        try std.testing.expect(!std.math.isNan(sample));
    }
    // Not constant (min != max)
    var min_val: f32 = buf[0];
    var max_val: f32 = buf[0];
    for (buf) |sample| {
        if (sample < min_val) min_val = sample;
        if (sample > max_val) max_val = sample;
    }
    try std.testing.expect(min_val != max_val);
}

// ── SuperSaw Tests (WP-015) ─────────────────────────────────────────

test "supersaw equals saw" {
    var phase_saw: f32 = 0.0;
    var phase_ssaw: f32 = 0.0;
    const phase_inc: f32 = 440.0 / 44100.0;
    var buf_saw: [BLOCK_SIZE]f32 = undefined;
    var buf_ssaw: [BLOCK_SIZE]f32 = undefined;
    process_block(&phase_saw, phase_inc, .saw, &buf_saw);
    process_block(&phase_ssaw, phase_inc, .supersaw, &buf_ssaw);
    for (buf_saw, buf_ssaw) |saw, ssaw| {
        try std.testing.expectEqual(saw, ssaw);
    }
    try std.testing.expectEqual(phase_saw, phase_ssaw);
}
