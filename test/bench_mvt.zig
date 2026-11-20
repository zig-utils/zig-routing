//! Single-threaded MVT encoder throughput after reusable buffers are warm.
const std = @import("std");
const routing = @import("routing");
const mvt = routing.tiles.mvt;
const io = routing.infra.io;

const feature_count = 4096;
const tiles_per_sample = 60;
const labels = [_][]const u8{ "main", "secondary", "trail", "service" };
const boundary = [_]mvt.Point{ .{ .x = 80, .y = 80 }, .{ .x = 300, .y = 80 }, .{ .x = 300, .y = 300 }, .{ .x = 80, .y = 300 } };
const hole = [_]mvt.Point{ .{ .x = 110, .y = 110 }, .{ .x = 110, .y = 160 }, .{ .x = 160, .y = 160 }, .{ .x = 160, .y = 110 } };
const rings = [_]mvt.Ring{ .{ .points = &boundary, .winding = .exterior }, .{ .points = &hole, .winding = .interior } };

fn fill(layer: *mvt.Layer, tile: *std.ArrayList(u8), points: []const mvt.Point, deadline: io.Deadline) !void {
    layer.reset();
    tile.clearRetainingCapacity();
    for (0..feature_count) |i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const properties = [_]mvt.Property{
            .{ .key = "class", .value = .{ .string = labels[i % labels.len] } },
            .{ .key = "length", .value = .{ .unsigned = 80 + i % 4 } },
            .{ .key = "access", .value = .{ .boolean = i % 2 != 0 } },
            .{ .key = "level", .value = .{ .zigzag = @as(i64, @intCast(i % 6)) - 3 } },
        };
        switch (i % 10) {
            0 => try layer.addPoint(i, points[i % points.len], &properties, .none),
            1 => try layer.addPolygon(i, &rings, &properties, .none),
            else => try layer.addLine(i, points[0 .. 12 + i % (points.len - 11)], &properties, .none),
        }
    }
    try layer.write(tile, deadline);
}

pub fn main(init: std.process.Init) !void {
    var counting: routing.infra.arena.CountingAllocator = .init(init.gpa);
    const a = counting.allocator();
    var layer: mvt.Layer = .init(a, "features");
    defer layer.deinit();
    var tile: std.ArrayList(u8) = .empty;
    defer tile.deinit(a);
    var line: [64]mvt.Point = undefined;
    for (&line, 0..) |*point, i| {
        point.* = .{ .x = @intCast(3 * i + 73), .y = @intCast(90 + (i * i + i * 13) % 101) };
    }
    const deadline = io.Deadline.fromNowMs(120_000);
    try fill(&layer, &tile, &line, deadline);
    const tile_bytes = tile.items.len;
    counting.resetCounts();
    var samples: [7]u64 = undefined;
    for (&samples) |*duration| {
        const time = io.Timer.start();
        for (0..tiles_per_sample) |_| {
            try fill(&layer, &tile, &line, deadline);
            std.mem.doNotOptimizeAway(tile.items);
        }
        duration.* = time.read();
    }
    std.mem.sort(u64, &samples, {}, comptime std.sort.asc(u64));
    const bytes = @as(f64, @floatFromInt(tile_bytes * tiles_per_sample));
    const mbps = bytes * (std.time.ns_per_s / 1_000_000) / @as(f64, @floatFromInt(samples[samples.len / 2]));
    var buffer: [512]u8 = undefined;
    var out = io.stdoutWriter(init.io, &buffer);
    try out.interface.print("features_per_tile {d}\nencoded_bytes_per_tile {d}\nmedian_encode_mb_per_second {d:.2}\nwarm_allocator_calls {d}\n", .{
        feature_count, tile_bytes, mbps, counting.calls(),
    });
    try out.interface.flush();
    if (counting.calls() != 0) return error.WarmMvtAllocated;
    if (mbps < 200) return error.MvtEncodeBudgetExceeded;
}
