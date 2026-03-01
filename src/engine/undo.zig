const std = @import("std");
const param = @import("param.zig");
const ParamSnapshot = param.ParamSnapshot;

// ── Undo/Redo System (WP-123) ──────────────────────────────────────
// Ring-Buffer with ParamSnapshots, max 100 entries.
// UI-Thread only — no locks needed.
//
// Semantic model:
//   push(s) records the current state s in history.
//   undo() returns the PREVIOUS state (one step back).
//   redo() returns the state that was undone (one step forward).
//   New push after undo invalidates redo history.
//
// Requires at least 2 entries for undo (current + previous).

pub const UndoStack = struct {
    buffer: [max_entries]?ParamSnapshot = [_]?ParamSnapshot{null} ** max_entries,
    // head: next write position (one past the most recent entry)
    head: usize = 0,
    // count: number of entries in the buffer (including "current")
    count: usize = 0,
    // redo_count: entries available for redo ahead of current position
    redo_count: usize = 0,

    const max_entries = 100;

    /// Store a snapshot in the undo history.
    /// Invalidates any redo history (new branch).
    pub fn push(self: *UndoStack, snapshot: ParamSnapshot) void {
        self.buffer[self.head % max_entries] = snapshot;
        self.head +%= 1;
        if (self.count < max_entries) {
            self.count += 1;
        }
        self.redo_count = 0;
    }

    /// Undo: move back one step. Returns the PREVIOUS snapshot
    /// (the state before the current one), or null if nothing to undo.
    pub fn undo(self: *UndoStack) ?ParamSnapshot {
        if (self.count <= 1) return null;
        self.head -%= 1;
        self.count -= 1;
        self.redo_count += 1;
        // Return the entry BEFORE head (the new "current" state)
        return self.buffer[(self.head -% 1) % max_entries];
    }

    /// Redo: move forward one step. Returns the next snapshot
    /// (restoring the state that was undone), or null if nothing to redo.
    pub fn redo(self: *UndoStack) ?ParamSnapshot {
        if (self.redo_count == 0) return null;
        const snapshot = self.buffer[self.head % max_entries];
        self.head +%= 1;
        self.redo_count -= 1;
        self.count += 1;
        return snapshot;
    }

    /// Returns true if undo is possible (need at least 2 entries).
    pub fn canUndo(self: *const UndoStack) bool {
        return self.count > 1;
    }

    /// Returns true if redo is possible.
    pub fn canRedo(self: *const UndoStack) bool {
        return self.redo_count > 0;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

fn make_snapshot(version: u64) ParamSnapshot {
    var snap = ParamSnapshot{
        .values = [_]f64{0.0} ** param.PARAM_COUNT,
        .version = version,
    };
    snap.values[0] = @floatFromInt(version);
    return snap;
}

test "AC-1: push 3 snapshots, undo returns snapshot 2" {
    var stack = UndoStack{};
    stack.push(make_snapshot(1));
    stack.push(make_snapshot(2));
    stack.push(make_snapshot(3));

    // Undo returns the PREVIOUS snapshot (snapshot 2)
    const result = stack.undo();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 2), result.?.version);
    try std.testing.expectEqual(@as(f64, 2.0), result.?.values[0]);
}

test "AC-2: undo + redo returns same state as before" {
    var stack = UndoStack{};
    stack.push(make_snapshot(1));
    stack.push(make_snapshot(2));
    stack.push(make_snapshot(3));

    // Save state before undo
    const can_undo_before = stack.canUndo();
    const can_redo_before = stack.canRedo();

    // Undo returns snapshot 2 (previous)
    const undone = stack.undo();
    try std.testing.expectEqual(@as(u64, 2), undone.?.version);

    // Redo returns snapshot 3 (restores the undone state)
    const redone = stack.redo();
    try std.testing.expectEqual(@as(u64, 3), redone.?.version);

    // Stack state identical to before undo+redo
    try std.testing.expectEqual(can_undo_before, stack.canUndo());
    try std.testing.expectEqual(can_redo_before, stack.canRedo());
}

test "AC-3: push after undo invalidates redo" {
    var stack = UndoStack{};
    stack.push(make_snapshot(1));
    stack.push(make_snapshot(2));
    stack.push(make_snapshot(3));

    _ = stack.undo(); // back to snapshot 2
    try std.testing.expect(stack.canRedo());

    // New push creates a new branch — redo history gone
    stack.push(make_snapshot(4));
    try std.testing.expect(!stack.canRedo());
    try std.testing.expect(stack.redo() == null);
}

test "AC-4: ring-buffer overflow overwrites oldest" {
    var stack = UndoStack{};

    // Fill all 100 entries (versions 1..100)
    for (1..101) |i| {
        stack.push(make_snapshot(@intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, 100), stack.count);

    // Push 101st — overwrites slot 0 (version 1)
    stack.push(make_snapshot(101));
    try std.testing.expectEqual(@as(usize, 100), stack.count);

    // Undo all — oldest reachable should be version 2
    // (version 1 was overwritten, and we need 1 entry as "current")
    var oldest_version: u64 = 999;
    var undo_ops: usize = 0;
    while (stack.undo()) |snap| {
        oldest_version = snap.version;
        undo_ops += 1;
    }
    try std.testing.expectEqual(@as(u64, 2), oldest_version);
    // 100 entries, but canUndo needs count>1, so 99 undo ops
    try std.testing.expectEqual(@as(usize, 99), undo_ops);
}

test "AC-5: canUndo/canRedo return correct values" {
    var stack = UndoStack{};

    // Empty stack: nothing to undo or redo
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    // After 1 push: still no undo (need 2 entries: current + previous)
    stack.push(make_snapshot(1));
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    // After 2 pushes: can undo
    stack.push(make_snapshot(2));
    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());

    // After undo: can redo, cannot undo further
    _ = stack.undo();
    try std.testing.expect(!stack.canUndo());
    try std.testing.expect(stack.canRedo());

    // After redo: can undo again, cannot redo
    _ = stack.redo();
    try std.testing.expect(stack.canUndo());
    try std.testing.expect(!stack.canRedo());
}

test "AC-N1: undo on empty stack returns null, no crash" {
    var stack = UndoStack{};
    try std.testing.expect(stack.undo() == null);
    try std.testing.expect(stack.undo() == null);
    try std.testing.expect(stack.redo() == null);

    // Single entry: undo also returns null (need 2+)
    stack.push(make_snapshot(1));
    try std.testing.expect(stack.undo() == null);
}

test "multi-undo: sequential undo traverses history" {
    var stack = UndoStack{};
    stack.push(make_snapshot(1));
    stack.push(make_snapshot(2));
    stack.push(make_snapshot(3));
    stack.push(make_snapshot(4));

    // Undo 3 times: 3→2→1
    try std.testing.expectEqual(@as(u64, 3), stack.undo().?.version);
    try std.testing.expectEqual(@as(u64, 2), stack.undo().?.version);
    try std.testing.expectEqual(@as(u64, 1), stack.undo().?.version);
    // No more undo (count=1, only entry 1 left as "current")
    try std.testing.expect(stack.undo() == null);
}

test "multi-redo: sequential redo traverses forward" {
    var stack = UndoStack{};
    stack.push(make_snapshot(1));
    stack.push(make_snapshot(2));
    stack.push(make_snapshot(3));
    stack.push(make_snapshot(4));

    // Undo all
    _ = stack.undo();
    _ = stack.undo();
    _ = stack.undo();

    // Redo 3 times: 2→3→4
    try std.testing.expectEqual(@as(u64, 2), stack.redo().?.version);
    try std.testing.expectEqual(@as(u64, 3), stack.redo().?.version);
    try std.testing.expectEqual(@as(u64, 4), stack.redo().?.version);
    try std.testing.expect(stack.redo() == null);
}

test "benchmark: push/undo/redo latency" {
    var stack = UndoStack{};
    const snap = make_snapshot(42);

    // Fill stack
    for (0..100) |_| stack.push(snap);

    // Benchmark: 200x push
    var timer = try std.time.Timer.start();
    for (0..200) |_| stack.push(snap);
    const push_ns = timer.read();

    // Benchmark: 200x undo (need count>1, so max 199 from 200 entries)
    timer.reset();
    var undo_count: usize = 0;
    for (0..200) |_| {
        if (stack.undo() != null) undo_count += 1;
    }
    const undo_ns = timer.read();

    // Re-fill for redo benchmark
    for (0..200) |_| stack.push(snap);
    for (0..200) |_| _ = stack.undo();

    // Benchmark: 200x redo
    timer.reset();
    var redo_count: usize = 0;
    for (0..200) |_| {
        if (stack.redo() != null) redo_count += 1;
    }
    const redo_ns = timer.read();

    const push_us = @as(f64, @floatFromInt(push_ns)) / 1000.0;
    const undo_us = @as(f64, @floatFromInt(undo_ns)) / 1000.0;
    const redo_us = @as(f64, @floatFromInt(redo_ns)) / 1000.0;

    std.debug.print("\n  [WP-123] Undo/Redo Benchmark — 200 Operations each\n", .{});
    std.debug.print("    push: {d:.1}us total, {d:.3}us/op\n", .{ push_us, push_us / 200.0 });
    std.debug.print("    undo: {d:.1}us total, {d:.3}us/op ({} ops)\n", .{ undo_us, undo_us / @as(f64, @floatFromInt(undo_count)), undo_count });
    std.debug.print("    redo: {d:.1}us total, {d:.3}us/op ({} ops)\n", .{ redo_us, redo_us / @as(f64, @floatFromInt(redo_count)), redo_count });
    std.debug.print("    Memory: {} entries x {} bytes = {} bytes ({d:.1} KB)\n", .{
        UndoStack.max_entries,
        @sizeOf(ParamSnapshot),
        UndoStack.max_entries * @sizeOf(ParamSnapshot),
        @as(f64, @floatFromInt(UndoStack.max_entries * @sizeOf(ParamSnapshot))) / 1024.0,
    });

    // Thresholds from issue: < 500us for 200 operations
    try std.testing.expect(push_us < 500.0);
    try std.testing.expect(undo_us < 500.0);
    try std.testing.expect(redo_us < 500.0);
}
