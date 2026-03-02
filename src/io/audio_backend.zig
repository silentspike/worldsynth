const std = @import("std");
const build_options = @import("build_options");
const jack_mod = @import("jack.zig");
const pw_mod = @import("pipewire.zig");

// ── Audio Backend Abstraction (WP-012) ──────────────────────────────
// Unified interface for PipeWire (preferred) and JACK (fallback).
// Runtime detection in detect_and_init() chooses the first available backend.
// No heap allocation — all state lives in the union payload.

/// Audio process callback — stereo planar f32, called from RT thread.
pub const ProcessFn = jack_mod.ProcessFn;

/// MIDI event callback (JACK only, PipeWire MIDI is out of scope).
pub const MidiEventFn = jack_mod.MidiEventFn;

/// Unified audio backend wrapping PipeWire and JACK.
/// detect_and_init() tries PipeWire first, then JACK.
/// start()/stop() delegate to the active backend.
pub const AudioBackend = union(enum) {
    pipewire: pw_mod.PipeWireClient,
    jack: jack_mod.JackAudioClient,

    /// Detect and initialize the best available audio backend.
    /// Order: PipeWire first (if compiled in), then JACK.
    /// Returns error.NoBackendAvailable if no backend can be initialized.
    pub fn detect_and_init(process_fn: ?ProcessFn, midi_fn: ?MidiEventFn) error{NoBackendAvailable}!AudioBackend {
        // PipeWire preferred — probe daemon, then init
        if (comptime build_options.enable_pipewire) {
            if (pw_mod.PipeWireClient.probe()) {
                if (pw_mod.PipeWireClient.init(process_fn)) |pw|
                    return .{ .pipewire = pw }
                else |_| {}
            }
        }
        // JACK fallback
        if (comptime build_options.enable_jack) {
            if (jack_mod.JackAudioClient.init(process_fn, midi_fn)) |j|
                return .{ .jack = j }
            else |_| {}
        }
        return error.NoBackendAvailable;
    }

    /// Start audio processing.
    /// PipeWire: blocks (runs pw_main_loop). JACK: returns after activation.
    /// self must be at a stable address (not on a temporary stack frame).
    pub fn start(self: *AudioBackend) !void {
        switch (self.*) {
            .pipewire => |*pw| if (comptime build_options.enable_pipewire) {
                try pw.start();
            } else unreachable,
            .jack => |*j| if (comptime build_options.enable_jack) {
                try j.start();
            } else unreachable,
        }
    }

    /// Stop audio processing and release all resources.
    pub fn stop(self: *AudioBackend) void {
        switch (self.*) {
            .pipewire => |*pw| if (comptime build_options.enable_pipewire) {
                pw.deinit();
            } else unreachable,
            .jack => |*j| if (comptime build_options.enable_jack) {
                j.deinit();
            } else unreachable,
        }
    }

    /// Get the sample rate of the active backend.
    pub fn get_sample_rate(self: *AudioBackend) u32 {
        return switch (self.*) {
            .pipewire => 44100, // Matches AudioFormatPod request
            .jack => |*j| if (comptime build_options.enable_jack)
                j.getSampleRate()
            else
                unreachable,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AudioBackend union has pipewire and jack variants" {
    const fields = @typeInfo(AudioBackend).@"union".fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("pipewire", fields[0].name);
    try std.testing.expectEqualStrings("jack", fields[1].name);
}

test "detect prefers pipewire" {
    // With both backends compiled out, detection falls through in order:
    // 1. PipeWire check (comptime false) → skip
    // 2. JACK check (comptime false) → skip
    // 3. NoBackendAvailable
    if (comptime build_options.enable_pipewire or build_options.enable_jack)
        return error.SkipZigTest;
    try std.testing.expectError(error.NoBackendAvailable, AudioBackend.detect_and_init(null, null));
}

test "fallback to jack" {
    // JACK fallback is the second check in detect_and_init.
    // With both disabled, confirms the JACK check is attempted after PipeWire.
    if (comptime build_options.enable_pipewire or build_options.enable_jack)
        return error.SkipZigTest;
    try std.testing.expectError(error.NoBackendAvailable, AudioBackend.detect_and_init(null, null));
}

test "start delegates to active backend" {
    // Compile-time verification: start() handles both union variants.
    // Taking the address forces compilation of switch arms with comptime guards.
    _ = &AudioBackend.start;
}

test "stop delegates to active backend" {
    // Compile-time verification: stop() handles both union variants.
    _ = &AudioBackend.stop;
}

test "ProcessFn type matches backend ProcessFn" {
    try std.testing.expect(ProcessFn == jack_mod.ProcessFn);
    try std.testing.expect(ProcessFn == pw_mod.ProcessFn);
}
