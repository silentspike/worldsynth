const std = @import("std");
const builtin = @import("builtin");

// ── RT-Hardening Module (WP-028) ────────────────────────────────────
// Platform-abstracted real-time audio thread hardening.
// 5 measures: Thread Priority, CPU Affinity, Memory Locking,
// Stack Pre-Faulting, Startup Diagnostics.
// Used by alsa.zig (and later jack.zig, Windows WASAPI).
// All functions are best-effort with graceful fallback — no panic.
// When libc is not linked (no audio backend), all functions return
// safe fallback values (no RT capability).

// ── POSIX Types (needed for struct layout regardless of libc) ───────

const has_libc = builtin.link_libc;

const sched_param_t = extern struct {
    sched_priority: c_int,
};

const SCHED_FIFO: c_int = 1;
const SCHED_RR: c_int = 2;
const MCL_CURRENT: c_int = 1;
const MCL_FUTURE: c_int = 2;
const PRIO_PROCESS: c_int = 0;

/// Linux cpu_set_t — 1024 bits = 128 bytes = 16 × u64.
const cpu_set_t = extern struct {
    bits: [16]u64,
};

// ── POSIX Extern Declarations (only resolved when libc is linked) ───

const posix = if (has_libc) struct {
    extern "c" fn sched_setscheduler(pid: c_int, policy: c_int, param: *const sched_param_t) c_int;
    extern "c" fn sched_setaffinity(pid: c_int, cpusetsize: usize, mask: *const cpu_set_t) c_int;
    extern "c" fn mlockall(flags: c_int) c_int;
    extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
} else struct {};

// ── Public Types ────────────────────────────────────────────────────

/// Achieved scheduler level after fallback chain.
pub const SchedulerLevel = enum {
    fifo_high, // SCHED_FIFO priority 80 (optimal)
    fifo_low, // SCHED_FIFO priority 50
    rr, // SCHED_RR priority 50
    nice, // setpriority nice -20
    none, // no RT capability

    pub fn label(self: SchedulerLevel) []const u8 {
        return switch (self) {
            .fifo_high => "SCHED_FIFO (priority 80)",
            .fifo_low => "SCHED_FIFO (priority 50)",
            .rr => "SCHED_RR (priority 50)",
            .nice => "nice -20",
            .none => "none (default scheduler)",
        };
    }

    pub fn isRt(self: SchedulerLevel) bool {
        return self == .fifo_high or self == .fifo_low or self == .rr;
    }
};

/// Full RT diagnostics — collected during setupAudioThread().
pub const RtDiagnostics = struct {
    pub const MAX_WARNINGS: usize = 8;
    pub const MAX_WARNING_LEN: usize = 128;

    scheduler: SchedulerLevel = .none,
    cpu_pinned: ?u32 = null, // Core ID or null
    memory_locked: bool = false,
    stack_prefaulted: bool = false,

    // Environment info (read from sysfs/procfs)
    kernel_preempt: [32]u8 = .{0} ** 32,
    kernel_preempt_len: u8 = 0,
    cpu_governor: [32]u8 = .{0} ** 32,
    cpu_governor_len: u8 = 0,
    rtprio_limit: u32 = 0,

    // Warnings
    warnings: [MAX_WARNINGS][MAX_WARNING_LEN]u8 = .{.{0} ** MAX_WARNING_LEN} ** MAX_WARNINGS,
    warning_count: u8 = 0,

    fn addWarning(self: *RtDiagnostics, msg: []const u8) void {
        if (self.warning_count >= MAX_WARNINGS) return;
        const len = @min(msg.len, MAX_WARNING_LEN);
        @memcpy(self.warnings[self.warning_count][0..len], msg[0..len]);
        self.warning_count += 1;
    }

    pub fn getKernelPreempt(self: *const RtDiagnostics) []const u8 {
        return self.kernel_preempt[0..self.kernel_preempt_len];
    }

    pub fn getCpuGovernor(self: *const RtDiagnostics) []const u8 {
        return self.cpu_governor[0..self.cpu_governor_len];
    }

    pub fn getWarning(self: *const RtDiagnostics, idx: usize) []const u8 {
        if (idx >= self.warning_count) return "";
        // Find actual length (until first zero)
        const w = &self.warnings[idx];
        var len: usize = 0;
        while (len < MAX_WARNING_LEN and w[len] != 0) : (len += 1) {}
        return w[0..len];
    }
};

/// Options for setupAudioThread().
pub const SetupOptions = struct {
    preferred_core: ?u32 = null, // null = auto-detect
};

// ── Core Functions ──────────────────────────────────────────────────

/// Set RT scheduling priority with 4-level fallback chain.
/// Tries SCHED_FIFO(80) → SCHED_FIFO(50) → SCHED_RR(50) → nice(-20).
/// Returns the achieved level.
pub fn setThreadPriority() SchedulerLevel {
    if (comptime !has_libc) return .none;
    // 1. SCHED_FIFO priority 80 (optimal)
    {
        const param = sched_param_t{ .sched_priority = 80 };
        if (posix.sched_setscheduler(0, SCHED_FIFO, &param) == 0) return .fifo_high;
    }
    // 2. SCHED_FIFO priority 50 (lower, often permitted)
    {
        const param = sched_param_t{ .sched_priority = 50 };
        if (posix.sched_setscheduler(0, SCHED_FIFO, &param) == 0) return .fifo_low;
    }
    // 3. SCHED_RR priority 50 (round-robin, broader compatibility)
    {
        const param = sched_param_t{ .sched_priority = 50 };
        if (posix.sched_setscheduler(0, SCHED_RR, &param) == 0) return .rr;
    }
    // 4. nice -20 (minimal, no CAP_SYS_NICE needed on some distros)
    if (posix.setpriority(PRIO_PROCESS, 0, -20) == 0) return .nice;
    // 5. Nothing worked
    return .none;
}

/// Pin current thread to a specific CPU core.
/// If core_id is null, auto-detects best core (avoids core 0, prefers high IDs).
/// Returns the pinned core ID, or null on failure.
pub fn pinToCore(core_id: ?u32) ?u32 {
    if (comptime !has_libc) return null;
    const target_core = core_id orelse autoDetectCore();
    if (target_core) |core| {
        var mask = std.mem.zeroes(cpu_set_t);
        const word_idx = core / 64;
        const bit_idx: u6 = @intCast(core % 64);
        mask.bits[word_idx] |= @as(u64, 1) << bit_idx;
        if (posix.sched_setaffinity(0, @sizeOf(cpu_set_t), &mask) == 0) {
            return core;
        }
    }
    return null;
}

/// Lock all current and future memory pages (prevents page faults in RT thread).
/// Returns true on success.
pub fn lockMemory() bool {
    if (comptime !has_libc) return false;
    return posix.mlockall(MCL_CURRENT | MCL_FUTURE) == 0;
}

/// Pre-fault 64KB of stack pages by writing volatile zeros every 4KB.
/// Must be called BEFORE the audio loop to ensure stack pages are resident.
/// Fixed at 64KB — covers all audio thread stack needs (actual usage ~4-8KB).
pub fn prefaultStack() void {
    const size = 64 * 1024; // 64KB = 16 pages
    var buf: [size]u8 = undefined;
    var i: usize = 0;
    while (i < size) : (i += 4096) {
        const ptr: *volatile u8 = @ptrCast(&buf[i]);
        ptr.* = 0;
    }
    // Touch last byte too
    const ptr: *volatile u8 = @ptrCast(&buf[size - 1]);
    ptr.* = 0;
}

/// Pre-fault a contiguous f32 buffer by reading each page.
pub fn prefaultBuffer(buf: []f32) void {
    if (buf.len == 0) return;
    const byte_ptr: [*]volatile u8 = @ptrCast(buf.ptr);
    const byte_len = buf.len * @sizeOf(f32);
    var i: usize = 0;
    while (i < byte_len) : (i += 4096) {
        _ = byte_ptr[i];
    }
    // Touch last byte
    _ = byte_ptr[byte_len - 1];
}

// ── Convenience: Setup Everything ───────────────────────────────────

/// Setup audio thread with all RT hardening measures.
/// Call this at the START of the audio thread, BEFORE any audio processing.
/// Returns diagnostics with achieved levels and warnings.
pub fn setupAudioThread(opts: SetupOptions) RtDiagnostics {
    var diag = RtDiagnostics{};

    // 1. Lock memory (before anything else — prevents future page faults)
    diag.memory_locked = lockMemory();
    if (!diag.memory_locked) {
        diag.addWarning("mlockall failed — page faults possible in RT thread");
    }

    // 2. Set thread priority (fallback chain)
    diag.scheduler = setThreadPriority();
    if (!diag.scheduler.isRt()) {
        diag.addWarning("RT priority not available — set rtprio in /etc/security/limits.conf");
    }

    // 3. Pin to CPU core
    diag.cpu_pinned = pinToCore(opts.preferred_core);
    if (diag.cpu_pinned == null) {
        diag.addWarning("CPU affinity failed — thread may migrate between cores");
    }

    // 4. Pre-fault stack (64KB fixed)
    prefaultStack();
    diag.stack_prefaulted = true;

    // 5. Read environment diagnostics (best-effort, non-critical)
    readKernelPreempt(&diag);
    readCpuGovernor(&diag);
    readRtprioLimit(&diag);

    return diag;
}

// ── Environment Diagnostics (sysfs/procfs reads) ────────────────────

/// Read kernel preemption mode from sysfs.
fn readKernelPreempt(diag: *RtDiagnostics) void {
    // Try /sys/kernel/debug/sched/preempt first (modern kernels)
    if (readSysFile("/sys/kernel/debug/sched/preempt")) |content| {
        copyToBuf(&diag.kernel_preempt, &diag.kernel_preempt_len, content);
        if (!std.mem.startsWith(u8, content, "full")) {
            diag.addWarning("Kernel preemption not 'full' — XRuns more likely under load");
        }
        return;
    }
    // Fallback: parse /proc/cmdline for preempt= parameter
    if (readSysFile("/proc/cmdline")) |cmdline| {
        if (std.mem.indexOf(u8, cmdline, "preempt=")) |idx| {
            const after = cmdline[idx + 8 ..];
            const end = std.mem.indexOfAny(u8, after, " \t\n") orelse after.len;
            copyToBuf(&diag.kernel_preempt, &diag.kernel_preempt_len, after[0..end]);
            return;
        }
    }
    copyToBuf(&diag.kernel_preempt, &diag.kernel_preempt_len, "unknown");
}

/// Read CPU frequency governor.
fn readCpuGovernor(diag: *RtDiagnostics) void {
    if (readSysFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")) |gov| {
        copyToBuf(&diag.cpu_governor, &diag.cpu_governor_len, gov);
        if (std.mem.startsWith(u8, gov, "powersave")) {
            diag.addWarning("CPU governor is 'powersave' — consider 'performance' or 'schedutil'");
        }
    } else {
        copyToBuf(&diag.cpu_governor, &diag.cpu_governor_len, "unknown");
    }
}

/// Read max realtime priority from /proc/self/limits.
fn readRtprioLimit(diag: *RtDiagnostics) void {
    if (readSysFile("/proc/self/limits")) |content| {
        // Find "Max realtime priority" line
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (std.mem.indexOf(u8, line, "Max realtime priority")) |_| {
                // Parse the soft limit (first number after fixed columns)
                // Format: "Max realtime priority     80                   80"
                // Skip the label, find first digit sequence
                var i: usize = 0;
                // Skip past "Max realtime priority"
                while (i < line.len and !(line[i] >= '0' and line[i] <= '9') and line[i] != 'u') : (i += 1) {}
                if (i < line.len and line[i] >= '0' and line[i] <= '9') {
                    var val: u32 = 0;
                    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
                        val = val * 10 + @as(u32, line[i] - '0');
                    }
                    diag.rtprio_limit = val;
                }
                break;
            }
        }
    }
}

// ── Auto-Detect Best Core ───────────────────────────────────────────

/// Pick the best CPU core for audio: avoid core 0, prefer high IDs.
fn autoDetectCore() ?u32 {
    // Read /sys/devices/system/cpu/online — e.g. "0-15" or "0-7,12-15"
    if (readSysFile("/sys/devices/system/cpu/online")) |content| {
        var max_core: ?u32 = null;
        var iter = std.mem.splitScalar(u8, content, ',');
        while (iter.next()) |range| {
            const trimmed = std.mem.trim(u8, range, " \t\n\r");
            if (std.mem.indexOf(u8, trimmed, "-")) |dash| {
                // Range like "0-15"
                if (parseU32(trimmed[dash + 1 ..])) |high| {
                    if (max_core == null or high > max_core.?) max_core = high;
                }
            } else {
                // Single core like "3"
                if (parseU32(trimmed)) |core| {
                    if (max_core == null or core > max_core.?) max_core = core;
                }
            }
        }
        // Use highest core, but avoid core 0 (IRQ handler load)
        if (max_core) |mc| {
            if (mc > 0) return mc;
            return 0; // Single-core system — use core 0
        }
    }
    return null;
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Read a sysfs/procfs file into a stack buffer. Returns trimmed content or null.
var sys_read_buf: [4096]u8 = undefined;

fn readSysFile(path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.read(&sys_read_buf) catch return null;
    if (n == 0) return null;
    return std.mem.trim(u8, sys_read_buf[0..n], " \t\n\r");
}

fn copyToBuf(dest: *[32]u8, len: *u8, src: []const u8) void {
    const n: u8 = @intCast(@min(src.len, 32));
    @memcpy(dest[0..n], src[0..n]);
    len.* = n;
}

fn parseU32(s: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return null;
    var val: u32 = 0;
    for (trimmed) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + @as(u32, c - '0');
    }
    return val;
}

// ── Print Diagnostics ───────────────────────────────────────────────

/// Print RT diagnostics to stderr (for startup reporting).
/// Call from main thread AFTER setupAudioThread() returns.
pub fn printDiagnostics(diag: *const RtDiagnostics) void {
    std.debug.print("\nWorldSynth RT Environment:\n", .{});
    std.debug.print("  Scheduler:   {s:<36} [{s}]\n", .{
        diag.scheduler.label(),
        if (diag.scheduler.isRt()) "OK" else "WARN",
    });
    if (diag.cpu_pinned) |core| {
        std.debug.print("  CPU Pinned:  Core {d:<32} [OK]\n", .{core});
    } else {
        std.debug.print("  CPU Pinned:  not pinned                          [WARN]\n", .{});
    }
    std.debug.print("  Memory Lock: {s:<36} [{s}]\n", .{
        if (diag.memory_locked) "active" else "failed",
        if (diag.memory_locked) "OK" else "WARN",
    });
    std.debug.print("  Stack:       {d}KB pre-faulted{s:>21} [{s}]\n", .{
        @as(u32, 64),
        "",
        if (diag.stack_prefaulted) "OK" else "WARN",
    });
    const preempt = diag.getKernelPreempt();
    std.debug.print("  Preemption:  {s:<36} [{s}]\n", .{
        if (preempt.len > 0) preempt else "unknown",
        if (std.mem.startsWith(u8, preempt, "full")) "OK" else "WARN",
    });
    const gov = diag.getCpuGovernor();
    std.debug.print("  CPU Governor: {s:<35} [{s}]\n", .{
        if (gov.len > 0) gov else "unknown",
        if (std.mem.startsWith(u8, gov, "powersave")) "WARN" else "OK",
    });
    if (diag.rtprio_limit > 0) {
        std.debug.print("  RTPRIO Limit: {d}\n", .{diag.rtprio_limit});
    }

    // Print warnings
    if (diag.warning_count > 0) {
        std.debug.print("  Warnings:\n", .{});
        for (0..diag.warning_count) |i| {
            const w = diag.getWarning(i);
            if (w.len > 0) std.debug.print("    - {s}\n", .{w});
        }
    }
    std.debug.print("\n", .{});
}

// ── Tests ───────────────────────────────────────────────────────────

test "SchedulerLevel labels" {
    try std.testing.expectEqualStrings("SCHED_FIFO (priority 80)", SchedulerLevel.fifo_high.label());
    try std.testing.expectEqualStrings("SCHED_FIFO (priority 50)", SchedulerLevel.fifo_low.label());
    try std.testing.expectEqualStrings("SCHED_RR (priority 50)", SchedulerLevel.rr.label());
    try std.testing.expectEqualStrings("nice -20", SchedulerLevel.nice.label());
    try std.testing.expectEqualStrings("none (default scheduler)", SchedulerLevel.none.label());
}

test "SchedulerLevel isRt" {
    try std.testing.expect(SchedulerLevel.fifo_high.isRt());
    try std.testing.expect(SchedulerLevel.fifo_low.isRt());
    try std.testing.expect(SchedulerLevel.rr.isRt());
    try std.testing.expect(!SchedulerLevel.nice.isRt());
    try std.testing.expect(!SchedulerLevel.none.isRt());
}

test "RtDiagnostics addWarning" {
    var diag = RtDiagnostics{};
    diag.addWarning("test warning 1");
    diag.addWarning("test warning 2");
    try std.testing.expectEqual(@as(u8, 2), diag.warning_count);
    try std.testing.expectEqualStrings("test warning 1", diag.getWarning(0));
    try std.testing.expectEqualStrings("test warning 2", diag.getWarning(1));
    try std.testing.expectEqualStrings("", diag.getWarning(2)); // out of bounds
}

test "RtDiagnostics max warnings" {
    var diag = RtDiagnostics{};
    for (0..RtDiagnostics.MAX_WARNINGS + 2) |i| {
        _ = i;
        diag.addWarning("overflow test");
    }
    try std.testing.expectEqual(@as(u8, RtDiagnostics.MAX_WARNINGS), diag.warning_count);
}

test "cpu_set_t size" {
    // Linux cpu_set_t is 128 bytes = 1024 bits
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(cpu_set_t));
}

test "sched_param_t layout" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(sched_param_t));
}

test "parseU32 basic" {
    try std.testing.expectEqual(@as(?u32, 15), parseU32("15"));
    try std.testing.expectEqual(@as(?u32, 0), parseU32("0"));
    try std.testing.expectEqual(@as(?u32, 1023), parseU32("1023"));
    try std.testing.expectEqual(@as(?u32, null), parseU32(""));
    try std.testing.expectEqual(@as(?u32, null), parseU32("abc"));
    try std.testing.expectEqual(@as(?u32, 7), parseU32(" 7 "));
}

test "copyToBuf basic" {
    var buf: [32]u8 = .{0} ** 32;
    var len: u8 = 0;
    copyToBuf(&buf, &len, "hello");
    try std.testing.expectEqual(@as(u8, 5), len);
    try std.testing.expectEqualStrings("hello", buf[0..len]);
}

test "copyToBuf truncation" {
    var buf: [32]u8 = .{0} ** 32;
    var len: u8 = 0;
    const long = "this string is definitely longer than 32 characters and should be truncated";
    copyToBuf(&buf, &len, long);
    try std.testing.expectEqual(@as(u8, 32), len);
}

test "prefaultStack does not crash" {
    // Smoke test — just ensure it runs without segfault.
    prefaultStack(); // 64KB = 16 pages
}

test "prefaultBuffer does not crash" {
    var buf: [1024]f32 = .{0} ** 1024;
    prefaultBuffer(&buf);
}

test "autoDetectCore returns value on Linux" {
    // On any Linux system, /sys/devices/system/cpu/online should exist
    const core = autoDetectCore();
    // Should return something (or null on non-Linux/restricted environments)
    if (core) |c| {
        try std.testing.expect(c < 1024); // Reasonable core count
    }
}

test "RtDiagnostics getKernelPreempt and getCpuGovernor" {
    var diag = RtDiagnostics{};
    copyToBuf(&diag.kernel_preempt, &diag.kernel_preempt_len, "voluntary");
    copyToBuf(&diag.cpu_governor, &diag.cpu_governor_len, "schedutil");
    try std.testing.expectEqualStrings("voluntary", diag.getKernelPreempt());
    try std.testing.expectEqualStrings("schedutil", diag.getCpuGovernor());
}

test "setThreadPriority returns a valid level" {
    // On CI/unprivileged systems this may return .none or .nice — that's fine.
    // Without libc, always returns .none.
    const level = setThreadPriority();
    _ = level.label();
    _ = level.isRt();
    if (comptime !has_libc) {
        try std.testing.expectEqual(SchedulerLevel.none, level);
    }
}
