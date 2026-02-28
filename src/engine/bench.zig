// DSP Foundation Benchmark Suite
//
// Built for optimization and tuning: shows side-by-side comparisons of
// function variants so you can measure the impact of each optimization.
//
// Usage:
//   zig build test                              -- run all (thresholds informational)
//   zig build test -Doptimize=ReleaseFast       -- run all (thresholds enforced, AC-B1)
//
// Adding benchmarks for a new WP:
//   1. @import the module at the top
//   2. Add a new section with test blocks
//   3. Use run_bench() for throughput, run_compare() for A/B comparisons
const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");
const tables_adaa = @import("tables_adaa.zig");

/// Threshold enforcement only in release builds.
const enforce = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

const WARMUP: usize = 1_000;
const ITERS: usize = 10_000;
const BLOCK: usize = 128;

// ── Benchmark Helpers ────────────────────────────────────────────────

/// Run a block-level benchmark. Returns ns per block (BLOCK iterations).
/// `body_fn` takes an index and returns a value to prevent dead-code elimination.
fn run_bench(comptime body_fn: fn (usize) callconv(.@"inline") f32) u64 {
    // Warmup
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        var acc: f32 = 0;
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            acc += body_fn(j);
        }
        std.mem.doNotOptimizeAway(acc);
    }
    // Measure
    var timer = std.time.Timer.start() catch return 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        var acc: f32 = 0;
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            acc += body_fn(j);
        }
        std.mem.doNotOptimizeAway(acc);
    }
    return timer.read() / ITERS;
}

/// Run a scalar benchmark (per-element doNotOptimizeAway, prevents auto-vectorization).
/// Use for fair A/B comparisons where both sides must be equally constrained.
fn run_bench_scalar(comptime body_fn: fn (usize) callconv(.@"inline") f32) u64 {
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            std.mem.doNotOptimizeAway(body_fn(j));
        }
    }
    var timer = std.time.Timer.start() catch return 0;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            std.mem.doNotOptimizeAway(body_fn(j));
        }
    }
    return timer.read() / ITERS;
}

// Pre-computed input arrays (comptime, not part of measurement)
const sine_phases: [BLOCK]f32 = blk: {
    var p: [BLOCK]f32 = undefined;
    var i: usize = 0;
    while (i < BLOCK) : (i += 1) {
        p[i] = @as(f32, @floatFromInt(i)) / @as(f32, BLOCK);
    }
    break :blk p;
};

const adaa_inputs: [BLOCK]f32 = blk: {
    var p: [BLOCK]f32 = undefined;
    var i: usize = 0;
    while (i < BLOCK) : (i += 1) {
        p[i] = -1.0 + 2.0 * @as(f32, @floatFromInt(i)) / @as(f32, BLOCK);
    }
    break :blk p;
};

// ── WP-001: Sine LUT Variants ────────────────────────────────────────
// Compares: sine_fast (safe, with wrapping) vs sine_lookup (optimized, no wrap)
// Optimizations measured: delta-table interpolation, @floor removal

fn sine_fast_body(j: usize) callconv(.@"inline") f32 {
    return tables.sine_fast(sine_phases[j]);
}

fn sine_lookup_body(j: usize) callconv(.@"inline") f32 {
    return tables.sine_lookup(sine_phases[j]);
}

fn sin_builtin_body(j: usize) callconv(.@"inline") f32 {
    return @sin(sine_phases[j] * 2.0 * std.math.pi);
}

fn midi_freq_body(j: usize) callconv(.@"inline") f32 {
    return tables.MIDI_FREQ[j];
}

test "bench: WP-001 sine variants comparison" {
    const fast_ns = run_bench(sine_fast_body);
    const lookup_ns = run_bench(sine_lookup_body);

    const improvement: f64 = if (fast_ns > 0) (1.0 - @as(f64, @floatFromInt(lookup_ns)) / @as(f64, @floatFromInt(fast_ns))) * 100.0 else 0;

    std.debug.print(
        \\
        \\  [WP-001] Sine LUT — {} lookups/block
        \\  ┌─────────────────────┬──────────┬──────────────┐
        \\  │ Variante            │ ns/block │ Verbesserung │
        \\  ├─────────────────────┼──────────┼──────────────┤
        \\  │ sine_fast (wrap)    │ {:>6}   │ baseline     │
        \\  │ sine_lookup (opt)   │ {:>6}   │ {d:>5.1}%      │
        \\  └─────────────────────┴──────────┴──────────────┘
        \\
    , .{ BLOCK, fast_ns, lookup_ns, -improvement });

    // AC-B1 threshold on the production function (sine_lookup)
    if (enforce) try std.testing.expect(lookup_ns < 200);
}

test "bench: WP-001 sine_lookup vs @sin speedup" {
    const lut_ns = run_bench_scalar(sine_lookup_body);
    const sin_ns = run_bench_scalar(sin_builtin_body);

    const lut_f: f64 = @floatFromInt(lut_ns);
    const sin_f: f64 = @floatFromInt(sin_ns);
    const speedup = if (lut_f > 0) sin_f / lut_f else 999.0;

    std.debug.print(
        \\
        \\  [WP-001] LUT vs @sin — scalar, {} lookups
        \\  ┌───────────────┬──────────┐
        \\  │ Methode       │ ns/block │
        \\  ├───────────────┼──────────┤
        \\  │ sine_lookup   │ {:>6}   │
        \\  │ @sin(f32)     │ {:>6}   │
        \\  │ Speedup       │ {d:>5.1}x  │
        \\  └───────────────┴──────────┘
        \\  Note: LLVM inlines @sin(f32) as polynomial (~15 cycles).
        \\  Realistic speedup on modern x86: 2-3x.
        \\
    , .{ BLOCK, lut_ns, sin_ns, speedup });

    if (enforce) try std.testing.expect(speedup >= 2.0);
}

test "bench: WP-001 MIDI_FREQ 128 lookups [< 100ns]" {
    const ns = run_bench(midi_freq_body);

    std.debug.print("\n  [WP-001] MIDI_FREQ: {}ns / {} lookups (limit: <100ns)\n", .{ ns, BLOCK });
    if (enforce) try std.testing.expect(ns < 100);
}

// ── WP-002: ADAA Antiderivative LUT ──────────────────────────────────

fn adaa_lookup_body(j: usize) callconv(.@"inline") f32 {
    return tables_adaa.adaa_lookup(adaa_inputs[j]);
}

test "bench: WP-002 adaa_lookup 128 lookups [< 500ns]" {
    const ns = run_bench(adaa_lookup_body);

    std.debug.print("\n  [WP-002] adaa_lookup: {}ns / {} lookups (limit: <500ns)\n", .{ ns, BLOCK });
    if (enforce) try std.testing.expect(ns < 500);
}

test "bench: WP-002 ADAA accuracy [max error < 1e-5]" {
    var max_err: f64 = 0;
    var j: usize = 0;
    while (j < tables_adaa.ADAA_TABLE_SIZE) : (j += 1) {
        const x: f64 = -1.0 + 2.0 * @as(f64, @floatFromInt(j)) / @as(f64, tables_adaa.ADAA_TABLE_SIZE - 1);
        const expected: f64 = x * x / 2.0;
        const actual: f64 = @as(f64, tables_adaa.adaa_lookup(@as(f32, @floatCast(x))));
        const err = @abs(expected - actual);
        if (err > max_err) max_err = err;
    }

    std.debug.print("\n  [WP-002] ADAA max error: {e:.2} (limit: <1e-5)\n", .{max_err});
    try std.testing.expect(max_err < 1e-5);
}

// ── Future WPs add benchmarks below ──────────────────────────────────
// WP-003: BLEP correction benchmarks (added when tables_blep.zig lands)
// WP-004: sin_fast_poly, exp_fast vs builtins
// WP-005: SIMD kernel benchmarks (AVX2 vs SSE4 vs Scalar)
// ...
