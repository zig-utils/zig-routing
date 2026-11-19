// Ported from src/thor/route_action.cc (Valhalla 3.9.3).

const std = @import("std");
const graph = @import("../graph/root.zig");
const scratch = @import("../infra/arena.zig");
const api = @import("../api/request.zig");
const snap = @import("../snap/search.zig");
const Reach = @import("../snap/reach.zig").Counts;
const Cost = @import("../costing/compiled.zig").Cost;
const endpoints = @import("endpoints.zig");
const search = @import("search.zig");
const EdgeId = graph.format.EdgeId;

pub const Waypoint = struct {
    elapsed_secs: f32,
    /// TODO(P5.15): Apply waiting when computing the next departure time.
    waiting_secs: f32,
    /// TODO(P5.15): Propagate arrival/departure timestamps and time zones.
    date_time: ?[]const u8,
    ignored_filter: bool,
};

pub const SegmentContext = struct {
    pair: usize,
    starts_pair: bool,
};

pub const Leg = struct {
    origin: usize,
    destination: usize,
    segments: []const endpoints.Segment,
    segment_contexts: []const SegmentContext,
    length_km: f32,
    cost: Cost,
};

pub const Route = struct {
    legs: []const Leg,
    waypoints: []const Waypoint,
    total: Cost,
    retried: bool,
};

pub const Options = struct {
    search: endpoints.Options,
    defaults: snap.Defaults = .{},
};

/// Find consecutive paths, keeping the arriving edge when the stop
/// forbids reversing. Return legs and waypoints in physical travel order.
pub fn route(engine: anytype, arena: *scratch.Arena, kernel: anytype, locations: []const api.Location, correlations: []const snap.PathLocation, options: Options, control: search.Control) !Route {
    try control.check();
    if (locations.len < 2 or locations.len != correlations.len) return error.InvalidLocations;
    const a = arena.allocator();
    const ranked = try a.alloc(endpoints.Ranked, locations.len);
    for (correlations, ranked) |location, *out| {
        out.* = try endpoints.rank(a, location, options.search.costing, control);
    }
    const point = arena.mark();
    var retried = false;
    const paths = findPairs(engine, arena, kernel, locations, ranked, options, true, control) catch |err| blk: {
        if (err != error.RetryReachability) return err;
        arena.rewind(point);
        const reachable = try a.dupe(endpoints.Ranked, ranked);
        for (locations[1 .. locations.len - 1], reachable[1 .. reachable.len - 1]) |location, *ranked_location| {
            const minimum = snap.thresholds(location, options.defaults);
            ranked_location.* = try filter(a, ranked_location.*, .{ .reach = minimum }, control);
            if (ranked_location.preferred_count == 0) return error.NoPath;
        }
        retried = true;
        break :blk try findPairs(engine, arena, kernel, locations, reachable, options, false, control);
    };
    return assemble(a, engine.view, locations, ranked, paths, retried, control);
}

fn isThrough(kind: api.LocationType) bool {
    return kind == .through or kind == .break_through;
}

fn isBreak(kind: api.LocationType) bool {
    return kind == .@"break" or kind == .break_through;
}

const Filter = union(enum) {
    edge: EdgeId,
    reach: Reach,
};

fn filter(a: std.mem.Allocator, input: endpoints.Ranked, condition: Filter, control: search.Control) !endpoints.Ranked {
    const kept = try a.alloc(endpoints.Candidate, input.all.len);
    var count: usize = 0;
    var preferred: usize = 0;
    for (input.all, 0..) |candidate, i| {
        if (i % 64 == 0) try control.check();
        const keep = switch (condition) {
            .edge => |edge| candidate.edge == edge,
            .reach => |minimum| candidate.reach.satisfies(minimum),
        };
        if (!keep) continue;
        kept[count] = candidate;
        count += 1;
        preferred += @intFromBool(i < input.preferred_count);
    }
    return .{
        .all = kept[0..count],
        .preferred_count = preferred,
        .ignored_filter = input.ignored_filter,
    };
}

fn findPairs(engine: anytype, arena: *scratch.Arena, kernel: anytype, locations: []const api.Location, candidates: []const endpoints.Ranked, options: Options, allow_reach_retry: bool, control: search.Control) ![]const endpoints.Path {
    const a = arena.allocator();
    const paths = try a.alloc(endpoints.Path, candidates.len - 1);
    const reverse = options.search.direction == .reverse;
    var carried: ?EdgeId = null;
    for (0..paths.len) |step| {
        try control.check();
        const pair = if (reverse) paths.len - step - 1 else step;
        var from = candidates[pair];
        var to = candidates[pair + 1];
        const waypoint = if (reverse) pair + 1 else pair;
        var pair_options = options.search;
        pair_options.forbid_initial_uturn = false;
        var restricted: ?endpoints.Ranked = null;
        if (carried) |edge| {
            if (isThrough(locations[waypoint].type)) {
                const passing = if (reverse) &to else &from;
                passing.* = try filter(a, passing.*, .{ .edge = edge }, control);
                restricted = passing.*;
                pair_options.forbid_initial_uturn = true;
            }
        }
        const path = endpoints.routeRanked(engine, arena, kernel, from, to, pair_options, search.Zero{}, control) catch |err| {
            if (err != error.NoPath or !allow_reach_retry) return err;
            if (restricted) |choice| {
                if (choice.preferred_count != 0 and
                    !choice.all[0].reach.satisfies(snap.thresholds(locations[waypoint], options.defaults)))
                    return error.RetryReachability;
            }
            return err;
        };
        paths[pair] = path;
        carried = if (reverse) path.segments[0].edge else path.segments[path.segments.len - 1].edge;
    }
    return paths;
}

fn assemble(a: std.mem.Allocator, view: *const graph.reader.View, locations: []const api.Location, ranked: []const endpoints.Ranked, paths: []const endpoints.Path, reach_retry: bool, control: search.Control) !Route {
    var leg_count: usize = 1;
    var segment_count: usize = 0;
    for (paths, 0..) |path, i| {
        if (i % 64 == 0) try control.check();
        segment_count = try std.math.add(usize, segment_count, path.segments.len);
        if (i + 1 < paths.len and isBreak(locations[i + 1].type)) leg_count += 1;
    }
    const legs = try a.alloc(Leg, leg_count);
    const segments = try a.alloc(endpoints.Segment, segment_count);
    const segment_contexts = try a.alloc(SegmentContext, segment_count);
    const waypoints = try a.alloc(Waypoint, locations.len);

    var total: Cost = .{};
    var leg_cost: Cost = .{};
    var length_km: f32 = 0;
    var leg_index: usize = 0;
    var leg_origin: usize = 0;
    var leg_start: usize = 0;
    var end: usize = 0;
    var retried = reach_retry;
    waypoints[0] = timing(locations[0], ranked[0], 0);
    for (paths, 0..) |path, i| {
        try control.check();
        const step: Cost = .{ .cost = path.cost, .secs = path.secs };
        total = total.add(step);
        leg_cost = leg_cost.add(step);
        retried = retried or path.retried;
        waypoints[i + 1] = timing(locations[i + 1], ranked[i + 1], total.secs);

        // Preserve both cuts at waypoints inside an edge. At a node, the
        // search may represent continuity with a repeated zero-length cut.
        for (path.segments, 0..) |segment, j| {
            if (j % 1024 == 0) try control.check();
            var starts_pair = j == 0;
            if (j == 0 and end > leg_start and segment.edge == segments[end - 1].edge) {
                if (atNode(segment)) continue;
                if (atNode(segments[end - 1])) {
                    // The previous search entered this edge at the node.
                    // Its transition still belongs to the stitched path.
                    starts_pair = segment_contexts[end - 1].starts_pair;
                    end -= 1;
                }
            }
            segments[end] = segment;
            segment_contexts[end] = .{ .pair = i, .starts_pair = starts_pair };
            end += 1;
            // TripLegBuilder stores the edge's fractional kilometres as
            // f32 and EnhancedTripLeg::GetLength sums those in path order.
            const metres: f32 = @floatFromInt((try view.edge(segment.edge)).geom.len_m);
            length_km += metres * 0.001 * (segment.end - segment.begin);
        }
        if (i + 1 == paths.len or isBreak(locations[i + 1].type)) {
            legs[leg_index] = .{
                .origin = leg_origin,
                .destination = i + 1,
                .segments = segments[leg_start..end],
                .segment_contexts = segment_contexts[leg_start..end],
                .length_km = length_km,
                .cost = leg_cost,
            };
            leg_index += 1;
            leg_origin = i + 1;
            leg_start = end;
            leg_cost = .{};
            length_km = 0;
        }
    }
    return .{ .legs = legs, .waypoints = waypoints, .total = total, .retried = retried };
}

fn atNode(segment: endpoints.Segment) bool {
    return segment.begin == segment.end and (segment.begin == 0 or segment.begin == 1);
}

fn timing(location: api.Location, ranked: endpoints.Ranked, elapsed: f32) Waypoint {
    return .{
        .elapsed_secs = elapsed,
        .waiting_secs = location.waiting_secs,
        .date_time = location.date_time,
        .ignored_filter = ranked.ignored_filter,
    };
}
