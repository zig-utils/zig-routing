//! Verify all directed edge keys and time shuffled warm lookups on a bundle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    if (args.next() != null) return error.InvalidArguments;

    var bundle = try routing.graph.reader.Bundle.openVerified(path, .none, null);
    defer bundle.close();
    const index = bundle.view.edge_key_index orelse return error.MissingEdgeKeys;
    if (index.records.len == 0) return error.EmptyGraph;
    for (0..bundle.view.edges.len) |id| {
        const edge: routing.graph.format.EdgeId = @fromBackingInt(@as(u32, @intCast(id)));
        if (try index.find(try index.key(edge)) != edge) return error.EdgeKeyRoundTripFailed;
    }

    const samples = try init.arena.allocator().alloc(routing.graph.edge_keys.Key, index.records.len);
    for (index.records, samples) |row, *sample| sample.* = row.key;
    var random = std.Random.DefaultPrng.init(196);
    random.random().shuffle(routing.graph.edge_keys.Key, samples);
    const repeats = std.math.divCeil(usize, 250_000, samples.len) catch unreachable;
    var elapsed: [11]u64 = undefined;
    for (&elapsed) |*measurement| {
        const timer = io.Timer.start();
        for (0..repeats) |_| {
            for (samples) |sample| {
                const found = (try index.find(sample)) orelse return error.EdgeKeyNotFound;
                std.mem.doNotOptimizeAway(found);
            }
        }
        measurement.* = timer.read();
    }
    std.mem.sort(u64, &elapsed, {}, comptime std.sort.asc(u64));
    const lookups = repeats * samples.len;
    const median_ns = @as(f64, @floatFromInt(elapsed[elapsed.len / 2])) / @as(f64, @floatFromInt(lookups));
    var buf: [1024]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buf);
    try output.interface.print("method {s}\nround_trips {d}\nlookups_per_batch {d}\nbatches {d}\nmedian_ns_per_lookup {d:.2}\n", .{
        if (index.hash == null) "binary_search" else "minimal_perfect_hash", samples.len, lookups, elapsed.len, median_ns,
    });
    try output.interface.flush();
    if (median_ns >= 200) return error.EdgeKeyLookupBudgetExceeded;
}
