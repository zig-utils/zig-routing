// Ported from src/thor/unidirectional_astar.cc and src/thor/worker.cc
// (Valhalla 3.9.3), for partial directed-edge origins and destinations.

const std = @import("std");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/search.zig");
const Reach = @import("../snap/reach.zig").Counts;
const request = @import("../api/request.zig");
const core = @import("search.zig");
const paged = @import("paged.zig");
const Arena = @import("../infra/arena.zig").Arena;
const EdgeId = graph.format.EdgeId;

pub const Candidate = struct {
    edge: EdgeId,
    fraction: f32,
    score: f32,
    begin_node: bool,
    end_node: bool,
    reach: Reach = .{},

    pub fn valid(self: Candidate) bool {
        return self.fraction >= 0 and self.fraction <= 1 and
            std.math.isFinite(self.score) and self.score >= 0 and
            !(self.begin_node and self.end_node);
    }
};

pub const Ranked = struct {
    all: []const Candidate,
    preferred_count: usize,
    /// Valhalla warning 215 when every candidate failed heading or side.
    ignored_filter: bool,

    pub fn candidates(self: Ranked, include_filtered: bool) []const Candidate {
        return if (include_filtered) self.all else self.all[0..self.preferred_count];
    }
};

fn maxScore(costing: request.Costing) f32 {
    return switch (costing) {
        .bicycle, .multimodal, .pedestrian, .bikeshare => 7200,
        .motor_scooter, .motorcycle, .transit => 14400,
        else => 43200,
    };
}

/// thor_worker_t::adjust_locations. Distances are narrowed before the
/// penalty calculation, matching the float field in Valhalla's PathEdge.
pub fn rank(arena: std.mem.Allocator, location: snap.PathLocation, costing: request.Costing, control: core.Control) !Ranked {
    try control.check();
    const count = try std.math.add(usize, location.edges.len, location.filtered_edges.len);
    if (count == 0) return error.NoCandidates;
    const candidates = try arena.alloc(Candidate, count);
    const ignored_filter = location.edges.len == 0;
    var largest: f32 = 0;
    for (location.edges, 0..) |edge, i| {
        if (i % 64 == 0) try control.check();
        largest = @max(largest, @as(f32, @floatCast(edge.distance)));
    }

    var minimum = std.math.floatMax(f32);
    var offset: usize = 0;
    for ([_][]const snap.PathEdge{ location.edges, location.filtered_edges }, 0..) |edges, group| {
        for (edges, 0..) |edge, index| {
            if (index % 64 == 0) try control.check();
            if (!(0 <= edge.percent_along and edge.percent_along <= 1) or
                !std.math.isFinite(edge.distance) or edge.distance < 0) return error.InvalidCandidate;
            var metres: f32 = @floatCast(edge.distance);
            if (group != 0 and !ignored_filter) metres = (metres + 3600) + largest;
            const score = if (location.rank_candidates) metres * metres * 10 else 0;
            if (!std.math.isFinite(score)) return error.InvalidCandidate;
            candidates[offset] = .{
                .edge = edge.id,
                .fraction = edge.percent_along,
                .score = score,
                .begin_node = edge.node == .begin,
                .end_node = edge.node == .end,
                .reach = edge.reach,
            };
            minimum = @min(minimum, score);
            offset += 1;
        }
    }
    for (candidates, 0..) |*candidate, i| {
        if (i % 64 == 0) try control.check();
        candidate.score = @min(maxScore(costing), candidate.score - minimum);
    }
    return .{
        .all = candidates,
        .preferred_count = if (ignored_filter) count else location.edges.len,
        .ignored_filter = ignored_filter,
    };
}

fn departureOnly(candidate: Candidate, direction: core.Direction) bool {
    return if (direction == .forward) candidate.begin_node else candidate.end_node;
}

fn arrivalOnly(candidate: Candidate, direction: core.Direction) bool {
    return if (direction == .forward) candidate.end_node else candidate.begin_node;
}

pub const Targets = struct {
    pub const Entry = struct {
        candidate: Candidate,
        next: u32,
    };
    entries: []const Entry = &.{},
    heads: paged.Array(u32, 0) = .{},

    /// SetDestination discards zero-traversal candidates at a node when an
    /// incoming candidate exists. Edges are indexed in physical travel order.
    pub fn init(arena: std.mem.Allocator, candidates: []const Candidate, direction: core.Direction, control: core.Control) !Targets {
        var has_arrival = false;
        for (candidates, 0..) |candidate, i| {
            if (i % 64 == 0) try control.check();
            if (!departureOnly(candidate, direction)) {
                has_arrival = true;
                break;
            }
        }
        var targets: Targets = .{};
        const entries = try arena.alloc(Entry, candidates.len);
        var count: usize = 0;
        // Insert in reverse order so equal-cost candidates retain snap order.
        var i = candidates.len;
        while (i != 0) {
            i -= 1;
            if (i % 64 == 0) try control.check();
            const candidate = candidates[i];
            if (!candidate.valid()) return error.InvalidCandidate;
            if (has_arrival and departureOnly(candidate, direction)) continue;
            const id = @backingInt(candidate.edge);
            const slot = try targets.heads.at(arena, id);
            const next = std.math.cast(u32, count + 1) orelse return error.TooManyCandidates;
            entries[count] = .{ .candidate = candidate, .next = slot.* };
            slot.* = next;
            count += 1;
        }
        targets.entries = entries[0..count];
        return targets;
    }

    pub fn on(self: *const Targets, edge: EdgeId) Iterator {
        return .{ .entries = self.entries, .index = self.heads.get(@backingInt(edge)) };
    }

    pub const Iterator = struct {
        entries: []const Entry,
        index: u32,

        pub fn next(self: *Iterator) ?Candidate {
            if (self.index == 0) return null;
            const entry = self.entries[self.index - 1];
            self.index = entry.next;
            return entry.candidate;
        }
    };
};

/// SetOrigin discards zero-traversal candidates if any outgoing candidate
/// exists. Retain the coincident-end exception to allow a route on one node.
pub fn starts(arena: std.mem.Allocator, candidates: []const Candidate, targets: *const Targets, direction: core.Direction, control: core.Control) ![]const Candidate {
    var has_departure = false;
    for (candidates, 0..) |candidate, i| {
        if (i % 64 == 0) try control.check();
        if (!arrivalOnly(candidate, direction)) {
            has_departure = true;
            break;
        }
    }
    if (!has_departure) return candidates;

    const accepted = try arena.alloc(Candidate, candidates.len);
    var count: usize = 0;
    for (candidates, 0..) |candidate, i| {
        if (i % 64 == 0) try control.check();
        if (arrivalOnly(candidate, direction)) {
            var dest = targets.on(candidate.edge);
            const coincident = found: {
                while (dest.next()) |target| {
                    try control.check();
                    if (target.fraction == candidate.fraction) break :found true;
                }
                break :found false;
            };
            if (!coincident) continue;
        }
        accepted[count] = candidate;
        count += 1;
    }
    return accepted[0..count];
}

pub const Segment = struct {
    edge: EdgeId,
    begin: f32,
    end: f32,
};

pub const Path = struct {
    segments: []const Segment,
    cost: f32,
    secs: f32,
    distance: u32,
    ignored_filter: [2]bool,
    retried: bool,
};

pub const Options = struct {
    costing: request.Costing,
    direction: core.Direction = .forward,
    /// The consuming worker can supply the selected model's policy. When
    /// omitted the pedestrian and bicycle defaults follow Valhalla.
    allow_filtered_retry: ?bool = null,
    forbid_initial_uturn: bool = false,
};

pub fn route(engine: anytype, arena: *Arena, kernel: anytype, origin: snap.PathLocation, destination: snap.PathLocation, options: Options, potential: anytype, control: core.Control) !Path {
    const a = arena.allocator();
    const from = try rank(a, origin, options.costing, control);
    const to = try rank(a, destination, options.costing, control);
    return routeRanked(engine, arena, kernel, from, to, options, potential, control);
}

/// Reuse the original score normalization when a waypoint's candidate set
/// is later narrowed to its arrival edge.
pub fn routeRanked(engine: anytype, arena: *Arena, kernel: anytype, from: Ranked, to: Ranked, options: Options, potential: anytype, control: core.Control) !Path {
    const a = arena.allocator();
    const start = if (options.direction == .forward) from else to;
    const goal = if (options.direction == .forward) to else from;
    const point = arena.mark();
    var retried = false;
    const result = attempt(engine, arena, kernel, start, goal, options, potential, false, control) catch |err| blk: {
        const allow_retry = options.allow_filtered_retry orelse (options.costing == .pedestrian);
        const has_filtered = start.preferred_count < start.all.len or goal.preferred_count < goal.all.len;
        if (err != error.NoPath or !allow_retry or !has_filtered) return err;
        arena.rewind(point);
        retried = true;
        break :blk try attempt(engine, arena, kernel, start, goal, options, potential, true, control);
    };
    const segments = try unpack(a, result, options.direction, control);
    const last = result.best();
    return .{
        .segments = segments,
        .cost = last.cost,
        .secs = last.secs,
        .distance = last.dist_m,
        .ignored_filter = .{ from.ignored_filter, to.ignored_filter },
        .retried = retried,
    };
}

fn attempt(engine: anytype, arena: *Arena, kernel: anytype, start: Ranked, goal: Ranked, options: Options, potential: anytype, filtered: bool, control: core.Control) !core.Result {
    const a = arena.allocator();
    const targets = try Targets.init(a, goal.candidates(filtered), options.direction, control);
    const seeds = try starts(a, start.candidates(filtered), &targets, options.direction, control);
    return engine.runPartial(arena, kernel, .{
        .starts = seeds,
        .targets = &targets,
        .direction = options.direction,
        .forbid_initial_uturn = options.forbid_initial_uturn,
    }, potential, control);
}

fn unpack(arena: std.mem.Allocator, result: core.Result, direction: core.Direction, control: core.Control) ![]Segment {
    var count: usize = 0;
    var index = result.index;
    while (index != core.no_index) : (count += 1) {
        if (count % 1024 == 0) try control.check();
        index = result.labels[index].pred;
    }
    const segments = try arena.alloc(Segment, count);
    index = result.index;
    for (0..count) |i| {
        if (i % 1024 == 0) try control.check();
        const label = result.labels[index];
        const cut: core.Cut = if (label.ctx == 0) .{} else result.cuts[label.ctx - 1];
        const position = if (direction == .forward) count - i - 1 else i;
        segments[position] = .{ .edge = label.edgeId(), .begin = cut.begin, .end = cut.end };
        index = label.pred;
    }
    return segments;
}
