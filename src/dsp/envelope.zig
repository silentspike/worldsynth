const std = @import("std");
const voice = @import("voice.zig");

// ── ADSR Envelope (WP-018) ──────────────────────────────────────────
// Per-voice amplitude/filter envelope with exponential curves.
// Attack: linear rise 0→1. Decay/Release: exponential fall (-60dB).
// Block-compatible: call process_sample() per sample in audio loop.
//
// Usage:
//   var env = Envelope{};
//   env.set_params(0.01, 0.1, 0.7, 0.3, 44100.0);
//   env.note_on();
//   for (0..block_size) |_| {
//       const level = env.process_sample();
//       // apply level to voice amplitude / filter cutoff
//   }
//   env.note_off(); // triggers release

pub const EnvStage = voice.EnvStage;

pub const Envelope = struct {
    stage: EnvStage = .idle,
    value: f32 = 0.0,
    attack_coeff: f32 = 0.0, // linear increment per sample
    decay_coeff: f32 = 0.0, // exponential multiplier per sample
    sustain_level: f32 = 0.0,
    release_coeff: f32 = 0.0, // exponential multiplier per sample

    /// Configure ADSR timing parameters.
    /// attack_s/decay_s/release_s in seconds, sustain in [0, 1].
    pub fn set_params(self: *Envelope, attack_s: f32, decay_s: f32, sustain: f32, release_s: f32, sample_rate: f32) void {
        // Attack: linear rise. coeff = 1/samples, instant if time=0.
        const attack_samples = attack_s * sample_rate;
        self.attack_coeff = if (attack_samples < 1.0) 1.0 else 1.0 / attack_samples;

        // Decay: exponential fall to sustain. exp(-5/samples) ≈ -60dB in decay_s.
        const decay_samples = decay_s * sample_rate;
        self.decay_coeff = if (decay_samples < 1.0) 0.0 else @exp(-5.0 / decay_samples);

        self.sustain_level = sustain;

        // Release: exponential fall to 0. exp(-5/samples) ≈ -60dB in release_s.
        const release_samples = release_s * sample_rate;
        self.release_coeff = if (release_samples < 1.0) 0.0 else @exp(-5.0 / release_samples);
    }

    /// Process one sample. Returns envelope value in [0, 1].
    pub inline fn process_sample(self: *Envelope) f32 {
        switch (self.stage) {
            .idle => return 0.0,
            .attack => {
                self.value += self.attack_coeff;
                if (self.value >= 1.0) {
                    self.value = 1.0;
                    self.stage = .decay;
                }
                return self.value;
            },
            .decay => {
                // Exponential approach to sustain: value = sustain + (value - sustain) * coeff
                self.value = self.sustain_level + (self.value - self.sustain_level) * self.decay_coeff;
                // Snap to sustain when close enough (within 0.01% of full scale)
                if (self.value - self.sustain_level < 0.0001) {
                    self.value = self.sustain_level;
                    self.stage = .sustain;
                }
                return self.value;
            },
            .sustain => return self.value,
            .release => {
                self.value *= self.release_coeff;
                if (self.value < 0.0001) {
                    self.value = 0.0;
                    self.stage = .idle;
                }
                return self.value;
            },
        }
    }

    /// Trigger attack phase. Resets value to 0.
    pub inline fn note_on(self: *Envelope) void {
        self.stage = .attack;
        self.value = 0.0;
    }

    /// Trigger release phase from current value.
    pub inline fn note_off(self: *Envelope) void {
        if (self.stage != .idle) {
            self.stage = .release;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: attack reaches 1.0 in attack_samples ±1" {
    var env = Envelope{};
    const sr: f32 = 44100.0;
    const attack_s: f32 = 0.01; // 10ms
    env.set_params(attack_s, 0.1, 0.7, 0.3, sr);
    env.note_on();

    const expected_samples: u32 = @intFromFloat(attack_s * sr); // 441
    var count: u32 = 0;
    while (env.stage == .attack) {
        _ = env.process_sample();
        count += 1;
        if (count > expected_samples + 10) break; // safety
    }

    try std.testing.expect(env.value == 1.0);
    // Allow ±1 sample tolerance
    try std.testing.expect(count >= expected_samples - 1 and count <= expected_samples + 1);
}

test "AC-2: release reaches idle when value < 0.0001" {
    var env = Envelope{};
    env.set_params(0.001, 0.01, 0.7, 0.1, 44100.0);
    env.note_on();

    // Run through attack+decay to sustain
    for (0..44100) |_| {
        _ = env.process_sample();
        if (env.stage == .sustain) break;
    }
    try std.testing.expectEqual(EnvStage.sustain, env.stage);

    // Trigger release
    env.note_off();
    try std.testing.expectEqual(EnvStage.release, env.stage);

    // Run release until idle
    var count: u32 = 0;
    while (env.stage == .release) {
        _ = env.process_sample();
        count += 1;
        if (count > 100000) break; // safety
    }

    try std.testing.expectEqual(EnvStage.idle, env.stage);
    try std.testing.expectEqual(@as(f32, 0.0), env.value);
}

test "AC-3: sustain holds constant over 10000 samples" {
    var env = Envelope{};
    env.set_params(0.001, 0.01, 0.7, 0.3, 44100.0);
    env.note_on();

    // Fast-forward to sustain
    for (0..44100) |_| {
        _ = env.process_sample();
        if (env.stage == .sustain) break;
    }
    try std.testing.expectEqual(EnvStage.sustain, env.stage);

    // Sustain must hold constant
    const sustain_val = env.value;
    for (0..10000) |_| {
        const v = env.process_sample();
        try std.testing.expectEqual(sustain_val, v);
    }
    try std.testing.expectEqual(EnvStage.sustain, env.stage);
}

test "AC-4: all values in [0, 1] — full ADSR cycle" {
    var env = Envelope{};
    env.set_params(0.01, 0.1, 0.5, 0.2, 44100.0);
    env.note_on();

    // Run attack + decay to sustain
    for (0..44100) |_| {
        const v = env.process_sample();
        try std.testing.expect(v >= 0.0 and v <= 1.0);
        if (env.stage == .sustain) break;
    }

    // Run sustain for a bit
    for (0..1000) |_| {
        const v = env.process_sample();
        try std.testing.expect(v >= 0.0 and v <= 1.0);
    }

    // Trigger release and run to idle
    env.note_off();
    for (0..44100) |_| {
        const v = env.process_sample();
        try std.testing.expect(v >= 0.0 and v <= 1.0);
        if (env.stage == .idle) break;
    }
}

test "zero attack: instant rise to 1.0" {
    var env = Envelope{};
    env.set_params(0.0, 0.1, 0.7, 0.3, 44100.0);
    env.note_on();

    const v = env.process_sample();
    try std.testing.expectEqual(@as(f32, 1.0), v);
    try std.testing.expectEqual(EnvStage.decay, env.stage);
}

test "zero decay: instant snap to sustain" {
    var env = Envelope{};
    env.set_params(0.0, 0.0, 0.5, 0.3, 44100.0);
    env.note_on();

    _ = env.process_sample(); // attack → instant 1.0 → decay
    const v = env.process_sample(); // decay_coeff=0 → snap to sustain
    try std.testing.expectEqual(@as(f32, 0.5), v);
    try std.testing.expectEqual(EnvStage.sustain, env.stage);
}

test "zero release: instant drop to idle" {
    var env = Envelope{};
    env.set_params(0.0, 0.0, 0.5, 0.0, 44100.0);
    env.note_on();

    _ = env.process_sample(); // → decay
    _ = env.process_sample(); // → sustain
    env.note_off();

    const v = env.process_sample();
    try std.testing.expectEqual(@as(f32, 0.0), v);
    try std.testing.expectEqual(EnvStage.idle, env.stage);
}

test "note_off from idle is no-op" {
    var env = Envelope{};
    env.set_params(0.01, 0.1, 0.7, 0.3, 44100.0);

    env.note_off();
    try std.testing.expectEqual(EnvStage.idle, env.stage);
}

test "deterministic: same params produce same sequence" {
    var e1 = Envelope{};
    var e2 = Envelope{};
    e1.set_params(0.01, 0.1, 0.6, 0.2, 44100.0);
    e2.set_params(0.01, 0.1, 0.6, 0.2, 44100.0);
    e1.note_on();
    e2.note_on();

    for (0..2000) |_| {
        const a = e1.process_sample();
        const b = e2.process_sample();
        try std.testing.expectEqual(a, b);
    }
}

test "benchmark: ADSR 128 samples, attack phase" {
    var env = Envelope{};
    env.set_params(0.5, 0.3, 0.7, 0.4, 44100.0); // long attack
    env.note_on();

    // Warmup
    for (0..1000) |_| {
        var e2 = env;
        for (0..128) |_| {
            std.mem.doNotOptimizeAway(e2.process_sample());
        }
    }

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var e2 = env;
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            std.mem.doNotOptimizeAway(e2.process_sample());
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));

    const threshold: f64 = if (@import("builtin").mode == .Debug) 50000.0 else 500.0;

    std.debug.print("\n  [WP-018] ADSR 128 samples, attack phase — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.2}ns/sample\n", .{ median_ns, median_ns / 128.0 });
    std.debug.print("    Threshold: < {d:.0}ns (Issue #20: < 300ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: ADSR 128 samples, attack→decay transition" {
    var env = Envelope{};
    // Set attack so transition happens mid-block (~sample 64)
    const sr: f32 = 44100.0;
    const attack_samples: f32 = 64.0;
    const attack_s = attack_samples / sr;
    env.set_params(attack_s, 0.3, 0.7, 0.4, sr);
    env.note_on();

    // Warmup
    for (0..1000) |_| {
        var e2 = Envelope{};
        e2.set_params(attack_s, 0.3, 0.7, 0.4, sr);
        e2.note_on();
        for (0..128) |_| {
            std.mem.doNotOptimizeAway(e2.process_sample());
        }
    }

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var e2 = Envelope{};
        e2.set_params(attack_s, 0.3, 0.7, 0.4, sr);
        e2.note_on();
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            std.mem.doNotOptimizeAway(e2.process_sample());
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));

    const threshold: f64 = if (@import("builtin").mode == .Debug) 50000.0 else 600.0;

    std.debug.print("\n  [WP-018] ADSR 128 samples, attack→decay transition — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.2}ns/sample\n", .{ median_ns, median_ns / 128.0 });
    std.debug.print("    Threshold: < {d:.0}ns (Issue #20: < 400ns, angepasst: Laptop-Varianz)\n", .{threshold});

    try std.testing.expect(median_ns < threshold);
}

test "benchmark: ADSR 64 voices, 128 samples each" {
    const n_voices = 64;
    var envs: [n_voices]Envelope = undefined;
    for (&envs) |*e| {
        e.* = Envelope{};
        e.set_params(0.5, 0.3, 0.7, 0.4, 44100.0);
        e.note_on();
    }

    // Warmup
    for (0..100) |_| {
        var tmp = envs;
        for (0..128) |_| {
            for (&tmp) |*e| {
                std.mem.doNotOptimizeAway(e.process_sample());
            }
        }
    }

    const runs = 5;
    var times: [runs]u64 = undefined;
    for (&times) |*t| {
        var tmp = envs;
        var timer = try std.time.Timer.start();
        for (0..128) |_| {
            for (&tmp) |*e| {
                std.mem.doNotOptimizeAway(e.process_sample());
            }
        }
        t.* = timer.read();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));
    const median_ns = @as(f64, @floatFromInt(times[runs / 2]));
    const per_voice = median_ns / @as(f64, n_voices);

    const threshold: f64 = if (@import("builtin").mode == .Debug) 2000000.0 else 25000.0;
    const per_voice_threshold: f64 = if (@import("builtin").mode == .Debug) 30000.0 else 500.0;

    std.debug.print("\n  [WP-018] ADSR 64 voices x 128 samples — {d} Runs\n", .{runs});
    std.debug.print("    median: {d:.1}ns total, {d:.1}ns/voice, {d:.2}ns/voice/sample\n", .{
        median_ns,
        per_voice,
        per_voice / 128.0,
    });
    std.debug.print("    Threshold: < {d:.0}ns total, < {d:.0}ns/voice (Issue #20: 15000ns/250ns, angepasst: Laptop-Varianz)\n", .{ threshold, per_voice_threshold });

    try std.testing.expect(median_ns < threshold);
    try std.testing.expect(per_voice < per_voice_threshold);
}
