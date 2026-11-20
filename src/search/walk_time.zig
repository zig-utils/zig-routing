//! Lower bounds on the remaining walk to a time-dependent restriction.
const std = @import("std");
const graph = @import("../graph/root.zig");
const core = @import("search.zig");
const Permission = @import("../costing/base.zig").Permission;
const paged = @import("paged.zig");
const queue = @import("queue.zig");
const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const NodeId = graph.format.NodeId;
const infinity = std.math.maxInt(u32);

pub const Distance = struct {
    nodes: paged.Array(u32, infinity) = .{},

    pub fn init(a: Allocator, view: *const View, permission: Permission, limit: u32, control: core.Control) !Distance {
        var result: Distance = .{};
        const modes = permission.restrictionModes();
        if (modes == 0) return result;
        var pending: queue.Heap = .{};
        defer pending.items.deinit(a);

        for (view.restriction_conditions orelse &.{}, 0..) |row, i| {
            if (i % 256 == 0) try control.check();
            if (row.attr.modes & modes == 0) continue;
            const states = view.restriction_automaton orelse return error.MissingRestrictionAutomaton;
            if (row.state >= states.len) return error.InvalidRestrictionState;
            try result.seed(a, view, &pending, @fromBackingInt(states[row.state].edge));
        }

        if (view.cold_data != null) for (view.edges, 0..) |edge, i| {
            if (i % 1024 == 0) try control.check();
            if (edge.cls.cold_checks == 0) continue;
            const class = try view.class(edge.cls.class_id);
            if (class.detail.access_restriction & modes == 0) continue;
            const id: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
            const record = try view.coldRecordWithDeadline(id, control.deadline);
            var limits = record.restrictions();
            while (limits.next()) |restriction| {
                try control.check();
                if (!restriction.attr.kind.timed() or restriction.modes() & modes == 0) continue;
                try result.seed(a, view, &pending, id);
                break;
            }
        };

        try result.propagate(a, view, &pending, limit, control);
        return result;
    }

    pub fn propagate(result: *Distance, a: Allocator, view: *const View, pending: *queue.Heap, limit: u32, control: core.Control) !void {
        while (pending.pop()) |item| {
            try control.check();
            const distance = item.key;
            if (distance != result.nodes.get(item.label)) continue;
            const exits = try view.outEdgeRange(@fromBackingInt(item.label));
            // Ignoring pedestrian access and turns can only shorten this
            // distance. A reverse arc uses its physical forward length.
            for (view.edges[exits.first..exits.end], exits.first..) |outgoing, i| {
                const edge: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
                const reverse = try view.edge(try view.oppEdge(edge));
                const next = distance +| reverse.geom.len_m;
                if (next <= limit) try result.offer(a, pending, outgoing.head, next);
            }
        }
    }

    fn seed(self: *Distance, a: Allocator, view: *const View, pending: *queue.Heap, edge: EdgeId) !void {
        const reverse = try view.edge(try view.oppEdge(edge));
        try self.offer(a, pending, reverse.head, 0);
    }

    pub fn offer(self: *Distance, a: Allocator, pending: *queue.Heap, id: u32, distance: u32) !void {
        if (distance >= self.nodes.get(id)) return;
        (try self.nodes.at(a, id)).* = distance;
        try pending.push(a, .{ .key = distance, .label = id });
    }

    pub fn within(self: *const Distance, node: NodeId, limit: u32) bool {
        return self.nodes.get(@backingInt(node)) <= limit;
    }
};
