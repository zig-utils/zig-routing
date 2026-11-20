// Ported from src/loki/route_action.cc and src/thor/route_action.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const snap = @import("../snap/root.zig");
const search = @import("../search/root.zig");
const costing = @import("../costing/root.zig");
const io = @import("../infra/io.zig");
const Arena = @import("../infra/arena.zig").Arena;
const request = @import("request.zig");
const Failure = @import("errors.zig").Failure;
const TripLeg = @import("trip.zig").TripLeg;

pub const Result = union(enum) {
    scheduled: ScheduledRoute,
    failure: Failure,
};

pub const ScheduledRoute = struct {
    paths: []const search.multimodal.Path,
    correlations: []const snap.candidates.PathLocation,
    waypoints: []const search.multi.Waypoint,
    pedestrian_type: costing.pedestrian.Type,

    pub fn trip(self: ScheduledRoute, a: std.mem.Allocator, view: *const graph.reader.View, options: *const request.Options, control: search.search.Control) ![]TripLeg {
        const attributes = try options.tripAttributes(true, control.deadline);
        const legs = try search.legs.buildScheduled(a, view, self.paths, options.locations, self.correlations, control);
        const output = try a.alloc(TripLeg, legs.len);
        for (legs, output, 0..) |*leg, *out, i| {
            try control.check();
            out.* = try search.tripleg.build(a, view, .{
                .segments = leg.segments,
                .geometry = &leg.geometry,
                .attributes = attributes,
                .travel = .{ .pedestrian = @fromBackingInt(@backingInt(self.pedestrian_type)) },
                .locations = .{ .requested = options.locations, .correlations = self.correlations, .waypoints = self.waypoints, .segment_contexts = leg.contexts },
                .algorithms = &.{"multimodal"},
                .leg_id = @intCast(i),
                .leg_count = @intCast(legs.len),
            }, control);
        }
        return output;
    }
};

pub fn route(view: *const graph.reader.View, arena: *Arena, options: *const request.Options, now: ?i64, control: search.search.Control) !Result {
    try control.check();
    return switch (options.costing) {
        .transit, .multimodal => scheduled(view, arena, options, now orelse io.wallSeconds(), control),
        else => .{ .failure = .{ .code = 107, .extra = "route" } },
    };
}

fn scheduled(view: *const graph.reader.View, arena: *Arena, options: *const request.Options, now: i64, control: search.search.Control) !Result {
    if (options.date_time_type == .arrive_by or options.date_time_type == .invariant)
        return .{ .failure = .{ .code = 141 } };
    const a = arena.allocator();
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    const profiles = try costing.multimodal.parse(a, options.costing_options orelse .null, &warnings, control.deadline);
    const kernel = try costing.multimodal.Kernel.init(a, view, profiles, control.deadline);
    const defaults: snap.candidates.Defaults = .{};
    const snapped = if (view.transit_index == null)
        try snap.location.route(view, a, options.locations, defaults, &kernel.walking, control.deadline)
    else
        try snap.location.correlate(view, a, options.locations, defaults, &kernel.walking, control.deadline);
    const correlated = switch (snapped) {
        .ok => |locations| locations,
        .failure => |failure| return .{ .failure = failure },
    };
    const ranked = try a.alloc(search.endpoints.Ranked, correlated.len);
    for (ranked, correlated) |*entry, location| entry.* = try search.endpoints.rank(a, location, options.costing, control);
    const engine = try search.multimodal.Search.init(a, view, &kernel, control);
    const excluded = try snap.exclusions.resolve(view, a, options, &.{}, defaults, &kernel.walking, control.deadline);
    const date_type: request.DateTimeType = if (options.date_time_type == .no_time) .current else options.date_time_type;
    const rules = if (view.tz_rules) |*present| present else null;
    var clock = try search.multi.startTiming(view, ranked[0].all[0].edge, date_type, options.locations[0].date_time, now, control);
    const waypoints = try a.alloc(search.multi.Waypoint, ranked.len);
    const paths = try a.alloc(search.multimodal.Path, ranked.len - 1);
    waypoints[0] = try waypoint(a, rules, clock.start, 0, 0, ranked[0].ignored_filter);
    var elapsed: f32 = 0;
    for (paths, 0..) |*path, i| {
        try control.check();
        var origin = ranked[i];
        const destination = ranked[i + 1];
        const direct_distance = firstProjection(correlated[i]).distance(firstProjection(correlated[i + 1]));
        if (direct_distance > 2000 and !try engine.destinationHasPlatform(destination, control))
            return .{ .failure = .{ .code = 440 } };
        const location = options.locations[i];
        const through = i != 0 and (location.type == .through or location.type == .break_through);
        if (through) {
            const previous = paths[i - 1].steps;
            origin = try carryEdge(a, origin, previous[previous.len - 1].movement.walk.edge, control);
        }
        const query: search.endpoints.Options = .{ .costing = options.costing, .timing = clock, .excluded = excluded, .forbid_initial_uturn = through };
        const mark = arena.mark();
        path.* = engine.run(arena, origin, destination, query, control) catch |err| blk: {
            if (err != error.NoPath) return err;
            if (origin.preferred_count == origin.all.len and destination.preferred_count == destination.all.len)
                return .{ .failure = .{ .code = 442 } };
            arena.rewind(mark);
            break :blk engine.attempt(arena, origin, destination, query, true, control) catch |retry_error| {
                if (retry_error == error.NoPath) return .{ .failure = .{ .code = 442 } };
                return retry_error;
            };
        };
        const last = path.steps[path.steps.len - 1].movement.walk;
        const node: graph.format.NodeId = @fromBackingInt((try view.edge(last.edge)).head);
        const destination_type = options.locations[i + 1].type;
        const waiting = if (i + 1 < paths.len and (destination_type == .@"break" or destination_type == .break_through))
            @max(0, options.locations[i + 1].waiting_secs)
        else
            0;
        elapsed += path.total.secs;
        clock.start = try clock.at(view, node, @floor(path.total.secs + waiting + 0.5), .forward);
        waypoints[i + 1] = try waypoint(a, rules, clock.start, elapsed, waiting, destination.ignored_filter);
    }
    return .{ .scheduled = .{ .paths = paths, .correlations = correlated, .waypoints = waypoints, .pedestrian_type = profiles.pedestrian.transport } };
}

fn firstProjection(location: snap.candidates.PathLocation) @import("../geo/point.zig").PointLL {
    const candidates = if (location.edges.len != 0) location.edges else location.filtered_edges;
    return candidates[0].projected;
}

fn carryEdge(a: std.mem.Allocator, ranked: search.endpoints.Ranked, edge: graph.format.EdgeId, control: search.search.Control) !search.endpoints.Ranked {
    const choices = try a.alloc(search.endpoints.Candidate, ranked.all.len);
    var count: usize = 0;
    var preferred: usize = 0;
    for (ranked.all, 0..) |item, i| {
        try control.check();
        if (item.edge != edge) continue;
        choices[count] = item;
        count += 1;
        preferred += @intFromBool(i < ranked.preferred_count);
    }
    return .{ .all = choices[0..count], .preferred_count = preferred, .ignored_filter = ranked.ignored_filter };
}

fn waypoint(a: std.mem.Allocator, rules: ?*const graph.timezone.Rules, clock: graph.time_info.TimeInfo, elapsed: f32, waiting: f32, ignored_filter: bool) !search.multi.Waypoint {
    var value: search.multi.Waypoint = .{ .elapsed_secs = elapsed, .waiting_secs = waiting, .date_time = null, .ignored_filter = ignored_filter, .clock = clock };
    const text = try a.alloc(u8, 22);
    if (try clock.display(rules, text)) |formatted| {
        value.date_time = formatted.date_time;
        value.time_zone_offset = formatted.time_zone_offset;
        value.time_zone_name = formatted.time_zone_name;
    }
    return value;
}
