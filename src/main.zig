const std = @import("std");
const Io = std.Io;
const evi = @import("evi");
const clap = @import("clap");
const posix = std.posix;

const build_options = @import("build_options");
const version = build_options.version;

const Command = enum { scan, clean, purge, analyze, status, config, help };

const main_parsers = .{
    .command = clap.parsers.enumeration(Command),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-v, --version  Show version and exit.
    \\<command>
    \\
);

pub fn main(init: std.process.Init) void {
    innerMain(init) catch |err| {
        var buf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(.stderr(), init.io, &buf);
        const stderr = &w.interface;

        switch (err) {
            error.OutOfMemory => stderr.print("error: out of memory\n", .{}) catch {},
            error.AccessDenied => stderr.print("error: permission denied — try running with appropriate permissions\n", .{}) catch {},
            error.FileNotFound => stderr.print("error: path not found\n", .{}) catch {},
            error.IsDir => stderr.print("error: expected a file but found a directory\n", .{}) catch {},
            error.NotDir => stderr.print("error: expected a directory but found a file\n", .{}) catch {},
            else => stderr.print("error: unexpected error ({s})\n", .{@errorName(err)}) catch {},
        }
        stderr.flush() catch {};
    };
}

fn innerMain(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    const raw_args = try init.minimal.args.toSlice(arena);
    const user_args = if (raw_args.len > 0) raw_args[1..] else raw_args[0..0];

    var iter = try init.minimal.args.iterateAllocator(arena);

    _ = iter.next(); // skip argv[0]

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = arena,
        .terminating_positional = 0,
    }) catch |err| {
        if (err == error.NameNotPartOfEnum) {
            const cmd: []const u8 = if (user_args.len > 0) user_args[0] else "";
            try stderr.print("Unknown command: {s}\nUse 'ev --help' for available commands.\n", .{cmd});
        } else {
            try diag.reportToFile(init.io, .stderr(), err);
        }
        try stderr.flush();
        return;
    };
    _ = &res;

    const home: []const u8 = init.environ_map.get("HOME") orelse "/tmp";

    const stdout_tty = Io.File.stdout().isTty(init.io) catch false;
    const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;
    evi.ui.initColors(stdout_tty and !no_color);

    if (res.args.help != 0) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    if (res.args.version != 0) {
        try stdout.print("ev {s}\n", .{version});
        try stdout.flush();
        return;
    }

    const command = res.positionals[0] orelse {
        try printUsage(stderr);
        try stderr.flush();
        return;
    };

    switch (command) {
        .scan => try cmdScan(arena, init.io, &iter, home, stdout, stderr),
        .clean => try cmdClean(arena, init.io, &iter, home, stdout, stderr, &stdout_writer),
        .purge => try cmdPurge(arena, init.io, &iter, home, stdout, stderr, &stdout_writer),
        .analyze => try cmdAnalyze(arena, init.io, &iter, home, stdout, stderr),
        .status => try cmdStatus(arena, init.io, &iter, stdout, stderr),
        .config => try cmdConfig(arena, init.io, &iter, home, stdout, stderr),
        .help => try printUsage(stdout),
    }

    try stdout.flush();
    try stderr.flush();
}

/// Progress lines belong on stderr, and only when a human is watching:
/// returns `stderr` if it is a TTY, null otherwise (pipes, redirects, CI).
fn progressWriter(io: Io, stderr: *Io.Writer) ?*Io.Writer {
    const is_tty = Io.File.stderr().isTty(io) catch false;
    return if (is_tty) stderr else null;
}

fn cmdScan(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    home: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --category <str>  Filter by category (dev, system, package, ai, browser)
        \\-h, --help            Show this help
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev scan [path] [options]
            \\
            \\Scan filesystem for reclaimable space.
            \\
            \\Options:
            \\  -c, --category <cat>  Filter by category (dev, system, package, ai, browser)
            \\  -h, --help            Show this help
            \\
            \\If no path is given, scans $HOME.
            \\
        , .{});
        return;
    }

    var category: ?evi.rules.Category = null;
    if (res.args.category) |cat_str| {
        category = parseCategory(cat_str) orelse {
            try stderr.print("error: unknown category '{s}'. Use: dev, system, package, ai, browser\n", .{cat_str});
            return;
        };
    }

    const target_path: []const u8 = res.positionals[0] orelse home;
    const width = evi.ui.getTerminalWidth();

    var results = try evi.scanner.scan(arena, io, target_path, .{
        .category = category,
        .home = home,
        .progress_writer = progressWriter(io, stderr),
    });
    defer results.deinit(arena);

    if (results.items.len == 0) {
        try stdout.print("\nNo reclaimable items found.\n", .{});
        return;
    }

    try evi.ui.printHeader(stdout, width);

    var total_size: u64 = 0;
    for (results.items) |result| {
        total_size += result.size;
        try evi.ui.printResult(
            stdout,
            width,
            result.rule.category,
            result.rule.risk,
            result.size,
            result.path,
        );
    }

    try evi.ui.printTotal(stdout, width, results.items.len, total_size);
}

fn cmdClean(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    home: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    stdout_writer: *Io.File.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\--dry-run              Show what would be deleted without deleting
        \\--force                Delete without interactive confirmation
        \\--dev                  Only dev artifacts (node_modules, target/, etc.)
        \\--system               Only system caches
        \\--package              Only package manager caches
        \\--ai                   Only AI/ML model caches
        \\--browser              Only browser caches
        \\-c, --category <str>   Filter by category name
        \\-h, --help             Show this help
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev clean [options]
            \\
            \\Clean reclaimable items from your system.
            \\
            \\Options:
            \\  --dry-run             Show what would be deleted without deleting
            \\  --force               Delete without interactive confirmation
            \\  --dev                 Only dev artifacts (node_modules, target/, etc.)
            \\  --system              Only system caches
            \\  --package             Only package manager caches
            \\  --ai                  Only AI/ML model caches
            \\  --browser             Only browser caches
            \\  -c, --category <cat>  Filter by category name
            \\  -h, --help            Show this help
            \\
            \\Default: interactive selection mode.
            \\
        , .{});
        return;
    }

    var mode: ?evi.cleaner.CleanMode = null;
    if (res.args.@"dry-run" != 0) mode = .dry_run;
    if (res.args.force != 0) mode = .force;

    var category: ?evi.rules.Category = null;
    if (res.args.dev != 0) category = .dev;
    if (res.args.system != 0) category = .system;
    if (res.args.package != 0) category = .package;
    if (res.args.ai != 0) category = .ai;
    if (res.args.browser != 0) category = .browser;
    if (res.args.category) |cat_str| {
        category = parseCategory(cat_str) orelse {
            try stderr.print("error: unknown category '{s}'\n", .{cat_str});
            return;
        };
    }

    const width = evi.ui.getTerminalWidth();

    var cfg = try evi.config.Config.load(arena, io, home);
    defer cfg.deinit();

    var results = try evi.scanner.scan(arena, io, home, .{
        .category = category,
        .home = home,
        .progress_writer = progressWriter(io, stderr),
    });
    defer results.deinit(arena);

    if (results.items.len == 0) {
        try stdout.print("\nNo reclaimable items found.\n", .{});
        return;
    }

    var log = evi.logger.Logger.init(io, home, arena);
    defer log.deinit();

    if (mode) |m| switch (m) {
        .dry_run => {
            try stdout.print("\n{s}{s}Dry run - nothing will be deleted:{s}\n\n", .{
                evi.ui.Color.bold, evi.ui.Color.yellow, evi.ui.Color.reset,
            });
            var total_size: u64 = 0;
            for (results.items) |result| {
                if (!cfg.isWhitelisted(result.path)) {
                    total_size += result.size;
                    try evi.ui.printDryRunResult(stdout, result.rule.category, result.size, result.path);
                }
            }
            var size_buf: [32]u8 = undefined;
            try stdout.print("\n  Total: {s}\n\n", .{evi.ui.formatSize(&size_buf, total_size)});
            return;
        },
        .force => {
            var tracker: evi.progress.Tracker = .{ .total = results.items.len };
            var ticker: ?evi.progress.Ticker = null;
            if (progressWriter(io, stderr)) |pw| {
                ticker = evi.progress.Ticker.init(io, pw, &tracker, "Deleting", "items");
                ticker.?.items_verb = "freed";
                ticker.?.begin();
            }
            const clean_result = evi.cleaner.clean(io, results.items, null, .force, &cfg, &log, &tracker);
            if (ticker) |*t| t.end();
            try evi.ui.printCleanSummary(stdout, width, clean_result.deleted_count, clean_result.deleted_size, clean_result.skipped_count, clean_result.error_count);
            return;
        },
    };

    // check if stdin is a TTY
    const stdin_file = Io.File.stdin();
    if (!(try stdin_file.isTty(io))) {
        try stderr.print("error: stdin is not a terminal. Use --force or --dry-run for non-interactive mode.\n", .{});
        return;
    }

    // TUI
    var selection = try evi.tui.SelectionList.init(arena, results.items, 20);
    defer selection.deinit();

    // flush stdout before entering raw mode
    try stdout.flush();

    const confirmed = selection.run(io, posix.STDIN_FILENO, stdout_writer) catch |err| {
        if (err == error.NotATty) {
            try stderr.print("error: stdin is not a terminal. Use --force or --dry-run.\n", .{});
            return;
        }
        return err;
    };

    if (!confirmed) {
        try stdout.print("\nCancelled.\n", .{});
        return;
    }

    const selected_indices = try selection.getSelected(arena);
    defer arena.free(selected_indices);

    if (selected_indices.len == 0) {
        try stdout.print("\nNo items selected.\n", .{});
        return;
    }

    var clean_result: evi.cleaner.CleanResult = .{};
    {
        var tracker: evi.progress.Tracker = .{ .total = selected_indices.len };
        var ticker: ?evi.progress.Ticker = null;
        if (progressWriter(io, stderr)) |pw| {
            ticker = evi.progress.Ticker.init(io, pw, &tracker, "Deleting", "items");
            ticker.?.items_verb = "freed";
            ticker.?.begin();
        }
        defer if (ticker) |*t| t.end();

        for (selected_indices) |idx| {
            if (idx >= results.items.len) continue;
            evi.cleaner.cleanItem(io, results.items[idx], .force, &cfg, &log, &clean_result, &tracker);
        }
    }

    if (clean_result.deleted_count > 0) {
        log.logSummary(clean_result.deleted_count, clean_result.deleted_size);
    }

    try evi.ui.printCleanSummary(stdout, width, clean_result.deleted_count, clean_result.deleted_size, clean_result.skipped_count, clean_result.error_count);
}

fn cmdPurge(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    home: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    stdout_writer: *Io.File.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\--depth <usize>    Maximum scan depth (default: 10)
        \\--dry-run          Show what would be deleted
        \\--force            Delete without confirmation
        \\-h, --help         Show this help
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev purge <path> [options]
            \\
            \\Find projects and clean their build artifacts.
            \\
            \\Options:
            \\  --depth N     Maximum scan depth (default: 10)
            \\  --dry-run     Show what would be deleted
            \\  --force       Delete without confirmation
            \\  -h, --help    Show this help
            \\
        , .{});
        return;
    }

    const target = res.positionals[0] orelse {
        try stderr.print("error: ev purge requires a path argument\n", .{});
        try stderr.print("Usage: ev purge <path> [--depth N] [--dry-run] [--force]\n", .{});
        return;
    };

    const max_depth: u32 = if (res.args.depth) |d| @intCast(d) else 10;

    var mode: ?evi.cleaner.CleanMode = null;
    if (res.args.@"dry-run" != 0) mode = .dry_run;
    if (res.args.force != 0) mode = .force;

    const width = evi.ui.getTerminalWidth();

    var cfg = try evi.config.Config.load(arena, io, home);
    defer cfg.deinit();

    // scan (purge mode = marker_file rules only)
    try stderr.print("Scanning {s} for project build artifacts...\n", .{target});
    try stderr.flush();

    var results = try evi.scanner.purgeScan(arena, io, target, .{
        .max_depth = max_depth,
        .home = home,
    });
    defer results.deinit(arena);

    if (results.items.len == 0) {
        try stdout.print("\nNo build artifacts found.\n", .{});
        return;
    }

    var log = evi.logger.Logger.init(io, home, arena);
    defer log.deinit();

    if (mode) |m| switch (m) {
        .dry_run => {
            try stdout.print("\n{s}{s}Dry run - nothing will be deleted:{s}\n\n", .{
                evi.ui.Color.bold, evi.ui.Color.yellow, evi.ui.Color.reset,
            });
            var total_size: u64 = 0;
            for (results.items) |result| {
                if (!cfg.isWhitelisted(result.path)) {
                    total_size += result.size;
                    try evi.ui.printDryRunResult(stdout, result.rule.category, result.size, result.path);
                }
            }
            var size_buf: [32]u8 = undefined;
            try stdout.print("\n  Total: {s}\n\n", .{evi.ui.formatSize(&size_buf, total_size)});
            return;
        },
        .force => {
            var tracker: evi.progress.Tracker = .{ .total = results.items.len };
            var ticker: ?evi.progress.Ticker = null;
            if (progressWriter(io, stderr)) |pw| {
                ticker = evi.progress.Ticker.init(io, pw, &tracker, "Deleting", "items");
                ticker.?.items_verb = "freed";
                ticker.?.begin();
            }
            const clean_result = evi.cleaner.clean(io, results.items, null, .force, &cfg, &log, &tracker);
            if (ticker) |*t| t.end();
            try evi.ui.printCleanSummary(stdout, width, clean_result.deleted_count, clean_result.deleted_size, clean_result.skipped_count, clean_result.error_count);
            return;
        },
    };

    const stdin_file = Io.File.stdin();
    if (!(try stdin_file.isTty(io))) {
        try stderr.print("error: stdin is not a terminal. Use --force or --dry-run.\n", .{});
        return;
    }

    var selection = try evi.tui.SelectionList.init(arena, results.items, 20);
    defer selection.deinit();

    try stdout.flush();

    const confirmed = selection.run(io, posix.STDIN_FILENO, stdout_writer) catch |err| {
        if (err == error.NotATty) {
            try stderr.print("error: stdin is not a terminal. Use --force or --dry-run.\n", .{});
            return;
        }
        return err;
    };

    if (!confirmed) {
        try stdout.print("\nCancelled.\n", .{});
        return;
    }

    const selected_indices = try selection.getSelected(arena);
    defer arena.free(selected_indices);

    if (selected_indices.len == 0) {
        try stdout.print("\nNo items selected.\n", .{});
        return;
    }

    var clean_result: evi.cleaner.CleanResult = .{};
    {
        var tracker: evi.progress.Tracker = .{ .total = selected_indices.len };
        var ticker: ?evi.progress.Ticker = null;
        if (progressWriter(io, stderr)) |pw| {
            ticker = evi.progress.Ticker.init(io, pw, &tracker, "Deleting", "items");
            ticker.?.items_verb = "freed";
            ticker.?.begin();
        }
        defer if (ticker) |*t| t.end();

        for (selected_indices) |idx| {
            if (idx >= results.items.len) continue;
            evi.cleaner.cleanItem(io, results.items[idx], .force, &cfg, &log, &clean_result, &tracker);
        }
    }

    if (clean_result.deleted_count > 0) {
        log.logSummary(clean_result.deleted_count, clean_result.deleted_size);
    }

    try evi.ui.printCleanSummary(stdout, width, clean_result.deleted_count, clean_result.deleted_size, clean_result.skipped_count, clean_result.error_count);
}

fn cmdAnalyze(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    home: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\--depth <usize>    Scan depth for category analysis (default: 3)
        \\--top <usize>      Number of top directories to show (default: 15)
        \\-h, --help         Show this help
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev analyze [path] [options]
            \\
            \\Analyze disk usage and show top directories by size.
            \\
            \\Options:
            \\  --depth N     Scan depth for category analysis (default: 3)
            \\  --top N       Number of top directories to show (default: 15)
            \\  -h, --help    Show this help
            \\
            \\If no path is given, analyzes $HOME.
            \\
        , .{});
        return;
    }

    const target = res.positionals[0] orelse home;
    const max_depth: u32 = if (res.args.depth) |d| @intCast(d) else 3;
    const top_n: usize = res.args.top orelse 15;
    const width = evi.ui.getTerminalWidth();

    const report = try evi.analyzer.analyze(arena, io, target, .{
        .max_depth = max_depth,
        .top_n = top_n,
        .home = home,
        .progress_writer = progressWriter(io, stderr),
    });

    try evi.analyzer.printReport(stdout, target, report, width);
}

fn cmdStatus(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev status
            \\
            \\Show system dashboard (CPU, RAM, disk, network).
            \\
            \\Options:
            \\  -h, --help  Show this help
            \\
        , .{});
        return;
    }

    const width = evi.ui.getTerminalWidth();

    var tracker: evi.progress.Tracker = .{};
    var ticker: ?evi.progress.Ticker = null;
    if (progressWriter(io, stderr)) |pw| {
        ticker = evi.progress.Ticker.init(io, pw, &tracker, "Collecting system info", "");
        ticker.?.begin();
    }

    const info = evi.platform.impl.getSystemInfo(arena, io);
    if (ticker) |*t| t.end();

    try evi.monitor.renderDashboard(stdout, try info, width);
}

fn cmdConfig(
    arena: std.mem.Allocator,
    io: Io,
    iter: anytype,
    home: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help
        \\<str>
        \\<str>
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.report(stderr, err);
        return;
    };
    _ = &res;

    if (res.args.help != 0) {
        try stdout.print(
            \\Usage: ev config <subcommand>
            \\
            \\Subcommands:
            \\  show                  Show current configuration
            \\  whitelist <path>      Add a path to the whitelist
            \\
        , .{});
        return;
    }

    const sub = res.positionals[0] orelse {
        try stdout.print(
            \\Usage: ev config <subcommand>
            \\
            \\Subcommands:
            \\  show                  Show current configuration
            \\  whitelist <path>      Add a path to the whitelist
            \\
        , .{});
        return;
    };

    if (std.mem.eql(u8, sub, "show")) {
        var cfg = try evi.config.Config.load(arena, io, home);
        defer cfg.deinit();

        const config_dir = try std.fs.path.join(arena, &.{ home, ".config", "evi" });

        try stdout.print("\n{s}{s}evi configuration{s}\n", .{ evi.ui.Color.bold, evi.ui.Color.cyan, evi.ui.Color.reset });
        try stdout.print("Config dir: {s}\n\n", .{config_dir});

        if (cfg.whitelist.items.len == 0) {
            try stdout.print("Whitelist: {s}(empty){s}\n", .{ evi.ui.Color.dim, evi.ui.Color.reset });
        } else {
            try stdout.print("Whitelist ({d} entries):\n", .{cfg.whitelist.items.len});
            for (cfg.whitelist.items) |entry| {
                try stdout.print("  {s}\n", .{entry});
            }
        }
        try stdout.print("\n", .{});
    } else if (std.mem.eql(u8, sub, "whitelist")) {
        const path: []const u8 = res.positionals[1] orelse {
            try stderr.print("error: ev config whitelist requires a path argument\n", .{});
            return;
        };

        var cfg = try evi.config.Config.load(arena, io, home);
        defer cfg.deinit();

        if (cfg.isWhitelisted(path)) {
            try stdout.print("Path already whitelisted: {s}\n", .{path});
            return;
        }

        try cfg.addWhitelist(path);
        try cfg.save(io, home);

        try stdout.print("{s}Added to whitelist:{s} {s}\n", .{ evi.ui.Color.green, evi.ui.Color.reset, path });
    } else {
        try stderr.print("Unknown config subcommand: {s}\n", .{sub});
        try stderr.print("Use: ev config show | ev config whitelist <path>\n", .{});
    }
}

fn parseCategory(s: []const u8) ?evi.rules.Category {
    const categories = .{
        .{ "dev", evi.rules.Category.dev },
        .{ "system", evi.rules.Category.system },
        .{ "package", evi.rules.Category.package },
        .{ "ai", evi.rules.Category.ai },
        .{ "browser", evi.rules.Category.browser },
    };
    inline for (categories) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return null;
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.print(
        \\Usage: ev <command> [options]
        \\
        \\Commands:
        \\  scan [path]           Scan for reclaimable space
        \\  clean [options]       Clean selected items (interactive by default)
        \\  purge <path>          Find projects and clean build artifacts
        \\  analyze [path]        Disk usage analysis with category breakdown
        \\  status                System dashboard (CPU, RAM, disk, network)
        \\  config <subcommand>   Configuration management
        \\
        \\Options:
        \\  -h, --help            Show this help
        \\  -v, --version         Show version
        \\
        \\Examples:
        \\  ev scan                       Scan home directory
        \\  ev clean --dry-run            Preview what would be deleted
        \\  ev clean --force --dev        Force-delete dev artifacts
        \\  ev clean                      Interactive selection mode
        \\  ev purge ~/projects           Clean build artifacts in projects
        \\  ev analyze ~                  Top directories + category breakdown
        \\  ev status                     System resource dashboard
        \\  ev config whitelist /path     Whitelist a path from cleaning
        \\
    , .{});
}
