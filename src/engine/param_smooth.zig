const std = @import("std");

// ── ParamSmoother (WP-008) ──────────────────────────────────────────
// Anti-Zipper Filter: Exponentielles Glaetten von Parameter-Aenderungen.
// One-Pole Lowpass auf Parameter-Werte. Verhindert hoerbare Klick-Artefakte
// bei sprunghaften Aenderungen (Cutoff, Volume, Automation).
// current += coeff * (target - current) — pro Sample, inline.

pub const ParamSmoother = struct {
    current: f32,
    target: f32,
    coeff: f32,

    /// Initialize with value, smoothing time in ms, and sample rate.
    /// Coefficient: 1.0 - exp(-1 / (tau_samples)), where tau = ms * 0.001 * sr.
    pub fn init(initial: f32, smoothing_ms: f32, sample_rate: f32) ParamSmoother {
        const tau = smoothing_ms * 0.001 * sample_rate;
        const coeff = if (tau > 0.0) 1.0 - @exp(-1.0 / tau) else 1.0;
        return .{
            .current = initial,
            .target = initial,
            .coeff = coeff,
        };
    }

    /// Set a new target value. Smoothing happens in next().
    pub inline fn set_target(self: *ParamSmoother, new_target: f32) void {
        self.target = new_target;
    }

    /// Advance one sample. Returns the smoothed value.
    /// Audio-thread hot-path — must be inline, no allocation, no branching.
    pub inline fn next(self: *ParamSmoother) f32 {
        self.current += self.coeff * (self.target - self.current);
        return self.current;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "init sets current and target to initial value" {
    const s = ParamSmoother.init(0.5, 5.0, 44100.0);
    try std.testing.expectEqual(@as(f32, 0.5), s.current);
    try std.testing.expectEqual(@as(f32, 0.5), s.target);
    try std.testing.expect(s.coeff > 0.0);
    try std.testing.expect(s.coeff <= 1.0);
}

test "converges within 441 samples (10ms @ 44.1kHz) to < 0.01 deviation (AC-1)" {
    // 2ms smoothing: tau = 88.2 samples, 441 samples = 5*tau → exp(-5) ≈ 0.0067
    var s = ParamSmoother.init(0.0, 2.0, 44100.0);
    s.set_target(1.0);
    var i: usize = 0;
    while (i < 441) : (i += 1) {
        _ = s.next();
    }
    // After 10ms (441 samples) with 2ms smoothing, must be within 0.01 of target
    try std.testing.expect(@abs(s.current - 1.0) < 0.01);
}

test "monotonic convergence toward target (AC-2)" {
    var s = ParamSmoother.init(0.5, 5.0, 44100.0);
    s.set_target(1.0);
    var prev = s.current;
    var monotonic = true;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const val = s.next();
        if (val < prev) {
            monotonic = false;
            break;
        }
        prev = val;
    }
    try std.testing.expect(monotonic);
}

test "monotonic convergence downward" {
    var s = ParamSmoother.init(1.0, 5.0, 44100.0);
    s.set_target(0.0);
    var prev = s.current;
    var monotonic = true;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const val = s.next();
        if (val > prev) {
            monotonic = false;
            break;
        }
        prev = val;
    }
    try std.testing.expect(monotonic);
}

test "zero smoothing time: instant convergence" {
    var s = ParamSmoother.init(0.0, 0.0, 44100.0);
    s.set_target(1.0);
    const val = s.next();
    try std.testing.expectEqual(@as(f32, 1.0), val);
}

test "set_target changes target without affecting current" {
    var s = ParamSmoother.init(0.0, 5.0, 44100.0);
    s.set_target(1.0);
    try std.testing.expectEqual(@as(f32, 0.0), s.current);
    try std.testing.expectEqual(@as(f32, 1.0), s.target);
}

test "multiple target changes: follows latest target" {
    // 2ms smoothing: 441 samples = 5*tau → converges within 0.01
    var s = ParamSmoother.init(0.0, 2.0, 44100.0);
    s.set_target(1.0);
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = s.next();
    s.set_target(0.5);
    i = 0;
    while (i < 441) : (i += 1) _ = s.next();
    try std.testing.expect(@abs(s.current - 0.5) < 0.01);
}

test "no NaN/Inf for edge cases" {
    const cases = [_][3]f32{
        .{ 0.0, 0.0, 44100.0 },
        .{ 0.0, 0.001, 44100.0 },
        .{ 0.0, 1000.0, 44100.0 },
        .{ -1.0, 5.0, 44100.0 },
        .{ 1e6, 5.0, 44100.0 },
    };
    for (cases) |c| {
        var s = ParamSmoother.init(c[0], c[1], c[2]);
        s.set_target(1.0);
        var i: usize = 0;
        while (i < 128) : (i += 1) {
            const val = s.next();
            try std.testing.expect(!std.math.isNan(val));
            try std.testing.expect(!std.math.isInf(val));
        }
    }
}
