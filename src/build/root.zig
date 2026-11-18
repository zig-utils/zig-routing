//! OSM to graph build pipeline (replaces Valhalla mjolnir).

const std = @import("std");

pub const osm = @import("osm.zig");
pub const osmxml = @import("osmxml.zig");

test {
    std.testing.refAllDecls(@This());
}
