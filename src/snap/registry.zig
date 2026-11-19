//! Select one regional graph snapshot for every snapped location in a route.
const std = @import("std");
const graph = @import("../graph/root.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const request = @import("../api/request.zig");
const errors = @import("../api/errors.zig");
const Arena = @import("../infra/arena.zig").Arena;
const Deadline = @import("../infra/io.zig").Deadline;
const candidates = @import("search.zig");
const location = @import("location.zig");
const View = graph.reader.View;

pub const Region = struct {
    name: []const u8,
    view: *const View,
    bounds: graph.format.Bounds,

    pub fn init(name: []const u8, view: *const View, deadline: Deadline) !Region {
        if (name.len == 0) return error.EmptyRegionName;
        if (view.coverage) |records| return .{ .name = name, .view = view, .bounds = records[0] };
        // Older bundle versions omitted coverage. Derive the bounds once at
        // registry setup from the available graph coordinates.
        var builder: graph.coverage.Builder = .{};
        try builder.add(view.coordinates orelse return error.MissingBundleCoverage, deadline);
        return .{ .name = name, .view = view, .bounds = builder.finish() orelse return error.MissingBundleCoverage };
    }
};

pub const Selection = struct {
    region: *const Region,
    locations: []const candidates.PathLocation,
};

pub const Result = union(enum) { ok: Selection, failure: errors.Failure };

/// Each request borrows one immutable registry and returns a borrow of the
/// selected region. The registry owner retains the views for that lifetime.
pub const Registry = struct {
    regions: []const Region,

    /// For overlapping regions, choose the first region in registry order
    /// that can snap every location to one connected road component.
    pub fn snap(self: Registry, arena: *Arena, locations: []const request.Location, defaults: candidates.Defaults, costing: anytype, deadline: Deadline) !Result {
        if (locations.len < 2) return .{ .failure = .{ .code = 120 } };
        for (locations) |input| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (!PointLL.init(input.lng, input.lat).inRange()) return .{ .failure = .{ .code = 171 } };
        }

        var disconnected: ?errors.Failure = null;
        for (self.regions) |*region| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (!try coversAll(region.bounds, locations, deadline)) continue;
            const mark = arena.mark();
            switch (try location.route(region.view, arena.allocator(), locations, defaults, costing, deadline)) {
                .ok => |snapped| return .{ .ok = .{ .region = region, .locations = snapped } },
                .failure => |failure| {
                    if (failure.code == 170) disconnected = failure;
                    arena.rewind(mark);
                },
            }
        }
        if (disconnected) |failure| return .{ .failure = failure };

        // Diagnose the failed selection on individual snaps. A location
        // inside a box can still lack an eligible road in that region.
        for (locations) |input| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const point = PointLL.init(input.lng, input.lat).toFixed();
            const snapped = for (self.regions) |*region| {
                if (deadline.expired()) return error.DeadlineExceeded;
                if (!region.bounds.contains(point)) continue;
                const mark = arena.mark();
                const hit = try candidates.search(region.view, arena.allocator(), input, defaults, costing, deadline);
                const found = hit.edges.len != 0 or hit.filtered_edges.len != 0;
                arena.rewind(mark);
                if (found) break true;
            } else false;
            if (!snapped) return .{ .failure = .{ .code = 171 } };
        }
        return .{ .failure = .{ .code = 170, .extra = "locations span multiple graph bundles" } };
    }
};

fn coversAll(bounds: graph.format.Bounds, locations: []const request.Location, deadline: Deadline) !bool {
    for (locations) |input| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!bounds.contains(PointLL.init(input.lng, input.lat).toFixed())) return false;
    }
    return true;
}
