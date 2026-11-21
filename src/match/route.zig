// Ported from src/meili/match_route.cc, src/meili/map_matcher.cc and
// src/thor/map_matcher.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const graph = @import("../graph/root.zig");
const memory = @import("../infra/arena.zig");
const core = @import("../search/search.zig");
const route_legs = @import("../search/legs.zig");
const endpoints = @import("../search/endpoints.zig");
const request = @import("../api/request.zig");
const snap = @import("../snap/search.zig");
const ShapeMatch = @import("../api/proto/options.zig").ShapeMatch;
const candidates = @import("candidates.zig");
const routing = @import("routing.zig");
const viterbi = @import("viterbi.zig");
const walking = @import("walk.zig");
const Emission = @import("emission.zig").Model;
const Transition = @import("transition.zig").Model;
const EdgeId = graph.format.EdgeId;
const View = graph.reader.View;
const Allocator = std.mem.Allocator;
const Measurement = candidates.Measurement;

pub const EndpointCorrelations = struct {
    origin: []const snap.PathEdge,
    target: []const snap.PathEdge,
};

pub const Options = struct {
    shape_match: ShapeMatch = .walk_or_snap,
    use_timestamps: bool = false,
    require_timestamps: bool = true,
    best_paths: u32 = 1,
    interpolation_distance: f32 = 10,
    timing: core.Timing = .{},
    correlated: ?EndpointCorrelations = null,
    start_clock: ?StartClock = null,
};

pub const StartClock = struct {
    date: ?[]const u8,
    timestamp: f64,
    now: i64,
};

pub const Match = struct {
    point: geo.PointLL,
    edge: ?EdgeId = null,
    fraction: f32 = -1,
    distance: f32 = 0,
    epoch_time: f64,
    state: viterbi.StateId = .{},
    kind: enum { matched, interpolated, unmatched } = .unmatched,
    break_point: bool,
    begins_discontinuity: bool = false,
    ends_discontinuity: bool = false,

    fn at(measurement: Measurement) Match {
        return .{
            .point = measurement.point,
            .epoch_time = measurement.epoch_time,
            .break_point = breaks(measurement.stop_type),
        };
    }
};

pub const Segment = struct {
    path: endpoints.Segment,
    first_match: ?u32 = null,
    last_match: ?u32 = null,
    discontinuity: bool = false,
    // Edge walking knows the index of each edge's end vertex in the trace.
    shape_end: ?u32 = null,
};

pub const Leg = struct {
    segments: []const endpoints.Segment,
    steps: []const route_legs.Recost.Step,
    first_match: u32,
    last_match: u32,
};

pub const Result = struct {
    matches: []const Match,
    segments: []const Segment,
    legs: []const Leg,
    score: f64 = 0,
};

fn breaks(stop_type: request.LocationType) bool {
    return stop_type == .@"break" or stop_type == .break_through;
}

const Columns = struct {
    states: viterbi.StateContainer = .{},
    input_indices: std.ArrayList(u32) = .empty,

    fn collect(self: *Columns, a: Allocator, finder: *candidates.Finder, kernel: anytype, trace: []const Measurement, distance: f32, control: core.Control) !void {
        var selected: usize = 0;
        const squared = distance * distance;
        for (trace, 0..) |measurement, i| {
            try control.check();
            if (i > 0 and i + 1 < trace.len and trace[selected].point.distanceSquared(measurement.point) <= squared) continue;
            if (i > selected + 1 and trace[i - 1].epoch_time >= 0) {
                const previous = trace[selected].point;
                const gap = previous.distance(measurement.point);
                if (gap > 0 and previous.distance(trace[i - 1].point.project(previous, measurement.point)) / gap < 0.2) {
                    self.states.columns.items[self.states.columns.items.len - 1].leave_time = trace[i - 1].epoch_time;
                }
            }
            const found = try finder.query(measurement, kernel, control.deadline);
            _ = try self.states.append(a, measurement, found);
            try self.input_indices.append(a, @intCast(i));
            selected = i;
        }
    }
};

pub fn resolve(
    arena: *memory.Arena,
    finder: *candidates.Finder,
    router: anytype,
    kernel: anytype,
    trace: []const Measurement,
    observations: Emission,
    movements: Transition,
    options: Options,
    control: core.Control,
) ![]const Result {
    try control.check();
    if (trace.len < 2 or trace.len >= core.no_index) return error.InvalidTraceShape;
    if (!(options.interpolation_distance > 0) or !std.math.isFinite(options.interpolation_distance)) return error.InvalidInterpolationDistance;
    if (options.best_paths == 0) return error.InvalidBestPathCount;
    var has_timestamp = false;
    for (trace, 0..) |measurement, i| {
        if (i % 256 == 0) try control.check();
        if (!measurement.point.inRange() or !std.math.isFinite(measurement.epoch_time)) return error.InvalidMeasurement;
        has_timestamp = has_timestamp or measurement.epoch_time >= 0;
    }
    if (options.use_timestamps and options.require_timestamps and !has_timestamp) return error.MissingTraceTimestamps;
    const mark = arena.mark();
    errdefer arena.rewind(mark);
    if (options.shape_match != .map_snap) {
        const view = finder.view;
        const a = arena.allocator();
        const correlated = options.correlated orelse blk: {
            const origin = try snap.search(view, a, .{ .lat = trace[0].point.lat, .lng = trace[0].point.lng }, .{}, kernel, control.deadline);
            const last = trace[trace.len - 1].point;
            const target = try snap.search(view, a, .{ .lat = last.lat, .lng = last.lng }, .{}, kernel, control.deadline);
            break :blk EndpointCorrelations{ .origin = origin.edges, .target = target.edges };
        };
        if (walking.find(view, arena, trace, correlated.origin, correlated.target, control)) |parts| {
            const output = try a.alloc(Result, 1);
            output[0] = try walked(a, view, kernel, trace, parts, correlated, options, control);
            return output;
        } else |err| {
            if (err != error.NoEdgeWalk or options.shape_match == .edge_walk) return err;
            arena.rewind(mark);
        }
    }
    return snapTrace(arena, finder, router, kernel, trace, observations, movements, options, control);
}

fn snapTrace(arena: *memory.Arena, finder: *candidates.Finder, router: anytype, kernel: anytype, trace: []const Measurement, observations: Emission, movements: Transition, options: Options, control: core.Control) ![]const Result {
    const a = arena.allocator();
    var columns: Columns = .{};
    try columns.collect(a, finder, kernel, trace, options.interpolation_distance, control);
    var search = try columns.states.startSearch(arena, control);
    var costs = try viterbi.RoutingCosts(@TypeOf(kernel)).init(arena, &columns.states, router, kernel, observations, movements, control);
    const Collector = struct {
        arena: *memory.Arena,
        view: *const View,
        kernel: @TypeOf(kernel),
        trace: []const Measurement,
        columns: *const Columns,
        costs: *@TypeOf(costs),
        observations: Emission,
        movements: Transition,
        options: Options,
        results: std.ArrayList(Result) = .empty,
        sequences: std.ArrayList([]const EdgeId) = .empty,

        pub fn accept(self: *@This(), alloc: Allocator, path: viterbi.Path, work: core.Control) !bool {
            const result = try stitch(self.arena, self.view, self.kernel, self.trace, self.columns, self.costs, path, self.observations, self.movements, self.options, work);
            if (self.options.best_paths > 1 and result.segments.len != 0) {
                const sequence = try edgeSequence(alloc, result.segments, work);
                for (self.sequences.items) |prior| {
                    if (try containsEdges(prior, sequence, work) or try containsEdges(sequence, prior, work)) return false;
                }
                try self.sequences.append(alloc, sequence);
            }
            try self.results.append(alloc, result);
            return true;
        }
    };
    var collector: Collector = .{
        .arena = arena,
        .view = finder.view,
        .kernel = kernel,
        .trace = trace,
        .columns = &columns,
        .costs = &costs,
        .observations = observations,
        .movements = movements,
        .options = options,
    };
    try search.enumeratePaths(arena, &costs, options.best_paths, &collector, control);
    return collector.results.items;
}

/// The public alternates describe distinct traversals. Adjacent cuts on
/// one directed edge and zero-length end cuts do not distinguish routes.
fn edgeSequence(a: Allocator, segments: []const Segment, control: core.Control) ![]const EdgeId {
    var edges: std.ArrayList(EdgeId) = .empty;
    for (segments, 0..) |segment, i| {
        if (i % 256 == 0) try control.check();
        if ((i == 0 and segment.path.begin == 1) or (i + 1 == segments.len and segment.path.end == 0)) continue;
        if (edges.items.len != 0 and edges.items[edges.items.len - 1] == segment.path.edge) continue;
        try edges.append(a, segment.path.edge);
    }
    return edges.items;
}

fn containsEdges(path: []const EdgeId, candidate: []const EdgeId, control: core.Control) !bool {
    if (candidate.len == 0) return path.len == 0;
    if (candidate.len > path.len) return false;
    for (0..path.len - candidate.len + 1) |start| {
        if (start % 256 == 0) try control.check();
        if (path[start] != candidate[0]) continue;
        for (path[start..][0..candidate.len], candidate, 0..) |edge, wanted, i| {
            if (i % 256 == 0) try control.check();
            if (edge != wanted) break;
        } else return true;
    }
    return false;
}

fn initialMatches(a: Allocator, trace: []const Measurement, control: core.Control) ![]Match {
    const matches = try a.alloc(Match, trace.len);
    for (trace, matches, 0..) |measurement, *match, i| {
        if (i % 256 == 0) try control.check();
        match.* = .at(measurement);
    }
    return matches;
}

fn walked(a: Allocator, view: *const View, kernel: anytype, trace: []const Measurement, parts: []const walking.Part, correlated: EndpointCorrelations, options: Options, control: core.Control) !Result {
    const matches = try initialMatches(a, trace, control);
    const segments = try a.alloc(Segment, parts.len);
    const last: u32 = @intCast(matches.len - 1);
    for (parts, segments, 0..) |part, *segment, i| {
        try control.check();
        segment.* = .{
            .path = part.segment,
            .first_match = if (i == 0) 0 else null,
            .last_match = if (i + 1 == parts.len) last else null,
            .shape_end = part.last,
        };
        if (i == 0) {
            matches[0].edge = part.segment.edge;
            matches[0].fraction = part.segment.begin;
            matches[0].kind = .matched;
        }
        matches[part.last].edge = part.segment.edge;
        matches[part.last].fraction = part.segment.end;
        matches[part.last].kind = .matched;
        if (part.last <= part.first + 1) continue;
        var length: f64 = 0;
        for (part.first + 1..part.last + 1) |shape_index| {
            if (shape_index % 256 == 0) try control.check();
            length += trace[shape_index - 1].point.distance(trace[shape_index].point);
        }
        var position: f64 = 0;
        for (part.first + 1..part.last) |shape_index| {
            if (shape_index % 256 == 0) try control.check();
            position += trace[shape_index - 1].point.distance(trace[shape_index].point);
            const along: f32 = if (length == 0) 0 else @floatCast(position / length);
            matches[shape_index].edge = part.segment.edge;
            matches[shape_index].fraction = part.segment.begin + along * (part.segment.end - part.segment.begin);
            matches[shape_index].kind = .interpolated;
        }
    }
    for (correlated.origin) |candidate| {
        try control.check();
        if (candidate.id == parts[0].segment.edge and candidate.percent_along == parts[0].segment.begin) {
            matches[0].point = candidate.projected;
            matches[0].distance = @floatCast(candidate.distance);
            break;
        }
    }
    const last_edge = parts[parts.len - 1].segment;
    for (correlated.target) |candidate| {
        try control.check();
        if (candidate.id == last_edge.edge and candidate.percent_along == last_edge.end) {
            matches[last].point = candidate.projected;
            matches[last].distance = @floatCast(candidate.distance);
            break;
        }
    }
    return .{
        .matches = matches,
        .segments = segments,
        .legs = try formPaths(a, view, kernel, matches, segments, options, true, control),
    };
}

fn stitch(arena: *memory.Arena, view: *const View, kernel: anytype, trace: []const Measurement, columns: *const Columns, costs: anytype, path: viterbi.Path, observations: Emission, movements: Transition, options: Options, control: core.Control) !Result {
    const a = arena.allocator();
    const matches = try initialMatches(a, trace, control);
    const pair_paths = try a.alloc(?routing.Route, path.states.len -| 1);
    @memset(pair_paths, null);
    for (path.submatches) |submatch| {
        try control.check();
        for (submatch.first..submatch.first + submatch.count - 1) |index| {
            try control.check();
            pair_paths[index] = (try costs.selectedRoute(arena, path.states[index], path.states[index + 1], control)) orelse
                return error.UnreproducibleTraceTransition;
        }
    }

    const following = try a.alloc(?EdgeId, path.states.len);
    var next: ?EdgeId = null;
    var time = path.states.len;
    while (time > 0) {
        if (time % 256 == 0) try control.check();
        time -= 1;
        if (time < pair_paths.len) {
            if (pair_paths[time]) |pair| {
                if (pair.segments.len > 0) next = pair.segments[0].edge;
            } else next = null;
        }
        following[time] = next;
    }

    var previous: ?EdgeId = null;
    for (path.states, columns.input_indices.items, following, 0..) |id, index, after, t| {
        try control.check();
        const arrives = t != 0 and pair_paths[t - 1] != null;
        const departs = t < pair_paths.len and pair_paths[t] != null;
        if (arrives) {
            previous = pair_paths[t - 1].?.last_edge orelse previous;
        } else previous = null;
        const candidate = columns.states.candidate(id) orelse continue;
        const match = &matches[index];
        match.state = id;
        const direction = (try matchDirection(view, candidate, previous, after)) orelse
            if ((arrives or departs) and candidate.node != null and candidate.arcs().len != 0) candidate.arcs()[0] else continue;
        match.point = candidate.point;
        match.distance = @floatCast(@sqrt(candidate.squared_distance));
        match.edge = direction.edge;
        match.fraction = direction.percent_along;
        match.kind = .matched;
        match.begins_discontinuity = t < pair_paths.len and !path.states[t + 1].valid();
        match.ends_discontinuity = t != 0 and !path.states[t - 1].valid();
    }

    var segments: std.ArrayList(Segment) = .empty;
    var pair_segments: std.ArrayList(Segment) = .empty;
    var interrupted = false;
    for (pair_paths, columns.input_indices.items[0..pair_paths.len], columns.input_indices.items[@min(@as(usize, 1), columns.input_indices.items.len)..]) |maybe_route, left, right| {
        try control.check();
        const route = maybe_route orelse {
            interrupted = true;
            continue;
        };
        pair_segments.clearRetainingCapacity();
        for (route.segments, 0..) |segment, i| {
            if (i % 256 == 0) try control.check();
            try pair_segments.append(a, .{ .path = .{ .edge = segment.edge, .begin = segment.cut.begin, .end = segment.cut.end } });
        }
        if (pair_segments.items.len == 0) {
            const id = matches[right].edge orelse continue;
            const cut = matches[right].fraction;
            try pair_segments.append(a, .{ .path = .{ .edge = id, .begin = cut, .end = cut } });
        }
        if (interrupted and segments.items.len != 0) segments.items[segments.items.len - 1].discontinuity = true;
        try appendPair(arena, view, trace, matches, pair_segments.items, &segments, left, right, observations, movements, control);
        interrupted = false;
    }
    return .{
        .matches = matches,
        .segments = segments.items,
        .legs = try formPaths(a, view, kernel, matches, segments.items, options, false, control),
        .score = path.cost,
    };
}

fn matchDirection(view: *const View, candidate: *const candidates.Candidate, previous: ?EdgeId, following: ?EdgeId) !?candidates.Candidate.Direction {
    for (candidate.arcs()) |direction| {
        if (direction.edge == previous or direction.edge == following) return direction;
        const node = candidate.node orelse continue;
        if (previous) |edge| {
            if ((try view.edge(edge)).head == @backingInt(node))
                return .{ .edge = edge, .percent_along = 1, .heading = direction.heading };
        }
        if (following) |edge| {
            if ((try view.edge(try view.oppEdge(edge))).head == @backingInt(node))
                return .{ .edge = edge, .percent_along = 0, .heading = direction.heading };
        }
    }
    return null;
}

const Projection = struct {
    point: geo.PointLL,
    squared: f64,
    fraction: f32,
};

fn project(arena: *memory.Arena, view: *const View, edge: EdgeId, point: geo.PointLL, control: core.Control) !Projection {
    const mark = arena.mark();
    defer arena.rewind(mark);
    const shape = try view.shapeWithDeadline(edge, arena.allocator(), control.deadline);
    if (shape.len < 2) return error.InvalidEdgeShape;
    const approx = geo.DistanceApproximator.init(point);
    var best: Projection = .{ .point = shape[0].toPoint(), .squared = std.math.inf(f64), .fraction = 0 };
    var length: f64 = 0;
    var along: f64 = 0;
    for (shape[0 .. shape.len - 1], shape[1..], 0..) |first, last, i| {
        if (i % 256 == 0) try control.check();
        const from = first.toPoint();
        const to = last.toPoint();
        const snapped = point.projectScaled(from, to, approx.lng_scale);
        const squared = approx.distanceSquared(snapped);
        if (squared < best.squared) {
            best.point = snapped;
            best.squared = squared;
            along = length + from.distance(snapped);
        }
        length += from.distance(to);
    }
    best.fraction = if (length == 0) 0 else @floatCast(@min(along / length, 1));
    return best;
}

const Cut = struct { segment: usize, fraction: f32, match_index: u32 };

fn appendPair(arena: *memory.Arena, view: *const View, trace: []const Measurement, matches: []Match, pair: []Segment, output: *std.ArrayList(Segment), left: u32, right: u32, observations: Emission, movements: Transition, control: core.Control) !void {
    var first: Cut = .{ .segment = 0, .fraction = pair[0].path.begin, .match_index = left };
    var cursor = first;
    var prior_point = matches[left].point;
    for (left + 1..right) |i| {
        try control.check();
        const measured = trace[i].point;
        const approx = geo.DistanceApproximator.init(measured);
        const observed: f32 = @floatCast(trace[left].point.distance(measured));
        var best_cost: f32 = std.math.inf(f32);
        var best: Projection = undefined;
        var selected: usize = cursor.segment;
        var metres: f32 = 0;
        for (pair[cursor.segment..], cursor.segment..) |segment, index| {
            try control.check();
            var projection = try project(arena, view, segment.path.edge, measured, control);
            if (index == cursor.segment and projection.fraction < cursor.fraction) {
                projection = .{ .point = prior_point, .squared = approx.distanceSquared(prior_point), .fraction = cursor.fraction };
            }
            if (index + 1 == pair.len and projection.fraction > segment.path.end) {
                projection = .{ .point = matches[right].point, .squared = approx.distanceSquared(matches[right].point), .fraction = segment.path.end };
            }
            const length: f32 = @floatFromInt((try view.edge(segment.path.edge)).geom.len_m);
            const cost = observations.cost(projection.squared) + movements.cost(0, metres + length * @abs(projection.fraction - segment.path.begin), observed);
            if (cost < best_cost) {
                best_cost = cost;
                best = projection;
                selected = index;
            }
            metres += (segment.path.end - segment.path.begin) * length;
        }
        if (!std.math.isFinite(best_cost)) continue;
        const match = &matches[i];
        match.point = best.point;
        match.edge = pair[selected].path.edge;
        match.fraction = best.fraction;
        match.distance = @floatCast(@sqrt(best.squared));
        match.kind = .interpolated;
        prior_point = best.point;
        cursor = .{ .segment = selected, .fraction = best.fraction, .match_index = @intCast(i) };
        if (match.break_point) {
            try appendInterval(arena.allocator(), matches, pair, output, first, cursor, control);
            first = cursor;
        } else {
            if (pair[selected].first_match == null) pair[selected].first_match = @intCast(i);
            pair[selected].last_match = @intCast(i);
        }
    }
    try appendInterval(arena.allocator(), matches, pair, output, first, .{ .segment = pair.len - 1, .fraction = pair[pair.len - 1].path.end, .match_index = right }, control);
}

fn appendInterval(a: Allocator, matches: []const Match, segments: []const Segment, output: *std.ArrayList(Segment), from: Cut, to: Cut, control: core.Control) !void {
    for (segments[from.segment .. to.segment + 1], from.segment..) |original, index| {
        if (index % 256 == 0) try control.check();
        var segment = original;
        if (index == from.segment) {
            segment.path.begin = from.fraction;
            segment.first_match = from.match_index;
        }
        if (index == to.segment) {
            segment.path.end = to.fraction;
            segment.last_match = to.match_index;
        }
        if (output.items.len != 0 and (index != from.segment or !matches[from.match_index].break_point)) {
            const previous = &output.items[output.items.len - 1];
            if (!previous.discontinuity and previous.path.edge == segment.path.edge and previous.path.end == segment.path.begin) {
                previous.path.end = segment.path.end;
                previous.first_match = previous.first_match orelse segment.first_match;
                previous.last_match = segment.last_match orelse previous.last_match;
                continue;
            }
        }
        try output.append(a, segment);
    }
}

/// Build the same recost steps used by ordinary route legs.
fn formPaths(a: Allocator, view: *const View, kernel: anytype, matches: []const Match, segments: []const Segment, options: Options, exact_walk: bool, control: core.Control) ![]const Leg {
    if (segments.len == 0) return &.{};
    var use_timestamps = options.use_timestamps;
    for (segments, 0..) |segment, i| {
        if (i % 256 == 0) try control.check();
        if (segment.discontinuity and i + 1 < segments.len) {
            use_timestamps = false;
            break;
        }
    }
    var initial_timing = options.timing;
    if (!initial_timing.start.valid) if (options.start_clock) |clock| {
        const first = try view.edge(segments[0].path.edge);
        const node: graph.format.NodeId = @fromBackingInt(first.head);
        if (clock.date) |date| {
            initial_timing.start = try graph.time_info.TimeInfo.fromNode(view, node, date, clock.now, control.deadline);
        } else if (clock.timestamp >= 0 and clock.timestamp < 253_402_300_800) {
            initial_timing.start = try graph.time_info.TimeInfo.fromUnix(view, node, @intFromFloat(clock.timestamp), clock.now);
        }
    };
    const edges = try a.alloc(endpoints.Segment, segments.len);
    const steps = try a.alloc(route_legs.Recost.Step, segments.len);
    var legs: std.ArrayList(Leg) = .empty;
    var first: usize = 0;
    var elapsed: f32 = 0;
    while (first < segments.len) {
        try control.check();
        var end = first + 1;
        while (end < segments.len and !segments[end - 1].discontinuity) : (end += 1) {
            if (end % 256 == 0) try control.check();
            if (segments[end].first_match) |index| {
                if (matches[index].break_point) break;
            }
        }
        const start_match = segments[first].first_match orelse return error.InvalidTracePath;
        const end_match = segments[end - 1].last_match orelse return error.InvalidTracePath;
        var timestamp_index = start_match;
        const epoch = matches[start_match].epoch_time;
        var recost: route_legs.Recost = .{};
        var timing = initial_timing;
        if (elapsed > 0 and timing.start.valid) {
            const start_node: graph.format.NodeId = @fromBackingInt((try view.edge(try view.oppEdge(segments[first].path.edge))).head);
            timing.start = try timing.at(view, start_node, elapsed, .forward);
        }
        for (segments[first..end], edges[first..end], steps[first..end], first..) |segment, *edge, *step, i| {
            try control.check();
            edge.* = segment.path;
            step.* = try recost.addForward(view, kernel, edge.*, i + 1 == end, .{ .timing = timing, .control = control });
            if (!use_timestamps or (options.require_timestamps and epoch < 0)) continue;
            if (exact_walk) {
                timestamp_index = segment.shape_end orelse return error.InvalidTracePath;
            } else if (segment.last_match) |index| timestamp_index = index;
            const timestamp = matches[timestamp_index].epoch_time;
            if (options.require_timestamps and timestamp < 0) continue;
            step.elapsed.secs = @floatCast(timestamp - epoch);
            recost.elapsed.secs = step.elapsed.secs;
            recost.previous.secs = step.elapsed.secs;
        }
        elapsed += steps[end - 1].elapsed.secs;
        try legs.append(a, .{
            .segments = edges[first..end],
            .steps = steps[first..end],
            .first_match = start_match,
            .last_match = end_match,
        });
        first = end;
    }
    return legs.items;
}
