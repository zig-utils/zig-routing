//! OSM to graph build pipeline (replaces Valhalla mjolnir).

const std = @import("std");

pub const driver = @import("driver.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const osm = @import("osm.zig");
pub const osmxml = @import("osmxml.zig");
pub const pbf = @import("pbf/root.zig");
pub const node_store = @import("node_store.zig");
pub const edges = @import("edges.zig");
pub const edge_class = @import("edge_class.zig");
pub const assemble = @import("assemble.zig");
pub const turns = @import("turns.zig");
pub const elevation = @import("elevation.zig");
pub const enhance = @import("enhance.zig");
pub const speeds = @import("speeds.zig");
pub const order = @import("order.zig");
pub const tags = @import("tags/root.zig");
pub const admin_boundaries = @import("admin_boundaries.zig");
pub const admin_tags = @import("admin_tags.zig");
pub const country_access = @import("country_access.zig");
pub const timezones = @import("timezones.zig");
pub const turn_restrictions = @import("turn_restrictions.zig");
pub const lanes = @import("lanes.zig");
pub const name_details = @import("name_details.zig");
pub const restriction_automaton = @import("restriction_automaton.zig");
pub const time_parsing = @import("time_parsing.zig");

test {
    std.testing.refAllDecls(@This());
}
