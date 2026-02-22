const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("platform.zig");
const ui = @import("ui.zig");

const GridLayout = struct {
    right_col: u16, // cursor position for column 2 (1-based)
    col_width: u16, // usable width per column
    bar_w: u16, // bar width that fits in a column
    is_wide: bool, // true if width >= 80

    fn init(width: u16) GridLayout {
        if (width >= 80) {
            const half = width / 2;
            return .{
                .right_col = half + 1,
                .col_width = half -| 2,
                .bar_w = @min(if (half > 22) half - 22 else 8, 20),
                .is_wide = true,
            };
        }
        return .{
            .right_col = 0,
            .col_width = width -| 2,
            .bar_w = @min(if (width > 40) width - 40 else 20, 20),
            .is_wide = false,
        };
    }
};

pub fn printDashboard(allocator: Allocator, io: Io, writer: anytype, width: u16) !void {
    const info = try platform.impl.getSystemInfo(allocator, io);
    const w = @min(width, 80);
    const grid = GridLayout.init(w);
    var detail_buf: [256]u8 = undefined;
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const detail = buildHeaderDetail(&detail_buf, &buf_a, info);

    try ui.printBrandedHeader(writer, "status", detail, w);

    if (grid.is_wide) {
        try printDashboardWide(writer, info, grid, &buf_a, &buf_b);
    } else {
        try printDashboardNarrow(writer, info, w, &buf_a, &buf_b);
    }

    try writer.writeAll("\n");
}

fn buildHeaderDetail(buf: []u8, uptime_buf: []u8, info: anytype) []const u8 {
    var ram_buf: [32]u8 = undefined;
    const ram_str = ui.formatSize(&ram_buf, info.mem_total);
    const up = ui.fmtShortUptime(uptime_buf, info.uptime_seconds);
    const cpu_short = ui.fmtShortCpuModel(info.cpu_model);

    if (info.cpu_cores > 0) {
        return std.fmt.bufPrint(buf, "{s} \xc2\xb7 {s} \xc2\xb7 {d} cores \xc2\xb7 {s} \xc2\xb7 {s} up", .{
            info.os_version, cpu_short, info.cpu_cores, ram_str, up,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s} \xc2\xb7 {s} \xc2\xb7 {s} \xc2\xb7 {s} up", .{
        info.os_version, cpu_short, ram_str, up,
    }) catch "";
}

fn printDashboardWide(writer: anytype, info: anytype, grid: GridLayout, buf1: *[32]u8, buf2: *[32]u8) !void {
    // CPU | Memory
    try writer.writeAll("\n");
    try ui.printGridSectionHeader(writer, ui.Box.gear, ui.Color.bright_cyan, "CPU");
    try ui.cursorTo(writer, grid.right_col);
    try ui.printGridSectionHeader(writer, ui.Box.grid, ui.Color.bright_yellow, "Memory");
    try writer.writeAll("\n");

    // CPU usage bar | RAM bar
    const mem_used = info.mem_total -| info.mem_available;
    const mem_pct: f64 = if (info.mem_total > 0)
        @as(f64, @floatFromInt(mem_used)) * 100.0 / @as(f64, @floatFromInt(info.mem_total))
    else
        0.0;

    try writer.print(" {s}Usage{s}  ", .{ ui.Color.fg_medium_gray, ui.Color.reset });
    try ui.printCompactBar(writer, info.cpu_usage_percent, grid.bar_w);
    try ui.cursorTo(writer, grid.right_col);
    try writer.print(" {s}RAM{s}   ", .{ ui.Color.fg_medium_gray, ui.Color.reset });
    try ui.printCompactBar(writer, mem_pct, grid.bar_w);
    try writer.writeAll("\n");

    // Load averages | RAM sizes
    const cores_f: f64 = if (info.cpu_cores > 0) @floatFromInt(info.cpu_cores) else 1.0;
    try writer.print(" {s}Load{s}   ", .{ ui.Color.fg_medium_gray, ui.Color.reset });
    inline for (0..3) |li| {
        const ratio = info.load_avg[li] / cores_f;
        const lcolor = if (ratio < 0.7) ui.Color.bright_green else if (ratio < 1.0) ui.Color.bright_yellow else ui.Color.bright_red;
        if (li > 0) try writer.writeAll("  ");
        try writer.print("{s}{d:.2}{s}", .{ lcolor, info.load_avg[li], ui.Color.reset });
    }
    try writer.print("  {s}({d} cores){s}", .{ ui.Color.fg_medium_gray, info.cpu_cores, ui.Color.reset });
    try ui.cursorTo(writer, grid.right_col);
    try writer.print(" {s}{s}{s} / {s}{s}{s}", .{
        ui.Color.bright_white,   ui.formatSize(buf1, mem_used),       ui.Color.reset,
        ui.Color.fg_medium_gray, ui.formatSize(buf2, info.mem_total), ui.Color.reset,
    });
    try writer.writeAll("\n");

    // CPU model | Swap bar (or blank)
    try writer.print(" {s}{s}{s}", .{ ui.Color.fg_medium_gray, ui.fmtShortCpuModel(info.cpu_model), ui.Color.reset });
    if (info.swap_total > 0) {
        const swap_used = info.swap_total -| info.swap_free;
        const swap_pct: f64 = @as(f64, @floatFromInt(swap_used)) * 100.0 / @as(f64, @floatFromInt(info.swap_total));
        try ui.cursorTo(writer, grid.right_col);
        try writer.print(" {s}Swap{s}  ", .{ ui.Color.fg_medium_gray, ui.Color.reset });
        try ui.printCompactBar(writer, swap_pct, grid.bar_w);
    }
    try writer.writeAll("\n");

    // blank left | Swap sizes
    if (info.swap_total > 0) {
        const swap_used = info.swap_total -| info.swap_free;
        try ui.cursorTo(writer, grid.right_col);
        try writer.print(" {s}{s}{s} / {s}{s}{s}", .{
            ui.Color.bright_white,   ui.formatSize(buf1, swap_used),       ui.Color.reset,
            ui.Color.fg_medium_gray, ui.formatSize(buf2, info.swap_total), ui.Color.reset,
        });
        try writer.writeAll("\n");
    }

    // Disk | Network section headers
    // Count real filesystems
    var real_fs: [16]usize = undefined;
    var real_fs_count: usize = 0;
    for (info.filesystems, 0..) |fs, idx| {
        if (!isVirtualMount(fs.mount_point, fs.total)) {
            if (real_fs_count < 16) {
                real_fs[real_fs_count] = idx;
                real_fs_count += 1;
            }
        }
    }

    const has_disk = real_fs_count > 0;
    const has_net = info.interfaces.len > 0;

    if (has_disk or has_net) {
        try writer.writeAll("\n");
        if (has_disk) {
            try ui.printGridSectionHeader(writer, ui.Box.bars, ui.Color.bright_green, "Disk");
        }
        if (has_net) {
            try ui.cursorTo(writer, grid.right_col);
            try ui.printGridSectionHeader(writer, ui.Box.arrows_ud, ui.Color.magenta, "Network");
        }
        try writer.writeAll("\n");

        const max_rows = @max(real_fs_count, info.interfaces.len);
        for (0..max_rows) |row| {
            if (row < real_fs_count) {
                const fs = info.filesystems[real_fs[row]];
                const pct: f64 = if (fs.total > 0)
                    @as(f64, @floatFromInt(fs.used)) * 100.0 / @as(f64, @floatFromInt(fs.total))
                else
                    0.0;
                const mp = truncStr(fs.mount_point, 7);
                try writer.print(" {s:<7}  ", .{mp});
                try ui.printCompactBar(writer, pct, grid.bar_w);
            }
            if (row < info.interfaces.len) {
                const iface = info.interfaces[row];
                try ui.cursorTo(writer, grid.right_col);
                const iname = truncStr(iface.iface_name, 10);
                try writer.print(" {s:<10} ", .{iname});
                try writer.print("{s}" ++ ui.Box.arrow_down ++ "{s} {s:<10}", .{
                    ui.Color.bright_green,               ui.Color.reset,
                    ui.formatSize(buf1, iface.rx_bytes),
                });
                try writer.print(" {s}" ++ ui.Box.arrow_up ++ "{s} {s}", .{
                    ui.Color.bright_cyan,                ui.Color.reset,
                    ui.formatSize(buf2, iface.tx_bytes),
                });
            }
            try writer.writeAll("\n");
        }
    }

    // Processes | System section headers
    const has_proc = info.top_processes.len > 0;
    const has_sys = info.service_count > 0 or info.package_count > 0;

    if (has_proc or has_sys) {
        try writer.writeAll("\n");
        if (has_proc) {
            try ui.printGridSectionHeader(writer, ui.Box.arrow_right, ui.Color.fg_gold, "Processes");
        }
        if (has_sys) {
            try ui.cursorTo(writer, grid.right_col);
            try ui.printGridSectionHeader(writer, ui.Box.gear, ui.Color.bright_cyan, "System");
        }
        try writer.writeAll("\n");

        const proc_count = @min(info.top_processes.len, 5);
        const sys_rows: usize = (if (info.service_count > 0) @as(usize, 1) else 0) +
            (if (info.package_count > 0) @as(usize, 1) else 0);
        const max_ps_rows = @max(proc_count, sys_rows);

        for (0..max_ps_rows) |row| {
            if (row < proc_count) {
                const proc = info.top_processes[row];
                const name = truncStr(proc.proc_name, 18);
                try writer.print(" {s:<18} {s}{s:>10}{s}", .{
                    name,
                    ui.sizeColor(proc.mem_rss),
                    ui.formatSize(buf1, proc.mem_rss),
                    ui.Color.reset,
                });
            }
            if (row < sys_rows) {
                try ui.cursorTo(writer, grid.right_col);
                if (row == 0 and info.service_count > 0) {
                    try writer.print(" {s}{d}{s} services {s}({s}){s}", .{
                        ui.Color.bright_white,   info.service_count,   ui.Color.reset,
                        ui.Color.fg_medium_gray, info.service_manager, ui.Color.reset,
                    });
                } else {
                    try writer.print(" {s}{d}{s} packages {s}({s}){s}", .{
                        ui.Color.bright_white,   info.package_count,   ui.Color.reset,
                        ui.Color.fg_medium_gray, info.package_manager, ui.Color.reset,
                    });
                }
            }
            try writer.writeAll("\n");
        }
    }
}

fn printDashboardNarrow(writer: anytype, info: anytype, width: u16, buf1: *[32]u8, buf2: *[32]u8) !void {
    const bw = barWidthNarrow(width);

    try ui.printSectionTitle(writer, "CPU", width);
    try writer.print(" {s}Model:{s}   {s}{s}{s}", .{
        ui.Color.fg_medium_gray, ui.Color.reset,
        ui.Color.bright_white,   info.cpu_model,
        ui.Color.reset,
    });
    if (info.cpu_cores > 0) {
        try writer.print(" {s}({d} cores){s}", .{ ui.Color.fg_medium_gray, info.cpu_cores, ui.Color.reset });
    }
    try writer.writeAll("\n");
    try writer.print(" {s}Usage:{s}   {s}{d:.1}%{s}  ", .{
        ui.Color.fg_medium_gray, ui.Color.reset,
        ui.Color.bright_white,   info.cpu_usage_percent,
        ui.Color.reset,
    });
    try ui.printColoredBar(writer, info.cpu_usage_percent, 100.0, bw);
    try writer.writeAll("\n");

    const cores_f: f64 = if (info.cpu_cores > 0) @floatFromInt(info.cpu_cores) else 1.0;
    try writer.print(" {s}Load:{s}    ", .{ ui.Color.fg_medium_gray, ui.Color.reset });
    inline for (0..3) |li| {
        const ratio = info.load_avg[li] / cores_f;
        const lcolor = if (ratio < 0.7) ui.Color.bright_green else if (ratio < 1.0) ui.Color.bright_yellow else ui.Color.bright_red;
        if (li > 0) try writer.writeAll("  ");
        try writer.print("{s}{d:.2}{s}", .{ lcolor, info.load_avg[li], ui.Color.reset });
    }
    try writer.writeAll("\n");

    try ui.printSectionTitle(writer, "Memory", width);
    const mem_used = info.mem_total -| info.mem_available;
    const mem_pct: f64 = if (info.mem_total > 0)
        @as(f64, @floatFromInt(mem_used)) * 100.0 / @as(f64, @floatFromInt(info.mem_total))
    else
        0.0;
    try writer.print(" {s}RAM:{s}     {s}{s}{s} / {s}{s}{s}  ", .{
        ui.Color.fg_medium_gray,             ui.Color.reset,
        ui.Color.bright_white,               ui.formatSize(buf1, mem_used),
        ui.Color.reset,                      ui.Color.fg_medium_gray,
        ui.formatSize(buf2, info.mem_total), ui.Color.reset,
    });
    try ui.printColoredBar(writer, mem_pct, 100.0, bw);
    try writer.print("  {s}{d:.0}%{s}\n", .{ ui.Color.bright_white, mem_pct, ui.Color.reset });

    if (info.swap_total > 0) {
        const swap_used = info.swap_total -| info.swap_free;
        const swap_pct: f64 = if (info.swap_total > 0)
            @as(f64, @floatFromInt(swap_used)) * 100.0 / @as(f64, @floatFromInt(info.swap_total))
        else
            0.0;
        try writer.print(" {s}Swap:{s}    {s}{s}{s} / {s}{s}{s}  ", .{
            ui.Color.fg_medium_gray,              ui.Color.reset,
            ui.Color.bright_white,                ui.formatSize(buf1, swap_used),
            ui.Color.reset,                       ui.Color.fg_medium_gray,
            ui.formatSize(buf2, info.swap_total), ui.Color.reset,
        });
        try ui.printColoredBar(writer, swap_pct, 100.0, bw);
        try writer.print("  {s}{d:.0}%{s}\n", .{ ui.Color.bright_white, swap_pct, ui.Color.reset });
    }

    if (info.filesystems.len > 0) {
        var has_real = false;
        for (info.filesystems) |fs| {
            if (!isVirtualMount(fs.mount_point, fs.total)) {
                has_real = true;
                break;
            }
        }
        if (has_real) {
            try ui.printSectionTitle(writer, "Disk", width);
            for (info.filesystems) |fs| {
                if (isVirtualMount(fs.mount_point, fs.total)) continue;
                const pct: f64 = if (fs.total > 0)
                    @as(f64, @floatFromInt(fs.used)) * 100.0 / @as(f64, @floatFromInt(fs.total))
                else
                    0.0;
                try writer.print(" {s:<8} {s}{s:>10}{s} / {s}{s:<10}{s}  ", .{
                    fs.mount_point,
                    ui.Color.bright_white,
                    ui.formatSize(buf1, fs.used),
                    ui.Color.reset,
                    ui.Color.fg_medium_gray,
                    ui.formatSize(buf2, fs.total),
                    ui.Color.reset,
                });
                try ui.printColoredBar(writer, pct, 100.0, bw);
                try writer.print("  {s}{d:.0}%{s}\n", .{ ui.Color.bright_white, pct, ui.Color.reset });
            }
        }
    }

    if (info.interfaces.len > 0) {
        try ui.printSectionTitle(writer, "Network", width);
        for (info.interfaces) |iface| {
            try writer.print(" {s:<8} ", .{iface.iface_name});
            try writer.print("{s}" ++ ui.Box.arrow_down ++ "{s} {s}  ", .{
                ui.Color.bright_green,               ui.Color.reset,
                ui.formatSize(buf1, iface.rx_bytes),
            });
            try writer.print("{s}" ++ ui.Box.arrow_up ++ "{s} {s}\n", .{
                ui.Color.bright_cyan,                ui.Color.reset,
                ui.formatSize(buf2, iface.tx_bytes),
            });
        }
    }

    if (info.top_processes.len > 0) {
        try ui.printSectionTitle(writer, "Top Processes (by memory)", width);
        for (info.top_processes) |proc| {
            const rss_color = ui.sizeColor(proc.mem_rss);
            try writer.print(" {s:<20} {s}{s:>10}{s}\n", .{
                proc.proc_name,
                rss_color,
                ui.formatSize(buf1, proc.mem_rss),
                ui.Color.reset,
            });
        }
    }

    if (info.service_count > 0) {
        try ui.printSectionTitle(writer, "Services", width);
        try writer.print(" {s}{d}{s} running services {s}({s}){s}\n", .{
            ui.Color.bright_white,   info.service_count,   ui.Color.reset,
            ui.Color.fg_medium_gray, info.service_manager, ui.Color.reset,
        });
    }
    if (info.package_count > 0) {
        try ui.printSectionTitle(writer, "Packages", width);
        try writer.print(" {s}{d}{s} installed {s}({s}){s}\n", .{
            ui.Color.bright_white,   info.package_count,   ui.Color.reset,
            ui.Color.fg_medium_gray, info.package_manager, ui.Color.reset,
        });
    }
}

/// Returns true for virtual/irrelevant mounts that should be filtered out.
fn isVirtualMount(mount_point: []const u8, total: u64) bool {
    const mb_100 = 100 * 1024 * 1024;
    if (total < mb_100) return true;

    const virtual_prefixes = [_][]const u8{
        "/dev/shm",
        "/run/credentials",
        "/run/user",
        "/run",
        "/sys",
        "/proc",
        "/dev",
    };
    for (&virtual_prefixes) |prefix| {
        if (std.mem.eql(u8, mount_point, prefix) or
            (std.mem.startsWith(u8, mount_point, prefix) and
                mount_point.len > prefix.len and mount_point[prefix.len] == '/'))
        {
            return true;
        }
    }
    return false;
}

fn barWidthNarrow(term_width: u16) u16 {
    return if (term_width > 60) term_width - 40 else 20;
}

fn truncStr(s: []const u8, max_len: usize) []const u8 {
    return if (s.len > max_len) s[0..max_len] else s;
}

fn fmtUptime(seconds: u64) []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    if (seconds == 0) return "unknown";
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const mins = (seconds % 3600) / 60;
    if (days > 0) {
        return std.fmt.bufPrint(&S.buf, "{d}d {d}h {d}m", .{ days, hours, mins }) catch "???";
    } else if (hours > 0) {
        return std.fmt.bufPrint(&S.buf, "{d}h {d}m", .{ hours, mins }) catch "???";
    } else {
        return std.fmt.bufPrint(&S.buf, "{d}m", .{mins}) catch "???";
    }
}

test "fmtUptime" {
    try std.testing.expectEqualStrings("unknown", fmtUptime(0));

    const one_day = fmtUptime(86400 + 3600 * 2 + 60 * 30);
    try std.testing.expect(std.mem.startsWith(u8, one_day, "1d"));

    const hours_only = fmtUptime(3600 * 5 + 60 * 15);
    try std.testing.expect(std.mem.startsWith(u8, hours_only, "5h"));

    const mins_only = fmtUptime(60 * 42);
    try std.testing.expect(std.mem.startsWith(u8, mins_only, "42m"));
}

test "isVirtualMount" {
    try std.testing.expect(isVirtualMount("/dev/shm", 1024 * 1024 * 1024));
    try std.testing.expect(isVirtualMount("/run", 500 * 1024 * 1024));
    try std.testing.expect(isVirtualMount("/run/user/1000", 500 * 1024 * 1024));
    try std.testing.expect(isVirtualMount("/run/credentials/foo", 500 * 1024 * 1024));
    try std.testing.expect(isVirtualMount("/boot/efi", 50 * 1024 * 1024));
    try std.testing.expect(!isVirtualMount("/", 500 * 1024 * 1024 * 1024));
    try std.testing.expect(!isVirtualMount("/home", 200 * 1024 * 1024 * 1024));
}

test "GridLayout" {
    const wide = GridLayout.init(100);
    try std.testing.expect(wide.is_wide);
    try std.testing.expectEqual(@as(u16, 51), wide.right_col);

    const narrow = GridLayout.init(60);
    try std.testing.expect(!narrow.is_wide);
}

test "truncStr" {
    try std.testing.expectEqualStrings("hello", truncStr("hello", 10));
    try std.testing.expectEqualStrings("hel", truncStr("hello", 3));
}
