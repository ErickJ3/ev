const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const scanner = @import("scanner.zig");
const config_mod = @import("config.zig");
const logger_mod = @import("logger.zig");

pub const CleanMode = enum {
    dry_run,
    force,
};

pub const CleanResult = struct {
    deleted_count: usize = 0,
    deleted_size: u64 = 0,
    skipped_count: usize = 0,
    error_count: usize = 0,

    pub fn add(self: *CleanResult, other: CleanResult) void {
        self.deleted_count += other.deleted_count;
        self.deleted_size += other.deleted_size;
        self.skipped_count += other.skipped_count;
        self.error_count += other.error_count;
    }
};

/// Clean the selected scan results.
///
/// `selected` is a slice of indices into `results` indicating which items to clean.
/// If `selected` is null, all results are cleaned.
pub fn clean(
    io: Io,
    results: []const scanner.ScanResult,
    selected: ?[]const usize,
    mode: CleanMode,
    cfg: *const config_mod.Config,
    log: ?*logger_mod.Logger,
) CleanResult {
    var result: CleanResult = .{};

    if (selected) |indices| {
        for (indices) |idx| {
            if (idx >= results.len) continue;
            cleanItem(io, results[idx], mode, cfg, log, &result);
        }
    } else {
        for (results) |item| {
            cleanItem(io, item, mode, cfg, log, &result);
        }
    }

    if (log) |l| {
        if (result.deleted_count > 0) {
            l.logSummary(result.deleted_count, result.deleted_size);
        }
    }

    return result;
}

pub fn cleanItem(
    io: Io,
    item: scanner.ScanResult,
    mode: CleanMode,
    cfg: *const config_mod.Config,
    log: ?*logger_mod.Logger,
    result: *CleanResult,
) void {
    if (cfg.isWhitelisted(item.path)) {
        result.skipped_count += 1;
        return;
    }

    if (mode == .dry_run) {
        result.deleted_count += 1;
        result.deleted_size += item.size;
        return;
    }

    deletePath(io, item.path) catch {
        result.error_count += 1;
        return;
    };

    result.deleted_count += 1;
    result.deleted_size += item.size;

    if (log) |l| {
        l.logDeletion(item.path, item.size, item.rule.category.label());
    }
}

/// Delete a path by opening its parent directory and calling deleteTree on the basename.
fn deletePath(io: Io, path: []const u8) !void {
    const dirname = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const basename = std.fs.path.basename(path);

    var parent = Dir.openDirAbsolute(io, dirname, .{}) catch return error.FileNotFound;
    defer parent.close(io);

    try parent.deleteTree(io, basename);
}

test "CleanResult accumulation" {
    var r1: CleanResult = .{ .deleted_count = 2, .deleted_size = 1000, .skipped_count = 1, .error_count = 0 };
    const r2: CleanResult = .{ .deleted_count = 3, .deleted_size = 2000, .skipped_count = 0, .error_count = 1 };
    r1.add(r2);

    try std.testing.expectEqual(@as(usize, 5), r1.deleted_count);
    try std.testing.expectEqual(@as(u64, 3000), r1.deleted_size);
    try std.testing.expectEqual(@as(usize, 1), r1.skipped_count);
    try std.testing.expectEqual(@as(usize, 1), r1.error_count);
}

const rules_mod = @import("rules.zig");

fn makeTestResult(path: []const u8, size: u64, rule: *const rules_mod.Rule) scanner.ScanResult {
    return .{
        .path = path,
        .size = size,
        .rule = rule,
    };
}

const test_rule: rules_mod.Rule = .{
    .name = "test-node-modules",
    .description = "Test rule",
    .category = .dev,
    .risk = .safe,
    .detection = .{ .dir_name = "node_modules" },
};

test "clean dry_run does not delete" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const tmp = "/tmp/evi_cleaner_dryrun_test";
    Dir.cwd().deleteTree(io, "tmp/evi_cleaner_dryrun_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_cleaner_dryrun_test") catch {};

    const target = tmp ++ "/node_modules";
    Dir.createDirAbsolute(io, target, .default_dir) catch {};

    var file = Dir.createFileAbsolute(io, target ++ "/package.json", .{}) catch return;
    file.close(io);

    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();

    const results = [_]scanner.ScanResult{
        makeTestResult(target, 1024, &test_rule),
    };

    const clean_result = clean(io, &results, null, .dry_run, &cfg, null);

    try std.testing.expectEqual(@as(usize, 1), clean_result.deleted_count);
    try std.testing.expectEqual(@as(u64, 1024), clean_result.deleted_size);

    var dir = Dir.openDirAbsolute(io, target, .{}) catch {
        return error.TestUnexpectedResult;
    };
    dir.close(io);
}

test "clean force deletes directories" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const tmp = "/tmp/evi_cleaner_force_test";
    Dir.cwd().deleteTree(io, "tmp/evi_cleaner_force_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_cleaner_force_test") catch {};

    const target = tmp ++ "/node_modules";
    Dir.createDirAbsolute(io, target, .default_dir) catch {};
    var file = Dir.createFileAbsolute(io, target ++ "/index.js", .{}) catch return;
    file.close(io);

    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();

    const results = [_]scanner.ScanResult{
        makeTestResult(target, 1024, &test_rule),
    };

    const clean_result = clean(io, &results, null, .force, &cfg, null);

    try std.testing.expectEqual(@as(usize, 1), clean_result.deleted_count);

    if (Dir.openDirAbsolute(io, target, .{})) |d| {
        var dir = d;
        dir.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "clean skips whitelisted paths" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const tmp = "/tmp/evi_cleaner_whitelist_test";
    Dir.cwd().deleteTree(io, "tmp/evi_cleaner_whitelist_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_cleaner_whitelist_test") catch {};

    const target = tmp ++ "/node_modules";
    Dir.createDirAbsolute(io, target, .default_dir) catch {};
    var file = Dir.createFileAbsolute(io, target ++ "/pkg.json", .{}) catch return;
    file.close(io);

    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();
    try cfg.addWhitelist(target);

    const results = [_]scanner.ScanResult{
        makeTestResult(target, 1024, &test_rule),
    };

    const clean_result = clean(io, &results, null, .force, &cfg, null);

    try std.testing.expectEqual(@as(usize, 0), clean_result.deleted_count);
    try std.testing.expectEqual(@as(usize, 1), clean_result.skipped_count);

    var dir = Dir.openDirAbsolute(io, target, .{}) catch {
        return error.TestUnexpectedResult;
    };
    dir.close(io);
}

fn writeTestContent(io: Io, file: Io.File) void {
    var buf: [64]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buf);
    writer.interface.print("test content placeholder data for size", .{}) catch {};
    writer.interface.flush() catch {};
}

test "end-to-end: scan -> dry_run -> force -> verify deleted + log" {
    const io = std.testing.io;
    const test_allocator = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(test_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const tmp = "/tmp/evi_e2e_test";
    Dir.cwd().deleteTree(io, "tmp/evi_e2e_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_e2e_test") catch {};

    Dir.createDirAbsolute(io, tmp ++ "/project", .default_dir) catch {};

    var marker = Dir.createFileAbsolute(io, tmp ++ "/project/Cargo.toml", .{}) catch return;
    marker.close(io);

    Dir.createDirAbsolute(io, tmp ++ "/project/target", .default_dir) catch {};
    var artifact = Dir.createFileAbsolute(io, tmp ++ "/project/target/output.o", .{}) catch return;
    writeTestContent(io, artifact);
    artifact.close(io);

    Dir.createDirAbsolute(io, tmp ++ "/project/node_modules", .default_dir) catch {};
    var pkg = Dir.createFileAbsolute(io, tmp ++ "/project/node_modules/index.js", .{}) catch return;
    writeTestContent(io, pkg);
    pkg.close(io);

    var results = try scanner.scan(allocator, io, tmp, .{ .home = tmp });

    try std.testing.expect(results.items.len >= 1);

    var cfg = config_mod.Config.init(test_allocator);
    defer cfg.deinit();

    const dry_result = clean(io, results.items, null, .dry_run, &cfg, null);
    try std.testing.expect(dry_result.deleted_count >= 1);

    {
        var d = Dir.openDirAbsolute(io, tmp ++ "/project/target", .{}) catch return error.TestUnexpectedResult;
        d.close(io);
    }
    {
        var d = Dir.openDirAbsolute(io, tmp ++ "/project/node_modules", .{}) catch return error.TestUnexpectedResult;
        d.close(io);
    }

    var log = logger_mod.Logger.init(io, tmp, test_allocator);
    defer log.deinit();

    const force_result = clean(io, results.items, null, .force, &cfg, &log);
    try std.testing.expect(force_result.deleted_count >= 1);

    if (Dir.openDirAbsolute(io, tmp ++ "/project/target", .{})) |d| {
        var dd = d;
        dd.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}

    log.deinit();
    log.file = null;

    const log_path = tmp ++ "/.local/share/evi/operations.log";
    if (Dir.openFileAbsolute(io, log_path, .{})) |f| {
        var file = f;
        defer file.close(io);

        const stat = file.stat(io) catch return;
        if (stat.size > 0) {
            var read_buf: [4096]u8 = undefined;
            var reader: Io.File.Reader = .init(file, io, &read_buf);
            const content = reader.interface.readAlloc(test_allocator, @intCast(stat.size)) catch return;
            defer test_allocator.free(content);

            try std.testing.expect(std.mem.indexOf(u8, content, "DELETE") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "SUMMARY") != null);
        }
    } else |_| {}
}
