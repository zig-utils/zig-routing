//! Shared static auto kernel for search diagnostics.
const std = @import("std");
const routing = @import("routing");
const auto = routing.costing.auto;
const Cost = routing.costing.compiled.Cost;
const View = routing.graph.reader.View;
const Edge = routing.graph.format.EdgeId;
const Hot = routing.graph.format.EdgeHot;
const search = routing.search.search;

pub const Auto = struct {
    profile: *const auto.Profile,
    tables: *const routing.costing.compiled.Compiled,
    arena: std.mem.Allocator,

    pub fn edgeCost(self: Auto, view: *const View, _: Edge, edge: *const Hot, _: search.Direction) !Cost {
        const class = try view.class(edge.cls.class_id);
        return auto.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedSpeed(edge.*), .{});
    }

    pub fn allowedTurn(self: Auto, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !bool {
        if (!self.profile.allowedNode(try view.node(movement.node))) return false;
        const from = try view.class(movement.incoming_edge.cls.class_id);
        const to = try view.class(movement.outgoing_edge.cls.class_id);
        const result = try auto.Kernel.allowed(self.profile, from, to, .{ .row = movement.row }, .{
            .previous_dead_end = from.flags.dead_end or (try view.outEdgeRange(movement.node)).count() == 1,
            .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
            .previous_access = movement.incoming_access,
        }, .none);
        return result.allowed;
    }

    pub fn turnCost(self: Auto, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
        const from = try view.class(movement.incoming_edge.cls.class_id);
        const to = try view.class(movement.outgoing_edge.cls.class_id);
        var turn = try auto.Turn.read(view, movement.node, movement.incoming, movement.outgoing, self.arena, .none);
        turn.measured_speed = @as(u8, @bitCast(self.profile.untimedSpeed(movement.incoming_edge.*).sources)) != 0;
        return auto.Kernel.turnCost(self.profile, try view.node(movement.node), from, to, turn);
    }
};
