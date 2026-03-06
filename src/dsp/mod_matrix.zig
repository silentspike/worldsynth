const std = @import("std");

// ── Modulation Matrix (WP-036) ────────────────────────────────────
// 256 preallocated modulation slots. Each slot routes a source value
// to a target parameter with a bipolar or unipolar amount.
// Zero heap allocation — all state is inline.
// Block-based evaluation for SIMD-friendly downstream processing.

pub const MAX_SLOTS: u32 = 256;

pub const ModSlot = struct {
    source_id: u16 = 0,
    target_id: u16 = 0,
    amount: f32 = 0.0,
    bipolar: bool = true,
    active: bool = false,
};

pub const ModMatrix = struct {
    const Self = @This();

    slots: [MAX_SLOTS]ModSlot,
    active_count: u32,

    /// Initialize with all slots inactive.
    pub fn init() Self {
        return .{
            .slots = [_]ModSlot{.{}} ** MAX_SLOTS,
            .active_count = 0,
        };
    }

    /// Add a modulation routing. Returns slot index or null if full.
    pub fn add_slot(self: *Self, source: u16, target: u16, amount: f32, bipolar: bool) ?usize {
        for (&self.slots, 0..) |*slot, idx| {
            if (!slot.active) {
                slot.* = .{
                    .source_id = source,
                    .target_id = target,
                    .amount = amount,
                    .bipolar = bipolar,
                    .active = true,
                };
                self.active_count += 1;
                return idx;
            }
        }
        return null; // Matrix full
    }

    /// Deactivate a slot, making it available for reuse.
    pub fn remove_slot(self: *Self, idx: usize) void {
        if (idx < MAX_SLOTS and self.slots[idx].active) {
            self.slots[idx].active = false;
            self.active_count -= 1;
        }
    }

    /// Apply all active modulation routings.
    /// Reads source values, scales by amount, and accumulates into targets.
    /// Bipolar: target += source * amount
    /// Unipolar: target += (source * amount + 1.0) * 0.5
    pub inline fn process_block(self: *const Self, sources: []const f32, targets: []f32) void {
        if (self.active_count == 0) return;
        for (self.slots) |slot| {
            if (!slot.active) continue;
            const src = sources[slot.source_id];
            var mod_val = src * slot.amount;
            if (!slot.bipolar) {
                mod_val = (mod_val + 1.0) * 0.5;
            }
            targets[slot.target_id] += mod_val;
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AC-1: 256 slots add without malloc, all active" {
    var matrix = ModMatrix.init();
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);

    for (0..MAX_SLOTS) |i| {
        const idx = matrix.add_slot(@intCast(i), @intCast(i), 0.5, true);
        try std.testing.expect(idx != null);
        try std.testing.expectEqual(i, idx.?);
    }
    try std.testing.expectEqual(@as(u32, MAX_SLOTS), matrix.active_count);

    // Verify all slots are active
    for (matrix.slots) |slot| {
        try std.testing.expect(slot.active);
    }
}

test "AC-2: 257th slot returns null" {
    var matrix = ModMatrix.init();
    for (0..MAX_SLOTS) |i| {
        _ = matrix.add_slot(@intCast(i), @intCast(i), 0.5, true);
    }
    try std.testing.expectEqual(@as(u32, MAX_SLOTS), matrix.active_count);

    // 257th must fail
    const overflow = matrix.add_slot(0, 0, 1.0, true);
    try std.testing.expect(overflow == null);
    try std.testing.expectEqual(@as(u32, MAX_SLOTS), matrix.active_count);
}

test "AC-4: process_block routes source to target (bipolar)" {
    var matrix = ModMatrix.init();
    _ = matrix.add_slot(0, 1, 0.5, true); // source 0 → target 1, amount 0.5, bipolar

    var sources = [_]f32{0.0} ** 4;
    var targets = [_]f32{0.0} ** 4;
    sources[0] = 1.0;

    matrix.process_block(&sources, &targets);

    // Bipolar: target[1] += sources[0] * 0.5 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), targets[1], 1e-6);
    // Other targets unchanged
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), targets[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), targets[2], 1e-6);
}

test "AC-4: process_block routes source to target (unipolar)" {
    var matrix = ModMatrix.init();
    _ = matrix.add_slot(0, 1, 0.5, false); // unipolar

    var sources = [_]f32{0.0} ** 4;
    var targets = [_]f32{0.0} ** 4;
    sources[0] = 1.0;

    matrix.process_block(&sources, &targets);

    // Unipolar: target[1] += (1.0 * 0.5 + 1.0) * 0.5 = 0.75
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), targets[1], 1e-6);
}

test "AC-4: bipolar negative amount" {
    var matrix = ModMatrix.init();
    _ = matrix.add_slot(0, 0, -1.0, true);

    var sources = [_]f32{0.0} ** 2;
    var targets = [_]f32{0.0} ** 2;
    sources[0] = 0.8;

    matrix.process_block(&sources, &targets);

    // target[0] += 0.8 * -1.0 = -0.8
    try std.testing.expectApproxEqAbs(@as(f32, -0.8), targets[0], 1e-6);
}

test "AC-4: unipolar with negative source maps to [0, 1]" {
    var matrix = ModMatrix.init();
    _ = matrix.add_slot(0, 0, 1.0, false); // unipolar, amount=1.0

    var sources = [_]f32{0.0} ** 2;
    var targets = [_]f32{0.0} ** 2;

    // Source = -1.0 → mod_val = -1.0 * 1.0 = -1.0 → (−1.0 + 1.0) * 0.5 = 0.0
    sources[0] = -1.0;
    matrix.process_block(&sources, &targets);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), targets[0], 1e-6);

    // Source = 0.0 → mod_val = 0.0 → (0.0 + 1.0) * 0.5 = 0.5
    @memset(&targets, 0.0);
    sources[0] = 0.0;
    matrix.process_block(&sources, &targets);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), targets[0], 1e-6);

    // Source = 1.0 → mod_val = 1.0 → (1.0 + 1.0) * 0.5 = 1.0
    @memset(&targets, 0.0);
    sources[0] = 1.0;
    matrix.process_block(&sources, &targets);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), targets[0], 1e-6);
}

test "AC-N1: remove makes slot reusable" {
    var matrix = ModMatrix.init();

    const idx = matrix.add_slot(0, 0, 1.0, true).?;
    try std.testing.expectEqual(@as(u32, 1), matrix.active_count);

    matrix.remove_slot(idx);
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);
    try std.testing.expect(!matrix.slots[idx].active);

    // Same slot is reusable
    const idx2 = matrix.add_slot(1, 1, 0.5, false).?;
    try std.testing.expectEqual(idx, idx2);
    try std.testing.expectEqual(@as(u32, 1), matrix.active_count);
    try std.testing.expect(matrix.slots[idx2].active);
    try std.testing.expectEqual(@as(u16, 1), matrix.slots[idx2].source_id);
}

test "early out when no active slots" {
    var matrix = ModMatrix.init();
    var sources = [_]f32{1.0} ** 4;
    var targets = [_]f32{0.0} ** 4;

    matrix.process_block(&sources, &targets);

    // All targets must remain zero
    for (targets) |t| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), t, 1e-6);
    }
}

test "multiple slots accumulate on same target" {
    var matrix = ModMatrix.init();
    _ = matrix.add_slot(0, 0, 0.3, true); // source 0 → target 0
    _ = matrix.add_slot(1, 0, 0.2, true); // source 1 → target 0

    var sources = [_]f32{0.0} ** 4;
    var targets = [_]f32{0.0} ** 4;
    sources[0] = 1.0;
    sources[1] = 1.0;

    matrix.process_block(&sources, &targets);

    // target[0] = 1.0*0.3 + 1.0*0.2 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), targets[0], 1e-6);
}

test "remove_slot bounds check" {
    var matrix = ModMatrix.init();

    // Remove on empty matrix — no crash
    matrix.remove_slot(0);
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);

    // Remove out of bounds — no crash
    matrix.remove_slot(MAX_SLOTS);
    matrix.remove_slot(MAX_SLOTS + 100);
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);
}

test "remove_slot idempotent" {
    var matrix = ModMatrix.init();
    const idx = matrix.add_slot(0, 0, 1.0, true).?;
    try std.testing.expectEqual(@as(u32, 1), matrix.active_count);

    matrix.remove_slot(idx);
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);

    // Double remove — no underflow
    matrix.remove_slot(idx);
    try std.testing.expectEqual(@as(u32, 0), matrix.active_count);
}

// ── Benchmarks ──────────────────────────────────────────────────────

test "benchmark: mod_matrix 128 slots" {
    var matrix = ModMatrix.init();
    for (0..128) |i| {
        _ = matrix.add_slot(@intCast(i), @intCast(i), 0.5, true);
    }

    var sources: [MAX_SLOTS]f32 = undefined;
    for (&sources, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / @as(f32, MAX_SLOTS);
    }
    var targets: [MAX_SLOTS]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        @memset(&targets, 0.0);
        matrix.process_block(&sources, &targets);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        @memset(&targets, 0.0);
        matrix.process_block(&sources, &targets);
        std.mem.doNotOptimizeAway(&targets);
    }
    const ns_per_block = timer.read() / iterations;

    const budget_ns: u64 = 100_000;
    std.debug.print("\n[WP-036] mod_matrix 128 slots: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: mod_matrix 256 slots (worst-case)" {
    var matrix = ModMatrix.init();
    for (0..MAX_SLOTS) |i| {
        _ = matrix.add_slot(@intCast(i), @intCast(i), 0.5, true);
    }

    var sources: [MAX_SLOTS]f32 = undefined;
    for (&sources, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / @as(f32, MAX_SLOTS);
    }
    var targets: [MAX_SLOTS]f32 = undefined;

    // Warmup
    for (0..1000) |_| {
        @memset(&targets, 0.0);
        matrix.process_block(&sources, &targets);
    }

    const iterations: u64 = 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        @memset(&targets, 0.0);
        matrix.process_block(&sources, &targets);
        std.mem.doNotOptimizeAway(&targets);
    }
    const ns_per_block = timer.read() / iterations;

    const budget_ns: u64 = 200_000;
    std.debug.print("\n[WP-036] mod_matrix 256 slots: {}ns/block (budget: {}ns)\n", .{ ns_per_block, budget_ns });
    try std.testing.expect(ns_per_block < budget_ns);
}

test "benchmark: mod_matrix scaling 32/64/128/256" {
    const slot_counts = [_]u32{ 32, 64, 128, 256 };
    var ns_results: [4]u64 = undefined;

    for (slot_counts, 0..) |n, ci| {
        var matrix = ModMatrix.init();
        for (0..n) |i| {
            _ = matrix.add_slot(@intCast(i % MAX_SLOTS), @intCast(i % MAX_SLOTS), 0.5, true);
        }

        var sources: [MAX_SLOTS]f32 = undefined;
        for (&sources, 0..) |*s, i| {
            s.* = @as(f32, @floatFromInt(i)) / @as(f32, MAX_SLOTS);
        }
        var targets: [MAX_SLOTS]f32 = undefined;

        // Warmup
        for (0..500) |_| {
            @memset(&targets, 0.0);
            matrix.process_block(&sources, &targets);
        }

        const iterations: u64 = 200_000;
        var timer = std.time.Timer.start() catch unreachable;
        for (0..iterations) |_| {
            @memset(&targets, 0.0);
            matrix.process_block(&sources, &targets);
            std.mem.doNotOptimizeAway(&targets);
        }
        ns_results[ci] = timer.read() / iterations;
    }

    std.debug.print("\n[WP-036] mod_matrix scaling:\n", .{});
    std.debug.print("  | Slots |  ns/block |  ns/slot |\n", .{});
    std.debug.print("  |-------|----------|----------|\n", .{});
    for (slot_counts, ns_results) |n, ns| {
        std.debug.print("  |  {:>4} | {:>8} | {:>8} |\n", .{ n, ns, ns / n });
    }

    // Check linearity: 256-slot cost should be < 3x of 128-slot cost
    // (perfect linear would be 2x, allow headroom for branch overhead)
    if (ns_results[2] > 0) {
        const ratio = @as(f64, @floatFromInt(ns_results[3])) / @as(f64, @floatFromInt(ns_results[2]));
        std.debug.print("  256/128 ratio: {d:.2}x (linear=2.0x, threshold=3.0x)\n", .{ratio});
        try std.testing.expect(ratio < 3.0);
    }
}
