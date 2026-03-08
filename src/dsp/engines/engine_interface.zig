const std = @import("std");
const builtin = @import("builtin");
const voice = @import("../voice.zig");
const physical = @import("physical.zig");
const phase_distortion = @import("phase_distortion.zig");
const formant_engine = @import("formant_engine.zig");

// -- Engine Interface (WP-068) ------------------------------------------------
// Unified union(enum) dispatch over all 11 EngineType variants.
// Engines with compatible process_block(*[BLOCK_SIZE]f32) are wired directly.
// Others use PlaceholderEngine (silence) until their WPs integrate them.
// Zero-cost dispatch via `inline else`.

pub const BLOCK_SIZE: usize = 128;

/// Placeholder for engines not yet integrated into the interface.
/// Produces silence. Exists so all 11 EngineType variants are representable.
pub const PlaceholderEngine = struct {
    pub fn init(_: f32) PlaceholderEngine {
        return .{};
    }

    pub fn reset(_: *PlaceholderEngine) void {}

    pub fn process_block(_: *PlaceholderEngine, out: *[BLOCK_SIZE]f32) void {
        @memset(out, 0.0);
    }
};

/// Wrapper for PdEngine — adapts its process_block(out, distortion) signature
/// to the unified process_block(out) interface by storing distortion state.
pub const PdEngineWrapper = struct {
    inner: phase_distortion.PdEngine,
    distortion: f32,

    pub fn init(sample_rate: f32) PdEngineWrapper {
        return .{
            .inner = phase_distortion.PdEngine.init(sample_rate),
            .distortion = 0.0,
        };
    }

    pub fn reset(self: *PdEngineWrapper) void {
        self.inner.reset();
    }

    pub fn set_distortion(self: *PdEngineWrapper, d: f32) void {
        self.distortion = d;
    }

    pub fn process_block(self: *PdEngineWrapper, out: *[BLOCK_SIZE]f32) void {
        self.inner.process_block(out, self.distortion);
    }
};

/// Unified engine instance — tagged union over all 11 EngineType variants.
/// Dispatches reset/process_block via inline else (zero-cost at comptime).
pub const EngineInstance = union(voice.EngineType) {
    virtual_analog: PlaceholderEngine,
    wavetable: PlaceholderEngine, // ~20MB, needs pointer wrapper
    fm: PlaceholderEngine,
    additive: PlaceholderEngine,
    granular: PlaceholderEngine,
    physical_modeling: physical.PhysicalEngine,
    sample_playback: PlaceholderEngine,
    phase_distortion: PdEngineWrapper,
    rave: PlaceholderEngine, // needs ONNX init
    ddsp: PlaceholderEngine,
    genetic: PlaceholderEngine, // breed() is module-level, not per-voice

    pub fn init(engine_type: voice.EngineType, sample_rate: f32) EngineInstance {
        return switch (engine_type) {
            .physical_modeling => .{ .physical_modeling = physical.PhysicalEngine.init(.karplus, sample_rate) },
            .phase_distortion => .{ .phase_distortion = PdEngineWrapper.init(sample_rate) },
            .virtual_analog => .{ .virtual_analog = PlaceholderEngine.init(sample_rate) },
            .wavetable => .{ .wavetable = PlaceholderEngine.init(sample_rate) },
            .fm => .{ .fm = PlaceholderEngine.init(sample_rate) },
            .additive => .{ .additive = PlaceholderEngine.init(sample_rate) },
            .granular => .{ .granular = PlaceholderEngine.init(sample_rate) },
            .sample_playback => .{ .sample_playback = PlaceholderEngine.init(sample_rate) },
            .rave => .{ .rave = PlaceholderEngine.init(sample_rate) },
            .ddsp => .{ .ddsp = PlaceholderEngine.init(sample_rate) },
            .genetic => .{ .genetic = PlaceholderEngine.init(sample_rate) },
        };
    }

    pub fn reset(self: *EngineInstance) void {
        switch (self.*) {
            .physical_modeling => |*e| {
                // PhysicalEngine has no union-level reset; re-init with karplus default.
                e.* = physical.PhysicalEngine.init(.karplus, 44_100.0);
            },
            inline else => |*e| e.reset(),
        }
    }

    pub fn process_block(self: *EngineInstance, out: *[BLOCK_SIZE]f32) void {
        switch (self.*) {
            inline else => |*e| e.process_block(out),
        }
    }

    /// Returns the active engine type.
    pub fn active_type(self: *const EngineInstance) voice.EngineType {
        return self.*;
    }
};

// -- Tests (WP-068) -----------------------------------------------------------

test "WP-068 AC-1: all 11 EngineType variants are instantiable" {
    const engine_types = @typeInfo(voice.EngineType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 11), engine_types.len);

    inline for (@typeInfo(voice.EngineType).@"enum".fields) |field| {
        const et: voice.EngineType = @enumFromInt(field.value);
        var inst = EngineInstance.init(et, 44_100.0);
        var out: [BLOCK_SIZE]f32 = undefined;
        inst.process_block(&out);
        // Must not crash.
    }
    std.debug.print("\n[WP-068] AC-1: all 11 engine types instantiable: PASS\n", .{});
}

test "WP-068 AC-2: runtime engine switch physical→phase_distortion" {
    var inst = EngineInstance.init(.physical_modeling, 44_100.0);
    var out: [BLOCK_SIZE]f32 = undefined;
    inst.process_block(&out);

    // Switch to phase_distortion at runtime.
    inst = EngineInstance.init(.phase_distortion, 44_100.0);
    inst.process_block(&out);

    // Verify active type changed.
    try std.testing.expectEqual(voice.EngineType.phase_distortion, inst.active_type());
    std.debug.print("\n[WP-068] AC-2: engine switch physical→pd: PASS\n", .{});
}

test "WP-068 AC-3: physical_modeling produces sound after excite" {
    var inst = EngineInstance.init(.physical_modeling, 44_100.0);

    // Excite the underlying KarplusStrong model.
    switch (inst) {
        .physical_modeling => |*pm| {
            pm.set_frequency(440.0);
            pm.set_damping(0.995);
            // Access the inner KarplusStrong to call excite.
            switch (pm.*) {
                .karplus => |*ks| ks.excite(1.0),
                else => {},
            }
        },
        else => unreachable,
    }

    var out: [BLOCK_SIZE]f32 = undefined;
    inst.process_block(&out);

    // Should have non-zero output after excitation.
    var has_sound = false;
    for (out) |s| {
        if (@abs(s) > 1e-6) {
            has_sound = true;
            break;
        }
    }
    try std.testing.expect(has_sound);
    std.debug.print("\n[WP-068] AC-3: physical_modeling produces sound after excite: PASS\n", .{});
}

test "WP-068 AC-N1: engine switch does not crash" {
    const sr: f32 = 44_100.0;
    var out: [BLOCK_SIZE]f32 = undefined;

    // Rapidly switch through all engine types.
    inline for (@typeInfo(voice.EngineType).@"enum".fields) |field| {
        const et: voice.EngineType = @enumFromInt(field.value);
        var inst = EngineInstance.init(et, sr);
        inst.process_block(&out);
        inst.reset();
        inst.process_block(&out);
    }
    std.debug.print("\n[WP-068] AC-N1: rapid engine switching no crash: PASS\n", .{});
}

test "placeholder engines produce silence" {
    var ph = PlaceholderEngine.init(44_100.0);
    var out: [BLOCK_SIZE]f32 = .{1.0} ** BLOCK_SIZE;
    ph.process_block(&out);
    for (out) |s| {
        try std.testing.expectEqual(@as(f32, 0.0), s);
    }
}

test "PdEngineWrapper stores distortion state" {
    var pd = PdEngineWrapper.init(44_100.0);
    pd.inner.set_note(440.0);

    // Zero distortion → pure cosine.
    pd.set_distortion(0.0);
    var out_clean: [BLOCK_SIZE]f32 = undefined;
    pd.process_block(&out_clean);

    // Reset and process with distortion.
    pd.reset();
    pd.set_distortion(0.8);
    var out_dirty: [BLOCK_SIZE]f32 = undefined;
    pd.process_block(&out_dirty);

    // Outputs must differ (different distortion amounts).
    var differs = false;
    for (out_clean, out_dirty) |c, d| {
        if (@abs(c - d) > 1e-6) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "active_type returns correct variant" {
    const inst_pm = EngineInstance.init(.physical_modeling, 44_100.0);
    try std.testing.expectEqual(voice.EngineType.physical_modeling, inst_pm.active_type());

    const inst_fm = EngineInstance.init(.fm, 44_100.0);
    try std.testing.expectEqual(voice.EngineType.fm, inst_fm.active_type());
}
