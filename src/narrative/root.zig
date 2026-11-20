//! Maneuvers and instructions in every locale (port of Valhalla odin).

const std = @import("std");

pub const enhanced = @import("enhanced.zig");
pub const dictionary = @import("dictionary.zig");
pub const instructions = @import("instructions.zig");
pub const maneuver = @import("maneuver.zig");
pub const maneuvers = @import("maneuvers.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("enhanced_test.zig");
    _ = @import("maneuvers_test.zig");
}
