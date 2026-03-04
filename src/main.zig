const std = @import("std");

pub const engine = struct {
    pub const tables = @import("engine/tables.zig");
    pub const tables_adaa = @import("engine/tables_adaa.zig");
    pub const tables_blep = @import("engine/tables_blep.zig");
    pub const tables_approx = @import("engine/tables_approx.zig");
    pub const tables_simd = @import("engine/tables_simd.zig");
    pub const param = @import("engine/param.zig");
    pub const param_smooth = @import("engine/param_smooth.zig");
    pub const undo = @import("engine/undo.zig");
    pub const microtuning = @import("engine/microtuning.zig");
    pub const bench = @import("engine/bench.zig");
    pub const engine_core = @import("engine/engine.zig");
};

pub const dsp = struct {
    pub const voice = @import("dsp/voice.zig");
    pub const drift = @import("dsp/drift.zig");
    pub const oscillator = @import("dsp/oscillator.zig");
    pub const osc_sine_noise = @import("dsp/osc_sine_noise.zig");
    pub const filter = @import("dsp/filter.zig");
    pub const ladder = @import("dsp/ladder.zig");
    pub const envelope = @import("dsp/envelope.zig");
    pub const voice_manager = @import("dsp/voice_manager.zig");
};

pub const platform = struct {
    pub const ring_buffer = @import("platform/ring_buffer.zig");
};

pub const io = struct {
    pub const jack = @import("io/jack.zig");
    pub const pipewire = @import("io/pipewire.zig");
    pub const alsa = @import("io/alsa.zig");
    pub const rt = @import("io/rt.zig");
    pub const audio_backend = @import("io/audio_backend.zig");
    pub const osc = @import("io/osc.zig");
    pub const midi_learn = @import("io/midi_learn.zig");
    pub const midi = @import("io/midi.zig");
};

const build_options = @import("build_options");
const Engine = @import("engine/engine.zig").Engine;
const jack_mod = @import("io/jack.zig");

// ── Global Engine reference for RT callbacks ─────────────────────────
// JACK/PipeWire callbacks are plain function pointers without context.
// Set BEFORE backend.start(), cleared AFTER backend.stop().
var global_engine: ?*Engine = null;

// ── Global backend reference for signal handler ──────────────────────
// PipeWire blocks in pw_main_loop_run — signal handler must call quit().
var global_backend: ?*io.audio_backend.AudioBackend = null;

// ── Signal handler for clean shutdown ────────────────────────────────
var running = std.atomic.Value(bool).init(true);

fn sighandler(_: c_int) callconv(.c) void {
    running.store(false, .release);
    // Unblock PipeWire's pw_main_loop_run (signal-safe)
    if (global_backend) |b| b.quit();
}

// ══════════════════════════════════════════════════════════════════════
// ZERO-OVERHEAD MONITORING — SPSC Ring Buffer Architecture
// ══════════════════════════════════════════════════════════════════════
// Audio callback writes ONLY to ring buffer + 3 atomics (~150ns total).
// ALL analysis (peak, RMS, clips, stutters, noise floor) runs in the
// monitor thread, reading from the ring buffer. Zero impact on audio.
// ══════════════════════════════════════════════════════════════════════

// ── SPSC ring buffer: audio thread → monitor thread ──
// Power-of-2 size for fast modular arithmetic (& mask).
const MON_RING_BITS: u5 = 16;
const MON_RING_SIZE: u32 = 1 << MON_RING_BITS; // 65536 = 1.36s at 48kHz
const MON_RING_MASK: u32 = MON_RING_SIZE - 1;
var mon_ring_l: [MON_RING_SIZE]f32 = [_]f32{0.0} ** MON_RING_SIZE;
var mon_ring_r: [MON_RING_SIZE]f32 = [_]f32{0.0} ** MON_RING_SIZE;
var mon_ring_head = std.atomic.Value(u32).init(0); // write position (audio thread ONLY)

// ── Atomics written by audio callback (minimal — 3 stores + timing) ──
var mon_voices = std.atomic.Value(u32).init(0);
var mon_n_frames = std.atomic.Value(u32).init(0);
var mon_cb_last_ns = std.atomic.Value(u64).init(0); // last callback process time (ns)
var mon_cb_count = std.atomic.Value(u64).init(0); // callback count
var mon_cb_sum_ns = std.atomic.Value(u64).init(0); // cumulative ns (for avg)
var mon_cb_max_ns = std.atomic.Value(u64).init(0); // worst-case ns
var mon_xrun_count = std.atomic.Value(u32).init(0); // callbacks exceeding budget

// ── Atomics written by monitor thread (all analysis results) ──
var mon_peak_l = std.atomic.Value(u32).init(0); // interval peak * 10000
var mon_peak_r = std.atomic.Value(u32).init(0);
var mon_true_peak = std.atomic.Value(u32).init(0); // session max peak * 10000
var mon_clip_count = std.atomic.Value(u32).init(0); // cumulative clipped samples
var mon_dropout_count = std.atomic.Value(u32).init(0); // audio→silence transitions
var mon_silent_blocks = std.atomic.Value(u32).init(0); // silence while voices active
var mon_discontinuities = std.atomic.Value(u32).init(0); // large sample jumps
var mon_stutter_count = std.atomic.Value(u32).init(0); // silence gaps >1ms during playback
var mon_stutter_max_samples = std.atomic.Value(u32).init(0); // longest stutter in samples
var mon_noise_floor = std.atomic.Value(u32).init(0); // max |sample|*1e6 when voices=0
var mon_rms_val = std.atomic.Value(u32).init(0); // RMS * 10000
var mon_dc_offset = std.atomic.Value(i32).init(0); // DC offset * 1e6

// ── Live capture (--capture mode, streaming WAV writer in monitor thread) ──
var capture_enabled: bool = false; // set in main(), read in monitorThread

// ── MIDI-to-audio latency measurement ──
var mon_midi_arrival_ns = std.atomic.Value(i64).init(0); // timestamp of last Note On (MIDI thread)
var mon_midi_latency_ns = std.atomic.Value(u64).init(0); // MIDI→dispatch latency (ns)
var mon_midi_latency_max_ns = std.atomic.Value(u64).init(0); // worst-case MIDI→dispatch (ns)
var mon_midi_latency_count = std.atomic.Value(u32).init(0); // count of measurements

// ── Waveform capture (1s of audio for analysis) ──
// Armed by test thread, captured in audio callback (RT-safe: just array writes).
// Written to WAV file from test thread after capture completes.
const WAVE_CAP_RATE: usize = 48000;
const WAVE_CAP_SIZE: usize = 24000; // 0.5s at 48kHz — enough for spectral analysis
var wave_cap_l: [WAVE_CAP_SIZE]f32 = [_]f32{0.0} ** WAVE_CAP_SIZE;
var wave_cap_r: [WAVE_CAP_SIZE]f32 = [_]f32{0.0} ** WAVE_CAP_SIZE;
var wave_cap_pos: usize = 0;
var wave_cap_armed = std.atomic.Value(bool).init(false);
var wave_cap_done = std.atomic.Value(bool).init(false);
var wave_cap_n_frames: u32 = 0;
const WAVE_CAP_PATH = "/tmp/worldsynth-capture.wav";

// MIDI event ring buffer (lock-free, single producer RT → single consumer monitor)
const MIDI_LOG_SIZE = 64;
const MidiLogEntry = struct {
    note: u8 = 0,
    velocity: u8 = 0,
    is_note_on: bool = false,
    channel: u4 = 0,
};
var midi_log: [MIDI_LOG_SIZE]MidiLogEntry = [_]MidiLogEntry{.{}} ** MIDI_LOG_SIZE;
var midi_log_write = std.atomic.Value(u32).init(0);
var midi_log_read: u32 = 0; // only read from monitor thread

// ── Sine test mode: bypass engine, pure 440Hz sine → ALSA output ──
// Tests the ALSA conversion + output path in isolation.
var test_sine_mode = std.atomic.Value(bool).init(false);
var sine_phase: f32 = 0.0; // audio-thread only

// ── Software MIDI injection (test thread → audio callback, RT-safe) ──
// SPSC ring buffer: test/external thread writes, audio callback reads.
// Events dispatched to engine INSIDE the audio callback for thread safety
// (no concurrent access to engine state).
const SOFT_MIDI_SIZE = 256;
const SoftMidiEvent = struct {
    bytes: [3]u8 = .{ 0, 0, 0 },
};
var soft_midi_buf: [SOFT_MIDI_SIZE]SoftMidiEvent = [_]SoftMidiEvent{.{}} ** SOFT_MIDI_SIZE;
var soft_midi_write = std.atomic.Value(u32).init(0);
var soft_midi_read: u32 = 0; // only read from audio callback (single consumer)

/// Inject a MIDI event from any thread. RT-safe on the read side.
fn injectMidi(bytes: *const [3]u8) void {
    const w = soft_midi_write.load(.monotonic);
    soft_midi_buf[w % SOFT_MIDI_SIZE] = .{ .bytes = bytes.* };
    soft_midi_write.store(w +% 1, .release);
}

// ── Audio callback: Engine.process wrapper ───────────────────────────
// Engine.process handles at most BLOCK_SIZE (128) samples at a time.
// JACK/PipeWire may request larger buffers — process in chunks.
const EngineModule = @import("engine/engine.zig");

/// Fast tanh approximation for soft clipping — Padé[1,1] approximant.
/// Maps any input smoothly to [-1, +1]. No branches in normal range.
/// Max error vs std.math.tanh: < 0.004 for |x| < 2.0.
inline fn softClip(x: f32) f32 {
    const x2 = x * x;
    if (x2 > 9.0) return if (x > 0) @as(f32, 1.0) else @as(f32, -1.0);
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

fn audioCallback(out_l: [*]f32, out_r: [*]f32, n_frames: u32) void {
    // ── Sine test mode: pure 440Hz sine, bypass engine entirely ──
    if (test_sine_mode.load(.monotonic)) {
        const sr: f32 = if (global_engine) |e| e.sample_rate else 48000.0;
        const inc: f32 = 440.0 / sr;
        for (0..n_frames) |i| {
            const val: f32 = @sin(sine_phase * 2.0 * std.math.pi) * 0.5;
            out_l[i] = val;
            out_r[i] = val;
            sine_phase += inc;
            if (sine_phase >= 1.0) sine_phase -= 1.0;
        }
        // Ring buffer write even in sine mode (monitor needs data)
        const w0 = mon_ring_head.load(.monotonic);
        for (0..n_frames) |i| {
            mon_ring_l[(w0 +% @as(u32, @intCast(i))) & MON_RING_MASK] = out_l[i];
            mon_ring_r[(w0 +% @as(u32, @intCast(i))) & MON_RING_MASK] = out_r[i];
        }
        mon_ring_head.store(w0 +% @as(u32, @intCast(n_frames)), .release);
        mon_n_frames.store(n_frames, .release);
        return;
    }

    if (global_engine) |eng| {
        // 1. Dispatch injected MIDI events (reads + calls only, no alloc)
        const sw = soft_midi_write.load(.acquire);
        var had_note_on = false;
        while (soft_midi_read != sw) {
            const evt = &soft_midi_buf[soft_midi_read % SOFT_MIDI_SIZE];
            if (evt.bytes[0] & 0xF0 == 0x90 and evt.bytes[2] > 0) had_note_on = true;
            eng.handle_midi_event(&evt.bytes);
            soft_midi_read +%= 1;
        }
        // MIDI→audio latency: time from MIDI arrival to audio dispatch
        if (had_note_on) {
            const arrival = mon_midi_arrival_ns.load(.acquire);
            if (arrival > 0) {
                const now: i64 = @truncate(std.time.nanoTimestamp());
                const delta = now - arrival;
                if (delta > 0 and delta < 100_000_000) { // sanity: < 100ms
                    const latency: u64 = @intCast(delta);
                    mon_midi_latency_ns.store(latency, .release);
                    const old_max = mon_midi_latency_max_ns.load(.monotonic);
                    if (latency > old_max) mon_midi_latency_max_ns.store(latency, .monotonic);
                    _ = mon_midi_latency_count.fetchAdd(1, .monotonic);
                }
                mon_midi_arrival_ns.store(0, .release); // consumed
            }
        }

        // 2. Process audio in chunks (timed — two vDSO calls, ~30ns)
        const t0 = std.time.Instant.now() catch null;
        var offset: u32 = 0;
        while (offset < n_frames) {
            const chunk: u32 = @min(EngineModule.BLOCK_SIZE, n_frames - offset);
            eng.process(out_l[offset..][0..chunk], out_r[offset..][0..chunk], chunk);
            offset += chunk;
        }
        if (t0) |start| {
            if (std.time.Instant.now()) |end| {
                const elapsed = end.since(start);
                mon_cb_last_ns.store(elapsed, .release);
                _ = mon_cb_sum_ns.fetchAdd(elapsed, .monotonic);
                const old_max = mon_cb_max_ns.load(.monotonic);
                if (elapsed > old_max) mon_cb_max_ns.store(elapsed, .monotonic);
                const budget = @as(u64, n_frames) * 1_000_000_000 / 48000;
                if (elapsed > budget) _ = mon_xrun_count.fetchAdd(1, .monotonic);
            } else |_| {}
        }
        _ = mon_cb_count.fetchAdd(1, .monotonic);

        // 3. Copy output to monitor ring buffer (~100ns for 256 samples)
        //    This is the ONLY output-touching code after process().
        const w = mon_ring_head.load(.monotonic);
        for (0..n_frames) |i| {
            mon_ring_l[(w +% @as(u32, @intCast(i))) & MON_RING_MASK] = out_l[i];
            mon_ring_r[(w +% @as(u32, @intCast(i))) & MON_RING_MASK] = out_r[i];
        }
        mon_ring_head.store(w +% @as(u32, @intCast(n_frames)), .release);

        // 4. Publish voice count + buffer size (2 atomic stores)
        mon_voices.store(eng.voice_manager.active_count(), .release);
        mon_n_frames.store(n_frames, .release);
    } else {
        @memset(out_l[0..n_frames], 0);
        @memset(out_r[0..n_frames], 0);
    }
}

// ── MIDI callback: MidiEvent → software MIDI ring buffer ─────────────
// Thread-safe: works from JACK RT thread AND ALSA rawmidi thread.
// Events are dispatched to engine INSIDE audioCallback (single-threaded access).
fn midiCallback(event: jack_mod.MidiEvent) void {
    // Timestamp Note On arrival for latency measurement
    if (event.status == .note_on and event.data2 > 0) {
        mon_midi_arrival_ns.store(@truncate(std.time.nanoTimestamp()), .release);
    }
    var buf: [3]u8 = undefined;
    buf[0] = (@as(u8, @intFromEnum(event.status)) << 4) | event.channel;
    buf[1] = event.data1;
    buf[2] = event.data2;
    injectMidi(&buf);
}

// ── Monitor thread: reads ring buffer, performs ALL analysis ──────────
// Zero impact on audio thread. Runs every 50ms, processes all new samples
// from the SPSC ring buffer. Detects peaks, clips, stutters, noise floor,
// dropouts, discontinuities, DC offset — all outside the RT path.
fn monitorThread(sample_rate_val: u32) void {
    const note_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const sr: f64 = @floatFromInt(sample_rate_val);

    // ── Local analysis state (never touched by audio thread) ──
    var ring_read_pos: u32 = 0;
    var prev_sl: f32 = 0.0;
    var prev_sr: f32 = 0.0;
    var prev_had_audio: bool = false;

    // Cumulative counters (published to atomics for health report)
    var total_clips: u32 = 0;
    var total_dropouts: u32 = 0;
    var total_silent_active: u32 = 0;
    var total_disc: u32 = 0;
    var total_stutters: u32 = 0;
    var max_stutter_len: u32 = 0;
    var true_peak: f32 = 0.0;
    var rms_sum: f64 = 0.0;
    var rms_count: u64 = 0;
    var dc_sum: f64 = 0.0;
    var noise_floor_max: f32 = 0.0;

    // Stutter detection: consecutive near-zero samples during active playback
    var zero_run_len: u32 = 0;
    const STUTTER_THRESH: u32 = 48; // >1ms at 48kHz = stutter

    // ── Streaming WAV capture (--capture mode) ──
    var cap_file: ?std.fs.File = null;
    var cap_written: u64 = 0;
    const CAP_BUF_SAMPLES = 2048;
    var cap_buf: [CAP_BUF_SAMPLES * 8]u8 = undefined; // 2048 stereo f32 frames
    var cap_buf_pos: usize = 0;
    if (capture_enabled) {
        if (std.fs.cwd().createFile("/tmp/worldsynth-live.wav", .{})) |f| {
            cap_file = f;
            // Write placeholder WAV header (44 bytes, data_size updated at shutdown)
            var hdr: [44]u8 = undefined;
            @memcpy(hdr[0..4], "RIFF");
            std.mem.writeInt(u32, hdr[4..8], 36, .little);
            @memcpy(hdr[8..12], "WAVE");
            @memcpy(hdr[12..16], "fmt ");
            std.mem.writeInt(u32, hdr[16..20], 16, .little);
            std.mem.writeInt(u16, hdr[20..22], 3, .little); // IEEE float
            std.mem.writeInt(u16, hdr[22..24], 2, .little); // stereo
            std.mem.writeInt(u32, hdr[24..28], sample_rate_val, .little);
            std.mem.writeInt(u32, hdr[28..32], sample_rate_val * 2 * 4, .little);
            std.mem.writeInt(u16, hdr[32..34], 8, .little); // block align
            std.mem.writeInt(u16, hdr[34..36], 32, .little); // bits
            @memcpy(hdr[36..40], "data");
            std.mem.writeInt(u32, hdr[40..44], 0, .little);
            f.writeAll(&hdr) catch {};
            std.debug.print("  [CAPTURE] Recording to /tmp/worldsynth-live.wav — Ctrl+C to stop\n", .{});
        } else |err| {
            std.debug.print("  [CAPTURE] Failed to create WAV: {}\n", .{err});
        }
    }

    while (running.load(.acquire)) {
        // ── MIDI events ──
        const mw = midi_log_write.load(.acquire);
        while (midi_log_read < mw) {
            const entry = midi_log[midi_log_read % MIDI_LOG_SIZE];
            const name = note_names[entry.note % 12];
            const octave: i8 = @as(i8, @intCast(entry.note / 12)) - 1;
            if (entry.is_note_on) {
                std.debug.print("  MIDI: ON  {s}{d} (note={d}, vel={d}, ch={d})\n", .{ name, octave, entry.note, entry.velocity, entry.channel });
            } else {
                std.debug.print("  MIDI: OFF {s}{d} (note={d}, ch={d})\n", .{ name, octave, entry.note, entry.channel });
            }
            midi_log_read += 1;
        }

        // ── Read ring buffer: process ALL new samples ──
        const head = mon_ring_head.load(.acquire);
        const voices = mon_voices.load(.acquire);
        const n_fr = mon_n_frames.load(.acquire);

        var interval_peak_l: f32 = 0.0;
        var interval_peak_r: f32 = 0.0;
        var interval_clips: u32 = 0;
        var interval_has_audio: bool = false;
        var interval_disc: u32 = 0;
        var interval_stutters: u32 = 0;
        var interval_silent_active: u32 = 0;
        var interval_samples: u32 = 0;

        while (ring_read_pos != head) {
            const pos = ring_read_pos & MON_RING_MASK;
            const sl = mon_ring_l[pos];
            const sr_s = mon_ring_r[pos];

            const al = @abs(sl);
            const ar = @abs(sr_s);

            // Peak
            if (al > interval_peak_l) interval_peak_l = al;
            if (ar > interval_peak_r) interval_peak_r = ar;

            // Clip
            if (al >= 1.0 or ar >= 1.0) interval_clips += 1;

            // Has audio (above noise threshold)
            const sample_has_audio = (al > 0.00001 or ar > 0.00001);
            if (sample_has_audio) {
                // End of zero run — check if stutter
                if (zero_run_len >= STUTTER_THRESH and voices > 0) {
                    interval_stutters += 1;
                    if (zero_run_len > max_stutter_len) max_stutter_len = zero_run_len;
                }
                zero_run_len = 0;
                interval_has_audio = true;
            } else {
                zero_run_len += 1;
                // Silent sample while voices active
                if (voices > 0) interval_silent_active += 1;
            }

            // Discontinuity (large jump between consecutive samples)
            if (@abs(sl - prev_sl) > 0.5) interval_disc += 1;

            // RMS + DC accumulation
            rms_sum += @as(f64, sl) * @as(f64, sl) + @as(f64, sr_s) * @as(f64, sr_s);
            rms_count += 2;
            dc_sum += @as(f64, sl) + @as(f64, sr_s);

            // Noise floor: max |sample| when NO voices are active
            // (should be exactly 0.0 — any non-zero value = noise)
            if (voices == 0) {
                if (al > noise_floor_max) noise_floor_max = al;
                if (ar > noise_floor_max) noise_floor_max = ar;
            }

            // Wave capture (in monitor thread — no RT impact)
            if (wave_cap_armed.load(.monotonic) and !wave_cap_done.load(.monotonic)) {
                if (wave_cap_pos < WAVE_CAP_SIZE) {
                    wave_cap_l[wave_cap_pos] = sl;
                    wave_cap_r[wave_cap_pos] = sr_s;
                    wave_cap_pos += 1;
                    if (wave_cap_pos >= WAVE_CAP_SIZE) {
                        wave_cap_n_frames = n_fr;
                        wave_cap_done.store(true, .release);
                        wave_cap_armed.store(false, .release);
                    }
                }
            }

            prev_sl = sl;
            prev_sr = sr_s;
            interval_samples += 1;

            // Streaming capture to WAV file (--capture mode)
            if (cap_file) |f| {
                @memcpy(cap_buf[cap_buf_pos..][0..4], std.mem.asBytes(&sl));
                cap_buf_pos += 4;
                @memcpy(cap_buf[cap_buf_pos..][0..4], std.mem.asBytes(&sr_s));
                cap_buf_pos += 4;
                cap_written += 1;
                if (cap_buf_pos >= CAP_BUF_SAMPLES * 8) {
                    f.writeAll(cap_buf[0..cap_buf_pos]) catch {};
                    cap_buf_pos = 0;
                }
            }

            ring_read_pos +%= 1;
        }

        // ── Update cumulative counters ──
        total_clips += interval_clips;
        total_disc += interval_disc;
        total_stutters += interval_stutters;
        total_silent_active += interval_silent_active;
        if (interval_peak_l > true_peak) true_peak = interval_peak_l;
        if (interval_peak_r > true_peak) true_peak = interval_peak_r;

        // Dropout detection (had audio → silence while voices active)
        if (!interval_has_audio and voices > 0 and prev_had_audio) {
            total_dropouts += 1;
        }
        prev_had_audio = interval_has_audio;

        // ── Publish to atomics (for health report + VU display) ──
        mon_peak_l.store(@intFromFloat(interval_peak_l * 10000.0), .release);
        mon_peak_r.store(@intFromFloat(interval_peak_r * 10000.0), .release);
        mon_true_peak.store(@intFromFloat(true_peak * 10000.0), .release);
        mon_clip_count.store(total_clips, .release);
        mon_dropout_count.store(total_dropouts, .release);
        mon_silent_blocks.store(total_silent_active, .release);
        mon_discontinuities.store(total_disc, .release);
        mon_stutter_count.store(total_stutters, .release);
        mon_stutter_max_samples.store(max_stutter_len, .release);
        mon_noise_floor.store(@intFromFloat(noise_floor_max * 1000000.0), .release);
        if (rms_count > 0) {
            const rms_linear: f32 = @floatCast(@sqrt(rms_sum / @as(f64, @floatFromInt(rms_count))));
            mon_rms_val.store(@intFromFloat(rms_linear * 10000.0), .release);
            const dc_off: f32 = @floatCast(dc_sum / @as(f64, @floatFromInt(rms_count)));
            mon_dc_offset.store(@intFromFloat(dc_off * 1000000.0), .release);
        }

        // ── VU meter display ──
        const pk_l = interval_peak_l;
        const pk_r = interval_peak_r;
        const bar_len: usize = 40;
        var bar_l: [bar_len]u8 = [_]u8{'.'} ** bar_len;
        var bar_r: [bar_len]u8 = [_]u8{'.'} ** bar_len;
        const fill_l: usize = @intFromFloat(@min(@as(f32, @floatFromInt(bar_len)), pk_l * @as(f32, @floatFromInt(bar_len))));
        const fill_r: usize = @intFromFloat(@min(@as(f32, @floatFromInt(bar_len)), pk_r * @as(f32, @floatFromInt(bar_len))));
        for (0..fill_l) |i| bar_l[i] = if (i >= bar_len - 4) '!' else '#';
        for (0..fill_r) |i| bar_r[i] = if (i >= bar_len - 4) '!' else '#';

        const db_l: f32 = if (pk_l > 0.00001) 20.0 * @log10(pk_l) else -120.0;
        const db_r: f32 = if (pk_r > 0.00001) 20.0 * @log10(pk_r) else -120.0;
        const buf_lat_ms: f64 = @as(f64, @floatFromInt(n_fr)) / sr * 1000.0;
        const true_pk_db: f32 = if (true_peak > 0.00001) 20.0 * @log10(true_peak) else -120.0;

        // Callback timing (from audio thread atomics)
        const cb_us = mon_cb_last_ns.load(.acquire) / 1000;
        const cb_max_us = mon_cb_max_ns.load(.acquire) / 1000;
        const xruns = mon_xrun_count.load(.acquire);
        const nf_raw = mon_noise_floor.load(.acquire);
        const nf_val: f32 = @as(f32, @floatFromInt(nf_raw)) / 1000000.0;
        const midi_lat_us: u64 = mon_midi_latency_ns.load(.acquire) / 1000;

        // Alert tags
        const clip_tag: []const u8 = if (total_clips > 0) " CLIP!" else "";
        const xrun_tag: []const u8 = if (xruns > 0) " XRUN!" else "";
        const stut_tag: []const u8 = if (total_stutters > 0) " STUT!" else "";
        const nf_tag: []const u8 = if (nf_val > 0.0001) " NOISE!" else "";

        std.debug.print("\r  VU L[{s}] {d:6.1}dB  R[{s}] {d:6.1}dB  v={d} buf={d}({d:.1}ms) proc={d}us max={d}us pk={d:.1}dB c={d} x={d} st={d} nf={d:.0}u d={d} ml={d}us{s}{s}{s}{s}      ", .{
            &bar_l,         db_l,
            &bar_r,         db_r,
            voices,         n_fr,
            buf_lat_ms,     cb_us,
            cb_max_us,      true_pk_db,
            total_clips,    xruns,
            total_stutters,
            nf_val * 1000000.0, // noise floor in micro-units
            total_dropouts,
            midi_lat_us,
            clip_tag,
            xrun_tag,
            stut_tag,
            nf_tag,
        });

        std.Thread.sleep(50 * std.time.ns_per_ms); // 50ms interval (faster than 100ms for stutter visibility)
    }

    // ── Finalize streaming capture ──
    if (cap_file) |f| {
        // Flush remaining buffer
        if (cap_buf_pos > 0) f.writeAll(cap_buf[0..cap_buf_pos]) catch {};
        // Update WAV header with actual data size
        const data_bytes: u32 = @intCast(@min(cap_written * 2 * 4, std.math.maxInt(u32)));
        var sz4: [4]u8 = undefined;
        // RIFF chunk size (offset 4)
        f.seekTo(4) catch {};
        std.mem.writeInt(u32, &sz4, 36 + data_bytes, .little);
        f.writeAll(&sz4) catch {};
        // data chunk size (offset 40)
        f.seekTo(40) catch {};
        std.mem.writeInt(u32, &sz4, data_bytes, .little);
        f.writeAll(&sz4) catch {};
        f.close();
        const dur_s: f64 = @as(f64, @floatFromInt(cap_written)) / sr;
        std.debug.print("\n  [CAPTURE] Saved /tmp/worldsynth-live.wav ({d} samples, {d:.1}s, stereo f32)\n", .{
            cap_written, dur_s,
        });

        // ── Capture session summary ──
        const ml_final = mon_midi_latency_ns.load(.acquire);
        const ml_max_final = mon_midi_latency_max_ns.load(.acquire);
        const ml_cnt_final = mon_midi_latency_count.load(.acquire);
        const xruns_final = mon_xrun_count.load(.acquire);
        const pk_final = @as(f32, @floatFromInt(mon_true_peak.load(.acquire))) / 10000.0;
        const pk_db_final: f32 = if (pk_final > 0.00001) 20.0 * @log10(pk_final) else -120.0;
        std.debug.print("  ── Session Summary ──\n", .{});
        std.debug.print("  Duration        : {d:.1}s\n", .{dur_s});
        std.debug.print("  True peak       : {d:.1} dBFS\n", .{pk_db_final});
        std.debug.print("  XRuns           : {d}\n", .{xruns_final});
        if (ml_cnt_final > 0) {
            const nf_lat = mon_n_frames.load(.acquire);
            const out_ms: f64 = @as(f64, @floatFromInt(nf_lat)) / sr * 1000.0;
            std.debug.print("  MIDI→dispatch   : {d}us (max {d}us, {d} measurements)\n", .{
                ml_final / 1000, ml_max_final / 1000, ml_cnt_final,
            });
            std.debug.print("  Output latency  : {d:.1}ms ({d} frames)\n", .{ out_ms, nf_lat });
            const total_ms: f64 = @as(f64, @floatFromInt(ml_final)) / 1_000_000.0 + out_ms;
            std.debug.print("  Total latency   : {d:.1}ms\n", .{total_ms});
        }
    }
}

// ── WAV file writer (32-bit float, stereo, for audio analysis) ────────
// Called from test thread (not audio thread) — disk I/O is safe here.
fn writeWav(path: [*:0]const u8, left: []const f32, right: []const f32, n_samples: usize, sample_rate: usize) void {
    const channels: u32 = 2;
    const bits: u32 = 32;
    const data_size: u32 = @intCast(n_samples * channels * (bits / 8));
    const file_size: u32 = 36 + data_size;
    const byte_rate: u32 = @intCast(sample_rate * channels * (bits / 8));
    const block_align: u16 = @intCast(channels * (bits / 8));

    const file = std.fs.cwd().createFileZ(path, .{}) catch |err| {
        std.debug.print("  [WAV-CAP] Failed to create {s}: {}\n", .{ path, err });
        return;
    };
    defer file.close();

    // Build 44-byte WAV header (IEEE float format tag = 3)
    var header: [44]u8 = undefined;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], file_size, .little);
    @memcpy(header[8..12], "WAVE");
    @memcpy(header[12..16], "fmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header[20..22], 3, .little); // IEEE float
    std.mem.writeInt(u16, header[22..24], @intCast(channels), .little);
    std.mem.writeInt(u32, header[24..28], @intCast(sample_rate), .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], @intCast(bits), .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_size, .little);

    file.writeAll(&header) catch return;

    // Write interleaved f32 samples in chunks (avoid huge single write)
    const CHUNK = 1024;
    var i: usize = 0;
    while (i < n_samples) {
        const end = @min(i + CHUNK, n_samples);
        var chunk_buf: [CHUNK * 2 * 4]u8 = undefined; // 2 channels × 4 bytes
        var pos: usize = 0;
        for (i..end) |s| {
            @memcpy(chunk_buf[pos..][0..4], std.mem.asBytes(&left[s]));
            pos += 4;
            @memcpy(chunk_buf[pos..][0..4], std.mem.asBytes(&right[s]));
            pos += 4;
        }
        file.writeAll(chunk_buf[0..pos]) catch return;
        i = end;
    }

    std.debug.print("  [WAV-CAP] Written {s} ({d} samples, {d}Hz, stereo f32)\n", .{
        path, n_samples, sample_rate,
    });
}

// ── Software MIDI test (bypasses keyboard/USB/driver entirely) ───────
// Injects Note-On/Off events via ring buffer → audio callback dispatches to engine.
// Phases: 1) Individual notes  2) Chord  3) Rapid fire stress test
fn testMidiThread() void {
    const note_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

    std.debug.print("\n  ═══════════════════════════════════════════════════\n", .{});
    std.debug.print("  [TEST-MIDI] Software MIDI test — bypasses keyboard/USB/driver\n", .{});
    std.debug.print("  ═══════════════════════════════════════════════════\n", .{});
    std.debug.print("  [TEST-MIDI] Waiting 1s for audio to stabilize...\n", .{});
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Phase 0: Waveform capture — play C4 saw for 1s, write WAV for analysis
    std.debug.print("\n  [TEST-MIDI] Phase 0: WAV capture (C4 saw, {d} samples = 0.5s)\n", .{WAVE_CAP_SIZE});
    injectMidi(&.{ 0x90, 60, 100 }); // C4 Note On
    std.Thread.sleep(50 * std.time.ns_per_ms); // let oscillator settle
    wave_cap_armed.store(true, .release);

    // Wait for capture to complete (max 3s for 1s of audio)
    var capture_wait: u32 = 0;
    while (!wave_cap_done.load(.acquire) and capture_wait < 300) : (capture_wait += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    injectMidi(&.{ 0x80, 60, 0 }); // C4 Note Off

    if (wave_cap_done.load(.acquire)) {
        std.debug.print("  [WAV-CAP] Captured {d} samples (callback n_frames={d})\n", .{ WAVE_CAP_SIZE, wave_cap_n_frames });

        // Quick inline analysis (first 32 samples + discontinuities)
        std.debug.print("  [WAV-CAP] First 16 samples:\n", .{});
        for (0..16) |si| {
            std.debug.print("    [{d:3}] L={d:10.6}  R={d:10.6}\n", .{ si, wave_cap_l[si], wave_cap_r[si] });
        }
        var jumps: u32 = 0;
        var zeros: u32 = 0;
        var dupes: u32 = 0;
        for (1..WAVE_CAP_SIZE) |si| {
            if (@abs(wave_cap_l[si] - wave_cap_l[si - 1]) > 0.1) jumps += 1;
            if (wave_cap_l[si] == 0.0 and wave_cap_r[si] == 0.0) zeros += 1;
            if (wave_cap_l[si] == wave_cap_l[si - 1]) dupes += 1;
        }
        std.debug.print("  [WAV-CAP] Quick: jumps={d}, zeros={d}, dupes={d}\n", .{ jumps, zeros, dupes });

        // Write WAV file (32-bit float, stereo)
        writeWav(WAVE_CAP_PATH, &wave_cap_l, &wave_cap_r, WAVE_CAP_SIZE, WAVE_CAP_RATE);
    } else {
        std.debug.print("  [WAV-CAP] TIMEOUT — capture incomplete (audio thread problem?)\n", .{});
    }
    std.Thread.sleep(1 * std.time.ns_per_s); // release envelope

    // Phase 1: Individual notes — each 400ms on, 600ms off
    const test_notes = [_]u8{ 60, 64, 67, 72, 48 }; // C4, E4, G4, C5, C3
    std.debug.print("\n  [TEST-MIDI] Phase 1: Individual notes (5 notes)\n", .{});
    for (test_notes, 0..) |note, i| {
        const name = note_names[note % 12];
        const oct: i8 = @as(i8, @intCast(note / 12)) - 1;

        injectMidi(&.{ 0x90, note, 100 });
        std.debug.print("  [TEST-MIDI] [{d}/5] ON  {s}{d} (note={d})\n", .{ i + 1, name, oct, note });
        std.Thread.sleep(400 * std.time.ns_per_ms);

        injectMidi(&.{ 0x80, note, 0 });
        std.debug.print("  [TEST-MIDI] [{d}/5] OFF {s}{d}\n", .{ i + 1, name, oct });
        std.Thread.sleep(600 * std.time.ns_per_ms);
    }

    // Wait for envelopes to finish
    std.debug.print("  [TEST-MIDI] Waiting 2s for envelope release...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    var voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 1 result: {d} active voices (expected: 0)\n\n", .{voices});

    // Phase 2: Chord (3 notes simultaneously)
    std.debug.print("  [TEST-MIDI] Phase 2: Chord C4+E4+G4\n", .{});
    injectMidi(&.{ 0x90, 60, 100 });
    injectMidi(&.{ 0x90, 64, 100 });
    injectMidi(&.{ 0x90, 67, 100 });
    std.debug.print("  [TEST-MIDI] ON  C4+E4+G4\n", .{});
    std.Thread.sleep(1 * std.time.ns_per_s);

    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Voices during chord: {d} (expected: 3)\n", .{voices});

    injectMidi(&.{ 0x80, 60, 0 });
    injectMidi(&.{ 0x80, 64, 0 });
    injectMidi(&.{ 0x80, 67, 0 });
    std.debug.print("  [TEST-MIDI] OFF C4+E4+G4\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 2 result: {d} active voices (expected: 0)\n\n", .{voices});

    // Phase 3: Rapid fire stress test (20 notes, 50ms each)
    std.debug.print("  [TEST-MIDI] Phase 3: Rapid fire (20 notes, 50ms each)\n", .{});
    for (0..20) |i| {
        const note: u8 = @intCast(48 + i); // C3 → G#4
        injectMidi(&.{ 0x90, note, 100 });
        std.Thread.sleep(50 * std.time.ns_per_ms);
        injectMidi(&.{ 0x80, note, 0 });
    }
    std.debug.print("  [TEST-MIDI] Rapid fire done. Waiting 3s for envelopes...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);

    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 3 result: {d} active voices (expected: 0)\n\n", .{voices});

    // Phase 4: Polyphony stress — 8 simultaneous voices held for 2s
    std.debug.print("  [TEST-MIDI] Phase 4: Polyphony stress (8 voices, 2s hold)\n", .{});
    const poly_notes = [_]u8{ 48, 52, 55, 59, 60, 64, 67, 71 }; // Cmaj7 + Cmaj7 octave up
    for (poly_notes) |note| {
        injectMidi(&.{ 0x90, note, 100 });
    }
    std.Thread.sleep(500 * std.time.ns_per_ms);
    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Voices during poly hold: {d} (expected: 8)\n", .{voices});
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    for (poly_notes) |note| {
        injectMidi(&.{ 0x80, note, 0 });
    }
    std.debug.print("  [TEST-MIDI] OFF all 8 notes. Waiting 3s for release...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);
    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 4 result: {d} active voices (expected: 0)\n\n", .{voices});

    // Phase 5: Velocity dynamics — same note at different velocities
    std.debug.print("  [TEST-MIDI] Phase 5: Velocity dynamics (C4 @ vel 20,60,100,127)\n", .{});
    const velocities = [_]u8{ 20, 60, 100, 127 };
    for (velocities, 0..) |vel, i| {
        injectMidi(&.{ 0x90, 60, vel });
        std.debug.print("  [TEST-MIDI] [{d}/4] C4 vel={d}\n", .{ i + 1, vel });
        std.Thread.sleep(500 * std.time.ns_per_ms);
        injectMidi(&.{ 0x80, 60, 0 });
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
    std.debug.print("  [TEST-MIDI] Waiting 2s for release...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 5 result: {d} active voices (expected: 0)\n\n", .{voices});

    // Phase 6: 64-voice sustained load test (60s)
    std.debug.print("  [TEST-MIDI] Phase 6: 64-voice sustained load (60s hold)\n", .{});
    // Activate all 64 voices across full MIDI range (C1..Eb6, 64 unique notes)
    for (0..64) |i| {
        const note: u8 = @intCast(24 + i); // 24..87 — no duplicates
        injectMidi(&.{ 0x90, note, 100 });
    }
    std.Thread.sleep(500 * std.time.ns_per_ms);
    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Voices active: {d} (expected: 64)\n", .{voices});

    // Capture 64-voice WAV for analysis (re-arm capture after settling)
    std.Thread.sleep(2 * std.time.ns_per_s); // let voices stabilize
    wave_cap_pos = 0;
    wave_cap_done.store(false, .release);
    wave_cap_armed.store(true, .release);
    var cap6_wait: u32 = 0;
    while (!wave_cap_done.load(.acquire) and cap6_wait < 300) : (cap6_wait += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    if (wave_cap_done.load(.acquire)) {
        std.debug.print("  [WAV-CAP] 64-voice capture: {d} samples\n", .{WAVE_CAP_SIZE});
        // Inline analysis
        var pk64: f32 = 0;
        var rms64: f64 = 0;
        var jumps64: u32 = 0;
        var zeros64: u32 = 0;
        for (0..WAVE_CAP_SIZE) |si| {
            const al = @abs(wave_cap_l[si]);
            if (al > pk64) pk64 = al;
            rms64 += @as(f64, wave_cap_l[si]) * @as(f64, wave_cap_l[si]);
            if (si > 0 and @abs(wave_cap_l[si] - wave_cap_l[si - 1]) > 0.3) jumps64 += 1;
            if (wave_cap_l[si] == 0.0 and wave_cap_r[si] == 0.0) zeros64 += 1;
        }
        const rms64f: f32 = @floatCast(@sqrt(rms64 / @as(f64, WAVE_CAP_SIZE)));
        const crest64: f32 = if (rms64f > 0.0001) pk64 / rms64f else 0.0;
        std.debug.print("  [WAV-CAP] 64v: pk={d:.4} rms={d:.4} crest={d:.1} jumps={d} zeros={d}\n", .{
            pk64, rms64f, crest64, jumps64, zeros64,
        });
        writeWav("/tmp/worldsynth-capture-64v.wav", &wave_cap_l, &wave_cap_r, WAVE_CAP_SIZE, WAVE_CAP_RATE);
    }

    // Hold for 60 seconds, report status every 10s
    for (0..6) |tick| {
        std.Thread.sleep(10 * std.time.ns_per_s);
        const t_clips = mon_clip_count.load(.acquire);
        const t_xruns = mon_xrun_count.load(.acquire);
        const t_stutters = mon_stutter_count.load(.acquire);
        const t_dropouts = mon_dropout_count.load(.acquire);
        const t_peak_raw = mon_true_peak.load(.acquire);
        const t_peak: f32 = @as(f32, @floatFromInt(t_peak_raw)) / 10000.0;
        const t_voices = mon_voices.load(.acquire);
        std.debug.print("  [TEST-MIDI] @{d}s: v={d} pk={d:.1}dBFS c={d} x={d} st={d} d={d}\n", .{
            (tick + 1) * 10,
            t_voices,
            if (t_peak > 0.0001) 20.0 * @log10(t_peak) else -120.0,
            t_clips,
            t_xruns,
            t_stutters,
            t_dropouts,
        });
    }

    // Release all 64 voices
    for (0..64) |i| {
        const note: u8 = @intCast(24 + i);
        injectMidi(&.{ 0x80, note, 0 });
    }
    std.debug.print("  [TEST-MIDI] OFF all 64 notes. Waiting 3s for release...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);
    voices = mon_voices.load(.acquire);
    std.debug.print("  [TEST-MIDI] Phase 6 result: {d} active voices (expected: 0)\n\n", .{voices});

    // ════════════════════════════════════════════════════════════════
    // COMPREHENSIVE AUDIO HEALTH REPORT
    // ════════════════════════════════════════════════════════════════
    const final_clips = mon_clip_count.load(.acquire);
    const final_silent = mon_silent_blocks.load(.acquire);
    const final_xruns = mon_xrun_count.load(.acquire);
    const final_dropouts = mon_dropout_count.load(.acquire);
    const final_stutters = mon_stutter_count.load(.acquire);
    const final_stutter_max = mon_stutter_max_samples.load(.acquire);
    const final_noise_raw = mon_noise_floor.load(.acquire);
    const final_noise: f32 = @as(f32, @floatFromInt(final_noise_raw)) / 1000000.0;
    const final_true_pk = @as(f32, @floatFromInt(mon_true_peak.load(.acquire))) / 10000.0;
    const final_true_pk_db: f32 = if (final_true_pk > 0.00001) 20.0 * @log10(final_true_pk) else -120.0;
    const total_cb = mon_cb_count.load(.acquire);
    const total_ns = mon_cb_sum_ns.load(.acquire);
    const max_cb_us = mon_cb_max_ns.load(.acquire) / 1000;
    const avg_cb_us: u64 = if (total_cb > 0) total_ns / total_cb / 1000 else 0;

    std.debug.print("\n  ═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  ██ AUDIO HEALTH REPORT ██\n", .{});
    std.debug.print("  ═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  ── Timing ──\n", .{});
    std.debug.print("  Callbacks total     : {d}\n", .{total_cb});
    std.debug.print("  Avg proc time       : {d} us\n", .{avg_cb_us});
    std.debug.print("  Max proc time       : {d} us (worst case)\n", .{max_cb_us});
    std.debug.print("  XRuns (over budget)  : {d}{s}\n", .{ final_xruns, if (final_xruns > 0) @as([]const u8, " *** FAIL ***") else @as([]const u8, " OK") });
    std.debug.print("  ── Signal ──\n", .{});
    std.debug.print("  True peak            : {d:.4} ({d:.1} dBFS)\n", .{ final_true_pk, final_true_pk_db });
    std.debug.print("  Clipped samples      : {d}{s}\n", .{ final_clips, if (final_clips > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    // RMS + Crest from monitor thread
    const rms_linear: f32 = @as(f32, @floatFromInt(mon_rms_val.load(.acquire))) / 10000.0;
    const rms_db: f32 = if (rms_linear > 0.00001) 20.0 * @log10(rms_linear) else -120.0;
    std.debug.print("  RMS level            : {d:.4} ({d:.1} dBFS)\n", .{ rms_linear, rms_db });
    const crest: f32 = if (rms_linear > 0.0001) final_true_pk / rms_linear else 0.0;
    const crest_db: f32 = if (crest > 0.01) 20.0 * @log10(crest) else 0.0;
    std.debug.print("  Crest factor         : {d:.1} ({d:.1} dB){s}\n", .{
        crest,                                                                                                   crest_db,
        if (crest > 0.01 and crest < 1.5) @as([]const u8, " *** WARN: compressed ***") else @as([]const u8, ""),
    });
    // DC offset
    const dc_off_raw = mon_dc_offset.load(.acquire);
    const dc_offset_val: f32 = @as(f32, @floatFromInt(dc_off_raw)) / 1000000.0;
    std.debug.print("  DC offset            : {d:.6}{s}\n", .{
        dc_offset_val,
        if (@abs(dc_offset_val) > 0.01) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK"),
    });
    std.debug.print("  ── Glitch Detection ──\n", .{});
    std.debug.print("  Dropouts (glitch)    : {d}{s}\n", .{ final_dropouts, if (final_dropouts > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    std.debug.print("  Stutters (>1ms gap)  : {d}{s}\n", .{ final_stutters, if (final_stutters > 0) @as([]const u8, " *** FAIL ***") else @as([]const u8, " OK") });
    if (final_stutter_max > 0) {
        const stutter_ms: f32 = @as(f32, @floatFromInt(final_stutter_max)) / 48.0;
        std.debug.print("  Longest stutter      : {d} samples ({d:.1}ms)\n", .{ final_stutter_max, stutter_ms });
    }
    std.debug.print("  Silent+active samples: {d}{s}\n", .{ final_silent, if (final_silent > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    const disc_count = mon_discontinuities.load(.acquire);
    std.debug.print("  Discontinuities      : {d}\n", .{disc_count});
    std.debug.print("  ── Noise Floor ──\n", .{});
    const noise_db: f32 = if (final_noise > 0.0000001) 20.0 * @log10(final_noise) else -999.0;
    std.debug.print("  Noise when silent    : {d:.7}{s}\n", .{
        final_noise,
        if (final_noise > 0.0001) @as([]const u8, " *** FAIL: audible noise leak ***") else if (final_noise > 0.0) @as([]const u8, " (inaudible)") else @as([]const u8, " CLEAN"),
    });
    if (final_noise > 0.0) {
        std.debug.print("  Noise floor (dBFS)   : {d:.1}\n", .{noise_db});
    }
    std.debug.print("  Hanging voices       : {d}{s}\n", .{ voices, if (voices > 0) @as([]const u8, " *** FAIL ***") else @as([]const u8, " OK") });
    std.debug.print("  ───────────────────────────────────────────────────────────\n", .{});

    // Overall verdict
    const has_failures = (voices > 0 or final_xruns > 0 or final_stutters > 0 or final_noise > 0.0001);
    const has_warnings = (final_clips > 0 or final_silent > 0 or final_dropouts > 0 or (crest > 0.01 and crest < 1.5));
    if (!has_failures and !has_warnings) {
        std.debug.print("  VERDICT: PASS — Audio engine healthy, no issues detected.\n", .{});
    } else if (!has_failures and has_warnings) {
        std.debug.print("  VERDICT: PASS (with warnings) — No critical issues.\n", .{});
    } else {
        std.debug.print("  VERDICT: FAIL — Critical audio issues detected!\n", .{});
    }
    // RT Environment context (helps correlate XRuns with RT status)
    if (comptime build_options.enable_alsa) {
        if (global_backend) |b| {
            switch (b.*) {
                .alsa => |*a| {
                    const diag = &a.rt_diag;
                    std.debug.print("  ── RT Environment ──\n", .{});
                    std.debug.print("  Scheduler        : {s}\n", .{diag.scheduler.label()});
                    if (diag.cpu_pinned) |core| {
                        std.debug.print("  CPU Pinned       : Core {d}\n", .{core});
                    } else {
                        std.debug.print("  CPU Pinned       : not pinned\n", .{});
                    }
                    std.debug.print("  Memory Locked    : {s}\n", .{if (diag.memory_locked) "yes" else "no"});
                    std.debug.print("  Buffer Adaptations: {d}\n", .{a.current_period_idx});
                    std.debug.print("  ───────────────────────────────────────────────────────────\n", .{});
                },
                else => {},
            }
        }
    }
    // ── Latency ──
    std.debug.print("  ── Latency ──\n", .{});
    {
        const nf_lat = mon_n_frames.load(.acquire);
        const sr_lat: u32 = if (global_engine) |e| @intFromFloat(e.sample_rate) else 48000;
        const lat_ms: f64 = @as(f64, @floatFromInt(nf_lat)) / @as(f64, @floatFromInt(sr_lat)) * 1000.0;
        std.debug.print("  Output latency       : {d:.1}ms ({d} frames @ {d}Hz)\n", .{ lat_ms, nf_lat, sr_lat });
        const ml_v = mon_midi_latency_ns.load(.acquire);
        const ml_max_v = mon_midi_latency_max_ns.load(.acquire);
        const ml_cnt = mon_midi_latency_count.load(.acquire);
        if (ml_cnt > 0) {
            std.debug.print("  MIDI→dispatch (last) : {d}us\n", .{ml_v / 1000});
            std.debug.print("  MIDI→dispatch (max)  : {d}us\n", .{ml_max_v / 1000});
            std.debug.print("  MIDI measurements    : {d}\n", .{ml_cnt});
            const total_ms: f64 = @as(f64, @floatFromInt(ml_v)) / 1_000_000.0 + lat_ms;
            std.debug.print("  Total MIDI→speaker   : {d:.1}ms{s}\n", .{
                total_ms,
                if (total_ms > 20.0) @as([]const u8, " *** HIGH ***") else @as([]const u8, " OK"),
            });
        } else {
            std.debug.print("  MIDI latency         : N/A (software MIDI used)\n", .{});
        }
    }
    std.debug.print("  ═══════════════════════════════════════════════════════════\n", .{});

    std.debug.print("  [TEST-MIDI] Shutting down in 2s...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    running.store(false, .release);
    if (global_backend) |b| b.quit();
}

// ── Single note test: one C4 for 5 seconds ────────────────────────────
// Plays a single note to isolate audio quality issues (noise, artifacts).
fn testSingleThread() void {
    std.debug.print("\n  ═══════════════════════════════════════════════════\n", .{});
    std.debug.print("  [TEST-SINGLE] Single note test — C4 (261Hz) for 5s\n", .{});
    std.debug.print("  ═══════════════════════════════════════════════════\n", .{});

    // Wait for audio to stabilize
    std.debug.print("  [TEST-SINGLE] Waiting 1s for audio to stabilize...\n", .{});
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Arm WAV capture
    wave_cap_pos = 0;
    wave_cap_done.store(false, .release);
    wave_cap_armed.store(true, .release);

    // Note On: C4, velocity 100
    injectMidi(&.{ 0x90, 60, 100 });
    std.debug.print("  [TEST-SINGLE] ON  C4 (note=60, vel=100)\n", .{});

    // Hold for 5 seconds, report every second
    for (1..6) |sec| {
        std.Thread.sleep(1 * std.time.ns_per_s);
        const voices = mon_voices.load(.acquire);
        const cb_us = mon_cb_last_ns.load(.acquire) / 1000;
        const pk_raw = mon_true_peak.load(.acquire);
        const pk: f32 = @as(f32, @floatFromInt(pk_raw)) / 10000.0;
        const pk_db: f32 = if (pk > 0.00001) 20.0 * @log10(pk) else -120.0;
        const xruns = mon_xrun_count.load(.acquire);
        const stutters = mon_stutter_count.load(.acquire);
        std.debug.print("  [TEST-SINGLE] @{d}s: v={d} proc={d}us pk={d:.1}dB x={d} st={d}\n", .{
            sec, voices, cb_us, pk_db, xruns, stutters,
        });
    }

    // Note Off
    injectMidi(&.{ 0x80, 60, 0 });
    std.debug.print("  [TEST-SINGLE] OFF C4\n", .{});

    // Wait for release envelope
    std.debug.print("  [TEST-SINGLE] Waiting 3s for release envelope...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);

    // Check WAV capture
    if (wave_cap_done.load(.acquire)) {
        std.debug.print("  [WAV-CAP] Captured {d} samples\n", .{WAVE_CAP_SIZE});
        // Quick analysis
        var pk_wav: f32 = 0;
        var rms_sum_wav: f64 = 0;
        var zeros_wav: u32 = 0;
        var jumps_wav: u32 = 0;
        for (0..WAVE_CAP_SIZE) |si| {
            const al = @abs(wave_cap_l[si]);
            if (al > pk_wav) pk_wav = al;
            rms_sum_wav += @as(f64, wave_cap_l[si]) * @as(f64, wave_cap_l[si]);
            if (wave_cap_l[si] == 0.0 and wave_cap_r[si] == 0.0) zeros_wav += 1;
            if (si > 0 and @abs(wave_cap_l[si] - wave_cap_l[si - 1]) > 0.1) jumps_wav += 1;
        }
        const rms_wav: f32 = @floatCast(@sqrt(rms_sum_wav / @as(f64, WAVE_CAP_SIZE)));
        const crest_wav: f32 = if (rms_wav > 0.0001) pk_wav / rms_wav else 0.0;
        std.debug.print("  [WAV-CAP] pk={d:.4} rms={d:.4} crest={d:.1} jumps={d} zeros={d}\n", .{
            pk_wav, rms_wav, crest_wav, jumps_wav, zeros_wav,
        });
        // First 16 samples
        std.debug.print("  [WAV-CAP] First 16 samples:\n", .{});
        for (0..16) |si| {
            std.debug.print("    [{d:3}] L={d:10.6}  R={d:10.6}\n", .{ si, wave_cap_l[si], wave_cap_r[si] });
        }
        writeWav("/tmp/worldsynth-single.wav", &wave_cap_l, &wave_cap_r, WAVE_CAP_SIZE, WAVE_CAP_RATE);
    }

    // Mini health report
    const voices = mon_voices.load(.acquire);
    const final_clips = mon_clip_count.load(.acquire);
    const final_xruns = mon_xrun_count.load(.acquire);
    const final_stutters = mon_stutter_count.load(.acquire);
    const final_noise_raw = mon_noise_floor.load(.acquire);
    const final_noise: f32 = @as(f32, @floatFromInt(final_noise_raw)) / 1000000.0;
    const final_true_pk = @as(f32, @floatFromInt(mon_true_peak.load(.acquire))) / 10000.0;
    const final_true_pk_db: f32 = if (final_true_pk > 0.00001) 20.0 * @log10(final_true_pk) else -120.0;
    const max_cb_us = mon_cb_max_ns.load(.acquire) / 1000;

    std.debug.print("\n  ═══════════════════════════════════════════════════\n", .{});
    std.debug.print("  ██ SINGLE NOTE HEALTH REPORT ██\n", .{});
    std.debug.print("  ═══════════════════════════════════════════════════\n", .{});
    std.debug.print("  Max proc time   : {d} us\n", .{max_cb_us});
    std.debug.print("  XRuns            : {d}{s}\n", .{ final_xruns, if (final_xruns > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    std.debug.print("  True peak        : {d:.4} ({d:.1} dBFS)\n", .{ final_true_pk, final_true_pk_db });
    std.debug.print("  Clipped samples  : {d}{s}\n", .{ final_clips, if (final_clips > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    std.debug.print("  Stutters         : {d}{s}\n", .{ final_stutters, if (final_stutters > 0) @as([]const u8, " *** WARN ***") else @as([]const u8, " OK") });
    std.debug.print("  Noise floor      : {d:.7}{s}\n", .{
        final_noise,
        if (final_noise > 0.0001) @as([]const u8, " *** FAIL ***") else if (final_noise > 0.0) @as([]const u8, " (inaudible)") else @as([]const u8, " CLEAN"),
    });
    std.debug.print("  Hanging voices   : {d}{s}\n", .{ voices, if (voices > 0) @as([]const u8, " *** FAIL ***") else @as([]const u8, " OK") });
    std.debug.print("  ═══════════════════════════════════════════════════\n", .{});

    std.debug.print("  [TEST-SINGLE] Shutting down in 2s...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);
    running.store(false, .release);
    if (global_backend) |b| b.quit();
}

pub fn main() void {
    std.debug.print("WorldSynth starting...\n", .{});

    // Parse command-line arguments
    var test_midi_mode = false;
    var test_single_mode = false;
    var sine_mode = false;
    var device_override: ?u8 = null;
    var midi_override: ?u8 = null;
    {
        var args = std.process.args();
        _ = args.next(); // skip program name
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--test-midi")) {
                test_midi_mode = true;
            } else if (std.mem.eql(u8, arg, "--test-single")) {
                test_single_mode = true;
            } else if (std.mem.eql(u8, arg, "--test-sine")) {
                sine_mode = true;
            } else if (std.mem.eql(u8, arg, "--device")) {
                if (args.next()) |dev_arg| {
                    device_override = std.fmt.parseInt(u8, dev_arg, 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "--midi")) {
                if (args.next()) |midi_arg| {
                    midi_override = std.fmt.parseInt(u8, midi_arg, 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "--capture")) {
                capture_enabled = true;
            }
        }
    }

    // Apply device/midi overrides before backend init
    if (device_override) |dev| {
        if (comptime build_options.enable_alsa) {
            io.alsa.AlsaClient.setPreferredCard(dev);
            std.debug.print("ALSA: device override → hw:{d}\n", .{dev});
        }
    }
    if (midi_override) |mid| {
        if (comptime build_options.enable_alsa) {
            io.alsa.AlsaClient.setPreferredMidiCard(mid);
            std.debug.print("ALSA: MIDI override → hw:{d}\n", .{mid});
        }
    }

    // Signal handlers for graceful shutdown (SIGINT, SIGTERM)
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sighandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    // Audio backend detection (PipeWire first, JACK fallback)
    var backend = io.audio_backend.AudioBackend.detect_and_init(audioCallback, midiCallback) catch |err| {
        std.debug.print("Audio backend init failed: {}\n", .{err});
        return;
    };

    const sample_rate = backend.get_sample_rate();

    switch (backend) {
        .pipewire => std.debug.print("Backend: PipeWire @ {d}Hz\n", .{sample_rate}),
        .jack => std.debug.print("Backend: JACK @ {d}Hz\n", .{sample_rate}),
        .alsa => std.debug.print("Backend: ALSA hw: mmap @ {d}Hz\n", .{sample_rate}),
    }

    // Engine creation (heap alloc here only, never in audio thread)
    const eng = Engine.create(std.heap.page_allocator, @floatFromInt(sample_rate)) catch |err| {
        std.debug.print("Engine init failed: {}\n", .{err});
        backend.stop();
        return;
    };

    // Set saw waveform as default (audible, harmonically rich)
    eng.param_state.set_param(.osc1_waveform, 1.0);
    // Open filter fully so saw harmonics are not attenuated (default=1000Hz is too dull)
    eng.param_state.set_param(.filter_cutoff, 20000.0);

    // Publish engine + backend to RT callbacks / signal handler BEFORE start
    global_engine = eng;
    global_backend = &backend;

    if (sine_mode) {
        test_sine_mode.store(true, .release);
        std.debug.print("Mode: --test-sine (pure 440Hz sine, engine BYPASSED — tests ALSA output path)\n", .{});
    }
    if (test_midi_mode) {
        std.debug.print("Mode: --test-midi (software MIDI, no keyboard/USB)\n", .{});
    } else if (test_single_mode) {
        std.debug.print("Mode: --test-single (single C4 note for 5s)\n", .{});
    }
    if (capture_enabled) {
        std.debug.print("Mode: --capture (live WAV recording to /tmp/worldsynth-live.wav)\n", .{});
    }
    std.debug.print("WorldSynth active. Press Ctrl+C to quit.\n", .{});

    // Spawn monitor thread (works for both JACK and PipeWire)
    const mon_thread = std.Thread.spawn(.{}, monitorThread, .{sample_rate}) catch |err| {
        std.debug.print("Monitor thread failed: {}\n", .{err});
        return;
    };

    // Spawn test thread if requested (before start — PipeWire blocks in start())
    var test_thread: ?std.Thread = null;
    if (test_midi_mode) {
        test_thread = std.Thread.spawn(.{}, testMidiThread, .{}) catch null;
    } else if (test_single_mode) {
        test_thread = std.Thread.spawn(.{}, testSingleThread, .{}) catch null;
    }

    // PipeWire: start() blocks in pw_main_loop_run until quit() is called.
    // JACK: start() returns immediately — spin-wait on running flag.
    backend.start() catch |err| {
        std.debug.print("Audio backend start failed: {}\n", .{err});
        running.store(false, .release);
        mon_thread.join();
        global_backend = null;
        global_engine = null;
        eng.destroy(std.heap.page_allocator);
        backend.stop();
        return;
    };

    // JACK/ALSA: wait for shutdown signal (PipeWire already exited via quit())
    switch (backend) {
        .jack, .alsa => {
            // Brief pause to let audio thread complete RT setup, then print diagnostics
            std.Thread.sleep(200 * std.time.ns_per_ms);
            if (build_options.enable_alsa) {
                switch (backend) {
                    .alsa => |*a| io.rt.printDiagnostics(&a.rt_diag),
                    else => {},
                }
            }
            while (running.load(.acquire)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        },
        .pipewire => {},
    }

    std.debug.print("\nShutting down...\n", .{});

    // Signal threads to stop and join
    running.store(false, .release);
    mon_thread.join();
    if (test_thread) |t| t.join();

    // Cleanup: stop backend first, then release engine
    global_backend = null;
    backend.stop();
    global_engine = null;
    eng.destroy(std.heap.page_allocator);
}

test {
    _ = engine.tables;
    _ = engine.tables_adaa;
    _ = engine.tables_blep;
    _ = engine.tables_approx;
    _ = engine.tables_simd;
    _ = engine.param;
    _ = engine.param_smooth;
    _ = engine.undo;
    _ = engine.microtuning;
    _ = engine.bench;
    _ = engine.engine_core;
    _ = io.jack;
    _ = io.pipewire;
    _ = io.alsa;
    _ = io.audio_backend;
    _ = dsp.voice;
    _ = dsp.drift;
    _ = dsp.oscillator;
    _ = dsp.osc_sine_noise;
    _ = dsp.filter;
    _ = dsp.ladder;
    _ = dsp.envelope;
    _ = dsp.voice_manager;
    _ = io.osc;
    _ = io.midi_learn;
    _ = io.midi;
    _ = platform.ring_buffer;
}
