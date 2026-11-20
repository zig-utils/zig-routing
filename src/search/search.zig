// Ported from src/thor/unidirectional_astar.cc and src/thor/bidirectional_astar.cc
// (Valhalla 3.9.3), with exact edge-state expansion over native CSR.

const std = @import("std");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const memory = @import("../infra/arena.zig");
const costing = @import("../costing/compiled.zig");
const base = @import("../costing/base.zig");
const DirectedEdge = @import("../snap/edge.zig").DirectedEdge;
pub const ExcludedEdge = @import("../snap/exclusions.zig").Edge;
const paged = @import("paged.zig");
const queue = @import("queue.zig");
const endpoints = @import("endpoints.zig");
const automaton = @import("../graph/restriction_automaton.zig");
const EdgeId = graph.format.EdgeId;
const EdgeHot = graph.format.EdgeHot;
const NodeId = graph.format.NodeId;
const TurnEntry = graph.format.TurnEntry;
const View = graph.reader.View;

pub const no_index = std.math.maxInt(u32);

pub const Label = extern struct {
    cost: f32 = 0,
    secs: f32 = 0,
    pred: u32 = no_index,
    edge: u32 = no_index,
    dist_m: u32 = 0,
    tcost: f32 = 0,
    flags: u32 = 0,
    ctx: u32 = 0,

    pub const target: u32 = 1;
    const partial_target: u32 = 2;
    const forbid_uturn: u32 = 4;
    const partial_start: u32 = 8;
    const alias_history: u32 = 16;
    const destination_only: u32 = 32;
    const exception_shift = 6;
    const prune_closures: u32 = 1 << 13;
    const excluded_start: u32 = 1 << 14;
    const measured_speed: u32 = 1 << 15;

    pub fn edgeId(self: Label) EdgeId {
        return @fromBackingInt(self.edge);
    }

    pub fn cut(self: Label, cuts: []const Cut) Cut {
        if (self.flags & (partial_start | partial_target) == 0) return .{};
        return cuts[self.ctx - 1];
    }

    pub fn accessState(self: Label) base.AccessState {
        return .{ .destination_only = self.flags & destination_only != 0, .vehicle_exceptions = @truncate(self.flags >> exception_shift) };
    }

    pub fn measuredSpeed(self: Label) bool {
        return self.flags & measured_speed != 0;
    }

    pub fn setTraversal(self: *Label, access: base.AccessState, traversal: Traversal) void {
        self.flags = contextFlags(.{}, access) | traversal.flags();
    }

    fn turnContext(self: Label) TurnContext {
        return .{ .value = self.ctx, .alias = self.flags & alias_history != 0 };
    }

    fn contextFlags(context: TurnContext, access: base.AccessState) u32 {
        return (if (context.alias) alias_history else 0) |
            (if (access.destination_only) destination_only else 0) |
            (@as(u32, access.vehicle_exceptions) << exception_shift);
    }
};

comptime {
    std.debug.assert(@sizeOf(Label) == 32 and @alignOf(Label) == 4);
    std.debug.assert(@offsetOf(Label, "cost") == 0 and @offsetOf(Label, "secs") == 4);
    std.debug.assert(@offsetOf(Label, "pred") == 8 and @offsetOf(Label, "edge") == 12);
    std.debug.assert(@offsetOf(Label, "dist_m") == 16 and @offsetOf(Label, "tcost") == 20);
    std.debug.assert(@offsetOf(Label, "flags") == 24 and @offsetOf(Label, "ctx") == 28);
}

pub const Direction = enum { forward, reverse };

pub const Timing = struct {
    start: graph.time_info.TimeInfo = .{},
    invariant: bool = false,

    pub noinline fn at(self: Timing, view: *const View, node: NodeId, elapsed: f32, direction: Direction) !graph.time_info.TimeInfo {
        if (!self.start.valid) return self.start;
        const zone = try view.nodeTimezone(node);
        const used = if (zone == graph.timezone.unknown) self.start.zone else zone;
        const rules = if (view.tz_rules) |*present| present else null;
        const seconds = if (self.invariant) 0 else elapsed;
        return switch (direction) {
            .forward => try self.start.forward(rules, seconds, used),
            .reverse => try self.start.reverse(rules, seconds, used),
        };
    }

    noinline fn local(self: Timing, view: *const View, node: NodeId, elapsed: f32, direction: Direction) !?graph.datetime.Local {
        const here = try self.at(view, node, elapsed, direction);
        const rules = if (view.tz_rules) |*present| present else null;
        return here.local(rules);
    }
};

pub const Request = struct {
    origin: NodeId,
    destination: NodeId,
    direction: Direction = .forward,
    timing: Timing = .{},
    excluded: []const ExcludedEdge = &.{},
};

pub const PartialRequest = struct {
    starts: []const endpoints.Candidate,
    targets: *const endpoints.Targets,
    direction: Direction = .forward,
    forbid_initial_uturn: bool = false,
    timing: Timing = .{},
    excluded: []const ExcludedEdge = &.{},
};

pub const ExpansionBounds = struct {
    cost: f32 = std.math.inf(f32),
    seconds: f32 = std.math.inf(f32),
    distance_m: u32 = std.math.maxInt(u32),

    fn allows(self: ExpansionBounds, value: costing.Cost, metres: u32) bool {
        return value.cost <= self.cost and value.secs <= self.seconds and metres <= self.distance_m;
    }
};

pub const ExpansionRequest = struct {
    origins: []const NodeId = &.{},
    /// One set of correlated directed edges per origin, in travel order.
    partial_origins: []const []const endpoints.Candidate = &.{},
    direction: Direction = .forward,
    timing: Timing = .{},
    bounds: ExpansionBounds = .{},
    excluded: []const ExcludedEdge = &.{},
    limit: usize = std.math.maxInt(usize),
    unit_size: u32 = 1,
    forbid_initial_uturn: bool = false,
};

pub const ExpansionVisit = struct {
    node: NodeId,
    index: u32,
    label: Label,
    cut: Cut,
    time: graph.time_info.TimeInfo,
};

pub const ExpansionDecision = enum { expand, prune, stop };

const NodeQuery = struct {
    start: NodeId,
    target: ?NodeId = null,
    limit: usize = std.math.maxInt(usize),
    timing: Timing = .{},
    excluded: []const ExcludedEdge = &.{},
};

pub const Cut = struct {
    begin: f32 = 0,
    end: f32 = 1,
};

pub const Control = struct {
    deadline: io.Deadline = .none,
    cancel: ?*const std.atomic.Value(bool) = null,

    pub fn check(self: Control) error{Cancelled}!void {
        if (self.deadline.expired()) return error.Cancelled;
        if (self.cancel) |flag| {
            if (flag.load(.monotonic)) return error.Cancelled;
        }
    }
};

/// Transition operands always follow physical travel order, even when the
/// search is proceeding from the destination back toward the origin.
pub const Transition = struct {
    node: NodeId,
    incoming: EdgeId,
    incoming_edge: *const EdgeHot,
    outgoing: EdgeId,
    outgoing_edge: *const EdgeHot,
    row: TurnEntry,
    incoming_access: base.AccessState = .{},
    outgoing_access: base.AccessState = .{},
    measured_speed: bool = false,
};

pub const Traversal = struct {
    cost: costing.Cost,
    measured_speed: bool = false,

    fn flags(self: Traversal) u32 {
        return if (self.measured_speed) Label.measured_speed else 0;
    }
};

pub inline fn priceEdge(view: *const View, kernel: anytype, id: EdgeId, edge: *const EdgeHot, comptime direction: Direction, time: graph.time_info.TimeInfo, comptime endpoint: bool) !Traversal {
    const K = @TypeOf(kernel);
    if (endpoint and @hasDecl(K, "endpointCostAt")) {
        if (time.valid) return kernel.endpointCostAt(view, id, edge, direction, time);
    }
    if (endpoint and @hasDecl(K, "endpointCost")) return .{ .cost = try kernel.endpointCost(view, id, edge, direction) };
    if (comptime @hasDecl(K, "edgeCostAt")) {
        if (time.valid) return kernel.edgeCostAt(view, id, edge, direction, time);
    }
    if (comptime @hasDecl(K, "edgeTraversal")) return kernel.edgeTraversal(view, id, edge, direction);
    return .{ .cost = try kernel.edgeCost(view, id, edge, direction) };
}

pub inline fn priceTurn(view: *const View, kernel: anytype, movement: Transition, previous: Label, comptime direction: Direction, time: graph.time_info.TimeInfo) !costing.Cost {
    if (comptime @hasDecl(@TypeOf(kernel), "turnCostAt")) {
        if (time.valid) return kernel.turnCostAt(view, movement, previous, direction, time);
    }
    return kernel.turnCost(view, movement, previous, direction);
}

pub const Result = struct {
    labels: []const Label,
    index: u32,
    popped: usize,
    settled: usize,
    cuts: []const Cut = &.{},

    pub fn best(self: Result) *const Label {
        return &self.labels[self.index];
    }
};

pub const SweepStats = struct {
    popped: usize = 0,
    settled: usize = 0,
};

pub const Zero = struct {
    pub fn estimate(_: Zero, _: NodeId) f32 {
        return 0;
    }
};

/// Lower bound for the native graph with integer metre lengths rounded to
/// the nearest metre. A represented nonzero edge is at most half a metre
/// shorter than its shape, so its length is at least two thirds of the
/// great-circle distance between its ends.
pub const L2 = struct {
    coordinates: []const graph.format.Coordinate,
    goal: graph.format.Coordinate,
    cost_per_metre: f64,

    pub fn init(view: *const View, goal: NodeId, lower_cost_per_metre: f32) !L2 {
        if (!std.math.isFinite(lower_cost_per_metre) or lower_cost_per_metre < 0) return error.InvalidPotential;
        return .{
            .coordinates = view.coordinates orelse return error.MissingCoordinates,
            .goal = try view.coordinate(goal),
            .cost_per_metre = lower_cost_per_metre,
        };
    }

    pub fn estimate(self: L2, node: NodeId) f32 {
        return self.estimateAt(node, 0);
    }

    pub fn estimateAt(self: L2, node: NodeId, cost: f32) f32 {
        if (self.cost_per_metre == 0) return 0;
        const here = self.coordinates[@backingInt(node)];
        const metres = here.toPoint().distance(self.goal.toPoint()) * (2.0 / 3.0) * (1 - 0x1p-20);
        const upper: f32 = @floatCast(@min(std.math.floatMax(f32), @as(f64, cost) + metres * self.cost_per_metre));
        const bits: u32 = @bitCast(upper);
        const next: f32 = @bitCast(bits + 1);
        // A competing path cheaper than this estimate never accumulates a
        // cost above upper. Each nonzero-length step can lose at most one
        // float spacing to rounding, and contains at least one metre.
        const spacing = if (std.math.isFinite(next)) @as(f64, next) - upper else @as(f64, upper) - @as(f32, @bitCast(bits - 1));
        return roundedDown(metres * @max(0, self.cost_per_metre - spacing));
    }
};

const Status = packed struct(u32) {
    label_plus_one: u32 = 0,

    // Requests with exclusions reserve label zero as the settled, impassable
    // state so the ordinary dominance check also prunes excluded edges.
    const exclusion: u32 = 1;
};

const PartialExclusion = struct { fraction: f32, seed: Status = .{} };
const ExclusionFractions = paged.Array(?PartialExclusion, null);

const TurnContext = struct {
    value: u32 = 0,
    alias: bool = false,

    const forbidden: TurnContext = .{ .value = no_index };

    fn present(self: TurnContext) bool {
        return self.value != 0 or self.alias;
    }
};

pub const PathAccess = struct {
    view: *const View,
    permission: base.Permission,
    direction: Direction,
    timing: Timing,
    control: Control,
    check_access: bool,

    pub const Position = enum { start, middle, end };

    pub inline fn evaluate(self: PathAccess, id: EdgeId, edge: *const EdgeHot, node: NodeId, previous: Label, position: Position) !base.AccessEvaluation {
        const class = try self.view.class(edge.cls.class_id);
        // The directed not_thru bit is Valhalla's search hint. Admission
        // here follows the edge's access rules on the first search.
        const restricted = self.permission.destinationOnly(class);
        const access_modes: u16 = @bitCast(self.permission.access_mask);
        var evaluation: base.AccessEvaluation = .{};
        if (self.check_access and edge.cls.cold_checks != 0 and class.detail.access_restriction & access_modes != 0) {
            evaluation = try self.evaluateConditionalAccess(id, node, previous, position);
        }
        evaluation.state.destination_only = evaluation.state.destination_only or restricted;
        return evaluation;
    }

    noinline fn evaluateConditionalAccess(self: PathAccess, id: EdgeId, node: NodeId, previous: Label, position: Position) !base.AccessEvaluation {
        const local = try self.timing.local(self.view, node, previous.secs, self.direction);
        try self.control.check();
        const record = try self.view.coldRecordWithDeadline(id, self.control.deadline);
        if (position == .start) {
            // Valhalla starts on the snapped edge and records the access
            // exemptions needed to leave a restricted area.
            return .{ .state = try self.permission.startingAccess(record.access_limits, !record.reverse, local, self.control.deadline) };
        }
        var prior = previous.accessState();
        if (previous.edge != no_index and !prior.destination_only) {
            const previous_class = try self.view.class((try self.view.edge(previous.edgeId())).cls.class_id);
            prior.destination_only = self.permission.destinationOnly(previous_class);
        }
        var permission = self.permission;
        permission.allow_destination_only = permission.allow_destination_only or position == .end;
        return permission.evaluateRestrictions(record.access_limits, !record.reverse, local, prior, null, self.control.deadline);
    }
};

const Restrictions = struct {
    const AliasKey = struct {
        edge: u32,
        value: u32,
        previous_edge: bool,
        elapsed: u32 = 0,
        access_flags: u32 = 0,
    };
    const AliasStatus = std.AutoHashMapUnmanaged(AliasKey, Status);

    access: PathAccess,
    states: []const automaton.State,
    modes: u16,
    has_exclusions: bool,
    keep_time: bool,
    aliases: AliasStatus = .empty,

    noinline fn advance(self: *const Restrictions, context: TurnContext, previous: Label, node: NodeId, id: EdgeId) !TurnContext {
        if (self.modes == 0) return .{};
        const simple = if (self.access.view.turn_restrictions) |rows| rows.len != 0 else false;
        if (!simple and self.states.len == 0) return .{};
        const edge = try self.access.view.edge(id);
        const class = try self.access.view.class(edge.cls.class_id);
        const flagged = simple and previous.edge != no_index and (try self.access.view.node(node)).attr.has_turn_restrictions;
        if (class.flags.node_connector) {
            if (context.present()) return context;
            return if (flagged) .{ .value = previous.edge, .alias = true } else .{};
        }
        if (flagged) {
            const predecessor: EdgeId = @fromBackingInt(if (context.alias) context.value else if (context.present()) self.states[context.value].edge else previous.edge);
            const modes = if (self.access.direction == .forward) self.access.view.turnRestrictionModes(predecessor, id) else self.access.view.turnRestrictionModes(id, predecessor);
            if (modes & self.modes != 0) return .forbidden;
        }
        if (self.states.len == 0) return .{};
        var parent = context.value;
        if (context.alias or parent == 0) {
            const start = if (self.access.direction == .forward) class.restrictions.start else class.restrictions.end;
            if (start & self.modes == 0) return .{};
            parent = if (self.access.direction == .forward) automaton.forward_root else automaton.reverse_root;
        }
        const next = automaton.advance(self.states, parent, @backingInt(id));
        const attributes = self.states[next].attr;
        if (attributes.forbidden & self.modes != 0) return .forbidden;
        if (attributes.timed) {
            if (try self.access.timing.local(self.access.view, node, previous.secs, self.access.direction)) |local| {
                try self.access.control.check();
                if (try automaton.blocksTimed(self.states, self.access.view.restriction_conditions orelse &.{}, next, self.modes, local, self.access.control.deadline)) return .forbidden;
            }
        }
        return if (next < automaton.first_context) .{} else .{ .value = next };
    }

    fn statusId(self: *const Restrictions, edge: u32, context: TurnContext) ?u32 {
        if (context.alias or self.states[context.value].edge != edge) return null;
        return @as(u32, @intCast(self.access.view.edges.len)) + (context.value - automaton.first_context);
    }

    fn aliasKey(edge: u32, context: TurnContext) AliasKey {
        return .{ .edge = edge, .value = context.value, .previous_edge = context.alias };
    }

    fn timedKey(label: Label, context: TurnContext) AliasKey {
        var key = aliasKey(label.edge, context);
        key.elapsed = @bitCast(label.secs);
        const access = Label.destination_only | (0x7f << Label.exception_shift) | Label.prune_closures |
            Label.excluded_start | Label.forbid_uturn | Label.measured_speed;
        key.access_flags = label.flags & access;
        return key;
    }
};

const TemporalInputs = struct {
    speeds: base.Flow = .{},
    access_modes: u16 = 0,
};

/// K supplies edgeCost(view, edge_id, hot, direction), turnCost(view,
/// transition, predecessor, direction), and optionally slowAllowed for
/// cold edges, allowedTurn for checking a pair of directed edges and
/// restrictionModes() or restrictionPermission() for selecting conditional
/// and complex restrictions (defaults to auto). A concrete closed(edge)
/// policy supplies current-traffic closures when Permission enables them.
/// Timed kernels can supply edgeCostAt and endpointCostAt returning a
/// Traversal, and turnCostAt with TimeInfo after the usual parameters.
/// edgeTraversal supplies source information in the untimed search too.
/// A graph-only timed kernel can use timeDependentCosts(Flow) to detect
/// whether the graph's populated speed layers can change its prices.
/// All weighted costs must be nonnegative. A state is the last directed edge
/// and the matched restriction prefix, with elapsed time when costs or
/// restrictions can change along the route.
/// The cost and admissibility of future steps must be independent of the
/// path to that state. Queue entries use nonnegative f32 ordering.
pub fn Search(comptime K: type, comptime Q: type) type {
    return struct {
        const Self = @This();
        const Pool = memory.PagePool(16 * 1024);
        const timed_costs = @hasDecl(K, "edgeCostAt") or @hasDecl(K, "turnCostAt") or @hasDecl(K, "endpointCostAt");
        const model_access = @hasDecl(K, "restrictionPermission");

        view: *const View,
        allocator: std.mem.Allocator,
        status: paged.EdgeStatus(Status),
        temporal_inputs: ?TemporalInputs = null,

        pub fn init(allocator: std.mem.Allocator, view: *const View) !Self {
            const virtual = if (view.restriction_automaton) |states| states.len - automaton.first_context else 0;
            return .{ .view = view, .allocator = allocator, .status = try .init(allocator, view.edges.len + virtual) };
        }

        pub fn deinit(self: *Self) void {
            self.status.deinit(self.allocator);
            self.* = undefined;
        }

        /// Result labels live in the request arena until the caller rewinds it.
        /// The arena may also contain request options, so search only clears
        /// its own persistent directory entries.
        pub fn run(self: *Self, arena: *memory.Arena, kernel: K, request: Request, potential: anytype, control: Control) !Result {
            try control.check();
            _ = try self.view.node(request.origin);
            _ = try self.view.node(request.destination);
            defer self.status.clear();
            return switch (request.direction) {
                .forward => self.runDirection(.forward, arena, kernel, NodeQuery{ .start = request.origin, .target = request.destination, .timing = request.timing, .excluded = request.excluded }, potential, control),
                .reverse => self.runDirection(.reverse, arena, kernel, NodeQuery{ .start = request.destination, .target = request.origin, .timing = request.timing, .excluded = request.excluded }, potential, control),
            };
        }

        /// The potential must bound the remaining cost to every usable
        /// destination edge, including a stop before the edge's far node.
        pub fn runPartial(self: *Self, arena: *memory.Arena, kernel: K, request: PartialRequest, potential: anytype, control: Control) !Result {
            try control.check();
            defer self.status.clear();
            return switch (request.direction) {
                .forward => self.runDirection(.forward, arena, kernel, request, potential, control),
                .reverse => self.runDirection(.reverse, arena, kernel, request, potential, control),
            };
        }

        /// Use the identical relaxation loop as a bounded Dijkstra sweep,
        /// including an exhausted component smaller than the label limit.
        pub fn sweep(self: *Self, arena: *memory.Arena, kernel: K, source: NodeId, direction: Direction, limit: usize, control: Control) !SweepStats {
            try control.check();
            _ = try self.view.node(source);
            if (limit == 0) return .{};
            defer self.status.clear();
            const result = try switch (direction) {
                .forward => self.runDirection(.forward, arena, kernel, NodeQuery{ .start = source, .limit = limit }, Zero{}, control),
                .reverse => self.runDirection(.reverse, arena, kernel, NodeQuery{ .start = source, .limit = limit }, Zero{}, control),
            };
            return .{ .popped = result.popped, .settled = result.settled };
        }

        pub fn expand(self: *Self, arena: *memory.Arena, kernel: K, request: ExpansionRequest, visitor: anytype, control: Control) !SweepStats {
            try control.check();
            if (!(request.bounds.cost >= 0 and request.bounds.seconds >= 0)) return error.InvalidExpansionBounds;
            if (request.limit == 0) return .{};
            defer self.status.clear();
            const query = .{
                .expansion = request,
                .timing = request.timing,
                .excluded = request.excluded,
                .limit = request.limit,
                .forbid_initial_uturn = request.forbid_initial_uturn,
                .visitor = visitor,
            };
            const result = try switch (request.direction) {
                .forward => self.runDirection(.forward, arena, kernel, query, Zero{}, control),
                .reverse => self.runDirection(.reverse, arena, kernel, query, Zero{}, control),
            };
            return .{ .popped = result.popped, .settled = result.settled };
        }

        fn runDirection(self: *Self, comptime direction: Direction, arena: *memory.Arena, kernel: K, query: anytype, potential: anytype, control: Control) !Result {
            const permission: base.Permission = if (model_access) kernel.restrictionPermission() else .{
                .flags = .empty,
                .flow = .{},
                .access_mask = if (comptime @hasDecl(K, "restrictionModes")) @bitCast(kernel.restrictionModes()) else .{ .auto = true },
                .filter_closures = false,
            };
            const modes = permission.restrictionModes();
            const simple = if (self.view.turn_restrictions) |rows| rows.len != 0 else false;
            const check_access = !permission.flags.contains(.ignore_restrictions) and (query.timing.start.valid or model_access);
            const keep_time = query.timing.start.valid and !query.timing.invariant and
                try self.keepTime(kernel, permission, check_access, control);
            if (model_access or check_access or (timed_costs and query.timing.start.valid) or (modes != 0 and (simple or self.view.restriction_automaton != null)))
                return self.runLoop(direction, true, arena, kernel, query, potential, control, permission, check_access, keep_time);
            return self.runLoop(direction, false, arena, kernel, query, potential, control, permission, false, false);
        }

        fn keepTime(self: *Self, kernel: K, permission: base.Permission, check_access: bool, control: Control) !bool {
            const graph_costs = timed_costs and @hasDecl(K, "timeDependentCosts");
            if (timed_costs and !graph_costs) return true;
            if (permission.restrictionModes() != 0) {
                if (self.view.restriction_conditions) |conditions| if (conditions.len != 0) return true;
            }
            const timed_access = check_access and !permission.flags.contains(.ignore_non_vehicular_restrictions) and self.view.cold_data != null;
            if (!graph_costs and !timed_access) return false;
            const inputs = self.temporal_inputs orelse try self.scanTemporalInputs(control);
            if (timed_access and inputs.access_modes & @as(u16, @bitCast(permission.access_mask)) != 0) return true;
            if (graph_costs) return kernel.timeDependentCosts(inputs.speeds);
            return false;
        }

        noinline fn scanTemporalInputs(self: *Self, control: Control) !TemporalInputs {
            var inputs: TemporalInputs = .{};
            for (self.view.edges, 0..) |*edge, i| {
                if (i % 1024 == 0) try control.check();
                inputs.speeds.freeflow = inputs.speeds.freeflow or edge.speed[1] != 0;
                inputs.speeds.constrained = inputs.speeds.constrained or edge.speed[2] != 0;
                if (edge.cls.cold_checks == 0 or self.view.cold_data == null or self.view.classes == null) continue;
                const class = try self.view.class(edge.cls.class_id);
                if (class.detail.access_restriction & ~inputs.access_modes == 0) continue;
                const record = try self.view.coldRecordWithDeadline(@fromBackingInt(@as(u32, @intCast(i))), control.deadline);
                var limits = record.restrictions();
                while (limits.next()) |limit| {
                    try control.check();
                    if (limit.attr.kind.timed()) inputs.access_modes |= limit.modes();
                }
            }
            self.temporal_inputs = inputs;
            return inputs;
        }

        fn runLoop(self: *Self, comptime direction: Direction, comptime with_restrictions: bool, arena: *memory.Arena, kernel: K, query: anytype, potential: anytype, control: Control, permission: base.Permission, check_access: bool, keep_time: bool) !Result {
            const partial = @TypeOf(query) == PartialRequest;
            const expanding = @hasField(@TypeOf(query), "expansion");
            const partial_starts = partial or expanding;
            const target = if (partial_starts) null else query.target;
            const limit = if (partial) std.math.maxInt(usize) else query.limit;
            const a = arena.allocator();
            var pool: Pool = .init(arena);
            var labels: std.ArrayList(Label) = .empty;
            if (!partial_starts and target != null and query.start == target.?) {
                try labels.append(a, .{ .flags = Label.target });
                return .{ .labels = labels.items, .index = 0, .popped = 0, .settled = 0 };
            }
            var cuts: std.ArrayList(Cut) = .empty;
            var pending: Q = if (@hasDecl(Q, "init"))
                try Q.init(if (expanding) query.expansion.unit_size else 1)
            else
                .{};
            var restrictions: if (with_restrictions) Restrictions else void = if (with_restrictions) .{
                .access = .{
                    .view = self.view,
                    .permission = permission,
                    .direction = direction,
                    .timing = query.timing,
                    .control = control,
                    .check_access = check_access,
                },
                .states = self.view.restriction_automaton orelse &.{},
                .modes = permission.restrictionModes(),
                .has_exclusions = query.excluded.len != 0,
                .keep_time = keep_time,
            } else {};
            const tracker = if (with_restrictions) &restrictions else null;
            var fractions: ?*ExclusionFractions = null;
            if (query.excluded.len != 0) {
                try labels.append(a, .{ .cost = -std.math.inf(f32) });
                if (partial_starts) {
                    fractions = try a.create(ExclusionFractions);
                    fractions.?.* = .{};
                }
                try self.markExcluded(&pool, query.excluded, fractions, control);
            }
            if (expanding) {
                for (query.expansion.partial_origins) |candidates| {
                    try control.check();
                    try self.seedPartials(direction, &pool, kernel, query, candidates, &labels, &cuts, &pending, potential, tracker, fractions, permission, control);
                }
                for (query.expansion.origins) |origin| {
                    try control.check();
                    try self.seedNode(direction, &pool, kernel, origin, null, query.timing, &labels, &pending, potential, tracker, permission, query.excluded.len != 0, query.expansion.bounds);
                }
            } else if (partial) {
                try self.seedPartials(direction, &pool, kernel, query, query.starts, &labels, &cuts, &pending, potential, tracker, fractions, permission, control);
            } else {
                try self.seedNode(direction, &pool, kernel, query.start, target, query.timing, &labels, &pending, potential, tracker, permission, query.excluded.len != 0, null);
            }

            var popped: usize = 0;
            var settled: usize = 0;
            while (if (@hasDecl(Q, "popWithin")) try pending.popWithin(a, control) else pending.pop()) |top| {
                popped += 1;
                if ((popped & 1023) == 0) try control.check();
                const last = labels.items[top.label];
                const context: TurnContext = if (with_restrictions)
                    if (last.flags & Label.partial_target != 0) .{} else if (last.flags & Label.partial_start != 0)
                        try tracker.advance(.{}, .{}, @fromBackingInt(@as(u32, 0)), last.edgeId())
                    else
                        last.turnContext()
                else
                    .{};
                if (last.flags & Label.partial_target == 0) {
                    const active: Status = if (with_restrictions and tracker.keep_time)
                        tracker.aliases.get(Restrictions.timedKey(last, context)) orelse Status{}
                    else if (partial_starts and last.flags & Label.excluded_start != 0)
                        fractions.?.get(last.edge).?.seed
                    else
                        self.findStatus(tracker, last.edge, context);
                    if (active.label_plus_one != top.label + 1) continue;
                }
                settled += 1;
                if (!expanding and (last.flags & Label.target != 0 or settled == limit)) {
                    try control.check();
                    return .{ .labels = labels.items, .index = top.label, .popped = popped, .settled = settled, .cuts = cuts.items };
                }

                const previous_id = last.edgeId();
                const previous_edge = &self.view.edges[last.edge];
                const geometry = if (direction == .forward) previous_edge else try self.view.edge(try self.view.oppEdge(previous_id));
                const at: NodeId = @fromBackingInt(geometry.head);
                const visits = expanding and @TypeOf(query.visitor) != void;
                const time: graph.time_info.TimeInfo = if (timed_costs or (visits and query.timing.start.valid))
                    try query.timing.at(self.view, at, last.secs, direction)
                else
                    .{};
                if (expanding) {
                    const decision: ExpansionDecision = if (visits)
                        try query.visitor.visit(.{ .node = at, .index = top.label, .label = last, .cut = last.cut(cuts.items), .time = time })
                    else
                        .expand;
                    if (settled == limit or decision == .stop) {
                        try control.check();
                        return .{ .labels = labels.items, .index = top.label, .popped = popped, .settled = settled, .cuts = cuts.items };
                    }
                    if (decision == .prune) continue;
                }
                const exits = try self.view.outEdgeRange(at);
                const forward_row = if (direction == .forward) try self.view.turnRow(at, geometry.cls.opp_local) else &.{};
                for (self.view.edges[exits.first..exits.end], exits.first.., 0..) |*outward, index, local| {
                    if (partial_starts and last.flags & Label.forbid_uturn != 0 and local == geometry.cls.opp_local) continue;
                    const local_id: EdgeId = @fromBackingInt(@as(u32, @intCast(index)));
                    const next_id = if (direction == .forward) local_id else try self.view.oppEdge(local_id);
                    const next_context: TurnContext = if (with_restrictions) try tracker.advance(context, last, at, next_id) else .{};
                    if (with_restrictions and next_context.value == no_index) continue;
                    const prior = self.findStatus(tracker, @backingInt(next_id), next_context);
                    const dominated = prior.label_plus_one != 0 and labels.items[prior.label_plus_one - 1].cost <= last.cost;
                    var targets = if (partial) query.targets.on(next_id) else {};
                    if (dominated and (!partial or targets.index == 0)) continue;
                    const next = if (direction == .forward) outward else try self.view.edge(next_id);
                    const closed = try self.edgeClosed(kernel, permission, next_id);
                    if (closed and last.flags & Label.prune_closures != 0) continue;
                    const head: NodeId = @fromBackingInt(outward.head);
                    const access = if (with_restrictions and (model_access or (check_access and next.cls.cold_checks != 0)))
                        try tracker.access.evaluate(next_id, next, at, last, if (target != null and head == target.?) .end else .middle)
                    else
                        base.AccessEvaluation{};
                    if (!access.allowed) {
                        if (!partial or targets.index == 0 or permission.allow_destination_only) continue;
                        const endpoint_access = if (with_restrictions)
                            try tracker.access.evaluate(next_id, next, at, last, .end)
                        else
                            base.AccessEvaluation{};
                        if (!endpoint_access.allowed) continue;
                    }
                    const previous_access: base.AccessState = if (with_restrictions) last.accessState() else .{};
                    const row = if (direction == .forward)
                        forward_row[local]
                    else blk: {
                        const reverse_row = try self.view.turnRow(at, outward.cls.local);
                        if (geometry.cls.opp_local >= reverse_row.len) return error.InvalidLocalEdge;
                        break :blk reverse_row[geometry.cls.opp_local];
                    };
                    var movement: Transition = .{
                        .node = at,
                        .incoming = if (direction == .forward) previous_id else next_id,
                        .incoming_edge = if (direction == .forward) previous_edge else next,
                        .outgoing = if (direction == .forward) next_id else previous_id,
                        .outgoing_edge = if (direction == .forward) next else previous_edge,
                        .row = row,
                        .incoming_access = if (direction == .forward) previous_access else access.state,
                        .outgoing_access = if (direction == .forward) access.state else previous_access,
                    };
                    if (comptime @hasDecl(K, "allowedTurn")) {
                        if (!try kernel.allowedTurn(self.view, movement, last, direction)) continue;
                    } else if (row & 0x80 != 0 and permission.restrictionModes() != 0) continue;
                    if (comptime @hasDecl(K, "slowAllowed")) {
                        if (next.cls.cold_checks != 0 and !try Self.slowAllowed(kernel, self.view, next_id, next, last, direction)) continue;
                    }
                    const traversal = try priceEdge(self.view, kernel, next_id, next, direction, time, false);
                    const edge_cost = traversal.cost;
                    if (edge_cost.cost == std.math.inf(f32)) continue;
                    movement.measured_speed = if (direction == .forward) last.measuredSpeed() else traversal.measured_speed;
                    const delay = try priceTurn(self.view, kernel, movement, last, direction, time);
                    if (delay.cost == std.math.inf(f32)) continue;
                    const previous: costing.Cost = .{ .cost = last.cost, .secs = last.secs };
                    if (partial) {
                        var count: usize = 0;
                        while (targets.next()) |candidate| : (count += 1) {
                            if (count % 64 == 0) try control.check();
                            if (fractions != null and prior.label_plus_one == Status.exclusion and
                                cutsExcluded(fractions.?.get(@backingInt(next_id)).?.fraction, candidate.fraction, direction == .reverse)) continue;
                            const cut: Cut = if (direction == .forward) .{ .end = candidate.fraction } else .{ .begin = candidate.fraction };
                            const step = scale(edge_cost, cut.end - cut.begin, 0);
                            const ending = previous.add(delay).add(step).add(.{ .cost = candidate.score });
                            try addTerminal(a, &labels, &cuts, &pending, cut, .{
                                .edge = @backingInt(next_id),
                                .pred = top.label,
                                .cost = ending.cost,
                                .secs = ending.secs,
                                .dist_m = last.dist_m +| fractionalLength(next.geom.len_m, cut),
                                .tcost = delay.cost,
                                .flags = Label.contextFlags(.{}, access.state),
                            });
                        }
                    }
                    if (dominated or !access.allowed) continue;
                    const total = if (partial)
                        previous.add(delay).add(edge_cost)
                    else if (expanding)
                        previous.add(edge_cost).add(delay)
                    else
                        previous.add(edge_cost.add(delay));
                    if (total.cost == std.math.inf(f32)) continue;
                    const metres = last.dist_m +| next.geom.len_m;
                    if (expanding and !query.expansion.bounds.allows(total, metres)) continue;
                    try self.offer(&pool, &labels, &pending, potential, target, head, prior, tracker, next_context, .{
                        .edge = @backingInt(next_id),
                        .pred = top.label,
                        .cost = total.cost,
                        .secs = total.secs,
                        .dist_m = metres,
                        .tcost = delay.cost,
                        .ctx = next_context.value,
                        .flags = Label.contextFlags(next_context, access.state) | closureFlag(!closed) | traversal.flags(),
                    }, null);
                }
            }
            try control.check();
            if (!partial and target == null) return .{ .labels = labels.items, .index = no_index, .popped = popped, .settled = settled, .cuts = cuts.items };
            return error.NoPath;
        }

        noinline fn markExcluded(self: *Self, pool: *Pool, edges: []const ExcludedEdge, fractions: ?*ExclusionFractions, control: Control) !void {
            for (edges, 0..) |edge, i| {
                if (i % 256 == 0) try control.check();
                _ = try self.view.edge(edge.id);
                if (!(0 <= edge.percent_along and edge.percent_along <= 1)) return error.InvalidExclusionFraction;
                const id = @backingInt(edge.id);
                const status = try self.status.at(pool, id);
                if (status.label_plus_one == Status.exclusion) continue;
                status.label_plus_one = Status.exclusion;
                if (fractions) |table| (try table.at(pool.arena.allocator(), id)).* = .{ .fraction = edge.percent_along };
            }
            if (self.view.restriction_automaton) |states| {
                const base_id: u32 = @intCast(self.view.edges.len);
                for (states[automaton.first_context..], 0..) |state, i| {
                    if (i % 256 == 0) try control.check();
                    if (self.status.get(state.edge).label_plus_one == Status.exclusion) {
                        (try self.status.at(pool, base_id + @as(u32, @intCast(i)))).label_plus_one = Status.exclusion;
                    }
                }
            }
        }

        fn seedNode(self: *Self, comptime direction: Direction, pool: *Pool, kernel: K, start: NodeId, target: ?NodeId, timing: Timing, labels: *std.ArrayList(Label), pending: *Q, potential: anytype, tracker: anytype, permission: base.Permission, has_exclusions: bool, bounds: anytype) !void {
            const seeds = try self.view.outEdgeRange(start);
            const time: graph.time_info.TimeInfo = if (timed_costs) try timing.at(self.view, start, 0, direction) else .{};
            for (self.view.edges[seeds.first..seeds.end], seeds.first..) |*outward, index| {
                const geometry_id: EdgeId = @fromBackingInt(@as(u32, @intCast(index)));
                const id = if (direction == .forward) geometry_id else try self.view.oppEdge(geometry_id);
                if (has_exclusions and self.status.get(@backingInt(id)).label_plus_one == Status.exclusion) continue;
                const edge = if (direction == .forward) outward else try self.view.edge(id);
                const closed = try self.edgeClosed(kernel, permission, id);
                if (closed and permission.filter_closures) continue;
                if (comptime @hasDecl(K, "slowAllowed")) {
                    if (edge.cls.cold_checks != 0 and !try Self.slowAllowed(kernel, self.view, id, edge, null, direction)) continue;
                }
                const traversal = try priceEdge(self.view, kernel, id, edge, direction, time, false);
                const edge_cost = traversal.cost;
                if (edge_cost.cost == std.math.inf(f32)) continue;
                if (@TypeOf(bounds) != @TypeOf(null) and !bounds.allows(edge_cost, edge.geom.len_m)) continue;
                const here: NodeId = @fromBackingInt(outward.head);
                const access = if (@TypeOf(tracker) != @TypeOf(null) and (model_access or (tracker.access.check_access and edge.cls.cold_checks != 0)))
                    try tracker.access.evaluate(id, edge, start, .{}, .start)
                else
                    base.AccessEvaluation{};
                if (!access.allowed) continue;
                const context: TurnContext = if (@TypeOf(tracker) == @TypeOf(null)) .{} else try tracker.advance(.{}, .{}, start, id);
                try self.offer(pool, labels, pending, potential, target, here, self.findStatus(tracker, @backingInt(id), context), tracker, context, .{
                    .edge = @backingInt(id),
                    .cost = edge_cost.cost,
                    .secs = edge_cost.secs,
                    .dist_m = edge.geom.len_m,
                    .ctx = context.value,
                    .flags = Label.contextFlags(context, access.state) | closureFlag(!closed) | traversal.flags(),
                }, null);
            }
        }

        fn seedPartials(self: *Self, comptime direction: Direction, pool: *Pool, kernel: K, query: anytype, starts: []const endpoints.Candidate, labels: *std.ArrayList(Label), cuts: *std.ArrayList(Cut), pending: *Q, potential: anytype, tracker: anytype, fractions: ?*ExclusionFractions, permission: base.Permission, control: Control) !void {
            const expanding = @hasField(@TypeOf(query), "expansion");
            const a = pool.arena.allocator();
            var has_departure = false;
            if (expanding) {
                for (starts, 0..) |candidate, index| {
                    if (index % 64 == 0) try control.check();
                    const arrival = if (direction == .forward) candidate.end_node else candidate.begin_node;
                    if (!arrival) {
                        has_departure = true;
                        break;
                    }
                }
            }
            for (starts, 0..) |candidate, index| {
                if (index % 64 == 0) try control.check();
                if (!candidate.valid()) return error.InvalidCandidate;
                const at_node = if (direction == .forward) candidate.end_node else candidate.begin_node;
                if (expanding and has_departure and at_node) continue;
                const id = candidate.edge;
                const edge = try self.view.edge(id);
                const excluded: ?*PartialExclusion = if (fractions) |table| blk: {
                    if (table.get(@backingInt(id)) == null) break :blk null;
                    break :blk &(try table.at(a, @backingInt(id))).*.?;
                } else null;
                if (excluded) |entry| if (cutsExcluded(entry.fraction, candidate.fraction, direction == .forward)) continue;
                const closed = try self.edgeClosed(kernel, permission, id);
                if (closed and permission.filter_closures) continue;
                const price_at_time = timed_costs and query.timing.start.valid;
                const check_limits = @TypeOf(tracker) != @TypeOf(null) and tracker.access.check_access and edge.cls.cold_checks != 0;
                const tail: NodeId = if (price_at_time or check_limits)
                    @fromBackingInt(if (direction == .forward) (try self.view.edge(try self.view.oppEdge(id))).head else edge.head)
                else
                    @fromBackingInt(edge.head);
                const time: graph.time_info.TimeInfo = if (price_at_time) try query.timing.at(self.view, tail, 0, direction) else .{};
                const traversal = try priceEdge(self.view, kernel, id, edge, direction, time, true);
                const full = traversal.cost;
                if (full.cost == std.math.inf(f32)) continue;
                const geometry = if (direction == .forward) edge else try self.view.edge(try self.view.oppEdge(id));
                const node: NodeId = @fromBackingInt(geometry.head);
                const portion: Cut = if (direction == .forward) .{ .begin = candidate.fraction } else .{ .end = candidate.fraction };
                const fraction = portion.end - portion.begin;
                const cost = scale(full, @max(fraction, std.math.floatEps(f32)), candidate.score);
                // Valhalla's Dijkstra seed stores the partial length in a
                // uint32_t path distance, dropping any fractional metre.
                const metres = if (expanding)
                    @as(u32, @intFromFloat(@as(f32, @floatFromInt(edge.geom.len_m)) * fraction))
                else
                    fractionalLength(edge.geom.len_m, portion);
                if (expanding and !query.expansion.bounds.allows(cost, metres)) continue;
                const access = if (@TypeOf(tracker) != @TypeOf(null) and (model_access or check_limits))
                    try tracker.access.evaluate(id, edge, tail, .{}, .start)
                else
                    base.AccessEvaluation{};
                if (!access.allowed) continue;
                try cuts.append(a, portion);
                const context: TurnContext = if (@TypeOf(tracker) == @TypeOf(null)) .{} else try tracker.advance(.{}, .{}, node, id);
                var label: Label = .{
                    .edge = @backingInt(id),
                    .cost = cost.cost,
                    .secs = cost.secs,
                    .dist_m = metres,
                    .flags = Label.contextFlags(context, access.state) | Label.partial_start | closureFlag(!closed) | traversal.flags() |
                        (if (query.forbid_initial_uturn and at_node and portion.begin == portion.end) Label.forbid_uturn else 0),
                    .ctx = std.math.cast(u32, cuts.items.len) orelse return error.TooManySearchLabels,
                };
                if (excluded) |entry| {
                    label.flags |= Label.excluded_start;
                    try self.offer(pool, labels, pending, potential, null, node, entry.seed, tracker, context, label, &entry.seed);
                } else {
                    try self.offer(pool, labels, pending, potential, null, node, self.findStatus(tracker, @backingInt(id), context), tracker, context, label, null);
                }
                if (expanding) continue;
                var dest = query.targets.on(id);
                var count: usize = 0;
                while (dest.next()) |match| : (count += 1) {
                    if (count % 64 == 0) try control.check();
                    if (excluded) |entry| if (cutsExcluded(entry.fraction, match.fraction, direction == .reverse)) continue;
                    const cut: Cut = if (direction == .forward)
                        .{ .begin = candidate.fraction, .end = match.fraction }
                    else
                        .{ .begin = match.fraction, .end = candidate.fraction };
                    if (cut.end < cut.begin) continue;
                    const direct = scale(full, @max(cut.end - cut.begin, std.math.floatEps(f32)), candidate.score + match.score);
                    try addTerminal(a, labels, cuts, pending, cut, .{
                        .edge = @backingInt(id),
                        .cost = direct.cost,
                        .secs = direct.secs,
                        .dist_m = fractionalLength(edge.geom.len_m, cut),
                        .flags = Label.contextFlags(.{}, access.state),
                    });
                }
            }
        }

        fn addTerminal(a: std.mem.Allocator, labels: *std.ArrayList(Label), cuts: *std.ArrayList(Cut), pending: *Q, cut: Cut, label: Label) !void {
            const index = std.math.cast(u32, labels.items.len) orelse return error.TooManySearchLabels;
            if (index == no_index) return error.TooManySearchLabels;
            try cuts.append(a, cut);
            var terminal = label;
            terminal.flags |= Label.target | Label.partial_target;
            terminal.ctx = std.math.cast(u32, cuts.items.len) orelse return error.TooManySearchLabels;
            try labels.append(a, terminal);
            try pending.push(a, queue.Entry.init(label.cost, index));
        }

        noinline fn slowAllowed(kernel: K, view: *const View, id: EdgeId, edge: *const EdgeHot, predecessor: ?Label, comptime direction: Direction) !bool {
            return try kernel.slowAllowed(view, id, edge, predecessor, direction);
        }

        fn closureFlag(prune: bool) u32 {
            if (comptime !@hasDecl(K, "closed")) return 0;
            return if (prune) Label.prune_closures else 0;
        }

        fn edgeClosed(self: *Self, kernel: K, permission: base.Permission, id: EdgeId) !bool {
            if (comptime !@hasDecl(K, "closed")) return false;
            if (!permission.usesClosures()) return false;
            return self.readClosure(kernel, id);
        }

        noinline fn readClosure(self: *Self, kernel: K, id: EdgeId) !bool {
            return kernel.closed(try DirectedEdge.read(self.view, id));
        }

        inline fn findStatus(self: *Self, tracker: anytype, edge: u32, context: TurnContext) Status {
            if (@TypeOf(tracker) == @TypeOf(null) or tracker.keep_time or !context.present()) return self.status.get(edge);
            if (tracker.statusId(edge, context)) |id| return self.status.get(id);
            if (tracker.has_exclusions and self.status.get(edge).label_plus_one == Status.exclusion) return .{ .label_plus_one = Status.exclusion };
            return tracker.aliases.get(Restrictions.aliasKey(edge, context)) orelse .{};
        }

        fn offer(self: *Self, pool: *Pool, labels: *std.ArrayList(Label), pending: *Q, potential: anytype, target: ?NodeId, head: NodeId, status: Status, tracker: anytype, context: TurnContext, label: Label, seed_slot: anytype) !void {
            const use_time = @TypeOf(tracker) != @TypeOf(null) and tracker.keep_time;
            const key = if (use_time) Restrictions.timedKey(label, context) else undefined;
            const previous = if (use_time and status.label_plus_one != Status.exclusion)
                tracker.aliases.get(key) orelse Status{}
            else
                status;
            if (previous.label_plus_one != 0 and labels.items[previous.label_plus_one - 1].cost <= label.cost) return;
            if (@backingInt(head) >= self.view.nodes.len) return error.InvalidEdgeHead;
            // A better label may reopen a state for an inconsistent, but
            // admissible, potential. Stale heap entries are skipped on pop.
            const index = std.math.cast(u32, labels.items.len) orelse return error.TooManySearchLabels;
            if (index == no_index) return error.TooManySearchLabels;
            const done = target != null and head == target.?;
            const estimate: f32 = if (done) 0 else if (comptime @hasDecl(@TypeOf(potential), "estimateAt"))
                potential.estimateAt(head, label.cost)
            else
                potential.estimate(head);
            if (!std.math.isFinite(estimate) or estimate < 0) return error.InvalidPotential;
            var record = label;
            if (done) record.flags |= Label.target;
            const a = pool.arena.allocator();
            const slot = if (use_time) timed: {
                const entry = try tracker.aliases.getOrPutValue(a, key, .{});
                break :timed entry.value_ptr;
            } else if (@TypeOf(seed_slot) != @TypeOf(null)) seed_slot else if (@TypeOf(tracker) == @TypeOf(null) or !context.present()) try self.status.at(pool, label.edge) else blk: {
                if (tracker.statusId(label.edge, context)) |id| break :blk try self.status.at(pool, id);
                const entry = try tracker.aliases.getOrPutValue(a, Restrictions.aliasKey(label.edge, context), .{});
                break :blk entry.value_ptr;
            };
            try labels.append(a, record);
            try pending.push(a, queue.Entry.init(roundedDown(@as(f64, label.cost) + estimate), index));
            slot.* = .{ .label_plus_one = index + 1 };
            @prefetch(&self.view.first_edge[@backingInt(head)], .{});
        }
    };
}

fn cutsExcluded(excluded: f32, endpoint: f32, origin: bool) bool {
    return if (origin) excluded >= endpoint else excluded <= endpoint;
}

fn scale(cost: costing.Cost, portion: f32, score: f32) costing.Cost {
    return (costing.Cost{ .cost = cost.cost * portion, .secs = cost.secs * portion }).add(.{ .cost = score });
}

fn fractionalLength(metres: u24, cut: Cut) u32 {
    const length: f32 = @floatFromInt(metres);
    return @intFromFloat(length * (cut.end - cut.begin) + 0.5);
}

fn roundedDown(value: f64) f32 {
    const rounded: f32 = @floatCast(@min(std.math.floatMax(f32), value));
    if (rounded <= value) return rounded;
    return @bitCast(@as(u32, @bitCast(rounded)) - 1);
}

test "a running sweep polls the atomic cancel flag and clears its pages" {
    const t = std.testing;
    const count = 1301;
    const Kernel = struct {
        calls: *usize,
        cancel: *std.atomic.Value(bool),

        pub fn edgeCost(self: @This(), _: *const View, _: EdgeId, _: *const EdgeHot, _: Direction) !costing.Cost {
            self.calls.* += 1;
            if (self.calls.* == 100) self.cancel.store(true, .monotonic);
            return .{ .cost = 1, .secs = 1 };
        }

        pub fn turnCost(_: @This(), _: *const View, _: Transition, _: Label, _: Direction) !costing.Cost {
            return .{};
        }
    };
    const nodes = try t.allocator.alloc(graph.format.NodeHot, count);
    defer t.allocator.free(nodes);
    const edges = try t.allocator.alloc(EdgeHot, (count - 1) * 2);
    defer t.allocator.free(edges);
    const first = try t.allocator.alloc(u32, count + 1);
    defer t.allocator.free(first);
    @memset(nodes, .{ .turn_off = 0, .attr = .{ .access = 0xfff, .type = 0, .density = 0, .signal = 0 } });
    for (0..count) |node| {
        const start = 2 * node -| 1;
        first[node] = @intCast(start);
        if (node != 0) {
            edges[start] = .{
                .head = @intCast(node - 1),
                .geom = .{ .len_m = 1, .grade = 6, .curvature = 0 },
                .cls = .{ .class_id = 0, .local = 0, .opp_local = @intFromBool(node > 1), .cold_checks = 0, .pred_speed = 0 },
                .speed = @splat(0),
            };
        }
        if (node != count - 1) {
            edges[2 * node] = .{
                .head = @intCast(node + 1),
                .geom = .{ .len_m = 1, .grade = 6, .curvature = 0 },
                .cls = .{ .class_id = 0, .local = @intFromBool(node > 0), .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
                .speed = @splat(0),
            };
        }
    }
    first[count] = @intCast(edges.len);
    const view: View = .{
        .headers = .initFill(null),
        .dataset_uuid = @splat(0),
        .nodes = nodes,
        .edges = edges,
        .first_edge = first,
        .turns = &.{ 0, 0, 0, 0 },
        .classes = null,
        .coordinates = null,
        .cold_idx = null,
        .cold = null,
        .cold_data = null,
        .slopes = null,
        .spatial = null,
        .spatial_index = null,
        .metadata = null,
        .components = null,
        .turn_sides = null,
        .turn_side_index = null,
    };
    var engine = try Search(Kernel, queue.Heap).init(t.allocator, &view);
    defer engine.deinit();
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    var cancelled: std.atomic.Value(bool) = .init(false);
    var calls: usize = 0;
    const kernel: Kernel = .{ .calls = &calls, .cancel = &cancelled };
    const start: NodeId = @fromBackingInt(@as(u32, 0));
    try t.expectError(error.Cancelled, engine.sweep(&arena, kernel, start, .forward, 2000, .{ .cancel = &cancelled }));
    try t.expect(calls >= 100 and calls < 2400);
    cancelled.store(false, .monotonic);
    arena.reset();
    const next = try engine.sweep(&arena, kernel, start, .forward, 7, .{ .cancel = &cancelled });
    try t.expectEqual(7, next.settled);
    try t.expectEqual(7, next.popped);

    const Canceller = struct {
        visits: usize = 0,
        flag: *std.atomic.Value(bool),

        pub fn visit(self: *@This(), _: ExpansionVisit) !ExpansionDecision {
            self.visits += 1;
            if (self.visits == 4) self.flag.store(true, .monotonic);
            return .expand;
        }
    };
    var expansion = try Search(Kernel, queue.BucketQueue).init(t.allocator, &view);
    defer expansion.deinit();
    for ([_]u32{ 1, 1_000_000 }) |width| {
        var observer: Canceller = .{ .flag = &cancelled };
        calls = 100;
        arena.reset();
        try t.expectError(error.Cancelled, expansion.expand(&arena, kernel, .{ .origins = &.{start}, .unit_size = width }, &observer, .{ .cancel = &cancelled }));
        try t.expect(observer.visits >= 4 and observer.visits < 4 + 1024);
        // The wide bucket never refills, so this checks the loop's own poll.
        if (width == 1_000_000) try t.expectEqual(1023, observer.visits);
        cancelled.store(false, .monotonic);
    }
    arena.reset();
    const after_cancel = try expansion.expand(&arena, kernel, .{ .origins = &.{start}, .limit = 7 }, {}, .{ .cancel = &cancelled });
    try t.expectEqual(7, after_cancel.settled);
}

test "L2 remains admissible when sub-ULP edge costs round away" {
    const points = [_]graph.format.Coordinate{ .{ .lng = 0, .lat = 0 }, .{ .lng = 1000, .lat = 0 } };
    const potential: L2 = .{ .coordinates = &points, .goal = points[1], .cost_per_metre = 1 };
    const origin: NodeId = @fromBackingInt(@as(u32, 0));
    const destination: NodeId = @fromBackingInt(@as(u32, 1));
    try std.testing.expect(potential.estimate(origin) > 0);
    try std.testing.expectEqual(@as(f32, 0), potential.estimate(destination));
    try std.testing.expectEqual(@as(f32, 0), potential.estimateAt(origin, 0x1p25));
}
