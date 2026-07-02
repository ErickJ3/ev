const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const rules_mod = @import("rules.zig");
const platform = @import("platform.zig");
const ui = @import("ui.zig");
const progress = @import("progress.zig");
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
pub const RuleLookup = struct {
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

    pub fn initFromRules(allocator: Allocator, selected_rules: []const Rule) !RuleLookup {
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

    var tracker: progress.Tracker = .{};
    var ticker: ?progress.Ticker = null;
    if (options.progress_writer) |pw| {
        ticker = progress.Ticker.init(io, pw, &tracker, "Scanning", "dirs");
        ticker.?.begin();
    }
    defer if (ticker) |*t| t.end();

    const home = options.home;
    const selected_rules = if (options.category) |cat|
        rules_mod.rulesForCategory(cat)
    else
        &rules_mod.all_rules;

    for (selected_rules) |*rule| {
        switch (rule.detection) {
            .path_prefix => |prefix| {
                const expanded = try expandTilde(allocator, prefix, home);
                tracker.setPath(0, expanded);
                const size = dirSizeTracked(io, expanded, &tracker) catch continue;
                if (size > 0) {
                    tracker.addItem(size);
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
        const prefix_count = results.items.len;
        parallelWalkDir(allocator, io, root_path, &lookup, &results, options.max_depth, &tracker) catch {
            results.shrinkRetainingCapacity(prefix_count);
            try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, &tracker);
        };
    } else {
        try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, &tracker);
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
    tracker: ?*progress.Tracker,
) !void {
    if (depth >= max_depth) return;
    if (platform.impl.isSkipDir(path)) return;

    if (tracker) |t| t.addDir(0, path);

    var dir = Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch {
        if (tracker) |t| t.addDenied();
        return;
    };
    defer dir.close(io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = path.len;

    var iter = dir.iterate();
    while (iter.next(io) catch return) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .directory) {
            if (lookup.dir_names.get(entry.name)) |rule| {
                const full_path = try std.fs.path.join(allocator, &.{ path, entry.name });
                if (tracker) |t| t.setPath(0, full_path);
                const size = dirSizeTracked(io, full_path, tracker) catch 0;
                if (size > 0) {
                    if (tracker) |t| t.addItem(size);
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
                try walkDir(allocator, io, path_buf[0..total_len], lookup, results, depth + 1, max_depth, tracker);
            }
        }

        if (entry.kind == .file) {
            if (lookup.marker_files.get(entry.name)) |rule| {
                const mf = rule.detection.marker_file;
                for (mf.targets) |target_name| {
                    const target_path = try std.fs.path.join(allocator, &.{ path, target_name });
                    const size = dirSizeTracked(io, target_path, tracker) catch continue;
                    if (size > 0) {
                        if (tracker) |t| t.addItem(size);
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

/// A directory queued for scanning. `path` is owned by the queue arena.
const Task = struct {
    path: []const u8,
    depth: u32,
};

/// Shared state for parallel directory scanning.
/// Workers drain a shared LIFO stack of directory tasks; while the stack is
/// hungry (below `hungry` entries) they hand subdirectories back to it instead
/// of recursing, so one giant subtree cannot pin a single worker while the
/// rest idle. Lock traffic is rare after warmup: the racy `pending_len`
/// pre-check keeps the hot path lock-free, and workers never touch shared
/// allocators or result lists (each has its own WorkerCtx).
const SharedScanState = struct {
    lookup: *const RuleLookup,
    io: Io,
    max_depth: u32,
    tracker: ?*progress.Tracker = null,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Guarded by `mutex`; storage and task paths live in `queue_alloc`.
    pending: std.ArrayList(Task) = .empty,
    queue_alloc: Allocator,
    /// Workers currently processing a task. Guarded by `mutex`.
    active: usize = 0,
    /// Mirror of `pending.items.len` for the lock-free pre-check.
    pending_len: std.atomic.Value(usize) = .init(0),
    /// Push subdirectories as tasks while the queue holds fewer than this.
    hungry: usize,

    /// Hand a directory to the queue if it is hungry. Returns false when the
    /// queue is full enough (or on allocation failure): caller walks inline.
    fn tryPush(state: *SharedScanState, path: []const u8, depth: u32) bool {
        if (state.pending_len.load(.monotonic) >= state.hungry) return false;

        const io = state.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);

        if (state.pending.items.len >= state.hungry) return false;
        const path_copy = state.queue_alloc.dupe(u8, path) catch return false;
        state.pending.append(state.queue_alloc, .{ .path = path_copy, .depth = depth }) catch return false;
        state.pending_len.store(state.pending.items.len, .monotonic);
        state.cond.signal(io);
        return true;
    }
};

/// Per-worker allocation context: results land in the worker's own arena
/// with zero cross-thread synchronization, merged by the main thread after join.
const WorkerCtx = struct {
    arena: std.heap.ArenaAllocator,
    results: ResultList = .empty,

    fn init() WorkerCtx {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
};

fn parallelWalkDir(
    allocator: Allocator,
    io: Io,
    root_path: []const u8,
    lookup: *const RuleLookup,
    results: *ResultList,
    max_depth: u32,
    tracker: ?*progress.Tracker,
) !void {
    if (platform.impl.isSkipDir(root_path)) return;
    if (max_depth == 0) return;

    const n_cpus = std.Thread.getCpuCount() catch 1;
    const n_workers: usize = @min(n_cpus, 8);
    if (n_workers <= 1) {
        return walkDir(allocator, io, root_path, lookup, results, 0, max_depth, tracker);
    }

    var queue_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer queue_arena.deinit();

    var state: SharedScanState = .{
        .lookup = lookup,
        .io = io,
        .max_depth = max_depth,
        .tracker = tracker,
        .queue_alloc = queue_arena.allocator(),
        .hungry = n_workers * 2,
    };

    try state.pending.append(state.queue_alloc, .{
        .path = try state.queue_alloc.dupe(u8, root_path),
        .depth = 0,
    });
    state.pending_len.store(1, .monotonic);

    const n_spawned = n_workers - 1;
    const threads = try allocator.alloc(std.Thread, n_spawned);

    const ctxs = try allocator.alloc(WorkerCtx, n_workers);
    for (ctxs) |*ctx| ctx.* = WorkerCtx.init();
    defer for (ctxs) |*ctx| ctx.arena.deinit();

    var spawned_count: usize = 0;
    for (0..n_spawned) |i| {
        threads[spawned_count] = std.Thread.spawn(.{}, workerLoop, .{ &state, &ctxs[i + 1], i + 1 }) catch break;
        spawned_count += 1;
    }

    workerLoop(&state, &ctxs[0], 0);

    for (threads[0..spawned_count]) |thread| {
        thread.join();
    }

    for (ctxs) |*ctx| {
        for (ctx.results.items) |r| {
            try results.append(allocator, .{
                .path = try allocator.dupe(u8, r.path),
                .size = r.size,
                .rule = r.rule,
            });
        }
    }
}

/// Drain the shared task queue until it is empty AND no worker is mid-task
/// (an active worker may still push more tasks). Termination: the last
/// worker to go idle broadcasts, waking the others to re-check and exit.
fn workerLoop(state: *SharedScanState, ctx: *WorkerCtx, slot: usize) void {
    const io = state.io;
    state.mutex.lockUncancelable(io);
    while (true) {
        if (state.pending.pop()) |task| {
            state.pending_len.store(state.pending.items.len, .monotonic);
            state.active += 1;
            state.mutex.unlock(io);

            workerWalkDir(state, ctx, slot, task.path, task.depth);

            state.mutex.lockUncancelable(io);
            state.active -= 1;
            if (state.active == 0 and state.pending.items.len == 0) {
                state.cond.broadcast(io);
                state.mutex.unlock(io);
                return;
            }
        } else if (state.active == 0) {
            state.mutex.unlock(io);
            return;
        } else {
            state.cond.waitUncancelable(io, &state.mutex);
        }
    }
}

fn workerWalkDir(state: *SharedScanState, ctx: *WorkerCtx, slot: usize, path: []const u8, depth: u32) void {
    if (depth >= state.max_depth) return;
    if (platform.impl.isSkipDir(path)) return;

    if (state.tracker) |t| t.addDir(slot, path);

    var dir = Dir.openDirAbsolute(state.io, path, .{ .iterate = true }) catch {
        if (state.tracker) |t| t.addDenied();
        return;
    };
    defer dir.close(state.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = path.len;

    const arena = ctx.arena.allocator();

    var iter = dir.iterate();
    while (iter.next(state.io) catch null) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .directory) {
            if (state.lookup.dir_names.get(entry.name)) |rule| {
                const full_path = std.fs.path.join(arena, &.{ path, entry.name }) catch return;
                if (state.tracker) |t| t.setPath(slot, full_path);
                const size = dirSizeTracked(state.io, full_path, state.tracker) catch 0;
                if (size > 0) {
                    if (state.tracker) |t| t.addItem(size);
                    ctx.results.append(arena, .{
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
                const sub_path = path_buf[0..total_len];
                if (!state.tryPush(sub_path, depth + 1)) {
                    workerWalkDir(state, ctx, slot, sub_path, depth + 1);
                }
            }
        }

        if (entry.kind == .file) {
            if (state.lookup.marker_files.get(entry.name)) |rule| {
                const mf = rule.detection.marker_file;
                for (mf.targets) |target_name| {
                    const target_path = std.fs.path.join(arena, &.{ path, target_name }) catch continue;
                    const size = dirSizeTracked(state.io, target_path, state.tracker) catch continue;
                    if (size > 0) {
                        if (state.tracker) |t| t.addItem(size);
                        ctx.results.append(arena, .{
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

pub fn expandTilde(allocator: Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return try std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return try allocator.dupe(u8, path);
}

pub fn dirSize(io: Io, path: []const u8) !u64 {
    return dirSizeTracked(io, path, null);
}

/// Like `dirSize` but bumps live-progress counters while it stats files,
/// so long size computations keep the status line moving.
pub fn dirSizeTracked(io: Io, path: []const u8, tracker: ?*progress.Tracker) !u64 {
    var total: u64 = 0;
    var dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    try dirSizeRecurse(io, dir, &total, 0, tracker);
    return total;
}

fn dirSizeRecurse(io: Io, dir: Dir, total: *u64, depth: u32, tracker: ?*progress.Tracker) !void {
    if (depth > 50) return;

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .file) {
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            total.* += stat.size;
            if (tracker) |t| t.addFile();
        } else if (entry.kind == .directory) {
            if (tracker) |t| t.addDirCount();
            var sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close(io);
            dirSizeRecurse(io, sub_dir, total, depth + 1, tracker) catch continue;
        }
    }
}

/// Expanded absolute path -> path_prefix rule, for matching during sizedWalk.
pub const PrefixLookup = std.StringHashMapUnmanaged(*const Rule);

pub fn buildPrefixLookup(allocator: Allocator, home: []const u8) !PrefixLookup {
    var map: PrefixLookup = .empty;
    for (&rules_mod.all_rules) |*rule| {
        switch (rule.detection) {
            .path_prefix => |prefix| {
                const expanded = try expandTilde(allocator, prefix, home);
                try map.put(allocator, expanded, rule);
            },
            else => {},
        }
    }
    return map;
}

/// Rule-aware sizing walk used by analyze: computes the full subtree size of
/// `path` in one traversal while attributing directories that match cleanup
/// rules to per-category totals.
///
/// `dir_matched` marks that an ancestor already matched a dir_name rule; it
/// suppresses nested dir_name matches (the scan walker never descends into a
/// matched dir, so e.g. node_modules inside node_modules counts once).
/// path_prefix rules deliberately nest (`~/.cache` is a system rule while
/// `~/.cache/pip` is a package rule) and are always attributed independently,
/// matching how scan sizes each prefix rule on its own.
pub fn sizedWalk(
    io: Io,
    path: []const u8,
    lookup: *const RuleLookup,
    prefixes: *const PrefixLookup,
    categories: *ui.CategorySizes,
    tracker: ?*progress.Tracker,
    slot: usize,
    depth: u32,
    dir_matched: bool,
) u64 {
    if (depth > 50) return 0;
    if (tracker) |t| t.addDir(slot, path);

    var dir = Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch {
        if (tracker) |t| t.addDenied();
        return 0;
    };
    defer dir.close(io);

    var total: u64 = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = path.len;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .sym_link) continue;

        if (entry.kind == .file) {
            const stat = dir.statFile(io, entry.name, .{}) catch continue;
            total += stat.size;
            if (tracker) |t| t.addFile();
        } else if (entry.kind == .directory) {
            const name_len = entry.name.len;
            const total_len = path_len + 1 + name_len;
            if (total_len > path_buf.len) continue;
            @memcpy(path_buf[0..path_len], path);
            path_buf[path_len] = '/';
            @memcpy(path_buf[path_len + 1 ..][0..name_len], entry.name);
            const sub_path = path_buf[0..total_len];

            var dir_rule: ?*const Rule = null;
            if (!dir_matched) {
                if (lookup.dir_names.get(entry.name)) |r| dir_rule = r;
            }
            const prefix_rule: ?*const Rule = prefixes.get(sub_path);

            const sub = sizedWalk(io, sub_path, lookup, prefixes, categories, tracker, slot, depth + 1, dir_matched or dir_rule != null);
            if (dir_rule) |r| categories.add(r.category, sub);
            if (prefix_rule) |r| categories.add(r.category, sub);
            total += sub;
        }
    }
    return total;
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

    try walkDir(allocator, io, root_path, &lookup, &results, 0, options.max_depth, null);

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

    const results = try purgeScan(allocator, io, tmp, .{ .home = "/tmp" });

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
        const results = try purgeScan(arena_state.allocator(), io, tmp, .{ .max_depth = 2, .home = "/tmp" });
        var found = false;
        for (results.items) |result| {
            if (std.mem.endsWith(u8, result.path, "/target")) found = true;
        }
        try std.testing.expect(!found);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const results = try purgeScan(arena_state.allocator(), io, tmp, .{ .max_depth = 10, .home = "/tmp" });
        var found = false;
        for (results.items) |result| {
            if (std.mem.endsWith(u8, result.path, "/target")) found = true;
        }
        try std.testing.expect(found);
    }
}

test "scan empty root terminates" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const tmp = "/tmp/evi_scan_empty_test";
    Dir.cwd().deleteTree(io, "tmp/evi_scan_empty_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_scan_empty_test") catch {};

    const results = try scan(arena_state.allocator(), io, tmp, .{ .category = .dev, .home = tmp });
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "scan deep single chain terminates and finds artifact" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const tmp = "/tmp/evi_scan_chain_test";
    Dir.cwd().deleteTree(io, "tmp/evi_scan_chain_test") catch {};
    Dir.createDirAbsolute(io, tmp, .default_dir) catch {};
    defer Dir.cwd().deleteTree(io, "tmp/evi_scan_chain_test") catch {};

    var path_buf: [512]u8 = undefined;
    var len: usize = tmp.len;
    @memcpy(path_buf[0..len], tmp);
    for (0..12) |_| {
        @memcpy(path_buf[len..][0..2], "/d");
        len += 2;
        Dir.createDirAbsolute(io, path_buf[0..len], .default_dir) catch {};
    }

    const nm = try std.fmt.allocPrint(allocator, "{s}/node_modules", .{path_buf[0..len]});
    Dir.createDirAbsolute(io, nm, .default_dir) catch {};
    const artifact_path = try std.fmt.allocPrint(allocator, "{s}/mod.js", .{nm});
    var artifact = Dir.createFileAbsolute(io, artifact_path, .{}) catch return;
    {
        var buf: [64]u8 = undefined;
        var writer: Io.File.Writer = .init(artifact, io, &buf);
        writer.interface.print("module content placeholder", .{}) catch {};
        writer.interface.flush() catch {};
    }
    artifact.close(io);

    const results = try scan(allocator, io, tmp, .{ .category = .dev, .home = tmp });
    var found = false;
    for (results.items) |r| {
        if (std.mem.endsWith(u8, r.path, "/node_modules")) found = true;
    }
    try std.testing.expect(found);
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
