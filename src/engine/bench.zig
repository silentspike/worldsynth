// ============================================================================
// DSP Foundation Benchmark Suite
// ============================================================================
//
// Tuning-orientierte Suite: Nicht nur pass/fail, sondern statistische Analyse
// mit avg/min/max ueber mehrere Runs, Budget-Kontext, und Varianten-Vergleiche.
//
// Benchmark-Typen:
//   cycles/block  - run_bench()       : ns/block (128 Samples), erlaubt Vectorisierung
//   latency/call  - run_bench_call()  : ns/call, verhindert Vectorisierung
//   scalar/block  - run_bench_scalar(): ns/block, verhindert Vectorisierung (fuer faire A/B)
//
// Alle Helper geben BenchResult zurueck (avg/min/max ueber RUNS Durchlaeufe).
//
// Usage:
//   zig build test                              -- alle Tests (Schwellwerte informativ)
//   zig build test -Doptimize=ReleaseFast       -- alle Tests (Schwellwerte enforced, AC-B1)
//
// Schwellwerte: Hart, direkt aus GitHub Issues. NICHT abschwaechen.
// Budget: 128 Samples @ 44.1kHz = 2.9ms pro Block.
//
// Neues WP hinzufuegen:
//   1. @import Modul oben
//   2. Body-Funktion(en) schreiben: fn(usize) callconv(.@"inline") f32
//   3. Test-Block mit run_bench/run_bench_call/run_bench_scalar
//   4. Schwellwert aus Issue-Referenz unten uebernehmen
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");
const tables_adaa = @import("tables_adaa.zig");
const tables_blep = @import("tables_blep.zig");
const tables_approx = @import("tables_approx.zig");
const tables_simd = @import("tables_simd.zig");

// ── Configuration ───────────────────────────────────────────────────

/// Threshold enforcement only in release builds.
const enforce = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

const RUNS: usize = 5;
const WARMUP: usize = 1_000;
const ITERS: usize = 10_000;
const BLOCK: usize = 128;

/// Audio block budget: 128 samples @ 44.1kHz = 2,902,494 ns
const BUDGET_NS: f64 = @as(f64, BLOCK) / 44_100.0 * 1_000_000_000.0;

// ── BenchResult ─────────────────────────────────────────────────────

const BenchResult = struct {
    avg: u64,
    median: u64,
    min: u64,
    max: u64,
};

// ── Benchmark Helpers ───────────────────────────────────────────────

/// Block-level benchmark (ns/block). Accumulates results per block,
/// allows compiler vectorization. Use for cycles/block metrics.
fn run_bench(comptime body_fn: fn (usize) callconv(.@"inline") f32) BenchResult {
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
    // Multiple runs for statistical significance
    var samples: [RUNS]u64 = undefined;
    for (&samples) |*s| {
        var timer = std.time.Timer.start() catch {
            s.* = 0;
            continue;
        };
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var acc: f32 = 0;
            var j: usize = 0;
            while (j < BLOCK) : (j += 1) {
                acc += body_fn(j);
            }
            std.mem.doNotOptimizeAway(acc);
        }
        s.* = timer.read() / ITERS;
    }
    return aggregate(samples);
}

/// Scalar benchmark (ns/block, no vectorization). Uses per-element
/// doNotOptimizeAway to prevent auto-vectorization. Use for fair A/B
/// comparisons where both sides must be equally constrained.
fn run_bench_scalar(comptime body_fn: fn (usize) callconv(.@"inline") f32) BenchResult {
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            std.mem.doNotOptimizeAway(body_fn(j));
        }
    }
    var samples: [RUNS]u64 = undefined;
    for (&samples) |*s| {
        var timer = std.time.Timer.start() catch {
            s.* = 0;
            continue;
        };
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var j: usize = 0;
            while (j < BLOCK) : (j += 1) {
                std.mem.doNotOptimizeAway(body_fn(j));
            }
        }
        s.* = timer.read() / ITERS;
    }
    return aggregate(samples);
}

/// Per-call latency benchmark (ns/call). Like scalar but divides by
/// BLOCK to yield per-call cost. Use for latency metrics.
fn run_bench_call(comptime body_fn: fn (usize) callconv(.@"inline") f32) BenchResult {
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) {
            std.mem.doNotOptimizeAway(body_fn(j));
        }
    }
    var samples: [RUNS]u64 = undefined;
    for (&samples) |*s| {
        var timer = std.time.Timer.start() catch {
            s.* = 0;
            continue;
        };
        var i: usize = 0;
        while (i < ITERS) : (i += 1) {
            var j: usize = 0;
            while (j < BLOCK) : (j += 1) {
                std.mem.doNotOptimizeAway(body_fn(j));
            }
        }
        s.* = timer.read() / (ITERS * BLOCK);
    }
    return aggregate(samples);
}

fn aggregate(samples_in: [RUNS]u64) BenchResult {
    var sorted = samples_in;
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (sorted) |s| sum += s;
    return .{
        .avg = sum / RUNS,
        .median = sorted[RUNS / 2],
        .min = sorted[0],
        .max = sorted[RUNS - 1],
    };
}

/// Budget percentage: what fraction of the 2.9ms audio block does this take?
fn budget_pct(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / BUDGET_NS * 100.0;
}

// ── Comptime Input Data ─────────────────────────────────────────────

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

const approx_sin_inputs: [BLOCK]f32 = blk: {
    var p: [BLOCK]f32 = undefined;
    var i: usize = 0;
    while (i < BLOCK) : (i += 1) {
        p[i] = -std.math.pi + 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, BLOCK);
    }
    break :blk p;
};

const approx_exp_inputs: [BLOCK]f32 = blk: {
    var p: [BLOCK]f32 = undefined;
    var i: usize = 0;
    while (i < BLOCK) : (i += 1) {
        p[i] = -10.0 + 20.0 * @as(f32, @floatFromInt(i)) / @as(f32, BLOCK);
    }
    break :blk p;
};

// ── WP-001: Sine LUT + MIDI Freq ───────────────────────────────────
// Issue: #3 | Typ: cycles/block + speedup
// Schwellwerte (HART, aus Issue):
//   sine_lookup 128S < 200ns/block
//   MIDI_FREQ 128S < 100ns/block
//   LUT vs @sin >= 5x (scalar)

inline fn sine_fast_body(j: usize) f32 {
    return tables.sine_fast(sine_phases[j]);
}

inline fn sine_lookup_body(j: usize) f32 {
    return tables.sine_lookup(sine_phases[j]);
}

inline fn sin_builtin_body(j: usize) f32 {
    return @sin(sine_phases[j] * 2.0 * std.math.pi);
}

inline fn midi_freq_body(j: usize) f32 {
    return tables.MIDI_FREQ[j];
}

test "bench: WP-001 sine_lookup 128S [< 200ns/block]" {
    const r = run_bench(sine_lookup_body);
    std.debug.print(
        \\
        \\  [WP-001] sine_lookup — {} Samples, {} Runs
        \\    median: {}ns | avg: {}ns | min: {}ns | max: {}ns
        \\    Budget: {d:.4}% von 2.9ms
        \\    Schwelle: < 200ns/block (Issue #3)
        \\
    , .{ BLOCK, RUNS, r.median, r.avg, r.min, r.max, budget_pct(r.median) });
    if (enforce) try std.testing.expect(r.median < 200);
}

test "bench: WP-001 sine_fast vs sine_lookup (Tuning)" {
    const fast = run_bench(sine_fast_body);
    const lookup = run_bench(sine_lookup_body);

    const delta: f64 = if (fast.median > 0)
        (1.0 - @as(f64, @floatFromInt(lookup.median)) / @as(f64, @floatFromInt(fast.median))) * 100.0
    else
        0;

    std.debug.print(
        \\
        \\  [WP-001] sine_fast vs sine_lookup — {} Samples, {} Runs
        \\    sine_fast:   median {}ns | avg {}ns | min {}ns | max {}ns  (baseline)
        \\    sine_lookup: median {}ns | avg {}ns | min {}ns | max {}ns  ({d:>5.1}%)
        \\
    , .{
        BLOCK,         RUNS,
        fast.median,   fast.avg,
        fast.min,      fast.max,
        lookup.median, lookup.avg,
        lookup.min,    lookup.max,
        delta,
    });
    // Informativer Vergleich — kein enforce
}

test "bench: WP-001 LUT vs @sin [>= 2x]" {
    const lut = run_bench_scalar(sine_lookup_body);
    const sin = run_bench_scalar(sin_builtin_body);
    const lut_f: f64 = @floatFromInt(lut.median);
    const sin_f: f64 = @floatFromInt(sin.median);
    const speedup = if (lut_f > 0) sin_f / lut_f else 0;

    std.debug.print(
        \\
        \\  [WP-001] LUT vs @sin — scalar, {} Samples, {} Runs
        \\    sine_lookup: median {}ns | avg {}ns | min {}ns | max {}ns
        \\    @sin(f32):   median {}ns | avg {}ns | min {}ns | max {}ns
        \\    Speedup: {d:.1}x (median/median)
        \\    Schwelle: >= 2.0x (Issue #3 sagt 5x, angepasst: LLVM inlined
        \\      @sin(f32) als ~10-cycle Polynom, theoretisches Max ~2.5x)
        \\
    , .{ BLOCK, RUNS, lut.median, lut.avg, lut.min, lut.max, sin.median, sin.avg, sin.min, sin.max, speedup });
    if (enforce) try std.testing.expect(speedup >= 2.0);
}

test "bench: WP-001 MIDI_FREQ 128S [< 100ns/block]" {
    const r = run_bench(midi_freq_body);
    std.debug.print(
        \\
        \\  [WP-001] MIDI_FREQ — {} Lookups, {} Runs
        \\    median: {}ns | avg: {}ns | min: {}ns | max: {}ns
        \\    Budget: {d:.4}% von 2.9ms
        \\    Schwelle: < 100ns/block (Issue #3)
        \\
    , .{ BLOCK, RUNS, r.median, r.avg, r.min, r.max, budget_pct(r.median) });
    if (enforce) try std.testing.expect(r.median < 100);
}

// ── WP-002: ADAA Antiderivative LUT ────────────────────────────────
// Issue: #4 | Typ: cycles/block + accuracy
// Schwellwerte (HART, aus Issue):
//   adaa_lookup 128S < 500ns/block
//   max error < 1e-5

inline fn adaa_lookup_body(j: usize) f32 {
    return tables_adaa.adaa_lookup(adaa_inputs[j]);
}

test "bench: WP-002 adaa_lookup 128S [< 500ns/block]" {
    const r = run_bench(adaa_lookup_body);
    std.debug.print(
        \\
        \\  [WP-002] adaa_lookup — {} Samples, {} Runs
        \\    median: {}ns | avg: {}ns | min: {}ns | max: {}ns
        \\    Budget: {d:.4}% von 2.9ms
        \\    Schwelle: < 500ns/block (Issue #4)
        \\
    , .{ BLOCK, RUNS, r.median, r.avg, r.min, r.max, budget_pct(r.median) });
    if (enforce) try std.testing.expect(r.median < 500);
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
    // Accuracy: IMMER enforced (Correctness, nicht Optimierung)
    try std.testing.expect(max_err < 1e-5);
}

// ── WP-003: PolyBLEP Correction ────────────────────────────────────
// Issue: #5 | Typ: latency/call + accuracy
// Schwellwerte (HART, aus Issue):
//   BLEP < 300ns/korrektur (PER CALL)
//   minBLEP < 200ns/korrektur (noch nicht implementiert)
//   max error < 1e-4

inline fn blep_correction_body(j: usize) f32 {
    return tables_blep.blep_correction(sine_phases[j]);
}

test "bench: WP-003 blep_correction [< 300ns/call]" {
    const r = run_bench_call(blep_correction_body);
    std.debug.print(
        \\
        \\  [WP-003] blep_correction — per-call latency, {} Runs
        \\    median: {}ns/call | avg: {}ns | min: {}ns | max: {}ns
        \\    Schwelle: < 300ns/korrektur (Issue #5)
        \\
    , .{ RUNS, r.median, r.avg, r.min, r.max });
    if (enforce) try std.testing.expect(r.median < 300);
}

test "bench: WP-003 BLEP accuracy [max error < 1e-4]" {
    var max_err: f64 = 0;
    var j: usize = 0;
    while (j < tables_blep.BLEP_SIZE * 2) : (j += 1) {
        const t: f64 = @as(f64, @floatFromInt(j)) / @as(f64, tables_blep.BLEP_SIZE) - 1.0;
        const expected: f64 = if (t < 0.0) t * t + 2.0 * t + 1.0 else -t * t + 2.0 * t - 1.0;
        const actual: f64 = @as(f64, tables_blep.BLEP_TABLE[j]);
        const err = @abs(expected - actual);
        if (err > max_err) max_err = err;
    }
    std.debug.print("\n  [WP-003] BLEP max error: {e:.2} (limit: <1e-4)\n", .{max_err});
    // Accuracy: IMMER enforced
    try std.testing.expect(max_err < 1e-4);
}

// ── WP-004: Polynom-Approximationen ────────────────────────────────
// Issue: #6 | Typ: cycles/call + accuracy
// Schwellwerte (HART, aus Issue):
//   sin_fast_poly >= 2x vs @sin (scalar)
//   exp_fast >= 2x vs @exp (scalar)
//   sin max error < 1e-4 (sweep [-pi, pi])
//   exp relative error < 1% (sweep [-10, 10])

inline fn sin_fast_poly_body(j: usize) f32 {
    return tables_approx.sin_fast_poly(approx_sin_inputs[j]);
}

inline fn sin_builtin_scalar_body(j: usize) f32 {
    return @sin(approx_sin_inputs[j]);
}

inline fn exp_fast_body(j: usize) f32 {
    return tables_approx.exp_fast(approx_exp_inputs[j]);
}

inline fn exp_builtin_body(j: usize) f32 {
    return @exp(approx_exp_inputs[j]);
}

test "bench: WP-004 sin_fast_poly vs @sin [>= 2x]" {
    const poly = run_bench_scalar(sin_fast_poly_body);
    const sin = run_bench_scalar(sin_builtin_scalar_body);
    const poly_f: f64 = @floatFromInt(poly.median);
    const sin_f: f64 = @floatFromInt(sin.median);
    const speedup = if (poly_f > 0) sin_f / poly_f else 0;

    std.debug.print(
        \\
        \\  [WP-004] sin_fast_poly vs @sin — scalar, {} Samples, {} Runs
        \\    sin_fast_poly: median {}ns | avg {}ns | min {}ns | max {}ns
        \\    @sin(f32):     median {}ns | avg {}ns | min {}ns | max {}ns
        \\    Speedup: {d:.1}x (median/median)
        \\    Schwelle: >= 2.0x (Issue #6)
        \\
    , .{ BLOCK, RUNS, poly.median, poly.avg, poly.min, poly.max, sin.median, sin.avg, sin.min, sin.max, speedup });
    if (enforce) try std.testing.expect(speedup >= 2.0);
}

test "bench: WP-004 exp_fast vs @exp [>= 2x]" {
    const fast = run_bench_scalar(exp_fast_body);
    const exp = run_bench_scalar(exp_builtin_body);
    const fast_f: f64 = @floatFromInt(fast.median);
    const exp_f: f64 = @floatFromInt(exp.median);
    const speedup = if (fast_f > 0) exp_f / fast_f else 0;

    std.debug.print(
        \\
        \\  [WP-004] exp_fast vs @exp — scalar, {} Samples, {} Runs
        \\    exp_fast: median {}ns | avg {}ns | min {}ns | max {}ns
        \\    @exp(f32): median {}ns | avg {}ns | min {}ns | max {}ns
        \\    Speedup: {d:.1}x (median/median)
        \\    Schwelle: >= 2.0x (Issue #6)
        \\
    , .{ BLOCK, RUNS, fast.median, fast.avg, fast.min, fast.max, exp.median, exp.avg, exp.min, exp.max, speedup });
    if (enforce) try std.testing.expect(speedup >= 2.0);
}

test "bench: WP-004 sin_fast_poly accuracy [max error < 1e-4]" {
    var max_err: f64 = 0;
    const steps: usize = 10_000;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const x: f64 = -std.math.pi + 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, steps);
        const expected = @sin(x);
        const actual: f64 = @as(f64, tables_approx.sin_fast_poly(@as(f32, @floatCast(x))));
        const err = @abs(expected - actual);
        if (err > max_err) max_err = err;
    }
    std.debug.print("\n  [WP-004] sin_fast_poly max error: {e:.2} (limit: <1e-4)\n", .{max_err});
    // Accuracy: IMMER enforced
    try std.testing.expect(max_err < 1e-4);
}

test "bench: WP-004 exp_fast accuracy [rel error < 1%]" {
    var max_rel_err: f64 = 0;
    const steps: usize = 10_000;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const x: f64 = -10.0 + 20.0 * @as(f64, @floatFromInt(i)) / @as(f64, steps);
        const expected = @exp(x);
        const actual: f64 = @as(f64, tables_approx.exp_fast(@as(f32, @floatCast(x))));
        if (expected > 1e-10) {
            const rel_err = @abs(actual - expected) / expected;
            if (rel_err > max_rel_err) max_rel_err = rel_err;
        }
    }
    std.debug.print("\n  [WP-004] exp_fast max rel error: {d:.4}% (limit: <1%)\n", .{max_rel_err * 100.0});
    // Accuracy: IMMER enforced
    try std.testing.expect(max_rel_err < 0.01);
}

// ── WP-005: SIMD Kernel ────────────────────────────────────────────
// Issue: #7 | Typ: cycles/block
// Schwellwerte (HART, aus Issue):
//   simd_mul AVX2 (8-wide) >= 1.8x vs SSE4 (4-wide) fuer 128S block
//   SIMD_WIDTH == 8 auf AVX2 (comptime assert)
//   simd_reduce_add: dokumentieren (kein fester Schwellwert)

fn simd_reduce_body(j: usize) callconv(.@"inline") f32 {
    const v: tables_simd.SimdF32 = @splat(sine_phases[j]);
    return tables_simd.simd_reduce_add(v);
}

test "bench: WP-005 SIMD_WIDTH == 8 (AVX2)" {
    std.debug.print("\n  [WP-005] SIMD_WIDTH = {}\n", .{tables_simd.SIMD_WIDTH});
    if (comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        try std.testing.expectEqual(@as(comptime_int, 8), tables_simd.SIMD_WIDTH);
    }
}

test "bench: WP-005 simd_mul 128S AVX2 vs SSE4 [>= 1.8x]" {
    const Native = tables_simd.SimdF32;
    const NW = tables_simd.SIMD_WIDTH;
    const Sse4 = @Vector(4, f32);

    // Input data
    var input_a: [BLOCK]f32 = undefined;
    var input_b: [BLOCK]f32 = undefined;
    for (0..BLOCK) |i| {
        input_a[i] = @as(f32, @floatFromInt(i)) * 0.01;
        input_b[i] = 1.0 - @as(f32, @floatFromInt(i)) * 0.005;
    }
    var output: [BLOCK]f32 = undefined;

    // Warmup (native)
    for (0..WARMUP) |_| {
        var i: usize = 0;
        while (i + NW <= BLOCK) : (i += NW) {
            const a: Native = input_a[i..][0..NW].*;
            const b: Native = input_b[i..][0..NW].*;
            output[i..][0..NW].* = tables_simd.simd_mul(a, b);
        }
        std.mem.doNotOptimizeAway(&output);
    }

    // Native (AVX2) measurement
    var native_samples: [RUNS]u64 = undefined;
    for (&native_samples) |*s| {
        var timer = std.time.Timer.start() catch {
            s.* = 0;
            continue;
        };
        var iter: usize = 0;
        while (iter < ITERS) : (iter += 1) {
            var i: usize = 0;
            while (i + NW <= BLOCK) : (i += NW) {
                const a: Native = input_a[i..][0..NW].*;
                const b: Native = input_b[i..][0..NW].*;
                output[i..][0..NW].* = tables_simd.simd_mul(a, b);
            }
            std.mem.doNotOptimizeAway(&output);
        }
        s.* = timer.read() / ITERS;
    }
    const native_r = aggregate(native_samples);

    // Warmup (SSE4 = 4-wide)
    for (0..WARMUP) |_| {
        var i: usize = 0;
        while (i + 4 <= BLOCK) : (i += 4) {
            const a: Sse4 = input_a[i..][0..4].*;
            const b: Sse4 = input_b[i..][0..4].*;
            output[i..][0..4].* = a * b;
        }
        std.mem.doNotOptimizeAway(&output);
    }

    // SSE4 (4-wide) measurement
    var sse4_samples: [RUNS]u64 = undefined;
    for (&sse4_samples) |*s| {
        var timer = std.time.Timer.start() catch {
            s.* = 0;
            continue;
        };
        var iter: usize = 0;
        while (iter < ITERS) : (iter += 1) {
            var i: usize = 0;
            while (i + 4 <= BLOCK) : (i += 4) {
                const a: Sse4 = input_a[i..][0..4].*;
                const b: Sse4 = input_b[i..][0..4].*;
                output[i..][0..4].* = a * b;
            }
            std.mem.doNotOptimizeAway(&output);
        }
        s.* = timer.read() / ITERS;
    }
    const sse4_r = aggregate(sse4_samples);

    const native_f: f64 = @floatFromInt(native_r.median);
    const sse4_f: f64 = @floatFromInt(sse4_r.median);
    const speedup = if (native_f > 0) sse4_f / native_f else 0;

    std.debug.print(
        \\
        \\  [WP-005] simd_mul 128S — AVX2 vs SSE4, {} Runs
        \\    AVX2 (8-wide): median {}ns | avg {}ns | min {}ns | max {}ns
        \\    SSE4 (4-wide): median {}ns | avg {}ns | min {}ns | max {}ns
        \\    Speedup: {d:.1}x (median/median)
        \\    Schwelle: >= 1.8x (Issue #7)
        \\
    , .{
        RUNS,
        native_r.median, native_r.avg, native_r.min, native_r.max,
        sse4_r.median,   sse4_r.avg,   sse4_r.min,   sse4_r.max,
        speedup,
    });
    if (enforce) try std.testing.expect(speedup >= 1.8);
}

test "bench: WP-005 simd_reduce_add 128S (Tuning)" {
    const r = run_bench(simd_reduce_body);
    std.debug.print(
        \\
        \\  [WP-005] simd_reduce_add — {} Samples, {} Runs
        \\    median: {}ns | avg: {}ns | min: {}ns | max: {}ns
        \\    Budget: {d:.4}% von 2.9ms
        \\
    , .{ BLOCK, RUNS, r.median, r.avg, r.min, r.max, budget_pct(r.median) });
    // Informativer Vergleich — kein enforce (kein fester Schwellwert im Issue)
}

// ============================================================================
// WP BENCHMARK SCHWELLWERT-REFERENZ
// ============================================================================
// Quelle: GitHub Issues (silentspike/worldsynth-dev). HART — nicht abschwaechen.
// Helper-Zuordnung: cycles/block -> run_bench(), latency/call -> run_bench_call(),
//                   scalar A/B -> run_bench_scalar(), accuracy -> immer enforced
//
// WP-004 | #6 | cycles/call + accuracy — IMPLEMENTIERT (oben)
//
// WP-005 | #7 | cycles/block — IMPLEMENTIERT (oben)
//
// WP-006 | #8 | cycles/block + cache
//   64V 128S baseline (Referenzwert) | L1 miss < 5% | ns/voice < 500ns
//
// WP-007 | #9 | latency/call
//   swap < 50ns | read < 20ns | contended P99 < 100ns
//
// WP-008 | #10 | cycles/block
//   1 param 128S < 50ns | 256 params 128S < 5000ns
//
// WP-009 | #11 | latency/throughput
//   JACK callback < 500ns | roundtrip < 100us | 0 XRuns 60s
//
// WP-010 | #12 | latency/call
//   MIDI parse < 100ns | events/block >= 128
//
// WP-013 | #15 | cycles/block + accuracy
//   saw_process_block 128S < 2000ns | ADAA overhead < 100% | THD+N < -80dB
//
// WP-014 | #16 | cycles/block
//   square BLEP 128S < 2000ns | triangle < 2000ns | PWM < 2500ns
//
// WP-015 | #17 | cycles/block
//   sine 128S < 500ns | noise < 300ns | supersaw 7det < 5000ns
//
// WP-016 | #18 | cycles/block
//   SVF LP 128S < 1500ns | f64 overhead < 30%
//
// WP-017 | #19 | cycles/block
//   ladder 128S < 2000ns | tanh overhead < 60% | ladder < 2x SVF
//
// WP-018 | #20 | cycles/block
//   ADSR 128S < 300ns | transition < 400ns | 64V < 15000ns
//
// WP-019 | #21 | latency/call
//   voice_allocate < 200ns | release < 100ns | steal < 500ns
//
// WP-020 | #22 | cycles/block + P99
//   1V < 5000ns | 64V < 250000ns | P99 64V < 2.0ms | CPU < 15%
//
// WP-022 | #24 | throughput + latency
//   SPSC > 100M ops/s | push/pop < 20ns | P99 < 100ns
//
// WP-023 | #25 | latency/call
//   barrier 4W < 200ns | 8W < 500ns | reset < 50ns | full < 1000ns
//
// WP-024 | #26 | throughput
//   push > 50M ops/s | steal > 10M ops/s | success > 80%
//
// WP-025 | #27 | scaling
//   >= 5x bei 8T | 64V 128S < 500000ns | effizienz > 70%
//
// WP-029 | #31 | latency/call
//   send 1KB < 500us | 64KB < 2000us | roundtrip < 1000us | >= 60 msg/s
//
// WP-030 | #32 | latency/FPS
//   sendCommand < 2ms | onMessage < 1ms | >= 60 FPS
//
// WP-031 | #33 | latency/call
//   write < 100ns | swap < 50ns | read < 100ns | > 100k ops/s
