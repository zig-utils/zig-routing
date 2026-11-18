//! The zr command line.

const std = @import("std");

pub const bench = @import("bench.zig");
pub const diff = @import("diff.zig");
pub const dem = @import("dem.zig");

test {
    std.testing.refAllDecls(@This());
}
