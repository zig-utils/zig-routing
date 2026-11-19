// Ported from src/mjolnir/elevationbuilder.cc and src/skadi/util.cc
// (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const line = @import("../geo/line.zig");
const build_math = @import("../geo/build_math.zig");
const dem = @import("../elevation/root.zig");
const format = @import("../graph/format.zig");
const Allocator = std.mem.Allocator;

pub const posting_interval = 60.0;
const minimum_length = 10;
const no_data = dem.hgt.no_data_value;

pub const Source = union(enum) {
    tiles: []const u8,
    catalog: *const dem.hgt.Tiles,
    pack: *const dem.@"packed".Pack,
};

pub const Coverage = struct {
    dem_configured: bool = false,
    total_edges: u64 = 0,
    fully_covered: u64 = 0,
    partially_covered: u64 = 0,
    missing: u64 = 0,
    postings: u64 = 0,
    valid_postings: u64 = 0,

    pub fn add(self: *Coverage, stamp: Stamp) void {
        if (stamp.valid_samples == 0) {
            self.missing += 1;
        } else if (stamp.valid_samples == stamp.samples) {
            self.fully_covered += 1;
        } else {
            self.partially_covered += 1;
        }
        self.total_edges += 1;
        self.postings += stamp.samples;
        self.valid_postings += stamp.valid_samples;
    }

    pub fn merge(self: *Coverage, other: Coverage) void {
        self.total_edges += other.total_edges;
        self.fully_covered += other.fully_covered;
        self.partially_covered += other.partially_covered;
        self.missing += other.missing;
        self.postings += other.postings;
        self.valid_postings += other.valid_postings;
    }
};

pub const Directed = struct {
    grade: u4 = 6,
    slopes: format.Slopes = format.Slopes.flat,
};

pub const Stamp = struct {
    directed: [2]Directed = @splat(.{}),
    mean: i16 = -500,
    samples: u32 = 0,
    valid_samples: u32 = 0,
};

pub const Profile = struct {
    weight: f64,
    up: f64,
    down: f64,
    mean: f64,
    valid: u32,
};

fn weighted(heights: []const f64, distance: f64, reverse: bool, deadline: io.Deadline) !Profile {
    const scale = 100.0 / distance;
    var sum: f64 = 0;
    var total_weight: f64 = 0;
    var up: f64 = 0;
    var down: f64 = 0;
    var elevation: f64 = 0;
    var valid: u32 = 0;
    var previous = heights[if (reverse) heights.len - 1 else 0];
    if (previous != no_data) {
        elevation = previous;
        valid += 1;
    }
    for (1..heights.len) |i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const current = heights[if (reverse) heights.len - 1 - i else i];
        const grade = if (previous == no_data or current == no_data) 0.0 else (current - previous) * scale;
        if (current != no_data) {
            elevation += current;
            valid += 1;
        }
        up = @max(up, grade);
        down = @min(down, grade);
        const limited = std.math.clamp(grade, -10.0, 15.0);
        const weight = 1.0 + limited / @as(f64, if (limited > 0) 7.0 else 17.0);
        sum += limited * weight;
        total_weight += weight;
        previous = current;
    }
    return .{
        .weight = sum * (1.0 / total_weight),
        .up = up,
        .down = down,
        .mean = if (valid == 0) no_data else elevation / @as(f64, @floatFromInt(valid)),
        .valid = valid,
    };
}

fn meanElevation(mean: f64) i16 {
    const lowered: f32 = @floatCast(mean);
    const bin: i16 = @intFromFloat(@min(4095, @max(0, (lowered + 500) / 2)));
    return -500 + bin * 2;
}

fn slope(value: f32) u5 {
    if (value < 16) return @intFromFloat(@ceil(@max(0, value)));
    if (value < 76) return 0x10 | @as(u5, @intFromFloat(@ceil((value - 16) * 0.25)));
    return 0x1f;
}

fn directed(profile: Profile, interpolate: bool) Directed {
    const grade: u4 = @intFromFloat(std.math.clamp(profile.weight * 0.6 + 6.5, 0, 15));
    const up: f32 = @floatCast(profile.up);
    const down: f32 = @floatCast(-profile.down);
    return .{
        .grade = if (interpolate) std.math.clamp(grade, 4, 8) else grade,
        .slopes = format.Slopes.init(slope(if (interpolate) @min(up, 3) else up), slope(if (interpolate) @min(down, 3) else down)),
    };
}

pub const Work = struct {
    allocator: Allocator,
    points: std.ArrayList(geo.PointLL) = .empty,
    heights: std.ArrayList(f64) = .empty,
    deadline: io.Deadline,

    pub fn deinit(self: *Work) void {
        self.points.deinit(self.allocator);
        self.heights.deinit(self.allocator);
    }

    pub fn measure(self: *Work, shape: []const geo.FixedLL, length_m: u24, interpolate: bool, sampler: anytype) !Stamp {
        if (shape.len < 2) return error.InvalidSegmentShape;
        try self.points.resize(self.allocator, shape.len);
        self.heights.clearRetainingCapacity();
        for (shape, self.points.items, 0..) |fixed, *point, i| {
            if (i % 256 == 0) try self.check();
            point.* = fixed.toTilePoint();
        }

        const Sink = struct {
            work: *Work,
            sampler: @TypeOf(sampler),
            interpolate: bool,

            pub fn check(sink: *const @This()) !void {
                try sink.work.check();
            }

            pub fn emit(sink: *const @This(), point: geo.PointLL) !void {
                if (sink.work.heights.items.len % 256 == 0) try sink.check();
                const height = if (sink.interpolate) no_data else sink.sampler.get(point);
                try sink.work.heights.append(sink.work.allocator, height);
            }
        };
        const sink: Sink = .{ .work = self, .sampler = sampler, .interpolate = interpolate };
        try line.visitResampledSphericalWith(self.points.items, posting_interval, false, &sink, build_math);
        try sink.emit(self.points.items[self.points.items.len - 1]);
        const heights = self.heights.items;

        if (interpolate) {
            const first = sampler.get(self.points.items[0]);
            const last = sampler.get(self.points.items[self.points.items.len - 1]);
            heights[0] = first;
            heights[heights.len - 1] = last;
            if (first != no_data and last != no_data) {
                const step: f32 = @floatCast((last - first) / @as(f64, @floatFromInt(heights.len)));
                for (1..heights.len) |i| {
                    if (i % 256 == 0) try self.check();
                    heights[i] = heights[i - 1] + @as(f64, step);
                }
            }
        }

        const samples = std.math.cast(u32, heights.len) orelse return error.TooManyElevationSamples;
        const forward = try weighted(heights, posting_interval, false, self.deadline);
        var result: Stamp = .{ .samples = samples, .valid_samples = forward.valid, .mean = meanElevation(forward.mean) };
        if (length_m < minimum_length or (interpolate and forward.valid < 2)) return result;
        result.directed[0] = directed(forward, interpolate);
        result.directed[1] = directed(try weighted(heights, posting_interval, true, self.deadline), interpolate);
        return result;
    }

    fn check(self: *const Work) error{DeadlineExceeded}!void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
    }
};

pub fn tileKey(first: geo.FixedLL) u32 {
    return @min(dem.hgt.tile_count, dem.hgt.tileIndex(first.toTilePoint()));
}

test "Valhalla energy weighting and mean elevation ignore voids" {
    const testing = std.testing;
    const up_weight = 1.0 + 15.0 / 7.0;
    const down_weight = 1.0 - 10.0 / 17.0;
    const symmetric = try weighted(&.{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 }, 1.0, false, .none);
    try testing.expectApproxEqAbs((15.0 * up_weight - 10.0 * down_weight) / (up_weight + down_weight), symmetric.weight, 0.00001);
    const downhill = try weighted(&.{ 0, 1, 0, -1, -2 }, 1.0, false, .none);
    try testing.expectApproxEqAbs((15.0 * up_weight - 30.0 * down_weight) / (up_weight + 3.0 * down_weight), downhill.weight, 0.00001);
    try testing.expectEqual(100.0, downhill.up);
    try testing.expectEqual(-100.0, downhill.down);
    try testing.expectEqual(7.5, (try weighted(&.{ 0, 15, no_data }, 1.0, false, .none)).mean);
    try testing.expectEqual(no_data, (try weighted(&.{ no_data, no_data }, 1.0, false, .none)).mean);
}

test "elevation stamps direction, short edges and bridge cutoffs" {
    const testing = std.testing;
    const Fixture = struct {
        last: f64,
        fn get(self: @This(), p: geo.PointLL) f64 {
            return if (p.lng == 0) 100 else self.last;
        }
    };
    const shape = [_]geo.FixedLL{ .{ .lng = 0, .lat = 0 }, .{ .lng = 2000, .lat = 0 } };
    var work: Work = .{ .allocator = testing.allocator, .deadline = .none };
    defer work.deinit();
    const sampler: Fixture = .{ .last = 106 };
    const road = try work.measure(&shape, 22, false, sampler);
    try testing.expectEqual(102, road.mean);
    try testing.expectEqual(12, road.directed[0].grade);
    try testing.expectEqual(0, road.directed[1].grade);
    try testing.expectEqual(10, road.directed[0].slopes.maxUp());
    try testing.expectEqual(-10, road.directed[1].slopes.maxDown());
    const short = try work.measure(&shape, 9, false, sampler);
    try testing.expectEqual(@as(Directed, .{}), short.directed[0]);
    try testing.expectEqual(road.mean, short.mean);
    const bridge = try work.measure(&shape, 22, true, sampler);
    try testing.expectEqual(8, bridge.directed[0].grade);
    try testing.expectEqual(4, bridge.directed[1].grade);
    try testing.expectEqual(3, bridge.directed[0].slopes.maxUp());
    try testing.expectEqual(-3, bridge.directed[1].slopes.maxDown());
    const partial = try work.measure(&shape, 22, true, Fixture{ .last = no_data });
    try testing.expectEqual(@as(Directed, .{}), partial.directed[0]);
    try testing.expectEqual(1, partial.valid_samples);
}
