const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const scanner = @import("scanner.zig");
const rules_mod = @import("rules.zig");
const platform = @import("platform.zig");
const ui = @import("ui.zig");
const evi_progress = @import("progress.zig");
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
    /// Sum of ALL scanned entries, not just the displayed top N.
    scanned_total: u64,
    /// Number of scanned entries with size > 0.
    entry_count: usize,
    /// Usage of the filesystem containing the analyzed path, when available.
    disk: ?platform.impl.DiskUsage,
    /// Directories the walk could not open (permissions). A large number
    /// usually means running without root misses part of the disk.
    denied_count: usize,
};

const DirSizeEntry = struct {
    path: []const u8,
    size: u64,
    is_dir: bool,
};

/// Work-stealing state for sizing top-level entries. Entries are claimed via
/// the atomic index; each entry is written by exactly one worker, and every
/// worker accumulates category sizes into its own `CategorySizes` (merged
/// after join), so there is no shared mutable state to lock.
const DirSizeState = struct {
    io: Io,
    entries: []DirSizeEntry,
    lookup: *const scanner.RuleLookup,
    prefixes: *const scanner.PrefixLookup,
    next_idx: std.atomic.Value(usize) = .init(0),
    tracker: ?*evi_progress.Tracker = null,
};

fn sizeEntry(state: *DirSizeState, entry: *DirSizeEntry, categories: *ui.CategorySizes, slot: usize) void {
    if (state.tracker) |t| t.setPath(slot, entry.path);
    if (entry.is_dir) {
        const base = std.fs.path.basename(entry.path);
        const dir_rule: ?*const rules_mod.Rule = state.lookup.dir_names.get(base);
        const prefix_rule: ?*const rules_mod.Rule = state.prefixes.get(entry.path);
        entry.size = scanner.sizedWalk(state.io, entry.path, state.lookup, state.prefixes, categories, state.tracker, slot, 0, dir_rule != null);
        if (dir_rule) |r| categories.add(r.category, entry.size);
        if (prefix_rule) |r| categories.add(r.category, entry.size);
    }
    if (state.tracker) |t| t.addDone();
}

fn dirSizeWorker(state: *DirSizeState, categories: *ui.CategorySizes, slot: usize) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .monotonic);
        if (idx >= state.entries.len) return;
        sizeEntry(state, &state.entries[idx], categories, slot);
    }
}

/// Analyze disk usage under root_path.
/// Returns top N largest children and a per-category size breakdown.
/// One traversal computes both: sizes are summed while rule matches are
/// attributed to categories on the way down.
pub fn analyze(allocator: Allocator, io: Io, root_path: []const u8, options: AnalyzeOptions) !AnalysisReport {
    var category_sizes: ui.CategorySizes = .{};

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

    const lookup = try scanner.RuleLookup.initFromRules(allocator, &rules_mod.all_rules);
    var prefixes = try scanner.buildPrefixLookup(allocator, options.home);
    defer prefixes.deinit(allocator);

    var tracker: evi_progress.Tracker = .{ .total = entries.items.len };
    var ticker: ?evi_progress.Ticker = null;
    if (options.progress_writer) |pw| {
        ticker = evi_progress.Ticker.init(io, pw, &tracker, "Analyzing", "entries");
        ticker.?.begin();
    }
    defer if (ticker) |*t| t.end();

    if (entries.items.len > 0) {
        const n_cpus = std.Thread.getCpuCount() catch 1;
        const n_workers = @min(n_cpus, @min(entries.items.len, 8));

        var state: DirSizeState = .{
            .io = io,
            .entries = entries.items,
            .lookup = &lookup,
            .prefixes = &prefixes,
            .tracker = &tracker,
        };

        if (n_workers > 1) {
            const n_spawned = n_workers - 1;
            const threads = try allocator.alloc(std.Thread, n_spawned);
            const worker_cats = try allocator.alloc(ui.CategorySizes, n_workers);
            for (worker_cats) |*c| c.* = .{};

            var spawned_count: usize = 0;
            for (0..n_spawned) |i| {
                threads[spawned_count] = std.Thread.spawn(.{}, dirSizeWorker, .{ &state, &worker_cats[i + 1], i + 1 }) catch break;
                spawned_count += 1;
            }

            dirSizeWorker(&state, &worker_cats[0], 0);

            for (threads[0..spawned_count]) |thread| {
                thread.join();
            }

            for (worker_cats) |c| {
                inline for (@typeInfo(rules_mod.Category).@"enum".fields) |field| {
                    const cat: rules_mod.Category = @enumFromInt(field.value);
                    category_sizes.add(cat, c.get(cat));
                }
            }
        } else {
            for (entries.items) |*entry| {
                sizeEntry(&state, entry, &category_sizes, 0);
            }
        }
    }

    var top_dirs: std.ArrayList(AnalyzeResult) = .empty;
    var scanned_total: u64 = 0;
    for (entries.items) |entry| {
        if (entry.size > 0) {
            scanned_total += entry.size;
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
        .scanned_total = scanned_total,
        .entry_count = top_dirs.items.len,
        .disk = platform.impl.diskUsage(allocator, io, root_path),
        .denied_count = tracker.dirs_denied.load(.monotonic),
    };
}

pub fn printReport(writer: anytype, root_path: []const u8, report: AnalysisReport, raw_width: u16) !void {
    const width = @min(raw_width, 80);
    const total_size = report.scanned_total;
    var detail_buf: [256]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const total_str = ui.formatSize(&total_buf, total_size);
    const detail = std.fmt.bufPrint(&detail_buf, "{s} \xc2\xb7 {s}", .{ root_path, total_str }) catch root_path;

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

        const display_path = blk: {
            if (std.mem.startsWith(u8, item.path, root_path) and item.path.len > root_path.len) {
                var rest = item.path[root_path.len..];
                while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
                if (rest.len > 0) break :blk rest;
            }
            break :blk item.path;
        };

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
    try writer.print(" Scanned: {s}{s}{s} across {s}{d}{s} entries (top {d} shown)", .{
        ui.Color.bright_white, total_str,          ui.Color.reset,
        ui.Color.bright_white, report.entry_count, ui.Color.reset,
        report.top_dirs.len,
    });
    if (report.denied_count > 0) {
        try writer.print(" {s}\xc2\xb7 {d} dirs inaccessible{s}", .{
            ui.Color.yellow, report.denied_count, ui.Color.reset,
        });
    }
    try writer.writeAll("\n");

    if (report.disk) |disk| {
        var used_buf: [32]u8 = undefined;
        var disk_total_buf: [32]u8 = undefined;
        var free_buf: [32]u8 = undefined;
        const disk_pct: f64 = if (disk.total > 0)
            @as(f64, @floatFromInt(disk.used)) * 100.0 / @as(f64, @floatFromInt(disk.total))
        else
            0.0;
        try writer.writeAll(" ");
        try writer.writeAll(ui.Color.fg_medium_gray);
        try writer.writeAll(ui.Box.h_line);
        try writer.writeAll(ui.Color.reset);
        try writer.print(" Disk: {s}{s}{s} / {s} used ({s}{d:.0}%{s}) \xc2\xb7 {s}{s}{s} free\n", .{
            ui.usageColor(disk_pct),
            ui.formatSize(&used_buf, disk.used),
            ui.Color.reset,
            ui.formatSize(&disk_total_buf, disk.total),
            ui.Color.bright_white,
            disk_pct,
            ui.Color.reset,
            ui.Color.bright_green,
            ui.formatSize(&free_buf, disk.available),
            ui.Color.reset,
        });

        // Surface the difference between what the walk saw and what the
        // filesystem reports: inaccessible dirs, other mounts/subvolumes,
        // btrfs snapshots. Only when the gap is meaningful (>5% of used).
        if (disk.used > total_size) {
            const gap = disk.used - total_size;
            if (gap > disk.used / 20) {
                var gap_buf: [32]u8 = undefined;
                try writer.writeAll(" ");
                try writer.writeAll(ui.Color.fg_medium_gray);
                try writer.writeAll(ui.Box.h_line);
                try writer.writeAll(ui.Color.reset);
                try writer.print(" Not scanned: {s}{s}{s} (outside this path, inaccessible dirs, or snapshots)\n", .{
                    ui.Color.yellow,
                    ui.formatSize(&gap_buf, gap),
                    ui.Color.reset,
                });
            }
        }
    }
    try writer.writeAll("\n");
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
