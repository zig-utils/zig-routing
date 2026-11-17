//! Geometry kernel: points, boxes, distances, polylines, cells (port of Valhalla midgard).

const std = @import("std");

pub const constants = @import("constants.zig");
pub const point = @import("point.zig");
pub const aabb = @import("aabb.zig");
pub const libm = @import("libm.zig");
pub const polyline = @import("polyline.zig");
pub const line = @import("line.zig");
pub const grid = @import("grid.zig");

pub const PointLL = point.PointLL;
pub const FixedLL = point.FixedLL;
pub const DistanceApproximator = point.DistanceApproximator;
pub const AABB = aabb.AABB;

test {
    std.testing.refAllDecls(@This());
}
