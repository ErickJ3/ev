//! Terminal rendering layer for the `evi` disk-cleanup CLI.
//!
//! Provides ANSI-colored output primitives (colors, box-drawing, bars, spinners),
//! formatted scan results, progress indicators, and branded headers.
//! Consumed by `main`, `analyzer`, `monitor`, `scanner`, `logger`, and `tui`.

const std = @import("std");
const builtin = @import("builtin");
const rules = @import("rules.zig");

/// ANSI SGR escape sequences for text styling.
/// Groups: basic (30-37), bright (90-97), 256-color (`38;5;N`).
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    // Bright variants (90-97)
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_cyan = "\x1b[96m";
    pub const bright_white = "\x1b[97m";

    // 256-color: gradient bar colors
    pub const fg_green_256 = "\x1b[38;5;34m"; // green
    pub const fg_lime_256 = "\x1b[38;5;118m"; // lime/yellow-green
    pub const fg_orange_256 = "\x1b[38;5;208m"; // orange
    pub const fg_red_256 = "\x1b[38;5;196m"; // red

    // 256-color: grays
    pub const fg_dark_gray = "\x1b[38;5;240m";
    pub const fg_medium_gray = "\x1b[38;5;245m";

    // 256-color: category accents
    pub const fg_teal = "\x1b[38;5;37m";
    pub const fg_purple = "\x1b[38;5;135m";
    pub const fg_sky = "\x1b[38;5;75m";
    pub const fg_gold = "\x1b[38;5;220m";
    pub const fg_coral = "\x1b[38;5;209m";

    // 256-color: rank medal colors
    pub const fg_gold_medal = "\x1b[38;5;220m";
    pub const fg_silver_medal = "\x1b[38;5;250m";
    pub const fg_bronze_medal = "\x1b[38;5;173m";
};

/// Unicode box-drawing characters and block/symbol elements for TUI frames.
pub const Box = struct {
    // Rounded corners
    pub const top_left = "\xe2\x95\xad"; // ╭
    pub const top_right = "\xe2\x95\xae"; // ╮
    pub const bottom_left = "\xe2\x95\xb0"; // ╰
    pub const bottom_right = "\xe2\x95\xaf"; // ╯

    // Lines
    pub const h_line = "\xe2\x94\x80"; // ─
    pub const v_line = "\xe2\x94\x82"; // │
    pub const t_right = "\xe2\x94\x9c"; // ├
    pub const t_left = "\xe2\x94\xa4"; // ┤

    // Block elements
    pub const block_full = "\xe2\x96\x88"; // █
    pub const block_light = "\xe2\x96\x91"; // ░

    // Symbols
    pub const bullet = "\xe2\x97\x8f"; // ●
    pub const diamond = "\xe2\x97\x86"; // ◆
    pub const arrow_right = "\xe2\x96\xb6"; // ▶
    pub const arrow_down = "\xe2\x86\x93"; // ↓
    pub const arrow_up = "\xe2\x86\x91"; // ↑

    // Section icons
    pub const gear = "\xe2\x9a\x99"; // ⚙
    pub const grid = "\xe2\x96\xa6"; // ▦
    pub const bars = "\xe2\x96\xa4"; // ▤
    pub const arrows_ud = "\xe2\x87\x85"; // ⇅
};

/// Accumulator for byte totals broken down by `rules.Category`.
///
/// Used to collect per-category sizes during a scan, then rendered by
/// `printCategoryBreakdown`. The field `package_` has a trailing underscore
/// because `package` is a Zig keyword.
pub const CategorySizes = struct {
    dev: u64 = 0,
    system: u64 = 0,
    package_: u64 = 0,
    ai: u64 = 0,
    browser: u64 = 0,

    /// Returns the accumulated size for `cat`.
    pub fn get(self: CategorySizes, cat: rules.Category) u64 {
        return switch (cat) {
            .dev => self.dev,
            .system => self.system,
            .package => self.package_,
            .ai => self.ai,
            .browser => self.browser,
        };
    }

    /// Adds `size` bytes to the running total for `cat`.
    pub fn add(self: *CategorySizes, cat: rules.Category, size: u64) void {
        switch (cat) {
            .dev => self.dev += size,
            .system => self.system += size,
            .package => self.package_ += size,
            .ai => self.ai += size,
            .browser => self.browser += size,
        }
    }

    /// Returns the grand total across all categories.
    pub fn total(self: CategorySizes) u64 {
        return self.dev + self.system + self.package_ + self.ai + self.browser;
    }
};

/// Braille-dot spinner animation for progress indicators.
/// Cycles through 10 frames: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
pub const Spinner = struct {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn frame(tick: usize) []const u8 {
        return frames[tick % frames.len];
    }
};

/// Returns a color escape based on usage percentage (green->lime->orange->red).
pub fn usageColor(pct: f64) []const u8 {
    if (pct < 50.0) return Color.fg_green_256;
    if (pct < 70.0) return Color.fg_lime_256;
    if (pct < 85.0) return Color.fg_orange_256;
    return Color.fg_red_256;
}

/// Returns a color escape based on byte magnitude.
pub fn sizeColor(bytes: u64) []const u8 {
    const mb_100 = 100 * 1024 * 1024;
    const gb_1 = 1024 * 1024 * 1024;
    const gb_10 = 10 * @as(u64, 1024 * 1024 * 1024);
    if (bytes < mb_100) return Color.fg_medium_gray;
    if (bytes < gb_1) return Color.bright_white;
    if (bytes < gb_10) return Color.bright_yellow;
    return Color.bright_red;
}

/// Maps a `rules.Category` to its 256-color accent for category bars and labels.
pub fn categoryColor(cat: rules.Category) []const u8 {
    return switch (cat) {
        .dev => Color.fg_teal,
        .system => Color.fg_purple,
        .package => Color.fg_sky,
        .ai => Color.fg_gold,
        .browser => Color.fg_coral,
    };
}

/// Maps a `rules.Risk` level to a basic ANSI color (green/yellow/red).
pub fn riskColor(risk: rules.Risk) []const u8 {
    return switch (risk) {
        .safe => Color.green,
        .moderate => Color.yellow,
        .caution => Color.red,
    };
}

/// Returns the number of visible columns a UTF-8 string occupies.
/// Counts codepoints (each multi-byte sequence = 1 column).
pub fn visibleLen(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            i += 1;
        } else if (byte < 0xE0) {
            i += 2;
        } else if (byte < 0xF0) {
            i += 3;
        } else {
            i += 4;
        }
        cols += 1;
    }
    return cols;
}

/// Truncates a UTF-8 string to at most `max_cols` visible columns.
/// Returns a byte slice that ends on a codepoint boundary.
pub fn truncateUtf8(s: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len and cols < max_cols) {
        const byte = s[i];
        const cp_len: usize = if (byte < 0x80) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
        if (i + cp_len > s.len) break;
        i += cp_len;
        cols += 1;
    }
    return s[0..i];
}

/// Prints a UTF-8 string `count` times.
pub fn printRepeat(writer: anytype, str: []const u8, count: usize) !void {
    for (0..count) |_| {
        try writer.writeAll(str);
    }
}

/// Formats a byte count into a human-readable string using binary units
/// (B, KB, MB, GB, TB). Writes into `buf` and returns the formatted slice.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }
    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "???";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ size, units[unit_idx] }) catch "???";
}

/// Returns short uptime like "14h" or "2d".
pub fn fmtShortUptime(buf: []u8, seconds: u64) []const u8 {
    if (seconds == 0) return "?";
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const mins = (seconds % 3600) / 60;
    if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "?";
    } else if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "?";
    }
}

/// Extracts a short CPU model identifier from the full string.
/// E.g. "11th Gen Intel(R) Core(TM) i5-11300H @ 3.10GHz" -> "i5-11300H"
pub fn fmtShortCpuModel(model: []const u8) []const u8 {
    // Search for "iN-" pattern (Intel Core iX-)
    if (std.mem.indexOf(u8, model, "i3-") orelse
        std.mem.indexOf(u8, model, "i5-") orelse
        std.mem.indexOf(u8, model, "i7-") orelse
        std.mem.indexOf(u8, model, "i9-")) |start|
    {
        const rest = model[start..];
        // Find end: space or @ or end of string
        for (rest, 0..) |c, idx| {
            if (c == ' ' or c == '@') return rest[0..idx];
        }
        return rest;
    }
    // Search for "Ryzen" pattern
    if (std.mem.indexOf(u8, model, "Ryzen")) |start| {
        const rest = model[start..];
        // Take up to 2 spaces worth (e.g. "Ryzen 7 5800X")
        var spaces: u8 = 0;
        for (rest, 0..) |c, idx| {
            if (c == ' ') spaces += 1;
            if (spaces >= 3) return rest[0..idx];
        }
        return rest;
    }
    // Fallback: return up to 20 chars
    return if (model.len > 20) model[0..20] else model;
}

/// Queries the terminal width via `ioctl(TIOCGWINSZ)`.
/// Returns 80 columns as a safe fallback on unsupported platforms or failure.
pub fn getTerminalWidth() u16 {
    const TIOCGWINSZ = switch (builtin.os.tag) {
        .linux => @as(u32, 0x5413),
        .freebsd => @as(u32, 0x40087468),
        else => return 80,
    };
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
    const rc = std.posix.system.ioctl(1, TIOCGWINSZ, @intFromPtr(&ws));
    return if (rc == 0 and ws.ws_col > 0) ws.ws_col else 80;
}

/// Emits ANSI CHA (Cursor Horizontal Absolute) to jump to column `col` (1-based).
pub fn cursorTo(writer: anytype, col: u16) !void {
    try writer.print("\x1b[{d}G", .{col});
}

/// Module-level tick counter for `printProgress`. Mutable because the spinner
/// must advance across successive calls without caller-managed state.
var progress_tick: usize = 0;

/// Prints a single-line progress indicator with a braille spinner, directory
/// count, and truncated current path. Overwrites the current line with `\r`
/// and hides the cursor while active.
pub fn printProgress(writer: anytype, count: usize, path: []const u8) !void {
    const max_display: usize = 40;
    const display = if (path.len > max_display) path[path.len - max_display ..] else path;
    const spin = Spinner.frame(progress_tick);
    progress_tick +%= 1;
    try writer.print("\x1b[?25l\r{s}{s} Scanning...{s} {s}{d}{s} dirs checked {s}[{s}]{s}" ++ " " ** 10, .{
        Color.cyan,
        spin,
        Color.reset,
        Color.bold,
        count,
        Color.reset,
        Color.dim,
        display,
        Color.reset,
    });
    try writer.flush();
}

/// Clears the progress line, resets the spinner tick, and restores cursor visibility.
pub fn clearProgress(writer: anytype) !void {
    progress_tick = 0;
    try writer.print("\r" ++ " " ** 80 ++ "\r\x1b[?25h", .{});
    try writer.flush();
}

/// Module-level tick counter for `printDeleteProgress`.
var delete_tick: usize = 0;

/// Prints a single-line deletion progress indicator with a braille spinner,
/// item count, freed size, and truncated current path. Overwrites the current
/// line with `\r` and hides the cursor while active.
pub fn printDeleteProgress(writer: anytype, current: usize, total_items: usize, freed_size: u64, path: []const u8) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, freed_size);
    const max_display: usize = 40;
    const display = if (path.len > max_display) path[path.len - max_display ..] else path;
    const spin = Spinner.frame(delete_tick);
    delete_tick +%= 1;
    try writer.print("\x1b[?25l\r{s}{s} Deleting...{s} {s}{d}/{d}{s} items ({s}{s}{s} freed) {s}[{s}]{s}" ++ " " ** 10, .{
        Color.cyan,
        spin,
        Color.reset,
        Color.bold,
        current,
        total_items,
        Color.reset,
        Color.bright_green,
        size_str,
        Color.reset,
        Color.dim,
        display,
        Color.reset,
    });
}

/// Clears the delete progress line, resets the tick counter, and restores cursor visibility.
pub fn clearDeleteProgress(writer: anytype) !void {
    delete_tick = 0;
    try writer.print("\r" ++ " " ** 80 ++ "\r\x1b[?25h", .{});
    try writer.flush();
}

/// Renders a branded header enclosed in a rounded box:
///
/// ```
/// ╭──────────────────────╮
/// │  ◆ ev <cmd> <detail> │
/// ╰──────────────────────╯
/// ```
///
/// The detail text is truncated if it would overflow the box width.
pub fn printBrandedHeader(writer: anytype, command: []const u8, detail: []const u8, width: u16) !void {
    const w: usize = @intCast(@max(width, 30));
    const inner = w -| 2; // subtract left+right border chars

    try writer.writeAll("\n");

    // Top border:
    try writer.writeAll(Color.bright_cyan);
    try writer.writeAll(Box.top_left);
    try printRepeat(writer, Box.h_line, inner);
    try writer.writeAll(Box.top_right);
    try writer.writeAll(Color.reset);
    try writer.writeAll("\n");

    try writer.writeAll(Color.bright_cyan);
    try writer.writeAll(Box.v_line);
    try writer.writeAll(Color.reset);

    // Build the inner content: "  ◆ ev <command> <detail>"
    // ◆ occupies 1 visible column (3 bytes UTF-8)
    // "  ◆ ev " = 7 visible columns + command.len
    const prefix_visible = 7 + command.len; // "  ◆ ev " + command
    try writer.writeAll("  ");
    try writer.writeAll(Color.fg_gold);
    try writer.writeAll(Box.diamond);
    try writer.writeAll(Color.reset);
    try writer.writeAll(" ");
    try writer.writeAll(Color.bold);
    try writer.writeAll(Color.bright_white);
    try writer.writeAll("ev ");
    try writer.writeAll(command);
    try writer.writeAll(Color.reset);
    if (detail.len > 0) {
        // Truncate detail if it would overflow the box
        const max_detail_visible = if (inner > prefix_visible + 1) inner - prefix_visible - 1 else 0;
        const truncated = truncateUtf8(detail, max_detail_visible);
        if (truncated.len > 0) {
            try writer.writeAll(" ");
            try writer.writeAll(Color.fg_medium_gray);
            try writer.writeAll(truncated);
            try writer.writeAll(Color.reset);
        }
    }
    // Recalculate padding after potential truncation
    const actual_detail_vis = if (detail.len > 0) blk: {
        const max_dv = if (inner > prefix_visible + 1) inner - prefix_visible - 1 else 0;
        const trunc = truncateUtf8(detail, max_dv);
        break :blk if (trunc.len > 0) 1 + visibleLen(trunc) else 0;
    } else 0;
    const actual_content = prefix_visible + actual_detail_vis;
    const final_padding = if (inner > actual_content) inner - actual_content else 0;
    try printRepeat(writer, " ", final_padding);

    try writer.writeAll(Color.bright_cyan);
    try writer.writeAll(Box.v_line);
    try writer.writeAll(Color.reset);
    try writer.writeAll("\n");

    // Bottom border: ╰─────╯
    try writer.writeAll(Color.bright_cyan);
    try writer.writeAll(Box.bottom_left);
    try printRepeat(writer, Box.h_line, inner);
    try writer.writeAll(Box.bottom_right);
    try writer.writeAll(Color.reset);
    try writer.writeAll("\n");
}

/// Renders a section title with a leading tee connector and a trailing rule:
///
/// ```
///  ├─ Title ──────────────
/// ```
pub fn printSectionTitle(writer: anytype, title: []const u8, width: u16) !void {
    const w: usize = @intCast(width);

    try writer.writeAll("\n ");
    try writer.writeAll(Color.bright_cyan);
    try writer.writeAll(Box.t_right);
    try writer.writeAll(Box.h_line);
    try writer.writeAll(Color.reset);
    try writer.writeAll(" ");
    try writer.writeAll(Color.bold);
    try writer.writeAll(Color.bright_white);
    try writer.writeAll(title);
    try writer.writeAll(Color.reset);
    try writer.writeAll(" ");

    // Fill rest with ─ in cyan
    // Used columns: " ├─ " = 4 visible + title.len + " " = 5 + title.len
    const used: usize = 5 + title.len + 1;
    if (w > used) {
        try writer.writeAll(Color.bright_cyan);
        try printRepeat(writer, Box.h_line, w - used);
        try writer.writeAll(Color.reset);
    }
    try writer.writeAll("\n");
}

/// Prints a full-width horizontal rule of `─` characters followed by a newline.
fn printSeparator(writer: anytype, width: u16) !void {
    try printRepeat(writer, Box.h_line, @min(@as(usize, @intCast(width)), 256));
    try writer.writeAll("\n");
}

/// Prints a compact section header: " ⚙ CPU" (no trailing newline, no rule).
pub fn printGridSectionHeader(writer: anytype, icon: []const u8, icon_color: []const u8, title: []const u8) !void {
    try writer.writeAll(" ");
    try writer.writeAll(icon_color);
    try writer.writeAll(icon);
    try writer.writeAll(Color.reset);
    try writer.writeAll(" ");
    try writer.writeAll(Color.bold);
    try writer.writeAll(Color.bright_white);
    try writer.writeAll(title);
    try writer.writeAll(Color.reset);
}

/// Renders a bar where filled portion is auto-colored by usage % (green->red).
/// Empty portion in dark gray.
pub fn printColoredBar(writer: anytype, value: f64, max_val: f64, bar_w: u16) !void {
    const bw: u64 = @intCast(@min(bar_w, 60));
    const pct: f64 = if (max_val > 0) value * 100.0 / max_val else 0.0;
    const filled: usize = if (max_val > 0)
        @intFromFloat(@min(@as(f64, @floatFromInt(bw)) * value / max_val, @as(f64, @floatFromInt(bw))))
    else
        0;
    const empty: usize = @intCast(bw - @as(u64, @intCast(filled)));

    const color = usageColor(pct);
    try writer.writeAll(color);
    try printRepeat(writer, Box.block_full, filled);
    try writer.writeAll(Color.fg_dark_gray);
    try printRepeat(writer, Box.block_light, empty);
    try writer.writeAll(Color.reset);
}

/// Renders a usage-colored bar followed by right-aligned percentage.
/// Total visible width = bar_w + 5 chars ("  XX%"). No trailing newline.
pub fn printCompactBar(writer: anytype, pct: f64, bar_w: u16) !void {
    const bw: usize = @intCast(@min(bar_w, 60));
    const clamped = @max(@min(pct, 100.0), 0.0);
    const filled: usize = @intFromFloat(@as(f64, @floatFromInt(bw)) * clamped / 100.0);
    const empty: usize = bw - filled;

    const color = usageColor(clamped);
    try writer.writeAll(color);
    try printRepeat(writer, Box.block_full, filled);
    try writer.writeAll(Color.fg_dark_gray);
    try printRepeat(writer, Box.block_light, empty);
    try writer.writeAll(Color.reset);
    try writer.print(" {s}{d:>3.0}%{s}", .{ Color.bright_white, clamped, Color.reset });
}

/// Renders a bar with explicit color + bullet prefix.
pub fn printCategoryBar(writer: anytype, label: []const u8, color: []const u8, value: u64, total_value: u64, bar_width: u16) !void {
    const effective_bw: u64 = @intCast(@min(bar_width, 60));

    const filled_count: usize = if (total_value > 0)
        @intCast(@min(effective_bw * value / total_value, effective_bw))
    else
        0;
    const empty_count: usize = @intCast(effective_bw - @as(u64, @intCast(filled_count)));
    const pct: f64 = if (total_value > 0)
        @as(f64, @floatFromInt(value)) * 100.0 / @as(f64, @floatFromInt(total_value))
    else
        0.0;

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, value);

    // ● Label
    try writer.writeAll(" ");
    try writer.writeAll(color);
    try writer.writeAll(Box.bullet);
    try writer.writeAll(Color.reset);
    try writer.print(" {s:<9} ", .{label});

    // Colored filled portion
    try writer.writeAll(color);
    try printRepeat(writer, Box.block_full, filled_count);
    // Dark gray empty portion
    try writer.writeAll(Color.fg_dark_gray);
    try printRepeat(writer, Box.block_light, empty_count);
    try writer.writeAll(Color.reset);

    try writer.print("  {s:>10}  ({d:>3.0}%)\n", .{ size_str, pct });
}

/// Renders a list of category bars for each non-zero category in `sizes`.
pub fn printCategoryBreakdown(writer: anytype, sizes: CategorySizes, width: u16) !void {
    const tot = sizes.total();
    if (tot == 0) return;

    const bar_width: u16 = @min(if (width > 40) width - 30 else 20, 15);

    const categories = [_]rules.Category{ .dev, .system, .package, .ai, .browser };
    for (&categories) |cat| {
        const s = sizes.get(cat);
        if (s > 0) {
            try printCategoryBar(writer, cat.label(), categoryColor(cat), s, tot, bar_width);
        }
    }
}

/// prints the scanner table header with column labels and a separator line.
pub fn printHeader(writer: anytype, width: u16) !void {
    try writer.print("\n{s}{s} evi scanner{s}\n\n", .{ Color.bold, Color.cyan, Color.reset });
    try writer.print("{s}{s:<10} {s:<10} {s:<10} {s}{s}\n", .{
        Color.dim,
        "Category",
        "Risk",
        "Size",
        "Path",
        Color.reset,
    });
    try writer.print("{s}", .{Color.dim});
    try printSeparator(writer, width);
    try writer.print("{s}", .{Color.reset});
}

/// prints a single scan result row: category, risk level, size, and path.
/// The path is tail-truncated to fit within the terminal width.
pub fn printResult(writer: anytype, width: u16, category: rules.Category, risk: rules.Risk, size: u64, path: []const u8) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, size);

    const fixed_cols: usize = 32;
    const w: usize = @intCast(width);
    const max_path_len: usize = if (w > fixed_cols) w - fixed_cols else 20;
    const display_path = if (path.len > max_path_len) path[path.len - max_path_len ..] else path;

    try writer.print("{s}{s:<10}{s} {s}{s:<10}{s} {s:<10} {s}\n", .{
        categoryColor(category),
        category.label(),
        Color.reset,
        riskColor(risk),
        risk.label(),
        Color.reset,
        size_str,
        display_path,
    });
}

/// prints a footer with item count and total reclaimable size after a scan.
pub fn printTotal(writer: anytype, width: u16, count: usize, total_size: u64) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, total_size);

    try writer.print("\n{s}", .{Color.dim});
    try printSeparator(writer, width);
    try writer.print("{s}", .{Color.reset});
    try writer.print("{s}{s}Found {d} items, {s} reclaimable{s}\n\n", .{
        Color.bold,
        Color.green,
        count,
        size_str,
        Color.reset,
    });
}

/// prints a "Would delete" line for dry-run mode with category, size, and path.
pub fn printDryRunResult(writer: anytype, category: rules.Category, size: u64, path: []const u8) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, size);

    try writer.print("  {s}Would delete:{s} {s}{s:<10}{s} {s:<10} {s}\n", .{
        Color.dim,
        Color.reset,
        categoryColor(category),
        category.label(),
        Color.reset,
        size_str,
        path,
    });
}

/// prints a post-cleanup summary with counts of deleted, skipped, and failed items.
pub fn printCleanSummary(writer: anytype, width: u16, deleted: usize, deleted_size: u64, skipped: usize, errors: usize) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, deleted_size);

    try writer.print("\n{s}", .{Color.dim});
    try printSeparator(writer, width);
    try writer.print("{s}", .{Color.reset});
    try writer.print("{s}{s}Deleted {d} items, {s} freed{s}\n", .{
        Color.bold,
        Color.green,
        deleted,
        size_str,
        Color.reset,
    });
    if (skipped > 0) {
        try writer.print("{s}Skipped {d} whitelisted items{s}\n", .{ Color.yellow, skipped, Color.reset });
    }
    if (errors > 0) {
        try writer.print("{s}Failed to delete {d} items{s}\n", .{ Color.red, errors, Color.reset });
    }
    try writer.print("\n", .{});
}

test "formatSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try std.testing.expectEqualStrings("1023 B", formatSize(&buf, 1023));

    const kb = formatSize(&buf, 1024);
    try std.testing.expect(std.mem.startsWith(u8, kb, "1"));

    const gb = formatSize(&buf, 1024 * 1024 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, gb, "1"));
}

test "getTerminalWidth fallback" {
    const w = getTerminalWidth();
    try std.testing.expect(w >= 20 and w <= 500);
}

test "CategorySizes tracking" {
    var sizes: CategorySizes = .{};
    sizes.add(.dev, 100);
    sizes.add(.dev, 200);
    sizes.add(.system, 50);
    try std.testing.expectEqual(@as(u64, 300), sizes.get(.dev));
    try std.testing.expectEqual(@as(u64, 50), sizes.get(.system));
    try std.testing.expectEqual(@as(u64, 350), sizes.total());
}

test "usageColor thresholds" {
    try std.testing.expectEqualStrings(Color.fg_green_256, usageColor(0.0));
    try std.testing.expectEqualStrings(Color.fg_green_256, usageColor(49.9));
    try std.testing.expectEqualStrings(Color.fg_lime_256, usageColor(50.0));
    try std.testing.expectEqualStrings(Color.fg_orange_256, usageColor(70.0));
    try std.testing.expectEqualStrings(Color.fg_red_256, usageColor(85.0));
    try std.testing.expectEqualStrings(Color.fg_red_256, usageColor(100.0));
}

test "fmtShortUptime" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("?", fmtShortUptime(&buf, 0));
    try std.testing.expectEqualStrings("14h", fmtShortUptime(&buf, 14 * 3600 + 1800));
    try std.testing.expectEqualStrings("2d", fmtShortUptime(&buf, 2 * 86400 + 3600));
    try std.testing.expectEqualStrings("42m", fmtShortUptime(&buf, 42 * 60));
}

test "fmtShortCpuModel" {
    try std.testing.expectEqualStrings("i5-11300H", fmtShortCpuModel("11th Gen Intel(R) Core(TM) i5-11300H @ 3.10GHz"));
    const ryzen = fmtShortCpuModel("AMD Ryzen 7 5800X 8-Core");
    try std.testing.expect(std.mem.startsWith(u8, ryzen, "Ryzen"));
}

test "sizeColor thresholds" {
    try std.testing.expectEqualStrings(Color.fg_medium_gray, sizeColor(0));
    try std.testing.expectEqualStrings(Color.fg_medium_gray, sizeColor(50 * 1024 * 1024)); // 50MB
    try std.testing.expectEqualStrings(Color.bright_white, sizeColor(500 * 1024 * 1024)); // 500MB
    try std.testing.expectEqualStrings(Color.bright_yellow, sizeColor(5 * 1024 * 1024 * 1024)); // 5GB
    try std.testing.expectEqualStrings(Color.bright_red, sizeColor(20 * @as(u64, 1024 * 1024 * 1024))); // 20GB
}
