//! Costing models compiled from request options (port of Valhalla sif).

pub const compiled = @import("compiled.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
