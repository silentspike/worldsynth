const std = @import("std");
const builtin = @import("builtin");

// ── MVCC Param-System (WP-007) ──────────────────────────────────────
// Lock-free Parameter-Updates via Triple-Buffer Atomic Swap.
// UI-Thread schreibt (Mutex-geschuetzt), Audio-Thread liest (Atomic Load).
// Triple-Buffer: 3 Snapshots — Writer kann NIE den Buffer ueberschreiben
// den der Reader gerade liest. Korrekt unter beliebiger Contention.

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

// ── ParamState (Triple-Buffer + Atomic Swap) ─────────────────────────
// 3 Slots: Reader besitzt einen, Writer schreibt in einen, der dritte
// ist frei. Writer waehlt immer den Slot der NICHT latest und NICHT
// reading ist. Dadurch wird der Reader-Slot nie ueberschrieben.

pub const SLOT_NONE: u8 = 3; // Sentinel: Reader liest gerade keinen Slot

pub const ParamState = struct {
    snapshots: [3]ParamSnapshot,
    // Cache-line aligned: latest (writer stores) und reading (reader stores)
    // auf separaten Cache-Lines um False Sharing zu vermeiden.
    latest: std.atomic.Value(u8) align(64), // Index des neuesten Snapshots (0, 1, 2)
    reading: std.atomic.Value(u8) align(64), // Index den der Reader gerade liest (0-2, oder SLOT_NONE)
    mutex: std.Thread.Mutex,

    /// In-place initialization. All 3 snapshots get defaults, latest=0.
    pub fn init(self: *ParamState) void {
        for (&self.snapshots) |*s| s.* = ParamSnapshot.init_defaults();
        self.latest = std.atomic.Value(u8).init(0);
        self.reading = std.atomic.Value(u8).init(SLOT_NONE);
        self.mutex = .{};
    }

    /// Set a parameter value. Mutex-protected — UI-Thread only!
    /// Picks a free slot (not latest, not reading), copies latest there,
    /// applies change, publishes with .release.
    pub fn set_param(self: *ParamState, id: ParamID, value: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const src = self.latest.load(.monotonic);
        // .acquire synchronisiert mit Reader's reading.store(.release).
        // .monotonic wuerde LLVM erlauben, stale Werte zu verwenden,
        // da es keine cross-variable Synchronisation garantiert.
        const rdr = self.reading.load(.acquire);
        const dst = free_slot(src, rdr);

        self.snapshots[dst] = self.snapshots[src];
        self.snapshots[dst].values[@intFromEnum(id)] = value;
        self.snapshots[dst].version = self.snapshots[src].version + 1;
        self.latest.store(dst, .release);
    }

    /// Read current parameter snapshot. Lock-free — NO mutex, NO blocking.
    /// Sets reading index so writer avoids this slot. Retry if latest
    /// changed between load and announce (practically never happens).
    pub inline fn read_snapshot(self: *ParamState) *const ParamSnapshot {
        while (true) {
            const idx = self.latest.load(.acquire);
            self.reading.store(idx, .release);
            // Verify: if latest hasn't changed, writer knows to avoid our slot
            if (self.latest.load(.acquire) == idx) return &self.snapshots[idx];
        }
    }

    /// Find a slot that is not a and not b. Always succeeds for 3 slots.
    fn free_slot(a: u8, b: u8) u8 {
        if (a != 0 and b != 0) return 0;
        if (a != 1 and b != 1) return 1;
        return 2;
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
    // Structural test: read_snapshot uses only atomic load/store, no mutex.
    // Verified via grep in AC-N2. Here we test it returns valid data.
    var state: ParamState = undefined;
    state.init();
    const snap1 = state.read_snapshot();
    const snap2 = state.read_snapshot();
    // Multiple reads return same snapshot (no writes in between)
    try std.testing.expectEqual(snap1.version, snap2.version);
}

test "triple-buffer uses 3 distinct slots" {
    var state: ParamState = undefined;
    state.init();
    const snap0 = state.read_snapshot();
    // Initially points to snapshots[0]
    try std.testing.expect(snap0 == &state.snapshots[0]);
    state.set_param(.filter_cutoff, 999.0);
    const snap1 = state.read_snapshot();
    // After one set_param, latest moved to a different slot
    try std.testing.expect(snap1 != snap0);
    try std.testing.expectEqual(@as(f64, 999.0), snap1.values[@intFromEnum(ParamID.filter_cutoff)]);
    state.set_param(.filter_cutoff, 888.0);
    const snap2 = state.read_snapshot();
    // After second set_param, latest moved again
    try std.testing.expect(snap2 != snap1);
    try std.testing.expectEqual(@as(f64, 888.0), snap2.values[@intFromEnum(ParamID.filter_cutoff)]);
    state.set_param(.filter_cutoff, 777.0);
    const snap3 = state.read_snapshot();
    // Third set_param — all 3 slots have been used
    try std.testing.expectEqual(@as(f64, 777.0), snap3.values[@intFromEnum(ParamID.filter_cutoff)]);
    try std.testing.expectEqual(@as(u64, 3), snap3.version);
}

test "free_slot returns slot not equal to either argument" {
    // Exhaustive test: all 4x4 combinations of (a, b) where a,b in {0,1,2,SLOT_NONE}
    const slots = [_]u8{ 0, 1, 2, SLOT_NONE };
    for (slots) |a| {
        for (slots) |b| {
            const f = ParamState.free_slot(a, b);
            try std.testing.expect(f <= 2);
            try std.testing.expect(f != a or a == SLOT_NONE);
            try std.testing.expect(f != b or b == SLOT_NONE);
        }
    }
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

test "multi-thread: 1M stress test, slot isolation (AC-8)" {
    var state: ParamState = undefined;
    state.init();

    const STRESS_ITERS: usize = if (builtin.mode == .Debug) 250_000 else 1_000_000;
    var writer_done = std.atomic.Value(bool).init(false);

    // Writer: 1M set_param, alternating values
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(s: *ParamState, done: *std.atomic.Value(bool)) void {
            for (0..STRESS_ITERS) |i| {
                const val: f64 = if (i % 2 == 0) 0.0 else 10000.0;
                s.set_param(.filter_cutoff, val);
            }
            done.store(true, .release);
        }
    }.run, .{ &state, &writer_done });

    // Reader (main thread): concurrent reads, check consistency
    var torn_read = false;
    var monotonic = true;
    var last_version: u64 = 0;
    var reads: usize = 0;
    while (!writer_done.load(.acquire) or reads < 100_000) : (reads += 1) {
        const snap = state.read_snapshot();
        const cutoff = snap.values[@intFromEnum(ParamID.filter_cutoff)];
        if (cutoff != 0.0 and cutoff != 10000.0 and cutoff != 1000.0) {
            torn_read = true;
            break;
        }
        if (snap.version < last_version) {
            monotonic = false;
            break;
        }
        last_version = snap.version;
    }

    writer.join();
    try std.testing.expect(!torn_read);
    try std.testing.expect(monotonic);
    try std.testing.expect(reads > 0);
}
