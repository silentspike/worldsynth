const std = @import("std");
const builtin = @import("builtin");

// ── FDN Reverb Householder 8ch (WP-042) ──────────────────────────
// Feedback Delay Network with 8 channels and Householder mixing matrix.
// Prime-based delay times for dense, colorless reflections.
// 1-pole LP damping in feedback path. Stereo output (ch 0-3 L, ch 4-7 R).
// Zero heap allocation — all delay lines preallocated inline.

pub const BLOCK_SIZE: u32 = 128;
const N: u32 = 8;
const MAX_DELAY: u32 = 4096; // must be power of 2 for bitmask

// Prime-based delay times for dense, colorless reflections
const DELAY_TIMES = [N]u32{ 1087, 1283, 1481, 1693, 1879, 2089, 2293, 2503 };

pub const FdnReverb = struct {
    const Self = @This();

    delay_lines: [N][MAX_DELAY]f32,
    write_pos: [N]u32,
    feedback_gains: [N]f32,
    damp_state: [N]f32,
    damping_coeff: f32,
    mix: f32,

    pub fn init() Self {
        return .{
            .delay_lines = [_][MAX_DELAY]f32{[_]f32{0.0} ** MAX_DELAY} ** N,
            .write_pos = [_]u32{0} ** N,
            .feedback_gains = [_]f32{0.85} ** N,
            .damp_state = [_]f32{0.0} ** N,
            .damping_coeff = 0.3,
            .mix = 0.3,
        };
    }

    /// Set decay time. Computes per-channel feedback gains from delay lengths.
    /// gain = 10^(-3 * delay_samples / (decay_secs * sample_rate))
    pub fn set_decay(self: *Self, decay_secs: f32, sample_rate: f32) void {
        const total = decay_secs * sample_rate;
        if (total < 1.0) {
            @memset(&self.feedback_gains, 0.0);
            return;
        }
        for (&self.feedback_gains, 0..) |*g, i| {
            const dt: f32 = @floatFromInt(DELAY_TIMES[i]);
            g.* = std.math.pow(f32, 0.001, dt / total);
        }
    }

    /// Set damping coefficient (0.0 = no damping, 1.0 = full damping).
    pub fn set_damping(self: *Self, coeff: f32) void {
        self.damping_coeff = std.math.clamp(coeff, 0.0, 1.0);
    }

    /// Set dry/wet mix (0.0 = dry, 1.0 = fully wet).
    pub fn set_mix(self: *Self, m: f32) void {
        self.mix = std.math.clamp(m, 0.0, 1.0);
    }

    /// Householder mixing matrix: out[i] = in[i] - (2/N) * sum(in)
    inline fn householder_mix(input: [N]f32) [N]f32 {
        var sum: f32 = 0.0;
        for (input) |v| sum += v;
        const scale = sum * (2.0 / @as(f32, @floatFromInt(N)));
        var result: [N]f32 = undefined;
        for (&result, input) |*r, v| {
            r.* = v - scale;
        }
        return result;
    }

    /// Process one stereo sample through the FDN.
    pub inline fn process_sample(self: *Self, in_l: f32, in_r: f32) [2]f32 {
        const mask = MAX_DELAY - 1;

        // Read from delay lines
        var tap: [N]f32 = undefined;
        for (0..N) |i| {
            const read_pos = (self.write_pos[i] -% DELAY_TIMES[i]) & mask;
            tap[i] = self.delay_lines[i][read_pos];
        }

        // Householder mix
        const mixed = householder_mix(tap);

        // Damping (1-pole LP) + feedback + write back
        const input_spread = (in_l + in_r) * 0.5;
        for (0..N) |i| {
            const damped = self.damp_state[i] + self.damping_coeff * (mixed[i] - self.damp_state[i]);
            self.damp_state[i] = damped;
            self.delay_lines[i][self.write_pos[i] & mask] = input_spread + damped * self.feedback_gains[i];
            self.write_pos[i] +%= 1;
        }

        // Sum to stereo: channels 0-3 → L, channels 4-7 → R
        var l: f32 = 0.0;
        var r: f32 = 0.0;
        for (0..4) |i| l += tap[i];
        for (4..8) |i| r += tap[i];

        return .{
            in_l * (1.0 - self.mix) + l * 0.25 * self.mix,
            in_r * (1.0 - self.mix) + r * 0.25 * self.mix,
        };
    }

    /// Process a block of stereo samples.
    pub fn process_block(
        self: *Self,
        out_l: *[BLOCK_SIZE]f32,
        out_r: *[BLOCK_SIZE]f32,
        in_l: *const [BLOCK_SIZE]f32,
        in_r: *const [BLOCK_SIZE]f32,
    ) void {
        for (out_l, out_r, in_l, in_r) |*ol, *or_, *il, *ir| {
            const result = self.process_sample(il.*, ir.*);
            ol.* = result[0];
            or_.* = result[1];
        }
    }

    /// Clear all delay line state (for preset changes etc.)
    pub fn clear(self: *Self) void {
        for (&self.delay_lines) |*dl| {
            @memset(dl, 0.0);
        }
        @memset(&self.damp_state, 0.0);
        @memset(&self.write_pos, 0);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

fn rms_block(buf_l: []const f32, buf_r: []const f32) f32 {
    var sum: f64 = 0.0;
    for (buf_l, buf_r) |l, r| {
        const sl: f64 = @floatCast(l);
        const sr: f64 = @floatCast(r);
        sum += sl * sl + sr * sr;
    }
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(buf_l.len * 2))));
}

test "AC-1: impulse produces exponential decay (RMS monotonically decreasing)" {
    var fdn = FdnReverb.init();
    fdn.set_decay(2.0, 44100.0);
    fdn.set_mix(1.0); // fully wet

    // Feed impulse
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;
    var in_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var in_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    in_l[0] = 1.0;
    in_r[0] = 1.0;
    fdn.process_block(&out_l, &out_r, &in_l, &in_r);

    // Measure RMS at 3 points: block 8 (~1000 samples), block 78 (~10000), block 344 (~44100)
    @memset(&in_l, 0.0);
    @memset(&in_r, 0.0);

    var rms_at_1k: f32 = 0.0;
    var rms_at_10k: f32 = 0.0;
    var rms_at_44k: f32 = 0.0;

    for (1..345) |block_idx| {
        fdn.process_block(&out_l, &out_r, &in_l, &in_r);
        if (block_idx == 8) rms_at_1k = rms_block(&out_l, &out_r);
        if (block_idx == 78) rms_at_10k = rms_block(&out_l, &out_r);
        if (block_idx == 344) rms_at_44k = rms_block(&out_l, &out_r);
    }

    // RMS must be monotonically decreasing and non-zero at early points
    try std.testing.expect(rms_at_1k > rms_at_10k);
    try std.testing.expect(rms_at_10k > rms_at_44k);
    try std.testing.expect(rms_at_1k > 0.0001); // not silent early on
}

test "AC-2: near-zero decay produces no reverb tail" {
    var fdn = FdnReverb.init();
    fdn.set_decay(0.001, 44100.0); // near-zero decay
    fdn.set_mix(1.0);

    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;
    var in_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var in_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    in_l[0] = 1.0;
    in_r[0] = 1.0;
    fdn.process_block(&out_l, &out_r, &in_l, &in_r);

    // Process enough blocks to pass the longest delay time (~2503 samples ≈ 20 blocks)
    @memset(&in_l, 0.0);
    @memset(&in_r, 0.0);
    for (0..30) |_| {
        fdn.process_block(&out_l, &out_r, &in_l, &in_r);
    }

    // After longest delay has passed with near-zero feedback, output should be silent
    const rms = rms_block(&out_l, &out_r);
    try std.testing.expect(rms < 0.001);
}

test "AC-N1: stereo output differs for mono input (spatial image)" {
    var fdn = FdnReverb.init();
    fdn.set_decay(1.5, 44100.0);
    fdn.set_mix(1.0);

    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;
    var in_l: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    var in_r: [BLOCK_SIZE]f32 = [_]f32{0.0} ** BLOCK_SIZE;
    in_l[0] = 1.0;
    in_r[0] = 1.0;
    fdn.process_block(&out_l, &out_r, &in_l, &in_r);

    // Process more blocks to let the different delay times create L/R difference
    @memset(&in_l, 0.0);
    @memset(&in_r, 0.0);
    for (0..20) |_| {
        fdn.process_block(&out_l, &out_r, &in_l, &in_r);
    }

    // L and R must differ (different delay times for channels 0-3 vs 4-7)
    var differs = false;
    for (out_l, out_r) |l, r| {
        if (@abs(l - r) > 0.0001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "householder matrix is energy-preserving" {
    const input = [_]f32{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const output = FdnReverb.householder_mix(input);

    // Energy should be preserved (unitary matrix): sum(out^2) == sum(in^2)
    var energy_in: f64 = 0.0;
    var energy_out: f64 = 0.0;
    for (input) |v| {
        const f: f64 = @floatCast(v);
        energy_in += f * f;
    }
    for (output) |v| {
        const f: f64 = @floatCast(v);
        energy_out += f * f;
    }
    try std.testing.expectApproxEqAbs(@as(f64, energy_in), energy_out, 0.001);
}

test "householder matrix is self-inverse" {
    const input = [_]f32{ 0.3, -0.5, 0.7, 0.1, -0.2, 0.4, -0.6, 0.8 };
    const once = FdnReverb.householder_mix(input);
    const twice = FdnReverb.householder_mix(once);

    // H * H = I, so applying twice should return original
    for (input, twice) |orig, recovered| {
        try std.testing.expectApproxEqAbs(orig, recovered, 0.0001);
    }
}

test "set_decay computes correct feedback gains" {
    var fdn = FdnReverb.init();
    fdn.set_decay(2.0, 44100.0);

    // All gains should be between 0 and 1 for positive decay
    for (fdn.feedback_gains) |g| {
        try std.testing.expect(g > 0.0);
        try std.testing.expect(g < 1.0);
    }

    // Shorter delay lines should have higher gain (decay same time = more feedback per tap)
    // DELAY_TIMES[0]=1087 < DELAY_TIMES[7]=2503
    try std.testing.expect(fdn.feedback_gains[0] > fdn.feedback_gains[7]);
}

test "clear resets all state" {
    var fdn = FdnReverb.init();
    fdn.set_decay(2.0, 44100.0);
    fdn.set_mix(1.0);

    // Process some audio
    var out: [2]f32 = undefined;
    out = fdn.process_sample(1.0, 1.0);
    for (0..5000) |_| {
        out = fdn.process_sample(0.0, 0.0);
    }

    // Clear and verify silence
    fdn.clear();
    out = fdn.process_sample(0.0, 0.0);
    try std.testing.expectEqual(@as(f32, 0.0), out[0]);
    try std.testing.expectEqual(@as(f32, 0.0), out[1]);
}

test "process_block matches sequential process_sample" {
    var fdn1 = FdnReverb.init();
    var fdn2 = FdnReverb.init();
    fdn1.set_decay(1.5, 44100.0);
    fdn2.set_decay(1.5, 44100.0);

    var in_l: [BLOCK_SIZE]f32 = undefined;
    var in_r: [BLOCK_SIZE]f32 = undefined;
    for (&in_l, &in_r, 0..) |*l, *r, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, BLOCK_SIZE);
        l.* = @sin(t * std.math.pi * 4.0) * 0.5;
        r.* = @cos(t * std.math.pi * 4.0) * 0.5;
    }

    // process_block
    var block_l: [BLOCK_SIZE]f32 = undefined;
    var block_r: [BLOCK_SIZE]f32 = undefined;
    fdn1.process_block(&block_l, &block_r, &in_l, &in_r);

    // sequential process_sample
    var sample_l: [BLOCK_SIZE]f32 = undefined;
    var sample_r: [BLOCK_SIZE]f32 = undefined;
    for (&sample_l, &sample_r, in_l, in_r) |*sl, *sr, il, ir| {
        const result = fdn2.process_sample(il, ir);
        sl.* = result[0];
        sr.* = result[1];
    }

    for (block_l, sample_l) |b, s| {
        try std.testing.expectApproxEqAbs(b, s, 0.0001);
    }
    for (block_r, sample_r) |b, s| {
        try std.testing.expectApproxEqAbs(b, s, 0.0001);
    }
}

test "no NaN/Inf after 100000 samples" {
    var fdn = FdnReverb.init();
    fdn.set_decay(3.0, 44100.0);
    fdn.set_mix(0.5);

    for (0..100_000) |i| {
        const input: f32 = if (i == 0) 1.0 else 0.0;
        const out = fdn.process_sample(input, input);
        try std.testing.expect(!std.math.isNan(out[0]));
        try std.testing.expect(!std.math.isNan(out[1]));
        try std.testing.expect(!std.math.isInf(out[0]));
        try std.testing.expect(!std.math.isInf(out[1]));
    }
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: FDN 128 samples 8ch Householder" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var fdn = FdnReverb.init();
    fdn.set_decay(2.0, 44100.0);
    fdn.set_mix(0.5);

    var in_l: [BLOCK_SIZE]f32 = [_]f32{0.1} ** BLOCK_SIZE;
    var in_r: [BLOCK_SIZE]f32 = [_]f32{0.1} ** BLOCK_SIZE;
    var out_l: [BLOCK_SIZE]f32 = undefined;
    var out_r: [BLOCK_SIZE]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        fdn.process_block(&out_l, &out_r, &in_l, &in_r);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        fdn.process_block(&out_l, &out_r, &in_l, &in_r);
        std.mem.doNotOptimizeAway(&out_l);
        std.mem.doNotOptimizeAway(&out_r);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 15_000 else 200_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-042] FDN 8ch: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: Householder matrix isolated" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    const input = [_]f32{ 0.3, -0.5, 0.7, 0.1, -0.2, 0.4, -0.6, 0.8 };

    // Warmup
    for (0..1000) |_| {
        std.mem.doNotOptimizeAway(&FdnReverb.householder_mix(input));
    }

    const iterations: u64 = 5_000_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        std.mem.doNotOptimizeAway(&FdnReverb.householder_mix(input));
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 50 else 500;
    const pass = ns < budget;
    std.debug.print("\n[WP-042] Householder 8x8: {}ns/call (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
