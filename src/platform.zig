const builtin = @import("builtin");

pub const impl = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .freebsd => @import("platform/freebsd.zig"),
    else => @compileError("unsupported OS: only Linux and FreeBSD are supported"),
};
