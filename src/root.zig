pub const rules = @import("rules.zig");
pub const scanner = @import("scanner.zig");
pub const cleaner = @import("cleaner.zig");
pub const config = @import("config.zig");
pub const ui = @import("ui.zig");
pub const platform = @import("platform.zig");
pub const logger = @import("logger.zig");
pub const tui = @import("tui.zig");
pub const analyzer = @import("analyzer.zig");
pub const monitor = @import("monitor.zig");
pub const progress = @import("progress.zig");

test {
    _ = progress;
    _ = rules;
    _ = scanner;
    _ = ui;
    _ = config;
    _ = logger;
    _ = cleaner;
    _ = tui;
    _ = analyzer;
    _ = monitor;
}
