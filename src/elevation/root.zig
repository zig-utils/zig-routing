//! DEM sampling for /height and graph grades (port of Valhalla skadi).

const std = @import("std");
const PointLL = @import("../geo/point.zig").PointLL;

pub const hgt = @import("hgt.zig");
pub const @"packed" = @import("packed.zig");

/// Where elevation comes from: loose .hgt tiles (upstream's layout) or a
/// pack built by `zr dem pack`. Both sample identically.
pub const Source = union(enum) {
    tiles: *hgt.Tiles,
    pack: *const @"packed".Pack,

    pub fn get(self: Source, p: PointLL) f64 {
        return switch (self) {
            .tiles => |t| hgt.get(t, p),
            .pack => |pk| pk.get(p),
        };
    }

    pub fn getAll(self: Source, pts: []const PointLL, out: []f64) void {
        switch (self) {
            .tiles => |t| hgt.getAll(t, pts, out),
            .pack => |pk| pk.getAll(pts, out),
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
