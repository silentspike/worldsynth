const std = @import("std");

// ── Ableton Link (WP-131) ───────────────────────────────────────────
// Standalone Link session wrapper with hand-written C ABI bindings.
// No @cImport. Runtime dynamic loading keeps builds working on systems
// without the Link library installed.
//
// Design:
// - `init()` tries to load Link library and create a real session.
// - `init_simulated()` provides deterministic behavior for CI/tests.
// - API always exposes tempo/beat/phase/peer_count.

pub const LinkError = error{
    InvalidTempo,
    InvalidQuantum,
    LinkLibraryUnavailable,
    LinkInitFailed,
};

pub const LinkSnapshot = struct {
    tempo_bpm: f64,
    enabled: bool,
    beat_origin: f64,
    epoch_ns: i128,
};

pub const LinkSession = struct {
    backend: Backend,

    const Backend = union(enum) {
        c_api: CBackend,
        simulated: SimBackend,
    };

    const CBackend = struct {
        lib: std.DynLib,
        fns: ApiFns,
        handle: ?*anyopaque,
        state: LinkSnapshot,
        closed: bool = false,
    };

    const SimBackend = struct {
        state: LinkSnapshot,
    };

    const ApiFns = struct {
        create: *const fn (f64) callconv(.c) ?*anyopaque,
        destroy: *const fn (?*anyopaque) callconv(.c) void,
        enable: ?*const fn (?*anyopaque, c_int) callconv(.c) void = null,
        set_tempo: ?*const fn (?*anyopaque, f64) callconv(.c) void = null,
        get_tempo: ?*const fn (?*anyopaque) callconv(.c) f64 = null,
        get_beat_at_time: ?*const fn (?*anyopaque, i64, f64) callconv(.c) f64 = null,
        get_phase: ?*const fn (?*anyopaque, i64, f64) callconv(.c) f64 = null,
        peer_count: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    };

    const default_lib_names = [_][]const u8{
        "libableton_link.so",
        "libableton-link.so",
        "libabl_link.so",
        "libableton_link.dylib",
        "libableton-link.dylib",
        "ableton_link.dll",
    };

    pub fn init(default_tempo_bpm: f64) LinkError!LinkSession {
        return init_with_library_names(default_tempo_bpm, default_lib_names[0..]);
    }

    pub fn init_simulated(default_tempo_bpm: f64) LinkError!LinkSession {
        const tempo = validate_tempo(default_tempo_bpm) catch return error.InvalidTempo;
        return .{
            .backend = .{
                .simulated = .{
                    .state = .{
                        .tempo_bpm = tempo,
                        .enabled = false,
                        .beat_origin = 0.0,
                        .epoch_ns = now_ns(),
                    },
                },
            },
        };
    }

    pub fn deinit(self: *LinkSession) void {
        switch (self.backend) {
            .c_api => |*c| {
                if (c.closed) return;
                if (c.handle) |h| {
                    c.fns.destroy(h);
                    c.handle = null;
                }
                c.lib.close();
                c.state.enabled = false;
                c.closed = true;
            },
            .simulated => |*s| {
                s.state.enabled = false;
            },
        }
    }

    pub fn enable(self: *LinkSession, enabled: bool) void {
        switch (self.backend) {
            .c_api => |*c| {
                c.state.enabled = enabled;
                if (c.closed) return;
                if (c.handle) |h| {
                    if (c.fns.enable) |f| {
                        f(h, if (enabled) 1 else 0);
                    }
                }
            },
            .simulated => |*s| {
                s.state.enabled = enabled;
            },
        }
    }

    pub fn disable(self: *LinkSession) void {
        self.enable(false);
    }

    pub fn get_tempo(self: *const LinkSession) f64 {
        return switch (self.backend) {
            .c_api => |c| blk: {
                if (!c.closed) {
                    if (c.handle) |h| {
                        if (c.fns.get_tempo) |f| {
                            const t = f(h);
                            if (std.math.isFinite(t) and t > 0.0) break :blk t;
                        }
                    }
                }
                break :blk c.state.tempo_bpm;
            },
            .simulated => |s| s.state.tempo_bpm,
        };
    }

    pub fn set_tempo(self: *LinkSession, bpm: f64) LinkError!void {
        const tempo = validate_tempo(bpm) catch return error.InvalidTempo;
        const t = now_ns();
        const beat_now = self.get_beat_at_time(t);

        switch (self.backend) {
            .c_api => |*c| {
                c.state.tempo_bpm = tempo;
                c.state.beat_origin = beat_now;
                c.state.epoch_ns = t;
                if (!c.closed) {
                    if (c.handle) |h| {
                        if (c.fns.set_tempo) |f| f(h, tempo);
                    }
                }
            },
            .simulated => |*s| {
                s.state.tempo_bpm = tempo;
                s.state.beat_origin = beat_now;
                s.state.epoch_ns = t;
            },
        }
    }

    pub fn get_beat_at_time(self: *const LinkSession, time_ns: i128) f64 {
        return switch (self.backend) {
            .c_api => |c| blk: {
                if (!c.closed) {
                    if (c.handle) |h| {
                        if (c.fns.get_beat_at_time) |f| {
                            const b = f(h, to_i64_sat(time_ns), 4.0);
                            if (std.math.isFinite(b)) break :blk b;
                        }
                    }
                }
                break :blk beat_at(&c.state, time_ns);
            },
            .simulated => |s| beat_at(&s.state, time_ns),
        };
    }

    pub fn get_phase(self: *const LinkSession, time_ns: i128, quantum: f64) LinkError!f64 {
        if (!std.math.isFinite(quantum) or quantum <= 0.0) return error.InvalidQuantum;

        return switch (self.backend) {
            .c_api => |c| blk: {
                if (!c.closed) {
                    if (c.handle) |h| {
                        if (c.fns.get_phase) |f| {
                            const p = f(h, to_i64_sat(time_ns), quantum);
                            if (std.math.isFinite(p)) break :blk positive_mod(p, quantum);
                        }
                    }
                }
                const b = beat_at(&c.state, time_ns);
                break :blk positive_mod(b, quantum);
            },
            .simulated => |s| positive_mod(beat_at(&s.state, time_ns), quantum),
        };
    }

    pub fn peer_count(self: *const LinkSession) u32 {
        return switch (self.backend) {
            .c_api => |c| blk: {
                if (!c.closed) {
                    if (c.handle) |h| {
                        if (c.fns.peer_count) |f| {
                            const v = f(h);
                            if (v >= 0) break :blk @as(u32, @intCast(v));
                        }
                    }
                }
                break :blk if (c.state.enabled) 1 else 0;
            },
            .simulated => |s| if (s.state.enabled) 1 else 0,
        };
    }

    pub fn simulate_peer_tempo(self: *LinkSession, bpm: f64) LinkError!void {
        // test helper: emulate remote peer tempo update
        return self.set_tempo(bpm);
    }
};

fn init_with_library_names(default_tempo_bpm: f64, names: []const []const u8) LinkError!LinkSession {
    const tempo = validate_tempo(default_tempo_bpm) catch return error.InvalidTempo;

    var lib_opt: ?std.DynLib = null;
    for (names) |name| {
        lib_opt = std.DynLib.open(name) catch null;
        if (lib_opt != null) break;
    }
    var lib = lib_opt orelse return error.LinkLibraryUnavailable;
    errdefer lib.close();

    const fns = load_api_fns(&lib) orelse return error.LinkLibraryUnavailable;
    const handle = fns.create(tempo) orelse return error.LinkInitFailed;

    return .{
        .backend = .{
            .c_api = .{
                .lib = lib,
                .fns = fns,
                .handle = handle,
                .state = .{
                    .tempo_bpm = tempo,
                    .enabled = false,
                    .beat_origin = 0.0,
                    .epoch_ns = now_ns(),
                },
                .closed = false,
            },
        },
    };
}

fn load_api_fns(lib: *std.DynLib) ?LinkSession.ApiFns {
    const create = lookup_fn(lib, *const fn (f64) callconv(.c) ?*anyopaque, "abl_link_create") orelse return null;
    const destroy = lookup_fn(lib, *const fn (?*anyopaque) callconv(.c) void, "abl_link_destroy") orelse return null;

    return .{
        .create = create,
        .destroy = destroy,
        .enable = lookup_fn(lib, *const fn (?*anyopaque, c_int) callconv(.c) void, "abl_link_enable"),
        .set_tempo = lookup_fn(lib, *const fn (?*anyopaque, f64) callconv(.c) void, "abl_link_set_tempo"),
        .get_tempo = lookup_fn(lib, *const fn (?*anyopaque) callconv(.c) f64, "abl_link_get_tempo"),
        .get_beat_at_time = lookup_fn(lib, *const fn (?*anyopaque, i64, f64) callconv(.c) f64, "abl_link_get_beat_at_time"),
        .get_phase = lookup_fn(lib, *const fn (?*anyopaque, i64, f64) callconv(.c) f64, "abl_link_get_phase"),
        .peer_count = lookup_fn(lib, *const fn (?*anyopaque) callconv(.c) c_int, "abl_link_peer_count"),
    };
}

fn lookup_fn(lib: *std.DynLib, comptime T: type, name: [:0]const u8) ?T {
    return lib.lookup(T, name);
}

fn validate_tempo(bpm: f64) LinkError!f64 {
    if (!std.math.isFinite(bpm) or bpm <= 0.0) return error.InvalidTempo;
    return bpm;
}

fn beat_at(state: *const LinkSnapshot, t_ns: i128) f64 {
    const dt = @as(f64, @floatFromInt(t_ns - state.epoch_ns)) * 1e-9;
    return state.beat_origin + dt * state.tempo_bpm / 60.0;
}

fn positive_mod(x: f64, quantum: f64) f64 {
    var r = @mod(x, quantum);
    if (r < 0.0) r += quantum;
    return r;
}

fn to_i64_sat(v: i128) i64 {
    if (v > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (v < std.math.minInt(i64)) return std.math.minInt(i64);
    return @as(i64, @intCast(v));
}

fn now_ns() i128 {
    return std.time.nanoTimestamp();
}

// ── Tests ─────────────────────────────────────────────────────────────

test "AC-1: session create + enable gives peer_count=1 (self)" {
    var s = try LinkSession.init_simulated(120.0);
    defer s.deinit();
    s.enable(true);
    try std.testing.expectEqual(@as(u32, 1), s.peer_count());
}

test "disable turns link participation off" {
    var s = try LinkSession.init_simulated(120.0);
    defer s.deinit();
    s.enable(true);
    s.disable();
    try std.testing.expectEqual(@as(u32, 0), s.peer_count());
}

test "AC-2: tempo sync updates local tempo" {
    var s = try LinkSession.init_simulated(120.0);
    defer s.deinit();
    s.enable(true);
    try s.simulate_peer_tempo(133.0);
    try std.testing.expectApproxEqAbs(@as(f64, 133.0), s.get_tempo(), 0.0001);
}

test "AC-3: beat position rises continuously" {
    var s = try LinkSession.init_simulated(120.0);
    defer s.deinit();
    s.enable(true);
    const t0 = now_ns();
    const b0 = s.get_beat_at_time(t0);
    const b1 = s.get_beat_at_time(t0 + 100_000_000); // +100ms
    try std.testing.expect(b1 > b0);
}

test "AC-4: deinit frees resources (idempotent)" {
    var s = try LinkSession.init_simulated(120.0);
    s.enable(true);
    s.deinit();
    // second deinit should still be safe
    s.deinit();
}

test "phase query returns valid range" {
    var s = try LinkSession.init_simulated(120.0);
    defer s.deinit();
    const p = try s.get_phase(now_ns(), 4.0);
    try std.testing.expect(p >= 0.0 and p < 4.0);
}

test "AC-N1: missing link library returns graceful error" {
    const fake_names = [_][]const u8{"lib_ableton_link_definitely_missing.so"};
    const r = init_with_library_names(120.0, fake_names[0..]);
    try std.testing.expectError(error.LinkLibraryUnavailable, r);
}

test "AC-B1: simulated link latency and phase benchmarks" {
    var timer = try std.time.Timer.start();

    // Join latency
    var s = try LinkSession.init_simulated(120.0);
    s.enable(true);
    const join_us = @as(f64, @floatFromInt(timer.read())) / 1000.0;

    // Beat/phase over 60s simulated horizon
    const t0 = now_ns();
    const b0 = s.get_beat_at_time(t0);
    const t60 = t0 + 60 * std.time.ns_per_s;
    const b60 = s.get_beat_at_time(t60);
    const expected_beats = 60.0 * s.get_tempo() / 60.0;
    const beat_drift_beats = @abs((b60 - b0) - expected_beats);
    const beat_drift_ms = beat_drift_beats * (60_000.0 / s.get_tempo());

    // Tempo update latency
    timer.reset();
    try s.simulate_peer_tempo(128.0);
    _ = s.get_tempo();
    const tempo_update_us = @as(f64, @floatFromInt(timer.read())) / 1000.0;

    // Phase query latency
    timer.reset();
    _ = try s.get_phase(now_ns(), 4.0);
    const phase_us = @as(f64, @floatFromInt(timer.read())) / 1000.0;

    std.debug.print(
        \\
        \\  [WP-131] Ableton Link Benchmark (simulated)
        \\    join:         {d:.3} us (threshold < 100000.0 us)
        \\    beat drift:   {d:.6} ms over 60s (threshold < 1.0 ms)
        \\    tempo update: {d:.3} us (threshold < 10000.0 us)
        \\    phase query:  {d:.3} us (threshold < 1000.0 us)
        \\
    , .{ join_us, beat_drift_ms, tempo_update_us, phase_us });

    try std.testing.expect(join_us < 100_000.0);
    try std.testing.expect(beat_drift_ms < 1.0);
    try std.testing.expect(tempo_update_us < 10_000.0);
    try std.testing.expect(phase_us < 1_000.0);
}
