const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const ui = @import("ui.zig");

pub const Logger = struct {
    file: ?Io.File,
    io: Io,
    buf: [512]u8,
    write_pos: u64,

    /// Initialize logger, opening/creating the log file at ~/.local/share/evi/operations.log.
    /// Silently disables logging if file creation fails.
    pub fn init(io: Io, home: []const u8, allocator: Allocator) Logger {
        return openLogFile(io, home, allocator) catch disabled(io);
    }

    fn disabled(io: Io) Logger {
        return .{
            .file = null,
            .io = io,
            .buf = undefined,
            .write_pos = 0,
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| {
            var file = f;
            file.close(self.io);
        }
        self.file = null;
    }

    /// Log a single deletion event.
    pub fn logDeletion(self: *Logger, path: []const u8, size: u64, category: []const u8) void {
        const f = self.file orelse return;
        var writer: Io.File.Writer = .init(f, self.io, &self.buf);
        writer.pos = self.write_pos;
        const iface = &writer.interface;

        var size_buf: [32]u8 = undefined;
        const size_str = ui.formatSize(&size_buf, size);

        var ts_buf: [20]u8 = undefined;
        const timestamp = getTimestamp(self.io, &ts_buf);
        iface.print("{s} DELETE {s} {s} [{s}]\n", .{ timestamp, size_str, path, category }) catch return;
        iface.flush() catch return;
        self.write_pos = writer.logicalPos();
    }

    /// Log a summary line after a clean operation.
    pub fn logSummary(self: *Logger, count: usize, size: u64) void {
        const f = self.file orelse return;
        var writer: Io.File.Writer = .init(f, self.io, &self.buf);
        writer.pos = self.write_pos;
        const iface = &writer.interface;

        var size_buf: [32]u8 = undefined;
        const size_str = ui.formatSize(&size_buf, size);

        var ts_buf: [20]u8 = undefined;
        const timestamp = getTimestamp(self.io, &ts_buf);
        iface.print("{s} SUMMARY {d} items, {s} freed\n", .{ timestamp, count, size_str }) catch return;
        iface.flush() catch return;
        self.write_pos = writer.logicalPos();
    }

    fn openLogFile(io: Io, home: []const u8, allocator: Allocator) !Logger {
        const share_dir = try std.fs.path.join(allocator, &.{ home, ".local", "share", "evi" });
        defer allocator.free(share_dir);

        const log_path = try std.fs.path.join(allocator, &.{ share_dir, "operations.log" });
        defer allocator.free(log_path);

        ensureDir(io, home, ".local", allocator);
        ensureDir(io, home, ".local/share", allocator);
        ensureDir(io, home, ".local/share/evi", allocator);

        // open/create log file without truncation
        const file = Dir.createFileAbsolute(io, log_path, .{ .truncate = false }) catch
            return error.FileNotFound;

        const stat = file.stat(io) catch return .{
            .file = file,
            .io = io,
            .buf = undefined,
            .write_pos = 0,
        };

        return .{
            .file = file,
            .io = io,
            .buf = undefined,
            .write_pos = stat.size,
        };
    }

    fn ensureDir(io: Io, home: []const u8, sub: []const u8, allocator: Allocator) void {
        const path = std.fs.path.join(allocator, &.{ home, sub }) catch return;
        defer allocator.free(path);
        Dir.createDirAbsolute(io, path, .default_dir) catch {};
    }
};

fn getTimestamp(io: Io, buf: []u8) []const u8 {
    const ts = Io.Timestamp.now(io, .real);
    return formatTimestamp(buf, ts.toSeconds());
}

/// Format a timestamp string from epoch seconds.
pub fn formatTimestamp(buf: []u8, epoch: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch "0000-00-00T00:00:00";
}

test "timestamp formatting" {
    var buf: [20]u8 = undefined;
    const ts = formatTimestamp(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00", ts);
}

test "timestamp formatting known date" {
    var buf: [20]u8 = undefined;
    const ts = formatTimestamp(&buf, 1771632000);
    try std.testing.expect(std.mem.startsWith(u8, ts, "2026-02-21"));
}

test "logger init and log events with temp dir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/evi_logger_test";

    Dir.cwd().deleteTree(io, "tmp/evi_logger_test") catch {};
    Dir.createDirAbsolute(io, tmp_home, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_logger_test") catch {};

    var log = Logger.init(io, tmp_home, allocator);
    defer log.deinit();

    if (log.file == null) return;

    log.logDeletion("/home/user/project/node_modules", 1024 * 1024 * 150, "Dev");
    log.logDeletion("/home/user/.cache/pip", 1024 * 1024 * 50, "Package");
    log.logSummary(2, 1024 * 1024 * 200);

    log.deinit();
    log.file = null;

    const log_path = tmp_home ++ "/.local/share/evi/operations.log";
    var file = Dir.openFileAbsolute(io, log_path, .{}) catch return;
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return;

    var read_buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &read_buf);
    const content = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "DELETE") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "node_modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "SUMMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[Dev]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[Package]") != null);
}
