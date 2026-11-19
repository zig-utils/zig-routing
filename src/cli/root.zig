//! The zr command line.

const std = @import("std");

pub const bench = @import("bench.zig");
pub const diff = @import("diff.zig");
pub const dem = @import("dem.zig");
pub const tags = @import("tags.zig");
pub const inspect = @import("inspect.zig");
pub const import_valhalla = @import("import_valhalla.zig");
pub const parity_costing = @import("parity_costing.zig");

test {
    std.testing.refAllDecls(@This());
}
