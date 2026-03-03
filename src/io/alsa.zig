const std = @import("std");
const jack_mod = @import("jack.zig");
const rt = @import("rt.zig");

// ── Raw ALSA hw: mmap Audio + MIDI Backend ────────────────────────────
// Hand-written libasound bindings for zero-copy DMA audio output.
// No @cImport — Zig extern declarations directly on the ALSA C API.
// Audio thread uses SCHED_FIFO RT priority + mlockall + mmap for minimum latency.
// Rawmidi for sub-ms MIDI input (no snd_seq overhead).

// ── Shared callback types (same across all backends) ──────────────────

pub const ProcessFn = jack_mod.ProcessFn;
pub const MidiEventFn = jack_mod.MidiEventFn;

// ── ALSA Constants ────────────────────────────────────────────────────

pub const SND_PCM_STREAM_PLAYBACK: c_int = 0;
pub const SND_PCM_ACCESS_MMAP_INTERLEAVED: c_int = 0;
pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
pub const SND_PCM_FORMAT_S24_3LE: c_int = 32; // 24-bit packed (3 bytes/sample) — Steinberg UR22 etc.
pub const SND_PCM_FORMAT_S32_LE: c_int = 10;
pub const SND_PCM_FORMAT_FLOAT_LE: c_int = 14;

const SCHED_FIFO: c_int = 1;
const MCL_CURRENT: c_int = 1;
const MCL_FUTURE: c_int = 2;

/// Maximum period size for preallocated conversion buffers.
/// 2048 frames covers all common period sizes (64..2048).
pub const MAX_PERIOD: usize = 2048;

// ── Opaque Types ──────────────────────────────────────────────────────

pub const snd_pcm_t = opaque {};
pub const snd_pcm_hw_params_t = opaque {};
pub const snd_pcm_sw_params_t = opaque {};
pub const snd_rawmidi_t = opaque {};

// ── ALSA C Types ──────────────────────────────────────────────────────

pub const snd_pcm_uframes_t = c_ulong;
pub const snd_pcm_sframes_t = c_long;

/// ALSA channel area descriptor — maps one channel in the mmap buffer.
/// Layout: addr(8) + first(4) + step(4) = 16 bytes on x86_64.
pub const snd_pcm_channel_area_t = extern struct {
    addr: ?*anyopaque,
    first: c_uint, // offset to first sample in bits
    step: c_uint, // inter-sample distance in bits
};

const sched_param_t = extern struct {
    sched_priority: c_int,
};

// ── PCM Extern Declarations (hand-written, NO @cImport) ──────────────

extern "asound" fn snd_pcm_open(pcm: *?*snd_pcm_t, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
extern "asound" fn snd_pcm_close(pcm: *snd_pcm_t) c_int;
extern "asound" fn snd_pcm_prepare(pcm: *snd_pcm_t) c_int;
extern "asound" fn snd_pcm_start(pcm: *snd_pcm_t) c_int;
extern "asound" fn snd_pcm_drop(pcm: *snd_pcm_t) c_int;
extern "asound" fn snd_pcm_wait(pcm: *snd_pcm_t, timeout: c_int) c_int;
extern "asound" fn snd_pcm_recover(pcm: *snd_pcm_t, err: c_int, silent: c_int) c_int;
extern "asound" fn snd_pcm_avail_update(pcm: *snd_pcm_t) snd_pcm_sframes_t;

extern "asound" fn snd_pcm_mmap_begin(
    pcm: *snd_pcm_t,
    areas: *?[*]const snd_pcm_channel_area_t,
    offset: *snd_pcm_uframes_t,
    frames: *snd_pcm_uframes_t,
) c_int;
extern "asound" fn snd_pcm_mmap_commit(
    pcm: *snd_pcm_t,
    offset: snd_pcm_uframes_t,
    frames: snd_pcm_uframes_t,
) snd_pcm_sframes_t;

// RW (non-mmap) write
extern "asound" fn snd_pcm_writei(pcm: *snd_pcm_t, buffer: [*]const u8, size: snd_pcm_uframes_t) snd_pcm_sframes_t;

// HW params
extern "asound" fn snd_pcm_hw_params_malloc(ptr: *?*snd_pcm_hw_params_t) c_int;
extern "asound" fn snd_pcm_hw_params_free(obj: *snd_pcm_hw_params_t) void;
extern "asound" fn snd_pcm_hw_params_any(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
extern "asound" fn snd_pcm_hw_params_set_access(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, access: c_int) c_int;
extern "asound" fn snd_pcm_hw_params_set_format(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, format: c_int) c_int;
extern "asound" fn snd_pcm_hw_params_set_channels(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: c_uint) c_int;
extern "asound" fn snd_pcm_hw_params_set_rate_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *c_uint, dir: ?*c_int) c_int;
extern "asound" fn snd_pcm_hw_params_set_period_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: ?*c_int) c_int;
extern "asound" fn snd_pcm_hw_params_set_buffer_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) c_int;
extern "asound" fn snd_pcm_hw_params(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
extern "asound" fn snd_pcm_hw_params_get_period_size(params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: ?*c_int) c_int;
extern "asound" fn snd_pcm_hw_params_get_buffer_size(params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) c_int;

// SW params
extern "asound" fn snd_pcm_sw_params_malloc(ptr: *?*snd_pcm_sw_params_t) c_int;
extern "asound" fn snd_pcm_sw_params_free(obj: *snd_pcm_sw_params_t) void;
extern "asound" fn snd_pcm_sw_params_current(pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t) c_int;
extern "asound" fn snd_pcm_sw_params_set_start_threshold(pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t, val: snd_pcm_uframes_t) c_int;
extern "asound" fn snd_pcm_sw_params_set_avail_min(pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t, val: snd_pcm_uframes_t) c_int;
extern "asound" fn snd_pcm_sw_params(pcm: *snd_pcm_t, params: *snd_pcm_sw_params_t) c_int;

// Rawmidi
extern "asound" fn snd_rawmidi_open(in_rmidi: ?*?*snd_rawmidi_t, out_rmidi: ?*?*snd_rawmidi_t, name: [*:0]const u8, mode: c_int) c_int;
extern "asound" fn snd_rawmidi_close(rmidi: *snd_rawmidi_t) c_int;
extern "asound" fn snd_rawmidi_read(rmidi: *snd_rawmidi_t, buffer: [*]u8, size: usize) c_long;
extern "asound" fn snd_rawmidi_nonblock(rmidi: *snd_rawmidi_t, nonblock: c_int) c_int;

// Error string (for debugging)
extern "asound" fn snd_strerror(errnum: c_int) [*:0]const u8;

// POSIX RT scheduling (in libc)
extern "c" fn sched_setscheduler(pid: c_int, policy: c_int, param: *const sched_param_t) c_int;
extern "c" fn mlockall(flags: c_int) c_int;

// ── AlsaClient ────────────────────────────────────────────────────────

/// Sample format detected during card configuration.
pub const SampleFormat = enum { float_le, s32_le, s24_3le };

pub const AlsaClient = struct {
    pcm: *snd_pcm_t,
    process_fn: ?ProcessFn,
    midi_fn: ?MidiEventFn,
    sample_rate: u32,
    period_size: u32,
    buffer_size: u32,
    channels: u32,
    format: SampleFormat,
    running: std.atomic.Value(bool),
    audio_thread: ?std.Thread,
    conv_buf_l: [MAX_PERIOD]f32,
    conv_buf_r: [MAX_PERIOD]f32,
    write_buf: [MAX_PERIOD * 8]u8 align(4), // interleaved output buffer (aligned for f32/i32 casts)
    rawmidi: ?*snd_rawmidi_t,
    midi_thread: ?std.Thread,

    // RT diagnostics (written by audio thread, read by main thread for reporting)
    rt_diag: rt.RtDiagnostics = .{},

    // Adaptive buffer-sizing state (audio thread only, no atomics needed)
    xrun_count: u32 = 0,
    adapt_cooldown: u32 = 0,
    stable_count: u32 = 0,
    current_period_idx: u8 = 0, // index into ADAPT_PERIODS

    /// Adaptive period sizes: step up on XRuns, step down when stable.
    const ADAPT_PERIODS = [_]u32{ 256, 512, 1024 };
    const XRUN_THRESHOLD: u32 = 3; // XRuns before scaling up
    const ADAPT_COOLDOWN_VAL: u32 = 1000; // ~5s of callbacks to wait after adapt
    const STABLE_THRESHOLD: u32 = 20000; // ~100s stable before scaling down

    /// Maximum cards to scan for probe/init.
    const MAX_CARDS: u8 = 8;

    /// Build "hw:N" device name string for card index.
    fn cardName(idx: u8) [8]u8 {
        var buf: [8]u8 = .{ 'h', 'w', ':', '0', 0, 0, 0, 0 };
        if (idx < 10) {
            buf[3] = '0' + idx;
            buf[4] = 0;
        } else {
            buf[3] = '0' + (idx / 10);
            buf[4] = '0' + (idx % 10);
            buf[5] = 0;
        }
        return buf;
    }

    /// Build "hw:N,0" rawmidi device name string for card index.
    fn midiName(idx: u8) [10]u8 {
        var buf: [10]u8 = .{ 'h', 'w', ':', '0', ',', '0', 0, 0, 0, 0 };
        if (idx < 10) {
            buf[3] = '0' + idx;
            buf[4] = ',';
            buf[5] = '0';
            buf[6] = 0;
        } else {
            buf[3] = '0' + (idx / 10);
            buf[4] = '0' + (idx % 10);
            buf[5] = ',';
            buf[6] = '0';
            buf[7] = 0;
        }
        return buf;
    }

    /// Probe for any ALSA hw:N playback device (scans cards 7→0).
    /// Reverse scan prefers USB audio interfaces (higher card numbers).
    /// Non-blocking open + immediate close — no resources held.
    pub fn probe() bool {
        var i: u8 = MAX_CARDS;
        while (i > 0) {
            i -= 1;
            const name = cardName(i);
            var pcm_ptr: ?*snd_pcm_t = null;
            if (snd_pcm_open(&pcm_ptr, @ptrCast(&name), SND_PCM_STREAM_PLAYBACK, 1) == 0) {
                if (pcm_ptr) |p| _ = snd_pcm_close(p);
                return true;
            }
        }
        return false;
    }

    /// Try to fully configure one ALSA hw:N card with mmap + stereo + 48kHz.
    /// Returns null if this card doesn't support our requirements.
    const CardConfig = struct {
        pcm: *snd_pcm_t,
        rate: u32,
        period_size: u32,
        buffer_size: u32,
        format: SampleFormat,
    };

    fn tryConfigureCard(idx: u8) ?CardConfig {
        const name = cardName(idx);
        var pcm_ptr: ?*snd_pcm_t = null;
        if (snd_pcm_open(&pcm_ptr, @ptrCast(&name), SND_PCM_STREAM_PLAYBACK, 0) < 0)
            return null;
        const pcm = pcm_ptr orelse return null;

        // HW params
        var hw: ?*snd_pcm_hw_params_t = null;
        if (snd_pcm_hw_params_malloc(&hw) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        const hw_p = hw orelse {
            _ = snd_pcm_close(pcm);
            return null;
        };
        defer snd_pcm_hw_params_free(hw_p);

        if (snd_pcm_hw_params_any(pcm, hw_p) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        if (snd_pcm_hw_params_set_access(pcm, hw_p, SND_PCM_ACCESS_RW_INTERLEAVED) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }

        // Format: try FLOAT_LE → S32_LE → S24_3LE (UR22 etc.)
        var format: SampleFormat = .float_le;
        if (snd_pcm_hw_params_set_format(pcm, hw_p, SND_PCM_FORMAT_FLOAT_LE) < 0) {
            if (snd_pcm_hw_params_set_format(pcm, hw_p, SND_PCM_FORMAT_S32_LE) < 0) {
                if (snd_pcm_hw_params_set_format(pcm, hw_p, SND_PCM_FORMAT_S24_3LE) < 0) {
                    _ = snd_pcm_close(pcm);
                    return null;
                }
                format = .s24_3le;
            } else {
                format = .s32_le;
            }
        }
        if (snd_pcm_hw_params_set_channels(pcm, hw_p, 2) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        var rate: c_uint = 48000;
        if (snd_pcm_hw_params_set_rate_near(pcm, hw_p, &rate, null) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        var period: snd_pcm_uframes_t = 256;
        if (snd_pcm_hw_params_set_period_size_near(pcm, hw_p, &period, null) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        var buf_size: snd_pcm_uframes_t = period * 4;
        if (snd_pcm_hw_params_set_buffer_size_near(pcm, hw_p, &buf_size) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        if (snd_pcm_hw_params(pcm, hw_p) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }

        // Read back actual values
        var actual_period: snd_pcm_uframes_t = 0;
        var actual_buf: snd_pcm_uframes_t = 0;
        _ = snd_pcm_hw_params_get_period_size(hw_p, &actual_period, null);
        _ = snd_pcm_hw_params_get_buffer_size(hw_p, &actual_buf);

        if (actual_period > MAX_PERIOD) {
            _ = snd_pcm_close(pcm);
            return null;
        }

        // SW params
        var sw: ?*snd_pcm_sw_params_t = null;
        if (snd_pcm_sw_params_malloc(&sw) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        const sw_p = sw orelse {
            _ = snd_pcm_close(pcm);
            return null;
        };
        defer snd_pcm_sw_params_free(sw_p);

        if (snd_pcm_sw_params_current(pcm, sw_p) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        if (snd_pcm_sw_params_set_start_threshold(pcm, sw_p, actual_period) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        if (snd_pcm_sw_params_set_avail_min(pcm, sw_p, actual_period) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }
        if (snd_pcm_sw_params(pcm, sw_p) < 0) {
            _ = snd_pcm_close(pcm);
            return null;
        }

        return .{
            .pcm = pcm,
            .rate = @intCast(rate),
            .period_size = @intCast(actual_period),
            .buffer_size = @intCast(actual_buf),
            .format = format,
        };
    }

    /// Preferred audio output card index.
    /// Set via setPreferredCard() before init(), or falls back to reverse scan.
    /// TODO(WP-UI): Replace with runtime device selector in GUI.
    var preferred_pcm_card: u8 = 3;

    /// Override the preferred PCM card index (call before init).
    pub fn setPreferredCard(card: u8) void {
        preferred_pcm_card = card;
    }

    /// Preferred MIDI input card index.
    /// Set via setPreferredMidiCard() before init(), or falls back to forward scan.
    var preferred_midi_card: u8 = 0xFF; // 0xFF = auto-scan

    /// Override the preferred MIDI card index (call before init).
    pub fn setPreferredMidiCard(card: u8) void {
        preferred_midi_card = card;
    }

    /// Open ALSA hw:N with mmap interleaved access.
    /// Tries preferred card first, then reverse-scans 7→0 as fallback.
    /// Format fallback: FLOAT_LE → S32_LE → S24_3LE.
    pub fn init(process_fn: ?ProcessFn, midi_fn: ?MidiEventFn) !AlsaClient {
        // Try preferred card first (UR22), then fall back to reverse scan
        var cfg: ?CardConfig = null;
        var card_idx: u8 = preferred_pcm_card;
        cfg = tryConfigureCard(preferred_pcm_card);
        if (cfg == null) {
            // Fallback: reverse scan (7→0) — prefers USB audio (higher card numbers)
            card_idx = MAX_CARDS;
            while (card_idx > 0) {
                card_idx -= 1;
                if (tryConfigureCard(card_idx)) |c| {
                    cfg = c;
                    break;
                }
            }
        }
        const config = cfg orelse return error.AlsaOpenFailed;

        // ── Rawmidi (try preferred card first, then scan all) ──
        var rawmidi: ?*snd_rawmidi_t = null;
        var midi_card: u8 = 0xFF;
        if (preferred_midi_card != 0xFF) {
            const mname = midiName(preferred_midi_card);
            if (snd_rawmidi_open(&rawmidi, null, @ptrCast(&mname), 0) == 0) {
                midi_card = preferred_midi_card;
            }
        }
        if (rawmidi == null) {
            for (0..MAX_CARDS) |mi| {
                const mname = midiName(@intCast(mi));
                if (snd_rawmidi_open(&rawmidi, null, @ptrCast(&mname), 0) == 0) {
                    midi_card = @intCast(mi);
                    break;
                }
            }
        }
        if (rawmidi) |rm| _ = snd_rawmidi_nonblock(rm, 1);

        const fmt_name: []const u8 = switch (config.format) {
            .float_le => "FLOAT_LE",
            .s32_le => "S32_LE",
            .s24_3le => "S24_3LE",
        };
        std.debug.print("ALSA: opened hw:{d} ({s}, period={d}, buf={d}, rate={d}Hz)\n", .{
            card_idx, fmt_name, config.period_size, config.buffer_size, config.rate,
        });
        if (midi_card != 0xFF) {
            std.debug.print("ALSA: rawmidi hw:{d},0 opened for MIDI input\n", .{midi_card});
        } else {
            std.debug.print("ALSA: no rawmidi device found — MIDI input disabled\n", .{});
        }

        return AlsaClient{
            .pcm = config.pcm,
            .process_fn = process_fn,
            .midi_fn = midi_fn,
            .sample_rate = config.rate,
            .period_size = config.period_size,
            .buffer_size = config.buffer_size,
            .channels = 2,
            .format = config.format,
            .running = std.atomic.Value(bool).init(false),
            .audio_thread = null,
            .conv_buf_l = [_]f32{0.0} ** MAX_PERIOD,
            .conv_buf_r = [_]f32{0.0} ** MAX_PERIOD,
            .write_buf = [_]u8{0} ** (MAX_PERIOD * 8),
            .rawmidi = rawmidi,
            .midi_thread = null,
        };
    }

    /// Spawn RT audio thread + optional MIDI thread. Returns immediately
    /// (like JACK — caller must spin-wait on a running flag).
    pub fn start(self: *AlsaClient) !void {
        self.running.store(true, .release);
        self.audio_thread = std.Thread.spawn(.{}, audioThreadFn, .{self}) catch
            return error.AlsaThreadFailed;
        if (self.rawmidi != null and self.midi_fn != null) {
            self.midi_thread = std.Thread.spawn(.{}, midiThreadFn, .{self}) catch null;
        }
    }

    /// Stop audio processing and release all resources.
    pub fn deinit(self: *AlsaClient) void {
        self.running.store(false, .release);
        if (self.audio_thread) |t| t.join();
        if (self.midi_thread) |t| t.join();
        _ = snd_pcm_drop(self.pcm);
        _ = snd_pcm_close(self.pcm);
        if (self.rawmidi) |rm| _ = snd_rawmidi_close(rm);
    }

    // ── RT Audio Thread (writei — simpler + more robust than mmap for USB) ──

    fn audioThreadFn(self: *AlsaClient) void {
        // ── RT-Hardening (WP-028) ──
        // setupAudioThread: mlockall → SCHED_FIFO/RR fallback → CPU pinning → stack pre-fault
        self.rt_diag = rt.setupAudioThread(.{
            .preferred_core = null, // auto-detect best core
        });

        // Pre-fault audio buffers (struct fields — touch every page)
        rt.prefaultBuffer(&self.conv_buf_l);
        rt.prefaultBuffer(&self.conv_buf_r);

        if (snd_pcm_prepare(self.pcm) < 0) return;

        const bytes_per_frame: u32 = switch (self.format) {
            .float_le, .s32_le => 8, // 4 bytes × 2 channels
            .s24_3le => 6, // 3 bytes × 2 channels
        };

        std.debug.print("ALSA: audio thread started (writei, {d}B/frame, period={d}, sched={s})\n", .{
            bytes_per_frame, self.period_size, self.rt_diag.scheduler.label(),
        });

        // Find initial adaptive period index
        self.current_period_idx = 0;
        for (ADAPT_PERIODS, 0..) |p, i| {
            if (self.period_size == p) {
                self.current_period_idx = @intCast(i);
                break;
            }
        }

        while (self.running.load(.acquire)) {
            // Block until one period of space is available (1s timeout)
            const wait_ret = snd_pcm_wait(self.pcm, 1000);
            if (wait_ret == 0) continue; // timeout, check running flag
            if (wait_ret < 0) {
                if (snd_pcm_recover(self.pcm, wait_ret, 1) < 0) break;
                self.handleXrun();
                continue;
            }

            const avail_raw = snd_pcm_avail_update(self.pcm);
            if (avail_raw < 0) {
                if (snd_pcm_recover(self.pcm, @intCast(avail_raw), 1) < 0) break;
                self.handleXrun();
                continue;
            }

            // Process one period at a time until buffer is adequately filled
            var avail: snd_pcm_uframes_t = @intCast(avail_raw);
            while (avail >= self.period_size and self.running.load(.monotonic)) {
                const chunk: u32 = self.period_size;

                // Generate audio into planar conv buffers
                if (self.process_fn) |process| {
                    process(&self.conv_buf_l, &self.conv_buf_r, chunk);
                } else {
                    @memset(self.conv_buf_l[0..chunk], 0.0);
                    @memset(self.conv_buf_r[0..chunk], 0.0);
                }

                // Interleave planar → write_buf
                self.interleaveToWriteBuf(chunk);

                // Write interleaved samples to ALSA (handles ring buffer wrap internally)
                const ret = snd_pcm_writei(self.pcm, &self.write_buf, chunk);
                if (ret < 0) {
                    _ = snd_pcm_recover(self.pcm, @intCast(ret), 1);
                    self.handleXrun();
                    break; // re-enter outer loop (wait + avail_update)
                }
                avail -|= @intCast(ret);
            }

            // Adaptive buffer cooldown + stability tracking
            if (self.adapt_cooldown > 0) self.adapt_cooldown -= 1;
            self.stable_count +|= 1;
        }
    }

    /// Handle XRun: count and potentially adapt period size upward.
    fn handleXrun(self: *AlsaClient) void {
        self.xrun_count += 1;
        self.stable_count = 0;

        // Check if we should scale up the period
        if (self.xrun_count >= XRUN_THRESHOLD and self.adapt_cooldown == 0) {
            if (self.current_period_idx + 1 < ADAPT_PERIODS.len) {
                const old_period = self.period_size;
                self.current_period_idx += 1;
                const new_period = ADAPT_PERIODS[self.current_period_idx];

                if (self.reconfigurePcm(new_period)) {
                    std.debug.print("ALSA: adapted period {d} -> {d} due to {d} XRuns\n", .{
                        old_period, new_period, self.xrun_count,
                    });
                } else {
                    // Reconfig failed — revert index
                    self.current_period_idx -= 1;
                }
            }
            self.xrun_count = 0;
            self.adapt_cooldown = ADAPT_COOLDOWN_VAL;
        }
    }

    /// Reconfigure PCM with a new period size. Returns true on success.
    /// Requires: PCM must be in a recoverable state (after snd_pcm_recover).
    fn reconfigurePcm(self: *AlsaClient, new_period: u32) bool {
        // Drop current playback state
        _ = snd_pcm_drop(self.pcm);

        // Reconfigure HW params with new period
        var hw_p: ?*snd_pcm_hw_params_t = null;
        if (snd_pcm_hw_params_malloc(&hw_p) < 0) return false;
        defer snd_pcm_hw_params_free(hw_p.?);

        if (snd_pcm_hw_params_any(self.pcm, hw_p.?) < 0) return false;

        const access: c_int = SND_PCM_ACCESS_RW_INTERLEAVED;
        if (snd_pcm_hw_params_set_access(self.pcm, hw_p.?, access) < 0) return false;

        const fmt: c_int = switch (self.format) {
            .float_le => SND_PCM_FORMAT_FLOAT_LE,
            .s32_le => SND_PCM_FORMAT_S32_LE,
            .s24_3le => SND_PCM_FORMAT_S24_3LE,
        };
        if (snd_pcm_hw_params_set_format(self.pcm, hw_p.?, fmt) < 0) return false;
        if (snd_pcm_hw_params_set_channels(self.pcm, hw_p.?, 2) < 0) return false;

        var rate: c_uint = @intCast(self.sample_rate);
        if (snd_pcm_hw_params_set_rate_near(self.pcm, hw_p.?, &rate, null) < 0) return false;

        var period: snd_pcm_uframes_t = new_period;
        if (snd_pcm_hw_params_set_period_size_near(self.pcm, hw_p.?, &period, null) < 0) return false;

        var buf_size: snd_pcm_uframes_t = new_period * 4;
        if (snd_pcm_hw_params_set_buffer_size_near(self.pcm, hw_p.?, &buf_size) < 0) return false;

        if (snd_pcm_hw_params(self.pcm, hw_p.?) < 0) return false;

        // Update internal state
        self.period_size = @intCast(period);
        self.buffer_size = @intCast(buf_size);

        // Prepare for playback
        if (snd_pcm_prepare(self.pcm) < 0) return false;

        return true;
    }

    /// Interleave planar conv_buf_l/conv_buf_r into write_buf for snd_pcm_writei.
    fn interleaveToWriteBuf(self: *AlsaClient, frames: u32) void {
        switch (self.format) {
            .float_le => {
                const buf: [*]f32 = @ptrCast(@alignCast(&self.write_buf));
                for (0..frames) |i| {
                    buf[i * 2] = self.conv_buf_l[i];
                    buf[i * 2 + 1] = self.conv_buf_r[i];
                }
            },
            .s32_le => {
                const buf: [*]i32 = @ptrCast(@alignCast(&self.write_buf));
                for (0..frames) |i| {
                    buf[i * 2] = f32ToS32(self.conv_buf_l[i]);
                    buf[i * 2 + 1] = f32ToS32(self.conv_buf_r[i]);
                }
            },
            .s24_3le => {
                // S24_3LE: 3 bytes per sample, 6 bytes per stereo frame
                for (0..frames) |i| {
                    const raw_l: u24 = f32ToS24(self.conv_buf_l[i]);
                    const raw_r: u24 = f32ToS24(self.conv_buf_r[i]);
                    const wl: u32 = raw_l;
                    const wr: u32 = raw_r;
                    const off = i * 6;
                    // L channel (bytes 0,1,2)
                    self.write_buf[off + 0] = @truncate(wl);
                    self.write_buf[off + 1] = @truncate(wl >> 8);
                    self.write_buf[off + 2] = @truncate(wl >> 16);
                    // R channel (bytes 3,4,5)
                    self.write_buf[off + 3] = @truncate(wr);
                    self.write_buf[off + 4] = @truncate(wr >> 8);
                    self.write_buf[off + 5] = @truncate(wr >> 16);
                }
            },
        }
    }

    // ── MIDI Thread (rawmidi non-blocking read) ───────────────────────

    fn midiThreadFn(self: *AlsaClient) void {
        const rm = self.rawmidi orelse return;
        const midi_handler = self.midi_fn orelse return;

        std.debug.print("ALSA: MIDI thread started (reading rawmidi)\n", .{});

        var buf: [256]u8 = undefined;
        var msg_buf: [3]u8 = .{ 0, 0, 0 };
        var msg_pos: usize = 0;
        var expected: usize = 0;

        while (self.running.load(.acquire)) {
            const n = snd_rawmidi_read(rm, &buf, buf.len);
            if (n <= 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            const count: usize = @intCast(n);
            for (buf[0..count]) |byte| {
                if (byte >= 0xF0) continue; // skip system messages

                if (byte & 0x80 != 0) {
                    // Status byte — start new message
                    msg_buf[0] = byte;
                    msg_pos = 1;
                    expected = midiMsgLen(byte);
                } else if (msg_pos > 0 and msg_pos < expected) {
                    msg_buf[msg_pos] = byte;
                    msg_pos += 1;

                    if (msg_pos == expected) {
                        // Complete message — dispatch
                        if (jack_mod.MidiEvent.parse(0, msg_buf[0..expected])) |event| {
                            midi_handler(event);
                        }
                        msg_pos = 1; // keep status for running status
                    }
                }
            }
        }
    }
};

// ── Format Conversion Helpers ─────────────────────────────────────────

/// Convert f32 [-1.0, +1.0] to S32_LE [-2^31, +2^31-1].
/// Clamped at boundaries to prevent overflow. Used in RT audio thread.
pub inline fn f32ToS32(x: f32) i32 {
    if (x >= 1.0) return std.math.maxInt(i32);
    if (x <= -1.0) return std.math.minInt(i32);
    return @intFromFloat(x * 2147483648.0);
}

/// Convert S32_LE to f32. Inverse of f32ToS32 (within f32 precision).
pub inline fn s32ToF32(x: i32) f32 {
    return @as(f32, @floatFromInt(x)) / 2147483648.0;
}

/// Convert f32 [-1.0, +1.0] to S24_3LE [0, 0xFFFFFF] (unsigned 24-bit packed).
/// Returns u24 as u32 for byte extraction. Clamped at boundaries.
pub inline fn f32ToS24(x: f32) u24 {
    const scaled: i32 = if (x >= 1.0)
        std.math.maxInt(i24)
    else if (x <= -1.0)
        std.math.minInt(i24)
    else
        @intFromFloat(x * 8388608.0); // 2^23
    return @bitCast(@as(i24, @intCast(std.math.clamp(scaled, std.math.minInt(i24), std.math.maxInt(i24)))));
}

/// Expected byte count for a MIDI channel message given its status byte.
pub fn midiMsgLen(status: u8) usize {
    return switch (status & 0xF0) {
        0x80, 0x90, 0xA0, 0xB0, 0xE0 => 3, // Note Off/On, Poly AT, CC, Pitch Bend
        0xC0, 0xD0 => 2, // Program Change, Channel AT
        else => 0,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "snd_pcm_channel_area_t layout matches C ABI" {
    // C: void* addr (8) + unsigned int first (4) + unsigned int step (4) = 16
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(snd_pcm_channel_area_t));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(snd_pcm_channel_area_t, "addr"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(snd_pcm_channel_area_t, "first"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(snd_pcm_channel_area_t, "step"));
}

test "snd_pcm_uframes_t is c_ulong" {
    try std.testing.expectEqual(@sizeOf(c_ulong), @sizeOf(snd_pcm_uframes_t));
}

test "ALSA format constants match libasound" {
    try std.testing.expectEqual(@as(c_int, 14), SND_PCM_FORMAT_FLOAT_LE);
    try std.testing.expectEqual(@as(c_int, 10), SND_PCM_FORMAT_S32_LE);
    try std.testing.expectEqual(@as(c_int, 0), SND_PCM_ACCESS_MMAP_INTERLEAVED);
    try std.testing.expectEqual(@as(c_int, 0), SND_PCM_STREAM_PLAYBACK);
}

test "f32ToS32 boundary values" {
    try std.testing.expectEqual(std.math.maxInt(i32), f32ToS32(1.0));
    try std.testing.expectEqual(std.math.minInt(i32), f32ToS32(-1.0));
    try std.testing.expectEqual(@as(i32, 0), f32ToS32(0.0));
    // Clipping beyond [-1, +1]
    try std.testing.expectEqual(std.math.maxInt(i32), f32ToS32(2.0));
    try std.testing.expectEqual(std.math.minInt(i32), f32ToS32(-2.0));
}

test "f32ToS32 mid-range accuracy" {
    const half = f32ToS32(0.5);
    // 0.5 * 2^31 = 1073741824
    try std.testing.expectEqual(@as(i32, 1073741824), half);
    const neg_half = f32ToS32(-0.5);
    try std.testing.expectEqual(@as(i32, -1073741824), neg_half);
}

test "s32ToF32 inverse" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s32ToF32(0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), s32ToF32(std.math.minInt(i32)), 0.0001);
    try std.testing.expect(s32ToF32(std.math.maxInt(i32)) > 0.999);
}

test "f32 → S32 → f32 roundtrip" {
    const values = [_]f32{ 0.0, 0.5, -0.5, 0.25, -0.75, 0.001, -0.001 };
    for (values) |v| {
        const roundtrip = s32ToF32(f32ToS32(v));
        try std.testing.expectApproxEqAbs(v, roundtrip, 0.001);
    }
}

test "midiMsgLen for standard messages" {
    try std.testing.expectEqual(@as(usize, 3), midiMsgLen(0x90)); // Note On
    try std.testing.expectEqual(@as(usize, 3), midiMsgLen(0x80)); // Note Off
    try std.testing.expectEqual(@as(usize, 3), midiMsgLen(0xB0)); // CC
    try std.testing.expectEqual(@as(usize, 2), midiMsgLen(0xC0)); // Program Change
    try std.testing.expectEqual(@as(usize, 2), midiMsgLen(0xD0)); // Channel AT
    try std.testing.expectEqual(@as(usize, 3), midiMsgLen(0xE0)); // Pitch Bend
}

test "midiMsgLen channel independence" {
    try std.testing.expectEqual(@as(usize, 3), midiMsgLen(0x9F)); // Note On ch15
    try std.testing.expectEqual(@as(usize, 2), midiMsgLen(0xC7)); // Program Change ch7
}

test "ProcessFn type matches backend ProcessFn" {
    try std.testing.expect(ProcessFn == jack_mod.ProcessFn);
}

/// Convert S24_3LE bytes back to f32 for roundtrip testing.
fn s24BytesToF32(b0: u8, b1: u8, b2: u8) f32 {
    // Reconstruct 24-bit value from LE bytes
    const raw: u32 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16);
    // Sign-extend from 24-bit to 32-bit
    const signed: i32 = if (raw & 0x800000 != 0)
        @as(i32, @bitCast(raw | 0xFF000000)) // negative: set upper bits
    else
        @intCast(raw);
    return @as(f32, @floatFromInt(signed)) / 8388608.0;
}

test "f32 → S24_3LE → f32 roundtrip accuracy" {
    // Test with a 440Hz sine wave — the same signal we use in --test-sine
    const SAMPLES = 256;
    var input: [SAMPLES]f32 = undefined;
    var output: [SAMPLES]f32 = undefined;

    // Generate sine wave
    for (0..SAMPLES) |i| {
        const phase: f32 = @as(f32, @floatFromInt(i)) / 48000.0 * 440.0;
        input[i] = @sin(phase * 2.0 * std.math.pi) * 0.5; // -0.5..+0.5
    }

    // Convert through full S24_3LE pipeline
    var write_buf: [SAMPLES * 6]u8 = undefined;
    for (0..SAMPLES) |i| {
        const raw: u24 = f32ToS24(input[i]);
        const w: u32 = raw;
        const off = i * 6;
        // Stereo: same value in both channels for this test
        write_buf[off + 0] = @truncate(w);
        write_buf[off + 1] = @truncate(w >> 8);
        write_buf[off + 2] = @truncate(w >> 16);
        write_buf[off + 3] = @truncate(w);
        write_buf[off + 4] = @truncate(w >> 8);
        write_buf[off + 5] = @truncate(w >> 16);
    }

    // Convert back from S24_3LE bytes to f32
    for (0..SAMPLES) |i| {
        const off = i * 6;
        output[i] = s24BytesToF32(write_buf[off + 0], write_buf[off + 1], write_buf[off + 2]);
    }

    // Compute error statistics
    var max_err: f32 = 0;
    var sum_sq_err: f64 = 0;
    var sum_sq_sig: f64 = 0;
    for (0..SAMPLES) |i| {
        const err = @abs(input[i] - output[i]);
        if (err > max_err) max_err = err;
        sum_sq_err += @as(f64, err) * @as(f64, err);
        sum_sq_sig += @as(f64, input[i]) * @as(f64, input[i]);
    }
    const rms_err = @sqrt(sum_sq_err / SAMPLES);
    const rms_sig = @sqrt(sum_sq_sig / SAMPLES);
    const snr_db: f64 = if (rms_err > 0) 20.0 * @log10(rms_sig / rms_err) else 200.0;

    std.debug.print("\n  [ALSA] S24_3LE roundtrip accuracy ({d} samples, 440Hz sine):\n", .{SAMPLES});
    std.debug.print("    max error:  {d:.9}\n", .{max_err});
    std.debug.print("    RMS error:  {e}\n", .{rms_err});
    std.debug.print("    SNR:        {d:.1} dB\n", .{snr_db});
    std.debug.print("    24-bit theoretical SNR: 144 dB\n\n", .{});

    // 24-bit quantization noise should give ~144 dB SNR
    // Allow some margin for floating-point rounding: > 130 dB
    try std.testing.expect(snr_db > 130.0);
    // Max error should be < 1 LSB (1/2^23 = ~0.000000119)
    try std.testing.expect(max_err < 0.0002); // generous bound
}

test "f32ToS24 boundary values" {
    // Zero
    try std.testing.expectEqual(@as(u24, 0), f32ToS24(0.0));
    // Positive max
    const pos = f32ToS24(1.0);
    try std.testing.expectEqual(@as(u24, @bitCast(@as(i24, std.math.maxInt(i24)))), pos);
    // Negative max (clamp)
    const neg = f32ToS24(-1.0);
    try std.testing.expectEqual(@as(u24, @bitCast(@as(i24, std.math.minInt(i24)))), neg);
    // Beyond range
    const over = f32ToS24(2.0);
    try std.testing.expectEqual(@as(u24, @bitCast(@as(i24, std.math.maxInt(i24)))), over);
}

test "S24_3LE interleave produces correct byte pattern" {
    // Known values: 0.5 and -0.5
    const half_raw: u24 = f32ToS24(0.5);
    const neg_half_raw: u24 = f32ToS24(-0.5);

    // 0.5 * 2^23 = 4194304 = 0x400000
    try std.testing.expectEqual(@as(u32, 0x400000), @as(u32, half_raw));

    // -0.5 * 2^23 = -4194304. As u24: 2^24 - 4194304 = 12582912 = 0xC00000
    try std.testing.expectEqual(@as(u32, 0xC00000), @as(u32, neg_half_raw));

    // Verify byte packing (LE)
    const wl: u32 = half_raw;
    try std.testing.expectEqual(@as(u8, 0x00), @as(u8, @truncate(wl)));
    try std.testing.expectEqual(@as(u8, 0x00), @as(u8, @truncate(wl >> 8)));
    try std.testing.expectEqual(@as(u8, 0x40), @as(u8, @truncate(wl >> 16)));
}

test "bench: f32ToS32 throughput (128 samples)" {
    const RUNS = 5;
    const SAMPLES = 128;

    var input: [SAMPLES]f32 = undefined;
    for (0..SAMPLES) |i| {
        input[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLES)) * 2.0 - 1.0;
    }

    var times: [RUNS]u64 = undefined;
    for (&times) |*t| {
        var output: [SAMPLES]i32 = undefined;
        const start_time = std.time.nanoTimestamp();
        for (0..SAMPLES) |i| {
            output[i] = f32ToS32(input[i]);
        }
        const end_time = std.time.nanoTimestamp();
        std.mem.doNotOptimizeAway(&output);
        t.* = @intCast(end_time - start_time);
    }

    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[RUNS / 2];

    std.debug.print(
        "\n  [ALSA] f32→S32 conversion — {d} samples, {d} Runs\n" ++
            "    median: {d}ns total | {d}ns/sample\n" ++
            "    Schwelle: < 1000ns total (ReleaseFast)\n\n",
        .{ SAMPLES, RUNS, median, median / SAMPLES },
    );

    if (@import("builtin").mode == .ReleaseFast) {
        if (median > 1000) {
            std.debug.print("  FAIL: {d}ns > 1000ns\n", .{median});
            return error.BenchmarkFailed;
        }
    }
}
