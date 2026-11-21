// Ported from src/meili/viterbi_search.cc, src/meili/topk_search.cc and
// valhalla/meili/state.h (Valhalla 3.9.3).
const std = @import("std");
const Candidate = @import("candidates.zig").Candidate;
const Measurement = @import("candidates.zig").Measurement;
const Emission = @import("emission.zig").Model;
const Transition = @import("transition.zig").Model;
const routing = @import("routing.zig");
const EdgeId = @import("../graph/format.zig").EdgeId;
const memory = @import("../infra/arena.zig");
const Control = @import("../search/search.zig").Control;
const pending = @import("state_queue.zig");
const Allocator = std.mem.Allocator;
const Index = pending.Index;
const none = pending.none;

pub const StateId = packed struct(u64) {
    time: u32 = none,
    id: u32 = 0,

    pub fn valid(self: StateId) bool {
        return self.time != none;
    }
};

pub const StateContainer = struct {
    pub const Column = struct {
        measurement: Measurement,
        leave_time: f64,
        candidates: []const Candidate,
    };

    columns: std.ArrayList(Column) = .empty,

    /// Copy the candidate finder result before querying the next measurement.
    pub fn append(self: *StateContainer, a: Allocator, measurement: Measurement, candidates: []const Candidate) !u32 {
        if (self.columns.items.len == none or candidates.len >= none) return error.TooManyTraceStates;
        try self.columns.ensureUnusedCapacity(a, 1);
        const copies = try a.dupe(Candidate, candidates);
        const time: u32 = @intCast(self.columns.items.len);
        self.columns.appendAssumeCapacity(.{ .measurement = measurement, .leave_time = measurement.epoch_time, .candidates = copies });
        return time;
    }

    pub fn candidate(self: *const StateContainer, id: StateId) ?*const Candidate {
        if (id.time >= self.columns.items.len) return null;
        const candidates = self.columns.items[id.time].candidates;
        return if (id.id < candidates.len) &candidates[id.id] else null;
    }

    pub fn startSearch(self: *const StateContainer, arena: *memory.Arena, control: Control) !Search {
        const checkpoint = arena.mark();
        errdefer arena.rewind(checkpoint);
        const a = arena.allocator();
        const widths = try a.alloc(u32, self.columns.items.len);
        for (widths, self.columns.items, 0..) |*width, column, time| {
            if (time % 256 == 0) try control.check();
            width.* = @intCast(column.candidates.len);
        }
        return Search.init(arena, widths, control);
    }
};

const Label = struct {
    state: StateId,
    origin: Index,
    predecessor: Index = none,
    cost: f64 = -1,
};

const SearchColumn = struct {
    first: Index,
    count: u32,
    remaining: u32,
    clones: std.ArrayList(Index) = .empty,
};

const Clone = struct { source: Index, copy: Index };

pub const Path = struct {
    pub const Submatch = struct { first: u32, count: u32 };

    states: []const StateId,
    submatches: []const Submatch,
    cost: f64,
    broken: bool,
};

const break_penalty: f64 = 1e8;

/// Dijkstra over successive candidate columns. The cost model supplies
/// emission(id) and transition(from, to, predecessor, control) returning
/// nonnegative costs or a negative value for an unavailable state or move.
pub const Search = struct {
    a: Allocator,
    columns: []SearchColumn,
    labels: std.ArrayList(Label),
    queue: pending.Queue = .{},
    skip_dominated_moves: bool = false,
    layers: std.ArrayList([]const Clone) = .empty,
    winners: []Index,
    solved: u32 = 0,
    earliest: u32 = 0,
    resume_from: Index = none,
    reset_needed: bool = false,

    pub fn init(arena: *memory.Arena, widths: []const u32, control: Control) !Search {
        try control.check();
        if (widths.len >= none) return error.TooManyTraceStates;
        const checkpoint = arena.mark();
        errdefer arena.rewind(checkpoint);
        const a = arena.allocator();
        const columns = try a.alloc(SearchColumn, widths.len);
        const winners = try a.alloc(Index, widths.len);
        var count: Index = 0;
        for (widths, columns, 0..) |width, *column, time| {
            if (time % 256 == 0) try control.check();
            column.* = .{ .first = count, .count = width, .remaining = width };
            count = std.math.add(Index, count, width) catch return error.TooManyTraceStates;
            if (count == none) return error.TooManyTraceStates;
        }
        var search: Search = .{ .a = a, .columns = columns, .labels = .empty, .winners = winners };
        try search.labels.resize(a, count);
        try search.queue.nodes.resize(a, count);
        for (columns, 0..) |column, time| {
            if (time % 256 == 0) try control.check();
            for (0..column.count) |offset| {
                if (offset % 256 == 0) try control.check();
                const slot = column.first + @as(u32, @intCast(offset));
                search.labels.items[slot] = .{ .state = .{ .time = @intCast(time), .id = @intCast(offset) }, .origin = slot };
                search.queue.nodes.items[slot] = .{};
            }
        }
        return search;
    }

    fn index(self: *const Search, id: StateId) Index {
        if (id.time >= self.columns.len) return none;
        const column = self.columns[id.time];
        if (id.id < column.count) return column.first + id.id;
        const clone = none - id.id;
        return if (clone < column.clones.items.len) column.clones.items[clone] else none;
    }

    fn state(self: *const Search, slot: Index) StateId {
        return if (slot == none) .{} else self.labels.items[slot].state;
    }

    fn original(self: *const Search, slot: Index) StateId {
        return if (slot == none) .{} else self.state(self.labels.items[slot].origin);
    }

    pub fn predecessor(self: *const Search, id: StateId) StateId {
        const slot = self.index(id);
        if (self.reset_needed or slot == none or self.labels.items[slot].cost < 0) return .{};
        return self.state(self.labels.items[slot].predecessor);
    }

    pub fn accumulatedCost(self: *const Search, id: StateId) ?f64 {
        const slot = self.index(id);
        if (self.reset_needed or slot == none) return null;
        const cost = self.labels.items[slot].cost;
        return if (cost >= 0) cost else null;
    }

    /// Keep candidate IDs and removed paths for subsequent searches.
    pub fn clearSearch(self: *Search, control: Control) !void {
        self.reset_needed = true;
        for (self.labels.items, self.queue.nodes.items, 0..) |*label, *node, i| {
            if (i % 256 == 0) try control.check();
            label.predecessor = none;
            label.cost = -1;
            node.* = .{};
        }
        for (self.columns, 0..) |*column, time| {
            if (time % 256 == 0) try control.check();
            column.remaining = column.count + @as(u32, @intCast(column.clones.items.len));
        }
        self.queue.roots = .{};
        self.queue.best = none;
        self.solved = 0;
        self.earliest = 0;
        self.resume_from = none;
        self.reset_needed = false;
    }

    pub fn winner(self: *Search, time: u32, model: anytype, control: Control) !StateId {
        return self.state(try self.findWinner(time, model, control));
    }

    fn findWinner(self: *Search, time: u32, model: anytype, control: Control) !Index {
        try control.check();
        if (self.columns.len == 0) return none;
        const target = @min(time, @as(u32, @intCast(self.columns.len - 1)));
        errdefer self.reset_needed = true;
        if (self.reset_needed) try self.clearSearch(control);
        if (target >= self.solved) {
            if (self.resume_from != none) {
                try self.expand(self.resume_from, model, control);
                self.resume_from = none;
            }
            while (self.solved <= target) {
                try control.check();
                if (self.queue.best == none) {
                    try self.seed(self.solved, model, control);
                    if (self.queue.best == none) {
                        self.winners[self.solved] = none;
                        self.solved += 1;
                        continue;
                    }
                }
                const slot = (try self.queue.pop(control)).?;
                const label = &self.labels.items[slot];
                const column_time = label.state.time;
                if (column_time < self.earliest) continue;
                label.cost = self.queue.nodes.items[slot].cost;
                const column = &self.columns[column_time];
                column.remaining -= 1;
                if (column.remaining == 0) self.earliest = column_time + 1;
                if (column_time == self.solved) {
                    self.winners[self.solved] = slot;
                    self.solved += 1;
                    if (column_time == target) {
                        self.resume_from = slot;
                        break;
                    }
                }
                try self.expand(slot, model, control);
            }
        }
        return if (time == target) self.winners[target] else none;
    }

    fn slots(column: SearchColumn, n: usize) Index {
        return if (n < column.count) column.first + @as(u32, @intCast(n)) else column.clones.items[n - column.count];
    }

    fn seed(self: *Search, time: u32, model: anytype, control: Control) !void {
        const column = self.columns[time];
        for (0..column.count + column.clones.items.len) |n| {
            if (n % 256 == 0) try control.check();
            const slot = slots(column, n);
            const cost = try self.emission(slot, model, control);
            if (available(cost)) _ = try self.queue.offer(slot, cost, control);
        }
    }

    fn expand(self: *Search, left: Index, model: anytype, control: Control) !void {
        const label = self.labels.items[left];
        const time = label.state.time + 1;
        if (time >= self.columns.len) return;
        const column = self.columns[time];
        for (0..column.count + column.clones.items.len) |n| {
            if (n % 256 == 0) try control.check();
            const right = slots(column, n);
            if (self.labels.items[right].cost >= 0) continue;
            const observation = try self.emission(right, model, control);
            if (!available(observation)) continue;
            const queued = self.queue.nodes.items[right].cost;
            if (self.skip_dominated_moves and queued >= 0 and queued <= label.cost + observation) continue;
            const movement = try self.transition(left, right, model, control);
            if (!available(movement)) continue;
            const sum = label.cost + movement + observation;
            if (try self.queue.offer(right, sum, control)) self.labels.items[right].predecessor = left;
        }
    }

    fn emission(self: *const Search, slot: Index, model: anytype, control: Control) !f32 {
        const time = self.labels.items[slot].state.time;
        var state_slot = slot;
        var layers = std.mem.reverseIterator(self.layers.items);
        var checked: usize = 0;
        while (layers.next()) |layer| : (checked += 1) {
            if (checked % 64 == 0) try control.check();
            const clone = layer[time];
            if (state_slot == clone.copy) {
                if (time + 1 == self.columns.len) return -1;
                state_slot = clone.source;
            } else if (time == 0 and state_slot == clone.source) return -1;
        }
        return model.emission(self.state(state_slot));
    }

    fn transition(self: *const Search, left: Index, right: Index, model: anytype, control: Control) !f32 {
        const time = self.labels.items[left].state.time;
        var from = left;
        var to = right;
        var layers = std.mem.reverseIterator(self.layers.items);
        var checked: usize = 0;
        while (layers.next()) |layer| : (checked += 1) {
            if (checked % 64 == 0) try control.check();
            const before = layer[time];
            const after = layer[time + 1];
            if (from == before.copy) {
                from = before.source;
                if (to == after.copy) {
                    to = after.source;
                } else if (to == after.source) return -1;
            } else if (to == after.copy) return -1;
        }
        const previous = if (self.labels.items[from].cost >= 0) self.original(self.labels.items[from].predecessor) else StateId{};
        return model.transition(self.state(from), self.state(to), previous, control);
    }

    fn removePath(self: *Search, path: []const Index, control: Control) !void {
        if (path.len > none - self.labels.items.len - 1) return error.TooManyTraceStates;
        const clones = try self.a.alloc(Clone, path.len);
        try self.layers.ensureUnusedCapacity(self.a, 1);
        try self.labels.ensureUnusedCapacity(self.a, path.len);
        try self.queue.nodes.ensureUnusedCapacity(self.a, path.len);
        for (self.columns, 0..) |*column, time| {
            if (time % 256 == 0) try control.check();
            try column.clones.ensureUnusedCapacity(self.a, 1);
        }
        // Reserve all storage before publishing the new clone IDs.
        for (self.columns, path, clones, 0..) |*column, source, *clone, time| {
            if (time % 256 == 0) try control.check();
            const slot: Index = @intCast(self.labels.items.len);
            self.labels.appendAssumeCapacity(.{
                .state = .{ .time = @intCast(time), .id = none - @as(u32, @intCast(column.clones.items.len)) },
                .origin = self.labels.items[source].origin,
            });
            self.queue.nodes.appendAssumeCapacity(.{});
            column.clones.appendAssumeCapacity(slot);
            clone.* = .{ .source = source, .copy = slot };
        }
        self.layers.appendAssumeCapacity(clones);
        self.reset_needed = true;
    }

    fn backtrack(self: *Search, path: []Index, model: anytype, control: Control) !struct { cost: f64, broken: bool } {
        var remaining = path.len;
        var cost: f64 = 0;
        var broken = false;
        while (remaining != 0) {
            var slot = try self.findWinner(@intCast(remaining - 1), model, control);
            if (slot == none) {
                broken = true;
                cost += break_penalty;
            } else cost += self.labels.items[slot].cost;
            while (remaining != 0) {
                if (remaining % 256 == 0) try control.check();
                remaining -= 1;
                path[remaining] = slot;
                if (remaining == 0) break;
                if (slot == none) {
                    slot = try self.findWinner(@intCast(remaining - 1), model, control);
                } else {
                    slot = self.labels.items[slot].predecessor;
                    if (slot == none) break;
                }
            }
            if (remaining != 0) {
                broken = true;
                cost += break_penalty;
            }
        }
        return .{ .cost = cost, .broken = broken };
    }

    /// Return the first match with breaks if necessary, then only continuous
    /// alternatives. All state IDs in the result refer to original candidates.
    /// Use a fresh search for a separate top-k enumeration.
    pub fn bestPaths(self: *Search, output: *memory.Arena, model: anytype, k: u32, control: Control) ![]const Path {
        const Collector = struct {
            entries: std.ArrayList(Path) = .empty,
            pub fn accept(collector: *@This(), a: Allocator, path: Path, _: Control) !bool {
                try collector.entries.append(a, path);
                return true;
            }
        };
        var collector: Collector = .{};
        try self.enumeratePaths(output, model, k, &collector, control);
        return collector.entries.items;
    }

    /// Visit ranked paths until the collector has accepted k. Rejected paths
    /// have their result allocations rewound before the next search starts.
    pub fn enumeratePaths(self: *Search, output: *memory.Arena, model: anytype, k: u32, collector: anytype, control: Control) !void {
        try control.check();
        if (k == 0) return error.InvalidBestPathCount;
        const first_layer = self.layers.items.len;
        const first_label = self.labels.items.len;
        errdefer {
            self.layers.shrinkRetainingCapacity(first_layer);
            self.labels.shrinkRetainingCapacity(first_label);
            self.queue.nodes.shrinkRetainingCapacity(first_label);
            for (self.columns) |*column| column.clones.shrinkRetainingCapacity(first_layer);
            self.reset_needed = true;
        }
        const a = output.allocator();
        const scratch = try self.a.alloc(Index, self.columns.len);
        var accepted: u32 = 0;
        while (accepted < k) {
            try control.check();
            const result = try self.backtrack(scratch, model, control);
            if (accepted != 0 and result.broken) break;
            const mark = output.mark();
            const states = try a.alloc(StateId, scratch.len);
            var submatches: std.ArrayList(Path.Submatch) = .empty;
            for (states, scratch, 0..) |*state_id, slot, time| {
                if (time % 256 == 0) try control.check();
                state_id.* = self.original(slot);
                if (slot == none) continue;
                if (self.labels.items[slot].predecessor == none) {
                    try submatches.append(a, .{ .first = @intCast(time), .count = 1 });
                } else submatches.items[submatches.items.len - 1].count += 1;
            }
            if (try collector.accept(a, .{ .states = states, .submatches = submatches.items, .cost = result.cost, .broken = result.broken }, control)) {
                accepted += 1;
            } else {
                output.rewind(mark);
            }
            if (result.broken or scratch.len == 0 or accepted == k) break;
            try self.removePath(scratch, control);
        }
    }
};

fn available(cost: f32) bool {
    return cost >= 0 and std.math.isFinite(cost);
}

/// Score candidate rows on demand. Retain only the score and arrival edge
/// needed for the next transition. The cost of a routed row is shared by
/// clones and subsequent top-k passes.
pub fn RoutingCosts(comptime K: type) type {
    return struct {
        const Self = @This();
        const Router = routing.Router(K);
        const retained_path_budget = 1024 * 1024;
        const column_cache_budget = 512 * 1024;
        const largest_cached_column = 64;
        const Move = struct { score: f32, arrival: ?EdgeId = null };
        const Row = struct {
            moves: []const Move,
            incoming: ?EdgeId,
            paths: ?[]const ?routing.Route = null,
        };

        arena: *memory.Arena,
        states: *const StateContainer,
        router: *Router,
        kernel: K,
        observations: Emission,
        movements: Transition,
        rows: [][]?Row,
        columns: []?*routing.DestinationColumn,
        column_bytes: usize = 0,
        retained_path_bytes: usize = 0,

        pub fn init(arena: *memory.Arena, states: *const StateContainer, router: *Router, kernel: K, observations: Emission, movements: Transition, control: Control) !Self {
            const mark = arena.mark();
            errdefer arena.rewind(mark);
            const a = arena.allocator();
            const rows = try a.alloc([]?Row, states.columns.items.len);
            const columns = try a.alloc(?*routing.DestinationColumn, states.columns.items.len);
            for (rows, states.columns.items, 0..) |*row, column, time| {
                if (time % 256 == 0) try control.check();
                columns[time] = null;
                row.* = try a.alloc(?Row, column.candidates.len);
                for (row.*, 0..) |*cell, i| {
                    if (i % 256 == 0) try control.check();
                    cell.* = null;
                }
            }
            return .{
                .arena = arena,
                .states = states,
                .router = router,
                .kernel = kernel,
                .observations = observations,
                .movements = movements,
                .rows = rows,
                .columns = columns,
            };
        }

        pub fn emission(self: *const Self, state: StateId) !f32 {
            const candidate = self.states.candidate(state) orelse return error.InvalidTraceState;
            return self.observations.cost(candidate.squared_distance);
        }

        pub fn transition(self: *Self, from: StateId, to: StateId, previous: StateId, control: Control) !f32 {
            const row = &self.rows[from.time][from.id];
            if (row.* == null) row.* = try self.routeRow(from, to.time, previous, control);
            return row.*.?.moves[to.id].score;
        }

        /// Recover only the selected path. Use the incoming edge that priced
        /// the row, including when top-k selected a different predecessor.
        pub fn selectedRoute(self: *Self, arena: *memory.Arena, from: StateId, to: StateId, control: Control) !?routing.Route {
            _ = self.states.candidate(from) orelse return error.InvalidTraceState;
            const target = self.states.candidate(to) orelse return error.InvalidTraceState;
            if (to.time != from.time + 1) return error.InvalidTraceState;
            const row = self.rows[from.time][from.id] orelse return null;
            if (!available(row.moves[to.id].score)) return null;
            if (row.paths) |paths| {
                var route = paths[to.id] orelse return null;
                if (arena != self.arena) route.segments = try arena.allocator().dupe(routing.Segment, route.segments);
                return route;
            }
            const paths = try self.connect(arena, from, to.time, &.{target.*}, row.incoming, control);
            const route = paths[0] orelse return error.UnreproducibleTraceTransition;
            if (route.score != row.moves[to.id].score or route.last_edge != row.moves[to.id].arrival)
                return error.UnreproducibleTraceTransition;
            return route;
        }

        fn routeRow(self: *Self, from: StateId, time: u32, previous: StateId, control: Control) !Row {
            const prepared = try self.prepareColumn(from, time, control);
            const mark = self.arena.mark();
            errdefer self.arena.rewind(mark);
            const right = self.states.columns.items[time];
            const arrival = if (previous.valid())
                (self.rows[previous.time][previous.id] orelse return error.UnroutedTracePredecessor).moves[from.id].arrival
            else
                null;
            const prices = try self.arena.allocator().alloc(Move, right.candidates.len);
            const temporary = self.arena.mark();
            const paths = if (prepared) |column|
                try self.router.connectPrepared(self.arena, self.kernel, &self.movements, self.origin(from, arrival), column, control)
            else
                try self.connect(self.arena, from, time, right.candidates, arrival, control);
            for (paths, prices, 0..) |path, *price, i| {
                if (i % 256 == 0) try control.check();
                price.* = if (path) |route| .{ .score = route.score, .arrival = route.last_edge } else .{ .score = -1 };
            }
            // The paths used to score a row can be reused for its selected
            // transition. A bounded cache keeps long traces and dense
            // candidate windows from retaining all their path geometry.
            const bytes = self.arena.used - temporary.used;
            const budget = @min(retained_path_budget, self.arena.options.cap_bytes / 16);
            if (bytes <= budget - self.retained_path_bytes) {
                self.retained_path_bytes += bytes;
                return .{ .moves = prices, .incoming = arrival, .paths = paths };
            }
            self.arena.rewind(temporary);
            return .{ .moves = prices, .incoming = arrival };
        }

        fn prepareColumn(self: *Self, from: StateId, time: u32, control: Control) !?*routing.DestinationColumn {
            const slot = &self.columns[time];
            const budget = @min(column_cache_budget, self.arena.options.cap_bytes / 32);
            const remaining = budget - self.column_bytes;
            if (slot.*) |column| {
                if (column.needsBounds() and remaining >= 2048) {
                    const mark = self.arena.mark();
                    column.bounds = self.router.prepareBounds(self.arena.allocator(), column, control) catch |err| blk: {
                        self.arena.rewind(mark);
                        if (err != error.OutOfMemory) return err;
                        break :blk null;
                    };
                    column.built_bounds = true;
                    const bytes = self.arena.used - mark.used;
                    if (bytes <= remaining) {
                        self.column_bytes += bytes;
                    } else {
                        self.arena.rewind(mark);
                        column.bounds = null;
                    }
                }
                return column;
            }
            const left = self.states.columns.items[from.time];
            const right = self.states.columns.items[time];
            if (left.candidates.len < 2 or right.candidates.len > largest_cached_column or remaining < 4096) return null;
            const mark = self.arena.mark();
            errdefer self.arena.rewind(mark);
            const a = self.arena.allocator();
            const column = a.create(routing.DestinationColumn) catch {
                self.arena.rewind(mark);
                return null;
            };
            column.* = self.router.prepareColumn(a, &self.movements, right.candidates, measurements(left, right), control) catch |err| {
                if (err != error.OutOfMemory) return err;
                self.arena.rewind(mark);
                return null;
            };
            const bytes = self.arena.used - mark.used;
            if (bytes > remaining) {
                self.arena.rewind(mark);
                return null;
            }
            slot.* = column;
            self.column_bytes += bytes;
            return column;
        }

        fn origin(self: *const Self, from: StateId, arrival: ?EdgeId) routing.Origin {
            const left = self.states.columns.items[from.time];
            return .{
                .candidate = left.candidates[from.id],
                .stop_type = left.measurement.stop_type,
                .previous_edge = arrival,
            };
        }

        fn measurements(left: StateContainer.Column, right: StateContainer.Column) routing.Measurements {
            return .{ .left = left.measurement, .right = right.measurement, .leave_time = left.leave_time };
        }

        fn connect(self: *Self, arena: *memory.Arena, from: StateId, time: u32, targets: []const Candidate, arrival: ?EdgeId, control: Control) ![]const ?routing.Route {
            const left = self.states.columns.items[from.time];
            const right = self.states.columns.items[time];
            return self.router.connect(arena, self.kernel, &self.movements, self.origin(from, arrival), targets, measurements(left, right), control);
        }
    };
}

// The eager reference uses a complete column-by-column dynamic program.
// It exists to check the lazy winner costs independently of queue order.
const NaiveLabel = struct {
    state: StateId = .{},
    predecessor: StateId = .{},
    cost: f64 = -1,
};

fn naive(a: Allocator, widths: []const u32, model: anytype, control: Control) ![]const NaiveLabel {
    var widest: u32 = 0;
    for (widths, 0..) |width, time| {
        if (time % 256 == 0) try control.check();
        widest = @max(widest, width);
    }
    var previous = try a.alloc(NaiveLabel, widest);
    var current = try a.alloc(NaiveLabel, widest);
    const winners = try a.alloc(NaiveLabel, widths.len);
    var previous_width: u32 = 0;
    for (widths, winners, 0..) |width, *winner, time| {
        try control.check();
        winner.* = .{};
        for (current[0..width], 0..) |*label, slot| {
            if (slot % 256 == 0) try control.check();
            label.* = .{ .state = .{ .time = @intCast(time), .id = @intCast(slot) } };
            const observation = try model.emission(label.state);
            if (!available(observation)) continue;
            for (previous[0..previous_width], 0..) |left, n| {
                if (n % 256 == 0) try control.check();
                if (left.cost < 0) continue;
                const movement = try model.transition(left.state, label.state, left.predecessor, control);
                if (!available(movement)) continue;
                const sum = left.cost + movement + observation;
                if (label.cost >= 0 and label.cost < sum) continue;
                label.cost = sum;
                label.predecessor = left.state;
            }
            if (label.cost >= 0 and (winner.cost < 0 or label.cost < winner.cost)) winner.* = label.*;
        }
        if (!winner.state.valid()) {
            for (current[0..width], 0..) |*label, slot| {
                if (slot % 256 == 0) try control.check();
                const observation = try model.emission(label.state);
                if (!available(observation)) continue;
                label.cost = observation;
                if (winner.cost < 0 or label.cost < winner.cost) winner.* = label.*;
            }
        }
        std.mem.swap([]NaiveLabel, &current, &previous);
        previous_width = width;
    }
    return winners;
}

const TestCosts = struct {
    widths: []const u32,
    emissions: []const []const f32,
    movements: []const []const f32,

    pub fn emission(self: TestCosts, state: StateId) !f32 {
        return self.emissions[state.time][state.id];
    }

    pub fn transition(self: TestCosts, from: StateId, to: StateId, _: StateId, _: Control) !f32 {
        return self.movements[from.time][@as(usize, from.id) * self.widths[to.time] + to.id];
    }

    fn generate(a: Allocator, random: std.Random, width: u32, times: usize, base: i32, span: i32) !TestCosts {
        const widths = try a.alloc(u32, times);
        const emissions = try a.alloc([]const f32, times);
        const movements = try a.alloc([]const f32, times);
        for (widths, emissions) |*count, *values| {
            count.* = random.intRangeAtMost(u32, 0, width);
            const row = try a.alloc(f32, count.*);
            for (row) |*value| value.* = @floatFromInt(random.intRangeAtMost(i32, base, span));
            values.* = row;
        }
        for (movements, 0..) |*values, time| {
            const count = if (time + 1 == times) 0 else widths[time] * widths[time + 1];
            const row = try a.alloc(f32, count);
            for (row) |*value| value.* = @floatFromInt(random.intRangeAtMost(i32, base, span));
            values.* = row;
        }
        return .{ .widths = widths, .emissions = emissions, .movements = movements };
    }
};

test "Meili lazy winners agree with an eager reference across random breaks" {
    const t = std.testing;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(179);
    const random = prng.random();
    // Ported from ViterbiSearch.TestViterbiSearch (Valhalla 3.9.3).
    for (0..12) |trial| {
        arena.reset();
        const cases = try TestCosts.generate(arena.allocator(), random, 30, if (trial < 6) 1000 else 34, if (trial % 2 == 0) -14 else 0, 50);
        const expected = try naive(arena.allocator(), cases.widths, cases, .{});
        var search = try Search.init(&arena, cases.widths, .{});
        for (expected, 0..) |value, time| {
            const winner_id = try search.winner(@intCast(time), cases, .{});
            try t.expectEqual(value.state.valid(), winner_id.valid());
            try t.expectEqual(if (value.state.valid()) @as(?f64, value.cost) else null, search.accumulatedCost(winner_id));
        }
        try search.clearSearch(.{});
        const last_time: u32 = @intCast(expected.len - 1);
        const winner_id = try search.winner(last_time, cases, .{});
        try t.expectEqual(if (expected[last_time].state.valid()) @as(?f64, expected[last_time].cost) else null, search.accumulatedCost(winner_id));
    }
}

test "Meili path removal returns the brute force top k without repeating a sequence" {
    const t = std.testing;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    const cases: TestCosts = .{
        .widths = &.{ 4, 5, 4 },
        .emissions = &.{ &.{ 1, 6, 3, 2 }, &.{ 3, 2, 5, 1, 2 }, &.{ 6, 2, 4, 3 } },
        .movements = &.{
            &.{ 3, 1, 5, 9, 7, 3, 5, 1, 7, 2, 8, 2, 2, 4, 3, 1, 2, 5, 4, 3 },
            &.{ 7, 1, 3, 5, 2, 1, 1, 3, 8, 8, 5, 1, 2, 3, 1, 7, 1, 2, 4, 3 },
        },
    };
    // Ported from ViterbiSearch.TestTopKSearch (Valhalla 3.9.3).
    var expected: [80]f64 = undefined;
    for (0..4) |first| {
        for (0..5) |second| {
            for (0..4) |last| {
                expected[(first * 5 + second) * 4 + last] = cases.emissions[0][first] +
                    cases.movements[0][first * 5 + second] + cases.emissions[1][second] +
                    cases.movements[1][second * 4 + last] + cases.emissions[2][last];
            }
        }
    }
    std.mem.sort(f64, &expected, {}, comptime std.sort.asc(f64));
    var search = try Search.init(&arena, cases.widths, .{});
    const actual = try search.bestPaths(&arena, cases, 81, .{});
    try t.expectEqual(expected.len, actual.len);
    var seen: std.StaticBitSet(80) = .empty;
    for (actual, expected) |path, cost| {
        try t.expect(!path.broken);
        try t.expectEqual(cost, path.cost);
        try t.expectEqual(@as(usize, 3), path.states.len);
        for (path.states, 0..) |id, time| try t.expectEqual(time, id.time);
        const key = (path.states[0].id * 5 + path.states[1].id) * 4 + path.states[2].id;
        try t.expect(!seen.isSet(key));
        seen.set(key);
    }
}

test "Meili path reports explicit breaks and ends alternatives after a break" {
    const t = std.testing;
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    const costs: TestCosts = .{
        .widths = &.{ 1, 0, 2, 1, 1 },
        .emissions = &.{ &.{2}, &.{}, &.{ 5, 1 }, &.{1}, &.{6} },
        .movements = &.{ &.{}, &.{}, &.{ 0, 0 }, &.{-1} },
    };
    var search = try Search.init(&arena, costs.widths, .{});
    const path = try search.bestPaths(&arena, costs, 4, .{});
    try t.expectEqual(@as(usize, 1), path.len);
    try t.expect(path[0].broken);
    try t.expectEqualSlices(StateId, &.{ .{ .time = 0 }, .{}, .{ .time = 2, .id = 1 }, .{ .time = 3 }, .{ .time = 4 } }, path[0].states);
    try t.expectEqualSlices(Path.Submatch, &.{ .{ .first = 0, .count = 1 }, .{ .first = 2, .count = 2 }, .{ .first = 4, .count = 1 } }, path[0].submatches);
    try t.expectEqual(3 * break_penalty + 8, path[0].cost);
}

test "Meili one-column top k recovers from a cancelled search without allocating after warmup" {
    const t = std.testing;
    var counted = memory.CountingAllocator.init(t.allocator);
    var arena = memory.Arena.init(counted.allocator(), .{});
    defer arena.deinit();
    const costs: TestCosts = .{ .widths = &.{3}, .emissions = &.{&.{ 4, 3, 5 }}, .movements = &.{} };
    for (0..2) |attempt| {
        arena.reset();
        counted.resetCounts();
        var search = try Search.init(&arena, costs.widths, .{});
        try t.expectError(error.Cancelled, search.winner(0, costs, .{ .deadline = .{ .at_ns = 0 } }));
        const actual = try search.bestPaths(&arena, costs, 4, .{});
        try t.expectEqual(@as(usize, 3), actual.len);
        for (actual, [_]u32{ 1, 0, 2 }) |path, expected| {
            try t.expectEqual(StateId{ .time = 0, .id = expected }, path.states[0]);
        }
        if (attempt != 0) try t.expectEqual(@as(usize, 0), counted.calls());
    }

    var empty = try Search.init(&arena, &.{}, .{});
    const matches = try empty.bestPaths(&arena, costs, 2, .{});
    try t.expectEqual(@as(usize, 1), matches.len);
    try t.expectEqual(@as(usize, 0), matches[0].states.len);
}

test "Meili queue order matches pinned top-k paths on tied costs" {
    const t = std.testing;
    const Costs = struct {
        pattern: u32,

        pub fn emission(self: @This(), state: StateId) !f32 {
            return @floatFromInt(state.id * self.pattern % 3);
        }

        pub fn transition(self: @This(), from: StateId, _: StateId, _: StateId, _: Control) !f32 {
            return @floatFromInt((from.id * 3 + from.time * self.pattern) % 5);
        }
    };
    // State sequences from ViterbiSearch and TopKSearch in Valhalla 3.9.3.
    const expected = [_]struct { pattern: u32, ids: [6][4]u32 }{
        .{ .pattern = 0, .ids = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 2 }, .{ 0, 0, 0, 3 }, .{ 0, 0, 2, 0 }, .{ 0, 0, 2, 2 } } },
        .{ .pattern = 1, .ids = .{ .{ 0, 0, 3, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 3, 3 }, .{ 0, 0, 1, 3 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 3, 1 } } },
        .{ .pattern = 2, .ids = .{ .{ 0, 0, 2, 0 }, .{ 0, 1, 2, 0 }, .{ 0, 1, 2, 3 }, .{ 0, 0, 2, 3 }, .{ 0, 1, 2, 2 }, .{ 0, 0, 2, 2 } } },
        .{ .pattern = 6, .ids = .{ .{ 0, 0, 1, 0 }, .{ 0, 0, 1, 1 }, .{ 0, 0, 1, 2 }, .{ 0, 0, 1, 3 }, .{ 0, 0, 3, 0 }, .{ 0, 0, 3, 1 } } },
        .{ .pattern = 7, .ids = .{ .{ 0, 1, 4, 0 }, .{ 0, 1, 4, 3 }, .{ 0, 1, 2, 0 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 3, 0 }, .{ 0, 1, 3, 3 } } },
        .{ .pattern = 12, .ids = .{ .{ 0, 1, 2, 0 }, .{ 0, 1, 2, 1 }, .{ 0, 1, 2, 2 }, .{ 0, 1, 2, 3 }, .{ 0, 1, 4, 0 }, .{ 0, 1, 4, 1 } } },
    };
    var arena = memory.Arena.init(t.allocator, .{});
    defer arena.deinit();
    for (expected) |entry| {
        arena.reset();
        var search = try Search.init(&arena, &.{ 4, 3, 5, 4 }, .{});
        const actual = try search.bestPaths(&arena, Costs{ .pattern = entry.pattern }, 6, .{});
        try t.expectEqual(entry.ids.len, actual.len);
        for (actual, entry.ids) |path, ids| {
            for (path.states, ids, 0..) |id, expected_id, time| {
                try t.expectEqual(StateId{ .time = @intCast(time), .id = expected_id }, id);
            }
        }
    }
}
