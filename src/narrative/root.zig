//! Maneuvers and instructions in every locale (port of Valhalla odin).

const std = @import("std");

pub const enhanced = @import("enhanced.zig");
pub const dictionary = @import("dictionary.zig");
pub const instructions = @import("instructions.zig");
pub const maneuver = @import("maneuver.zig");
pub const maneuvers = @import("maneuvers.zig");
pub const markup = @import("markup.zig");
pub const verbal_instructions = @import("verbal_instructions.zig");
pub const verbal_text = @import("verbal_text.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("enhanced_test.zig");
    _ = @import("maneuvers_test.zig");
}
