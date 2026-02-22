const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("evi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const clap_dep = b.dependency("clap", .{});
    const clap_mod = clap_dep.module("clap");

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "ev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "evi", .module = mod },
                .{ .name = "clap", .module = clap_mod },
                .{ .name = "build_options", .module = version_options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const release_step = b.step("release", "Build release binaries for all targets");

    const release_targets = [_]struct {
        query: std.Target.Query,
        name: []const u8,
    }{
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }, .name = "x86_64-linux" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, .name = "aarch64-linux" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .freebsd }, .name = "x86_64-freebsd" },
    };

    for (release_targets) |rt| {
        const resolved = b.resolveTargetQuery(rt.query);

        const release_evi_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
        });

        const release_exe = b.addExecutable(.{
            .name = "ev",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "evi", .module = release_evi_mod },
                    .{ .name = "clap", .module = clap_mod },
                    .{ .name = "build_options", .module = version_options.createModule() },
                },
            }),
        });

        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{rt.name}) } },
        });
        release_step.dependOn(&install.step);
    }
}
