//! Stage timings for a bulk /height request (ReleaseFast): parse, sample, serialize.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;

test "perf: bulk height stages" {
    if (@import("builtin").mode != .fast) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    try body.appendSlice(gpa, "{\"shape\":[");
    for (0..10_000) |i| {
        if (i > 0) try body.append(gpa, ',');
        try body.print(gpa, "{{\"lat\":{d:.6},\"lon\":{d:.6}}}", .{ 52 + r.float(f64), 5 + r.float(f64) });
    }
    try body.appendSlice(gpa, "]}");

    var tiles = try routing.elevation.hgt.Tiles.init(gpa, "oracle/data/utrecht/elevation");
    defer tiles.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var t_parse: u64 = 0;
    var t_sample: u64 = 0;
    var t_ser: u64 = 0;
    const rounds = 50;
    for (0..rounds) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var t = io.Timer.start();
        const parsed = try routing.api.request.parseHttp(a, "/height", &.{}, body.items);
        var o = parsed.ok;
        t_parse += t.lap();
        const pts = try a.alloc(routing.geo.PointLL, o.shape.len);
        for (o.shape, pts) |l, *p| p.* = .{ .lng = l.lng, .lat = l.lat };
        const h = try a.alloc(f64, pts.len);
        routing.elevation.hgt.getAll(&tiles, pts, h);
        t_sample += t.lap();
        var out: std.ArrayList(u8) = .empty;
        try routing.api.height_action.serialize(a, &out, &o, pts, null, h, &.{});
        t_ser += t.lap();
    }
    std.debug.print("\n10k-point /height ({d} KB body): parse {d:.2} ms, sample {d:.2} ms, serialize {d:.2} ms\n", .{
        body.items.len / 1024,
        @as(f64, @floatFromInt(t_parse / rounds)) / 1e6,
        @as(f64, @floatFromInt(t_sample / rounds)) / 1e6,
        @as(f64, @floatFromInt(t_ser / rounds)) / 1e6,
    });
}
