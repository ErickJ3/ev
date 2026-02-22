//! Interactive TUI for item selection in `evi clean`.
//!
//! Provides raw terminal mode (via termios), keyboard input parsing
//! (arrows, vim-style j/k, and action keys), and a scrollable checkbox
//! list widget. The main entry point is `SelectionList.run()`, which
//! drives the render-input loop until the user confirms or cancels.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const scanner = @import("scanner.zig");
const ui_mod = @import("ui.zig");
const rules_mod = @import("rules.zig");

/// Manages raw terminal mode via POSIX termios.
///
/// Saves the original terminal attributes on `enable()` and restores
/// them on `disable()`, ensuring the terminal is never left in a
/// broken state (use with `defer`).
pub const RawTerm = struct {
    original: posix.termios,
    fd: posix.fd_t,

    // VMIN and VTIME indices in the cc array (standard Linux/FreeBSD)
    const VMIN_IDX = 6;
    const VTIME_IDX = 5;

    /// Enable raw terminal mode. Returns error if fd is not a TTY.
    pub fn enable(fd: posix.fd_t) !RawTerm {
        const original = try posix.tcgetattr(fd);
        var raw = original;

        // Disable canonical mode, echo, and signal processing
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;

        // Set VMIN=1, VTIME=0 for blocking single-character reads
        raw.cc[VMIN_IDX] = 1;
        raw.cc[VTIME_IDX] = 0;

        try posix.tcsetattr(fd, .FLUSH, raw);

        return .{
            .original = original,
            .fd = fd,
        };
    }

    /// Restore original terminal settings.
    pub fn disable(self: *const RawTerm) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }

    /// Read a keypress from the terminal.
    pub fn readKey(self: *const RawTerm) !Key {
        var buf: [4]u8 = undefined;
        const n = try posix.read(self.fd, &buf);
        if (n == 0) return .escape;

        return parseKey(buf[0..n]);
    }
};

/// Supported keybindings for the selection TUI.
///
/// Includes arrow keys (via ANSI escape sequences), vim-style `j`/`k`,
/// `Space` (toggle), `Enter` (confirm), `q`/`Esc` (cancel), and
/// `a` (select all) / `n` (deselect all).
pub const Key = enum {
    up,
    down,
    space,
    enter,
    escape,
    q,
    a, // select all
    n, // deselect all
    other,
};

/// Convert raw bytes read from the terminal fd into a `Key`.
///
/// Handles both multi-byte ANSI escape sequences (`\x1b[A`/`\x1b[B`
/// for arrow keys) and single-byte inputs (space, enter, vim keys, etc.).
pub fn parseKey(bytes: []const u8) Key {
    if (bytes.len == 0) return .other;

    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
        return switch (bytes[2]) {
            'A' => .up,
            'B' => .down,
            else => .other,
        };
    }

    return switch (bytes[0]) {
        0x1b => .escape,
        ' ' => .space,
        '\r', '\n' => .enter,
        'q', 'Q' => .q,
        'a', 'A' => .a,
        'n', 'N' => .n,
        'k' => .up, // vim-style
        'j' => .down, // vim-style
        else => .other,
    };
}

/// A scan result paired with its selection state for the interactive list.
pub const SelectionItem = struct {
    result: scanner.ScanResult,
    selected: bool,
};

/// Scrollable checkbox list for interactive item selection.
///
/// Renders a header, a visible window of items with cursor and checkboxes,
/// scroll indicators, and a footer with selected count/size. Navigation,
/// toggling, and bulk selection are handled by the `run()` event loop.
pub const SelectionList = struct {
    items: []SelectionItem,
    cursor: usize,
    scroll_offset: usize,
    max_visible: usize,
    allocator: std.mem.Allocator,

    /// Initialize the list with all items pre-selected.
    pub fn init(allocator: std.mem.Allocator, results: []const scanner.ScanResult, max_visible: usize) !SelectionList {
        const items = try allocator.alloc(SelectionItem, results.len);
        for (results, 0..) |r, i| {
            items[i] = .{
                .result = r,
                .selected = true,
            };
        }
        return .{
            .items = items,
            .cursor = 0,
            .scroll_offset = 0,
            .max_visible = max_visible,
            .allocator = allocator,
        };
    }

    /// Free the allocated items slice.
    pub fn deinit(self: *SelectionList) void {
        self.allocator.free(self.items);
    }

    /// Move the cursor up one position, scrolling if necessary.
    pub fn moveUp(self: *SelectionList) void {
        if (self.items.len == 0) return;
        if (self.cursor > 0) {
            self.cursor -= 1;
            if (self.cursor < self.scroll_offset) {
                self.scroll_offset = self.cursor;
            }
        }
    }

    /// Move the cursor down one position, scrolling if necessary.
    pub fn moveDown(self: *SelectionList) void {
        if (self.items.len == 0) return;
        if (self.cursor < self.items.len - 1) {
            self.cursor += 1;
            if (self.cursor >= self.scroll_offset + self.max_visible) {
                self.scroll_offset = self.cursor - self.max_visible + 1;
            }
        }
    }

    /// Toggle the selection state of the item under the cursor.
    pub fn toggleCurrent(self: *SelectionList) void {
        if (self.items.len == 0) return;
        self.items[self.cursor].selected = !self.items[self.cursor].selected;
    }

    /// Mark all items as selected.
    pub fn selectAll(self: *SelectionList) void {
        for (self.items) |*item| {
            item.selected = true;
        }
    }

    /// Mark all items as deselected.
    pub fn deselectAll(self: *SelectionList) void {
        for (self.items) |*item| {
            item.selected = false;
        }
    }

    /// Return the number of currently selected items.
    pub fn selectedCount(self: *const SelectionList) usize {
        var count: usize = 0;
        for (self.items) |item| {
            if (item.selected) count += 1;
        }
        return count;
    }

    /// Return the total size (in bytes) of all selected items.
    pub fn selectedSize(self: *const SelectionList) u64 {
        var total: u64 = 0;
        for (self.items) |item| {
            if (item.selected) total += item.result.size;
        }
        return total;
    }

    const SelectedStats = struct { count: usize, size: u64 };

    /// Compute selected count and total size in a single pass over items.
    fn selectedStats(self: *const SelectionList) SelectedStats {
        var count: usize = 0;
        var size: u64 = 0;
        for (self.items) |item| {
            if (item.selected) {
                count += 1;
                size += item.result.size;
            }
        }
        return .{ .count = count, .size = size };
    }

    /// Return the indices of all selected items.
    pub fn getSelected(self: *const SelectionList, allocator: std.mem.Allocator) ![]usize {
        var indices: std.ArrayList(usize) = .empty;
        errdefer indices.deinit(allocator);
        for (self.items, 0..) |item, i| {
            if (item.selected) {
                try indices.append(allocator, i);
            }
        }
        return indices.toOwnedSlice(allocator);
    }

    /// Draw the selection list to the given writer.
    ///
    /// Uses cursor-home then erase-below (instead of full-screen clear)
    /// to avoid visible flicker between frames.
    pub fn render(self: *const SelectionList, writer: anytype) !void {
        // Move cursor to home position (content is overwritten in-place)
        try writer.print("\x1b[H", .{});
        try writer.print("{s}{s} evi cleaner{s}\n\n", .{ ui_mod.Color.bold, ui_mod.Color.cyan, ui_mod.Color.reset });
        try writer.print("  Use {s}\xe2\x86\x91\xe2\x86\x93{s}/jk to move, {s}Space{s} to toggle, {s}a{s}ll/{s}n{s}one, {s}Enter{s} to confirm, {s}q{s} to cancel\n\n", .{
            ui_mod.Color.bold, ui_mod.Color.reset,
            ui_mod.Color.bold, ui_mod.Color.reset,
            ui_mod.Color.bold, ui_mod.Color.reset,
            ui_mod.Color.bold, ui_mod.Color.reset,
            ui_mod.Color.bold, ui_mod.Color.reset,
            ui_mod.Color.bold, ui_mod.Color.reset,
        });

        const end = @min(self.scroll_offset + self.max_visible, self.items.len);
        for (self.scroll_offset..end) |i| {
            const item = self.items[i];
            const is_cursor = (i == self.cursor);

            const check = if (item.selected) "x" else " ";
            const cursor_indicator = if (is_cursor) ">" else " ";
            const highlight = if (is_cursor) ui_mod.Color.bold else "";

            var size_buf: [32]u8 = undefined;
            const size_str = ui_mod.formatSize(&size_buf, item.result.size);

            try writer.print("  {s}{s}[{s}] {s}{s:<10}{s} {s:<10} {s}{s}\n", .{
                highlight,
                cursor_indicator,
                check,
                ui_mod.categoryColor(item.result.rule.category),
                item.result.rule.category.label(),
                ui_mod.Color.reset,
                size_str,
                item.result.path,
                if (is_cursor) ui_mod.Color.reset else "",
            });
        }

        if (self.items.len > self.max_visible) {
            if (self.scroll_offset > 0) {
                try writer.print("\n  {s}... {d} more above{s}", .{ ui_mod.Color.dim, self.scroll_offset, ui_mod.Color.reset });
            }
            if (end < self.items.len) {
                try writer.print("\n  {s}... {d} more below{s}", .{ ui_mod.Color.dim, self.items.len - end, ui_mod.Color.reset });
            }
        }

        const stats = self.selectedStats();
        var total_buf: [32]u8 = undefined;
        const total_str = ui_mod.formatSize(&total_buf, stats.size);
        try writer.print("\n\n  {s}Selected: {d}/{d} items, {s}{s}\n", .{
            ui_mod.Color.green,
            stats.count,
            self.items.len,
            total_str,
            ui_mod.Color.reset,
        });

        // Erase from cursor to end of screen (clears stale lines from previous frame)
        try writer.print("\x1b[J", .{});
    }

    /// Main event loop: renders the list, reads input, and dispatches actions.
    ///
    /// Returns `true` if the user confirmed (Enter), `false` if cancelled
    /// (Esc/q). The terminal is put into raw mode for the duration and
    /// restored on return.
    pub fn run(self: *SelectionList, io: Io, stdin_fd: posix.fd_t, writer: *Io.File.Writer) !bool {
        const stdin_file = Io.File.stdin();
        if (!(try stdin_file.isTty(io))) return error.NotATty;

        var raw = try RawTerm.enable(stdin_fd);
        defer raw.disable();

        const iface = &writer.interface;

        try iface.print("\x1b[?25l", .{});
        try iface.flush();

        defer {
            iface.print("\x1b[?25h", .{}) catch {};
            iface.flush() catch {};
        }

        while (true) {
            try self.render(iface);
            try iface.flush();

            const key = try raw.readKey();
            switch (key) {
                .up => self.moveUp(),
                .down => self.moveDown(),
                .space => self.toggleCurrent(),
                .a => self.selectAll(),
                .n => self.deselectAll(),
                .enter => return true,
                .escape, .q => return false,
                .other => {},
            }
        }
    }
};

test "parseKey escape sequence up arrow" {
    const key = parseKey(&[_]u8{ 0x1b, '[', 'A' });
    try std.testing.expectEqual(Key.up, key);
}

test "parseKey escape sequence down arrow" {
    const key = parseKey(&[_]u8{ 0x1b, '[', 'B' });
    try std.testing.expectEqual(Key.down, key);
}

test "parseKey single bytes" {
    try std.testing.expectEqual(Key.space, parseKey(&[_]u8{' '}));
    try std.testing.expectEqual(Key.enter, parseKey(&[_]u8{'\r'}));
    try std.testing.expectEqual(Key.enter, parseKey(&[_]u8{'\n'}));
    try std.testing.expectEqual(Key.q, parseKey(&[_]u8{'q'}));
    try std.testing.expectEqual(Key.escape, parseKey(&[_]u8{0x1b}));
    try std.testing.expectEqual(Key.a, parseKey(&[_]u8{'a'}));
    try std.testing.expectEqual(Key.n, parseKey(&[_]u8{'n'}));
}

test "parseKey vim-style j/k" {
    try std.testing.expectEqual(Key.down, parseKey(&[_]u8{'j'}));
    try std.testing.expectEqual(Key.up, parseKey(&[_]u8{'k'}));
}

test "parseKey unknown" {
    try std.testing.expectEqual(Key.other, parseKey(&[_]u8{'x'}));
    try std.testing.expectEqual(Key.other, parseKey(&[_]u8{}));
}

const test_rule_dev: rules_mod.Rule = .{
    .name = "test-node-modules",
    .description = "Test rule",
    .category = .dev,
    .risk = .safe,
    .detection = .{ .dir_name = "node_modules" },
};

const test_rule_pkg: rules_mod.Rule = .{
    .name = "test-cache",
    .description = "Test cache rule",
    .category = .package,
    .risk = .moderate,
    .detection = .{ .dir_name = ".cache" },
};

fn makeTestResults() [3]scanner.ScanResult {
    return .{
        .{ .path = "/home/user/project1/node_modules", .size = 1024 * 1024 * 200, .rule = &test_rule_dev },
        .{ .path = "/home/user/project2/node_modules", .size = 1024 * 1024 * 150, .rule = &test_rule_dev },
        .{ .path = "/home/user/.cache/pip", .size = 1024 * 1024 * 50, .rule = &test_rule_pkg },
    };
}

test "cursor movement and wrapping" {
    const allocator = std.testing.allocator;
    const results = makeTestResults();
    var list = try SelectionList.init(allocator, &results, 10);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 0), list.cursor);

    list.moveDown();
    try std.testing.expectEqual(@as(usize, 1), list.cursor);

    list.moveDown();
    try std.testing.expectEqual(@as(usize, 2), list.cursor);

    list.moveDown();
    try std.testing.expectEqual(@as(usize, 2), list.cursor);

    list.moveUp();
    try std.testing.expectEqual(@as(usize, 1), list.cursor);

    list.moveUp();
    try std.testing.expectEqual(@as(usize, 0), list.cursor);

    list.moveUp();
    try std.testing.expectEqual(@as(usize, 0), list.cursor);
}

test "toggle and selectAll/deselectAll" {
    const allocator = std.testing.allocator;
    const results = makeTestResults();
    var list = try SelectionList.init(allocator, &results, 10);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 3), list.selectedCount());

    list.toggleCurrent();
    try std.testing.expect(!list.items[0].selected);
    try std.testing.expectEqual(@as(usize, 2), list.selectedCount());

    list.toggleCurrent();
    try std.testing.expect(list.items[0].selected);

    list.deselectAll();
    try std.testing.expectEqual(@as(usize, 0), list.selectedCount());

    list.selectAll();
    try std.testing.expectEqual(@as(usize, 3), list.selectedCount());
}

test "scroll offset when cursor exceeds visible range" {
    const allocator = std.testing.allocator;
    const results = makeTestResults();
    var list = try SelectionList.init(allocator, &results, 2);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);

    list.moveDown(); // cursor=1, scroll=0 (visible: 0,1)
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);

    list.moveDown(); // cursor=2, scroll should advance
    try std.testing.expectEqual(@as(usize, 1), list.scroll_offset);

    list.moveUp(); // cursor=1, scroll=1 (visible: 1,2)
    try std.testing.expectEqual(@as(usize, 1), list.scroll_offset);

    list.moveUp(); // cursor=0, scroll should go back
    try std.testing.expectEqual(@as(usize, 0), list.scroll_offset);
}

test "getSelected returns correct indices" {
    const allocator = std.testing.allocator;
    const results = makeTestResults();
    var list = try SelectionList.init(allocator, &results, 10);
    defer list.deinit();

    list.deselectAll();
    list.items[0].selected = true;
    list.items[2].selected = true;

    const selected = try list.getSelected(allocator);
    defer allocator.free(selected);

    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(@as(usize, 0), selected[0]);
    try std.testing.expectEqual(@as(usize, 2), selected[1]);
}

test "selectedSize sums correctly" {
    const allocator = std.testing.allocator;
    const results = makeTestResults();
    var list = try SelectionList.init(allocator, &results, 10);
    defer list.deinit();

    const total = list.selectedSize();
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * (200 + 150 + 50)), total);

    list.deselectAll();
    try std.testing.expectEqual(@as(u64, 0), list.selectedSize());
}
