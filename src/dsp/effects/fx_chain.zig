const std = @import("std");
const builtin = @import("builtin");

// -- FX-Chain Routing (WP-049) --------------------------------------------
// Insert chain (8 slots, serial) + Send/Return buses (4, parallel).
// Function-pointer dispatch — effect instances are caller-managed.
// Routing only: configuration + dispatch + buffer management.
// Zero heap allocation.

pub const BLOCK_SIZE: u32 = 128;
pub const MAX_INSERTS: u32 = 8;
pub const MAX_SENDS: u32 = 4;

pub const FxType = enum(u4) {
    none,
    reverb,
    delay,
    chorus,
    distortion,
    eq,
    stereo_widener,
    compressor,
};

/// Unified effect processing callback.
/// ctx: opaque pointer to effect state (caller-managed).
/// out: output buffer (128 samples).
/// in_buf: input buffer (128 samples).
pub const ProcessFn = *const fn (ctx: *anyopaque, out: *[BLOCK_SIZE]f32, in_buf: *const [BLOCK_SIZE]f32) void;

pub const FxSlot = struct {
    fx_type: FxType = .none,
    bypass: bool = true,
    mix: f32 = 1.0,
    process_fn: ?ProcessFn = null,
    ctx: ?*anyopaque = null,
};

pub const SendBus = struct {
    fx_type: FxType = .none,
    send_amount: f32 = 0.0,
    active: bool = false,
    process_fn: ?ProcessFn = null,
    ctx: ?*anyopaque = null,
};

pub const FxChain = struct {
    const Self = @This();

    insert_slots: [MAX_INSERTS]FxSlot,
    send_buses: [MAX_SENDS]SendBus,
    slot_order: [MAX_INSERTS]u8,

    pub fn init() Self {
        return .{
            .insert_slots = [_]FxSlot{.{}} ** MAX_INSERTS,
            .send_buses = [_]SendBus{.{}} ** MAX_SENDS,
            .slot_order = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
        };
    }

    /// Configure an insert slot with effect type and processing callback.
    pub fn set_insert(
        self: *Self,
        slot_idx: u32,
        fx_type: FxType,
        process_fn: ProcessFn,
        ctx: *anyopaque,
    ) void {
        if (slot_idx >= MAX_INSERTS) return;
        self.insert_slots[slot_idx] = .{
            .fx_type = fx_type,
            .bypass = false,
            .mix = 1.0,
            .process_fn = process_fn,
            .ctx = ctx,
        };
    }

    /// Configure a send bus with effect type, amount, and callback.
    pub fn set_send(
        self: *Self,
        bus_idx: u32,
        fx_type: FxType,
        amount: f32,
        process_fn: ProcessFn,
        ctx: *anyopaque,
    ) void {
        if (bus_idx >= MAX_SENDS) return;
        self.send_buses[bus_idx] = .{
            .fx_type = fx_type,
            .send_amount = std.math.clamp(amount, 0.0, 1.0),
            .active = true,
            .process_fn = process_fn,
            .ctx = ctx,
        };
    }

    /// Set bypass state for a single insert slot.
    pub fn bypass_slot(self: *Self, slot_idx: u32, bypass: bool) void {
        if (slot_idx >= MAX_INSERTS) return;
        self.insert_slots[slot_idx].bypass = bypass;
    }

    /// Set mix (dry/wet) for a single insert slot.
    pub fn set_mix(self: *Self, slot_idx: u32, mix: f32) void {
        if (slot_idx >= MAX_INSERTS) return;
        self.insert_slots[slot_idx].mix = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Bypass all inserts and deactivate all sends.
    pub fn bypass_all(self: *Self) void {
        for (&self.insert_slots) |*slot| slot.bypass = true;
        for (&self.send_buses) |*bus| bus.active = false;
    }

    /// Set insert processing order.
    pub fn reorder(self: *Self, new_order: [MAX_INSERTS]u8) void {
        self.slot_order = new_order;
    }

    /// Reset a single insert slot to none/bypassed.
    pub fn reset_slot(self: *Self, slot_idx: u32) void {
        if (slot_idx >= MAX_INSERTS) return;
        self.insert_slots[slot_idx] = .{};
    }

    /// Process a block through the full FX chain.
    /// Signal flows: Input → Inserts (serial) → + Send Returns → Output.
    pub fn process_block(
        self: *Self,
        out: *[BLOCK_SIZE]f32,
        in_buf: *const [BLOCK_SIZE]f32,
    ) void {
        var buf: [BLOCK_SIZE]f32 = in_buf.*;

        // Insert chain (serial, in slot_order)
        for (self.slot_order) |idx| {
            if (idx >= MAX_INSERTS) continue;
            const slot = &self.insert_slots[idx];
            if (slot.bypass or slot.fx_type == .none) continue;
            const process_fn = slot.process_fn orelse continue;
            const ctx = slot.ctx orelse continue;

            var temp: [BLOCK_SIZE]f32 = undefined;
            process_fn(ctx, &temp, &buf);

            if (slot.mix >= 1.0) {
                buf = temp;
            } else {
                const m = slot.mix;
                const dry = 1.0 - m;
                for (&buf, temp) |*b, w| {
                    b.* = b.* * dry + w * m;
                }
            }
        }

        // Send/Return (parallel, additive)
        for (&self.send_buses) |*bus| {
            if (!bus.active or bus.fx_type == .none) continue;
            const process_fn = bus.process_fn orelse continue;
            const ctx = bus.ctx orelse continue;

            var send_in: [BLOCK_SIZE]f32 = undefined;
            const amt = bus.send_amount;
            for (&send_in, buf) |*s, b| {
                s.* = b * amt;
            }

            var send_out: [BLOCK_SIZE]f32 = undefined;
            process_fn(ctx, &send_out, &send_in);

            for (&buf, send_out) |*b, r| {
                b.* += r;
            }
        }

        out.* = buf;
    }
};

// -- Test helpers ---------------------------------------------------------

const distortion = @import("distortion.zig");
const eq_mod = @import("eq.zig");

const DistortionCtx = struct {
    drive: f32,
    mode: distortion.DistortionMode,
};

fn distortion_process(ctx_ptr: *anyopaque, out: *[BLOCK_SIZE]f32, in_buf: *const [BLOCK_SIZE]f32) void {
    const c: *DistortionCtx = @ptrCast(@alignCast(ctx_ptr));
    distortion.process_block(out, in_buf, c.drive, c.mode);
}

fn eq_process(ctx_ptr: *anyopaque, out: *[BLOCK_SIZE]f32, in_buf: *const [BLOCK_SIZE]f32) void {
    const eq_ptr: *eq_mod.EQ = @ptrCast(@alignCast(ctx_ptr));
    eq_ptr.process_block(in_buf, out);
}

fn passthrough(ctx_ptr: *anyopaque, out: *[BLOCK_SIZE]f32, in_buf: *const [BLOCK_SIZE]f32) void {
    _ = ctx_ptr;
    out.* = in_buf.*;
}

// -- Tests ----------------------------------------------------------------

fn make_saw(buf: *[BLOCK_SIZE]f32) void {
    var phase: f32 = 0.0;
    for (buf) |*s| {
        s.* = 2.0 * phase - 1.0;
        phase += 440.0 / 44100.0;
        if (phase >= 1.0) phase -= 1.0;
    }
}

fn buffers_equal(a: *const [BLOCK_SIZE]f32, b: *const [BLOCK_SIZE]f32) bool {
    for (a, b) |x, y| {
        if (@abs(x - y) > 0.0001) return false;
    }
    return true;
}

test "AC-1: Insert + Send active -> output != input" {
    var chain = FxChain.init();

    // Insert: Distortion (tube, drive=5)
    var dist_ctx = DistortionCtx{ .drive = 5.0, .mode = .tube };
    chain.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx));

    // Send: EQ with +12dB at 1kHz
    var eq_inst = eq_mod.EQ.init(44100.0);
    eq_inst.set_band(4, 12.0);
    chain.set_send(0, .eq, 0.5, &eq_process, @ptrCast(&eq_inst));

    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);
    var output: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&output, &input);

    // Output must differ from input
    try std.testing.expect(!buffers_equal(&output, &input));
}

test "AC-2: bypass_all -> output == input (passthrough)" {
    var chain = FxChain.init();

    // Set up some effects
    var dist_ctx = DistortionCtx{ .drive = 5.0, .mode = .tube };
    chain.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx));
    var eq_inst = eq_mod.EQ.init(44100.0);
    eq_inst.set_band(4, 12.0);
    chain.set_send(0, .eq, 0.5, &eq_process, @ptrCast(&eq_inst));

    // Bypass everything
    chain.bypass_all();

    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);
    var output: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&output, &input);

    try std.testing.expect(buffers_equal(&output, &input));
}

test "AC-3: slot_order changes result (Distortion->EQ != EQ->Distortion)" {
    // Chain A: Distortion first, then EQ
    var chain_a = FxChain.init();
    var dist_ctx_a = DistortionCtx{ .drive = 5.0, .mode = .tube };
    var eq_a = eq_mod.EQ.init(44100.0);
    eq_a.set_band(4, 12.0);
    chain_a.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx_a));
    chain_a.set_insert(1, .eq, &eq_process, @ptrCast(&eq_a));
    chain_a.slot_order = .{ 0, 1, 2, 3, 4, 5, 6, 7 }; // dist(0) -> eq(1)

    // Chain B: EQ first, then Distortion
    var chain_b = FxChain.init();
    var dist_ctx_b = DistortionCtx{ .drive = 5.0, .mode = .tube };
    var eq_b = eq_mod.EQ.init(44100.0);
    eq_b.set_band(4, 12.0);
    chain_b.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx_b));
    chain_b.set_insert(1, .eq, &eq_process, @ptrCast(&eq_b));
    chain_b.slot_order = .{ 1, 0, 2, 3, 4, 5, 6, 7 }; // eq(1) -> dist(0)

    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);

    var out_a: [BLOCK_SIZE]f32 = undefined;
    var out_b: [BLOCK_SIZE]f32 = undefined;
    chain_a.process_block(&out_a, &input);
    chain_b.process_block(&out_b, &input);

    // Different order should produce different output
    try std.testing.expect(!buffers_equal(&out_a, &out_b));
}

test "empty chain = passthrough" {
    var chain = FxChain.init();
    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);
    var output: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&output, &input);
    try std.testing.expect(buffers_equal(&output, &input));
}

test "single insert with mix=0.5 blends dry/wet" {
    var chain = FxChain.init();
    var dist_ctx = DistortionCtx{ .drive = 10.0, .mode = .hard_clip };
    chain.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx));
    chain.set_mix(0, 0.5);

    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);

    // Full wet
    var chain_wet = FxChain.init();
    var dist_ctx_wet = DistortionCtx{ .drive = 10.0, .mode = .hard_clip };
    chain_wet.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx_wet));

    var out_mix: [BLOCK_SIZE]f32 = undefined;
    var out_wet: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&out_mix, &input);
    chain_wet.process_block(&out_wet, &input);

    // Mixed output should be between dry (input) and wet
    for (out_mix, input, out_wet) |m, d, w| {
        const expected = d * 0.5 + w * 0.5;
        try std.testing.expectApproxEqAbs(expected, m, 0.0001);
    }
}

test "send with amount=0 has no effect" {
    var chain = FxChain.init();
    var eq_inst = eq_mod.EQ.init(44100.0);
    eq_inst.set_band(4, 12.0);
    chain.set_send(0, .eq, 0.0, &eq_process, @ptrCast(&eq_inst));

    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);
    var output: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&output, &input);

    // Send amount 0 → no signal to effect → no change
    try std.testing.expect(buffers_equal(&output, &input));
}

test "reset_slot clears to none/bypassed" {
    var chain = FxChain.init();
    var dist_ctx = DistortionCtx{ .drive = 5.0, .mode = .tube };
    chain.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx));

    try std.testing.expect(chain.insert_slots[0].fx_type == .distortion);
    try std.testing.expect(!chain.insert_slots[0].bypass);

    chain.reset_slot(0);
    try std.testing.expect(chain.insert_slots[0].fx_type == .none);
    try std.testing.expect(chain.insert_slots[0].bypass);
    try std.testing.expect(chain.insert_slots[0].process_fn == null);
}

test "reorder function updates slot_order" {
    var chain = FxChain.init();
    const new_order = [_]u8{ 7, 6, 5, 4, 3, 2, 1, 0 };
    chain.reorder(new_order);
    try std.testing.expectEqual(new_order, chain.slot_order);
}

test "bypass_slot toggles single slot" {
    var chain = FxChain.init();
    var dist_ctx = DistortionCtx{ .drive = 5.0, .mode = .tube };
    chain.set_insert(0, .distortion, &distortion_process, @ptrCast(&dist_ctx));

    try std.testing.expect(!chain.insert_slots[0].bypass);
    chain.bypass_slot(0, true);
    try std.testing.expect(chain.insert_slots[0].bypass);

    // Bypassed slot should not affect output
    var input: [BLOCK_SIZE]f32 = undefined;
    make_saw(&input);
    var output: [BLOCK_SIZE]f32 = undefined;
    chain.process_block(&output, &input);
    try std.testing.expect(buffers_equal(&output, &input));
}

test "out-of-range set_insert is safe" {
    var chain = FxChain.init();
    var dist_ctx = DistortionCtx{ .drive = 5.0, .mode = .tube };
    chain.set_insert(8, .distortion, &distortion_process, @ptrCast(&dist_ctx));
    chain.set_insert(100, .distortion, &distortion_process, @ptrCast(&dist_ctx));
    chain.bypass_slot(99, true);
    chain.set_mix(99, 0.5);
    chain.reset_slot(99);
    // Should not crash
}

// -- Benchmarks -----------------------------------------------------------

var dummy_ctx: u8 = 0;

test "benchmark: empty chain (0 inserts)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();

    var input = [_]f32{0.3} ** BLOCK_SIZE;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| chain.process_block(&output, &input);

    const iterations: u64 = if (strict) 5_000_000 else 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        chain.process_block(&output, &input);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 50 else 5_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] Empty chain: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 4 inserts (passthrough)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();
    for (0..4) |i| {
        chain.set_insert(@intCast(i), .eq, &passthrough, @ptrCast(&dummy_ctx));
    }

    var input = [_]f32{0.3} ** BLOCK_SIZE;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| chain.process_block(&output, &input);

    const iterations: u64 = if (strict) 5_000_000 else 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        chain.process_block(&output, &input);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 250 else 20_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] 4 inserts: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 8 inserts (passthrough)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();
    for (0..8) |i| {
        chain.set_insert(@intCast(i), .eq, &passthrough, @ptrCast(&dummy_ctx));
    }

    var input = [_]f32{0.3} ** BLOCK_SIZE;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| chain.process_block(&output, &input);

    const iterations: u64 = if (strict) 5_000_000 else 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        chain.process_block(&output, &input);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 400 else 40_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] 8 inserts: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: 4 sends (passthrough)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();
    for (0..4) |i| {
        chain.set_send(@intCast(i), .reverb, 0.5, &passthrough, @ptrCast(&dummy_ctx));
    }

    var input = [_]f32{0.3} ** BLOCK_SIZE;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| chain.process_block(&output, &input);

    const iterations: u64 = if (strict) 5_000_000 else 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        chain.process_block(&output, &input);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 500 else 50_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] 4 sends: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: full chain (8 inserts + 4 sends)" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();
    for (0..8) |i| {
        chain.set_insert(@intCast(i), .eq, &passthrough, @ptrCast(&dummy_ctx));
    }
    for (0..4) |i| {
        chain.set_send(@intCast(i), .reverb, 0.5, &passthrough, @ptrCast(&dummy_ctx));
    }

    var input = [_]f32{0.3} ** BLOCK_SIZE;
    var output: [BLOCK_SIZE]f32 = undefined;

    for (0..1000) |_| chain.process_block(&output, &input);

    const iterations: u64 = if (strict) 5_000_000 else 500_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |_| {
        chain.process_block(&output, &input);
        std.mem.doNotOptimizeAway(&output);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 800 else 80_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] Full chain: {}ns/block (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}

test "benchmark: reorder" {
    const strict = builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;
    var chain = FxChain.init();

    const order_a = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const order_b = [_]u8{ 7, 6, 5, 4, 3, 2, 1, 0 };

    for (0..1000) |_| chain.reorder(order_a);

    const iterations: u64 = if (strict) 10_000_000 else 1_000_000;
    var timer = std.time.Timer.start() catch unreachable;
    for (0..iterations) |i| {
        chain.reorder(if (i % 2 == 0) order_a else order_b);
        std.mem.doNotOptimizeAway(&chain.slot_order);
    }
    const ns = timer.read() / iterations;

    const budget: u64 = if (strict) 100 else 5_000;
    const pass = ns < budget;
    std.debug.print("\n[WP-049] Reorder: {}ns/call (budget: {}ns) {s}\n", .{ ns, budget, if (pass) "PASS" else "<<< FAIL >>>" });
    try std.testing.expect(pass);
}
