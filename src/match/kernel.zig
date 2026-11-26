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
const Class = graph.class_table.EdgeClass;

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
        pub const UntimedEdge = struct {
            cost: Cost,
            flags: packed struct(u32) {
                measured_speed: bool,
                allowed: bool,
                allowed_turns: u30,
            },
        };

        comptime {
            std.debug.assert(@sizeOf(UntimedEdge) == 12);
        }

        profile: *const model.Profile,
        tables: *const costing.compiled.Compiled,
        arena: std.mem.Allocator,
        control: search.Control,
        traffic: Traffic = .{},
        features: ?*const linear.Table = null,
        untimed_edges: ?[]const UntimedEdge = null,

        pub fn linearCosts(self: Self) ?*const linear.Table {
            return self.features;
        }

        pub fn allowed(self: Self, directed: snap.DirectedEdge) bool {
            if (self.untimed_edges) |edges| return edges[@backingInt(directed.id)].flags.allowed;
            return self.profile.allowedCandidate(directed.class, .{}, .{}, self.linearAllows(directed.id));
        }

        /// Compile graph-only prices for a batch with a fixed profile.
        /// The caller keeps the graph, profile and static traffic data fixed.
        pub fn prepareUntimed(self: Self, allocator: std.mem.Allocator, view: *const View, control: search.Control) ![]UntimedEdge {
            const output = try allocator.alloc(UntimedEdge, view.edges.len);
            errdefer allocator.free(output);
            for (view.edges, output, 0..) |*edge, *entry, index| {
                if (index % 1024 == 0) try control.check();
                const id: EdgeId = @fromBackingInt(@as(u32, @intCast(index)));
                const class = try view.class(edge.cls.class_id);
                const traversal = self.priceClass(id, edge, class, null);
                entry.* = .{
                    .cost = traversal.cost,
                    .flags = .{
                        .allowed_turns = if (model == costing.auto) try self.prepareAllowedTurns(view, id, edge, class, control) else 0,
                        .measured_speed = traversal.measured_speed,
                        .allowed = self.profile.allowedCandidate(class, .{}, .{}, self.linearAllows(id)),
                    },
                };
            }
            return output;
        }

        fn prepareAllowedTurns(self: Self, view: *const View, incoming: EdgeId, edge: *const Hot, class: *const Class, control: search.Control) !u30 {
            const at: graph.format.NodeId = @fromBackingInt(edge.head);
            const node = try view.node(at);
            if (!self.allowedNode(node)) return 0;
            const range = try view.outEdgeRange(at);
            const row = try view.turnRowAt(node, range.count(), edge.cls.opp_local);
            var mask: u30 = 0;
            for (view.edges[range.first..range.end], range.first.., row) |*outgoing, i, turn| {
                try control.check();
                if (outgoing.cls.local >= @bitSizeOf(u30)) continue;
                const permitted = try self.allowedTurn(view, .{
                    .node = at,
                    .incoming = incoming,
                    .incoming_edge = edge,
                    .outgoing = @fromBackingInt(@as(u32, @intCast(i))),
                    .outgoing_edge = outgoing,
                    .row = turn,
                    .predecessor_dead_end = class.flags.dead_end,
                    .node_record = node,
                    .edge_range = range,
                    .incoming_class = class,
                    .outgoing_class = try view.class(outgoing.cls.class_id),
                }, .{}, .forward);
                if (permitted) mask |= @as(u30, 1) << outgoing.cls.local;
            }
            return mask;
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
            if (self.preparedTraversal(id)) |traversal| return traversal;
            return self.price(view, id, edge, null);
        }

        pub fn edgeCostAt(self: Self, view: *const View, id: EdgeId, edge: *const Hot, _: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            return self.price(view, id, edge, graph.speed.Time.fromTimeInfo(time));
        }

        fn linearAllows(self: Self, id: EdgeId) bool {
            return if (self.features) |features| features.allows(id) else false;
        }

        pub inline fn edgeTraversalWithClass(self: Self, _: *const View, id: EdgeId, edge: *const Hot, class: *const Class, _: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            if (!time.valid) if (self.preparedTraversal(id)) |traversal| return traversal;
            return self.priceClass(id, edge, class, if (time.valid) graph.speed.Time.fromTimeInfo(time) else null);
        }

        inline fn preparedTraversal(self: Self, id: EdgeId) ?search.Traversal {
            const edges = self.untimed_edges orelse return null;
            const entry = edges[@backingInt(id)];
            return .{ .cost = entry.cost, .measured_speed = entry.flags.measured_speed };
        }

        fn price(self: Self, view: *const View, id: EdgeId, edge: *const Hot, time: ?graph.speed.Time) !search.Traversal {
            return self.priceClass(id, edge, try view.class(edge.cls.class_id), time);
        }

        fn priceClass(self: Self, id: EdgeId, edge: *const Hot, class: *const Class, time: ?graph.speed.Time) search.Traversal {
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
            if (!self.allowedNode(try movement.nodeRecord(view))) return false;
            const from = try movement.incomingClass(view);
            const to = try movement.outgoingClass(view);
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

        /// The forward distance sweep uses the local movement and dead-end
        /// rule compiled with the untimed batch prices. Search evaluates
        /// elapsed time and predecessor access separately.
        pub inline fn cachedExpansionTurn(self: Self, incoming: EdgeId, local: u5) ?bool {
            if (model == costing.auto and local < @bitSizeOf(u30)) {
                if (self.untimed_edges) |edges| {
                    return edges[@backingInt(incoming)].flags.allowed_turns & (@as(u30, 1) << local) != 0;
                }
            }
            return null;
        }

        pub fn turnCost(self: Self, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
            const from = try movement.incomingClass(view);
            const to = try movement.outgoingClass(view);
            var turn = try model.Turn.fromRange(view, movement.node, try movement.edgeRange(view), movement.incoming_edge.cls.opp_local, movement.outgoing_edge.cls.local, movement.row, self.arena, self.control.deadline);
            turn.measured_speed = movement.measured_speed;
            return model.Kernel.turnCost(self.profile, try movement.nodeRecord(view), from, to, turn);
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
            return self.priceClass(id, edge, try view.class(edge.cls.class_id));
        }

        pub fn edgeTraversalWithClass(self: Self, _: *const View, id: EdgeId, edge: *const Hot, class: *const Class, _: search.Direction, _: graph.time_info.TimeInfo) !search.Traversal {
            return .{ .cost = self.priceClass(id, edge, class) };
        }

        fn priceClass(self: Self, id: EdgeId, edge: *const Hot, class: *const Class) Cost {
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
            if (!self.allowedNode(try movement.nodeRecord(view))) return false;
            const from = try movement.incomingClass(view);
            const to = try movement.outgoingClass(view);
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
            const from = try movement.incomingClass(view);
            const to = try movement.outgoingClass(view);
            const node = try movement.nodeRecord(view);
            const degree = (try movement.edgeRange(view)).count();
            const from_local = movement.incoming_edge.cls.opp_local;
            const to_local = movement.outgoing_edge.cls.local;
            if (model == costing.pedestrian) return model.Kernel.turnCostRow(self.profile, node, from, to, .{
                .view = view,
                .node = movement.node,
                .degree = degree,
                .incoming = movement.incoming,
                .outgoing = movement.outgoing,
                .from = from_local,
                .to = to_local,
                .row = movement.row,
            });
            const turn: model.Turn = .{ .base_turn = .{ .row = movement.row }, .sides = try view.turnSidesAtDegree(movement.node, degree, from_local, to_local) };
            return model.Kernel.turnCost(self.profile, node, from, to, turn);
        }
    };
}
