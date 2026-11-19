//! Path algorithms: the exact search core, matrices, isochrones (port of Valhalla thor).

pub const paged = @import("paged.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
