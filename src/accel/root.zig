//! Acceleration: nested-dissection order, customizable hierarchy, potentials (new).

const std = @import("std");

pub const partition = @import("partition.zig");

test {
    _ = @import("partition_test.zig");
    std.testing.refAllDecls(@This());
}
