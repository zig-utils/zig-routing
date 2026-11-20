//! Maneuvers and instructions in every locale (port of Valhalla odin).

const std = @import("std");

pub const enhanced = @import("enhanced.zig");
pub const maneuver = @import("maneuver.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("enhanced_test.zig");
}
