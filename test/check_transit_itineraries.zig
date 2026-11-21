//! Replay Valhalla-correlated locations and reprice its fixed path.
const std = @import("std");
const routing = @import("routing");
const graph = routing.graph;
const search = routing.search;
const costing = routing.costing;
const Snap = routing.snap.candidates;
const api = routing.api;
const io = routing.infra.io;
const Route = api.route_action.ScheduledRoute;
const Segment = search.endpoints.Segment;
const ReplayStep = search.multimodal.ReplayStep;
const Cost = costing.compiled.Cost;
const EdgeId = graph.format.EdgeId;
const Allocator = std.mem.Allocator;
const Control = search.search.Control;

const Cut = struct {
    edge: u32,
    fraction: f32,
    distance: f64,
    lng: f64,
    lat: f64,
    begin: bool,
    end: bool,
};

const Location = struct {
    edges: []const Cut,
    filtered: []const Cut,
    rank: bool,

    fn correlation(self: Location, a: Allocator) !Snap.PathLocation {
        return .{ .edges = try edgesFor(a, self.edges), .filtered_edges = try edgesFor(a, self.filtered), .rank_candidates = self.rank };
    }

    fn edgesFor(a: Allocator, input: []const Cut) ![]const Snap.PathEdge {
        const edges = try a.alloc(Snap.PathEdge, input.len);
        for (edges, input) |*out, cut| {
            out.* = .{
                .id = @fromBackingInt(cut.edge),
                .projected = .{ .lng = cut.lng, .lat = cut.lat },
                .distance = cut.distance,
                .percent_along = cut.fraction,
                .node = if (cut.begin) .begin else if (cut.end) .end else .none,
                .heading = 0,
            };
        }
        return edges;
    }
};

const InputStep = struct {
    edge: ?u32 = null,
    line: ?u32 = null,
    trip: ?u32 = null,
    board_minute: ?i64 = null,
};

const Reference = struct {
    index: usize,
    cuts: ?[2]Location = null,
    steps: ?[]const InputStep = null,
    error_code: ?u32 = null,
    offers: ?[]const Offer = null,
};

const Offer = struct { trip: u32, start: u32, duration: u32, cost: f32 };

const OutputStep = struct {
    edge: ?u32 = null,
    begin: ?f32 = null,
    end: ?f32 = null,
    line: ?u32 = null,
    trip: ?u32 = null,
    route: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    board: ?[]const u8 = null,
    elapsed: f32,
    cost: f32,
};

const Recost = struct {
    cost: ?f32 = null,
    elapsed: ?f32 = null,
    blocked_at: ?usize = null,
    failure: ?[]const u8 = null,
};

const Output = struct {
    index: usize,
    error_code: ?u32 = null,
    failure: ?[]const u8 = null,
    steps: ?[]const OutputStep = null,
    cost: ?f32 = null,
    elapsed: ?f32 = null,
    oracle_recost: ?Recost = null,
    native_recost: ?Recost = null,
    offers: ?[]const Offer = null,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const bundle_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const reference_path = args.next() orelse return error.MissingReference;
    if (args.next() != null) return error.InvalidArguments;
    var bundle = try graph.reader.Bundle.open(bundle_path);
    defer bundle.close();
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();
    const reference = try io.Mapping.mapFile(reference_path, .read_only);
    defer reference.unmap();
    var arena = routing.infra.arena.Arena.init(init.gpa, .{});
    defer arena.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    const writer = &stdout.interface;

    var requests = std.mem.tokenizeScalar(u8, corpus.bytes, '\n');
    var rows = std.mem.tokenizeScalar(u8, reference.bytes, '\n');
    var index: usize = 0;
    while (requests.next()) |row| : (index += 1) {
        if (!std.mem.startsWith(u8, row, "/route\t")) return error.InvalidCorpusRow;
        arena.reset();
        const a = arena.allocator();
        const input = try std.json.parseFromSliceLeaky(Reference, a, rows.next() orelse return error.ShortReference, .{ .ignore_unknown_fields = true });
        if (input.index != index) return error.InvalidReferenceIndex;
        const result = check(&bundle.view, &arena, row[7..], input) catch |err| Output{ .index = index, .failure = @errorName(err) };
        try std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, writer);
        try writer.writeByte('\n');
        try writer.flush();
    }
    if (rows.next() != null) return error.LongReference;
}

fn check(view: *const graph.reader.View, arena: *routing.infra.arena.Arena, body: []const u8, input: Reference) !Output {
    const a = arena.allocator();
    const control: Control = .{ .deadline = io.Deadline.fromNowMs(20_000) };
    const parsed = try api.request.parseHttpWithin(a, "/route", &.{}, body, false, control.deadline);
    var result: Output = .{ .index = input.index };
    if (parsed == .failure) {
        result.error_code = parsed.failure.code;
        return result;
    }
    const locations = input.cuts orelse {
        result.failure = "MissingOracleCuts";
        return result;
    };
    const correlated = [2]Snap.PathLocation{ try locations[0].correlation(a), try locations[1].correlation(a) };
    const options = &parsed.ok;
    const routed = api.route_action.routeWithCorrelations(view, arena, options, &correlated, control);
    var emitted: ?Route = null;
    if (routed) |route| switch (route) {
        .failure => |failure| {
            result.error_code = failure.code;
        },
        .scheduled => |success| {
            if (success.paths.len != 1) return error.ExpectedOneLeg;
            const path = success.paths[0];
            result.cost = path.total.cost;
            result.elapsed = path.total.secs;
            result.steps = try describe(a, view, path, control);
            emitted = success;
        },
    } else |err| {
        result.failure = @errorName(err);
    }

    const replay_control: Control = .{ .deadline = io.Deadline.fromNowMs(20_000) };
    reprice(a, view, options, correlated, input, emitted, &result, replay_control) catch |err| {
        result.oracle_recost = .{ .failure = @errorName(err) };
    };
    return result;
}

fn describe(a: Allocator, view: *const graph.reader.View, path: search.multimodal.Path, control: Control) ![]const OutputStep {
    const table = view.transit_index orelse return error.MissingTransitSection;
    const output = try a.alloc(OutputStep, path.steps.len);
    const rules = if (view.tz_rules) |*present| present else null;
    for (path.steps, output) |step, *item| {
        try control.check();
        item.* = .{ .elapsed = step.elapsed.secs, .cost = step.elapsed.cost };
        switch (step.movement) {
            .walk => |walk| {
                item.edge = @backingInt(walk.edge);
                item.begin = walk.begin;
                item.end = walk.end;
            },
            .ride => |ride| {
                const line = table.lines[ride.departure.line];
                const from = table.stops[line.origin].place;
                const to = table.stops[line.destination].place;
                item.line = ride.departure.line;
                item.trip = ride.departure.trip;
                item.route = try table.text(table.routes[line.route].one_stop_id);
                item.origin = try table.text(from.one_stop_id);
                item.destination = try table.text(to.one_stop_id);
                const zone = try view.nodeTimezone(@fromBackingInt(from.graph_node));
                const time: graph.time_info.TimeInfo = .{ .valid = true, .zone = zone, .unix_time = ride.departure_time };
                const buffer = try a.alloc(u8, 22);
                if (try time.display(rules, buffer)) |display| {
                    item.board = buffer[0 .. display.date_time.len + display.time_zone_offset.len];
                }
            },
        }
    }
    return output;
}

fn reprice(a: Allocator, view: *const graph.reader.View, options: *const api.request.Options, locations: [2]Snap.PathLocation, oracle: Reference, native: ?Route, result: *Output, control: Control) !void {
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    const profiles = try costing.multimodal.parse(a, options.costing_options orelse .null, &warnings, control.deadline);
    const kernel = try costing.multimodal.Kernel.init(a, view, profiles, control.deadline);
    const engine = try search.multimodal.Search.init(a, view, &kernel, control);
    const origin = try search.endpoints.rank(a, locations[0], options.costing, control);
    const destination = try search.endpoints.rank(a, locations[1], options.costing, control);
    const timing = try search.multi.startTiming(view, origin.all[0].edge, options.date_time_type, options.locations[0].date_time, io.wallSeconds(), control);
    const exclusions = try routing.snap.exclusions.resolve(view, a, options, &.{}, .{}, &kernel.walking, control.deadline);
    const query: search.endpoints.Options = .{ .costing = options.costing, .timing = timing, .excluded = exclusions };
    if (oracle.steps) |path| {
        const steps = try a.alloc(ReplayStep, path.len);
        if (steps.len == 0) return error.EmptyOraclePath;
        const from = try candidate(origin, @fromBackingInt(path[0].edge orelse return error.InvalidOracleEndpoint), null);
        const to = try candidate(destination, @fromBackingInt(path[path.len - 1].edge orelse return error.InvalidOracleEndpoint), null);
        for (path, steps, 0..) |item, *step, i| {
            try control.check();
            step.* = if (item.edge) |edge| .{ .walk = .{
                .edge = @fromBackingInt(edge),
                .begin = if (i == 0) from.fraction else 0,
                .end = if (i + 1 == steps.len) to.fraction else 1,
            } } else .{ .ride = .{
                .line = item.line orelse return error.InvalidOracleRide,
                .trip = item.trip orelse return error.InvalidOracleRide,
                .board_minute = item.board_minute orelse return error.InvalidOracleRide,
            } };
        }
        result.oracle_recost = price(&engine, a, from, to, steps, query, control);
    }
    if (native) |route| {
        const path = route.paths[0];
        const steps = try a.alloc(ReplayStep, path.steps.len);
        for (path.steps, steps) |item, *step| {
            try control.check();
            step.* = switch (item.movement) {
                .walk => |walk| .{ .walk = walk },
                .ride => |ride| .{ .ride = .{
                    .line = ride.departure.line,
                    .trip = ride.departure.trip,
                    .board_minute = @divFloor(ride.departure_time, 60),
                } },
            };
        }
        const first = steps[0].walk;
        const last = steps[steps.len - 1].walk;
        const from = try candidate(origin, first.edge, first.begin);
        const to = try candidate(destination, last.edge, last.end);
        result.native_recost = price(&engine, a, from, to, steps, query, control);
        if (oracle.offers != null) result.offers = try fixtureOffers(&engine, a, from, to, steps, path, query, control);
    }
}

fn fixtureOffers(engine: *const search.multimodal.Search, a: Allocator, from: search.endpoints.Candidate, to: search.endpoints.Candidate, steps: []ReplayStep, path: search.multimodal.Path, query: search.endpoints.Options, control: Control) ![]const Offer {
    const table = engine.view.transit_index orelse return error.MissingTransitSection;
    const rules = engine.view.tz_rules orelse return error.MissingTimezones;
    var position: ?usize = null;
    for (path.steps, 0..) |step, i| {
        try control.check();
        if (step.movement != .ride) continue;
        if (position != null) return error.ExpectedOneFixtureRide;
        position = i;
    }
    const i = position orelse return error.ExpectedOneFixtureRide;
    const ride = path.steps[i].movement.ride;
    const line = ride.departure.line;
    const stop = table.stops[table.lines[line].origin].place;
    const zone = try engine.view.nodeTimezone(@fromBackingInt(stop.graph_node));
    const offset = (try rules.offsetAt(zone, ride.ready_time) orelse return error.MissingTimezones).seconds;
    const now = ride.ready_time + offset;
    const midnight = @divFloor(now, 86400) * 86400;
    const day: i32 = @intCast(@divFloor(now, 86400));
    const weekday: graph.transit.Weekday = @fromBackingInt(@as(u3, @intCast(@mod(day + 4, 7))));
    var iterator = try table.departureIterator(line, @intCast(now - midnight));
    var offers: std.ArrayList(Offer) = .empty;
    while (try iterator.next()) |offer| {
        try control.check();
        if (offer.departure.flags.kind != .fixed) return error.ExpectedFixedFixtureDeparture;
        if (!try table.scheduleActive(offer.departure.schedule, day, weekday) or
            !try engine.kernel.allowsDeparture(engine.view, offer.departure)) continue;
        const instant = try rules.toUtc(zone, midnight + offer.time, control.deadline) orelse return error.InvalidFixtureDepartureTime;
        steps[i] = .{ .ride = .{ .line = line, .trip = offer.departure.trip, .board_minute = @divFloor(instant, 60) } };
        const cost = price(engine, a, from, to, steps, query, control);
        try offers.append(a, .{ .trip = offer.departure.trip, .start = offer.time, .duration = offer.departure.elapsed_time, .cost = cost.cost orelse return error.BlockedFixtureDeparture });
    }
    return offers.items;
}

fn candidate(ranked: search.endpoints.Ranked, edge: EdgeId, fraction: ?f32) !search.endpoints.Candidate {
    var best: ?search.endpoints.Candidate = null;
    for (ranked.all) |item| {
        if (item.edge != edge) continue;
        if (fraction) |point| if (item.fraction != point) continue;
        if (best == null or item.score < best.?.score) best = item;
    }
    return best orelse error.MissingPathCut;
}

fn price(engine: *const search.multimodal.Search, a: Allocator, from: search.endpoints.Candidate, to: search.endpoints.Candidate, steps: []const ReplayStep, query: search.endpoints.Options, control: Control) Recost {
    const result = engine.reprice(a, from, to, steps, query, control) catch |err| return .{ .failure = @errorName(err) };
    return switch (result) {
        .cost => |value| .{ .cost = value.cost, .elapsed = value.secs },
        .blocked_at => |step| .{ .blocked_at = step },
    };
}
