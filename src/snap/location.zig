// Ported from src/loki/route_action.cc and src/baldr/connectivity_map.cc (Valhalla 3.9.3).
const std = @import("std");
const candidates = @import("search.zig");
const reach = @import("reach.zig");
const request = @import("../api/request.zig");
const errors = @import("../api/errors.zig");
const graph = @import("../graph/root.zig");
const paged = @import("../search/paged.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

pub const Result = union(enum) {
    ok: []const candidates.PathLocation,
    failure: errors.Failure,
};

/// Prepare route locations with a shared reach cache. Matching a weak
/// component is a necessary condition. Directional routing still depends on
/// costing, restrictions and the path search.
pub fn route(view: *const graph.reader.View, arena: Allocator, locations: []const request.Location, defaults: candidates.Defaults, costing: anytype, deadline: Deadline) !Result {
    if (locations.len < 2) return .{ .failure = .{ .code = 120 } };
    var limit: u32 = 0;
    for (locations) |location| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const limits = candidates.thresholds(location, defaults);
        limit = @max(limit, limits.inbound, limits.outbound);
    }
    var finder: reach.Finder = .{ .view = view, .arena = arena, .limit = limit, .deadline = deadline };
    const results = try arena.alloc(candidates.PathLocation, locations.len);
    for (locations, results) |location, *result| {
        result.* = candidates.searchWithReach(&finder, location, defaults, costing) catch |err| switch (err) {
            error.InvalidCoordinate => return .{ .failure = .{ .code = 171 } },
            else => return err,
        };
        if (result.edges.len == 0 and result.filtered_edges.len == 0)
            return .{ .failure = .{ .code = 171 } };
    }
    if (view.components != null and !try connected(view, arena, results, deadline))
        return .{ .failure = .{ .code = 170 } };
    return .{ .ok = results };
}

fn connected(view: *const graph.reader.View, arena: Allocator, locations: []const candidates.PathLocation, deadline: Deadline) !bool {
    var marks: paged.Array(usize, 0) = .{};
    for (locations, 0..) |location, index| {
        var matched = false;
        for ([_][]const candidates.PathEdge{ location.edges, location.filtered_edges }) |edges| {
            for (edges) |candidate| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const arc = try view.edge(candidate.id);
                const component = try view.component(@fromBackingInt(arc.head));
                if (marks.get(component) != index) continue;
                (try marks.at(arena, component)).* = index + 1;
                matched = true;
            }
        }
        if (!matched) return false;
    }
    return true;
}
