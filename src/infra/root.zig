//! Shared runtime pieces: arenas, allocators, clocks and the IO shim.

const std = @import("std");

pub const io = @import("io.zig");
pub const arena = @import("arena.zig");
pub const config = @import("config.zig");

test {
    std.testing.refAllDecls(@This());
}
