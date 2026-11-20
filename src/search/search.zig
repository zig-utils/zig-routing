// Ported from src/thor/unidirectional_astar.cc and src/thor/bidirectional_astar.cc
// (Valhalla 3.9.3), with exact edge-state expansion over native CSR.

const std = @import("std");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const memory = @import("../infra/arena.zig");
const costing = @import("../costing/compiled.zig");
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

    pub fn edgeId(self: Label) EdgeId {
        return @fromBackingInt(self.edge);
    }

    pub fn cut(self: Label, cuts: []const Cut) Cut {
        if (self.flags & (partial_start | partial_target) == 0) return .{};
        return cuts[self.ctx - 1];
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

pub const Request = struct {
    origin: NodeId,
    destination: NodeId,
    direction: Direction = .forward,
};

pub const PartialRequest = struct {
    starts: []const endpoints.Candidate,
    targets: *const endpoints.Targets,
    direction: Direction = .forward,
    forbid_initial_uturn: bool = false,
};

const NodeQuery = struct {
    start: NodeId,
    target: ?NodeId = null,
    limit: usize = std.math.maxInt(usize),
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
};

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
};

const Restrictions = struct {
    const forbidden = no_index;
    const AliasStatus = std.AutoHashMapUnmanaged(u64, Status);

    view: *const View,
    states: []const automaton.State,
    modes: u16,
    root: u32,
    aliases: AliasStatus = .empty,

    noinline fn advance(self: *const Restrictions, context: u32, id: EdgeId) !u32 {
        const edge = try self.view.edge(id);
        const class = try self.view.class(edge.cls.class_id);
        if (class.flags.node_connector) return context;
        if (context == 0) {
            const start = if (self.root == automaton.forward_root) class.restrictions.start else class.restrictions.end;
            if (start & self.modes == 0) return 0;
        }
        const next = automaton.advance(self.states, if (context == 0) self.root else context, @backingInt(id));
        if (self.states[next].attr.forbidden & self.modes != 0) return forbidden;
        return if (next < automaton.first_context) 0 else next;
    }

    fn statusId(self: *const Restrictions, edge: u32, context: u32) ?u32 {
        if (self.states[context].edge != edge) return null;
        return @as(u32, @intCast(self.view.edges.len)) + (context - automaton.first_context);
    }

    fn aliasKey(edge: u32, context: u32) u64 {
        return (@as(u64, edge) << 32) | context;
    }
};

/// K supplies edgeCost(view, edge_id, hot, direction), turnCost(view,
/// transition, predecessor, direction), and optionally slowAllowed for
/// cold edges, allowedTurn for checking a pair of directed edges and
/// restrictionModes() for selecting complex restrictions (defaults to auto).
/// All weighted costs must be nonnegative. A state is the last directed edge
/// and the matched restriction prefix.
/// The cost and admissibility of future steps must be independent of the
/// path to that state. Queue entries use nonnegative f32 ordering.
pub fn Search(comptime K: type, comptime Q: type) type {
    return struct {
        const Self = @This();
        const Pool = memory.PagePool(16 * 1024);

        view: *const View,
        allocator: std.mem.Allocator,
        status: paged.EdgeStatus(Status),

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
                .forward => self.runDirection(.forward, arena, kernel, NodeQuery{ .start = request.origin, .target = request.destination }, potential, control),
                .reverse => self.runDirection(.reverse, arena, kernel, NodeQuery{ .start = request.destination, .target = request.origin }, potential, control),
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

        fn runDirection(self: *Self, comptime direction: Direction, arena: *memory.Arena, kernel: K, query: anytype, potential: anytype, control: Control) !Result {
            const modes = if (comptime @hasDecl(K, "restrictionModes"))
                kernel.restrictionModes()
            else
                @as(u16, @bitCast(graph.constants.AccessMask{ .auto = true }));
            if (modes != 0 and self.view.restriction_automaton != null)
                return self.runLoop(direction, true, arena, kernel, query, potential, control, modes);
            return self.runLoop(direction, false, arena, kernel, query, potential, control, 0);
        }

        fn runLoop(self: *Self, comptime direction: Direction, comptime with_restrictions: bool, arena: *memory.Arena, kernel: K, query: anytype, potential: anytype, control: Control, modes: u16) !Result {
            const partial = @TypeOf(query) == PartialRequest;
            const target = if (partial) null else query.target;
            const limit = if (partial) std.math.maxInt(usize) else query.limit;
            const a = arena.allocator();
            var pool: Pool = .init(arena);
            var labels: std.ArrayList(Label) = .empty;
            var cuts: std.ArrayList(Cut) = .empty;
            var pending: Q = .{};
            var restrictions: if (with_restrictions) Restrictions else void = if (with_restrictions) .{
                .view = self.view,
                .states = self.view.restriction_automaton.?,
                .modes = modes,
                .root = if (direction == .forward) automaton.forward_root else automaton.reverse_root,
            } else {};
            const tracker = if (with_restrictions) &restrictions else null;
            if (partial) {
                try self.seedPartials(direction, &pool, kernel, query, &labels, &cuts, &pending, potential, tracker, control);
            } else {
                if (target != null and query.start == target.?) {
                    try labels.append(a, .{ .flags = Label.target });
                    return .{ .labels = labels.items, .index = 0, .popped = 0, .settled = 0 };
                }
                try self.seedNode(direction, &pool, kernel, query.start, target, &labels, &pending, potential, tracker);
            }

            var popped: usize = 0;
            var settled: usize = 0;
            while (pending.pop()) |top| {
                popped += 1;
                if ((popped & 1023) == 0) try control.check();
                const last = labels.items[top.label];
                const context = if (with_restrictions)
                    if (last.flags & Label.partial_target != 0) 0 else if (last.flags & Label.partial_start != 0)
                        try tracker.advance(0, last.edgeId())
                    else
                        last.ctx
                else
                    0;
                if (last.flags & Label.partial_target == 0 and self.findStatus(tracker, last.edge, context).label_plus_one != top.label + 1) continue;
                settled += 1;
                if (last.flags & Label.target != 0 or settled == limit) {
                    try control.check();
                    return .{ .labels = labels.items, .index = top.label, .popped = popped, .settled = settled, .cuts = cuts.items };
                }

                const previous_id = last.edgeId();
                const previous_edge = &self.view.edges[last.edge];
                const geometry = if (direction == .forward) previous_edge else try self.view.edge(try self.view.oppEdge(previous_id));
                const at: NodeId = @fromBackingInt(geometry.head);
                const exits = try self.view.outEdgeRange(at);
                const forward_row = if (direction == .forward) try self.view.turnRow(at, geometry.cls.opp_local) else &.{};
                for (self.view.edges[exits.first..exits.end], exits.first.., 0..) |*outward, index, local| {
                    if (partial and last.flags & Label.forbid_uturn != 0 and local == geometry.cls.opp_local) continue;
                    const local_id: EdgeId = @fromBackingInt(@as(u32, @intCast(index)));
                    const next_id = if (direction == .forward) local_id else try self.view.oppEdge(local_id);
                    const next_context = if (with_restrictions) try tracker.advance(context, next_id) else 0;
                    if (with_restrictions and next_context == Restrictions.forbidden) continue;
                    const prior = self.findStatus(tracker, @backingInt(next_id), next_context);
                    const dominated = prior.label_plus_one != 0 and labels.items[prior.label_plus_one - 1].cost <= last.cost;
                    var targets = if (partial) query.targets.on(next_id) else {};
                    if (dominated and (!partial or targets.index == 0)) continue;
                    const next = if (direction == .forward) outward else try self.view.edge(next_id);
                    const row = if (direction == .forward)
                        forward_row[local]
                    else blk: {
                        const reverse_row = try self.view.turnRow(at, outward.cls.local);
                        if (geometry.cls.opp_local >= reverse_row.len) return error.InvalidLocalEdge;
                        break :blk reverse_row[geometry.cls.opp_local];
                    };
                    const movement: Transition = .{
                        .node = at,
                        .incoming = if (direction == .forward) previous_id else next_id,
                        .incoming_edge = if (direction == .forward) previous_edge else next,
                        .outgoing = if (direction == .forward) next_id else previous_id,
                        .outgoing_edge = if (direction == .forward) next else previous_edge,
                        .row = row,
                    };
                    if (comptime @hasDecl(K, "allowedTurn")) {
                        if (!try kernel.allowedTurn(self.view, movement, last, direction)) continue;
                    } else if (row & 0x80 != 0) continue;
                    if (comptime @hasDecl(K, "slowAllowed")) {
                        if (next.cls.cold_checks != 0 and !try Self.slowAllowed(kernel, self.view, next_id, next, last, direction)) continue;
                    }
                    const edge_cost = try kernel.edgeCost(self.view, next_id, next, direction);
                    if (edge_cost.cost == std.math.inf(f32)) continue;
                    const delay = try kernel.turnCost(self.view, movement, last, direction);
                    if (delay.cost == std.math.inf(f32)) continue;
                    const previous: costing.Cost = .{ .cost = last.cost, .secs = last.secs };
                    if (partial) {
                        var count: usize = 0;
                        while (targets.next()) |candidate| : (count += 1) {
                            if (count % 64 == 0) try control.check();
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
                            });
                        }
                    }
                    if (dominated) continue;
                    const total = if (partial) previous.add(delay).add(edge_cost) else previous.add(edge_cost.add(delay));
                    if (total.cost == std.math.inf(f32)) continue;
                    const head: NodeId = @fromBackingInt(outward.head);
                    try self.offer(&pool, &labels, &pending, potential, target, head, prior, tracker, next_context, .{
                        .edge = @backingInt(next_id),
                        .pred = top.label,
                        .cost = total.cost,
                        .secs = total.secs,
                        .dist_m = last.dist_m +| next.geom.len_m,
                        .tcost = delay.cost,
                        .ctx = next_context,
                    });
                }
            }
            try control.check();
            if (!partial and target == null) return .{ .labels = labels.items, .index = no_index, .popped = popped, .settled = settled };
            return error.NoPath;
        }

        fn seedNode(self: *Self, comptime direction: Direction, pool: *Pool, kernel: K, start: NodeId, target: ?NodeId, labels: *std.ArrayList(Label), pending: *Q, potential: anytype, tracker: anytype) !void {
            const seeds = try self.view.outEdgeRange(start);
            for (self.view.edges[seeds.first..seeds.end], seeds.first..) |*outward, index| {
                const geometry_id: EdgeId = @fromBackingInt(@as(u32, @intCast(index)));
                const id = if (direction == .forward) geometry_id else try self.view.oppEdge(geometry_id);
                const edge = if (direction == .forward) outward else try self.view.edge(id);
                if (comptime @hasDecl(K, "slowAllowed")) {
                    if (edge.cls.cold_checks != 0 and !try Self.slowAllowed(kernel, self.view, id, edge, null, direction)) continue;
                }
                const edge_cost = try kernel.edgeCost(self.view, id, edge, direction);
                if (edge_cost.cost == std.math.inf(f32)) continue;
                const here: NodeId = @fromBackingInt(outward.head);
                const context = if (@TypeOf(tracker) == @TypeOf(null)) 0 else try tracker.advance(0, id);
                try self.offer(pool, labels, pending, potential, target, here, self.findStatus(tracker, @backingInt(id), context), tracker, context, .{
                    .edge = @backingInt(id),
                    .cost = edge_cost.cost,
                    .secs = edge_cost.secs,
                    .dist_m = edge.geom.len_m,
                    .ctx = context,
                });
            }
        }

        fn seedPartials(self: *Self, comptime direction: Direction, pool: *Pool, kernel: K, query: PartialRequest, labels: *std.ArrayList(Label), cuts: *std.ArrayList(Cut), pending: *Q, potential: anytype, tracker: anytype, control: Control) !void {
            const a = pool.arena.allocator();
            for (query.starts, 0..) |candidate, index| {
                if (index % 64 == 0) try control.check();
                if (!candidate.valid()) return error.InvalidCandidate;
                const id = candidate.edge;
                const edge = try self.view.edge(id);
                const full = if (comptime @hasDecl(K, "endpointCost"))
                    try kernel.endpointCost(self.view, id, edge, direction)
                else
                    try kernel.edgeCost(self.view, id, edge, direction);
                if (full.cost == std.math.inf(f32)) continue;
                const geometry = if (direction == .forward) edge else try self.view.edge(try self.view.oppEdge(id));
                const node: NodeId = @fromBackingInt(geometry.head);
                const portion: Cut = if (direction == .forward) .{ .begin = candidate.fraction } else .{ .end = candidate.fraction };
                const at_node = if (direction == .forward) candidate.end_node else candidate.begin_node;
                const cost = scale(full, @max(portion.end - portion.begin, std.math.floatEps(f32)), candidate.score);
                try cuts.append(a, portion);
                const context = if (@TypeOf(tracker) == @TypeOf(null)) 0 else try tracker.advance(0, id);
                try self.offer(pool, labels, pending, potential, null, node, self.findStatus(tracker, @backingInt(id), context), tracker, context, .{
                    .edge = @backingInt(id),
                    .cost = cost.cost,
                    .secs = cost.secs,
                    .dist_m = fractionalLength(edge.geom.len_m, portion),
                    .flags = Label.partial_start | if (query.forbid_initial_uturn and at_node and portion.begin == portion.end) Label.forbid_uturn else 0,
                    .ctx = std.math.cast(u32, cuts.items.len) orelse return error.TooManySearchLabels,
                });
                var dest = query.targets.on(id);
                var count: usize = 0;
                while (dest.next()) |match| : (count += 1) {
                    if (count % 64 == 0) try control.check();
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
                    });
                }
            }
        }

        fn addTerminal(a: std.mem.Allocator, labels: *std.ArrayList(Label), cuts: *std.ArrayList(Cut), pending: *Q, cut: Cut, label: Label) !void {
            const index = std.math.cast(u32, labels.items.len) orelse return error.TooManySearchLabels;
            if (index == no_index) return error.TooManySearchLabels;
            try cuts.append(a, cut);
            var terminal = label;
            terminal.flags = Label.target | Label.partial_target;
            terminal.ctx = std.math.cast(u32, cuts.items.len) orelse return error.TooManySearchLabels;
            try labels.append(a, terminal);
            try pending.push(a, queue.Entry.init(label.cost, index));
        }

        noinline fn slowAllowed(kernel: K, view: *const View, id: EdgeId, edge: *const EdgeHot, predecessor: ?Label, comptime direction: Direction) !bool {
            return try kernel.slowAllowed(view, id, edge, predecessor, direction);
        }

        inline fn findStatus(self: *Self, tracker: anytype, edge: u32, context: u32) Status {
            if (@TypeOf(tracker) == @TypeOf(null) or context == 0) return self.status.get(edge);
            if (tracker.statusId(edge, context)) |id| return self.status.get(id);
            return tracker.aliases.get(Restrictions.aliasKey(edge, context)) orelse .{};
        }

        fn offer(self: *Self, pool: *Pool, labels: *std.ArrayList(Label), pending: *Q, potential: anytype, target: ?NodeId, head: NodeId, status: Status, tracker: anytype, context: u32, label: Label) !void {
            if (status.label_plus_one != 0 and labels.items[status.label_plus_one - 1].cost <= label.cost) return;
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
            const slot = if (@TypeOf(tracker) == @TypeOf(null) or context == 0) try self.status.at(pool, label.edge) else blk: {
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
