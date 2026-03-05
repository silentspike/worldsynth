const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const onnx_runtime = @import("../../io/onnx_runtime.zig");

// ── Neural RAVE Engine (WP-062) ─────────────────────────────────────
// Realtime neural oscillator shell with latent-space controls and
// lock-free preallocated buffering. ONNX inference is optional and
// gracefully degrades to silence when unavailable.

pub const BLOCK_SIZE: usize = 128;
pub const RING_SIZE: usize = 1024;
pub const MAX_LATENT_DIM: u8 = 16;
pub const DEFAULT_LATENT_DIM: u8 = 8;
pub const DDSP_BINS: usize = 64;
pub const DEFAULT_SAMPLE_RATE: f32 = 48_000.0;

pub const RaveError = error{
    InvalidLatentDim,
};

fn clamp01(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return @max(0.0, @min(1.0, v));
}

fn clampSampleRate(sample_rate: f32) f32 {
    if (!std.math.isFinite(sample_rate) or sample_rate < 1_000.0) {
        return DEFAULT_SAMPLE_RATE;
    }
    return sample_rate;
}

fn clampFrequency(freq: f32) f32 {
    if (!std.math.isFinite(freq) or freq <= 0.0) return 0.0;
    return @max(20.0, @min(20_000.0, freq));
}

pub const RaveEngine = struct {
    const Self = @This();

    onnx_session: ?onnx_runtime.OnnxSession,
    latent_dim: u8,
    latent_coords: [MAX_LATENT_DIM]f32,
    ring_buffer: [RING_SIZE]f32,
    staging_buffer: [RING_SIZE]f32,
    read_pos: usize,
    write_pos: usize,
    available_samples: usize,
    buffer_ready: bool,
    staging_ready: bool,
    last_output: f32,
    degraded: bool,

    pub fn init(model_path: ?[*:0]const u8) RaveError!Self {
        if (DEFAULT_LATENT_DIM == 0 or DEFAULT_LATENT_DIM > MAX_LATENT_DIM) {
            return error.InvalidLatentDim;
        }

        var self = Self{
            .onnx_session = null,
            .latent_dim = DEFAULT_LATENT_DIM,
            .latent_coords = .{0.5} ** MAX_LATENT_DIM,
            .ring_buffer = .{0.0} ** RING_SIZE,
            .staging_buffer = .{0.0} ** RING_SIZE,
            .read_pos = 0,
            .write_pos = 0,
            .available_samples = 0,
            .buffer_ready = false,
            .staging_ready = false,
            .last_output = 0.0,
            .degraded = true,
        };

        if (comptime build_options.enable_neural) {
            if (model_path) |path| {
                self.onnx_session = onnx_runtime.OnnxSession.init(path) catch null;
                self.degraded = self.onnx_session == null;
            }
        }

        return self;
    }

    pub fn set_latent(self: *Self, dim: u8, value: f32) void {
        if (dim >= self.latent_dim or dim >= MAX_LATENT_DIM) return;
        self.latent_coords[dim] = clamp01(value);
        self.staging_ready = false;
    }

    fn generateNextBuffer(self: *Self, out: *[RING_SIZE]f32) void {
        if (comptime build_options.enable_neural) {
            if (self.onnx_session) |*session| {
                const latent_len: usize = @intCast(self.latent_dim);
                session.run(self.latent_coords[0..latent_len], out[0..]) catch {
                    @memset(out, 0.0);
                    self.degraded = true;
                    return;
                };
                self.degraded = false;
                return;
            }
        }

        // Graceful degradation when ONNX/model is unavailable.
        @memset(out, 0.0);
        self.degraded = true;
    }

    fn swapInStaging(self: *Self) void {
        // Fade first samples from previous output to reduce click risk.
        const fade_len = @min(@as(usize, 8), RING_SIZE);
        for (0..fade_len) |i| {
            const t: f32 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(fade_len));
            self.staging_buffer[i] = self.last_output * (1.0 - t) + self.staging_buffer[i] * t;
        }

        @memcpy(self.ring_buffer[0..], self.staging_buffer[0..]);
        self.read_pos = 0;
        self.write_pos = 0;
        self.available_samples = RING_SIZE;
        self.buffer_ready = true;
        self.staging_ready = false;
    }

    fn ensureAvailable(self: *Self, needed: usize) void {
        if (self.available_samples >= needed) return;

        if (!self.staging_ready) {
            self.generateNextBuffer(&self.staging_buffer);
            self.staging_ready = true;
        }

        if (self.staging_ready and self.available_samples < needed) {
            self.swapInStaging();
        }
    }

    pub fn process_block(self: *Self, out: []f32) void {
        if (out.len == 0) return;

        self.ensureAvailable(out.len);

        for (out) |*sample| {
            if (self.available_samples == 0) {
                self.ensureAvailable(1);
            }

            if (self.available_samples == 0) {
                sample.* = 0.0;
                self.last_output = 0.0;
                continue;
            }

            sample.* = self.ring_buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % RING_SIZE;
            self.available_samples -= 1;
            self.buffer_ready = self.available_samples >= BLOCK_SIZE;
            self.last_output = sample.*;
        }

        // Background-ready staging generation for next block.
        if (self.available_samples <= BLOCK_SIZE and !self.staging_ready) {
            self.generateNextBuffer(&self.staging_buffer);
            self.staging_ready = true;
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.onnx_session) |*session| {
            session.deinit();
        }
        self.onnx_session = null;
    }
};

pub const DdspMode = struct {
    const Self = @This();

    harmonic_distribution: [DDSP_BINS]f32,
    noise_filter: [DDSP_BINS]f32,
    fundamental_freq: f32,
    phase_accumulators: [DDSP_BINS]f64,
    sample_rate: f32,
    noise_state: u64,
    noise_level: f32,

    pub fn init(sample_rate: f32) DdspMode {
        var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
        harmonics[0] = 1.0;

        return .{
            .harmonic_distribution = harmonics,
            .noise_filter = .{0.0} ** DDSP_BINS,
            .fundamental_freq = 440.0,
            .phase_accumulators = .{0.0} ** DDSP_BINS,
            .sample_rate = clampSampleRate(sample_rate),
            .noise_state = 0x9E3779B97F4A7C15,
            .noise_level = 0.0,
        };
    }

    pub fn set_frequency(self: *Self, freq: f32) void {
        self.fundamental_freq = clampFrequency(freq);
    }

    pub fn update_neural(self: *Self, harmonics: []const f32, noise: []const f32) void {
        var harmonic_sum: f32 = 0.0;
        var noise_sum: f32 = 0.0;

        for (0..DDSP_BINS) |i| {
            const harmonic = clamp01(if (i < harmonics.len) harmonics[i] else 0.0);
            const noise_weight = clamp01(if (i < noise.len) noise[i] else 0.0);

            self.harmonic_distribution[i] = harmonic;
            self.noise_filter[i] = noise_weight;

            harmonic_sum += harmonic;
            noise_sum += noise_weight;
        }

        if (harmonic_sum <= 1e-6) {
            @memset(self.harmonic_distribution[0..], 0.0);
            self.harmonic_distribution[0] = 1.0;
        } else {
            const inv_sum = 1.0 / harmonic_sum;
            for (&self.harmonic_distribution) |*harmonic| {
                harmonic.* *= inv_sum;
            }
        }

        self.noise_level = clamp01(noise_sum / @as(f32, @floatFromInt(DDSP_BINS)));
    }

    fn nextWhiteNoise(self: *Self) f32 {
        // xorshift64* — deterministic, allocation-free white noise.
        var x = self.noise_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.noise_state = x;

        const scrambled = x *% 2685821657736338717;
        const unit = @as(f64, @floatFromInt(scrambled)) /
            @as(f64, @floatFromInt(std.math.maxInt(u64)));

        return @floatCast(unit * 2.0 - 1.0);
    }

    pub fn process_sample(self: *Self) f32 {
        if (self.fundamental_freq <= 0.0) return 0.0;

        const tau: f64 = std.math.tau;
        const base_phase_inc = tau * @as(f64, self.fundamental_freq) / @as(f64, self.sample_rate);

        var harmonic_out: f64 = 0.0;
        for (0..DDSP_BINS) |i| {
            const harmonic_idx: f64 = @as(f64, @floatFromInt(i + 1));
            var phase = self.phase_accumulators[i] + (base_phase_inc * harmonic_idx);
            if (phase >= tau) {
                phase -= tau * @floor(phase / tau);
            }
            self.phase_accumulators[i] = phase;
            harmonic_out += @as(f64, self.harmonic_distribution[i]) * std.math.sin(phase);
        }

        var shaped_noise: f32 = 0.0;
        if (self.noise_level > 0.0) {
            for (self.noise_filter) |weight| {
                if (weight > 0.0) {
                    shaped_noise += self.nextWhiteNoise() * weight;
                }
            }
            shaped_noise /= self.noise_level * @as(f32, @floatFromInt(DDSP_BINS));
        }

        const harmonic_mix = @as(f32, @floatCast(harmonic_out));
        const mixed = harmonic_mix * 0.9 + shaped_noise * (0.1 * self.noise_level);
        return @max(-1.0, @min(1.0, mixed));
    }

    pub fn process_block(self: *Self, out: []f32) void {
        for (out) |*sample| {
            sample.* = self.process_sample();
        }
    }
};

pub const NeuralMode = enum {
    rave,
    ddsp,
};

pub const NeuralEngine = struct {
    const Self = @This();

    mode: NeuralMode,
    rave: RaveEngine,
    ddsp: DdspMode,

    pub fn init(model_path: ?[*:0]const u8, sample_rate: f32) RaveError!Self {
        return .{
            .mode = .rave,
            .rave = try RaveEngine.init(model_path),
            .ddsp = DdspMode.init(sample_rate),
        };
    }

    pub fn set_mode(self: *Self, mode: NeuralMode) void {
        self.mode = mode;
    }

    pub fn set_latent(self: *Self, dim: u8, value: f32) void {
        self.rave.set_latent(dim, value);
    }

    pub fn set_frequency(self: *Self, freq: f32) void {
        self.ddsp.set_frequency(freq);
    }

    pub fn update_ddsp(self: *Self, harmonics: []const f32, noise: []const f32) void {
        self.ddsp.update_neural(harmonics, noise);
    }

    pub fn process_block(self: *Self, out: []f32) void {
        switch (self.mode) {
            .rave => self.rave.process_block(out),
            .ddsp => self.ddsp.process_block(out),
        }
    }

    pub fn deinit(self: *Self) void {
        self.rave.deinit();
    }
};

fn estimateFundamentalHz(samples: []const f32, sample_rate: f32) f32 {
    if (samples.len < 3) return 0.0;

    var crossings: [256]usize = undefined;
    var crossing_count: usize = 0;
    var prev = samples[0];

    for (samples[1..], 1..) |cur, idx| {
        if (prev <= 0.0 and cur > 0.0) {
            if (crossing_count == crossings.len) break;
            crossings[crossing_count] = idx;
            crossing_count += 1;
        }
        prev = cur;
    }

    if (crossing_count < 2) return 0.0;

    var period_sum: f64 = 0.0;
    for (crossings[1..crossing_count], crossings[0 .. crossing_count - 1]) |curr, prev_idx| {
        period_sum += @as(f64, @floatFromInt(curr - prev_idx));
    }

    const avg_period = period_sum / @as(f64, @floatFromInt(crossing_count - 1));
    if (avg_period <= 0.0) return 0.0;

    const freq = @as(f64, sample_rate) / avg_period;
    return @floatCast(freq);
}

// ── Tests ───────────────────────────────────────────────────────────

test "set_latent clamps to [0,1] and ignores out-of-range dimensions" {
    var eng = try RaveEngine.init(null);
    defer eng.deinit();

    try std.testing.expectEqual(@as(u8, DEFAULT_LATENT_DIM), eng.latent_dim);

    eng.set_latent(0, 1.5);
    eng.set_latent(1, -0.3);
    eng.set_latent(15, 0.9); // outside current latent_dim=8, should be ignored

    try std.testing.expectEqual(@as(f32, 1.0), eng.latent_coords[0]);
    try std.testing.expectEqual(@as(f32, 0.0), eng.latent_coords[1]);
    try std.testing.expectEqual(@as(f32, 0.5), eng.latent_coords[15]);
}

test "AC-N1/AC-N2: missing model degrades gracefully to silence (no crash)" {
    var eng = try RaveEngine.init(null);
    defer eng.deinit();

    var out: [BLOCK_SIZE]f32 = undefined;
    eng.process_block(&out);

    for (out) |s| {
        try std.testing.expectEqual(@as(f32, 0.0), s);
        try std.testing.expect(!std.math.isNan(s));
        try std.testing.expect(!std.math.isInf(s));
    }
}

test "AC-3: ring/staging swap is click-reduced at boundary" {
    var eng = try RaveEngine.init(null);
    defer eng.deinit();

    for (0..BLOCK_SIZE) |i| {
        eng.ring_buffer[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(BLOCK_SIZE));
    }
    for (BLOCK_SIZE..RING_SIZE) |i| {
        eng.ring_buffer[i] = eng.ring_buffer[BLOCK_SIZE - 1];
    }
    for (&eng.staging_buffer) |*s| s.* = -1.0;

    eng.read_pos = 0;
    eng.write_pos = 0;
    eng.available_samples = BLOCK_SIZE;
    eng.buffer_ready = true;
    eng.staging_ready = true;
    eng.last_output = eng.ring_buffer[BLOCK_SIZE - 1];

    var out_a: [BLOCK_SIZE]f32 = undefined;
    eng.process_block(&out_a);
    var out_b: [BLOCK_SIZE]f32 = undefined;
    eng.process_block(&out_b);

    const jump = @abs(out_b[0] - out_a[BLOCK_SIZE - 1]);
    std.debug.print("\n[AC-3] boundary jump={d:.6}\n", .{jump});

    // Hard jump from ~1.0 to -1.0 would be ~2.0; smoothing should keep this much lower.
    try std.testing.expect(jump < 0.3);
}

test "AC-1: latent vector yields non-silent output when ONNX model is available" {
    if (comptime !build_options.enable_neural) return error.SkipZigTest;

    const model_path = std.process.getEnvVarOwned(std.testing.allocator, "WORLDSYNTH_RAVE_MODEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(model_path);

    if (model_path.len == 0) return error.SkipZigTest;

    const model_path_z = try std.testing.allocator.dupeZ(u8, model_path);
    defer std.testing.allocator.free(model_path_z);

    var eng = try RaveEngine.init(model_path_z.ptr);
    defer eng.deinit();
    if (eng.onnx_session == null) return error.SkipZigTest;

    for (0..eng.latent_dim) |i| eng.set_latent(@intCast(i), 0.5);

    var out: [BLOCK_SIZE]f32 = undefined;
    eng.process_block(&out);

    var has_nonzero = false;
    for (out) |s| {
        if (@abs(s) > 1e-7) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "AC-2: different latent vectors produce different output when ONNX model is available" {
    if (comptime !build_options.enable_neural) return error.SkipZigTest;

    const model_path = std.process.getEnvVarOwned(std.testing.allocator, "WORLDSYNTH_RAVE_MODEL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(model_path);

    if (model_path.len == 0) return error.SkipZigTest;

    const model_path_z = try std.testing.allocator.dupeZ(u8, model_path);
    defer std.testing.allocator.free(model_path_z);

    var eng = try RaveEngine.init(model_path_z.ptr);
    defer eng.deinit();
    if (eng.onnx_session == null) return error.SkipZigTest;

    var out_a: [BLOCK_SIZE]f32 = undefined;
    var out_b: [BLOCK_SIZE]f32 = undefined;

    for (0..eng.latent_dim) |i| eng.set_latent(@intCast(i), 0.2);
    eng.available_samples = 0;
    eng.staging_ready = false;
    eng.process_block(&out_a);

    for (0..eng.latent_dim) |i| eng.set_latent(@intCast(i), 0.8);
    eng.available_samples = 0;
    eng.staging_ready = false;
    eng.process_block(&out_b);

    var diff_sum: f64 = 0.0;
    for (out_a, out_b) |a, b| {
        diff_sum += @abs(@as(f64, a) - @as(f64, b));
    }
    std.debug.print("\n[AC-2] latent diff sum={d:.6}\n", .{diff_sum});
    try std.testing.expect(diff_sum > 1e-4);
}

test "DDSP AC-1: C4 stays near 261.6Hz (+/- 5Hz)" {
    var ddsp = DdspMode.init(48_000.0);
    ddsp.set_frequency(261.62558);

    var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    harmonics[0] = 1.0;
    const noise: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    ddsp.update_neural(&harmonics, &noise);

    var samples: [8192]f32 = undefined;
    ddsp.process_block(&samples);

    const estimated = estimateFundamentalHz(&samples, ddsp.sample_rate);
    std.debug.print("\n[DDSP AC-1] estimated fundamental={d:.3}Hz\n", .{estimated});

    try std.testing.expect(@abs(estimated - 261.62558) <= 5.0);
}

test "DDSP AC-2: neural output changes texture, not pitch" {
    var ddsp_a = DdspMode.init(48_000.0);
    var ddsp_b = DdspMode.init(48_000.0);
    ddsp_a.set_frequency(261.62558);
    ddsp_b.set_frequency(261.62558);

    var harmonics_a: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var harmonics_b: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var noise_a: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var noise_b: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;

    harmonics_a[0] = 1.0;
    harmonics_b[0] = 1.0;
    for (0..DDSP_BINS) |i| {
        noise_b[i] = if (i < 8) 0.5 else 0.15;
    }

    ddsp_a.update_neural(&harmonics_a, &noise_a);
    ddsp_b.update_neural(&harmonics_b, &noise_b);

    var out_a: [8192]f32 = undefined;
    var out_b: [8192]f32 = undefined;
    ddsp_a.process_block(&out_a);
    ddsp_b.process_block(&out_b);

    const freq_a = estimateFundamentalHz(&out_a, ddsp_a.sample_rate);
    const freq_b = estimateFundamentalHz(&out_b, ddsp_b.sample_rate);

    var diff_sum: f64 = 0.0;
    for (out_a, out_b) |a, b| {
        diff_sum += @abs(@as(f64, a) - @as(f64, b));
    }

    std.debug.print("\n[DDSP AC-2] freq_a={d:.3}Hz freq_b={d:.3}Hz diff={d:.3}\n", .{
        freq_a,
        freq_b,
        diff_sum,
    });

    try std.testing.expect(@abs(freq_a - freq_b) <= 5.0);
    try std.testing.expect(diff_sum > 10.0);
}

test "DDSP AC-3: mode switch RAVE <-> DDSP is stable" {
    var engine = try NeuralEngine.init(null, 48_000.0);
    defer engine.deinit();

    var out_rave: [BLOCK_SIZE]f32 = undefined;
    var out_ddsp: [BLOCK_SIZE]f32 = undefined;
    var out_rave_again: [BLOCK_SIZE]f32 = undefined;

    engine.set_mode(.rave);
    engine.process_block(&out_rave);

    var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    const noise: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    harmonics[0] = 1.0;

    engine.set_mode(.ddsp);
    engine.set_frequency(261.62558);
    engine.update_ddsp(&harmonics, &noise);
    engine.process_block(&out_ddsp);

    engine.set_mode(.rave);
    engine.process_block(&out_rave_again);

    var ddsp_has_signal = false;
    for (out_ddsp) |s| {
        if (@abs(s) > 1e-6) {
            ddsp_has_signal = true;
            break;
        }
    }

    for (out_rave_again) |s| {
        try std.testing.expect(!std.math.isNan(s));
        try std.testing.expect(!std.math.isInf(s));
    }

    try std.testing.expect(ddsp_has_signal);
}

test "DDSP AC-N1: invalid neural values are sanitized (no panic)" {
    var ddsp = DdspMode.init(48_000.0);
    ddsp.set_frequency(220.0);

    var bad_harmonics: [DDSP_BINS]f32 = undefined;
    var bad_noise: [DDSP_BINS]f32 = undefined;

    for (0..DDSP_BINS) |i| {
        bad_harmonics[i] = switch (i % 4) {
            0 => std.math.nan(f32),
            1 => std.math.inf(f32),
            2 => -0.7,
            else => 1.7,
        };
        bad_noise[i] = switch (i % 4) {
            0 => -std.math.inf(f32),
            1 => std.math.nan(f32),
            2 => -1.3,
            else => 2.0,
        };
    }

    ddsp.update_neural(&bad_harmonics, &bad_noise);

    var sum: f32 = 0.0;
    for (ddsp.harmonic_distribution) |h| {
        try std.testing.expect(std.math.isFinite(h));
        try std.testing.expect(h >= 0.0 and h <= 1.0);
        sum += h;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-3);

    var out: [BLOCK_SIZE]f32 = undefined;
    ddsp.process_block(&out);
    for (out) |s| {
        try std.testing.expect(!std.math.isNan(s));
        try std.testing.expect(!std.math.isInf(s));
    }
}

test "benchmark: ddsp neural parameter update (64 harm + 64 noise)" {
    var ddsp = DdspMode.init(48_000.0);

    var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var noise: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    const iterations = 25_000;

    for (0..2_000) |i| {
        for (0..DDSP_BINS) |h| {
            harmonics[h] = @as(f32, @floatFromInt((i + h) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
            noise[h] = @as(f32, @floatFromInt((i * 3 + h) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
        }
        ddsp.update_neural(&harmonics, &noise);
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |i| {
        for (0..DDSP_BINS) |h| {
            harmonics[h] = @as(f32, @floatFromInt((i + h * 5) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
            noise[h] = @as(f32, @floatFromInt((i * 7 + h) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
        }
        ddsp.update_neural(&harmonics, &noise);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_inference = elapsed_ns / iterations;
    const ms_per_inference = @as(f64, @floatFromInt(ns_per_inference)) / 1_000_000.0;

    std.debug.print("\n[WP-063] ddsp neural update: {d:.6}ms/inference (budget: <1.500000ms)\n", .{
        ms_per_inference,
    });

    const budget_ns: u64 = if (builtin.mode == .Debug) 8_000_000 else 1_500_000;
    try std.testing.expect(ns_per_inference < budget_ns);
}

test "benchmark: ddsp dsp block (128 samples)" {
    var ddsp = DdspMode.init(48_000.0);
    ddsp.set_frequency(220.0);

    var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var noise: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    for (0..DDSP_BINS) |i| {
        harmonics[i] = if (i == 0) 1.0 else 0.2 / @as(f32, @floatFromInt(i + 1));
        noise[i] = if (i < 8) 0.4 else 0.05;
    }
    ddsp.update_neural(&harmonics, &noise);

    var out: [BLOCK_SIZE]f32 = undefined;
    const iterations = 2_000;

    for (0..128) |_| {
        ddsp.process_block(&out);
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        ddsp.process_block(&out);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_block = elapsed_ns / iterations;

    std.debug.print("\n[WP-063] ddsp dsp: {d}ns/block (budget: <3000ns)\n", .{ns_per_block});

    const budget_ns: u64 = if (builtin.mode == .Debug) 2_000_000 else 3_000;
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: ddsp hybrid total (neural + dsp block)" {
    var ddsp = DdspMode.init(48_000.0);
    ddsp.set_frequency(261.62558);

    var harmonics: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var noise: [DDSP_BINS]f32 = .{0.0} ** DDSP_BINS;
    var out: [BLOCK_SIZE]f32 = undefined;
    const iterations = 1_500;

    for (0..96) |_| {
        ddsp.update_neural(&harmonics, &noise);
        ddsp.process_block(&out);
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |i| {
        for (0..DDSP_BINS) |h| {
            harmonics[h] = @as(f32, @floatFromInt((i + h) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
            noise[h] = @as(f32, @floatFromInt((i * 11 + h) % DDSP_BINS)) / @as(f32, @floatFromInt(DDSP_BINS - 1));
        }
        ddsp.update_neural(&harmonics, &noise);
        ddsp.process_block(&out);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_block = elapsed_ns / iterations;
    const ms_per_block = @as(f64, @floatFromInt(ns_per_block)) / 1_000_000.0;

    std.debug.print("\n[WP-063] ddsp hybrid total: {d:.6}ms/block (budget: <2.000000ms)\n", .{
        ms_per_block,
    });

    const budget_ns: u64 = if (builtin.mode == .Debug) 6_000_000 else 2_000_000;
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: rave latent navigation 16 dims" {
    var eng = try RaveEngine.init(null);
    defer eng.deinit();

    const iterations = 50_000;

    for (0..5_000) |i| {
        const dim: u8 = @intCast(i % eng.latent_dim);
        const t: f32 = @as(f32, @floatFromInt(i % 1000)) / 1000.0;
        eng.set_latent(dim, t);
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |i| {
        const dim: u8 = @intCast(i % eng.latent_dim);
        const t: f32 = @as(f32, @floatFromInt((i * 37) % 1000)) / 1000.0;
        eng.set_latent(dim, t);
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    const ns_per_op = elapsed_ns / iterations;

    std.debug.print("\n[WP-062] rave latent navigation: {d}ns/op\n", .{ns_per_op});

    const budget_ns: u64 = if (builtin.mode == .Debug) 50_000 else 1_000;
    try std.testing.expect(ns_per_op < budget_ns);
}
