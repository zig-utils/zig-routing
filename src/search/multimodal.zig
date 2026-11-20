// Ported from src/thor/multimodal_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const costing = @import("../costing/root.zig");
const core = @import("search.zig");
const endpoints = @import("endpoints.zig");
const paged = @import("paged.zig");
const queue = @import("queue.zig");
const walk_time = @import("walk_time.zig");
const transit_potential = @import("transit_potential.zig");
const Arena = @import("../infra/arena.zig").Arena;
const Control = core.Control;
const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const Transit = graph.transit;
const NodeId = graph.format.NodeId;
const EdgeId = graph.format.EdgeId;
const EdgeHot = graph.format.EdgeHot;
const Use = graph.constants.Use;
const Cost = costing.compiled.Cost;
const Kernel = costing.multimodal.Kernel;
const timezone = graph.timezone;
const seconds_per_day = graph.datetime.seconds_per_day;
const no_label = core.no_index;

const ServiceClock = struct {
    rules: ?*const timezone.Rules,
    zone: timezone.Id,
    earliest_local: i64,
    today: i64,
    instant: i64,

    fn init(rules: ?*const timezone.Rules, zone: timezone.Id, instant: i64, service_anchor: i64, control: Control) !ServiceClock {
        try control.check();
        const resolved = if (rules) |value| try value.offsetAt(zone, instant) else null;
        const offset = if (resolved) |value| value.seconds else 0;
        const local = try std.math.add(i64, instant, offset);
        const anchor_offset = if (resolved != null) (try rules.?.offsetAt(zone, service_anchor)).?.seconds else 0;
        var clock: ServiceClock = .{
            .rules = rules,
            .zone = if (resolved == null) timezone.utc else zone,
            .earliest_local = local,
            .today = @divFloor(try std.math.add(i64, service_anchor, anchor_offset), seconds_per_day),
            .instant = instant,
        };
        if (clock.zone != timezone.utc) {
            // During the first pass through an overlap, a lower wall time
            // can still resolve to a future instant on the second pass.
            const later = try clock.resolve(local, control);
            clock.earliest_local -= @max(0, later - instant);
            // At a forward jump, skipped wall times resolve to the instant
            // at which the clock jumps. Include them in the first seek.
            const before = try rules.?.offsetAt(zone, instant -| 1);
            if (before) |previous| clock.earliest_local = @min(clock.earliest_local, instant + previous.seconds);
        }
        return clock;
    }

    fn resolve(clock: ServiceClock, local: i64, control: Control) !i64 {
        if (clock.zone == timezone.utc) return local;
        return (try clock.rules.?.toUtc(clock.zone, local, control.deadline)) orelse error.InvalidTransitTime;
    }
};

const ScheduledDeparture = struct {
    offered: Transit.NextDeparture,
    instant: i64,
    service_day: i32,
};

const Departures = struct {
    table: Transit.View,
    line: u32,
    clock: ServiceClock,
    day: i64,
    slots: ?Transit.DepartureIterator = null,

    fn init(table: Transit.View, line: u32, clock: ServiceClock) !Departures {
        const last = try table.lastDepartureTime(line);
        return .{
            .table = table,
            .line = line,
            .clock = clock,
            .day = if (last) |time| @divFloor(clock.earliest_local - @as(i64, time) + seconds_per_day - 1, seconds_per_day) else clock.today + 1,
        };
    }

    fn next(self: *Departures, control: Control) !?ScheduledDeparture {
        while (self.day <= self.clock.today) {
            try control.check();
            const midnight = self.day * seconds_per_day;
            if (self.slots == null) {
                const seek: u32 = @intCast(@max(0, self.clock.earliest_local - midnight));
                self.slots = try self.table.departureIterator(self.line, seek);
            }
            const offered = try self.slots.?.next() orelse {
                self.day += 1;
                self.slots = null;
                continue;
            };
            const day = std.math.cast(i32, self.day) orelse return error.InvalidTransitTime;
            const weekday: Transit.Weekday = @fromBackingInt(@as(u3, @intCast(@mod(self.day + 4, 7))));
            if (!try self.table.scheduleActive(offered.departure.schedule, day, weekday)) continue;
            const instant = try self.clock.resolve(midnight + offered.time, control);
            if (instant >= self.clock.instant) return .{ .offered = offered, .instant = instant, .service_day = day };
        }
        return null;
    }
};

/// Prepare the native timetable's directed platform adjacency in the query
/// arena. Each platform's lines retain their on-disk order.
pub const TimetableIndex = struct {
    outgoing_lines: LineIndex,
    incoming_lines: LineIndex,
    platforms_by_node: std.AutoHashMapUnmanaged(NodeId, u32),
    stations_by_node: std.AutoHashMapUnmanaged(NodeId, u32),

    pub fn init(arena: Allocator, table: Transit.View, deadline: io.Deadline) !TimetableIndex {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (table.stops.len > Transit.no_id or table.lines.len > Transit.no_id or table.stations.len > Transit.no_id)
            return error.TooManyTransitRecords;
        var platforms = try indexNodes(arena, table.stops, deadline);
        errdefer platforms.deinit(arena);
        return .{
            .outgoing_lines = try LineIndex.init(arena, table, "origin", deadline),
            .incoming_lines = try LineIndex.init(arena, table, "destination", deadline),
            .platforms_by_node = platforms,
            .stations_by_node = try indexNodes(arena, table.stations, deadline),
        };
    }

    pub fn outgoing(self: *const TimetableIndex, stop: u32) ![]const u32 {
        return self.outgoing_lines.at(stop);
    }

    pub fn incoming(self: *const TimetableIndex, stop: u32) ![]const u32 {
        return self.incoming_lines.at(stop);
    }

    pub fn platformAt(self: *const TimetableIndex, node: NodeId) ?u32 {
        return self.platforms_by_node.get(node);
    }

    pub fn stationAt(self: *const TimetableIndex, node: NodeId) ?u32 {
        return self.stations_by_node.get(node);
    }
};

const LineIndex = struct {
    first_line: []const u32,
    lines: []const u32,

    fn init(a: Allocator, table: Transit.View, comptime endpoint: []const u8, deadline: io.Deadline) !LineIndex {
        const first = try a.alloc(u32, table.stops.len + 1);
        @memset(first, 0);
        for (table.lines, 0..) |line, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const stop = @field(line, endpoint);
            if (stop >= table.stops.len) return error.InvalidTransitLine;
            first[@as(usize, stop) + 1] += 1;
        }
        for (first[1..], 0..) |*offset, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            offset.* += first[i];
        }
        const lines = try a.alloc(u32, table.lines.len);
        const next = try a.dupe(u32, first[0..table.stops.len]);
        defer a.free(next);
        for (table.lines, 0..) |line, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const slot = &next[@field(line, endpoint)];
            lines[slot.*] = @intCast(i);
            slot.* += 1;
        }
        return .{ .first_line = first, .lines = lines };
    }

    fn at(self: LineIndex, stop: u32) ![]const u32 {
        if (stop >= self.first_line.len - 1) return error.InvalidTransitStop;
        return self.lines[self.first_line[stop]..self.first_line[@as(usize, stop) + 1]];
    }
};

fn indexNodes(arena: Allocator, records: anytype, deadline: io.Deadline) !std.AutoHashMapUnmanaged(NodeId, u32) {
    var by_node: std.AutoHashMapUnmanaged(NodeId, u32) = .empty;
    errdefer by_node.deinit(arena);
    try by_node.ensureTotalCapacity(arena, @intCast(records.len));
    for (records, 0..) |entry, id| {
        if (id % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (entry.place.graph_node == Transit.no_id) continue;
        const node: NodeId = @fromBackingInt(entry.place.graph_node);
        const item = by_node.getOrPutAssumeCapacity(node);
        if (item.found_existing) return error.DuplicateTransitNode;
        item.value_ptr.* = @intCast(id);
    }
    return by_node;
}

pub const Ride = struct {
    departure: *const Transit.Departure,
    ready_time: i64,
    departure_time: i64,
    arrival_time: i64,
    service_day: i32,
};

pub const Step = struct {
    movement: union(enum) { walk: endpoints.Segment, ride: Ride },
    elapsed: Cost,
    transition: Cost = .{},
};

pub const Path = struct {
    steps: []const Step,
    total: Cost,
    ignored_filter: [2]bool,
};

const Journey = struct {
    stop: u32 = Transit.no_id,
    route: u32 = Transit.no_id,
    trip: u32 = Transit.no_id,
    block: u32 = Transit.no_id,
    operator: Transit.Text = .none,
    service_day: i32 = 0,
    occurrence: u32 = 0,
    arrived: i64 = 0,

    fn hasTransit(self: Journey) bool {
        return self.stop != Transit.no_id;
    }
};

const Label = struct {
    step: Step,
    node: NodeId,
    predecessor: u32 = no_label,
    next_at_edge: u32 = no_label,
    inactive: bool = false,
    terminal: bool = false,
    forbid_initial_uturn: bool = false,
    can_board: bool = true,
    walk_distance: u32 = 0,
    journey: u32 = 0,
    access: costing.base.AccessState = .{},
    turn: core.TurnContext = .{},

    fn streetLabel(self: Label) core.Label {
        var road: core.Label = .{ .secs = self.step.elapsed.secs, .dist_m = self.walk_distance };
        if (self.step.movement == .walk) road.edge = @backingInt(self.step.movement.walk.edge);
        road.setTraversal(self.access, .{ .cost = self.step.elapsed });
        return road;
    }
};

const TransferIndex = struct {
    const Key = struct { from: u32, to: u32 };
    const Entry = struct { next: u32, rule: *const Transit.Transfer };
    heads: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    origins: std.AutoHashMapUnmanaged(u32, void) = .empty,
    entries: []const Entry = &.{},

    fn init(a: Allocator, rules: []const Transit.Transfer, control: Control) !TransferIndex {
        var result: TransferIndex = .{};
        const entries = try a.alloc(Entry, rules.len);
        for (rules, entries, 0..) |*rule, *entry, i| {
            if (i % 256 == 0) try control.check();
            const id = std.math.cast(u32, i) orelse return error.TooManyTransitRecords;
            const slot = try result.heads.getOrPut(a, .{ .from = rule.origin, .to = rule.destination });
            try result.origins.put(a, rule.origin, {});
            entry.* = .{ .next = if (slot.found_existing) slot.value_ptr.* else no_label, .rule = rule };
            slot.value_ptr.* = id;
        }
        result.entries = entries;
        return result;
    }

    fn afterAlighting(self: TransferIndex, journey: Journey) Journey {
        if (self.origins.contains(journey.stop) or self.origins.contains(Transit.no_id)) return journey;
        // Once the rider leaves the vehicle, its trip and block can only
        // affect a later boarding through a transfer rule from this stop.
        return .{ .stop = journey.stop, .operator = journey.operator };
    }

    fn find(self: TransferIndex, from: Journey, to: u32, departure: *const Transit.Departure, control: Control) !?*const Transit.Transfer {
        if (!from.hasTransit() or self.entries.len == 0) return null;
        var best: ?*const Transit.Transfer = null;
        var best_rank: u8 = 0;
        const from_stops = [_]u32{ from.stop, Transit.no_id };
        const to_stops = [_]u32{ to, Transit.no_id };
        for (from_stops) |origin| for (to_stops) |destination| {
            var id = self.heads.get(.{ .from = origin, .to = destination }) orelse continue;
            while (id != no_label) {
                try control.check();
                const entry = self.entries[id];
                id = entry.next;
                const rule = entry.rule;
                if (!selector(rule.origin_route, from.route) or !selector(rule.destination_route, departure.route) or
                    !selector(rule.origin_trip, from.trip) or !selector(rule.destination_trip, departure.trip)) continue;
                const trips = @as(u8, @intFromBool(rule.origin_trip != Transit.no_id)) + @intFromBool(rule.destination_trip != Transit.no_id);
                const routes = @as(u8, @intFromBool(rule.origin_route != Transit.no_id)) + @intFromBool(rule.destination_route != Transit.no_id);
                const stops = @as(u8, @intFromBool(origin != Transit.no_id)) + @intFromBool(destination != Transit.no_id);
                const rank = trips * 9 + routes * 3 + stops;
                if (best == null or rank > best_rank) {
                    best = rule;
                    best_rank = rank;
                }
            }
        };
        return best;
    }

    fn selector(value: u32, id: u32) bool {
        return value == Transit.no_id or value == id;
    }
};

/// Reused for every pair of locations on the same request.
pub const Search = struct {
    view: *const View,
    kernel: *const Kernel,
    timetable: ?TimetableIndex,
    transfers: TransferIndex,
    timed_walking: walk_time.Distance,
    platforms: walk_time.Distance,
    minimum_ride: []const f32,

    pub fn init(a: Allocator, view: *const View, kernel: *const Kernel, control: Control) !Search {
        try control.check();
        const table = view.transit_index;
        var platforms: walk_time.Distance = .{};
        if (table) |present| {
            var pending: queue.Heap = .{};
            defer pending.items.deinit(a);
            for (present.stops) |stop| {
                try control.check();
                if (stop.place.graph_node != Transit.no_id)
                    try platforms.offer(a, &pending, stop.place.graph_node, 0);
            }
            try platforms.propagate(a, view, &pending, kernel.walking_limit, control);
        }
        return .{
            .view = view,
            .kernel = kernel,
            .timetable = if (table) |present| try TimetableIndex.init(a, present, control.deadline) else null,
            .transfers = try TransferIndex.init(a, if (table) |present| present.transfers else &.{}, control),
            .timed_walking = try walk_time.Distance.init(a, view, kernel.walking.permission, kernel.walking_limit, control),
            .platforms = platforms,
            .minimum_ride = if (table) |present| try cheapestRides(a, present, kernel, control) else &.{},
        };
    }

    fn cheapestRides(a: Allocator, table: Transit.View, kernel: *const Kernel, control: Control) ![]const f32 {
        const costs = try a.alloc(f32, table.lines.len);
        for (table.lines, costs) |line, *cost| {
            try control.check();
            if (line.route >= table.routes.len) return error.InvalidTransitRoute;
            const use = costing.transit.vehicleUse(table.routes[line.route].flags.vehicle);
            cost.* = std.math.inf(f32);
            for (try line.departures.items(Transit.Departure, table.departures), 0..) |departure, j| {
                if (j % 256 == 0) try control.check();
                cost.* = @min(cost.*, kernel.transit.rideCost(use, departure.elapsed_time, 0).cost);
            }
        }
        return costs;
    }

    pub fn run(self: *const Search, arena: *Arena, from: endpoints.Ranked, to: endpoints.Ranked, options: endpoints.Options, control: Control) !Path {
        return self.attempt(arena, from, to, options, false, control);
    }

    pub fn attempt(self: *const Search, arena: *Arena, from: endpoints.Ranked, to: endpoints.Ranked, options: endpoints.Options, filtered: bool, control: Control) !Path {
        try control.check();
        if (options.direction != .forward or options.timing.invariant) return error.UnsupportedTransitDateTime;
        if (!options.timing.start.valid) return error.NoPath;
        const mark = arena.mark();
        errdefer arena.rewind(mark);
        var ceiling: f32 = 32768;
        while (true) {
            try control.check();
            return self.runWithin(arena.allocator(), from, to, options, filtered, ceiling, control) catch |err| {
                if (err != error.CostCeilingReached) return err;
                arena.rewind(mark);
                ceiling = @min(ceiling * 4, std.math.floatMax(f32));
                continue;
            };
        }
    }

    fn runWithin(self: *const Search, a: Allocator, from: endpoints.Ranked, to: endpoints.Ranked, options: endpoints.Options, filtered: bool, ceiling: f32, control: Control) !Path {
        const permission = self.kernel.walking.permission;
        const restrictions: core.Restrictions = .{
            .access = .{ .view = self.view, .permission = permission, .direction = .forward, .timing = options.timing, .control = control, .check_access = self.view.cold_data != null },
            .states = self.view.restriction_automaton orelse &.{},
            .modes = permission.restrictionModes(),
            .has_exclusions = options.excluded.len != 0,
            .keep_time = true,
        };
        const targets = try endpoints.Targets.init(a, to.candidates(filtered), .forward, control);
        const timetable = if (self.timetable) |*present| present else null;
        var query: Query = .{
            .search = self,
            .a = a,
            .control = control,
            .restrictions = restrictions,
            .targets = targets,
            .ceiling = ceiling,
            .potential = try transit_potential.Potential.init(a, self.view, self.kernel, timetable, self.minimum_ride, &targets, ceiling, control),
            .ignored_filter = .{ from.ignored_filter, to.ignored_filter },
        };
        var pending: queue.Heap = .{};
        defer pending.items.deinit(a);
        for (query.targets.entries) |entry| {
            try control.check();
            const id = entry.candidate.edge;
            const edge = try self.view.edge(id);
            const opposite = try self.view.edge(try self.view.oppEdge(id));
            const metres = Query.length(edge, entry.candidate.fraction);
            if (metres <= self.kernel.walking_limit) try query.destination.offer(a, &pending, opposite.head, metres);
        }
        try query.destination.propagate(a, self.view, &pending, self.kernel.walking_limit, control);
        for (options.excluded) |excluded| {
            try control.check();
            const last = try query.excluded.getOrPut(a, excluded.id);
            if (!last.found_existing) last.value_ptr.* = excluded.percent_along;
        }
        const starts = try endpoints.starts(a, from.candidates(filtered), &query.targets, .forward, control);
        for (starts) |start| try query.seed(start, options.forbid_initial_uturn);
        return query.finish();
    }
};

const Query = struct {
    const StreetState = struct {
        edge: EdgeId,
        journey: u32,
        turn: core.TurnContext,
        access: costing.base.AccessState,
        instant: u32,
        forbid_initial_uturn: bool,
        can_board: bool,
    };
    const RideState = struct { line: u32, journey: u32 };

    search: *const Search,
    a: Allocator,
    control: Control,
    restrictions: core.Restrictions,
    targets: endpoints.Targets,
    ceiling: f32,
    potential: transit_potential.Potential,
    ceiling_hit: bool = false,
    destination: walk_time.Distance = .{},
    ignored_filter: [2]bool,
    excluded: std.AutoHashMapUnmanaged(EdgeId, f32) = .empty,
    walk_hits: paged.Array(u32, 0) = .{},
    timed_hits: std.AutoHashMapUnmanaged(StreetState, u32) = .empty,
    ride_hits: std.AutoHashMapUnmanaged(RideState, u32) = .empty,
    journeys: std.AutoArrayHashMapUnmanaged(Journey, void) = .empty,
    labels: paged.Array(Label, undefined) = .{},
    label_count: u32 = 0,
    pending: queue.Heap = .{},
    terminal_cost: f32 = std.math.inf(f32),

    fn finish(self: *Query) !Path {
        while (self.pending.pop()) |item| {
            try self.control.check();
            const label = self.labels.get(item.label);
            if (label.inactive) continue;
            if (label.terminal) return self.trace(item.label);
            if (!try self.canEnter(label.node)) continue;
            try self.expandWalk(item.label, label);
            if (label.can_board) try self.expandRides(item.label, label);
        }
        return if (self.ceiling_hit) error.CostCeilingReached else error.NoPath;
    }

    fn canEnter(self: *const Query, node: NodeId) !bool {
        const view = self.search.view;
        const kernel = self.search.kernel;
        if (!kernel.walking.allowedNode(try view.node(node))) return false;
        const index = &(self.search.timetable orelse return true);
        if (index.platformAt(node)) |platform| {
            if (!try kernel.allowsStop(view, platform)) return false;
            const station = view.transit_index.?.stops[platform].station;
            if (station != Transit.no_id and !try kernel.allowsStation(view, station)) return false;
        }
        if (index.stationAt(node)) |station| return kernel.allowsStation(view, station);
        return true;
    }

    fn trace(self: *const Query, end: u32) !Path {
        var count: usize = 0;
        var id = end;
        while (id != no_label) : (count += 1) {
            try self.control.check();
            id = self.labels.get(id).predecessor;
        }
        const steps = try self.a.alloc(Step, count);
        id = end;
        while (count != 0) {
            try self.control.check();
            count -= 1;
            const label = self.labels.get(id);
            steps[count] = label.step;
            id = label.predecessor;
        }
        return .{ .steps = steps, .total = self.labels.get(end).step.elapsed, .ignored_filter = self.ignored_filter };
    }

    fn insert(self: *Query, label: Label, priority: f32) !void {
        const next = self.label_count;
        if (next == no_label) return error.TooManySearchLabels;
        (try self.labels.at(self.a, next)).* = label;
        self.label_count += 1;
        try self.pending.push(self.a, queue.Entry.init(priority, next));
    }

    fn journey(self: *const Query, id: u32) Journey {
        return if (id == 0) .{} else self.journeys.keys()[id - 1];
    }

    fn internJourney(self: *Query, state: Journey) !u32 {
        const entry = try self.journeys.getOrPut(self.a, state);
        return std.math.cast(u32, entry.index + 1) orelse error.TooManySearchLabels;
    }

    fn offer(self: *Query, offered: Label) !void {
        var candidate = offered;
        const cost = candidate.step.elapsed.cost;
        if (cost >= self.terminal_cost) return;
        const priority = if (candidate.terminal) cost else core.roundedDown(@as(f64, cost) + self.potential.estimate(candidate.node));
        if (priority >= self.terminal_cost) return;
        if (priority > self.ceiling) {
            self.ceiling_hit = true;
            return;
        }
        if (candidate.terminal) {
            self.terminal_cost = cost;
            return self.insert(candidate, priority);
        }
        if (candidate.step.movement == .walk) {
            const walking_limit = self.search.kernel.walking_limit;
            const board_limit = if (candidate.journey != 0) @min(walking_limit, self.search.kernel.transfer_limit) else walking_limit;
            candidate.can_board = candidate.can_board and candidate.walk_distance <= board_limit and
                self.search.platforms.within(candidate.node, board_limit - candidate.walk_distance);
            if (!candidate.can_board) {
                if (!self.destination.within(candidate.node, walking_limit - candidate.walk_distance)) return;
                candidate.journey = 0;
            }
        }
        const timed = candidate.step.movement == .walk and self.needsClock(candidate);
        const slot = switch (candidate.step.movement) {
            .walk => |walk| if (timed or candidate.journey != 0) blk: {
                const entry = try self.timed_hits.getOrPut(self.a, .{
                    .edge = walk.edge,
                    .journey = candidate.journey,
                    .turn = candidate.turn,
                    .access = candidate.access,
                    .instant = if (timed) @bitCast(candidate.step.elapsed.secs) else 0,
                    .forbid_initial_uturn = candidate.forbid_initial_uturn,
                    .can_board = candidate.can_board,
                });
                if (!entry.found_existing) entry.value_ptr.* = 0;
                break :blk entry.value_ptr;
            } else try self.walk_hits.at(self.a, @backingInt(walk.edge)),
            .ride => |ride| blk: {
                const entry = try self.ride_hits.getOrPut(self.a, .{ .line = ride.departure.line, .journey = candidate.journey });
                if (!entry.found_existing) entry.value_ptr.* = 0;
                break :blk entry.value_ptr;
            },
        };
        var parent = slot;
        var scanned: usize = 0;
        while (parent.* != 0) : (scanned += 1) {
            if (scanned % 64 == 0) try self.control.check();
            const prior = try self.labels.at(self.a, parent.* - 1);
            if (comparable(prior.*, candidate)) {
                if (self.dominates(prior.*, candidate)) return;
                if (self.dominates(candidate, prior.*)) {
                    prior.inactive = true;
                    parent.* = prior.next_at_edge;
                    continue;
                }
            }
            parent = &prior.next_at_edge;
        }
        var label = candidate;
        label.next_at_edge = slot.*;
        const index = self.label_count;
        try self.insert(label, priority);
        slot.* = @intCast(index + 1);
    }

    fn comparable(a: Label, b: Label) bool {
        return a.journey == b.journey and std.meta.eql(a.turn, b.turn) and
            std.meta.eql(a.access, b.access) and a.forbid_initial_uturn == b.forbid_initial_uturn and
            a.can_board == b.can_board;
    }

    fn dominates(self: *const Query, a: Label, b: Label) bool {
        if (a.walk_distance > b.walk_distance) return false;
        const first = a.step.elapsed;
        const second = b.step.elapsed;
        if (first.secs == second.secs) return first.cost <= second.cost;
        if (self.needsClock(b)) return false;
        if (!b.can_board) return first.cost <= second.cost;
        if (first.secs > second.secs) return false;
        // With static walking access, the earlier label can follow the
        // same walk and wait for the same departure. Allow for whole-second
        // timetable rounding when comparing its extra wait cost.
        const extra_wait = @ceil(second.secs - first.secs) + 1;
        return first.cost + extra_wait <= second.cost;
    }

    fn needsClock(self: *const Query, label: Label) bool {
        return self.search.timed_walking.within(label.node, self.search.kernel.walking_limit -| label.walk_distance);
    }

    fn walkCost(self: *const Query, edge: *const EdgeHot, class: *const graph.class_table.EdgeClass) Cost {
        const kernel = self.search.kernel;
        return kernel.walkCost(class, edge.*, kernel.walking.untimedFerrySpeed(edge.*), .{});
    }

    fn partial(cost: Cost, fraction: f32, score: f32) Cost {
        return .{ .cost = cost.cost * fraction + score, .secs = cost.secs * fraction };
    }

    fn length(edge: *const EdgeHot, fraction: f32) u32 {
        return @intFromFloat(@as(f32, @floatFromInt(edge.geom.len_m)) * fraction);
    }

    fn seed(self: *Query, start: endpoints.Candidate, forbid_initial_uturn: bool) !void {
        try self.control.check();
        const view = self.search.view;
        const edge = try view.edge(start.edge);
        const node: NodeId = @fromBackingInt(edge.head);
        const forbidden = self.excluded.get(start.edge);
        if (forbidden != null and forbidden.? >= start.fraction) return;
        const cost = self.walkCost(edge, try view.class(edge.cls.class_id));
        if (!std.math.isFinite(cost.cost)) return;
        const tail: NodeId = @fromBackingInt((try view.edge(try view.oppEdge(start.edge))).head);
        const access = try self.restrictions.access.evaluate(start.edge, edge, tail, .{}, .start);
        if (!access.allowed) return;
        const turn = try self.restrictions.advance(.{}, .{}, tail, start.edge);
        const remaining = 1 - start.fraction;
        var label: Label = .{
            .node = node,
            .step = .{ .movement = .{ .walk = .{ .edge = start.edge, .begin = start.fraction, .end = 1 } }, .elapsed = partial(cost, remaining, start.score) },
            .access = access.state,
            .turn = turn,
            .walk_distance = length(edge, remaining),
            .forbid_initial_uturn = forbid_initial_uturn and remaining == 0,
        };
        if (!turn.blocked() and label.walk_distance <= self.search.kernel.walking_limit) try self.offer(label);
        var targets = self.targets.on(start.edge);
        while (targets.next()) |target| {
            try self.control.check();
            if (target.fraction < start.fraction) continue;
            const fraction = target.fraction - start.fraction;
            if (length(edge, fraction) > self.search.kernel.walking_limit) continue;
            label.terminal = true;
            label.step.movement.walk.end = target.fraction;
            label.step.elapsed = partial(cost, fraction, start.score + target.score);
            try self.offer(label);
        }
    }

    fn expandWalk(self: *Query, pred: u32, label: Label) !void {
        const view = self.search.view;
        const kernel = self.search.kernel;
        const node = try view.node(label.node);
        const road = label.streetLabel();
        const previous = if (road.edge != no_label) try view.edge(road.edgeId()) else null;
        const previous_class = if (previous) |edge| try view.class(edge.cls.class_id) else null;
        const previous_journey = self.journey(label.journey);
        const walking_journey = if (label.step.movement == .ride)
            try self.internJourney(self.search.transfers.afterAlighting(previous_journey))
        else
            label.journey;
        const range = try view.outEdgeRange(label.node);
        for (view.edges[range.first..range.end], range.first..) |*edge, i| {
            try self.control.check();
            const id: EdgeId = @fromBackingInt(@as(u32, @intCast(i)));
            const class = try view.class(edge.cls.class_id);
            const head: NodeId = @fromBackingInt(edge.head);
            const backtrack = if (previous) |arc| arc.cls.opp_local == edge.cls.local else false;
            if (backtrack and label.forbid_initial_uturn) continue;
            if (class.category.use == @backingInt(Use.transit_connection) and node.attr.type == @backingInt(graph.constants.NodeType.transit_egress)) {
                if (previous_class) |prior| if (prior.category.use == @backingInt(Use.transit_connection)) continue;
            }
            const incoming = previous_class orelse class;
            const check: costing.pedestrian.PathCheck = .{
                .previous_dead_end = incoming.flags.dead_end or range.count() == 1,
                .previous_pedestrian = previous != null,
                .backtrack = backtrack,
            };
            if (!costing.pedestrian.Kernel.allowed(&kernel.walking, incoming, class, edge.*, check)) continue;
            const turn = try self.restrictions.advance(label.turn, road, label.node, id);
            if (turn.blocked()) continue;
            const forbidden = self.excluded.get(id);
            const cost = self.walkCost(edge, class);
            if (!std.math.isFinite(cost.cost)) continue;
            const transition: Cost = if (previous != null)
                costing.pedestrian.Kernel.turnCost(&kernel.walking, node, incoming, class, try costing.pedestrian.Turn.read(view, label.node, road.edgeId(), id))
            else
                .{};
            const elapsed = label.step.elapsed.add(transition);
            var next: Label = .{
                .node = head,
                .step = .{ .movement = .{ .walk = .{ .edge = id, .begin = 0, .end = 1 } }, .elapsed = elapsed.add(cost), .transition = transition },
                .predecessor = pred,
                .walk_distance = label.walk_distance +| edge.geom.len_m,
                .journey = walking_journey,
                .can_board = label.can_board,
                .turn = turn,
            };
            var targets = self.targets.on(id);
            if (targets.index != 0) {
                const access = try self.restrictions.access.evaluate(id, edge, label.node, road, .end);
                if (access.allowed) while (targets.next()) |target| {
                    try self.control.check();
                    if (forbidden != null and forbidden.? <= target.fraction) continue;
                    const metres = label.walk_distance +| length(edge, target.fraction);
                    if (metres > kernel.walking_limit) continue;
                    var terminal = next;
                    terminal.terminal = true;
                    terminal.step.movement.walk.end = target.fraction;
                    terminal.step.elapsed = elapsed.add(partial(cost, target.fraction, target.score));
                    try self.offer(terminal);
                };
            }
            if (forbidden != null or next.walk_distance > kernel.walking_limit) continue;
            if (self.search.timetable) |*index| if (index.platformAt(head)) |platform| {
                if (!label.can_board or platform == previous_journey.stop or (label.journey != 0 and next.walk_distance > kernel.transfer_limit)) continue;
            };
            const access = try self.restrictions.access.evaluate(id, edge, label.node, road, .middle);
            if (!access.allowed) continue;
            next.access = access.state;
            try self.offer(next);
        }
    }

    fn expandRides(self: *Query, pred: u32, label: Label) !void {
        const index = &(self.search.timetable orelse return);
        const platform = index.platformAt(label.node) orelse return;
        const view = self.search.view;
        const table = view.transit_index.?;
        const timing = self.restrictions.access.timing;
        const time = try timing.at(view, label.node, label.step.elapsed.secs, .forward);
        const rules = if (view.tz_rules) |*present| present else null;
        const clock = try ServiceClock.init(rules, time.zone, time.unix_time, timing.start.unix_time, self.control);
        const transfer_kind: costing.multimodal.Transfer = if (label.journey != 0 and label.step.movement == .walk) .between_stations else .within_station;
        const transfer = self.search.kernel.transferCost(transfer_kind);
        for (try index.outgoing(platform)) |line_id| {
            try self.control.check();
            const line = table.lines[line_id];
            const place = table.stops[line.destination].place;
            if (place.graph_node == Transit.no_id) continue;
            const destination: NodeId = @fromBackingInt(place.graph_node);
            if (!try self.canEnter(destination)) continue;
            var departures = try Departures.init(table, line_id, clock);
            while (try departures.next(self.control)) |departure| {
                try self.board(pred, label, table, platform, destination, departure, transfer, clock.instant);
            }
        }
    }

    fn board(self: *Query, pred: u32, label: Label, table: Transit.View, platform: u32, destination: NodeId, scheduled: ScheduledDeparture, transfer: Cost, now: i64) !void {
        const kernel = self.search.kernel;
        const offered = scheduled.offered.departure;
        if (offered.trip == Transit.no_id) return error.InvalidTransitTrip;
        if (!try kernel.allowsDeparture(self.search.view, offered)) return;
        const trip = self.journey(label.journey);
        const route = table.routes[offered.route];
        const rule = try self.search.transfers.find(trip, platform, offered, self.control);
        const kind = if (rule) |value| value.flags.kind else .recommended;
        const walking = label.step.movement == .walk;
        const same_day = trip.service_day == scheduled.service_day;
        const occurrence = if (offered.flags.kind == .frequency) (scheduled.offered.time - offered.start_time) / offered.headway else 0;
        const same_trip = same_day and trip.trip == offered.trip and trip.occurrence == occurrence;
        const same_block = same_day and trip.trip != offered.trip and trip.block != Transit.no_id and trip.block == offered.block;
        const continuing = !walking and kind != .forced_alight and (same_trip or same_block or (same_day and kind == .in_seat));
        if (kind == .forbidden or (!continuing and kind == .in_seat)) return;
        const boarding_time: i64 = if (continuing or kind == .timed or walking) 0 else 30;
        const minimum = if (rule) |value| if (kind == .minimum_time) value.minimum_time else 0 else 0;
        if (scheduled.instant < now + boarding_time or (trip.hasTransit() and scheduled.instant < trip.arrived + minimum)) return;
        const wait = std.math.cast(u32, scheduled.instant - now) orelse return error.InvalidTransitTime;
        const arrival = scheduled.instant + offered.elapsed_time;
        const operator = if (continuing) trip.operator else route.operator_one_stop_id;
        const transition: Cost = .{ .cost = if (continuing) 0 else if (trip.operator != .none and operator != trip.operator) 300 else transfer.cost };
        var elapsed = label.step.elapsed.add(transition).add(kernel.transit.rideCost(costing.transit.vehicleUse(route.flags.vehicle), offered.elapsed_time, wait));
        elapsed.secs = @floatFromInt(arrival - self.restrictions.access.timing.start.unix_time);
        try self.offer(.{
            .node = destination,
            .step = .{ .movement = .{ .ride = .{ .departure = offered, .ready_time = now, .departure_time = scheduled.instant, .arrival_time = arrival, .service_day = scheduled.service_day } }, .elapsed = elapsed, .transition = transition },
            .journey = try self.internJourney(.{ .stop = table.lines[offered.line].destination, .trip = offered.trip, .route = offered.route, .block = offered.block, .operator = operator, .service_day = scheduled.service_day, .occurrence = occurrence, .arrived = arrival }),
            .predecessor = pred,
        });
    }
};

test "multimodal timetable groups lines by the boarding platform" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const table: Transit.View = .{
        .metadata = .{ .start_day = 0 },
        .stops = &.{
            .{ .place = .{ .coordinate = .{ .lng = 0, .lat = 0 }, .name = .none, .one_stop_id = .none, .graph_node = 10 } },
            .{ .place = .{ .coordinate = .{ .lng = 0, .lat = 0 }, .name = .none, .one_stop_id = .none, .graph_node = 20 } },
            .{ .place = .{ .coordinate = .{ .lng = 0, .lat = 0 }, .name = .none, .one_stop_id = .none } },
        },
        .stations = &.{.{ .place = .{ .coordinate = .{ .lng = 0, .lat = 0 }, .name = .none, .one_stop_id = .none, .graph_node = 30 } }},
        .egresses = &.{},
        .routes = &.{},
        .lines = &.{
            .{ .origin = 1, .destination = 0, .route = 0, .departures = .{} },
            .{ .origin = 0, .destination = 1, .route = 0, .departures = .{} },
            .{ .origin = 1, .destination = 2, .route = 1, .departures = .{} },
        },
        .departures = &.{},
        .occurrences = &.{},
        .schedules = &.{},
        .days = &.{},
        .exceptions = &.{},
        .transfers = &.{},
        .strings = undefined,
    };
    const index = try TimetableIndex.init(arena.allocator(), table, .none);
    try testing.expectEqualSlices(u32, &.{1}, try index.outgoing(0));
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, try index.outgoing(1));
    try testing.expectEqualSlices(u32, &.{}, try index.outgoing(2));
    try testing.expectEqualSlices(u32, &.{0}, try index.incoming(0));
    try testing.expectError(error.InvalidTransitStop, index.outgoing(3));
    try testing.expectEqual(@as(?u32, 1), index.platformAt(@fromBackingInt(20)));
    try testing.expectEqual(@as(?u32, 0), index.stationAt(@fromBackingInt(30)));
    try testing.expectEqual(null, index.platformAt(@fromBackingInt(30)));
}

test "after-midnight departures check the preceding service day's calendar" {
    const testing = std.testing;
    const date = graph.datetime.Local.parse("2026-03-09T00:00").?;
    const day: i32 = @intCast(date.date.days());
    const records = [_]Transit.Departure{
        .{ .line = 0, .route = 0, .trip = 0, .block = Transit.no_id, .schedule = 0, .start_time = 1800, .elapsed_time = 300 },
        .{ .line = 0, .route = 0, .trip = 1, .block = Transit.no_id, .schedule = 0, .start_time = 88200, .elapsed_time = 300 },
    };
    const table: Transit.View = .{
        .metadata = .{ .start_day = day },
        .stops = &.{},
        .stations = &.{},
        .egresses = &.{},
        .routes = &.{},
        .lines = &.{.{ .origin = 0, .destination = 1, .route = 0, .departures = .{ .count = records.len } }},
        .departures = &records,
        .occurrences = &.{},
        .schedules = &.{.{ .days = .{ .count = 1 }, .day_count = 2 }},
        .days = &.{.{ .bits = 1 }},
        .exceptions = &.{},
        .transfers = &.{},
        .strings = undefined,
    };
    const instant = date.seconds() + seconds_per_day + 900;
    const clock = try ServiceClock.init(null, timezone.utc, instant, instant, .{});
    var departures = try Departures.init(table, 0, clock);
    const found = (try departures.next(.{})).?;
    try testing.expectEqual(day, found.service_day);
    try testing.expectEqual(1, found.offered.departure.trip);
    try testing.expectEqual(instant + 900, found.instant);
    try testing.expectEqual(null, try departures.next(.{}));
}
