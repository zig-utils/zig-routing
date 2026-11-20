//! Experiment E1. Time the plain Dijkstra loop on a native country bundle.
const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const perf = @import("perf_counters");
const graph = routing.graph;
const search = routing.search.search;
const queue = routing.search.queue;
const pedestrian = routing.costing.pedestrian;
const Cost = routing.costing.compiled.Cost;
const io = routing.infra.io;
const Edge = graph.format.EdgeId;
const Node = graph.format.NodeId;
const View = graph.reader.View;
const Hot = graph.format.EdgeHot;

const Foot = struct {
    profile: *const pedestrian.Profile,
    tables: *const routing.costing.compiled.Compiled,

    pub fn restrictionModes(self: Foot) u16 {
        const permission = self.profile.permission;
        if (permission.flags.contains(.ignore_restrictions) or permission.flags.contains(.ignore_non_vehicular_restrictions)) return 0;
        return @bitCast(permission.access_mask);
    }

    pub fn edgeCost(self: Foot, view: *const View, _: Edge, edge: *const Hot, _: search.Direction) !Cost {
        const class = try view.class(edge.cls.class_id);
        return pedestrian.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedFerrySpeed(edge.*), .{});
    }

    pub fn allowedTurn(self: Foot, view: *const View, movement: search.Transition, previous: search.Label, _: search.Direction) !bool {
        if (!self.profile.allowedNode(try view.node(movement.node))) return false;
        const from = try view.class(movement.incoming_edge.cls.class_id);
        const to = try view.class(movement.outgoing_edge.cls.class_id);
        return pedestrian.Kernel.allowed(self.profile, from, to, movement.outgoing_edge.*, .{
            .previous_distance = previous.dist_m,
            .previous_dead_end = from.flags.dead_end or (try view.outEdgeRange(movement.node)).count() == 1,
            .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
        });
    }

    pub fn turnCost(self: Foot, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
        const from = try view.class(movement.incoming_edge.cls.class_id);
        const to = try view.class(movement.outgoing_edge.cls.class_id);
        const turn = try pedestrian.Turn.read(view, movement.node, movement.incoming, movement.outgoing);
        return pedestrian.Kernel.turnCost(self.profile, try view.node(movement.node), from, to, turn);
    }
};

const Motor = struct {
    pub fn edgeCost(_: Motor, view: *const View, _: Edge, edge: *const Hot, _: search.Direction) !Cost {
        const class = try view.class(edge.cls.class_id);
        if (!class.forwardAccess().auto or edge.speed[0] == 0) return .forbidden;
        const seconds = @as(f32, @floatFromInt(edge.geom.len_m)) * 3.6 / @as(f32, @floatFromInt(edge.speed[0]));
        return .{ .cost = seconds, .secs = seconds };
    }

    pub fn turnCost(_: Motor, _: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
        const seconds: f32 = @floatFromInt((movement.row >> 3) & 7);
        return .{ .cost = seconds, .secs = seconds };
    }
};

const Sample = struct {
    source: u32,
    settled: usize,
    popped: usize,
    elapsed_ns: u64,
    ns_per_label: ?f64,
    counters_per_label: ?perf.Counts.PerUnit,
};

fn measure(comptime K: type, kernel: K, gpa: std.mem.Allocator, view: *const View, sources: []const Node, limit: usize) ![]Sample {
    var engine = try search.Search(K, queue.Heap).init(gpa, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(gpa, .{});
    defer arena.deinit();
    // Visit the identical sources for warm-up and measurement.
    for (sources) |source| {
        _ = try engine.sweep(&arena, kernel, source, .forward, limit, .{});
        arena.reset();
    }
    const samples = try gpa.alloc(Sample, sources.len);
    errdefer gpa.free(samples);
    for (sources, samples) |source, *sample| {
        var counters = perf.Counters.start();
        defer if (counters) |*counter| counter.deinit();
        const timer = io.Timer.start();
        const stats = try engine.sweep(&arena, kernel, source, .forward, limit, .{});
        const elapsed = timer.read();
        const counts = if (counters) |*counter| counter.finish() else null;
        sample.* = .{
            .source = @backingInt(source),
            .settled = stats.settled,
            .popped = stats.popped,
            .elapsed_ns = elapsed,
            .ns_per_label = if (stats.settled == 0) null else @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(stats.settled)),
            .counters_per_label = if (counts) |value| value.perUnit(stats.settled) else null,
        };
        arena.reset();
    }
    return samples;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const samples = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 10;
    const limit = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 1_000_000;
    const seed = if (args.next()) |arg| try std.fmt.parseInt(u64, arg, 10) else 82;
    if (args.next() != null or samples == 0 or limit == 0) return error.InvalidSearchBenchmarkArguments;
    const a = init.arena.allocator();
    var bundle = try graph.reader.Bundle.open(path);
    defer bundle.close();
    const view = &bundle.view;
    if (view.nodes.len == 0) return error.EmptyBundle;
    const sources = try a.alloc(Node, samples);
    var random = std.Random.DefaultPrng.init(seed);
    for (sources) |*source| source.* = @fromBackingInt(random.random().uintLessThan(u32, @intCast(view.nodes.len)));

    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    var options = try pedestrian.parse(a, .null, &warnings, .none);
    // Use an unbounded sweep so the service's distance limit does not stop it.
    options.max_distance = std.math.maxInt(u32);
    var cache = try pedestrian.Cache.init(a, view.classes orelse return error.MissingClasses, 1);
    defer cache.deinit();
    var lease = try cache.acquire(options, .none);
    defer lease.release();
    const foot = try measure(Foot, .{ .profile = lease.profile(), .tables = lease.tables() }, a, view, sources, limit);
    const motor = try measure(Motor, .{}, a, view, sources, limit);

    var buffer: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .platform = @tagName(builtin.os.tag),
        .architecture = @tagName(builtin.cpu.arch),
        .dataset_uuid = std.fmt.bytesToHex(view.dataset_uuid, .lower),
        .nodes = view.nodes.len,
        .directed_edges = view.edges.len,
        .seed = seed,
        .label_limit = limit,
        .pedestrian = foot,
        .stub_motor = motor,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
