//! Read a /route corpus and dump the typed trip legs for oracle comparison.
const std = @import("std");
const routing = @import("routing");
const request = routing.api.request;
const io = routing.infra.io;
const search = routing.search;
const trip = routing.api.trip;
const auto = routing.costing.auto;
const pedestrian = routing.costing.pedestrian;
const Auto = @import("auto_search_kernel.zig").Auto;
const Foot = @import("pedestrian_search_kernel.zig").Foot;
const Snap = routing.snap.candidates;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const bundle_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const count = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else std.math.maxInt(usize);
    var narrative: Narrative = .none;
    var on_foot = false;
    var multimodal = false;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--maneuvers") and narrative == .none) {
            narrative = .maneuvers;
        } else if (std.mem.eql(u8, option, "--instructions") and narrative == .none) {
            narrative = .instructions;
        } else if (std.mem.eql(u8, option, "--verbal-instructions") and narrative == .none) {
            narrative = .verbal_instructions;
        } else if (std.mem.eql(u8, option, "--pedestrian") and !on_foot) {
            on_foot = true;
        } else if (std.mem.eql(u8, option, "--multimodal") and !multimodal) {
            multimodal = true;
        } else return error.InvalidOption;
    }
    if (multimodal) {
        if (on_foot or narrative != .none) return error.InvalidOption;
        return runScheduled(init, bundle_path, corpus_path, count);
    }
    if (on_foot) return run(.pedestrian, init, bundle_path, corpus_path, count, narrative);
    return run(.auto, init, bundle_path, corpus_path, count, narrative);
}

fn runScheduled(init: std.process.Init, bundle_path: []const u8, corpus_path: []const u8, count: usize) !void {
    var bundle = try routing.graph.reader.Bundle.open(bundle_path);
    defer bundle.close();
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();
    var arena = routing.infra.arena.Arena.init(init.gpa, .{});
    defer arena.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    const writer = &stdout.interface;
    var lines = std.mem.tokenizeScalar(u8, corpus.bytes, '\n');
    for (0..count) |index| {
        const line = lines.next() orelse break;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidCorpusRow;
        if (!std.mem.eql(u8, line[0..tab], "/route")) return error.InvalidCorpusRow;
        arena.reset();
        const a = arena.allocator();
        const control: search.search.Control = .{ .deadline = io.Deadline.fromNowMs(10_000) };
        const parsed = try request.parseHttpWithin(a, "/route", &.{}, line[tab + 1 ..], false, control.deadline);
        const result = switch (parsed) {
            .ok => |*options| routing.api.route_action.route(&bundle.view, &arena, options, null, control) catch |err| {
                try std.json.Stringify.value(.{ .index = index, .failure = @errorName(err) }, .{}, writer);
                try writer.writeByte('\n');
                try writer.flush();
                continue;
            },
            .failure => |failure| routing.api.route_action.Result{ .failure = failure },
        };
        switch (result) {
            .failure => |failure| try std.json.Stringify.value(.{ .index = index, .error_code = failure.code }, .{}, writer),
            .scheduled => |route| {
                const trip_legs = route.trip(a, &bundle.view, &parsed.ok, control) catch |err| {
                    try std.json.Stringify.value(.{ .index = index, .failure = @errorName(err) }, .{}, writer);
                    try writer.writeByte('\n');
                    try writer.flush();
                    continue;
                };
                const table = bundle.view.transit_index orelse return error.MissingTransitSection;
                const Segment = struct { route: ?[]const u8, origin: ?[]const u8, destination: ?[]const u8, departure: i64, arrival: i64, trip: u32 };
                var rides: std.ArrayList(Segment) = .empty;
                for (route.paths) |path| for (path.steps) |step| switch (step.movement) {
                    .walk => {},
                    .ride => |ride| {
                        const transit_line = table.lines[ride.departure.line];
                        try rides.append(a, .{
                            .route = try table.text(table.routes[transit_line.route].one_stop_id),
                            .origin = try table.text(table.stops[transit_line.origin].place.one_stop_id),
                            .destination = try table.text(table.stops[transit_line.destination].place.one_stop_id),
                            .departure = ride.departure_time,
                            .arrival = ride.arrival_time,
                            .trip = ride.departure.trip,
                        });
                    },
                };
                try std.json.Stringify.value(.{ .index = index, .rides = rides.items, .elapsed = route.waypoints[route.waypoints.len - 1].elapsed_secs, .legs = trip_legs }, .{ .emit_null_optional_fields = false }, writer);
            },
        }
        try writer.writeByte('\n');
        try writer.flush();
    }
}

const Narrative = enum { none, maneuvers, instructions, verbal_instructions };

fn run(comptime mode: request.Costing, init: std.process.Init, bundle_path: []const u8, corpus_path: []const u8, count: usize, narrative: Narrative) !void {
    const Kernel = if (mode == .pedestrian) Foot else Auto;
    const Engine = search.search.Search(Kernel, search.queue.Heap);
    const Cache = if (mode == .pedestrian) pedestrian.Cache else auto.Cache;
    var bundle = try routing.graph.reader.Bundle.open(bundle_path);
    defer bundle.close();
    const view = &bundle.view;
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();
    var arena = routing.infra.arena.Arena.init(init.gpa, .{});
    defer arena.deinit();
    var engine = try Engine.init(init.gpa, view);
    defer engine.deinit();
    var cache = try Cache.init(init.gpa, view.classes orelse return error.MissingClasses, 1);
    defer cache.deinit();
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    const writer = &stdout.interface;

    var lines = std.mem.tokenizeScalar(u8, corpus.bytes, '\n');
    for (0..count) |index| {
        const line = lines.next() orelse break;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidCorpusRow;
        if (!std.mem.eql(u8, line[0..tab], "/route")) return error.InvalidCorpusRow;
        arena.reset();
        const checked = check(mode, &engine, view, &arena, &cache, line[tab + 1 ..]) catch |err| {
            try std.json.Stringify.value(.{ .index = index, .failure = @errorName(err) }, .{}, writer);
            try writer.writeByte('\n');
            continue;
        };
        const legs = checked.legs;
        if (narrative != .none) {
            const a = arena.allocator();
            const values = try a.alloc(ManeuverResult, legs.len);
            for (legs, values) |*leg, *result| {
                const deadline = io.Deadline.fromNowMs(10_000);
                const built_leg = switch (narrative) {
                    .none => unreachable,
                    .maneuvers => routing.narrative.maneuvers.buildAnnotated(a, leg, .{ .roundabout_exits = checked.narrative.roundabout_exits }, deadline),
                    .instructions => routing.narrative.instructions.build(a, leg, .{
                        .roundabout_exits = checked.narrative.roundabout_exits,
                        .language = checked.narrative.language,
                    }, deadline),
                    .verbal_instructions => routing.narrative.verbal_instructions.build(a, leg, checked.narrative, deadline),
                };
                if (built_leg) |built| {
                    leg.* = built.trip_leg;
                    result.* = .{ .steps = built.maneuvers };
                } else |err| {
                    result.* = .{ .failure = @errorName(err) };
                }
            }
            try std.json.Stringify.value(.{ .index = index, .legs = legs, .maneuvers = values }, .{ .emit_null_optional_fields = false }, writer);
        } else {
            try std.json.Stringify.value(.{ .index = index, .legs = legs }, .{ .emit_null_optional_fields = false }, writer);
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}

const ManeuverResult = struct {
    steps: ?[]const routing.narrative.maneuver.Maneuver = null,
    failure: ?[]const u8 = null,
};

const Checked = struct {
    legs: []trip.TripLeg,
    narrative: routing.narrative.verbal_instructions.Options,
};

fn check(comptime mode: request.Costing, engine: anytype, view: *const routing.graph.reader.View, arena: *routing.infra.arena.Arena, cache: anytype, request_json: []const u8) !Checked {
    const a = arena.allocator();
    const deadline = io.Deadline.fromNowMs(10_000);
    const control: search.search.Control = .{ .deadline = deadline };
    const parsed = try request.parseHttpWithin(a, "/route", &.{}, request_json, false, deadline);
    const opts = switch (parsed) {
        .ok => |options| options,
        .failure => return error.InvalidRequest,
    };
    if (opts.costing != mode or opts.date_time_type != .no_time) return error.UnsupportedProfile;
    const options_key = if (mode == .pedestrian) "/pedestrian" else "/auto";
    const model_options = if (opts.costing_options) |root| routing.api.json.pointer(root, options_key) orelse .null else .null;
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const options = if (mode == .pedestrian)
        try pedestrian.parse(a, model_options, &warnings, deadline)
    else
        try auto.parse(a, .auto, model_options, &warnings, deadline);
    var lease = try cache.acquire(options, deadline);
    defer lease.release();
    const kernel = if (mode == .pedestrian)
        Foot{ .profile = lease.profile(), .tables = lease.tables() }
    else
        Auto{ .profile = lease.profile(), .tables = lease.tables(), .arena = a };
    const correlated = try a.alloc(Snap.PathLocation, opts.locations.len);
    const access: Snap.Access = .{ .mask = lease.profile().permission.access_mask };
    for (opts.locations, correlated) |location, *out| {
        try control.check();
        out.* = try Snap.search(view, a, location, .{}, access, deadline);
    }
    const path = try search.multi.route(engine, arena, kernel, opts.locations, correlated, .{ .search = .{ .costing = mode } }, control);
    const geometry = try search.legs.build(a, view, kernel, path, correlated, control);
    const attrs = try opts.tripAttributes(true, deadline);
    const output = try a.alloc(trip.TripLeg, path.legs.len);
    for (path.legs, geometry.legs, output, 0..) |leg, *shape, *out, i| {
        try control.check();
        out.* = try search.tripleg.build(a, view, .{
            .segments = leg.segments,
            .geometry = shape,
            .attributes = attrs,
            .travel = if (mode == .pedestrian)
                .{ .pedestrian = @fromBackingInt(@backingInt(options.transport)) }
            else
                .{ .drive = .kCar },
            .locations = .{
                .requested = opts.locations,
                .correlations = correlated,
                .waypoints = path.waypoints,
                .segment_contexts = leg.segment_contexts,
            },
            .leg_id = @intCast(i),
            .leg_count = @intCast(output.len),
        }, control);
    }
    return .{ .legs = output, .narrative = .{
        .roundabout_exits = opts.roundabout_exits,
        .language = opts.language,
        .units = opts.units,
    } };
}
