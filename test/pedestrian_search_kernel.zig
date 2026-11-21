//! Static pedestrian kernel shared by the search diagnostics.
const routing = @import("routing");
const EdgeClass = routing.graph.class_table.EdgeClass;
const pedestrian = routing.costing.pedestrian;
const graph = routing.graph;
const View = graph.reader.View;
const Edge = graph.format.EdgeId;
const Hot = graph.format.EdgeHot;
const search = routing.search.search;
const Cost = routing.costing.compiled.Cost;

pub const Foot = struct {
    profile: *const pedestrian.Profile,
    tables: *const routing.costing.compiled.Compiled,

    pub fn restrictionModes(self: Foot) u16 {
        const permission = self.profile.permission;
        if (permission.flags.contains(.ignore_restrictions) or permission.flags.contains(.ignore_non_vehicular_restrictions)) return 0;
        return @bitCast(permission.access_mask);
    }

    pub fn edgeCost(self: Foot, view: *const View, _: Edge, edge: *const Hot, _: search.Direction) !Cost {
        return self.classCost(try view.class(edge.cls.class_id), edge);
    }

    pub fn edgeTraversalWithClass(self: @This(), _: *const View, _: Edge, edge: *const Hot, class: *const EdgeClass, _: search.Direction, _: routing.graph.time_info.TimeInfo) !search.Traversal {
        return .{ .cost = self.classCost(class, edge) };
    }

    fn classCost(self: @This(), class: *const EdgeClass, edge: *const Hot) Cost {
        return pedestrian.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedFerrySpeed(edge.*), .{});
    }

    pub fn allowedTurn(self: Foot, view: *const View, movement: search.Transition, previous: search.Label, direction: search.Direction) !bool {
        if (!self.profile.allowedNode(try movement.nodeRecord(view))) return false;
        const from = try movement.incomingClass(view);
        const to = try movement.outgoingClass(view);
        const prior = if (direction == .forward) from else to;
        const check: pedestrian.PathCheck = .{
            .previous_distance = previous.dist_m,
            .previous_dead_end = try movement.predecessorAtDeadEnd(view, prior),
            .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
        };
        return if (direction == .forward)
            pedestrian.Kernel.allowed(self.profile, from, to, movement.outgoing_edge.*, check)
        else
            pedestrian.Kernel.allowedReverse(self.profile, from, to, check);
    }

    pub fn turnCost(self: Foot, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
        const from = try movement.incomingClass(view);
        const to = try movement.outgoingClass(view);
        const node = try movement.nodeRecord(view);
        const turn = if (movement.compact_movement) |cached|
            try pedestrian.Turn.fromIntersection(view, node, movement.incoming, movement.outgoing, .{
                .base_turn = .{ .row = cached.row },
                .sides = cached.sides,
            })
        else
            try pedestrian.Turn.fromRow(view, movement.node, node, (try movement.edgeRange(view)).count(), movement.incoming, movement.outgoing, movement.incoming_edge.cls.opp_local, movement.outgoing_edge.cls.local, movement.row);
        return pedestrian.Kernel.turnCost(self.profile, node, from, to, turn);
    }
};
