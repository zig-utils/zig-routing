//! Compare exact-coordinate reverse results with sampled source addresses.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const reverse = routing.geocode.reverse;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingGeocodeBundle;
    if (args.next() != null) return error.UnexpectedArgument;
    const a = init.arena.allocator();
    var engine = try reverse.Engine.open(std.heap.page_allocator, path, .none);
    defer engine.close();
    const data = engine.bundle.data;
    const sample_count = 10_000;
    if (data.addresses.len < sample_count) return error.InsufficientReverseAddresses;

    var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer used.deinit(a);
    const ids = try a.alloc(u32, sample_count);
    var rng = std.Random.DefaultPrng.init(224);
    const random = rng.random();
    for (ids) |*id| {
        while (true) {
            const row = random.uintLessThan(u32, @intCast(data.addresses.len));
            if ((try used.getOrPut(a, row)).found_existing) continue;
            id.* = row;
            break;
        }
    }
    var backing = routing.infra.arena.CountingAllocator.init(std.heap.page_allocator);
    var arena = routing.infra.arena.Arena.init(backing.allocator(), .{});
    defer arena.deinit();
    const memory = arena.allocator();
    var exact: routing.cli.bench.Histogram = .{};
    var offset: routing.cli.bench.Histogram = .{};
    var matching: usize = 0;
    for (0..2) |round| {
        for (ids, 0..) |id, i| {
            const record = data.addresses[id].record;
            const point = record.coordinate.toPoint();
            arena.reset();
            const start = io.Timer.start();
            const response = try engine.lookup(memory, .{ .point = point }, .fromNowMs(250));
            if (round == 1) {
                exact.record(start.read());
                if (response.results.len != 0) {
                    const result = response.results[0];
                    if (result.layer == .address and !result.approximate and result.osm_id == record.osm_id and result.source == record.attr.source)
                        matching += 1;
                }
            }
            arena.reset();
            const off_center = jitter(point, i);
            const shifted_start = io.Timer.start();
            _ = try engine.lookup(memory, .{ .point = off_center }, .fromNowMs(250));
            if (round == 1) offset.record(shifted_start.read());
        }
        if (round == 0) backing.resetCounts();
    }
    const calls = backing.calls();
    arena.reset();
    const ocean = try engine.lookup(memory, .{ .point = .init(-140, 0) }, .none);
    if (ocean.results.len > 1 or (ocean.results.len == 1 and ocean.results[0].layer != .country)) return error.InvalidReverseOceanResult;
    const result = try std.json.Stringify.valueAlloc(a, .{
        .dataset_uuid = engine.bundle.uuid,
        .sampled = sample_count,
        .matching_osm_address = matching,
        .recall = @as(f64, @floatFromInt(matching)) / sample_count,
        .on_address = .{ .p50_ns = exact.percentile(50), .p99_ns = exact.percentile(99) },
        .off_address = .{ .p50_ns = offset.percentile(50), .p99_ns = offset.percentile(99) },
        .ocean_results = ocean.results.len,
        .steady_state_heap_calls = calls,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(result);
    try io.writeStdout("\n");
    if (matching * 100 < sample_count * 98) return error.ReverseAddressRecallBelowBudget;
    if (@max(exact.percentile(99), offset.percentile(99)) >= std.time.ns_per_ms) return error.ReverseLatencyOverBudget;
    if (calls != 0) return error.ReverseAllocatedAfterWarmup;
}

fn jitter(point: routing.geo.PointLL, i: usize) routing.geo.PointLL {
    const lng = point.lng + (if (i & 1 == 0) @as(f64, 0.0002) else -0.0002);
    const lat = point.lat + (if (i & 2 == 0) @as(f64, 0.0001) else -0.0001);
    return .init(if (lng > 180) lng - 360 else if (lng < -180) lng + 360 else lng, std.math.clamp(lat, -90, 90));
}
