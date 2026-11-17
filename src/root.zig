//! zig-routing: a faithful, faster Zig port of the Valhalla routing engine.
//!
//! One module per area; the upstream Valhalla module each replaces is noted
//! in its root file. See docs/PLAN.md and AGENTS.md.

const std = @import("std");

pub const version = "0.0.0";

pub const infra = @import("infra/root.zig");
pub const geo = @import("geo/root.zig");
pub const graph = @import("graph/root.zig");
pub const costing = @import("costing/root.zig");
pub const snap = @import("snap/root.zig");
pub const search = @import("search/root.zig");
pub const accel = @import("accel/root.zig");
pub const match = @import("match/root.zig");
pub const narrative = @import("narrative/root.zig");
pub const api = @import("api/root.zig");
pub const elevation = @import("elevation/root.zig");
pub const build = @import("build/root.zig");
pub const server = @import("server/root.zig");
pub const traffic = @import("traffic/root.zig");
pub const tiles = @import("tiles/root.zig");
pub const geocode = @import("geocode/root.zig");
pub const cli = @import("cli/root.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version is set" {
    try std.testing.expect(version.len > 0);
}
