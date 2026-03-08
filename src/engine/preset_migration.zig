const std = @import("std");
const flatbuf = @import("../io/flatbuf.zig");

// -- Preset Schema Migration (WP-070) -----------------------------------------
// Versioned schema migrations for long-term preset compatibility.
// Each version bump adds a migration function that sets new fields to sensible
// defaults. migrate() chains all necessary migrations: v1→v2→v3→...
// Always forward-compatible: old presets load via migration, new presets are
// created at CURRENT_VERSION.

pub const CURRENT_VERSION: u16 = flatbuf.SCHEMA_VERSION; // 2

pub const MigrationError = error{UnknownVersion};

/// Migrate a preset from its current version to CURRENT_VERSION.
/// Applies all intermediate migrations in sequence.
/// Returns error.UnknownVersion if the preset version is not recognized.
pub fn migrate(preset: *flatbuf.PresetSchema) MigrationError!void {
    if (preset.version > CURRENT_VERSION) return error.UnknownVersion;
    while (preset.version < CURRENT_VERSION) {
        switch (preset.version) {
            1 => migrate_v1_to_v2(preset),
            else => return error.UnknownVersion,
        }
    }
}

/// v1→v2: Added pitch_bend_range (default 2.0 semitones) and glide_time
/// (default 0.0 — no portamento).
fn migrate_v1_to_v2(preset: *flatbuf.PresetSchema) void {
    preset.pitch_bend_range = 2.0;
    preset.glide_time = 0.0;
    preset.version = 2;
}

// -- Tests (WP-070 Migration) -------------------------------------------------

test "WP-070 AC-2: v1 to v2 migration sets defaults" {
    // Simulate a v1 preset (version=1, v2 fields zeroed).
    var preset = flatbuf.PresetSchema.init();
    preset.version = 1;
    preset.pitch_bend_range = 0.0;
    preset.glide_time = 0.0;

    try migrate(&preset);

    try std.testing.expectEqual(@as(u16, 2), preset.version);
    try std.testing.expectEqual(@as(f32, 2.0), preset.pitch_bend_range);
    try std.testing.expectEqual(@as(f32, 0.0), preset.glide_time);
    // Other fields unchanged.
    try std.testing.expectEqual(@as(f32, 1.0), preset.master_volume);

    std.debug.print("\n[WP-070] AC-2: v1→v2 migration PASS\n", .{});
}

test "WP-070 AC-N1: unknown version returns error" {
    var preset = flatbuf.PresetSchema.init();
    preset.version = 99;

    const result = migrate(&preset);
    try std.testing.expectError(error.UnknownVersion, result);
    std.debug.print("\n[WP-070] AC-N1: UnknownVersion PASS\n", .{});
}

test "WP-070 migration: already current version is no-op" {
    var preset = flatbuf.PresetSchema.init();
    const original_volume = preset.master_volume;

    try migrate(&preset);

    // Nothing changed.
    try std.testing.expectEqual(CURRENT_VERSION, preset.version);
    try std.testing.expectEqual(original_volume, preset.master_volume);
    std.debug.print("\n[WP-070] migration no-op PASS\n", .{});
}
