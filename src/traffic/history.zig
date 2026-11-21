//! Aggregate anonymous edge traversals into Valhalla weekly speed profiles.
const std = @import("std");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const codec = @import("predicted_codec.zig");
const ingest = @import("predicted_ingest.zig");

const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const Deadline = io.Deadline;
const bucket_count = codec.bucket_count;
const max_kph = graph.constants.max_assumed_speed;
const road_classes = 8;

pub const Sample = struct {
    edge: EdgeId,
    bucket: u11,
    kph: f32,

    fn key(_: void, self: Sample) u64 {
        return (@as(u64, @backingInt(self.edge)) << 11) | self.bucket;
    }
};

pub const Coverage = struct {
    road_class: graph.constants.RoadClass,
    graph_edges: u64 = 0,
    profiled_edges: u64 = 0,
    observed_buckets: u64 = 0,
    supported_buckets: u64 = 0,
    samples: u64 = 0,
    retained_samples: u64 = 0,
    confidence: f64 = 0,
};

pub const Fit = struct {
    profiles: []const ingest.GeneratedProfile,
    coverage: [road_classes]Coverage,

    pub fn deinit(self: Fit, a: Allocator) void {
        a.free(self.profiles);
    }
};

const Bin = struct {
    count: u64 = 0,
    speeds: f64 = 0,
};

const Robust = struct {
    speed: f32,
    retained: u64,
};

/// Tukey fences reject implausible observations while keeping the
/// average of the surviving speeds at their original precision.
fn robustMean(samples: []const Sample, minimum: u32, deadline: Deadline) !?Robust {
    var bins: [max_kph + 1]Bin = @splat(.{});
    for (samples, 0..) |sample, index| {
        if (index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!(sample.kph >= 1 and sample.kph <= max_kph)) return error.InvalidHistoricalSpeed;
        const bin: usize = @intFromFloat(@round(sample.kph));
        bins[bin].count += 1;
        bins[bin].speeds += sample.kph;
    }
    if (samples.len < minimum) return null;
    const rank = samples.len - 1;
    const low = quantile(&bins, rank / 4);
    const high = quantile(&bins, rank - rank / 4);
    const spread = @max(3, (high - low) * 3 / 2);
    const start = low -| spread;
    const end = @min(max_kph, high + spread);
    var retained: u64 = 0;
    var sum: f64 = 0;
    for (bins[start .. end + 1]) |bin| {
        retained += bin.count;
        sum += bin.speeds;
    }
    if (retained < minimum) return null;
    return .{ .speed = @floatCast(sum / @as(f64, @floatFromInt(retained))), .retained = retained };
}

fn quantile(bins: *const [max_kph + 1]Bin, rank: usize) usize {
    var passed: u64 = 0;
    for (bins, 0..) |bin, speed| {
        passed += bin.count;
        if (passed > rank) return speed;
    }
    unreachable;
}

const Static = struct {
    speeds: [road_classes][2]Bin = @splat(@splat(.{})),

    fn add(self: *Static, road_class: u3, edge: graph.format.EdgeHot) void {
        for (&self.speeds[road_class], edge.speed[1..3]) |*out, stored| {
            const effective = if (stored == 0) edge.speed[0] else stored;
            if (effective == 0) continue;
            out.speeds += @floatFromInt(@min(max_kph, effective));
            out.count += 1;
        }
    }

    fn speed(self: Static, road_class: u3, edge: graph.format.EdgeHot, bucket: usize) f32 {
        const local_hour = (bucket * codec.bucket_seconds / std.time.s_per_hour) % 24;
        const slot: usize = @intFromBool(local_hour >= 7 and local_hour < 19);
        const posted = edge.speed[1 + slot];
        if (posted != 0) return @floatFromInt(@min(max_kph, posted));
        const class = self.speeds[road_class][slot];
        if (class.count == 0) return @floatFromInt(@max(1, @min(max_kph, edge.speed[0])));
        return @floatCast(class.speeds / @as(f64, @floatFromInt(class.count)));
    }
};

pub fn fit(a: Allocator, view: *const View, samples: []Sample, minimum_samples: u32, deadline: Deadline) !Fit {
    if (minimum_samples < 3) return error.InvalidHistoricalSampleMinimum;
    var coverage: [road_classes]Coverage = undefined;
    for (&coverage, 0..) |*stats, index|
        stats.* = .{ .road_class = @fromBackingInt(@as(u8, @intCast(index))) };
    var static: Static = .{};
    for (view.edges, 0..) |edge, index| {
        if (index % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const class = try view.class(edge.cls.class_id);
        if (!class.forwardAccess().auto or class.flags.node_connector) continue;
        coverage[class.category.road_class].graph_edges += 1;
        static.add(class.category.road_class, edge);
    }

    const scratch = try a.alloc(Sample, samples.len);
    defer a.free(scratch);
    try radix.sortByU64(Sample, a, samples, scratch, {}, Sample.key, deadline);
    const projection = try codec.Codec.init(deadline);
    var profiles: std.ArrayList(ingest.GeneratedProfile) = .empty;
    errdefer profiles.deinit(a);
    var offset: usize = 0;
    while (offset < samples.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const id = samples[offset].edge;
        const edge = try view.edge(id);
        const class = try view.class(edge.cls.class_id);
        const attrs = &coverage[class.category.road_class];
        var speeds: [bucket_count]f32 = @splat(0);
        var supported: usize = 0;
        while (offset < samples.len and samples[offset].edge == id) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const first = offset;
            const bucket = samples[offset].bucket;
            if (bucket >= bucket_count) return error.InvalidHistoricalBucket;
            while (offset < samples.len and samples[offset].edge == id and samples[offset].bucket == bucket) : (offset += 1) {
                if (offset % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            }
            attrs.observed_buckets += 1;
            attrs.samples += offset - first;
            if (try robustMean(samples[first..offset], minimum_samples, deadline)) |mean| {
                speeds[bucket] = mean.speed;
                supported += 1;
                attrs.retained_samples += mean.retained;
            }
        }
        if (supported == 0) continue;
        attrs.profiled_edges += 1;
        attrs.supported_buckets += supported;
        var smoothed: [bucket_count]f32 = undefined;
        for (&smoothed, speeds, 0..) |*out, centre, bucket| {
            if (bucket % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (centre == 0) {
                out.* = static.speed(class.category.road_class, edge.*, bucket);
                continue;
            }
            const left = speeds[(bucket + bucket_count - 1) % bucket_count];
            const right = speeds[(bucket + 1) % bucket_count];
            const weight: f32 = @floatFromInt(2 + @as(u3, @intFromBool(left != 0)) + @intFromBool(right != 0));
            out.* = (2 * centre + left + right) / weight;
        }
        try profiles.append(a, .{ .edge = id, .coefficients = try projection.compress(&smoothed, deadline) });
    }
    for (&coverage) |*stats| {
        if (stats.samples != 0)
            stats.confidence = @as(f64, @floatFromInt(stats.retained_samples)) / @as(f64, @floatFromInt(stats.samples));
    }
    return .{ .profiles = try profiles.toOwnedSlice(a), .coverage = coverage };
}

test "historical sample floors and robust speed estimates" {
    const id: EdgeId = @fromBackingInt(0);
    const speeds = [_]f32{ 46.8, 47.2, 47.6, 48.4, 125 };
    var samples: [speeds.len]Sample = undefined;
    for (&samples, speeds) |*sample, value| sample.* = .{ .edge = id, .bucket = 0, .kph = value };
    try std.testing.expectEqual(null, try robustMean(samples[0..2], 3, .none));
    const mean = (try robustMean(&samples, 3, .none)).?;
    try std.testing.expectEqual(4, mean.retained);
    try std.testing.expectApproxEqAbs(47.5, mean.speed, 0.01);
}
