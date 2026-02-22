const Rule = @import("../rules.zig").Rule;

pub const rules = [_]Rule{
    .{
        .name = "chrome-cache",
        .description = "Google Chrome browser cache",
        .category = .browser,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/google-chrome" },
    },
    .{
        .name = "chromium-cache",
        .description = "Chromium browser cache",
        .category = .browser,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/chromium" },
    },
    .{
        .name = "firefox-cache",
        .description = "Firefox browser cache",
        .category = .browser,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/mozilla/firefox" },
    },
    .{
        .name = "brave-cache",
        .description = "Brave browser cache",
        .category = .browser,
        .risk = .safe,
        .detection = .{ .path_prefix = "~/.cache/BraveSoftware" },
    },
};
