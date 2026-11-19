//! Native graph format, reader and attribute model (replaces Valhalla baldr tiles).

const std = @import("std");

pub const attributes = @import("attributes.zig");

test {
    std.testing.refAllDecls(@This());
}
