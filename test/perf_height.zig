//! Stage timings for /height (ReleaseFast): `zig build perf`.
//!
//! Two workloads: a synthetic 10k-point request (random points, the worst
//! case for locality), and the bulk corpus `bench/corpora/height.utrecht.tsv`
//! replayed request by request (skipped when the corpus or the oracle tiles
//! are absent; `bun tools/corpus/generate.ts` and `oracle/fetch.sh utrecht`
//! provide them). Each reports parse, sample and serialize time per point.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const height_action = routing.api.height_action;

const Stages = struct {
    parse: u64 = 0,
    sample: u64 = 0,
    serialize: u64 = 0,
    points: u64 = 0,
    requests: u64 = 0,

    fn print(self: Stages, name: []const u8) void {
        const p: f64 = @floatFromInt(@max(self.points, 1));
        const total = self.parse + self.sample + self.serialize;
        std.debug.print("{s}: {d} requests, {d} points: parse {d:.1} ns/pt, sample {d:.1} ns/pt, serialize {d:.1} ns/pt, total {d:.1} ns/pt ({d:.1} us/request)\n", .{
            name,                                    self.requests,                                                                           self.points,
            @as(f64, @floatFromInt(self.parse)) / p, @as(f64, @floatFromInt(self.sample)) / p,                                                @as(f64, @floatFromInt(self.serialize)) / p,
            @as(f64, @floatFromInt(total)) / p,      @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(@max(self.requests, 1))) / 1000,
        });
    }
};

/// Runs one request body through the /height stages the handler runs.
fn stages(a: std.mem.Allocator, source: routing.elevation.Source, body: []const u8, s: *Stages) !void {
    var t = io.Timer.start();
    const parsed = try routing.api.request.parseHttp(a, "/height", &.{}, body);
    var o = switch (parsed) {
        .ok => |o| o,
        .failure => return,
    };
    s.parse += t.lap();
    const pts = try a.alloc(routing.geo.PointLL, o.shape.len);
    for (o.shape, pts) |l, *p| p.* = .{ .lng = l.lng, .lat = l.lat };
    const h = try a.alloc(f64, pts.len);
    try source.getAllBatched(a, pts, h);
    var ranges: []f64 = &.{};
    if (o.range) {
        ranges = try a.alloc(f64, pts.len);
        ranges[0] = 0;
        for (1..pts.len) |i| ranges[i] = ranges[i - 1] + pts[i].distance(pts[i - 1]);
    }
    s.sample += t.lap();
    var out: std.ArrayList(u8) = .empty;
    try height_action.serialize(a, &out, &o, pts, o.encoded_polyline, h, ranges);
    s.serialize += t.lap();
    s.points += pts.len;
    s.requests += 1;
}

test "perf: bulk height stages" {
    if (@import("builtin").mode != .fast) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tiles = try routing.elevation.hgt.Tiles.init(gpa, "oracle/data/utrecht/elevation");
    defer tiles.deinit();
    if (tiles.count == 0) return error.SkipZigTest;
    const source: routing.elevation.Source = .{ .tiles = &tiles };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

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
    var synthetic: Stages = .{};
    for (0..50) |_| {
        _ = arena.reset(.retain_capacity);
        try stages(arena.allocator(), source, body.items, &synthetic);
    }
    synthetic.print("random 10k-point request");

    // Sampling alone on the scattered points: one by one against batched, same run.
    {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const parsed = try routing.api.request.parseHttp(a, "/height", &.{}, body.items);
        const pts = try a.alloc(routing.geo.PointLL, parsed.ok.shape.len);
        for (parsed.ok.shape, pts) |l, *p| p.* = .{ .lng = l.lng, .lat = l.lat };
        const h = try a.alloc(f64, pts.len);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        // Between runs, sweep 64 MiB so the tile is out of cache, as it is in a
        // server where parsing and serializing other requests evict it.
        const sweep = try gpa.alloc(u8, 64 << 20);
        defer gpa.free(sweep);
        var sink: u64 = 0;
        var t_one: u64 = 0;
        var t_batch: u64 = 0;
        for (0..50) |_| {
            @memset(sweep, @truncate(sink));
            sink +%= sweep[sink % sweep.len];
            var t = io.Timer.start();
            source.getAll(pts, h);
            t_one += t.lap();
            @memset(sweep, @truncate(sink));
            sink +%= sweep[(sink * 7) % sweep.len];
            _ = scratch.reset(.retain_capacity);
            t = io.Timer.start();
            try source.getAllBatched(scratch.allocator(), pts, h);
            t_batch += t.lap();
        }
        std.mem.doNotOptimizeAway(sink);
        const per: f64 = @floatFromInt(50 * pts.len);
        std.debug.print("scattered sampling, tiles: one by one {d:.1} ns/pt, batched {d:.1} ns/pt\n", .{ @as(f64, @floatFromInt(t_one)) / per, @as(f64, @floatFromInt(t_batch)) / per });

        // The same through a pack (bench/results/utrecht.zdem, from `zr dem pack`), if present.
        if (routing.elevation.@"packed".Pack.open("bench/results/utrecht.zdem")) |pack_in| {
            var pack = pack_in;
            defer pack.close();
            const ps: routing.elevation.Source = .{ .pack = &pack };
            t_one = 0;
            t_batch = 0;
            for (0..20) |_| {
                var t = io.Timer.start();
                ps.getAll(pts, h);
                t_one += t.lap();
                _ = scratch.reset(.retain_capacity);
                try ps.getAllBatched(scratch.allocator(), pts, h);
                t_batch += t.lap();
            }
            const per20: f64 = @floatFromInt(20 * pts.len);
            std.debug.print("scattered sampling, pack: one by one {d:.1} ns/pt, batched {d:.1} ns/pt\n", .{ @as(f64, @floatFromInt(t_one)) / per20, @as(f64, @floatFromInt(t_batch)) / per20 });
        } else |_| {}
    }

    const corpus = io.readFileAlloc(gpa, "bench/corpora/height.utrecht.tsv", 64 << 20) catch return;
    defer gpa.free(corpus);
    var bulk: Stages = .{};
    for (0..20) |_| {
        var lines = std.mem.splitScalar(u8, corpus, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            _ = arena.reset(.retain_capacity);
            try stages(arena.allocator(), source, line[tab + 1 ..], &bulk);
        }
    }
    bulk.print("height.utrecht corpus x20");

    // The budget (bench/budgets/height.json): a stage over it fails the run.
    const budget_text = try io.readFileAlloc(gpa, "bench/budgets/height.json", 1 << 16);
    defer gpa.free(budget_text);
    var budget_arena = std.heap.ArenaAllocator.init(gpa);
    defer budget_arena.deinit();
    const budget = try routing.api.json.parse(budget_arena.allocator(), budget_text);
    const p: f64 = @floatFromInt(bulk.points);
    const measured = [_]struct { name: []const u8, ns: f64 }{
        .{ .name = "parse", .ns = @as(f64, @floatFromInt(bulk.parse)) / p },
        .{ .name = "sample", .ns = @as(f64, @floatFromInt(bulk.sample)) / p },
        .{ .name = "serialize", .ns = @as(f64, @floatFromInt(bulk.serialize)) / p },
        .{ .name = "total", .ns = @as(f64, @floatFromInt(bulk.parse + bulk.sample + bulk.serialize)) / p },
    };
    var over = false;
    for (measured) |m| {
        var path_buf: [32]u8 = undefined;
        const limit = routing.api.json.get(f64, budget, try std.fmt.bufPrint(&path_buf, "/{s}", .{m.name}), std.math.inf(f64));
        if (m.ns > limit) {
            std.debug.print("over budget: {s} {d:.1} ns/pt > {d:.1}\n", .{ m.name, m.ns, limit });
            over = true;
        }
    }
    try std.testing.expect(!over);
}
