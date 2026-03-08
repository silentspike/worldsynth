const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const onnx_runtime = @import("../../io/onnx_runtime.zig");

// -- Genetic Quick Breed (WP-066) --------------------------------------------
// Parameter-level crossover and mutation for evolutionary sound design.
// Two parent parameter arrays are crossed and mutated to produce 8 children.
// Deterministic given the same seed. No heap allocation.

pub const MAX_PARAMS: usize = 256;
pub const MAX_CHILDREN: usize = 8;

pub const CrossoverType = enum(u2) {
    single_point,
    multi_point,
    uniform,
};

pub const Constraints = struct {
    locked: [MAX_PARAMS]bool,
    min_values: [MAX_PARAMS]f32,
    max_values: [MAX_PARAMS]f32,

    pub fn init() Constraints {
        return .{
            .locked = .{false} ** MAX_PARAMS,
            .min_values = .{0.0} ** MAX_PARAMS,
            .max_values = .{1.0} ** MAX_PARAMS,
        };
    }

    pub fn lock(self: *Constraints, param: usize) void {
        if (param < MAX_PARAMS) self.locked[param] = true;
    }

    pub fn unlock(self: *Constraints, param: usize) void {
        if (param < MAX_PARAMS) self.locked[param] = false;
    }

    pub fn set_range(self: *Constraints, param: usize, min: f32, max: f32) void {
        if (param < MAX_PARAMS) {
            self.min_values[param] = min;
            self.max_values[param] = max;
        }
    }
};

// -- PRNG: xorshift64* (same algorithm as physical.zig KarplusStrong) ---------

fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 2685821657736338717;
}

fn random_f32(state: *u64) f32 {
    const bits = xorshift64(state);
    return @as(f32, @floatFromInt(bits >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
}

fn random_usize(state: *u64, max: usize) usize {
    if (max == 0) return 0;
    return @intCast(xorshift64(state) % @as(u64, @intCast(max)));
}

// -- Crossover ----------------------------------------------------------------

fn crossover_single_point(
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    child: *[MAX_PARAMS]f32,
    param_count: usize,
    constraints: *const Constraints,
    rng: *u64,
) void {
    const count = @min(param_count, MAX_PARAMS);
    const point = if (count > 1) random_usize(rng, count) else 0;
    for (0..count) |i| {
        if (constraints.locked[i]) {
            child[i] = parent_a[i];
        } else {
            child[i] = if (i < point) parent_a[i] else parent_b[i];
        }
    }
}

fn crossover_multi_point(
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    child: *[MAX_PARAMS]f32,
    param_count: usize,
    constraints: *const Constraints,
    rng: *u64,
) void {
    const count = @min(param_count, MAX_PARAMS);
    // Generate 3 crossover points and sort them.
    var points: [3]usize = undefined;
    for (&points) |*p| {
        p.* = if (count > 1) random_usize(rng, count) else 0;
    }
    // Simple sort of 3 elements.
    if (points[0] > points[1]) std.mem.swap(usize, &points[0], &points[1]);
    if (points[1] > points[2]) std.mem.swap(usize, &points[1], &points[2]);
    if (points[0] > points[1]) std.mem.swap(usize, &points[0], &points[1]);

    for (0..count) |i| {
        if (constraints.locked[i]) {
            child[i] = parent_a[i];
            continue;
        }
        // Determine segment: before p0, p0-p1, p1-p2, after p2
        var segment: usize = 0;
        for (points) |p| {
            if (i >= p) segment += 1;
        }
        // Even segments → parent A, odd segments → parent B
        child[i] = if (segment % 2 == 0) parent_a[i] else parent_b[i];
    }
}

fn crossover_uniform(
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    child: *[MAX_PARAMS]f32,
    param_count: usize,
    constraints: *const Constraints,
    rng: *u64,
) void {
    const count = @min(param_count, MAX_PARAMS);
    for (0..count) |i| {
        if (constraints.locked[i]) {
            child[i] = parent_a[i];
        } else {
            child[i] = if (random_f32(rng) < 0.5) parent_a[i] else parent_b[i];
        }
    }
}

fn do_crossover(
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    child: *[MAX_PARAMS]f32,
    param_count: usize,
    crossover_type: CrossoverType,
    constraints: *const Constraints,
    rng: *u64,
) void {
    switch (crossover_type) {
        .single_point => crossover_single_point(parent_a, parent_b, child, param_count, constraints, rng),
        .multi_point => crossover_multi_point(parent_a, parent_b, child, param_count, constraints, rng),
        .uniform => crossover_uniform(parent_a, parent_b, child, param_count, constraints, rng),
    }
}

// -- Mutation -----------------------------------------------------------------

fn mutate(
    params: *[MAX_PARAMS]f32,
    param_count: usize,
    rate: f32,
    constraints: *const Constraints,
    rng: *u64,
) void {
    const count = @min(param_count, MAX_PARAMS);
    const clamped_rate = std.math.clamp(rate, 0.0, 1.0);
    for (0..count) |i| {
        if (constraints.locked[i]) continue;
        if (random_f32(rng) < clamped_rate) {
            const delta = (random_f32(rng) - 0.5) * 0.2;
            params[i] = std.math.clamp(
                params[i] + delta,
                constraints.min_values[i],
                constraints.max_values[i],
            );
        }
    }
}

// -- Public API ---------------------------------------------------------------

/// Breed 8 children from two parents using crossover and mutation.
/// Deterministic: same seed produces identical results.
pub fn breed(
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    children: *[MAX_CHILDREN][MAX_PARAMS]f32,
    param_count: usize,
    mutation_rate: f32,
    crossover_type: CrossoverType,
    constraints: *const Constraints,
    seed: u64,
) void {
    var rng: u64 = if (seed == 0) 0x9E3779B97F4A7C15 else seed;
    for (0..MAX_CHILDREN) |child_idx| {
        do_crossover(parent_a, parent_b, &children[child_idx], param_count, crossover_type, constraints, &rng);
        mutate(&children[child_idx], param_count, mutation_rate, constraints, &rng);
    }
}

// -- Deep Breed VAE (WP-067) --------------------------------------------------
// Latent-space navigation via ONNX VAE Encoder/Decoder.
// Degraded mode: identity mapping + linear parameter interpolation.

pub const LATENT_DIM: usize = 32;

pub const VaeBreeder = struct {
    encoder: ?onnx_runtime.OnnxSession,
    decoder: ?onnx_runtime.OnnxSession,
    degraded: bool,

    pub fn init(
        encoder_path: ?[*:0]const u8,
        decoder_path: ?[*:0]const u8,
    ) VaeBreeder {
        if (comptime !build_options.enable_neural) {
            return .{ .encoder = null, .decoder = null, .degraded = true };
        }

        const enc = if (encoder_path) |p|
            onnx_runtime.OnnxSession.init(p) catch null
        else
            null;

        const dec = if (decoder_path) |p|
            onnx_runtime.OnnxSession.init(p) catch null
        else
            null;

        const is_degraded = enc == null or dec == null;
        // If one session succeeded but the other failed, clean up the successful one.
        if (is_degraded) {
            if (enc) |*e| {
                var session = e.*;
                session.deinit();
            }
            if (dec) |*d| {
                var session = d.*;
                session.deinit();
            }
            return .{ .encoder = null, .decoder = null, .degraded = true };
        }

        return .{ .encoder = enc, .decoder = dec, .degraded = false };
    }

    pub fn deinit(self: *VaeBreeder) void {
        if (self.encoder) |*enc| enc.deinit();
        if (self.decoder) |*dec| dec.deinit();
        self.encoder = null;
        self.decoder = null;
    }

    /// Encode parameters to latent space.
    /// Degraded: identity mapping (first LATENT_DIM params, rest truncated).
    pub fn encode(self: *VaeBreeder, params: *const [MAX_PARAMS]f32) [LATENT_DIM]f32 {
        if (self.encoder) |*enc| {
            var latent: [LATENT_DIM]f32 = .{0.0} ** LATENT_DIM;
            enc.run(params, &latent) catch {
                // Fallback to identity on runtime error.
                return identity_encode(params);
            };
            return latent;
        }
        return identity_encode(params);
    }

    /// Decode latent vector back to parameters.
    /// Degraded: identity mapping (latent dims become first params).
    pub fn decode(self: *VaeBreeder, latent: *const [LATENT_DIM]f32) [MAX_PARAMS]f32 {
        if (self.decoder) |*dec| {
            var params: [MAX_PARAMS]f32 = .{0.0} ** MAX_PARAMS;
            dec.run(latent, &params) catch {
                return identity_decode(latent);
            };
            return params;
        }
        return identity_decode(latent);
    }
};

fn identity_encode(params: *const [MAX_PARAMS]f32) [LATENT_DIM]f32 {
    var latent: [LATENT_DIM]f32 = .{0.0} ** LATENT_DIM;
    @memcpy(&latent, params[0..LATENT_DIM]);
    return latent;
}

fn identity_decode(latent: *const [LATENT_DIM]f32) [MAX_PARAMS]f32 {
    var params: [MAX_PARAMS]f32 = .{0.0} ** MAX_PARAMS;
    @memcpy(params[0..LATENT_DIM], latent);
    return params;
}

/// Interpolate between two latent vectors. Pure math, no ONNX needed.
pub fn interpolate_latent(
    a: *const [LATENT_DIM]f32,
    b: *const [LATENT_DIM]f32,
    t: f32,
) [LATENT_DIM]f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - clamped;
    var result: [LATENT_DIM]f32 = undefined;
    for (0..LATENT_DIM) |i| {
        result[i] = @mulAdd(f32, clamped, b[i], inv * a[i]);
    }
    return result;
}

/// Convenience: encode two parents, interpolate at even spacing, decode.
/// Produces MAX_CHILDREN child parameter sets.
/// Falls back to linear parameter interpolation when degraded.
pub fn deep_breed(
    breeder: *VaeBreeder,
    parent_a: *const [MAX_PARAMS]f32,
    parent_b: *const [MAX_PARAMS]f32,
    children: *[MAX_CHILDREN][MAX_PARAMS]f32,
    param_count: usize,
) void {
    if (breeder.degraded) {
        // Linear parameter interpolation fallback.
        const count = @min(param_count, MAX_PARAMS);
        for (0..MAX_CHILDREN) |ci| {
            const t: f32 = @as(f32, @floatFromInt(ci + 1)) / @as(f32, @floatFromInt(MAX_CHILDREN + 1));
            for (0..count) |p| {
                children[ci][p] = @mulAdd(f32, t, parent_b[p], (1.0 - t) * parent_a[p]);
            }
            // Zero remaining params.
            for (count..MAX_PARAMS) |p| {
                children[ci][p] = 0.0;
            }
        }
        return;
    }

    const latent_a = breeder.encode(parent_a);
    const latent_b = breeder.encode(parent_b);

    for (0..MAX_CHILDREN) |ci| {
        const t: f32 = @as(f32, @floatFromInt(ci + 1)) / @as(f32, @floatFromInt(MAX_CHILDREN + 1));
        const latent = interpolate_latent(&latent_a, &latent_b, t);
        children[ci] = breeder.decode(&latent);
    }
}

fn benchIterations(debug_iters: u64, safe_iters: u64, release_iters: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_iters,
        .ReleaseSafe => safe_iters,
        .ReleaseFast, .ReleaseSmall => release_iters,
    };
}

fn benchBudget(debug_budget: u64, safe_budget: u64, release_budget: u64) u64 {
    return switch (builtin.mode) {
        .Debug => debug_budget,
        .ReleaseSafe => safe_budget,
        .ReleaseFast, .ReleaseSmall => release_budget,
    };
}

// -- Tests --------------------------------------------------------------------

test "AC-1: 2 parents produce 8 different children" {
    var parent_a: [MAX_PARAMS]f32 = undefined;
    var parent_b: [MAX_PARAMS]f32 = undefined;
    for (0..MAX_PARAMS) |i| {
        parent_a[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_PARAMS));
        parent_b[i] = 1.0 - parent_a[i];
    }

    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    const constraints = Constraints.init();
    breed(&parent_a, &parent_b, &children, 200, 0.1, .uniform, &constraints, 42);

    // Every pair of children must differ in at least one parameter.
    var all_different = true;
    for (0..MAX_CHILDREN) |i| {
        for (i + 1..MAX_CHILDREN) |j| {
            var differs = false;
            for (0..200) |p| {
                if (children[i][p] != children[j][p]) {
                    differs = true;
                    break;
                }
            }
            if (!differs) all_different = false;
        }
    }
    try std.testing.expect(all_different);
    std.debug.print("\n[WP-066] AC-1: 8 children all different: true\n", .{});
}

test "AC-2: mutation_rate=0 produces pure crossover (values only from parents)" {
    var parent_a: [MAX_PARAMS]f32 = .{0.2} ** MAX_PARAMS;
    var parent_b: [MAX_PARAMS]f32 = .{0.8} ** MAX_PARAMS;

    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    const constraints = Constraints.init();
    breed(&parent_a, &parent_b, &children, 200, 0.0, .uniform, &constraints, 123);

    // Every child parameter must be exactly 0.2 or 0.8.
    for (0..MAX_CHILDREN) |c| {
        for (0..200) |p| {
            const v = children[c][p];
            const is_a = v == 0.2;
            const is_b = v == 0.8;
            if (!is_a and !is_b) {
                std.debug.print("\n[WP-066] AC-2 FAIL: child[{}][{}] = {d:.6}\n", .{ c, p, v });
                try std.testing.expect(false);
            }
        }
    }
    std.debug.print("\n[WP-066] AC-2: mutation_rate=0 → all values from parents: PASS\n", .{});
}

test "AC-3: locked parameters are preserved from parent A" {
    var parent_a: [MAX_PARAMS]f32 = .{0.3} ** MAX_PARAMS;
    var parent_b: [MAX_PARAMS]f32 = .{0.7} ** MAX_PARAMS;

    var constraints = Constraints.init();
    constraints.lock(5);
    constraints.lock(10);
    constraints.lock(50);

    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    breed(&parent_a, &parent_b, &children, 200, 0.5, .uniform, &constraints, 999);

    for (0..MAX_CHILDREN) |c| {
        try std.testing.expectEqual(@as(f32, 0.3), children[c][5]);
        try std.testing.expectEqual(@as(f32, 0.3), children[c][10]);
        try std.testing.expectEqual(@as(f32, 0.3), children[c][50]);
    }
    std.debug.print("\n[WP-066] AC-3: locked params preserved for all 8 children: PASS\n", .{});
}

test "AC-N1: mutation_rate=1.0 keeps all values in range" {
    var parent_a: [MAX_PARAMS]f32 = .{0.5} ** MAX_PARAMS;
    var parent_b: [MAX_PARAMS]f32 = .{0.5} ** MAX_PARAMS;

    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    const constraints = Constraints.init();
    breed(&parent_a, &parent_b, &children, MAX_PARAMS, 1.0, .uniform, &constraints, 77);

    for (0..MAX_CHILDREN) |c| {
        for (0..MAX_PARAMS) |p| {
            const v = children[c][p];
            if (v < 0.0 or v > 1.0 or !std.math.isFinite(v)) {
                std.debug.print("\n[WP-066] AC-N1 FAIL: child[{}][{}] = {d:.6}\n", .{ c, p, v });
                try std.testing.expect(false);
            }
        }
    }
    std.debug.print("\n[WP-066] AC-N1: all values in [0,1] with rate=1.0: PASS\n", .{});
}

test "determinism: same seed produces identical children" {
    var parent_a: [MAX_PARAMS]f32 = undefined;
    var parent_b: [MAX_PARAMS]f32 = undefined;
    for (0..MAX_PARAMS) |i| {
        parent_a[i] = @as(f32, @floatFromInt(i % 100)) / 100.0;
        parent_b[i] = 1.0 - parent_a[i];
    }

    const constraints = Constraints.init();
    var children_1: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    var children_2: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;

    breed(&parent_a, &parent_b, &children_1, 200, 0.3, .multi_point, &constraints, 0xDEAD);
    breed(&parent_a, &parent_b, &children_2, 200, 0.3, .multi_point, &constraints, 0xDEAD);

    for (0..MAX_CHILDREN) |c| {
        for (0..200) |p| {
            try std.testing.expectEqual(children_1[c][p], children_2[c][p]);
        }
    }
    std.debug.print("\n[WP-066] Determinism: same seed → identical children: PASS\n", .{});
}

test "crossover types produce different distributions" {
    var parent_a: [MAX_PARAMS]f32 = .{0.1} ** MAX_PARAMS;
    var parent_b: [MAX_PARAMS]f32 = .{0.9} ** MAX_PARAMS;

    const constraints = Constraints.init();
    var children_sp: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    var children_mp: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    var children_uni: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;

    breed(&parent_a, &parent_b, &children_sp, 200, 0.0, .single_point, &constraints, 42);
    breed(&parent_a, &parent_b, &children_mp, 200, 0.0, .multi_point, &constraints, 42);
    breed(&parent_a, &parent_b, &children_uni, 200, 0.0, .uniform, &constraints, 42);

    // Count how many params come from parent_a across ALL 8 children.
    var count_sp: usize = 0;
    var count_mp: usize = 0;
    var count_uni: usize = 0;
    for (0..MAX_CHILDREN) |c| {
        for (0..200) |p| {
            if (children_sp[c][p] == 0.1) count_sp += 1;
            if (children_mp[c][p] == 0.1) count_mp += 1;
            if (children_uni[c][p] == 0.1) count_uni += 1;
        }
    }
    const total = MAX_CHILDREN * 200;

    std.debug.print("\n[WP-066] Crossover distributions (8 children, 200 params): SP={}/{}, MP={}/{}, UNI={}/{}\n", .{
        count_sp, total, count_mp, total, count_uni, total,
    });

    // Over 8 children, each type must have a mix of A and B values.
    try std.testing.expect(count_sp > 0 and count_sp < total);
    try std.testing.expect(count_mp > 0 and count_mp < total);
    try std.testing.expect(count_uni > 0 and count_uni < total);
}

test "benchmark: breed 8 children (200 params)" {
    var parent_a: [MAX_PARAMS]f32 = undefined;
    var parent_b: [MAX_PARAMS]f32 = undefined;
    for (0..MAX_PARAMS) |i| {
        parent_a[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_PARAMS));
        parent_b[i] = 1.0 - parent_a[i];
    }
    const constraints = Constraints.init();
    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;

    // Warmup
    for (0..100) |s| {
        breed(&parent_a, &parent_b, &children, 200, 0.3, .uniform, &constraints, s + 1);
    }

    const iterations = benchIterations(5_000, 50_000, 200_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |s| {
        breed(&parent_a, &parent_b, &children, 200, 0.3, .uniform, &constraints, s + 1);
        std.mem.doNotOptimizeAway(&children);
    }
    const ns_per_breed = timer.read() / iterations;

    const budget = benchBudget(
        10_000_000, // 10ms debug
        1_000_000, // 1ms release-safe
        500_000, // 500µs release-fast
    );
    std.debug.print("\n[WP-066] breed 8 children (200 params): {}ns ({d:.2}µs, budget: {}ns, mode={s})\n", .{
        ns_per_breed,
        @as(f64, @floatFromInt(ns_per_breed)) / 1000.0,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_breed < budget);
}

// -- WP-067: Deep Breed VAE Tests ---------------------------------------------

test "WP-067 AC-1: encode/decode identity in degraded mode" {
    var breeder = VaeBreeder.init(null, null);
    defer breeder.deinit();
    try std.testing.expect(breeder.degraded);

    var params: [MAX_PARAMS]f32 = undefined;
    for (0..MAX_PARAMS) |i| {
        params[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_PARAMS));
    }

    const latent = breeder.encode(&params);
    const decoded = breeder.decode(&latent);

    // In degraded mode: first LATENT_DIM params round-trip exactly.
    for (0..LATENT_DIM) |i| {
        try std.testing.expectEqual(params[i], decoded[i]);
    }
    // Remaining params are zeroed in degraded decode.
    for (LATENT_DIM..MAX_PARAMS) |i| {
        try std.testing.expectEqual(@as(f32, 0.0), decoded[i]);
    }
    std.debug.print("\n[WP-067] AC-1: encode→decode identity in degraded mode: PASS\n", .{});
}

test "WP-067 AC-2: interpolate_latent produces midpoint" {
    var a: [LATENT_DIM]f32 = .{0.0} ** LATENT_DIM;
    var b: [LATENT_DIM]f32 = .{1.0} ** LATENT_DIM;
    // Set some varying values.
    for (0..LATENT_DIM) |i| {
        a[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(LATENT_DIM));
        b[i] = 1.0 - a[i];
    }

    const mid = interpolate_latent(&a, &b, 0.5);

    // Midpoint should differ from both a and b.
    var differs_a = false;
    var differs_b = false;
    for (0..LATENT_DIM) |i| {
        if (mid[i] != a[i]) differs_a = true;
        if (mid[i] != b[i]) differs_b = true;
        // Midpoint should be approximately (a+b)/2.
        const expected = (a[i] + b[i]) * 0.5;
        try std.testing.expectApproxEqAbs(expected, mid[i], 1e-6);
    }
    try std.testing.expect(differs_a);
    try std.testing.expect(differs_b);

    // Boundary: t=0 → a, t=1 → b.
    const at_zero = interpolate_latent(&a, &b, 0.0);
    const at_one = interpolate_latent(&a, &b, 1.0);
    for (0..LATENT_DIM) |i| {
        try std.testing.expectEqual(a[i], at_zero[i]);
        try std.testing.expectEqual(b[i], at_one[i]);
    }
    std.debug.print("\n[WP-067] AC-2: interpolate produces correct midpoint: PASS\n", .{});
}

test "WP-067 AC-3: deep_breed degraded produces linear interpolation" {
    var breeder = VaeBreeder.init(null, null);
    defer breeder.deinit();
    try std.testing.expect(breeder.degraded);

    var parent_a: [MAX_PARAMS]f32 = .{0.0} ** MAX_PARAMS;
    var parent_b: [MAX_PARAMS]f32 = .{1.0} ** MAX_PARAMS;

    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;
    deep_breed(&breeder, &parent_a, &parent_b, &children, 100);

    // Each child should be a linear interpolation at t = (ci+1)/(MAX_CHILDREN+1).
    for (0..MAX_CHILDREN) |ci| {
        const t: f32 = @as(f32, @floatFromInt(ci + 1)) / @as(f32, @floatFromInt(MAX_CHILDREN + 1));
        for (0..100) |p| {
            const expected = t * parent_b[p] + (1.0 - t) * parent_a[p];
            try std.testing.expectApproxEqAbs(expected, children[ci][p], 1e-6);
        }
    }
    std.debug.print("\n[WP-067] AC-3: deep_breed degraded → linear interpolation: PASS\n", .{});
}

test "WP-067 AC-N1: VaeBreeder init/deinit without crash" {
    // No model paths → degraded, no crash.
    var breeder = VaeBreeder.init(null, null);
    try std.testing.expect(breeder.degraded);
    try std.testing.expect(breeder.encoder == null);
    try std.testing.expect(breeder.decoder == null);
    breeder.deinit();
    // Double deinit must not crash.
    breeder.deinit();
    std.debug.print("\n[WP-067] AC-N1: graceful degradation without model: PASS\n", .{});
}

test "benchmark: deep_breed 8 children (degraded)" {
    var breeder = VaeBreeder.init(null, null);
    defer breeder.deinit();

    var parent_a: [MAX_PARAMS]f32 = undefined;
    var parent_b: [MAX_PARAMS]f32 = undefined;
    for (0..MAX_PARAMS) |i| {
        parent_a[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(MAX_PARAMS));
        parent_b[i] = 1.0 - parent_a[i];
    }
    var children: [MAX_CHILDREN][MAX_PARAMS]f32 = undefined;

    // Warmup
    for (0..100) |_| {
        deep_breed(&breeder, &parent_a, &parent_b, &children, 200);
    }

    const iterations = benchIterations(5_000, 50_000, 200_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        deep_breed(&breeder, &parent_a, &parent_b, &children, 200);
        std.mem.doNotOptimizeAway(&children);
    }
    const ns_per_breed = timer.read() / iterations;

    const budget = benchBudget(
        5_000_000, // 5ms debug
        100_000, // 100µs release-safe
        100_000, // 100µs release-fast
    );
    std.debug.print("\n[WP-067] deep_breed 8 children (degraded): {}ns ({d:.2}µs, budget: {}ns, mode={s})\n", .{
        ns_per_breed,
        @as(f64, @floatFromInt(ns_per_breed)) / 1000.0,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_breed < budget);
}

test "benchmark: interpolate_latent" {
    var a: [LATENT_DIM]f32 = undefined;
    var b: [LATENT_DIM]f32 = undefined;
    for (0..LATENT_DIM) |i| {
        a[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(LATENT_DIM));
        b[i] = 1.0 - a[i];
    }

    // Warmup
    for (0..1000) |_| {
        const r = interpolate_latent(&a, &b, 0.5);
        std.mem.doNotOptimizeAway(&r);
    }

    const iterations = benchIterations(100_000, 1_000_000, 5_000_000);
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |iter| {
        const t: f32 = @as(f32, @floatFromInt(iter % 100)) / 100.0;
        const r = interpolate_latent(&a, &b, t);
        std.mem.doNotOptimizeAway(&r);
    }
    const ns_per_interp = timer.read() / iterations;

    const budget = benchBudget(
        50_000, // 50µs debug
        1_000, // 1µs release-safe
        1_000, // 1µs release-fast
    );
    std.debug.print("\n[WP-067] interpolate_latent: {}ns (budget: {}ns, mode={s})\n", .{
        ns_per_interp,
        budget,
        @tagName(builtin.mode),
    });
    try std.testing.expect(ns_per_interp < budget);
}
