const std = @import("std");
const builtin = @import("builtin");

// -- Content-Addressable Storage (WP-070) -------------------------------------
// SHA-256 based CAS for preset/wavetable deduplication. Git-like directory
// structure: base_path/XX/YY/XXYYZZ... (first 4 hex chars split into 2 levels).
// IO-thread only — no audio-thread usage. Zero heap allocation in store/load.

pub const HASH_SIZE: usize = 32;
pub const HEX_SIZE: usize = 64;

const Sha256 = std.crypto.hash.sha2.Sha256;

// -- Hex Encoding -------------------------------------------------------------

pub fn hex_encode(hash_val: [HASH_SIZE]u8) [HEX_SIZE]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [HEX_SIZE]u8 = undefined;
    for (hash_val, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

// -- ContentStore -------------------------------------------------------------

pub const ContentStore = struct {
    base_path: [256]u8,
    base_len: u8,

    pub fn init(path: []const u8) ContentStore {
        var self = ContentStore{
            .base_path = undefined,
            .base_len = @intCast(@min(path.len, 256)),
        };
        @memcpy(self.base_path[0..self.base_len], path[0..self.base_len]);
        return self;
    }

    /// Compute SHA-256 hash of data.
    pub fn hash(data: []const u8) [HASH_SIZE]u8 {
        var out: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data, &out, .{});
        return out;
    }

    /// Store data, return its SHA-256 hash. Deduplicates: skips write if
    /// content with the same hash already exists.
    pub fn store(self: *const ContentStore, data: []const u8) ![HASH_SIZE]u8 {
        const hash_val = ContentStore.hash(data);

        // Dedup: skip write if already stored.
        if (self.exists(hash_val)) return hash_val;

        // Build file path.
        var path_buf: [512]u8 = undefined;
        const file_path = try self.build_path(hash_val, &path_buf);

        // Create parent directories.
        const dir_end = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return error.InvalidPath;
        try std.fs.cwd().makePath(file_path[0..dir_end]);

        // Write content.
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(data);

        return hash_val;
    }

    /// Load content by hash into caller-provided buffer. Returns slice of bytes read.
    pub fn load(self: *const ContentStore, hash_val: [HASH_SIZE]u8, buf: []u8) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const file_path = try self.build_path(hash_val, &path_buf);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        const size: usize = @intCast(stat.size);
        if (size > buf.len) return error.BufferTooSmall;
        const bytes_read = try file.readAll(buf[0..size]);
        return buf[0..bytes_read];
    }

    /// Check if content with given hash exists in store.
    pub fn exists(self: *const ContentStore, hash_val: [HASH_SIZE]u8) bool {
        var path_buf: [512]u8 = undefined;
        const file_path = self.build_path(hash_val, &path_buf) catch return false;
        std.fs.cwd().access(file_path, .{}) catch return false;
        return true;
    }

    fn build_path(self: *const ContentStore, hash_val: [HASH_SIZE]u8, buf: *[512]u8) ![]u8 {
        const hex = hex_encode(hash_val);
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{
            self.base_path[0..self.base_len],
            hex[0..2],
            hex[2..4],
            &hex,
        });
    }
};

// -- Tests (WP-070 CAS) ------------------------------------------------------
// IMPORTANT: Every test/benchmark MUST start with `var t = try std.time.Timer.start();`
// and print elapsed time at the end: `[{d:.2}ms]`. This is mandatory for all new tests.

const TEST_DIR = "/tmp/worldsynth-cas-test";

fn cleanup_test_dir() void {
    std.fs.cwd().deleteTree(TEST_DIR) catch {};
}

test "WP-070 AC-1: same data produces same hash" {
    var t = try std.time.Timer.start();
    const data_a = "hello worldsynth preset data";
    const data_b = "hello worldsynth preset data";
    const data_c = "different preset data";

    const hash_a = ContentStore.hash(data_a);
    const hash_b = ContentStore.hash(data_b);
    const hash_c = ContentStore.hash(data_c);

    // Identical data → identical hash.
    try std.testing.expectEqualSlices(u8, &hash_a, &hash_b);

    // Different data → different hash.
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_c));

    const elapsed = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
    std.debug.print("\n[WP-070] AC-1: deterministic hash PASS [{d:.2}ms]\n", .{elapsed});
}

test "WP-070 AC-3: store/load roundtrip" {
    var t = try std.time.Timer.start();
    cleanup_test_dir();
    defer cleanup_test_dir();

    var cas = ContentStore.init(TEST_DIR);
    const data = "preset binary payload for roundtrip test — 1234567890";

    // Store.
    const hash_val = try cas.store(data);
    try std.testing.expect(cas.exists(hash_val));

    // Load.
    var load_buf: [1024]u8 = undefined;
    const loaded = try cas.load(hash_val, &load_buf);

    try std.testing.expectEqualSlices(u8, data, loaded);

    // Store again — dedup (should not crash or duplicate).
    const hash_val2 = try cas.store(data);
    try std.testing.expectEqualSlices(u8, &hash_val, &hash_val2);

    const elapsed = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
    std.debug.print("\n[WP-070] AC-3: store/load roundtrip PASS [{d:.2}ms]\n", .{elapsed});
}

test "WP-070 dedup: 100 identical stores produce 1 entry" {
    var t = try std.time.Timer.start();
    cleanup_test_dir();
    defer cleanup_test_dir();

    var cas = ContentStore.init(TEST_DIR);
    const data = "identical wavetable data for dedup verification";

    var first_hash: [HASH_SIZE]u8 = undefined;
    for (0..100) |i| {
        const h = try cas.store(data);
        if (i == 0) first_hash = h;
        try std.testing.expectEqualSlices(u8, &first_hash, &h);
    }
    try std.testing.expect(cas.exists(first_hash));

    const elapsed = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
    std.debug.print("\n[WP-070] dedup: 100 stores -> same hash PASS [{d:.2}ms]\n", .{elapsed});
}

test "WP-070 AC-B1: CAS benchmarks" {
    var t = try std.time.Timer.start();
    cleanup_test_dir();
    defer cleanup_test_dir();

    // Simulate wavetable data: 256 frames * 2048 samples * 4 bytes = 2MB.
    const wt_size = 256 * 2048 * @sizeOf(f32);
    const data = try std.heap.page_allocator.alloc(u8, wt_size);
    defer std.heap.page_allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    const iterations: u64 = switch (builtin.mode) {
        .Debug => 5,
        .ReleaseSafe => 20,
        .ReleaseFast, .ReleaseSmall => 100,
    };

    // Warmup hash.
    _ = ContentStore.hash(data);

    // Benchmark: hash computation.
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        _ = ContentStore.hash(data);
    }
    const hash_ns = timer.read() / iterations;

    // Benchmark: store (first write).
    var cas = ContentStore.init(TEST_DIR);
    timer.reset();
    const hash_val = try cas.store(data);
    const store_ns = timer.read();

    // Benchmark: exists lookup.
    timer.reset();
    for (0..iterations) |_| {
        _ = cas.exists(hash_val);
    }
    const lookup_ns = timer.read() / iterations;

    const hash_budget: u64 = switch (builtin.mode) {
        .Debug => 500_000_000, // 500ms (SHA-256 unoptimized ~100x slower)
        .ReleaseSafe => 20_000_000, // 20ms
        .ReleaseFast, .ReleaseSmall => 5_000_000, // 5ms (SHA-256 on 2MB data)
    };
    const lookup_budget: u64 = switch (builtin.mode) {
        .Debug => 1_000_000,
        .ReleaseSafe => 100_000,
        .ReleaseFast, .ReleaseSmall => 50_000, // 50µs (file existence check)
    };
    const store_budget: u64 = switch (builtin.mode) {
        .Debug => 1_000_000_000, // 1s (hash + file write, unoptimized)
        .ReleaseSafe => 100_000_000, // 100ms
        .ReleaseFast, .ReleaseSmall => 50_000_000, // 50ms (2MB file write)
    };

    const elapsed = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
    std.debug.print("\n[WP-070] AC-B1: hash={d}ns (budget {d}ns), lookup={d}ns (budget {d}ns), store={d}ns (budget {d}ns), mode={s} [{d:.2}ms total]\n", .{
        hash_ns, hash_budget, lookup_ns, lookup_budget, store_ns, store_budget, @tagName(builtin.mode), elapsed,
    });

    try std.testing.expect(hash_ns < hash_budget);
    try std.testing.expect(lookup_ns < lookup_budget);
    try std.testing.expect(store_ns < store_budget);
}
