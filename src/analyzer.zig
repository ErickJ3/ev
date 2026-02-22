const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const scanner = @import("scanner.zig");
const rules_mod = @import("rules.zig");
const platform = @import("platform.zig");
const ui = @import("ui.zig");
const Allocator = std.mem.Allocator;

pub const AnalyzeResult = struct {
    path: []const u8,
    size: u64,
    is_dir: bool,
};

pub const AnalyzeOptions = struct {
    max_depth: u32 = 3,
    top_n: usize = 15,
    home: []const u8 = "/tmp",
    progress_writer: ?*Io.Writer = null,
};

pub const AnalysisReport = struct {
    top_dirs: []const AnalyzeResult,
    category_sizes: ui.CategorySizes,
};

const DirSizeEntry = struct {
    path: []const u8,
    size: u64,
    is_dir: bool,
};

const DirSizeState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    io: Io,
    entries: []DirSizeEntry,
    next_idx: std.atomic.Value(usize) = .init(0),
    progress_count: std.atomic.Value(usize) = .init(0),

    fn lock(self: *DirSizeState) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *DirSizeState) void {
        self.mutex.unlock();
    }
};

fn dirSizeWorker(state: *DirSizeState) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .monotonic);
        if (idx >= state.entries.len) return;

        const entry = &state.entries[idx];
        if (entry.is_dir) {
            entry.size = scanner.dirSize(state.io, entry.path) catch 0;
        }
        _ = state.progress_count.fetchAdd(1, .monotonic);
    }
}

/// Analyze disk usage under root_path.
/// Returns top N largest children and a per-category size breakdown.
pub fn analyze(allocator: Allocator, io: Io, root_path: []const u8, options: AnalyzeOptions) !AnalysisReport {
    var category_sizes: ui.CategorySizes = .{};
    var scan_results = scanner.scan(allocator, io, root_path, .{
        .home = options.home,
        .max_depth = options.max_depth,
    }) catch scanner.ResultList.empty;

    for (scan_results.items) |result| {
        category_sizes.add(result.rule.category, result.size);
    }

    var entries: std.ArrayList(DirSizeEntry) = .empty;

    {
        var dir = try Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .sym_link) continue;

            const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });

            if (entry.kind == .directory) {
                if (platform.impl.isSkipDir(full_path)) continue;
                try entries.append(allocator, .{ .path = full_path, .size = 0, .is_dir = true });
            } else if (entry.kind == .file) {
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                if (stat.size > 0) {
                    try entries.append(allocator, .{ .path = full_path, .size = stat.size, .is_dir = false });
                }
            }
        }
    }

    if (entries.items.len > 0) {
        const n_cpus = std.Thread.getCpuCount() catch 1;
        const n_workers = @min(n_cpus, @min(entries.items.len, 8));

        var state: DirSizeState = .{
            .io = io,
            .entries = entries.items,
        };

        if (n_workers > 1) {
            const n_spawned = n_workers - 1;
            const threads = try allocator.alloc(std.Thread, n_spawned);
            var spawned_count: usize = 0;
            for (0..n_spawned) |_| {
                threads[spawned_count] = std.Thread.spawn(.{}, dirSizeWorker, .{&state}) catch break;
                spawned_count += 1;
            }

            while (true) {
                const idx = state.next_idx.fetchAdd(1, .monotonic);
                if (idx >= state.entries.len) break;

                if (options.progress_writer) |pw| {
                    const done = state.progress_count.load(.monotonic);
                    ui.printProgress(pw, done, state.entries[idx].path) catch {};
                }

                const entry = &state.entries[idx];
                if (entry.is_dir) {
                    entry.size = scanner.dirSize(io, entry.path) catch 0;
                }
                _ = state.progress_count.fetchAdd(1, .monotonic);
            }

            for (threads[0..spawned_count]) |thread| {
                thread.join();
            }
        } else {
            for (entries.items, 0..) |*entry, i| {
                if (options.progress_writer) |pw| {
                    ui.printProgress(pw, i, entry.path) catch {};
                }
                if (entry.is_dir) {
                    entry.size = scanner.dirSize(io, entry.path) catch 0;
                }
            }
        }
    }

    if (options.progress_writer) |pw| {
        try ui.clearProgress(pw);
    }

    var top_dirs: std.ArrayList(AnalyzeResult) = .empty;
    for (entries.items) |entry| {
        if (entry.size > 0) {
            try top_dirs.append(allocator, .{
                .path = entry.path,
                .size = entry.size,
                .is_dir = entry.is_dir,
            });
        }
    }

    std.mem.sort(AnalyzeResult, top_dirs.items, {}, struct {
        fn lessThan(_: void, a: AnalyzeResult, b: AnalyzeResult) bool {
            return a.size > b.size;
        }
    }.lessThan);

    const count = @min(top_dirs.items.len, options.top_n);

    return .{
        .top_dirs = top_dirs.items[0..count],
        .category_sizes = category_sizes,
    };
}

pub fn printReport(writer: anytype, root_path: []const u8, report: AnalysisReport, raw_width: u16) !void {
    const width = @min(raw_width, 80);
    var total_size: u64 = 0;
    for (report.top_dirs) |item| {
        total_size += item.size;
    }
    var detail_buf: [256]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const total_str = ui.formatSize(&total_buf, total_size);
    const detail = std.fmt.bufPrint(&detail_buf, "{s} \xc2\xb7 Total: {s}", .{ root_path, total_str }) catch root_path;

    try ui.printBrandedHeader(writer, "analyze", detail, width);

    if (report.top_dirs.len == 0) {
        try writer.print("\n  No items found.\n\n", .{});
        return;
    }

    const max_size = report.top_dirs[0].size;
    const bar_w: u16 = if (width > 60) @min(width -| 47, 20) else 12;

    try ui.printSectionTitle(writer, "Top directories", width);
    try writer.writeAll("\n");

    for (report.top_dirs, 0..) |item, i| {
        var size_buf: [32]u8 = undefined;
        const size_str = ui.formatSize(&size_buf, item.size);

        const pct: f64 = if (total_size > 0)
            @as(f64, @floatFromInt(item.size)) * 100.0 / @as(f64, @floatFromInt(total_size))
        else
            0.0;

        if (i < 3) {
            const medal_color = switch (i) {
                0 => ui.Color.fg_gold_medal,
                1 => ui.Color.fg_silver_medal,
                2 => ui.Color.fg_bronze_medal,
                else => unreachable,
            };
            try writer.print(" {s}" ++ ui.Box.arrow_right ++ "{s}", .{ medal_color, ui.Color.reset });
        } else {
            try writer.writeAll("  ");
        }

        const bar_color = if (pct > 30.0)
            ui.Color.fg_red_256
        else if (pct > 15.0)
            ui.Color.fg_orange_256
        else if (pct > 5.0)
            ui.Color.fg_lime_256
        else
            ui.Color.fg_green_256;

        try writer.print("{d:>2}. ", .{i + 1});

        const effective_bw: u64 = @intCast(@min(bar_w, 30));
        const filled: usize = if (max_size > 0)
            @intCast(@min(effective_bw * item.size / max_size, effective_bw))
        else
            0;
        const empty: usize = @intCast(effective_bw - @as(u64, @intCast(filled)));

        try writer.writeAll(bar_color);
        try ui.printRepeat(writer, ui.Box.block_full, filled);
        try writer.writeAll(ui.Color.fg_dark_gray);
        try ui.printRepeat(writer, ui.Box.block_light, empty);
        try writer.writeAll(ui.Color.reset);
        try writer.print(" {s}{d:>5.1}%{s}", .{ ui.Color.bright_white, pct, ui.Color.reset });
        try writer.print("  {s}" ++ ui.Box.v_line ++ "{s}  ", .{ ui.Color.fg_dark_gray, ui.Color.reset });

        const display_path = if (std.mem.startsWith(u8, item.path, root_path) and item.path.len > root_path.len + 1)
            item.path[root_path.len + 1 ..]
        else
            item.path;

        const max_name: usize = 20;
        const name = if (display_path.len > max_name) display_path[0..max_name] else display_path;
        const sc = ui.sizeColor(item.size);
        try writer.print("{s:<20} {s}{s:>10}{s}\n", .{
            name,
            sc,
            size_str,
            ui.Color.reset,
        });
    }

    if (report.category_sizes.total() > 0) {
        try ui.printSectionTitle(writer, "Category breakdown", width);
        try writer.writeAll("\n");
        try ui.printCategoryBreakdown(writer, report.category_sizes, width);
    }

    try writer.writeAll("\n ");
    try writer.writeAll(ui.Color.fg_medium_gray);
    try writer.writeAll(ui.Box.h_line);
    try writer.writeAll(ui.Color.reset);
    try writer.print(" Total: {s}{s}{s} across {s}{d}{s} entries\n\n", .{
        ui.Color.bright_white, total_str,           ui.Color.reset,
        ui.Color.bright_white, report.top_dirs.len, ui.Color.reset,
    });
}

test "AnalyzeResult sorting" {
    const items = [_]AnalyzeResult{
        .{ .path = "/a", .size = 100, .is_dir = true },
        .{ .path = "/b", .size = 300, .is_dir = true },
        .{ .path = "/c", .size = 200, .is_dir = true },
    };
    var list = items;
    std.mem.sort(AnalyzeResult, &list, {}, struct {
        fn lessThan(_: void, a: AnalyzeResult, b: AnalyzeResult) bool {
            return a.size > b.size;
        }
    }.lessThan);
    try std.testing.expectEqual(@as(u64, 300), list[0].size);
    try std.testing.expectEqual(@as(u64, 200), list[1].size);
    try std.testing.expectEqual(@as(u64, 100), list[2].size);
}

test "CategorySizes accumulation" {
    var sizes: ui.CategorySizes = .{};
    sizes.add(.dev, 1000);
    sizes.add(.dev, 2000);
    sizes.add(.system, 500);
    sizes.add(.package, 300);
    try std.testing.expectEqual(@as(u64, 3000), sizes.get(.dev));
    try std.testing.expectEqual(@as(u64, 500), sizes.get(.system));
    try std.testing.expectEqual(@as(u64, 3800), sizes.total());
}
