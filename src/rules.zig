const std = @import("std");

pub const Category = enum {
    dev,
    system,
    package,
    ai,
    browser,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .dev => "Dev",
            .system => "System",
            .package => "Package",
            .ai => "AI/ML",
            .browser => "Browser",
        };
    }
};

pub const Risk = enum {
    safe,
    moderate,
    caution,

    pub fn label(self: Risk) []const u8 {
        return switch (self) {
            .safe => "Safe",
            .moderate => "Moderate",
            .caution => "Caution",
        };
    }
};

pub const DetectionType = union(enum) {
    dir_name: []const u8,
    marker_file: struct {
        marker: []const u8,
        targets: []const []const u8,
    },
    path_prefix: []const u8,
};

pub const Rule = struct {
    name: []const u8,
    description: []const u8,
    category: Category,
    risk: Risk,
    detection: DetectionType,
};

pub const dev = @import("rules/dev.zig");
pub const system = @import("rules/system.zig");
pub const package = @import("rules/package.zig");
pub const ai = @import("rules/ai.zig");
pub const browser = @import("rules/browser.zig");

pub const all_rules = dev.rules ++ system.rules ++ package.rules ++ ai.rules ++ browser.rules;

pub fn rulesForCategory(category: Category) []const Rule {
    return switch (category) {
        .dev => &dev.rules,
        .system => &system.rules,
        .package => &package.rules,
        .ai => &ai.rules,
        .browser => &browser.rules,
    };
}

test "all rules have non-empty names" {
    for (&all_rules) |rule| {
        try std.testing.expect(rule.name.len > 0);
        try std.testing.expect(rule.description.len > 0);
    }
}
