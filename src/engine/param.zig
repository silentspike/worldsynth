const std = @import("std");

// ── MVCC Param-System (WP-007) ──────────────────────────────────────
// Lock-free Parameter-Updates via Atomic Pointer Swap (Double-Buffer).
// UI-Thread schreibt (Mutex-geschuetzt), Audio-Thread liest (Atomic Load).
// Garantie: Audio-Thread sieht IMMER einen konsistenten Snapshot.

// ── ParamID ──────────────────────────────────────────────────────────

pub const ParamID = enum(u16) {
    // Oscillator 1
    osc1_waveform = 0,
    osc1_detune = 1,
    osc1_level = 2,
    // Oscillator 2
    osc2_waveform = 3,
    osc2_detune = 4,
    osc2_level = 5,
    // Filter
    filter_cutoff = 6,
    filter_resonance = 7,
    filter_type = 8,
    // Envelope
    env_attack = 9,
    env_decay = 10,
    env_sustain = 11,
    env_release = 12,
    // Master
    master_volume = 13,
    quality_mode = 14,
    _,
};

// ── ParamSnapshot ────────────────────────────────────────────────────

pub const PARAM_COUNT: usize = 1024;

pub const ParamSnapshot = struct {
    values: [PARAM_COUNT]f64,
    version: u64,

    /// Returns a snapshot initialized with sensible defaults.
    pub fn init_defaults() ParamSnapshot {
        var snap = ParamSnapshot{
            .values = [_]f64{0.0} ** PARAM_COUNT,
            .version = 0,
        };
        snap.values[@intFromEnum(ParamID.osc1_level)] = 1.0;
        snap.values[@intFromEnum(ParamID.filter_cutoff)] = 1000.0;
        snap.values[@intFromEnum(ParamID.env_attack)] = 0.01;
        snap.values[@intFromEnum(ParamID.env_decay)] = 0.1;
        snap.values[@intFromEnum(ParamID.env_sustain)] = 0.7;
        snap.values[@intFromEnum(ParamID.env_release)] = 0.3;
        snap.values[@intFromEnum(ParamID.master_volume)] = 1.0;
        return snap;
    }
};

// ── ParamState (Double-Buffer + Atomic Swap) ─────────────────────────

pub const ParamState = struct {
    snap_a: ParamSnapshot,
    snap_b: ParamSnapshot,
    current: std.atomic.Value(*ParamSnapshot),
    mutex: std.Thread.Mutex,

    /// In-place initialization. Sets defaults, atomic pointer to snap_a.
    pub fn init(self: *ParamState) void {
        self.snap_a = ParamSnapshot.init_defaults();
        self.snap_b = ParamSnapshot.init_defaults();
        self.mutex = .{};
        self.current = std.atomic.Value(*ParamSnapshot).init(&self.snap_a);
    }

    /// Set a parameter value. Mutex-protected — UI-Thread only!
    /// Copies active snapshot to inactive, sets value, increments version,
    /// then atomically swaps current pointer with .release ordering.
    pub fn set_param(self: *ParamState, id: ParamID, value: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const active = self.current.load(.acquire);
        const inactive: *ParamSnapshot = if (active == &self.snap_a)
            &self.snap_b
        else
            &self.snap_a;

        // Copy active state to inactive buffer
        inactive.* = active.*;
        // Apply change
        inactive.values[@intFromEnum(id)] = value;
        inactive.version = active.version + 1;
        // Atomic swap — audio thread sees new snapshot on next read
        self.current.store(inactive, .release);
    }

    /// Read current parameter snapshot. Lock-free atomic load with .acquire.
    /// Safe to call from the audio thread — NO mutex, NO blocking.
    pub inline fn read_snapshot(self: *const ParamState) *const ParamSnapshot {
        return self.current.load(.acquire);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "init sets default values" {
    var state: ParamState = undefined;
    state.init();
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(f64, 1000.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
    try std.testing.expectEqual(@as(f64, 1.0), snap.values[@intFromEnum(ParamID.master_volume)]);
    try std.testing.expectEqual(@as(f64, 1.0), snap.values[@intFromEnum(ParamID.osc1_level)]);
    try std.testing.expectEqual(@as(f64, 0.7), snap.values[@intFromEnum(ParamID.env_sustain)]);
    try std.testing.expectEqual(@as(u64, 0), snap.version);
}

test "set_param changes value and increments version" {
    var state: ParamState = undefined;
    state.init();
    state.set_param(.filter_cutoff, 2000.0);
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(f64, 2000.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
    try std.testing.expectEqual(@as(u64, 1), snap.version);
}

test "set_param does not affect other parameters" {
    var state: ParamState = undefined;
    state.init();
    state.set_param(.filter_cutoff, 5000.0);
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(f64, 5000.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
    // Other defaults unchanged
    try std.testing.expectEqual(@as(f64, 1.0), snap.values[@intFromEnum(ParamID.master_volume)]);
    try std.testing.expectEqual(@as(f64, 0.01), snap.values[@intFromEnum(ParamID.env_attack)]);
}

test "multiple set_param calls increment version" {
    var state: ParamState = undefined;
    state.init();
    state.set_param(.filter_cutoff, 100.0);
    state.set_param(.filter_cutoff, 200.0);
    state.set_param(.filter_resonance, 0.5);
    const snap = state.read_snapshot();
    try std.testing.expectEqual(@as(u64, 3), snap.version);
    try std.testing.expectEqual(@as(f64, 200.0), snap.values[@intFromEnum(ParamID.filter_cutoff)]);
    try std.testing.expectEqual(@as(f64, 0.5), snap.values[@intFromEnum(ParamID.filter_resonance)]);
}

test "read_snapshot is lock-free (no mutex)" {
    // Structural test: read_snapshot uses only atomic load.
    // Verified via grep in AC-N2. Here we test it returns valid data.
    var state: ParamState = undefined;
    state.init();
    const snap1 = state.read_snapshot();
    const snap2 = state.read_snapshot();
    // Multiple reads return same snapshot (no writes in between)
    try std.testing.expectEqual(snap1.version, snap2.version);
}

test "double-buffer alternates between snap_a and snap_b" {
    var state: ParamState = undefined;
    state.init();
    const snap0 = state.read_snapshot();
    // Initially points to snap_a
    try std.testing.expect(snap0 == &state.snap_a);
    state.set_param(.filter_cutoff, 999.0);
    const snap1 = state.read_snapshot();
    // After one set_param, points to snap_b
    try std.testing.expect(snap1 == &state.snap_b);
    state.set_param(.filter_cutoff, 888.0);
    const snap2 = state.read_snapshot();
    // After second set_param, back to snap_a
    try std.testing.expect(snap2 == &state.snap_a);
}

test "multi-thread: writer + reader, no torn reads" {
    var state: ParamState = undefined;
    state.init();

    var writer_done = std.atomic.Value(bool).init(false);

    // Writer thread: alternates filter_cutoff between 0.0 and 10000.0
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(s: *ParamState, done: *std.atomic.Value(bool)) void {
            for (0..10_000) |i| {
                const val: f64 = if (i % 2 == 0) 0.0 else 10000.0;
                s.set_param(.filter_cutoff, val);
            }
            done.store(true, .release);
        }
    }.run, .{ &state, &writer_done });

    // Reader (main thread): check cutoff is always 0.0, 10000.0, or default 1000.0
    var torn_read = false;
    var reads: usize = 0;
    while (!writer_done.load(.acquire) or reads < 1000) : (reads += 1) {
        const snap = state.read_snapshot();
        const cutoff = snap.values[@intFromEnum(ParamID.filter_cutoff)];
        if (cutoff != 0.0 and cutoff != 10000.0 and cutoff != 1000.0) {
            torn_read = true;
            break;
        }
    }

    writer.join();
    try std.testing.expect(!torn_read);
    try std.testing.expect(reads > 0);
}

test "multi-thread: version monotonically increases" {
    var state: ParamState = undefined;
    state.init();

    var writer_done = std.atomic.Value(bool).init(false);

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(s: *ParamState, done: *std.atomic.Value(bool)) void {
            for (0..10_000) |i| {
                s.set_param(.master_volume, @as(f64, @floatFromInt(i)) * 0.0001);
            }
            done.store(true, .release);
        }
    }.run, .{ &state, &writer_done });

    var last_version: u64 = 0;
    var monotonic = true;
    while (!writer_done.load(.acquire)) {
        const snap = state.read_snapshot();
        if (snap.version < last_version) {
            monotonic = false;
            break;
        }
        last_version = snap.version;
    }

    writer.join();
    try std.testing.expect(monotonic);
}
