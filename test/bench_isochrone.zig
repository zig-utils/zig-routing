//! Time the isochrone grid stage with the same inputs as the Valhalla oracle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const memory = routing.infra.arena;
const iso = routing.search.isochrone;
const snap = routing.snap.candidates;
const Candidate = routing.search.endpoints.Candidate;
const View = routing.graph.reader.View;
const Foot = @import("pedestrian_search_kernel.zig").Foot;
const Auto = @import("auto_search_kernel.zig").Auto;
const pedestrian = routing.costing.pedestrian;
const auto = routing.costing.auto;

const Mode = enum { auto, pedestrian };
const Location = struct { lat: f64, lon: f64 };
const Contour = struct { time: ?f32 = null, distance: ?f32 = null };
const Row = struct {
    locations: []const Location,
    contours: []const Contour,
    costing: Mode,
    reverse: bool = false,
};

const Trace = struct {
    a: std.mem.Allocator,
    labels: std.ArrayList(Entry) = .empty,

    const Entry = extern struct {
        index: u32,
        edge: u32,
        previous: u32,
        seconds: f32,
        cost: f32,
        metres: u32,
    };

    pub fn observe(self: *Trace, event: routing.search.expand.Visit) !void {
        try self.labels.append(self.a, .{
            .index = event.index,
            .edge = event.label.edge,
            .previous = event.label.pred,
            .seconds = event.label.secs,
            .cost = event.label.cost,
            .metres = event.label.dist_m,
        });
    }
};

fn measure(
    engine: anytype,
    kernel: anytype,
    request: iso.Request,
    arena: *memory.Arena,
    backing: *memory.CountingAllocator,
    index: usize,
    log: *std.Io.Writer,
    grids: io.File,
    traces: ?io.File,
    scratch: std.mem.Allocator,
) !void {
    arena.reset();
    _ = try engine.run(arena, kernel, request, .{});
    backing.resetCounts();
    arena.reset();
    const start = io.monotonicNs();
    const result = try engine.run(arena, kernel, request, .{});
    const elapsed = io.monotonicNs() - start;
    if (backing.calls() != 0) return error.IsochroneAllocatedAfterWarmup;
    const tiles = result.grid.tiles;
    const bounds = tiles.bounds;
    try log.print("{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        index,               elapsed,     tiles.ncolumns, tiles.nrows, @as(f64, tiles.tilesize),
        bounds.minx,         bounds.miny, bounds.maxx,    bounds.maxy, result.stats.settled,
        result.stats.popped,
    });
    try grids.writeAll(std.mem.sliceAsBytes(result.grid.data));
    if (traces) |file| {
        arena.reset();
        var trace: Trace = .{ .a = scratch };
        _ = try engine.runObserved(arena, kernel, request, &trace, .{});
        const count: u32 = @intCast(trace.labels.items.len);
        try file.writeAll(std.mem.asBytes(&count));
        try file.writeAll(std.mem.sliceAsBytes(trace.labels.items));
    }
}

fn correlate(view: *const View, a: std.mem.Allocator, row: Row) ![]const iso.Origin {
    const access: snap.Access = .{ .mask = switch (row.costing) {
        .auto => .{ .auto = true },
        .pedestrian => .{ .pedestrian = true },
    } };
    const origins = try a.alloc(iso.Origin, row.locations.len);
    for (row.locations, origins) |location, *origin| {
        const path = try snap.search(view, a, .{ .lat = location.lat, .lng = location.lon }, .{}, access, .none);
        const seeds = try a.alloc(Candidate, path.edges.len);
        for (path.edges, seeds) |edge, *seed| {
            seed.* = .{
                .edge = edge.id,
                .fraction = edge.percent_along,
                .score = @floatCast(edge.distance),
                .begin_node = edge.node == .begin,
                .end_node = edge.node == .end,
            };
        }
        origin.* = .{ .location = .init(location.lon, location.lat), .seed = .{ .edges = seeds } };
    }
    return origins;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const graph_path = args.next() orelse return error.MissingBundle;
    const input_path = args.next() orelse return error.MissingCorpus;
    const output_path = args.next() orelse return error.MissingGridOutput;
    const trace_path = args.next();
    if (args.next() != null) return error.InvalidArguments;
    const input = try io.File.open(input_path, .read_only);
    defer input.close();
    const data = try init.arena.allocator().alloc(u8, @intCast(try input.size()));
    try input.preadAll(data, 0);
    const grids = try io.File.open(output_path, .create_truncate);
    defer grids.close();
    const traces = if (trace_path) |path| try io.File.open(path, .create_truncate) else null;
    defer if (traces) |file| file.close();

    var bundle = try routing.graph.reader.Bundle.open(graph_path);
    defer bundle.close();
    const view = &bundle.view;
    var backing = memory.CountingAllocator.init(init.gpa);
    var walker = try iso.Isochrone(Foot).init(backing.allocator(), view);
    defer walker.deinit();
    var motorist = try iso.Isochrone(Auto).init(backing.allocator(), view);
    defer motorist.deinit();
    var walk_cache = try pedestrian.Cache.init(init.gpa, view.classes.?, 1);
    defer walk_cache.deinit();
    var drive_cache = try auto.Cache.init(init.gpa, view.classes.?, 1);
    defer drive_cache.deinit();
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    defer warnings.deinit(init.gpa);
    var walk = try walk_cache.acquire(try pedestrian.parse(init.gpa, .null, &warnings, .none), .none);
    defer walk.release();
    var drive = try drive_cache.acquire(try auto.parse(init.gpa, .auto, .null, &warnings, .none), .none);
    defer drive.release();

    var output_buffer: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &output_buffer);
    var request_memory = memory.Arena.init(backing.allocator(), .{});
    defer request_memory.deinit();
    var rows = std.mem.tokenizeScalar(u8, data, '\n');
    var index: usize = 0;
    while (rows.next()) |line| : (index += 1) {
        var storage: std.heap.ArenaAllocator = .init(init.gpa);
        defer storage.deinit();
        const a = storage.allocator();
        const row = try std.json.parseFromSliceLeaky(Row, a, line, .{ .ignore_unknown_fields = true });
        var contours: std.ArrayList(iso.Interval) = .empty;
        for (row.contours) |contour| {
            if (contour.time) |value| try contours.append(a, .{ .metric = iso.time_metric, .value = value });
            if (contour.distance) |value| try contours.append(a, .{ .metric = iso.distance_metric, .value = value });
        }
        const origins = try correlate(view, a, row);
        const request: iso.Request = .{
            .origins = origins,
            .contours = contours.items,
            .direction = if (row.reverse) .reverse else .forward,
            .mode = switch (row.costing) {
                .auto => .motor,
                .pedestrian => .pedestrian,
            },
            .unit_size = switch (row.costing) {
                .auto => drive.tables().unit_size,
                .pedestrian => walk.tables().unit_size,
            },
        };
        switch (row.costing) {
            .auto => try measure(&motorist, Auto{ .profile = drive.profile(), .tables = drive.tables(), .arena = request_memory.allocator() }, request, &request_memory, &backing, index, &output.interface, grids, traces, a),
            .pedestrian => try measure(&walker, Foot{ .profile = walk.profile(), .tables = walk.tables() }, request, &request_memory, &backing, index, &output.interface, grids, traces, a),
        }
    }
    try output.interface.flush();
}
