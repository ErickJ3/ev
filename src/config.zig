const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    whitelist: std.ArrayList([]const u8),
    whitelist_set: std.StringHashMapUnmanaged(void),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Config {
        return .{
            .whitelist = .empty,
            .whitelist_set = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.whitelist.items) |entry| {
            self.allocator.free(entry);
        }
        self.whitelist.deinit(self.allocator);
        self.whitelist_set.deinit(self.allocator);
    }

    /// Load whitelist from ~/.config/evi/whitelist.
    /// Returns empty config if file doesn't exist.
    pub fn load(allocator: Allocator, io: Io, home: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        const config_path = try std.fs.path.join(allocator, &.{ home, ".config", "evi", "whitelist" });
        defer allocator.free(config_path);

        const contents = readFileAbsolute(io, allocator, config_path) catch |err| switch (err) {
            error.FileNotFound => return cfg,
            else => return cfg,
        };
        defer allocator.free(contents);

        var line_iter = std.mem.splitScalar(u8, contents, '\n');
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            const duped = try allocator.dupe(u8, line);
            try cfg.whitelist.append(allocator, duped);
            try cfg.whitelist_set.put(allocator, duped, {});
        }

        return cfg;
    }

    /// Save whitelist to ~/.config/evi/whitelist.
    /// Creates directories if needed.
    pub fn save(self: *const Config, io: Io, home: []const u8) !void {
        const allocator = self.allocator;

        const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "evi" });
        defer allocator.free(config_dir);

        const config_path = try std.fs.path.join(allocator, &.{ config_dir, "whitelist" });
        defer allocator.free(config_path);

        const config_parent = try std.fs.path.join(allocator, &.{ home, ".config" });
        defer allocator.free(config_parent);
        Dir.createDirAbsolute(io, config_parent, .default_dir) catch {};
        Dir.createDirAbsolute(io, config_dir, .default_dir) catch {};

        var file = Dir.createFileAbsolute(io, config_path, .{}) catch return error.FileNotFound;
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer: Io.File.Writer = .init(file, io, &buf);
        const iface = &writer.interface;

        try iface.print("# evi whitelist - one path per line\n", .{});
        for (self.whitelist.items) |entry| {
            try iface.print("{s}\n", .{entry});
        }
        try iface.flush();
    }

    /// Add a path to the whitelist (no-op if already present).
    pub fn addWhitelist(self: *Config, path: []const u8) !void {
        if (self.isWhitelisted(path)) return;
        const duped = try self.allocator.dupe(u8, path);
        try self.whitelist.append(self.allocator, duped);
        try self.whitelist_set.put(self.allocator, duped, {});
    }

    /// Remove a path from the whitelist.
    pub fn removeWhitelist(self: *Config, path: []const u8) void {
        var i: usize = 0;
        while (i < self.whitelist.items.len) {
            if (std.mem.eql(u8, self.whitelist.items[i], path)) {
                const removed = self.whitelist.items[i];
                _ = self.whitelist_set.remove(removed);
                self.allocator.free(removed);
                _ = self.whitelist.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// O(1) whitelist check via HashMap.
    pub fn isWhitelisted(self: *const Config, path: []const u8) bool {
        return self.whitelist_set.contains(path);
    }
};

fn readFileAbsolute(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    var file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return try allocator.alloc(u8, 0);

    var read_buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &read_buf);
    return reader.interface.readAlloc(allocator, @intCast(stat.size));
}

test "isWhitelisted with manually added entries" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.addWhitelist("/home/user/node_modules");
    try cfg.addWhitelist("/home/user/.cache/pip");

    try std.testing.expect(cfg.isWhitelisted("/home/user/node_modules"));
    try std.testing.expect(cfg.isWhitelisted("/home/user/.cache/pip"));
    try std.testing.expect(!cfg.isWhitelisted("/home/user/other"));
}

test "addWhitelist deduplication" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.addWhitelist("/home/user/node_modules");
    try cfg.addWhitelist("/home/user/node_modules");
    try cfg.addWhitelist("/home/user/node_modules");

    try std.testing.expectEqual(@as(usize, 1), cfg.whitelist.items.len);
}

test "removeWhitelist" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.addWhitelist("/path/a");
    try cfg.addWhitelist("/path/b");
    try std.testing.expectEqual(@as(usize, 2), cfg.whitelist.items.len);

    cfg.removeWhitelist("/path/a");
    try std.testing.expectEqual(@as(usize, 1), cfg.whitelist.items.len);
    try std.testing.expect(!cfg.isWhitelisted("/path/a"));
    try std.testing.expect(cfg.isWhitelisted("/path/b"));
}

test "load from non-existent file returns empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cfg = try Config.load(allocator, io, "/tmp/evi_test_nonexistent_dir_12345");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.whitelist.items.len);
}

test "save and reload round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/evi_config_test";

    Dir.cwd().deleteTree(io, "tmp/evi_config_test") catch {};
    Dir.createDirAbsolute(io, tmp_home, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_config_test") catch {};

    {
        var cfg = Config.init(allocator);
        defer cfg.deinit();
        try cfg.addWhitelist("/home/user/keep_this");
        try cfg.addWhitelist("/opt/important/data");
        try cfg.save(io, tmp_home);
    }
    {
        var cfg = try Config.load(allocator, io, tmp_home);
        defer cfg.deinit();

        try std.testing.expectEqual(@as(usize, 2), cfg.whitelist.items.len);
        try std.testing.expect(cfg.isWhitelisted("/home/user/keep_this"));
        try std.testing.expect(cfg.isWhitelisted("/opt/important/data"));
    }
}

test "comment lines and blank lines skipped during load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/evi_config_comment_test";

    Dir.cwd().deleteTree(io, "tmp/evi_config_comment_test") catch {};
    Dir.createDirAbsolute(io, tmp_home, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_config_comment_test") catch {};

    const config_dir = tmp_home ++ "/.config/evi";
    Dir.createDirAbsolute(io, tmp_home ++ "/.config", .default_dir) catch {};
    Dir.createDirAbsolute(io, config_dir, .default_dir) catch {};

    const content = "# This is a comment\n\n/path/one\n# Another comment\n  \n/path/two\n";
    var file = try Dir.createFileAbsolute(io, config_dir ++ "/whitelist", .{});
    var wbuf: [512]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &wbuf);
    try writer.interface.print("{s}", .{content});
    try writer.interface.flush();
    file.close(io);

    var cfg = try Config.load(allocator, io, tmp_home);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.whitelist.items.len);
    try std.testing.expect(cfg.isWhitelisted("/path/one"));
    try std.testing.expect(cfg.isWhitelisted("/path/two"));
}
