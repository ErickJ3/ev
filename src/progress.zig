//! Lock-free progress tracking shared between scan workers and a dedicated
//! render thread. Workers bump atomic counters and publish their current path
//! into a per-worker slot; the Ticker thread renders a single status line to
//! stderr at a fixed interval, so feedback stays live no matter how long any
//! individual worker spends inside one subtree.
const std = @import("std");
const Io = std.Io;
const ui = @import("ui.zig");

pub const max_workers = 8;
const slot_count = max_workers + 1;
/// Workers publish their current path only every Nth directory to keep the
/// hot path cheap.
const path_update_interval = 16;

const PathSlot = struct {
    len: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    buf: [256]u8 = undefined,
};

/// Shared counters for one long-running operation. All methods are safe to
/// call from any thread. The path slots are intentionally racy for the
/// renderer: a torn read can only garble one displayed frame, never touch
/// invalid memory (fixed buffer, clamped length).
pub const Tracker = struct {
    dirs_visited: std.atomic.Value(usize) = .init(0),
    files_stated: std.atomic.Value(usize) = .init(0),
    bytes_found: std.atomic.Value(u64) = .init(0),
    items_found: std.atomic.Value(usize) = .init(0),
    /// Directories that could not be opened (permissions, races).
    dirs_denied: std.atomic.Value(usize) = .init(0),
    /// Completed units for phases with a known total.
    done: std.atomic.Value(usize) = .init(0),
    /// Known total units; 0 means unknown (render counts instead of k/n).
    total: usize = 0,
    last_writer: std.atomic.Value(usize) = .init(0),
    slots: [slot_count]PathSlot = @splat(.{}),

    /// Count a visited directory; periodically publish `path` as the
    /// worker's current position.
    pub fn addDir(self: *Tracker, slot: usize, path: []const u8) void {
        const n = self.dirs_visited.fetchAdd(1, .monotonic) + 1;
        if (n % path_update_interval == 0) self.setPath(slot, path);
    }

    /// Count a directory without publishing a path (used inside size
    /// recursion where only entry names are available).
    pub fn addDirCount(self: *Tracker) void {
        _ = self.dirs_visited.fetchAdd(1, .monotonic);
    }

    pub fn addFile(self: *Tracker) void {
        _ = self.files_stated.fetchAdd(1, .monotonic);
    }

    pub fn addDenied(self: *Tracker) void {
        _ = self.dirs_denied.fetchAdd(1, .monotonic);
    }

    pub fn addItem(self: *Tracker, bytes: u64) void {
        _ = self.items_found.fetchAdd(1, .monotonic);
        _ = self.bytes_found.fetchAdd(bytes, .monotonic);
    }

    pub fn addDone(self: *Tracker) void {
        _ = self.done.fetchAdd(1, .monotonic);
    }

    pub fn setPath(self: *Tracker, slot: usize, path: []const u8) void {
        const s = &self.slots[slot % slot_count];
        const n: u32 = @intCast(@min(path.len, s.buf.len));
        @memcpy(s.buf[0..n], path[0..n]);
        s.len.store(n, .release);
        self.last_writer.store(slot % slot_count, .monotonic);
    }

    fn snapshotPath(self: *Tracker, out: []u8) []const u8 {
        const idx = self.last_writer.load(.monotonic) % slot_count;
        const s = &self.slots[idx];
        const n: usize = @min(s.len.load(.acquire), @min(s.buf.len, out.len));
        @memcpy(out[0..n], s.buf[0..n]);
        return out[0..n];
    }
};

/// Renders a Tracker to a writer on a background thread at ~12 Hz.
/// The Ticker exclusively owns `writer` between begin() and end();
/// nothing else may write to it while the ticker is live.
pub const Ticker = struct {
    io: Io,
    writer: *Io.Writer,
    tracker: *Tracker,
    verb: []const u8,
    unit: []const u8,
    /// Word after the byte counter in the status line ("found", "freed").
    items_verb: []const u8 = "found",
    started_at: Io.Timestamp,
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    tick: usize = 0,

    pub fn init(io: Io, writer: *Io.Writer, tracker: *Tracker, verb: []const u8, unit: []const u8) Ticker {
        return .{
            .io = io,
            .writer = writer,
            .tracker = tracker,
            .verb = verb,
            .unit = unit,
            .started_at = Io.Timestamp.now(io, .awake),
        };
    }

    /// Spawn the render thread. `self` must not move afterwards.
    /// On spawn failure the ticker is inert and end() is still safe.
    pub fn begin(self: *Ticker) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    /// Stop the render thread, join it, and clear the status line.
    pub fn end(self: *Ticker) void {
        if (self.thread) |t| {
            self.stop_flag.store(true, .release);
            t.join();
            self.thread = null;
            ui.clearProgress(self.writer) catch {};
        }
    }

    fn run(self: *Ticker) void {
        while (!self.stop_flag.load(.acquire)) {
            self.render() catch {};
            self.io.sleep(.fromMilliseconds(80), .awake) catch break;
        }
    }

    fn render(self: *Ticker) !void {
        var path_buf: [256]u8 = undefined;
        const path = self.tracker.snapshotPath(&path_buf);
        const display = ui.pathTail(path, 40);
        const spin = ui.Spinner.frame(self.tick);
        self.tick +%= 1;

        var size_buf: [32]u8 = undefined;
        const size_str = ui.formatSize(&size_buf, self.tracker.bytes_found.load(.monotonic));
        const items = self.tracker.items_found.load(.monotonic);

        try self.writer.print("\x1b[?25l\r{s}{s} {s}...{s} ", .{
            ui.Color.cyan, spin, self.verb, ui.Color.reset,
        });

        if (self.tracker.total > 0) {
            try self.writer.print("{s}{d}/{d}{s} {s}", .{
                ui.Color.bold,
                self.tracker.done.load(.monotonic),
                self.tracker.total,
                ui.Color.reset,
                self.unit,
            });
        } else {
            const dirs = self.tracker.dirs_visited.load(.monotonic);
            // With nothing counted yet (or a counterless phase like status
            // collection) render just the spinner and label.
            if (dirs > 0) {
                const elapsed_ms = self.started_at.untilNow(self.io, .awake).toMilliseconds();
                const rate: usize = if (elapsed_ms > 0) dirs * 1000 / @as(usize, @intCast(elapsed_ms)) else 0;
                try self.writer.print("{s}{d}{s} {s} ({d}/s)", .{
                    ui.Color.bold, dirs, ui.Color.reset, self.unit, rate,
                });
            }
        }

        if (items > 0) {
            try self.writer.print(" {s}·{s} {d} {s} {s}·{s} {s}{s}{s}", .{
                ui.Color.dim,          ui.Color.reset, items,
                self.items_verb,       ui.Color.dim,   ui.Color.reset,
                ui.Color.bright_green, size_str,       ui.Color.reset,
            });
        }

        if (display.len > 0) {
            try self.writer.print(" {s}[{s}]{s}", .{ ui.Color.dim, display, ui.Color.reset });
        }

        try self.writer.writeAll("\x1b[K");
        try self.writer.flush();
    }
};

test "tracker counters" {
    var tracker: Tracker = .{};
    tracker.addDir(0, "/tmp/a");
    tracker.addFile();
    tracker.addItem(1024);
    tracker.addItem(1024);
    try std.testing.expectEqual(@as(usize, 1), tracker.dirs_visited.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tracker.files_stated.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), tracker.items_found.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2048), tracker.bytes_found.load(.monotonic));
}

test "tracker path slot roundtrip" {
    var tracker: Tracker = .{};
    tracker.setPath(3, "/home/user/projects/thing");
    var out: [256]u8 = undefined;
    const got = tracker.snapshotPath(&out);
    try std.testing.expectEqualStrings("/home/user/projects/thing", got);
}

test "tracker path slot clamps long paths" {
    var tracker: Tracker = .{};
    const long = "x" ** 300;
    tracker.setPath(0, long);
    var out: [256]u8 = undefined;
    const got = tracker.snapshotPath(&out);
    try std.testing.expectEqual(@as(usize, 256), got.len);
}
