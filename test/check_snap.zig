const std = @import("std");
const routing = @import("routing");
const request = routing.api.request;
const io = routing.infra.io;
const Bundle = routing.graph.reader.Bundle;
const snap = routing.snap.candidates;
const json_util = routing.api.json;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const bundle_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const count = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else std.math.maxInt(usize);
    const default_reach = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 0;
    if (args.next() != null) return error.TooManyArguments;
    var bundle = try Bundle.open(bundle_path);
    defer bundle.close();
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var stdout_buf: [16_384]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &stdout_buf);
    const writer = &stdout.interface;
    var lines = std.mem.tokenizeScalar(u8, corpus.bytes, '\n');
    for (0..count) |_| {
        const line = lines.next() orelse break;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.InvalidCorpusRow;
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();
        const parsed = try request.parseHttp(allocator, line[0..tab], &.{}, line[tab + 1 ..]);
        const options = switch (parsed) {
            .ok => |options| options,
            .failure => return error.InvalidRequest,
        };
        const access: snap.Access = .{ .mask = switch (options.costing) {
            .pedestrian => .{ .pedestrian = true },
            .bicycle => .{ .bicycle = true },
            .auto => .{ .auto = true },
            .none => routing.graph.constants.AccessMask.all_tag_modes,
            else => return error.UnsupportedCosting,
        } };
        const hiking_difficulty = if (options.costing_options) |costing_options|
            json_util.getOptional(u32, costing_options, "/pedestrian/max_hiking_difficulty")
        else
            null;
        const costing: Costing = .{
            .access = access,
            .max_hiking_difficulty = if (options.costing == .pedestrian) @intCast(@min(hiking_difficulty orelse 1, 6)) else null,
        };
        for (options.locations) |input| {
            var location = input;
            location.minimum_reachability = input.minimum_reachability orelse default_reach;
            const timer = io.Timer.start();
            const result = try snap.search(&bundle.view, allocator, location, .{}, costing, .none);
            const ns = timer.read();
            var json: std.json.Stringify = .{ .writer = writer };
            try json.beginObject();
            try json.objectField("ns");
            try json.write(ns);
            try json.objectField("edges");
            try writeEdges(&json, &bundle, allocator, result.edges);
            try json.objectField("filtered_edges");
            try writeEdges(&json, &bundle, allocator, result.filtered_edges);
            try json.endObject();
            try writer.writeByte('\n');
        }
    }
    try writer.flush();
}

// Use the pedestrian and bicycle predicates relevant to the fixture profiles.
const Costing = struct {
    access: snap.Access,
    max_hiking_difficulty: ?u3,

    pub fn allowed(self: Costing, edge: snap.DirectedEdge) bool {
        const category = edge.class.category;
        if (!self.access.allowed(edge) or category.use == @backingInt(routing.graph.constants.Use.construction)) return false;
        if (self.max_hiking_difficulty) |difficulty| {
            return category.sac_scale <= difficulty and category.use < @backingInt(routing.graph.constants.Use.rail_ferry) and
                !edge.class.flags.bike_share_connection;
        }
        return !edge.class.flags.bike_share_connection;
    }
};

fn writeEdges(json: *std.json.Stringify, bundle: *const Bundle, allocator: std.mem.Allocator, edges: []const snap.PathEdge) !void {
    try json.beginArray();
    for (edges, 0..) |edge, index| {
        var record = try bundle.view.coldRecord(edge.id);
        const forward = !record.reverse;
        record.reverse = false;
        const shape = if (index == 0) try encodeShape(allocator, record) else null;
        try json.write(.{
            .id = @backingInt(edge.id),
            .way_id = record.wayId(),
            .forward = forward,
            .shape = shape,
            .lat = edge.projected.lat,
            .lon = edge.projected.lng,
            .distance = edge.distance,
            .percent_along = edge.percent_along,
            .heading = edge.heading,
            .inbound_reach = edge.reach.inbound,
            .outbound_reach = edge.reach.outbound,
            .side = @tagName(edge.side),
            .node = @tagName(edge.node),
        });
    }
    try json.endArray();
}

fn encodeShape(allocator: std.mem.Allocator, record: routing.graph.cold.Record) ![]const u8 {
    const fixed = try record.shape(allocator, .none);
    const points = try allocator.alloc(routing.geo.PointLL, fixed.len);
    for (fixed, points) |point, *out| out.* = point.toTilePoint();
    return routing.geo.polyline.encodeAlloc(allocator, .polyline, 6, points);
}
