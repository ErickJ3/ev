const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const name = "Linux";

pub const skip_dirs = [_][]const u8{
    "/proc",
    "/sys",
    "/dev",
    "/run",
    "/snap",
    "/lost+found",
};

pub fn isSkipDir(path: []const u8) bool {
    for (&skip_dirs) |skip| {
        if (std.mem.eql(u8, path, skip)) return true;
        if (std.mem.startsWith(u8, path, skip) and
            path.len > skip.len and path[skip.len] == '/')
            return true;
    }
    return false;
}

pub const FilesystemInfo = struct {
    mount_point: []const u8,
    fs_type: []const u8,
    total: u64,
    used: u64,
    available: u64,
};

pub const NetworkInfo = struct {
    iface_name: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
};

pub const ProcessInfo = struct {
    pid: u32,
    proc_name: []const u8,
    mem_rss: u64,
};

pub const SystemInfo = struct {
    cpu_model: []const u8,
    cpu_cores: u32,
    cpu_usage_percent: f64,
    load_avg: [3]f64,
    mem_total: u64,
    mem_available: u64,
    swap_total: u64,
    swap_free: u64,
    uptime_seconds: u64,
    os_version: []const u8,
    filesystems: []const FilesystemInfo,
    interfaces: []const NetworkInfo,
    top_processes: []const ProcessInfo,
    service_count: u32,
    service_manager: []const u8,
    package_count: u32,
    package_manager: []const u8,
};

/// Shared state for parallel system info gathering.
/// Each field is written by exactly one thread, so no mutex needed.
/// Workers allocate ONLY from their own arena (the caller's arena is not
/// thread-safe); the caller deep-copies results out after joining.
const AsyncSystemInfo = struct {
    // Written by thread 1 (CPU usage - 250ms sample window)
    cpu_usage_percent: f64 = 0.0,
    // Written by thread 2 (process enumeration - reads many /proc/PID/status files)
    top_processes: []const ProcessInfo = &.{},
    // Written by thread 3 (subprocesses: df, systemctl, packages)
    filesystems: []const FilesystemInfo = &.{},
    service_count: u32 = 0,
    pkg_info: PackageInfo = .{ .count = 0, .manager = "unknown" },
};

fn cpuUsageWorker(arena: *std.heap.ArenaAllocator, io: Io, out: *AsyncSystemInfo) void {
    out.cpu_usage_percent = readCpuUsage(arena.allocator(), io);
}

fn processWorker(arena: *std.heap.ArenaAllocator, io: Io, out: *AsyncSystemInfo) void {
    out.top_processes = readTopProcesses(arena.allocator(), io);
}

fn subprocessWorker(arena: *std.heap.ArenaAllocator, io: Io, out: *AsyncSystemInfo) void {
    const allocator = arena.allocator();
    out.filesystems = readFilesystems(allocator, io);
    out.service_count = readServiceCount(allocator, io);
    out.pkg_info = readPackageInfo(allocator, io);
}

pub fn getSystemInfo(allocator: Allocator, io: Io) !SystemInfo {
    // Fast /proc reads on main thread (< 1ms each)
    const cpu_info = readCpuInfo(allocator, io);
    const mem_info = readMemInfo(allocator, io);

    // Spawn threads for slow operations, each with its own arena
    var async_info: AsyncSystemInfo = .{};

    var worker_arenas: [3]std.heap.ArenaAllocator = .{
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer for (&worker_arenas) |*a| a.deinit();

    const t1 = std.Thread.spawn(.{}, cpuUsageWorker, .{ &worker_arenas[0], io, &async_info }) catch null;
    const t2 = std.Thread.spawn(.{}, processWorker, .{ &worker_arenas[1], io, &async_info }) catch null;
    const t3 = std.Thread.spawn(.{}, subprocessWorker, .{ &worker_arenas[2], io, &async_info }) catch null;

    // Main thread does remaining fast /proc reads while workers run
    const load_avg = readLoadAvg(allocator, io);
    const uptime = readUptime(allocator, io);
    const os_version = readOsVersion(allocator, io);
    const interfaces = readNetworkInterfaces(allocator, io);

    // Wait for workers; on spawn failure run inline so the dashboard still has data
    if (t1) |t| t.join() else cpuUsageWorker(&worker_arenas[0], io, &async_info);
    if (t2) |t| t.join() else processWorker(&worker_arenas[1], io, &async_info);
    if (t3) |t| t.join() else subprocessWorker(&worker_arenas[2], io, &async_info);

    // Deep-copy worker results into the caller's arena before the worker
    // arenas are torn down. pkg_info.manager is always a static string.
    const top_processes = blk: {
        const copy = allocator.alloc(ProcessInfo, async_info.top_processes.len) catch break :blk &[_]ProcessInfo{};
        for (copy, async_info.top_processes) |*dst, src| {
            dst.* = .{
                .pid = src.pid,
                .proc_name = allocator.dupe(u8, src.proc_name) catch "?",
                .mem_rss = src.mem_rss,
            };
        }
        break :blk copy;
    };

    const filesystems = blk: {
        const copy = allocator.alloc(FilesystemInfo, async_info.filesystems.len) catch break :blk &[_]FilesystemInfo{};
        for (copy, async_info.filesystems) |*dst, src| {
            dst.* = .{
                .mount_point = allocator.dupe(u8, src.mount_point) catch "?",
                .fs_type = allocator.dupe(u8, src.fs_type) catch "?",
                .total = src.total,
                .used = src.used,
                .available = src.available,
            };
        }
        break :blk copy;
    };

    return .{
        .cpu_model = cpu_info.model,
        .cpu_cores = cpu_info.cores,
        .cpu_usage_percent = async_info.cpu_usage_percent,
        .load_avg = load_avg,
        .mem_total = mem_info.total,
        .mem_available = mem_info.available,
        .swap_total = mem_info.swap_total,
        .swap_free = mem_info.swap_free,
        .uptime_seconds = uptime,
        .os_version = os_version,
        .filesystems = filesystems,
        .interfaces = interfaces,
        .top_processes = top_processes,
        .service_count = async_info.service_count,
        .service_manager = "systemd",
        .package_count = async_info.pkg_info.count,
        .package_manager = async_info.pkg_info.manager,
    };
}

fn readFileContents(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    var file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const fd = file.handle;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        var buf: [8192]u8 = undefined;
        const n = try std.posix.read(fd, &buf);
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
        if (n < buf.len) break;
    }
    return try result.toOwnedSlice(allocator);
}

const CpuInfo = struct { model: []const u8, cores: u32 };

/// Read /proc/cpuinfo once and extract both CPU model and core count.
fn readCpuInfo(allocator: Allocator, io: Io) CpuInfo {
    const contents = readFileContents(io, allocator, "/proc/cpuinfo") catch return .{ .model = "Unknown", .cores = 0 };
    defer allocator.free(contents);

    var model: []const u8 = "Unknown";
    var cores: u32 = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "processor")) {
            cores += 1;
        } else if (std.mem.eql(u8, model, "Unknown") and std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOf(u8, line, ": ")) |idx| {
                model = allocator.dupe(u8, std.mem.trim(u8, line[idx + 2 ..], &std.ascii.whitespace)) catch "Unknown";
            }
        }
    }
    return .{ .model = model, .cores = cores };
}

fn readCpuUsage(allocator: Allocator, io: Io) f64 {
    const sample1 = readCpuSample(allocator, io) orelse return 0.0;
    // Honest sample window; runs concurrently with the subprocess worker,
    // so it rarely extends total wall time.
    io.sleep(.fromMilliseconds(250), .awake) catch {};
    const sample2 = readCpuSample(allocator, io) orelse return 0.0;

    const idle_delta = sample2.idle -| sample1.idle;
    const total_delta = sample2.total -| sample1.total;
    if (total_delta == 0) return 0.0;
    return (1.0 - @as(f64, @floatFromInt(idle_delta)) / @as(f64, @floatFromInt(total_delta))) * 100.0;
}

const CpuSample = struct { idle: u64, total: u64 };

fn readCpuSample(allocator: Allocator, io: Io) ?CpuSample {
    const contents = readFileContents(io, allocator, "/proc/stat") catch return null;
    defer allocator.free(contents);
    // First line: cpu  user nice system idle iowait irq softirq steal
    const first_line = if (std.mem.indexOf(u8, contents, "\n")) |nl| contents[0..nl] else contents;
    var tokens = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = tokens.next(); // skip "cpu"
    var total: u64 = 0;
    var idle: u64 = 0;
    var col: usize = 0;
    while (tokens.next()) |tok| {
        const val = std.fmt.parseInt(u64, tok, 10) catch continue;
        total += val;
        if (col == 3) idle = val; // 4th field is idle
        col += 1;
    }
    return .{ .idle = idle, .total = total };
}

fn readLoadAvg(allocator: Allocator, io: Io) [3]f64 {
    const contents = readFileContents(io, allocator, "/proc/loadavg") catch return .{ 0.0, 0.0, 0.0 };
    defer allocator.free(contents);
    var tokens = std.mem.tokenizeScalar(u8, contents, ' ');
    var result: [3]f64 = .{ 0.0, 0.0, 0.0 };
    for (0..3) |i| {
        const tok = tokens.next() orelse break;
        result[i] = std.fmt.parseFloat(f64, tok) catch 0.0;
    }
    return result;
}

const MemInfo = struct { total: u64, available: u64, swap_total: u64, swap_free: u64 };

/// Read /proc/meminfo once and extract all 4 memory fields.
fn readMemInfo(allocator: Allocator, io: Io) MemInfo {
    const contents = readFileContents(io, allocator, "/proc/meminfo") catch return .{ .total = 0, .available = 0, .swap_total = 0, .swap_free = 0 };
    defer allocator.free(contents);

    var result: MemInfo = .{ .total = 0, .available = 0, .swap_total = 0, .swap_free = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (parseMemLine(line, "MemTotal:")) |v| {
            result.total = v;
        } else if (parseMemLine(line, "MemAvailable:")) |v| {
            result.available = v;
        } else if (parseMemLine(line, "SwapTotal:")) |v| {
            result.swap_total = v;
        } else if (parseMemLine(line, "SwapFree:")) |v| {
            result.swap_free = v;
        }
    }
    return result;
}

fn parseMemLine(line: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
    var tokens = std.mem.tokenizeScalar(u8, rest, ' ');
    const val_str = tokens.next() orelse return null;
    const kb = std.fmt.parseInt(u64, val_str, 10) catch return null;
    return kb * 1024; // kB to bytes
}

fn readUptime(allocator: Allocator, io: Io) u64 {
    const contents = readFileContents(io, allocator, "/proc/uptime") catch return 0;
    defer allocator.free(contents);
    var tokens = std.mem.tokenizeScalar(u8, contents, ' ');
    const tok = tokens.next() orelse return 0;
    const dot_pos = std.mem.indexOf(u8, tok, ".") orelse tok.len;
    return std.fmt.parseInt(u64, tok[0..dot_pos], 10) catch 0;
}

fn readOsVersion(allocator: Allocator, io: Io) []const u8 {
    const contents = readFileContents(io, allocator, "/proc/version") catch return "Linux";
    defer allocator.free(contents);
    var tokens = std.mem.tokenizeScalar(u8, contents, ' ');
    const os_name = tokens.next() orelse return "Linux";
    _ = tokens.next(); // "version"
    const ver = tokens.next() orelse return "Linux";
    var buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{s} {s}", .{ os_name, ver }) catch return "Linux";
    return allocator.dupe(u8, formatted) catch "Linux";
}

fn readFilesystems(allocator: Allocator, io: Io) []const FilesystemInfo {
    const result = runCommand(allocator, io, &.{ "timeout", "5", "df", "-B1", "--output=target,fstype,size,used,avail" }) catch return &.{};
    defer allocator.free(result);

    var list: std.ArrayList(FilesystemInfo) = .empty;
    var lines = std.mem.splitScalar(u8, result, '\n');
    _ = lines.next(); // skip header

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const mount = tokens.next() orelse continue;
        const fs_type = tokens.next() orelse continue;
        const total_str = tokens.next() orelse continue;
        const used_str = tokens.next() orelse continue;
        const avail_str = tokens.next() orelse continue;

        if (!isRealFs(fs_type)) continue;

        list.append(allocator, .{
            .mount_point = allocator.dupe(u8, mount) catch continue,
            .fs_type = allocator.dupe(u8, fs_type) catch continue,
            .total = std.fmt.parseInt(u64, total_str, 10) catch continue,
            .used = std.fmt.parseInt(u64, used_str, 10) catch continue,
            .available = std.fmt.parseInt(u64, avail_str, 10) catch continue,
        }) catch continue;
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

pub const DiskUsage = struct {
    total: u64,
    used: u64,
    available: u64,
};

/// Disk usage of the filesystem containing `path`, via `df` (std has no
/// statfs wrapper). Returns null on any failure.
pub fn diskUsage(allocator: Allocator, io: Io, path: []const u8) ?DiskUsage {
    const result = runCommand(allocator, io, &.{ "timeout", "5", "df", "-B1", "--output=size,used,avail", path }) catch return null;
    defer allocator.free(result);

    var lines = std.mem.splitScalar(u8, result, '\n');
    _ = lines.next(); // header
    const line = lines.next() orelse return null;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const total = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    const used = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    const avail = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    return .{ .total = total, .used = used, .available = avail };
}

fn isRealFs(fs_type: []const u8) bool {
    const real_types = [_][]const u8{ "ext4", "ext3", "ext2", "btrfs", "xfs", "zfs", "ntfs", "vfat", "fat32", "tmpfs", "nfs", "nfs4" };
    for (&real_types) |t| {
        if (std.mem.eql(u8, fs_type, t)) return true;
    }
    return false;
}

fn readNetworkInterfaces(allocator: Allocator, io: Io) []const NetworkInfo {
    const contents = readFileContents(io, allocator, "/proc/net/dev") catch return &.{};
    defer allocator.free(contents);

    var list: std.ArrayList(NetworkInfo) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next(); // header 1
    _ = lines.next(); // header 2

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon_pos = std.mem.indexOf(u8, line, ":") orelse continue;
        const iface = std.mem.trim(u8, line[0..colon_pos], &std.ascii.whitespace);
        if (std.mem.eql(u8, iface, "lo")) continue;
        if (std.mem.startsWith(u8, iface, "veth")) continue;
        if (std.mem.startsWith(u8, iface, "br-")) continue;
        if (std.mem.startsWith(u8, iface, "docker")) continue;

        var tokens = std.mem.tokenizeScalar(u8, line[colon_pos + 1 ..], ' ');
        const rx_str = tokens.next() orelse continue;
        for (0..7) |_| _ = tokens.next();
        const tx_str = tokens.next() orelse continue;

        list.append(allocator, .{
            .iface_name = allocator.dupe(u8, iface) catch continue,
            .rx_bytes = std.fmt.parseInt(u64, rx_str, 10) catch 0,
            .tx_bytes = std.fmt.parseInt(u64, tx_str, 10) catch 0,
        }) catch continue;
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

fn readTopProcesses(allocator: Allocator, io: Io) []const ProcessInfo {
    var proc_dir = Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return &.{};
    defer proc_dir.close(io);

    const top_n = 10;
    var top: [top_n]ProcessInfo = undefined;
    var top_count: usize = 0;

    var iter = proc_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        var path_buf: [64]u8 = undefined;
        const status_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch continue;
        const info = readProcessStatus(allocator, io, pid, status_path) orelse continue;
        if (info.mem_rss < 1024 * 1024) continue; // Skip < 1MB

        // Bounded insertion: maintain top-N sorted by mem_rss descending
        if (top_count < top_n) {
            // Array not full yet, insert in sorted position
            var pos: usize = top_count;
            while (pos > 0 and top[pos - 1].mem_rss < info.mem_rss) : (pos -= 1) {
                top[pos] = top[pos - 1];
            }
            top[pos] = info;
            top_count += 1;
        } else if (info.mem_rss > top[top_count - 1].mem_rss) {
            // Replace the smallest (last) entry and re-insert in position
            var pos: usize = top_count - 1;
            while (pos > 0 and top[pos - 1].mem_rss < info.mem_rss) : (pos -= 1) {
                top[pos] = top[pos - 1];
            }
            top[pos] = info;
        }
    }

    const result = allocator.alloc(ProcessInfo, top_count) catch return &.{};
    @memcpy(result, top[0..top_count]);
    return result;
}

fn readProcessStatus(allocator: Allocator, io: Io, pid: u32, status_path: []const u8) ?ProcessInfo {
    const contents = readFileContents(io, allocator, status_path) catch return null;
    defer allocator.free(contents);

    var proc_name: []const u8 = "?";
    var rss_bytes: u64 = 0;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Name:")) {
            const val = std.mem.trim(u8, line["Name:".len..], &std.ascii.whitespace);
            proc_name = allocator.dupe(u8, val) catch "?";
        } else if (std.mem.startsWith(u8, line, "VmRSS:")) {
            const val = std.mem.trim(u8, line["VmRSS:".len..], &std.ascii.whitespace);
            var tokens = std.mem.tokenizeScalar(u8, val, ' ');
            const num_str = tokens.next() orelse continue;
            const kb = std.fmt.parseInt(u64, num_str, 10) catch continue;
            rss_bytes = kb * 1024;
        }
    }

    if (rss_bytes == 0) return null;

    return .{
        .pid = pid,
        .proc_name = proc_name,
        .mem_rss = rss_bytes,
    };
}

fn readServiceCount(allocator: Allocator, io: Io) u32 {
    const result = runCommand(allocator, io, &.{ "timeout", "5", "systemctl", "list-units", "--type=service", "--state=running", "--no-pager", "--no-legend" }) catch return 0;
    defer allocator.free(result);
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

const PackageInfo = struct { count: u32, manager: []const u8 };

/// Detect package manager and count in a single pass.
/// Each package manager command is run at most once.
fn readPackageInfo(allocator: Allocator, io: Io) PackageInfo {
    if (tryCommandLineCount(allocator, io, &.{ "rpm", "-qa" })) |c| {
        const manager: []const u8 = blk: {
            const dnf_result = runCommand(allocator, io, &.{ "timeout", "5", "dnf", "--version" }) catch break :blk "yum";
            allocator.free(dnf_result);
            break :blk "dnf";
        };
        return .{ .count = c, .manager = manager };
    }
    if (tryCommandLineCount(allocator, io, &.{ "dpkg-query", "-f", ".\n", "-W" })) |c|
        return .{ .count = c, .manager = "apt" };
    if (tryCommandLineCount(allocator, io, &.{ "pacman", "-Q" })) |c|
        return .{ .count = c, .manager = "pacman" };
    return .{ .count = 0, .manager = "unknown" };
}

fn tryCommandLineCount(allocator: Allocator, io: Io, argv: []const []const u8) ?u32 {
    const result = runCommand(allocator, io, argv) catch return null;
    defer allocator.free(result);
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    if (count == 0) return null;
    return count;
}

pub fn runCommand(allocator: Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
    });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.FileNotFound;
    }
    return result.stdout;
}

test "parseMemLine" {
    const val = parseMemLine("MemTotal:       16384000 kB", "MemTotal:");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u64, 16384000 * 1024), val.?);
}

test "parseMemLine no match" {
    const val = parseMemLine("SwapTotal:       8192000 kB", "MemTotal:");
    try std.testing.expect(val == null);
}

test "isRealFs" {
    try std.testing.expect(isRealFs("ext4"));
    try std.testing.expect(isRealFs("btrfs"));
    try std.testing.expect(!isRealFs("proc"));
    try std.testing.expect(!isRealFs("sysfs"));
}
