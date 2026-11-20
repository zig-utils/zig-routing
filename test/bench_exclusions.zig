//! Measure parsing, validation and edge collection for a large exclude polygon.
const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const request = routing.api.request;
const exclusions = routing.api.exclusions;
const io = routing.infra.io;
const memory = routing.infra.arena;

const limits: exclusions.Limits = .{};
const samples = 32;
const budget_ns = 50 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const longitude = try std.fmt.parseFloat(f64, args.next() orelse return error.MissingLongitude);
    const latitude = try std.fmt.parseFloat(f64, args.next() orelse return error.MissingLatitude);
    if (args.next() != null) return error.InvalidArguments;
    const center: routing.geo.PointLL = .init(longitude, latitude);
    if (!center.inRange() or @abs(latitude) > 85) return error.InvalidCenter;
    var ring: [limits.max_exclude_polygons_vertices - 1][2]f64 = undefined;
    const latitude_radius = 1_450 / routing.geo.constants.meters_per_degree_lat;
    const longitude_radius = latitude_radius / routing.geo.libm.cosF(latitude * routing.geo.constants.rad_per_deg_d);
    for (&ring, 0..) |*p, i| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / ring.len;
        p.* = .{ longitude + longitude_radius * routing.geo.libm.cosF(angle), latitude + latitude_radius * routing.geo.libm.sinF(angle) };
    }
    const body = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .costing = "auto",
        .exclude_polygons = .{ring},
    }, .{});
    var bundle = try routing.graph.reader.Bundle.open(path);
    defer bundle.close();
    var backing = memory.CountingAllocator.init(std.heap.page_allocator);
    var arena = memory.Arena.init(backing.allocator(), .{});
    defer arena.deinit();
    const warm = try resolve(&bundle.view, arena.allocator(), body, .none);
    if (warm == 0) return error.EmptyExclusion;
    arena.reset();
    backing.resetCounts();
    var elapsed: [samples]u64 = undefined;
    for (&elapsed) |*sample| {
        const timer = io.Timer.start();
        const count = try resolve(&bundle.view, arena.allocator(), body, .{ .at_ns = timer.start_ns + budget_ns });
        sample.* = timer.read();
        if (count != warm) return error.ExclusionCountChanged;
        arena.reset();
    }
    if (backing.calls() != 0) return error.SteadyStateHeapCall;
    std.sort.heap(u64, &elapsed, {}, std.sort.asc(u64));
    const slowest = elapsed[elapsed.len - 1];
    var buffer: [1024]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .platform = @tagName(builtin.os.tag),
        .architecture = @tagName(builtin.cpu.arch),
        .dataset_uuid = std.fmt.bytesToHex(bundle.view.dataset_uuid, .lower),
        .vertices = ring.len + 1,
        .excluded_edges = warm,
        .requests = samples,
        .p50_ns = elapsed[samples / 2 - 1],
        .max_ns = slowest,
        .budget_ns = budget_ns,
        .arena_high_water_bytes = arena.high_water,
        .heap_calls = backing.calls(),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (slowest > budget_ns) return error.ExclusionBudgetExceeded;
}

fn resolve(view: *const routing.graph.reader.View, arena: std.mem.Allocator, body: []const u8, deadline: io.Deadline) !usize {
    const parsed = try request.parseHttpWithin(arena, "/route", &.{}, body, false, deadline);
    if (parsed != .ok) return error.InvalidBenchmarkRequest;
    if (try exclusions.validate(arena, limits, parsed.ok.exclude_polygons, 0, deadline) != null) return error.InvalidBenchmarkRequest;
    const found = try routing.snap.exclusions.resolve(view, arena, &parsed.ok, &.{}, .{}, routing.snap.candidates.Access{ .mask = .{ .auto = true } }, deadline);
    return found.len;
}
