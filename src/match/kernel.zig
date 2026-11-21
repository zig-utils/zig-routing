//! Static street costing for candidate search, transitions and trace recosting.
const std = @import("std");
const costing = @import("../costing/root.zig");
const graph = @import("../graph/root.zig");
const search = @import("../search/search.zig");
const linear = @import("../costing/linear.zig");
const snap = @import("../snap/search.zig");
const traffic_live = @import("../traffic/live.zig");
const traffic_predicted = @import("../traffic/predicted.zig");
const Cost = costing.compiled.Cost;
const View = graph.reader.View;
const Hot = graph.format.EdgeHot;
const EdgeId = graph.format.EdgeId;

pub const Traffic = struct {
    observations: traffic_live.Overlays = .{},
    forecasts: ?traffic_predicted.View = null,

    pub fn live(self: Traffic, id: EdgeId) ?graph.speed.Live {
        return self.observations.live(id);
    }

    pub fn predicted(self: Traffic, id: EdgeId, bucket: graph.speed.Bucket) ?f32 {
        const forecasts = self.forecasts orelse return null;
        return forecasts.speed(id, @as(u64, bucket) * graph.speed.seconds_per_bucket);
    }
};

pub fn Motor(comptime model: type) type {
    return struct {
        const Self = @This();
        profile: *const model.Profile,
        tables: *const costing.compiled.Compiled,
        arena: std.mem.Allocator,
        control: search.Control,
        traffic: Traffic = .{},
        features: ?*const linear.Table = null,

        pub fn linearCosts(self: Self) ?*const linear.Table {
            return self.features;
        }

        pub fn allowed(self: Self, directed: snap.DirectedEdge) bool {
            return self.profile.allowedCandidate(directed.class, .{}, .{}, self.linearAllows(directed.id));
        }

        pub fn allowedNode(self: Self, node: *const graph.format.NodeHot) bool {
            return self.profile.allowedNode(node);
        }

        pub fn restrictionPermission(self: Self) costing.base.Permission {
            return self.profile.permission;
        }

        pub const restrictionDimensions = if (model == costing.auto) autoDimensions else if (model == costing.truck) truckDimensions else noDimensions;

        fn autoDimensions(self: Self) costing.auto.Dimensions {
            return self.profile.dimensions;
        }

        fn truckDimensions(self: Self) costing.truck.Vehicle {
            return self.profile.vehicle;
        }

        const NoVehicleLimits = struct {
            pub fn allowed(_: @This(), _: graph.cold.access_restriction.Entry) bool {
                return true;
            }
        };

        fn noDimensions(_: Self) NoVehicleLimits {
            return .{};
        }

        pub fn edgeCost(self: Self, view: *const View, id: EdgeId, edge: *const Hot, direction: search.Direction) !Cost {
            return (try self.edgeTraversal(view, id, edge, direction)).cost;
        }

        pub fn edgeTraversal(self: Self, view: *const View, id: EdgeId, edge: *const Hot, _: search.Direction) !search.Traversal {
            return self.price(view, id, edge, null);
        }

        pub fn edgeCostAt(self: Self, view: *const View, id: EdgeId, edge: *const Hot, _: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            return self.price(view, id, edge, graph.speed.Time.fromTimeInfo(time));
        }

        fn linearAllows(self: Self, id: EdgeId) bool {
            return if (self.features) |features| features.allows(id) else false;
        }

        fn price(self: Self, view: *const View, id: EdgeId, edge: *const Hot, time: ?graph.speed.Time) !search.Traversal {
            const class = try view.class(edge.cls.class_id);
            const permitted = self.linearAllows(id);
            if (!self.profile.allowedCandidate(class, .{}, .{}, permitted) or
                class.category.use == @backingInt(graph.constants.Use.transit_connection)) return .{ .cost = .forbidden };
            // A permissive table contains weights for classes that are only
            // routable on an explicitly permitted directed edge.
            if (model != costing.motorcycle and self.profile.may_allow_edges and
                !permitted and !self.profile.pathClassAllowed(class)) return .{ .cost = .forbidden };
            const hot = if (self.traffic.forecasts) |overlay| overlay.applyStatic(id, edge.*) else edge.*;
            const speed = if (time == null) self.profile.untimedSpeed(hot) else self.profile.resolvedSpeed(hot, id, time, self.traffic);
            return .{
                .cost = model.Kernel.edgeCost(self.profile, self.tables, class, hot, speed, .{}),
                .measured_speed = @as(u8, @bitCast(speed.sources)) != 0,
            };
        }

        pub fn allowedTurn(self: Self, view: *const View, movement: search.Transition, previous: search.Label, _: search.Direction) !bool {
            if (!self.allowedNode(try view.node(movement.node))) return false;
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const turn: costing.base.Turn = .{ .row = movement.row };
            const check: model.PathCheck = .{
                .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
                .previous_dead_end = try movement.predecessorAtDeadEnd(view, from),
                .previous_access = previous.accessState(),
            };
            const access = if (model == costing.truck)
                try model.Kernel.allowed(self.profile, view, movement.outgoing, from, to, turn, check, self.control.deadline)
            else
                try model.Kernel.allowed(self.profile, from, to, turn, check, self.control.deadline);
            return access.allowed;
        }

        pub fn turnCost(self: Self, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            var turn = try model.Turn.fromRow(view, movement.node, movement.incoming_edge.cls.opp_local, movement.outgoing_edge.cls.local, movement.row, self.arena, self.control.deadline);
            turn.measured_speed = movement.measured_speed;
            return model.Kernel.turnCost(self.profile, try view.node(movement.node), from, to, turn);
        }
    };
}

pub fn Active(comptime model: type) type {
    return struct {
        const Self = @This();
        profile: *const model.Profile,
        tables: *const costing.compiled.Compiled,
        bikeshare: bool = false,
        features: ?*const linear.Table = null,

        pub fn linearCosts(self: Self) ?*const linear.Table {
            return self.features;
        }

        pub fn allowed(self: Self, directed: snap.DirectedEdge) bool {
            if (self.features) |features| if (features.allows(directed.id)) return true;
            return if (model == costing.pedestrian)
                self.profile.allowedCandidate(directed.class, .{}, .{}, self.bikeshare)
            else
                self.profile.allowed(directed);
        }

        pub fn allowedNode(self: Self, node: *const graph.format.NodeHot) bool {
            return self.profile.allowedNode(node);
        }

        pub fn restrictionPermission(self: Self) costing.base.Permission {
            return self.profile.permission;
        }

        pub fn edgeCost(self: Self, view: *const View, id: EdgeId, edge: *const Hot, _: search.Direction) !Cost {
            const class = try view.class(edge.cls.class_id);
            if (self.profile.may_allow_edges and !self.profile.pathClassAllowed(class)) {
                const features = self.features orelse return .forbidden;
                if (!features.allows(id)) return .forbidden;
            }
            return if (model == costing.pedestrian)
                model.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedFerrySpeed(edge.*), .{})
            else
                model.Kernel.edgeCost(self.profile, self.tables, class, edge.*, .{});
        }

        pub fn allowedTurn(self: Self, view: *const View, movement: search.Transition, previous: search.Label, _: search.Direction) !bool {
            if (!self.allowedNode(try view.node(movement.node))) return false;
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local;
            const deadend = try movement.predecessorAtDeadEnd(view, from);
            return if (model == costing.pedestrian)
                model.Kernel.allowed(self.profile, from, to, movement.outgoing_edge.*, .{
                    .previous_distance = @intFromFloat(@min(@max(@as(f64, previous.cost), 0), @as(f64, std.math.maxInt(u32)))),
                    .previous_pedestrian = self.profile.permission.accessibleClass(from),
                    .previous_dead_end = deadend,
                    .backtrack = backtrack,
                })
            else
                model.Kernel.allowed(self.profile, from, to, .{ .row = movement.row }, .{
                    .previous_bicycle = self.profile.permission.accessibleClass(from),
                    .previous_dead_end = deadend,
                    .backtrack = backtrack,
                });
        }

        pub fn turnCost(self: Self, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const turn = try model.Turn.read(view, movement.node, movement.incoming, movement.outgoing);
            return model.Kernel.turnCost(self.profile, try view.node(movement.node), from, to, turn);
        }
    };
}
