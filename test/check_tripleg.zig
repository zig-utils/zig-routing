//! Read a /route corpus and dump the typed trip legs for oracle comparison.
const std = @import("std");
const routing = @import("routing");
const request = routing.api.request;
const io = routing.infra.io;
const search = routing.search;
const trip = routing.api.trip;
const auto = routing.costing.auto;
const Auto = @import("auto_search_kernel.zig").Auto;
const Engine = search.search.Search(Auto, search.queue.Heap);
const Snap = routing.snap.candidates;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const bundle_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const count = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else std.math.maxInt(usize);
    const with_maneuvers = if (args.next()) |option|
        if (std.mem.eql(u8, option, "--maneuvers")) true else return error.InvalidOption
    else
        false;
    if (args.next() != null) return error.TooManyArguments;

    var bundle = try routing.graph.reader.Bundle.open(bundle_path);
    defer bundle.close();
    const view = &bundle.view;
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();
    var arena = routing.infra.arena.Arena.init(init.gpa, .{});
    defer arena.deinit();
    var engine = try Engine.init(init.gpa, view);
    defer engine.deinit();
    var cache = try auto.Cache.init(init.gpa, view.classes orelse return error.MissingClasses, 1);
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
        const legs = check(&engine, view, &arena, &cache, line[tab + 1 ..]) catch |err| {
            try std.json.Stringify.value(.{ .index = index, .failure = @errorName(err) }, .{}, writer);
            try writer.writeByte('\n');
            continue;
        };
        if (with_maneuvers) {
            const a = arena.allocator();
            const values = try a.alloc(ManeuverResult, legs.len);
            for (legs, values) |*leg, *result| {
                const maneuvers = routing.narrative.maneuvers.build(a, leg, io.Deadline.fromNowMs(10_000));
                result.* = if (maneuvers) |steps| .{ .steps = steps } else |err| .{ .failure = @errorName(err) };
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

fn check(engine: *Engine, view: *const routing.graph.reader.View, arena: *routing.infra.arena.Arena, cache: *auto.Cache, request_json: []const u8) ![]const trip.TripLeg {
    const a = arena.allocator();
    const deadline = io.Deadline.fromNowMs(10_000);
    const control: search.search.Control = .{ .deadline = deadline };
    const parsed = try request.parseHttpWithin(a, "/route", &.{}, request_json, false, deadline);
    const opts = switch (parsed) {
        .ok => |options| options,
        .failure => return error.InvalidRequest,
    };
    if (opts.costing != .auto or opts.date_time_type != .no_time) return error.UnsupportedProfile;
    const auto_options = if (opts.costing_options) |root| routing.api.json.pointer(root, "/auto") orelse .null else .null;
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const options = try auto.parse(a, .auto, auto_options, &warnings, deadline);
    var lease = try cache.acquire(options, deadline);
    defer lease.release();
    const kernel: Auto = .{ .profile = lease.profile(), .tables = lease.tables(), .arena = a };
    const correlated = try a.alloc(Snap.PathLocation, opts.locations.len);
    const access: Snap.Access = .{ .mask = lease.profile().permission.access_mask };
    for (opts.locations, correlated) |location, *out| {
        try control.check();
        out.* = try Snap.search(view, a, location, .{}, access, deadline);
    }
    const path = try search.multi.route(engine, arena, kernel, opts.locations, correlated, .{ .search = .{ .costing = .auto } }, control);
    const geometry = try search.legs.build(a, view, kernel, path, correlated, control);
    const attrs = try opts.tripAttributes(true, deadline);
    const output = try a.alloc(trip.TripLeg, path.legs.len);
    for (path.legs, geometry.legs, output, 0..) |leg, *shape, *out, i| {
        try control.check();
        out.* = try search.tripleg.build(a, view, .{
            .segments = leg.segments,
            .geometry = shape,
            .attributes = attrs,
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
    return output;
}
