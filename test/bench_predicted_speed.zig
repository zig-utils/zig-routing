//! Measure warm SIMD speed throughput and dependent lookup latency.
const std = @import("std");
const routing = @import("routing");
const codec_mod = routing.traffic.predicted_codec;
const io = routing.infra.io;

pub fn main(init: std.process.Init) !void {
    const deadline = io.Deadline.fromNowMs(30_000);
    const codec = try codec_mod.Codec.init(deadline);
    var profile: codec_mod.Profile = undefined;
    profile[0] = 2245;
    for (profile[1..], 1..) |*value, i| value.* = @as(i16, @intCast((i * 29 + 31) % 227)) - 112;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    var buf: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buf);
    if (args.next()) |encoded| {
        if (args.next() != null) return error.InvalidArguments;
        profile = try codec_mod.decode(encoded, deadline);
        const stored = codec_mod.StoredProfile.init(profile);
        for (0..codec_mod.bucket_count) |bucket| {
            const speed = codec.decodeBucket(&stored, @intCast(bucket));
            try output.interface.print("{d:.8}\n", .{speed});
        }
        try output.interface.flush();
        return;
    }

    const stored = codec_mod.StoredProfile.init(profile);
    for (0..codec_mod.bucket_count) |bucket| {
        std.mem.doNotOptimizeAway(codec.decodeBucket(&stored, @intCast(bucket)));
    }
    const iterations = 250_000;
    const seconds_per_week = codec_mod.bucket_count * codec_mod.bucket_seconds;
    var dependent: [9]u64 = undefined;
    var independent: [9]u64 = undefined;
    var hot_window: [9]u64 = undefined;
    // Compare a small cache-resident time window with the full weekly basis.
    for (&dependent, &independent, &hot_window) |*chain_time, *batch_time, *hot_time| {
        if (deadline.expired()) return error.DeadlineExceeded;
        var prior: u32 = 0;
        const start = io.Timer.start();
        for (0..iterations) |i| {
            const seconds = (@as(u32, @intCast(i)) * 9297 +% prior) % seconds_per_week;
            prior = @bitCast(codec.speed(&stored, seconds));
        }
        std.mem.doNotOptimizeAway(prior);
        chain_time.* = start.read();
        const batch_start = io.Timer.start();
        for (0..iterations) |i| {
            const seconds = i * 9297 % seconds_per_week;
            std.mem.doNotOptimizeAway(codec.speed(&stored, seconds));
        }
        batch_time.* = batch_start.read();
        prior = 0;
        const hot_start = io.Timer.start();
        for (0..iterations) |i| {
            const bucket = 832 + ((@as(u32, @intCast(i)) +% prior) & 15);
            prior = @bitCast(codec.speed(&stored, @as(u64, bucket) * codec_mod.bucket_seconds));
        }
        std.mem.doNotOptimizeAway(prior);
        hot_time.* = hot_start.read();
    }
    std.mem.sort(u64, &dependent, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &independent, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, &hot_window, {}, comptime std.sort.asc(u64));
    const per_lookup = @as(f64, @floatFromInt(independent[independent.len / 2])) / iterations;
    const dependent_lookup = @as(f64, @floatFromInt(dependent[dependent.len / 2])) / iterations;
    const hot_lookup = @as(f64, @floatFromInt(hot_window[hot_window.len / 2])) / iterations;
    try output.interface.print(
        "warm_weekly_buckets {d}\nsimd_ns_per_lookup {d:.3}\ndependent_simd_ns_per_lookup {d:.3}\ncache_resident_dependent_ns_per_lookup {d:.3}\n",
        .{ codec_mod.bucket_count, per_lookup, dependent_lookup, hot_lookup },
    );
    try output.interface.flush();
    if (per_lookup >= 30) return error.PredictedDecodeBudgetExceeded;
}
