//! Shared static auto kernel for search diagnostics.
const std = @import("std");
const routing = @import("routing");
const EdgeClass = routing.graph.class_table.EdgeClass;
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

    pub fn restrictionPermission(self: Auto) routing.costing.base.Permission {
        return self.profile.permission;
    }

    pub fn restrictionDimensions(self: Auto) auto.Dimensions {
        return self.profile.dimensions;
    }

    pub fn edgeCost(self: Auto, view: *const View, _: Edge, edge: *const Hot, _: search.Direction) !Cost {
        return self.classCost(try view.class(edge.cls.class_id), edge);
    }

    pub fn edgeTraversalWithClass(self: @This(), _: *const View, _: Edge, edge: *const Hot, class: *const EdgeClass, _: search.Direction, _: routing.graph.time_info.TimeInfo) !search.Traversal {
        return .{ .cost = self.classCost(class, edge) };
    }

    fn classCost(self: @This(), class: *const EdgeClass, edge: *const Hot) Cost {
        return auto.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedSpeed(edge.*), .{});
    }

    pub fn allowedTurn(self: Auto, view: *const View, movement: search.Transition, _: search.Label, direction: search.Direction) !bool {
        if (!self.profile.allowedNode(try movement.nodeRecord(view))) return false;
        const from = try movement.incomingClass(view);
        const to = try movement.outgoingClass(view);
        const previous = if (direction == .forward) from else to;
        const check: auto.PathCheck = .{
            .previous_dead_end = try movement.predecessorAtDeadEnd(view, previous),
            .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
            .previous_access = if (direction == .forward) movement.incoming_access else movement.outgoing_access,
        };
        const result = if (direction == .forward)
            try auto.Kernel.allowed(self.profile, from, to, .{ .row = movement.row }, check, .none)
        else
            try auto.Kernel.allowedReverse(self.profile, from, to, .{ .row = movement.row }, check, .none);
        return result.allowed;
    }

    pub fn turnCost(self: Auto, view: *const View, movement: search.Transition, _: search.Label, direction: search.Direction) !Cost {
        const from = try movement.incomingClass(view);
        const to = try movement.outgoingClass(view);
        var turn = if (movement.compact_movement) |cached|
            cached.motorTurn()
        else
            try auto.Turn.fromRange(view, movement.node, try movement.edgeRange(view), movement.incoming_edge.cls.opp_local, movement.outgoing_edge.cls.local, movement.row, self.arena, .none);
        const previous = if (direction == .forward) movement.incoming_edge else movement.outgoing_edge;
        turn.measured_speed = @as(u8, @bitCast(self.profile.untimedSpeed(previous.*).sources)) != 0;
        const node = try movement.nodeRecord(view);
        return if (direction == .forward)
            auto.Kernel.turnCost(self.profile, node, from, to, turn)
        else
            auto.Kernel.turnCostReverse(self.profile, node, from, to, turn);
    }
};
