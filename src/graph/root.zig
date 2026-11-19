//! Native graph format, reader and attribute model (replaces Valhalla baldr tiles).

const std = @import("std");

pub const constants = @import("constants.zig");
pub const format = @import("format.zig");

test {
    std.testing.refAllDecls(@This());
}
