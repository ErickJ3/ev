const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const name = "FreeBSD";

pub const skip_dirs = [_][]const u8{
    "/proc",
    "/dev",
    "/var/run",
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

pub fn getSystemInfo(allocator: Allocator, io: Io) !SystemInfo {
    return .{
        .cpu_model = sysctlString(allocator, io, "hw.model"),
        .cpu_cores = sysctlU32(allocator, io, "hw.ncpu"),
        .cpu_usage_percent = 0.0,
        .load_avg = .{ 0.0, 0.0, 0.0 },
        .mem_total = sysctlU64(allocator, io, "hw.physmem"),
        .mem_available = 0,
        .swap_total = 0,
        .swap_free = 0,
        .uptime_seconds = 0,
        .os_version = blk: {
            const r = runCommand(allocator, io, &.{ "uname", "-r" }) catch break :blk "FreeBSD";
            break :blk std.mem.trim(u8, r, &std.ascii.whitespace);
        },
        .filesystems = &.{},
        .interfaces = &.{},
        .top_processes = &.{},
        .service_count = readServiceCount(allocator, io),
        .service_manager = "rc",
        .package_count = readPackageCount(allocator, io),
        .package_manager = "pkg",
    };
}

pub const DiskUsage = struct {
    total: u64,
    used: u64,
    available: u64,
};

/// Disk usage of the filesystem containing `path`, via POSIX `df -P -k`.
/// Returns null on any failure.
pub fn diskUsage(allocator: Allocator, io: Io, path: []const u8) ?DiskUsage {
    const result = runCommand(allocator, io, &.{ "df", "-P", "-k", path }) catch return null;
    defer allocator.free(result);

    var lines = std.mem.splitScalar(u8, result, '\n');
    _ = lines.next(); // header
    const line = lines.next() orelse return null;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    _ = tokens.next(); // filesystem name
    const total_kb = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    const used_kb = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    const avail_kb = std.fmt.parseInt(u64, tokens.next() orelse return null, 10) catch return null;
    return .{ .total = total_kb * 1024, .used = used_kb * 1024, .available = avail_kb * 1024 };
}

fn sysctlString(allocator: Allocator, io: Io, oid: []const u8) []const u8 {
    const result = runCommand(allocator, io, &.{ "sysctl", "-n", oid }) catch return "Unknown";
    return std.mem.trim(u8, result, &std.ascii.whitespace);
}

fn sysctlU32(allocator: Allocator, io: Io, oid: []const u8) u32 {
    const result = runCommand(allocator, io, &.{ "sysctl", "-n", oid }) catch return 0;
    defer allocator.free(result);
    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

fn sysctlU64(allocator: Allocator, io: Io, oid: []const u8) u64 {
    const result = runCommand(allocator, io, &.{ "sysctl", "-n", oid }) catch return 0;
    defer allocator.free(result);
    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

fn readServiceCount(allocator: Allocator, io: Io) u32 {
    const result = runCommand(allocator, io, &.{ "service", "-e" }) catch return 0;
    defer allocator.free(result);
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

fn readPackageCount(allocator: Allocator, io: Io) u32 {
    const result = runCommand(allocator, io, &.{ "pkg", "info" }) catch return 0;
    defer allocator.free(result);
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
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
