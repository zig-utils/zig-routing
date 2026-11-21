// Ported from src/loki/linear_cost_factors.cc and src/loki/worker.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const linear = @import("../costing/linear.zig");
const Feature = @import("../api/linear_shapes.zig").Feature;
const errors = @import("../api/errors.zig");
const route = @import("../match/route.zig");
const walker = @import("../match/walk.zig");
const Measurement = @import("../match/candidates.zig").Measurement;
const search = @import("../search/search.zig");
const snap = @import("search.zig");
const Arena = @import("../infra/arena.zig").Arena;
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    min_factor: f32 = 1,
    max_edges: usize = 50_000,
};

pub const Resolved = struct {
    costs: linear.Table = .{},
    // The indices are appended to Valhalla warning 216.
    failed: []const u8 = "",
};

pub const Result = union(enum) {
    ok: Resolved,
    failure: errors.Failure,
};

const missing_endpoint: Result = .{ .failure = .{ .code = 173, .extra = "No edges near start/end of linear cost feature." } };

pub noinline fn resolve(view: *const graph.reader.View, a: Allocator, scratch: *Arena, features: []const Feature, limits: Limits, control: search.Control) !Result {
    var costs: linear.Table = .{};
    var failed: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (features, 0..) |feature, index| {
        try control.check();
        if (feature.points.len == 0)
            return .{ .failure = .{ .code = 173, .extra = "feature coordinates are empty" } };
        const mark = scratch.mark();
        defer scratch.rewind(mark);
        const temp = scratch.allocator();
        const shape = try temp.alloc(Measurement, feature.points.len);
        for (feature.points, shape, 0..) |point, *measurement, i| {
            if (i % 256 == 0) try control.check();
            if (!point.inRange()) return .{ .failure = .{ .code = 173, .extra = "invalid feature coordinates" } };
            measurement.* = .{ .point = point };
        }
        const first = shape[0].point;
        const last = shape[shape.len - 1].point;
        const origin = try snap.search(view, temp, route.endpoint(.{ .lat = first.lat, .lng = first.lng }), .{}, snap.NoCost{}, control.deadline);
        const target = try snap.search(view, temp, route.endpoint(.{ .lat = last.lat, .lng = last.lng }), .{}, snap.NoCost{}, control.deadline);
        if (origin.edges.len == 0 or target.edges.len == 0) return missing_endpoint;
        const parts = walker.find(view, scratch, shape, origin.edges, target.edges, control) catch |err| switch (err) {
            error.NoEdgeWalk, error.InvalidTraceShape => {
                if (failed.items.len != 0) try failed.appendSlice(a, ", ");
                try failed.print(a, "{d}", .{index});
                continue;
            },
            else => return err,
        };
        const factor = if (parts.len == 1) feature.factor else @max(feature.factor, limits.min_factor);
        for (parts, 0..) |part, i| {
            if (i % 64 == 0) try control.check();
            if (count > limits.max_edges) return .{ .failure = .{ .code = 234 } };
            const segment = part.segment;
            if (parts.len > 1 and (i == 0 or i + 1 == parts.len)) {
                const length: f32 = @floatFromInt((try view.edge(segment.edge)).geom.len_m);
                if (length * (segment.end - segment.begin) < 1) continue;
            }
            count += 1;
            try costs.append(a, segment.edge, .{ .begin = segment.begin, .end = segment.end, .factor = factor }, feature.allow);
        }
    }
    try costs.finish(control.deadline);
    return .{ .ok = .{ .costs = costs, .failed = failed.items } };
}
