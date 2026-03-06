const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");

// ── Microtuning System (WP-124) ────────────────────────────────────
// TuningTable with 128 f32 frequencies, Scala .scl parser,
// drop-in replacement for MIDI_FREQ lookup.
//
// Scala format (.scl):
//   - Lines starting with '!' are comments
//   - First non-comment line: description
//   - Second non-comment line: number of intervals (N)
//   - Following N lines: intervals as cents (e.g. "100.000") or ratio (e.g. "3/2")
//   - Intervals define one octave relative to 1/1 (implicit unison)
//   - Last interval should be the octave (e.g. "1200.000" or "2/1")

pub const TuningTable = struct {
    freqs: [128]f32 = undefined,

    /// Initialize with standard 12-TET tuning (identical to MIDI_FREQ).
    pub fn init_12tet() TuningTable {
        var t: TuningTable = undefined;
        for (0..128) |note| {
            t.freqs[note] = calc_12tet_freq(note);
        }
        return t;
    }

    /// Frequency lookup — drop-in replacement for MIDI_FREQ[note].
    pub fn note_to_freq(self: *const TuningTable, note: u7) f32 {
        return self.freqs[note];
    }

    /// Reset to standard 12-TET tuning.
    pub fn reset(self: *TuningTable) void {
        self.* = init_12tet();
    }

    /// Load tuning from Scala .scl file content (in-memory string).
    /// Returns error for malformed files.
    pub fn load_scala(self: *TuningTable, data: []const u8) !void {
        const intervals = try parse_scala(data);

        if (intervals.count == 0) return error.EmptyScale;

        // Build full 128-note table from parsed intervals.
        // Base frequency: MIDI note 0 in 12-TET as reference.
        const base_freq: f32 = calc_12tet_freq(0);
        const octave_ratio = intervals.ratios[intervals.count - 1];
        const scale_len = intervals.count;

        self.freqs[0] = base_freq;
        for (1..128) |note| {
            // Which octave and scale degree does this note fall into?
            // note = octave * scale_len + degree
            const octave: i32 = @intCast(@divFloor(@as(i32, @intCast(note)), @as(i32, @intCast(scale_len))));
            const degree: usize = @intCast(@mod(@as(i32, @intCast(note)), @as(i32, @intCast(scale_len))));

            // Ratio for this degree (degree 0 = unison = 1.0)
            const degree_ratio: f64 = if (degree == 0) 1.0 else intervals.ratios[degree - 1];

            // Octave transposition using the scale's own octave ratio
            const oct_factor = std.math.pow(f64, octave_ratio, @floatFromInt(octave));
            self.freqs[note] = @floatCast(base_freq * degree_ratio * oct_factor);
        }
    }
};

// ── Scala Parser ────────────────────────────────────────────────────

const max_intervals = 128;

const ScalaData = struct {
    ratios: [max_intervals]f64, // intervals as frequency ratios
    count: usize,
};

const ScalaError = error{
    InvalidFormat,
    InvalidInterval,
    TooManyIntervals,
    EmptyScale,
};

/// Parse Scala .scl file content into interval ratios.
fn parse_scala(data: []const u8) ScalaError!ScalaData {
    var result = ScalaData{
        .ratios = [_]f64{0.0} ** max_intervals,
        .count = 0,
    };

    var lines = std.mem.splitScalar(u8, data, '\n');
    var non_comment_line: usize = 0;
    var expected_count: usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '!') continue;

        if (non_comment_line == 0) {
            // First non-comment line: description (ignored)
            non_comment_line += 1;
            continue;
        }

        if (non_comment_line == 1) {
            // Second non-comment line: number of intervals
            expected_count = parse_note_count(line) orelse return error.InvalidFormat;
            if (expected_count > max_intervals) return error.TooManyIntervals;
            non_comment_line += 1;
            continue;
        }

        // Interval lines
        if (result.count >= expected_count) break;

        const ratio = parse_interval(line) orelse return error.InvalidInterval;
        result.ratios[result.count] = ratio;
        result.count += 1;
        non_comment_line += 1;
    }

    if (result.count != expected_count) return error.InvalidFormat;

    return result;
}

/// Parse the note count line (integer string).
fn parse_note_count(line: []const u8) ?usize {
    // Trim any trailing comments or whitespace
    var end: usize = 0;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(usize, line[0..end], 10) catch null;
}

/// Parse a single interval line. Supports:
/// - Cents: number with decimal point (e.g. "100.000", "701.955")
/// - Ratio: numerator/denominator (e.g. "3/2", "5/4")
fn parse_interval(line: []const u8) ?f64 {
    // Trim trailing comments (anything after whitespace)
    var effective = line;
    for (line, 0..) |c, i| {
        if (c == ' ' or c == '\t') {
            effective = line[0..i];
            break;
        }
    }
    if (effective.len == 0) return null;

    // Check for ratio (contains '/')
    if (std.mem.indexOfScalar(u8, effective, '/')) |slash_pos| {
        const num = std.fmt.parseFloat(f64, effective[0..slash_pos]) catch return null;
        const den = std.fmt.parseFloat(f64, effective[slash_pos + 1 ..]) catch return null;
        if (den == 0.0) return null;
        return num / den;
    }

    // Check for cents (contains '.')
    if (std.mem.indexOfScalar(u8, effective, '.')) |_| {
        const cents = std.fmt.parseFloat(f64, effective) catch return null;
        return cents_to_ratio(cents);
    }

    // Plain integer — treat as cents (e.g. "1200" = octave)
    const val = std.fmt.parseFloat(f64, effective) catch return null;
    return cents_to_ratio(val);
}

/// Convert cents to frequency ratio: ratio = 2^(cents/1200)
fn cents_to_ratio(cents: f64) f64 {
    return std.math.pow(f64, 2.0, cents / 1200.0);
}

/// Calculate 12-TET frequency for a MIDI note.
fn calc_12tet_freq(note: usize) f32 {
    return @floatCast(440.0 * std.math.pow(f64, 2.0, (@as(f64, @floatFromInt(note)) - 69.0) / 12.0));
}

/// Convert frequency ratio to cents: cents = 1200 * log2(ratio)
fn ratio_to_cents(ratio: f64) f64 {
    return 1200.0 * std.math.log2(ratio);
}

// ── MTS-ESP Stub (WP-124: placeholder for future host sync) ────────

pub const MtsEspStatus = enum {
    disconnected,
    connected,
};

/// MTS-ESP stub — always returns disconnected.
/// Will be replaced with real implementation when MTS-ESP host sync is added.
pub fn mts_esp_status() MtsEspStatus {
    return .disconnected;
}

/// MTS-ESP stub — returns 12-TET frequency for given note.
/// Uses the comptime MIDI_FREQ table for fast lookup.
pub fn mts_esp_note_to_freq(note: u7) f32 {
    return tables.MIDI_FREQ[note];
}

// ── Tests ─────────────────────────────────────────────────────────────

// Standard 12-TET Scala file (12 notes, 100 cents each)
const scala_12tet =
    \\! 12-TET standard tuning
    \\12-tone equal temperament
    \\12
    \\100.000
    \\200.000
    \\300.000
    \\400.000
    \\500.000
    \\600.000
    \\700.000
    \\800.000
    \\900.000
    \\1000.000
    \\1100.000
    \\1200.000
;

// Just Intonation Scala file (12 notes, ratio-based)
const scala_just =
    \\! Just Intonation (5-limit)
    \\Just Intonation 12-note scale
    \\12
    \\16/15
    \\9/8
    \\6/5
    \\5/4
    \\4/3
    \\45/32
    \\3/2
    \\8/5
    \\5/3
    \\9/5
    \\15/8
    \\2/1
;

test "AC-1: 12-TET scala matches MIDI_FREQ" {
    var t = TuningTable.init_12tet();
    try t.load_scala(scala_12tet);

    // Compare against comptime MIDI_FREQ for all 128 notes
    for (0..128) |note| {
        const expected = tables.MIDI_FREQ[note];
        const actual = t.freqs[note];
        // Allow tiny floating-point deviation (comptime f64→f32 vs runtime f64→f32)
        const tolerance: f32 = expected * 0.0001; // 0.01%
        try std.testing.expectApproxEqAbs(expected, actual, tolerance);
    }
}

test "AC-2: just intonation scala gives correct frequencies" {
    var t = TuningTable.init_12tet();
    try t.load_scala(scala_just);

    // Base freq = MIDI note 0 in 12-TET
    const base = calc_12tet_freq(0);

    // Check known ratios within the first octave (notes 1-12)
    // note 7 = 3/2 (perfect fifth)
    const fifth_expected = base * 1.5;
    try std.testing.expectApproxEqAbs(fifth_expected, t.freqs[7], fifth_expected * 0.0001);

    // note 4 = 5/4 (major third)
    const third_expected = base * 1.25;
    try std.testing.expectApproxEqAbs(third_expected, t.freqs[4], third_expected * 0.0001);

    // note 5 = 4/3 (perfect fourth)
    const fourth_expected = base * (4.0 / 3.0);
    try std.testing.expectApproxEqAbs(fourth_expected, t.freqs[5], fourth_expected * 0.0001);

    // note 12 = 2/1 (octave) — should be 2x base
    const octave_expected = base * 2.0;
    try std.testing.expectApproxEqAbs(octave_expected, t.freqs[12], octave_expected * 0.0001);
}

test "AC-3: note_to_freq returns correct value after tuning change" {
    var t = TuningTable.init_12tet();

    // Before: 12-TET A4
    const a4_12tet = t.note_to_freq(69);
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), a4_12tet, 0.01);

    // Load just intonation
    try t.load_scala(scala_just);

    // After: note_to_freq should return the just-tuned value (different from 440.0)
    const a4_just = t.note_to_freq(69);
    // In just intonation, note 69 maps to a different frequency than 12-TET
    try std.testing.expect(a4_just > 0.0);
    // Verify it actually changed (just != 12-TET for most notes)
    // Note 69 = octave 5, degree 9 (69/12 = 5 rem 9). Degree 9 = 5/3 ratio.
    const base = calc_12tet_freq(0);
    const oct_factor = std.math.pow(f64, 2.0, 5.0); // octave 5
    const expected: f32 = @floatCast(base * (5.0 / 3.0) * oct_factor);
    try std.testing.expectApproxEqAbs(expected, a4_just, expected * 0.001);
}

test "AC-4: reset restores 12-TET" {
    var t = TuningTable.init_12tet();
    try t.load_scala(scala_just);

    // After load, values differ from 12-TET
    const just_freq = t.freqs[69];

    // Reset
    t.reset();

    // Should match MIDI_FREQ again
    try std.testing.expectApproxEqAbs(tables.MIDI_FREQ[69], t.freqs[69], 0.01);
    // And differ from the just-tuned value
    try std.testing.expect(@abs(t.freqs[69] - just_freq) > 0.1);
}

test "AC-N1: invalid scala file returns error, no crash" {
    var t = TuningTable.init_12tet();

    // Empty content
    try std.testing.expectError(error.EmptyScale, t.load_scala(""));

    // Missing intervals
    try std.testing.expectError(error.InvalidFormat, t.load_scala(
        \\! bad file
        \\description
        \\3
        \\100.0
    ));

    // Invalid interval syntax
    try std.testing.expectError(error.InvalidInterval, t.load_scala(
        \\! bad interval
        \\description
        \\1
        \\not_a_number
    ));

    // Division by zero in ratio
    try std.testing.expectError(error.InvalidInterval, t.load_scala(
        \\! div by zero
        \\description
        \\1
        \\3/0
    ));
}

test "12-TET accuracy: A4 within 0.01 cent" {
    const t = TuningTable.init_12tet();
    const a4 = t.note_to_freq(69);
    // Cents deviation from 440.0
    const ratio: f64 = @as(f64, a4) / 440.0;
    const cents_dev = @abs(ratio_to_cents(ratio));
    try std.testing.expect(cents_dev < 0.01);
}

test "init_12tet matches MIDI_FREQ exactly" {
    const t = TuningTable.init_12tet();
    for (0..128) |note| {
        try std.testing.expectEqual(tables.MIDI_FREQ[note], t.freqs[note]);
    }
}

test "MTS-ESP stub returns disconnected" {
    try std.testing.expectEqual(MtsEspStatus.disconnected, mts_esp_status());
}

test "MTS-ESP stub note_to_freq matches 12-TET" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), mts_esp_note_to_freq(69), 0.01);
}

test "benchmark: lookup, parse, accuracy" {
    const lookup_budget_ns = switch (builtin.mode) {
        .Debug => 250.0,
        .ReleaseSafe => 120.0,
        .ReleaseFast, .ReleaseSmall => 100.0,
    };

    // -- Lookup benchmark --
    const t_12tet = TuningTable.init_12tet();
    var timer = try std.time.Timer.start();
    var sum: f32 = 0.0;
    for (0..10000) |i| {
        sum += t_12tet.note_to_freq(@intCast(i % 128));
    }
    const lookup_ns = timer.read();
    std.mem.doNotOptimizeAway(sum);

    const lookup_ns_per_op = @as(f64, @floatFromInt(lookup_ns)) / 10000.0;

    // -- Parse benchmark --
    var t_bench: TuningTable = undefined;
    timer.reset();
    for (0..1000) |_| {
        t_bench.load_scala(scala_12tet) catch unreachable;
    }
    const parse_ns = timer.read();
    const parse_us_per_op = @as(f64, @floatFromInt(parse_ns)) / 1000.0 / 1000.0;

    // -- Accuracy benchmark --
    const t_acc = TuningTable.init_12tet();
    var max_cents_dev: f64 = 0.0;
    for (0..128) |note| {
        const actual: f64 = @floatCast(t_acc.freqs[note]);
        const expected: f64 = 440.0 * std.math.pow(f64, 2.0, (@as(f64, @floatFromInt(note)) - 69.0) / 12.0);
        if (expected > 0.0) {
            const dev = @abs(ratio_to_cents(actual / expected));
            if (dev > max_cents_dev) max_cents_dev = dev;
        }
    }

    // -- MTS-ESP stub benchmark --
    timer.reset();
    var mts_sum: f32 = 0.0;
    for (0..10000) |i| {
        mts_sum += mts_esp_note_to_freq(@intCast(i % 128));
    }
    const mts_ns = timer.read();
    std.mem.doNotOptimizeAway(mts_sum);
    const mts_ns_per_op = @as(f64, @floatFromInt(mts_ns)) / 10000.0;

    std.debug.print("\n  [WP-124] Microtuning Benchmark\n", .{});
    std.debug.print("    Lookup:   {d:.1}ns/op (Schwelle: <{d:.1}ns, mode={s})\n", .{
        lookup_ns_per_op,
        lookup_budget_ns,
        @tagName(builtin.mode),
    });
    std.debug.print("    Parse:    {d:.1}us/op (Schwelle: <5ms)\n", .{parse_us_per_op});
    std.debug.print("    Accuracy: {d:.6} Cent max deviation (Schwelle: <0.01 Cent)\n", .{max_cents_dev});
    const mts_budget_ns = switch (builtin.mode) {
        .Debug => 380.0,
        .ReleaseSafe => 260.0,
        .ReleaseFast, .ReleaseSmall => 200.0,
    };
    std.debug.print("    MTS-ESP:  {d:.1}ns/op (Schwelle: <{d:.1}ns)\n", .{ mts_ns_per_op, mts_budget_ns });

    // Enforce thresholds
    try std.testing.expect(lookup_ns_per_op < lookup_budget_ns);
    try std.testing.expect(parse_us_per_op < 5000.0); // < 5ms
    try std.testing.expect(max_cents_dev < 0.01);
    try std.testing.expect(mts_ns_per_op < mts_budget_ns);
}
