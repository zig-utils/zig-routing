//! Compare the production projection and polyline kernels on the same inputs.
const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const geo = routing.geo;
const io = routing.infra.io;
const snap = routing.snap.candidates;
const polyline = geo.polyline;

const samples = 9;
const warmups = 2;
const repeats = 4000;
const max_vertices = 65;
const Buffer = [polyline.maxEncodedLen(.polyline, max_vertices)]u8;
const Shape = struct {
    points: [max_vertices]geo.PointLL,
    len: usize,
    approx: geo.DistanceApproximator,

    fn vertices(self: *const Shape) []const geo.PointLL {
        return self.points[0..self.len];
    }
};

fn makeShapes() [64]Shape {
    var prng = std.Random.DefaultPrng.init(110);
    const random = prng.random();
    var shapes: [64]Shape = undefined;
    const lengths = [_]usize{ 3, 9, 33, max_vertices };
    for (&shapes, 0..) |*shape, i| {
        const center: geo.PointLL = .init(
            -170.0 + 340.0 * random.float(f64),
            -75.0 + 150.0 * random.float(f64),
        );
        shape.len = lengths[i % lengths.len];
        shape.approx = .init(center);
        for (&shape.points, 0..) |*point, j| {
            const along = @as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(shape.len)) * 0.5;
            point.* = .init(
                center.lng + along * 0.00009,
                center.lat + (random.float(f64) - 0.5) * 0.001,
            );
        }
    }
    return shapes;
}

const Kernel = enum { snap_projection, polyline_encode };

const Measurement = struct {
    ns_per_item: f64,
    digest: [16]u8,
};

fn measure(comptime kernel: Kernel, shapes: []const Shape, deadline: io.Deadline) !Measurement {
    var input_count: usize = 0;
    var hash = std.hash.Wyhash.init(0);
    for (shapes) |*shape| switch (kernel) {
        .snap_projection => {
            input_count += shape.len - 1;
            const result = try snap.project(shape.approx, shape.vertices(), deadline);
            hash.update(std.mem.asBytes(&result.point.lng));
            hash.update(std.mem.asBytes(&result.point.lat));
            hash.update(std.mem.asBytes(&result.squared));
            hash.update(std.mem.asBytes(&@as(u32, @intCast(result.segment))));
        },
        .polyline_encode => {
            input_count += shape.len;
            var out: Buffer = undefined;
            const written = try polyline.encode(.polyline, 6, shape.vertices(), &out);
            hash.update(out[0..written]);
        },
    };

    var elapsed: [samples]u64 = undefined;
    for (0..samples + warmups) |sample| {
        const timer = io.Timer.start();
        for (0..repeats) |iteration| {
            if (iteration % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            for (shapes) |*shape| switch (kernel) {
                .snap_projection => {
                    const projection = try snap.project(shape.approx, shape.vertices(), .none);
                    std.mem.doNotOptimizeAway(projection);
                },
                .polyline_encode => {
                    var out: Buffer = undefined;
                    const written = try polyline.encode(.polyline, 6, shape.vertices(), &out);
                    std.mem.doNotOptimizeAway(out[0..written]);
                },
            };
        }
        if (sample >= warmups) elapsed[sample - warmups] = timer.read();
    }
    std.mem.sortUnstable(u64, &elapsed, {}, std.sort.asc(u64));
    var digest: [8]u8 = undefined;
    std.mem.writeInt(u64, &digest, hash.final(), .little);
    return .{
        .ns_per_item = @as(f64, @floatFromInt(elapsed[samples / 2])) /
            @as(f64, @floatFromInt(repeats * input_count)),
        .digest = std.fmt.bytesToHex(digest, .lower),
    };
}

pub fn main(init: std.process.Init) !u8 {
    const shapes = makeShapes();
    const deadline = io.Deadline.fromNowMs(120_000);
    const projection = try measure(.snap_projection, &shapes, deadline);
    const encode = try measure(.polyline_encode, &shapes, deadline);
    var buffer: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .benchmark = "cpu_kernels",
        .arch = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .cpu = builtin.cpu.model.name,
        .samples = samples,
        .repeats = repeats,
        .snap_projection = projection,
        .polyline_encode = encode,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    return 0;
}
