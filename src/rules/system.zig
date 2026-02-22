const Rule = @import("../rules.zig").Rule;

pub const rules = [_]Rule{
    .{
        .name = "user-cache",
        .description = "User cache directory (~/.cache)",
        .category = .system,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.cache" },
    },
    .{
        .name = "thumbnails",
        .description = "Thumbnail cache",
        .category = .system,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/thumbnails" },
    },
    .{
        .name = "fontconfig",
        .description = "Font configuration cache",
        .category = .system,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/fontconfig" },
    },
    .{
        .name = "mesa-shader-cache",
        .description = "Mesa GPU shader cache",
        .category = .system,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/mesa_shader_cache" },
    },
    .{
        .name = "trash",
        .description = "Desktop trash / recycle bin",
        .category = .system,
        .risk = .moderate,
        .detection = .{ .path_prefix = "~/.local/share/Trash" },
    },
    .{
        .name = "journald-user",
        .description = "User systemd journal logs",
        .category = .system,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.local/share/systemd" },
    },
    .{
        .name = "recently-used",
        .description = "Recently used files metadata",
        .category = .system,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.local/share/recently-used.xbel" },
    },
};
