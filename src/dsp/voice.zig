const std = @import("std");

// ── VoicePool AoSoA Layout (WP-006) ─────────────────────────────────
// Array-of-Struct-of-Arrays: 8 Voices pro Chunk (= 1 AVX2 Register).
// Hot/Cold Split: Audio-kritische Daten (Phase, Amplitude, Pan) im L1,
// selten benoetigte Daten (Filter-State f64, Mod-Values) separat.

// ── Constants ─────────────────────────────────────────────────────────

pub const MAX_VOICES: usize = 64;
pub const MAX_UNISON: usize = 16;
pub const MAX_LAYERS: usize = 4;
pub const CHUNK_SIZE: usize = 8;
pub const NUM_CHUNKS: usize = MAX_VOICES / CHUNK_SIZE;

// ── Enums ─────────────────────────────────────────────────────────────

pub const EnvStage = enum(u8) {
    idle,
    attack,
    decay,
    sustain,
    release,
};

pub const EngineType = enum(u8) {
    virtual_analog,
    wavetable,
    fm,
    additive,
    granular,
    physical_modeling,
    sample_playback,
    phase_distortion,
    rave,
    ddsp,
    genetic,
};

pub const FilterType = enum(u8) {
    low_pass,
    high_pass,
    band_pass,
    notch,
    peak,
    all_pass,
};

// ── VoiceHot (L1 Cache-optimiert, Audio-Thread-Daten) ────────────────
// Alle f32 arrays mit CHUNK_SIZE=8 (32 Bytes = 1 AVX2 Register).

pub const VoiceHot = struct {
    phase: [CHUNK_SIZE]f32,
    phase_inc: [CHUNK_SIZE]f32,
    amplitude: [CHUNK_SIZE]f32,
    pan_l: [CHUNK_SIZE]f32,
    pan_r: [CHUNK_SIZE]f32,
    prev_output: [CHUNK_SIZE]f32,
    env_value: [CHUNK_SIZE]f32,
    env_increment: [CHUNK_SIZE]f32,
    env_sample_count: [CHUNK_SIZE]u32,
    env_stage: [CHUNK_SIZE]EnvStage,
    active: [CHUNK_SIZE]bool,
};

// ── VoiceCold (selten gelesen, f64 Filter-State + Metadata) ──────────

pub const VoiceCold = struct {
    // ZDF filter integrator state (f64 fuer numerische Stabilitaet)
    flt_z1: [CHUNK_SIZE]f64,
    flt_z2: [CHUNK_SIZE]f64,
    flt_x1: [CHUNK_SIZE]f64,
    flt_x2: [CHUNK_SIZE]f64,
    // Metadata
    layer: [CHUNK_SIZE]u8,
    engine_type: [CHUNK_SIZE]EngineType,
    filter_type: [CHUNK_SIZE]FilterType,
    note: [CHUNK_SIZE]u8,
    velocity: [CHUNK_SIZE]u8,
    age: [CHUNK_SIZE]u32,
    unison_count: [CHUNK_SIZE]u8,
    mod_values: [CHUNK_SIZE][256]f32,
};

// ── VoiceLoc ──────────────────────────────────────────────────────────

pub const VoiceLoc = struct {
    chunk: u3,
    slot: u3,
};

// ── VoicePool ─────────────────────────────────────────────────────────

pub const VoicePool = struct {
    hot: [NUM_CHUNKS]VoiceHot,
    cold: [NUM_CHUNKS]VoiceCold,

    /// In-place initialization — sets all voices to inactive/idle.
    /// Must be called via pointer (VoicePool is too large for by-value return).
    pub fn init(self: *VoicePool) void {
        for (&self.hot) |*chunk| {
            chunk.* = std.mem.zeroes(VoiceHot);
        }
        for (&self.cold) |*chunk| {
            chunk.* = std.mem.zeroes(VoiceCold);
        }
    }

    /// Maps linear voice index (0..63) to chunk/slot location.
    pub inline fn voice_loc(voice_idx: u6) VoiceLoc {
        return .{
            .chunk = @intCast(voice_idx >> 3),
            .slot = @intCast(voice_idx & 7),
        };
    }

    /// Returns the first inactive voice, or null if all voices are active.
    pub fn find_free_voice(self: *const VoicePool) ?u6 {
        for (self.hot, 0..) |chunk, ci| {
            for (chunk.active, 0..) |active, si| {
                if (!active) {
                    return @intCast(ci * CHUNK_SIZE + si);
                }
            }
        }
        return null;
    }

    /// Returns the index of the oldest active voice (highest age).
    /// For voice stealing when all voices are in use.
    /// Precondition: at least one voice must be active.
    pub fn steal_oldest(self: *const VoicePool) u6 {
        var oldest_age: u32 = 0;
        var oldest_idx: u6 = 0;
        var found: bool = false;
        for (self.hot, self.cold, 0..) |hot_chunk, cold_chunk, ci| {
            for (0..CHUNK_SIZE) |si| {
                if (hot_chunk.active[si]) {
                    if (!found or cold_chunk.age[si] > oldest_age) {
                        oldest_age = cold_chunk.age[si];
                        oldest_idx = @intCast(ci * CHUNK_SIZE + si);
                        found = true;
                    }
                }
            }
        }
        return oldest_idx;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "init sets all voices inactive and idle" {
    var pool: VoicePool = undefined;
    pool.init();
    try std.testing.expectEqual(false, pool.hot[0].active[0]);
    for (pool.hot) |chunk| {
        for (chunk.active) |a| {
            try std.testing.expectEqual(false, a);
        }
        for (chunk.env_stage) |s| {
            try std.testing.expectEqual(EnvStage.idle, s);
        }
    }
}

test "find_free_voice returns 0 on empty pool" {
    var pool: VoicePool = undefined;
    pool.init();
    try std.testing.expectEqual(@as(?u6, 0), pool.find_free_voice());
}

test "find_free_voice returns null when all active" {
    var pool: VoicePool = undefined;
    pool.init();
    for (&pool.hot) |*chunk| {
        for (&chunk.active) |*a| {
            a.* = true;
        }
    }
    try std.testing.expectEqual(@as(?u6, null), pool.find_free_voice());
}

test "find_free_voice skips active voices" {
    var pool: VoicePool = undefined;
    pool.init();
    pool.hot[0].active[0] = true;
    pool.hot[0].active[1] = true;
    pool.hot[0].active[2] = true;
    try std.testing.expectEqual(@as(?u6, 3), pool.find_free_voice());
}

test "steal_oldest returns oldest active voice" {
    var pool: VoicePool = undefined;
    pool.init();
    pool.hot[0].active[0] = true;
    pool.cold[0].age[0] = 10;
    pool.hot[0].active[3] = true;
    pool.cold[0].age[3] = 50;
    pool.hot[1].active[2] = true;
    pool.cold[1].age[2] = 30;
    try std.testing.expectEqual(@as(u6, 3), pool.steal_oldest());
}

test "steal_oldest across chunks" {
    var pool: VoicePool = undefined;
    pool.init();
    pool.hot[0].active[0] = true;
    pool.cold[0].age[0] = 100;
    pool.hot[7].active[7] = true;
    pool.cold[7].age[7] = 200;
    try std.testing.expectEqual(@as(u6, 63), pool.steal_oldest());
}

test "voice_loc(9) is chunk 1, slot 1" {
    const loc = VoicePool.voice_loc(9);
    try std.testing.expectEqual(@as(u3, 1), loc.chunk);
    try std.testing.expectEqual(@as(u3, 1), loc.slot);
}

test "voice_loc(0) is chunk 0, slot 0" {
    const loc = VoicePool.voice_loc(0);
    try std.testing.expectEqual(@as(u3, 0), loc.chunk);
    try std.testing.expectEqual(@as(u3, 0), loc.slot);
}

test "voice_loc(63) is chunk 7, slot 7" {
    const loc = VoicePool.voice_loc(63);
    try std.testing.expectEqual(@as(u3, 7), loc.chunk);
    try std.testing.expectEqual(@as(u3, 7), loc.slot);
}

test "EngineType has 11 variants" {
    const fields = @typeInfo(EngineType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 11), fields.len);
}

test "FilterType has 6 variants" {
    const fields = @typeInfo(FilterType).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 6), fields.len);
}
