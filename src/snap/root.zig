//! Location correlation: candidate search, projection, reachability (port of Valhalla loki).

pub const candidates = @import("search.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
