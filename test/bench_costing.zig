//! Time cold compiles and warm canonical cache hits over a real class table.
const std = @import("std");
const routing = @import("routing");
const costing = routing.costing.compiled;
const graph = routing.graph;
const io = routing.infra.io;

const Model = struct {
    pub const Options = f32;
    pub const Canonical = f32;

    pub fn canonicalize(value: Options) !Canonical {
        return @min(2, @max(0.01, value));
    }

    pub fn rules(_: Canonical) !costing.Rules {
        return .{ .node_access_mask = @bitCast(graph.constants.AccessMask{ .pedestrian = true }) };
    }

    pub fn classFactor(weight: Canonical, class: graph.class_table.EdgeClass) !f32 {
        if (!class.forwardAccess().pedestrian) return std.math.inf(f32);
        const importance: f32 = @floatFromInt(class.category.road_class);
        return 1 + weight * importance * 0.1;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const limit = if (args.next()) |arg| try std.fmt.parseInt(u64, arg, 10) else null;
    if (args.next() != null) return error.TooManyArguments;
    var bundle = try graph.reader.Bundle.open(path);
    defer bundle.close();
    const classes = bundle.view.classes orelse return error.MissingClasses;
    var allocator = std.testing.FailingAllocator.init(init.gpa, .{});
    var cache = try costing.Cache(Model).init(allocator.allocator(), classes, 4);
    defer cache.deinit();
    allocator.fail_index = allocator.alloc_index;

    const samples = 1024;
    const hit_batch = 64;
    var misses: [samples]u64 = undefined;
    var hits: [samples]u64 = undefined;
    var checksum: u64 = 0;
    for (0..samples + 32) |i| {
        const option = 0.1 + @as(f32, @floatFromInt(i)) / 2048.0;
        const miss_start = io.Timer.start();
        var cold = try cache.acquire(option, .none);
        const miss_ns = miss_start.read();
        checksum +%= std.mem.readInt(u64, cold.tables().metric_key[0..8], .little);
        cold.release();

        const hit_start = io.Timer.start();
        for (0..hit_batch) |_| {
            var warm = try cache.acquire(option, .none);
            checksum +%= std.mem.readInt(u64, warm.tables().metric_key[8..16], .little);
            warm.release();
        }
        const hit_ns = hit_start.read() / hit_batch;
        if (i >= 32) {
            misses[i - 32] = miss_ns;
            hits[i - 32] = hit_ns;
        }
    }
    std.mem.sortUnstable(u64, &misses, {}, std.sort.asc(u64));
    std.mem.sortUnstable(u64, &hits, {}, std.sort.asc(u64));
    const median = misses[samples / 2 - 1];
    var buffer: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .classes = classes.len,
        .iterations = samples,
        .miss_median_ns = median,
        .miss_p95_ns = misses[@divFloor(95 * samples, 100) - 1],
        .hit_median_ns = hits[samples / 2 - 1],
        .hit_p95_ns = hits[@divFloor(95 * samples, 100) - 1],
        .checksum = checksum,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (limit) |ns| if (median > ns) return error.CostCompileBudgetExceeded;
}
