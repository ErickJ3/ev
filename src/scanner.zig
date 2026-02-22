const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const rules_mod = @import("rules.zig");
const platform = @import("platform.zig");
const ui = @import("ui.zig");
const Rule = rules_mod.Rule;
const Category = rules_mod.Category;
const Allocator = std.mem.Allocator;

pub const ScanResult = struct {
    path: []const u8,
    size: u64,
    rule: *const Rule,
};

pub const ScanOptions = struct {
    category: ?Category = null,
    max_depth: u32 = 20,
    home: []const u8 = "/tmp",
    progress_writer: ?*Io.Writer = null,
};

pub const ResultList = std.ArrayList(ScanResult);

/// Pre-built lookup tables for O(1) rule matching by entry name.
const RuleLookup = struct {
    dir_names: std.StringHashMapUnmanaged(*const Rule),
    marker_files: std.StringHashMapUnmanaged(*const Rule),

    fn init(allocator: Allocator, rule_ptrs: []const *const Rule) !RuleLookup {
        var dir_names: std.StringHashMapUnmanaged(*const Rule) = .empty;
        var marker_files: std.StringHashMapUnmanaged(*const Rule) = .empty;

        for (rule_ptrs) |rule| {
            switch (rule.detection) {
                .dir_name => |name| {
                    try dir_names.put(allocator, name, rule);
                },
                .marker_file => |mf| {
                    try marker_files.put(allocator, mf.marker, rule);
                },
                .path_prefix => {},
            }
        }
        return .{ .dir_names = dir_names, .marker_files = marker_files };
    }

    fn initFromRules(allocator: Allocator, selected_rules: []const Rule) !RuleLookup {
        var dir_names: std.StringHashMapUnmanaged(*const Rule) = .empty;
        var marker_files: std.StringHashMapUnmanaged(*const Rule) = .empty;

        for (selected_rules) |*rule| {
            switch (rule.detection) {
                .dir_name => |name| {
                    try dir_names.put(allocator, name, rule);
                },
                .marker_file => |mf| {
                    try marker_files.put(allocator, mf.marker, rule);
                },
                .path_prefix => {},
            }
        }
        return .{ .dir_names = dir_names, .marker_files = marker_files };
    }
};

/// Run a full scan from `root_path`, matching against all rules (or filtered category).
/// Returns a list of ScanResults sorted by size descending.
pub fn scan(allocator: Allocator, io: Io, root_path: []const u8, options: ScanOptions) !ResultList {
    var results: ResultList = .empty;
    errdefer results.deinit(allocator);

    const home = options.home;
    const selected_rules = if (options.category) |cat|
        rules_mod.rulesForCategory(cat)
    else
        &rules_mod.all_rules;

    for (selected_rules) |*rule| {
        switch (rule.detection) {
            .path_prefix => |prefix| {
                const expanded = try expandTilde(allocator, prefix, home);
                const size = dirSize(io, expanded) catch continue;
                if (size > 0) {
                    try results.append(allocator, .{
                        .path = expanded,
                        .size = size,
                        .rule = rule,
                    });
                }
            },
            else => {},
        }
    }

    const lookup = try RuleLookup.initFromRules(allocator, selected_rules);
    const n_cpus = std.Thread.getCpuCount() catch 1;

    if (n_cpus > 1) {
        parallelWalkDir(allocator, io, root_path, &lookup, &results, options.max_depth, options.progress_writer) catch {
            var dir_count: usize = 0;
            try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, options.progress_writer, &dir_count);
        };
    } else {
        var dir_count: usize = 0;
        try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, options.progress_writer, &dir_count);
    }

    if (options.progress_writer) |pw| {
        ui.clearProgress(pw) catch {};
    }

    std.mem.sort(ScanResult, results.items, {}, struct {
        fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
            return a.size > b.size;
        }
    }.lessThan);

    return results;
}

fn walkDir(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    lookup: *const RuleLookup,
    results: *ResultList,
    depth: u32,
    max_depth: u32,
    progress_writer: ?*Io.Writer,
    dir_count: *usize,
) !void {
    if (depth >= max_depth) return;
    if (platform.impl.isSkipDir(path)) return;

    dir_count.* += 1;
    if (progress_writer) |pw| {
        if (dir_count.* % 10 == 0) {
            ui.printProgress(pw, dir_count.*, path) catch {};
        }
    }

    var dir = Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = path.len;

    var iter = dir.iterate();
    while (iter.next(io) catch return) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .directory) {
            if (lookup.dir_names.get(entry.name)) |rule| {
                const full_path = try std.fs.path.join(allocator, &.{ path, entry.name });
                const size = dirSize(io, full_path) catch 0;
                if (size > 0) {
                    try results.append(allocator, .{
                        .path = full_path,
                        .size = size,
                        .rule = rule,
                    });
                }
                continue;
            }

            if (entry.name.len > 0 and entry.name[0] == '.') {
                if (!isInterestingHiddenDir(entry.name)) continue;
            }

            const name_len = entry.name.len;
            const total_len = path_len + 1 + name_len;
            if (total_len <= path_buf.len) {
                @memcpy(path_buf[0..path_len], path);
                path_buf[path_len] = '/';
                @memcpy(path_buf[path_len + 1 ..][0..name_len], entry.name);
                const sub_path = try allocator.dupe(u8, path_buf[0..total_len]);
                try walkDir(allocator, io, sub_path, lookup, results, depth + 1, max_depth, progress_writer, dir_count);
            }
        }

        if (entry.kind == .file) {
            if (lookup.marker_files.get(entry.name)) |rule| {
                const mf = rule.detection.marker_file;
                for (mf.targets) |target_name| {
                    const target_path = try std.fs.path.join(allocator, &.{ path, target_name });
                    const size = dirSize(io, target_path) catch continue;
                    if (size > 0) {
                        try results.append(allocator, .{
                            .path = target_path,
                            .size = size,
                            .rule = rule,
                        });
                    }
                }
            }
        }
    }
}

/// Shared state for parallel directory scanning.
/// Workers steal toplevel subdirectories via atomic index, then walk sequentially.
const SharedScanState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    allocator: Allocator,
    results: *ResultList,
    lookup: *const RuleLookup,
    io: Io,
    max_depth: u32,
    children: []const []const u8,
    next_idx: std.atomic.Value(usize) = .init(0),
    dir_count: std.atomic.Value(usize) = .init(0),

    fn lock(self: *SharedScanState) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SharedScanState) void {
        self.mutex.unlock();
    }
};

fn parallelWalkDir(
    allocator: Allocator,
    io: Io,
    root_path: []const u8,
    lookup: *const RuleLookup,
    results: *ResultList,
    max_depth: u32,
    progress_writer: ?*Io.Writer,
) !void {
    if (platform.impl.isSkipDir(root_path)) return;
    if (max_depth == 0) return;

    var children: std.ArrayList([]const u8) = .empty;

    {
        var dir = Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .sym_link) continue;

            if (entry.kind == .directory) {
                if (lookup.dir_names.get(entry.name)) |rule| {
                    const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                    const size = dirSize(io, full_path) catch 0;
                    if (size > 0) {
                        try results.append(allocator, .{ .path = full_path, .size = size, .rule = rule });
                    }
                    continue;
                }

                if (entry.name.len > 0 and entry.name[0] == '.') {
                    if (!isInterestingHiddenDir(entry.name)) continue;
                }

                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                try children.append(allocator, child_path);
            }

            if (entry.kind == .file) {
                if (lookup.marker_files.get(entry.name)) |rule| {
                    const mf = rule.detection.marker_file;
                    for (mf.targets) |target_name| {
                        const target_path = try std.fs.path.join(allocator, &.{ root_path, target_name });
                        const size = dirSize(io, target_path) catch continue;
                        if (size > 0) {
                            try results.append(allocator, .{ .path = target_path, .size = size, .rule = rule });
                        }
                    }
                }
            }
        }
    }

    if (children.items.len == 0) return;

    const n_cpus = std.Thread.getCpuCount() catch 1;
    const n_workers = @min(n_cpus, @min(children.items.len, 8));

    if (n_workers <= 1) {
        var dir_count: usize = 0;
        for (children.items) |child_path| {
            try walkDir(allocator, io, child_path, lookup, results, 1, max_depth, progress_writer, &dir_count);
        }
        return;
    }

    var state: SharedScanState = .{
        .allocator = allocator,
        .results = results,
        .lookup = lookup,
        .io = io,
        .max_depth = max_depth,
        .children = children.items,
    };

    const n_spawned = n_workers - 1;
    const threads = try allocator.alloc(std.Thread, n_spawned);

    var spawned_count: usize = 0;
    for (0..n_spawned) |_| {
        threads[spawned_count] = std.Thread.spawn(.{}, workerThreadFn, .{&state}) catch break;
        spawned_count += 1;
    }

    if (progress_writer != null) {
        mainThreadWorkerWithProgress(&state, progress_writer.?);
    } else {
        workerThreadFn(&state);
    }

    for (threads[0..spawned_count]) |thread| {
        thread.join();
    }
}

fn workerThreadFn(state: *SharedScanState) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .monotonic);
        if (idx >= state.children.len) return;
        workerWalkDir(state, state.children[idx], 1);
    }
}

fn mainThreadWorkerWithProgress(state: *SharedScanState, pw: *Io.Writer) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .monotonic);
        if (idx >= state.children.len) return;

        const count = state.dir_count.load(.monotonic);
        if (count > 0) {
            ui.printProgress(pw, count, state.children[idx]) catch {};
        }

        workerWalkDir(state, state.children[idx], 1);
    }
}

fn workerWalkDir(state: *SharedScanState, path: []const u8, depth: u32) void {
    if (depth >= state.max_depth) return;
    if (platform.impl.isSkipDir(path)) return;

    _ = state.dir_count.fetchAdd(1, .monotonic);

    var dir = Dir.openDirAbsolute(state.io, path, .{ .iterate = true }) catch return;
    defer dir.close(state.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = path.len;

    var iter = dir.iterate();
    while (iter.next(state.io) catch null) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .directory) {
            if (state.lookup.dir_names.get(entry.name)) |rule| {
                const full_path = blk: {
                    state.lock();
                    defer state.unlock();
                    break :blk std.fs.path.join(state.allocator, &.{ path, entry.name }) catch return;
                };
                const size = dirSize(state.io, full_path) catch 0;
                if (size > 0) {
                    state.lock();
                    defer state.unlock();
                    state.results.append(state.allocator, .{
                        .path = full_path,
                        .size = size,
                        .rule = rule,
                    }) catch {};
                }
                continue;
            }

            if (entry.name.len > 0 and entry.name[0] == '.') {
                if (!isInterestingHiddenDir(entry.name)) continue;
            }

            const name_len = entry.name.len;
            const total_len = path_len + 1 + name_len;
            if (total_len <= path_buf.len) {
                @memcpy(path_buf[0..path_len], path);
                path_buf[path_len] = '/';
                @memcpy(path_buf[path_len + 1 ..][0..name_len], entry.name);
                const sub_path = blk: {
                    state.lock();
                    defer state.unlock();
                    break :blk state.allocator.dupe(u8, path_buf[0..total_len]) catch return;
                };
                workerWalkDir(state, sub_path, depth + 1);
            }
        }

        if (entry.kind == .file) {
            if (state.lookup.marker_files.get(entry.name)) |rule| {
                const mf = rule.detection.marker_file;
                for (mf.targets) |target_name| {
                    const target_path = blk: {
                        state.lock();
                        defer state.unlock();
                        break :blk std.fs.path.join(state.allocator, &.{ path, target_name }) catch continue;
                    };
                    const size = dirSize(state.io, target_path) catch continue;
                    if (size > 0) {
                        state.lock();
                        defer state.unlock();
                        state.results.append(state.allocator, .{
                            .path = target_path,
                            .size = size,
                            .rule = rule,
                        }) catch {};
                    }
                }
            }
        }
    }
}

fn isInterestingHiddenDir(name: []const u8) bool {
    const interesting = [_][]const u8{
        ".cache",
        ".local",
        ".cargo",
        ".npm",
        ".gradle",
        ".m2",
        ".ollama",
        ".conda",
        ".keras",
    };
    for (&interesting) |dir_name| {
        if (std.mem.eql(u8, name, dir_name)) return true;
    }
    return false;
}

fn expandTilde(allocator: Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return try std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return try allocator.dupe(u8, path);
}

pub fn dirSize(io: Io, path: []const u8) !u64 {
    var total: u64 = 0;
    var dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    try dirSizeRecurse(io, dir, &total, 0);
    return total;
}

fn dirSizeRecurse(io: Io, dir: Dir, total: *u64, depth: u32) !void {
    if (depth > 50) return;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .file) {
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            total.* += stat.size;
        } else if (entry.kind == .directory) {
            var sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close(io);
            dirSizeRecurse(io, sub_dir, total, depth + 1) catch continue;
        }
    }
}

pub const PurgeOptions = struct {
    max_depth: u32 = 10,
    home: []const u8 = "/tmp",
};

/// Project-centric scan: only uses marker_file rules to find build artifacts.
/// Walks from root_path looking for project markers (Cargo.toml, package.json, etc.)
/// and reports their target directories (target/, node_modules/, etc.).
pub fn purgeScan(allocator: Allocator, io: Io, root_path: []const u8, options: PurgeOptions) !ResultList {
    var results: ResultList = .empty;
    errdefer results.deinit(allocator);

    const marker_rules = comptime blk: {
        var count: usize = 0;
        for (rules_mod.all_rules) |rule| {
            switch (rule.detection) {
                .marker_file => count += 1,
                else => {},
            }
        }
        var buf: [count]*const Rule = undefined;
        var i: usize = 0;
        for (&rules_mod.all_rules) |*rule| {
            switch (rule.detection) {
                .marker_file => {
                    buf[i] = rule;
                    i += 1;
                },
                else => {},
            }
        }
        break :blk buf;
    };

    const lookup = try RuleLookup.init(allocator, &marker_rules);

    var dir_count: usize = 0;
    try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, null, &dir_count);

    std.mem.sort(ScanResult, results.items, {}, struct {
        fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
            return a.size > b.size;
        }
    }.lessThan);

    return results;
}

test "expandTilde" {
    const allocator = std.testing.allocator;
    const result = try expandTilde(allocator, "~/.cache/pip", "/home/user");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/.cache/pip", result);
}

test "purgeScan finds mock Rust project" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const tmp = "/tmp/evi_purge_test";
    Dir.cwd().deleteTree(io, "tmp/evi_purge_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_purge_test") catch {};

    const project = tmp ++ "/myproject";
    Dir.createDirAbsolute(io, project, .default_dir) catch {};

    var marker = Dir.createFileAbsolute(io, project ++ "/Cargo.toml", .{}) catch return;
    marker.close(io);

    Dir.createDirAbsolute(io, project ++ "/target", .default_dir) catch {};
    var artifact = Dir.createFileAbsolute(io, project ++ "/target/debug_binary", .{}) catch return;
    {
        var buf: [64]u8 = undefined;
        var writer: Io.File.Writer = .init(artifact, io, &buf);
        writer.interface.print("binary content placeholder data", .{}) catch {};
        writer.interface.flush() catch {};
    }
    artifact.close(io);

    var results = try purgeScan(allocator, io, tmp, .{ .home = "/tmp" });

    try std.testing.expect(results.items.len >= 1);
    var found_target = false;
    for (results.items) |result| {
        if (std.mem.endsWith(u8, result.path, "/target")) {
            found_target = true;
            switch (result.rule.detection) {
                .marker_file => {},
                else => return error.TestUnexpectedResult,
            }
        }
    }
    try std.testing.expect(found_target);
}

test "purgeScan depth limit respected" {
    const io = std.testing.io;

    const tmp = "/tmp/evi_purge_depth_test";
    Dir.cwd().deleteTree(io, "tmp/evi_purge_depth_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_purge_depth_test") catch {};

    Dir.createDirAbsolute(io, tmp ++ "/a", .default_dir) catch {};
    Dir.createDirAbsolute(io, tmp ++ "/a/b", .default_dir) catch {};
    Dir.createDirAbsolute(io, tmp ++ "/a/b/c", .default_dir) catch {};

    var marker = Dir.createFileAbsolute(io, tmp ++ "/a/b/c/Cargo.toml", .{}) catch return;
    marker.close(io);
    Dir.createDirAbsolute(io, tmp ++ "/a/b/c/target", .default_dir) catch {};
    var artifact = Dir.createFileAbsolute(io, tmp ++ "/a/b/c/target/bin", .{}) catch return;
    {
        var buf: [64]u8 = undefined;
        var writer: Io.File.Writer = .init(artifact, io, &buf);
        writer.interface.print("binary content placeholder data", .{}) catch {};
        writer.interface.flush() catch {};
    }
    artifact.close(io);

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var results = try purgeScan(arena_state.allocator(), io, tmp, .{ .max_depth = 2, .home = "/tmp" });
        var found = false;
        for (results.items) |result| {
            if (std.mem.endsWith(u8, result.path, "/target")) found = true;
        }
        try std.testing.expect(!found);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var results = try purgeScan(arena_state.allocator(), io, tmp, .{ .max_depth = 10, .home = "/tmp" });
        var found = false;
        for (results.items) |result| {
            if (std.mem.endsWith(u8, result.path, "/target")) found = true;
        }
        try std.testing.expect(found);
    }
}

test "purgeScan only uses marker_file rules" {
    const marker_rules = comptime blk: {
        var count: usize = 0;
        for (rules_mod.all_rules) |rule| {
            switch (rule.detection) {
                .marker_file => count += 1,
                else => {},
            }
        }
        break :blk count;
    };
    try std.testing.expect(marker_rules > 0);

    var non_marker: usize = 0;
    for (&rules_mod.all_rules) |rule| {
        switch (rule.detection) {
            .marker_file => {},
            else => non_marker += 1,
        }
    }
    try std.testing.expect(non_marker > 0);
    try std.testing.expect(marker_rules + non_marker == rules_mod.all_rules.len);
}
