//! Experiment E1. Time the plain Dijkstra loop on a native country bundle.
const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const perf = @import("perf_counters");
const graph = routing.graph;
const search = routing.search.search;
const queue = routing.search.queue;
const pedestrian = routing.costing.pedestrian;
const auto = routing.costing.auto;
const Cost = routing.costing.compiled.Cost;
const io = routing.infra.io;
const Edge = graph.format.EdgeId;
const Node = graph.format.NodeId;
const View = graph.reader.View;
const Hot = graph.format.EdgeHot;

const Foot = @import("pedestrian_search_kernel.zig").Foot;

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

const Auto = @import("auto_search_kernel.zig").Auto;

const Sample = struct {
    source: u32,
    settled: usize,
    popped: usize,
    elapsed_ns: u64,
    ns_per_label: ?f64,
    counters_per_label: ?perf.Counts.PerUnit,
};

const QueueKind = enum { heap, bucket };

fn measure(comptime K: type, kernel: K, gpa: std.mem.Allocator, view: *const View, sources: []const Node, limit: usize, kind: QueueKind, unit_size: u32) ![]Sample {
    return switch (kind) {
        .heap => measureWithQueue(K, .heap, kernel, gpa, view, sources, limit, unit_size),
        .bucket => measureWithQueue(K, .bucket, kernel, gpa, view, sources, limit, unit_size),
    };
}

fn measureWithQueue(comptime K: type, comptime kind: QueueKind, kernel: K, gpa: std.mem.Allocator, view: *const View, sources: []const Node, limit: usize, unit_size: u32) ![]Sample {
    const Engine = if (kind == .heap) search.Search(K, queue.Heap) else routing.search.expand.Expansion(K, queue.BucketQueue);
    var engine = try Engine.init(gpa, view);
    defer engine.deinit();
    var arena = routing.infra.arena.Arena.init(gpa, .{});
    defer arena.deinit();
    // Visit the identical sources for warm-up and measurement.
    for (sources) |source| {
        _ = try sweep(kind, &engine, &arena, kernel, source, limit, unit_size);
        arena.reset();
    }
    const samples = try gpa.alloc(Sample, sources.len);
    errdefer gpa.free(samples);
    for (sources, samples) |source, *sample| {
        var counters = perf.Counters.start();
        defer if (counters) |*counter| counter.deinit();
        const timer = io.Timer.start();
        const stats = try sweep(kind, &engine, &arena, kernel, source, limit, unit_size);
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

fn sweep(comptime kind: QueueKind, engine: anytype, arena: *routing.infra.arena.Arena, kernel: anytype, source: Node, limit: usize, unit_size: u32) !search.SweepStats {
    if (kind == .heap) return engine.sweep(arena, kernel, source, .forward, limit, .{});
    return engine.run(arena, kernel, .{ .origins = &.{source}, .limit = limit, .unit_size = unit_size }, {}, .{});
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const samples = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 10;
    const limit = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 10) else 1_000_000;
    const seed = if (args.next()) |arg| try std.fmt.parseInt(u64, arg, 10) else 82;
    var auto_only = false;
    var kind: QueueKind = .heap;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--auto") and !auto_only) {
            auto_only = true;
        } else if (std.mem.eql(u8, arg, "--bucket") and kind == .heap) {
            kind = .bucket;
        } else return error.InvalidSearchBenchmarkArguments;
    }
    if (samples == 0 or limit == 0) return error.InvalidSearchBenchmarkArguments;
    const a = init.arena.allocator();
    var bundle = try graph.reader.Bundle.open(path);
    defer bundle.close();
    const view = &bundle.view;
    if (view.nodes.len == 0) return error.EmptyBundle;
    const sources = try a.alloc(Node, samples);
    var random = std.Random.DefaultPrng.init(seed);
    for (sources) |*source| source.* = @fromBackingInt(random.random().uintLessThan(u32, @intCast(view.nodes.len)));

    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    var buffer: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    if (auto_only) {
        const options = try auto.parse(a, .auto, .null, &warnings, .none);
        var cache = try auto.Cache.init(a, view.classes orelse return error.MissingClasses, 1);
        defer cache.deinit();
        var lease = try cache.acquire(options, .none);
        defer lease.release();
        const results = try measure(Auto, .{ .profile = lease.profile(), .tables = lease.tables(), .arena = init.gpa }, a, view, sources, limit, kind, lease.tables().unit_size);
        try std.json.Stringify.value(.{
            .platform = @tagName(builtin.os.tag),
            .architecture = @tagName(builtin.cpu.arch),
            .dataset_uuid = std.fmt.bytesToHex(view.dataset_uuid, .lower),
            .seed = seed,
            .label_limit = limit,
            .auto = results,
        }, .{}, &stdout.interface);
        try stdout.interface.writeByte('\n');
        return stdout.interface.flush();
    }
    var options = try pedestrian.parse(a, .null, &warnings, .none);
    // Use an unbounded sweep so the service's distance limit does not stop it.
    options.max_distance = std.math.maxInt(u32);
    var cache = try pedestrian.Cache.init(a, view.classes orelse return error.MissingClasses, 1);
    defer cache.deinit();
    var lease = try cache.acquire(options, .none);
    defer lease.release();
    const foot = try measure(Foot, .{ .profile = lease.profile(), .tables = lease.tables() }, a, view, sources, limit, kind, lease.tables().unit_size);
    const motor = try measure(Motor, .{}, a, view, sources, limit, kind, 1);

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
