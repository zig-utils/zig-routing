// Ported from src/thor/route_matcher.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const memory = @import("../infra/arena.zig");
const core = @import("../search/search.zig");
const snap = @import("../snap/search.zig");
const Segment = @import("../search/endpoints.zig").Segment;
const Measurement = @import("candidates.zig").Measurement;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;

pub const Part = struct {
    segment: Segment,
    first: u32,
    last: u32,
};

const End = struct { edge: snap.PathEdge, distance: f32 };
const Frame = struct {
    node: NodeId,
    point: u32,
    next: u32,
    end: u32,
    checked_end: bool = false,
};

const Walker = struct {
    view: *const View,
    arena: *memory.Arena,
    trace: []const Measurement,
    distances: []const f32,
    prefix: []const f32,
    targets: ?[]const snap.PathEdge = null,
    ends: std.AutoHashMapUnmanaged(NodeId, End) = .empty,
    path: std.ArrayList(Part) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    control: core.Control,

    fn frame(self: *const Walker, node: NodeId, point: u32) !Frame {
        const range = try self.view.outEdgeRange(node);
        return .{ .node = node, .point = point, .next = range.first, .end = range.end };
    }

    fn matchShape(self: *Walker, id: EdgeId, from: u32, to: u32) !bool {
        const mark = self.arena.mark();
        defer self.arena.rewind(mark);
        const shape = try self.view.shapeWithDeadline(id, self.arena.allocator(), self.control.deadline);
        const count = to - from;
        if (count >= shape.len or (from > 0 and shape.len - count != 1)) return false;
        const shape_start = shape.len - count;
        for (self.trace[from + 1 .. to], shape[shape_start .. shape.len - 1], 0..) |measurement, point, index| {
            if (index % 256 == 0) try self.control.check();
            if (!measurement.point.approxEql(point.toPoint())) return false;
        }
        return true;
    }

    fn endOfEdge(self: *Walker, id: EdgeId, hot: *const graph.format.EdgeHot, from: u32, metres: f32) !?u32 {
        const end = (try self.view.coordinate(@fromBackingInt(hot.head))).toPoint();
        var length: f32 = 0;
        for (self.trace[from + 1 ..], from + 1..) |point, index| {
            if (index % 256 == 0) try self.control.check();
            length += self.distances[index];
            if (length > lengthLimit(metres)) break;
            if (point.point.approxEql(end) and metres < lengthLimit(length)) {
                if (hot.geom.len_m == 0 and index == from + 1) return @intCast(index);
                if (try self.matchShape(id, from, @intCast(index))) return @intCast(index);
            }
        }
        return null;
    }

    fn finish(self: *Walker, node: NodeId, index: u32) !bool {
        const end = self.ends.get(node) orelse return false;
        const last: u32 = @intCast(self.trace.len - 1);
        if (@abs(self.prefix[index] + end.distance - self.prefix[last]) >= 5) return false;
        if (end.edge.node == .end) {
            const edge = self.path.items[self.path.items.len - 1].segment.edge;
            for (self.targets.?, 0..) |target, i| {
                if (i % 256 == 0) try self.control.check();
                if (target.id == edge and target.node == .end) return true;
            }
            return false;
        }
        try self.path.append(self.arena.allocator(), .{
            .segment = .{ .edge = end.edge.id, .begin = 0, .end = end.edge.percent_along },
            .first = index,
            .last = last,
        });
        return true;
    }

    fn descend(self: *Walker, node: NodeId, index: u32) !bool {
        const a = self.arena.allocator();
        try self.frames.append(a, try self.frame(node, index));
        var iterations: usize = 0;
        while (self.frames.items.len > 0) : (iterations += 1) {
            if (iterations % 256 == 0) try self.control.check();
            const current = &self.frames.items[self.frames.items.len - 1];
            if (!current.checked_end) {
                current.checked_end = true;
                if (try self.finish(current.node, current.point)) return true;
            }
            if (current.next == current.end) {
                _ = self.frames.pop();
                _ = self.path.pop();
                continue;
            }
            const id: EdgeId = @fromBackingInt(current.next);
            current.next += 1;
            const hot = try self.view.edge(id);
            const class = try self.view.class(hot.cls.class_id);
            if (class.category.use == @backingInt(graph.constants.Use.transit_connection)) continue;
            const n = self.path.items.len;
            if (n > 1 and (self.path.items[n - 1].segment.edge == id or self.path.items[n - 2].segment.edge == id)) continue;
            const head: NodeId = @fromBackingInt(hot.head);
            const from = current.point;
            const next = if (class.flags.node_connector) next: {
                var ancestors = std.mem.reverseIterator(self.frames.items);
                var count: usize = 0;
                while (ancestors.next()) |ancestor| : (count += 1) {
                    if (count % 64 == 0) try self.control.check();
                    if (ancestor.point != from) break;
                    if (ancestor.node == head) break :next null;
                }
                break :next @as(?u32, from);
            } else try self.endOfEdge(id, hot, from, @floatFromInt(hot.geom.len_m));
            if (next) |point| {
                try self.path.append(a, .{ .segment = .{ .edge = id, .begin = 0, .end = 1 }, .first = from, .last = point });
                try self.frames.append(a, try self.frame(head, point));
            }
        }
        return false;
    }

    fn start(self: *Walker, origins: []const snap.PathEdge, destination: anytype) ![]const Part {
        const a = self.arena.allocator();
        const last: u32 = @intCast(self.trace.len - 1);
        for (origins) |origin| {
            try self.control.check();
            if (origin.node == .end) continue;
            if (!(origin.percent_along >= 0 and origin.percent_along <= 1)) return error.InvalidCandidate;
            const hot = try self.view.edge(origin.id);
            const metres = @as(f32, @floatFromInt(hot.geom.len_m)) * (1 - origin.percent_along);
            if (try self.endOfEdge(origin.id, hot, 0, metres)) |point| {
                try self.loadTargets(destination);
                try self.path.append(a, .{
                    .segment = .{ .edge = origin.id, .begin = origin.percent_along, .end = 1 },
                    .first = 0,
                    .last = point,
                });
                if (try self.descend(@fromBackingInt(hot.head), point)) return self.path.items;
                return error.NoEdgeWalk;
            }
            if (self.prefix[last] > lengthLimit(metres)) continue;
            try self.loadTargets(destination);
            for (self.targets.?, 0..) |target, i| {
                if (i % 256 == 0) try self.control.check();
                if (target.node == .begin or target.id != origin.id or target.percent_along < origin.percent_along) continue;
                try self.path.append(a, .{
                    .segment = .{ .edge = origin.id, .begin = origin.percent_along, .end = target.percent_along },
                    .first = 0,
                    .last = last,
                });
                return self.path.items;
            }
        }
        return error.NoEdgeWalk;
    }

    fn loadTargets(self: *Walker, destination: anytype) !void {
        if (self.targets != null) return;
        const targets = try destination.get();
        const a = self.arena.allocator();
        for (targets) |target| {
            try self.control.check();
            if (target.node == .begin) continue;
            if (!(target.percent_along >= 0 and target.percent_along <= 1)) return error.InvalidCandidate;
            const edge = try self.view.edge(target.id);
            const opposing = try self.view.edge(try self.view.oppEdge(target.id));
            const at_node = target.node == .end;
            const node: NodeId = @fromBackingInt(if (at_node) edge.head else opposing.head);
            _ = try self.ends.getOrPutValue(a, node, .{
                .edge = target,
                .distance = if (at_node) 0 else @as(f32, @floatFromInt(opposing.geom.len_m)) * target.percent_along,
            });
        }
        if (self.ends.count() == 0) return error.NoEdgeWalk;
        self.targets = targets;
    }
};

fn lengthLimit(metres: f32) f32 {
    return metres + std.math.clamp(metres * 0.05, 10, 25);
}

/// Recover a directed route from the ordered shape and its endpoint
/// correlations. A geometric mismatch leaves the request arena unchanged.
pub fn find(view: *const View, arena: *memory.Arena, trace: []const Measurement, origins: []const snap.PathEdge, targets: []const snap.PathEdge, control: core.Control) ![]const Part {
    const Resolved = struct {
        edges: []const snap.PathEdge,

        fn get(self: @This()) ![]const snap.PathEdge {
            return self.edges;
        }
    };
    return findLazy(view, arena, trace, origins, Resolved{ .edges = targets }, control);
}

/// Resolve the destination when an origin could lead to a geometric walk.
pub fn findLazy(view: *const View, arena: *memory.Arena, trace: []const Measurement, origins: []const snap.PathEdge, destination: anytype, control: core.Control) ![]const Part {
    try control.check();
    if (trace.len < 2 or trace.len >= core.no_index) return error.InvalidTraceShape;
    const mark = arena.mark();
    errdefer arena.rewind(mark);
    const a = arena.allocator();
    const distances = try a.alloc(f32, trace.len);
    const prefix = try a.alloc(f32, trace.len);
    distances[0] = 0;
    prefix[0] = 0;
    for (trace, 0..) |measurement, i| {
        if (i % 256 == 0) try control.check();
        if (!measurement.point.inRange()) return error.InvalidMeasurement;
        if (i == 0) continue;
        distances[i] = @floatCast(trace[i - 1].point.distance(measurement.point));
        prefix[i] = prefix[i - 1] + distances[i];
    }
    var walker: Walker = .{
        .view = view,
        .arena = arena,
        .trace = trace,
        .distances = distances,
        .prefix = prefix,
        .control = control,
    };
    return walker.start(origins, destination);
}
