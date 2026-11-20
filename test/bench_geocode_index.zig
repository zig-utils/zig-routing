//! Measure warm prefix lookup and index size on a previously built bundle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const geocode = routing.geocode;

const Query = struct { field: geocode.index.Field, prefix: []const u8 };

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingGeocodeBundle;
    if (args.next() != null) return error.UnexpectedArgument;
    const a = init.arena.allocator();
    const dir = try io.Directory.open(path);
    defer dir.close();
    var bundle = try geocode.bundle.Bundle.openInDir(dir, .none);
    defer bundle.close();
    var index = try geocode.index.Index.open(dir, bundle.uuid, .none);
    defer index.close();
    if (index.view.header.analyzed_bytes == 0) return error.EmptyGeocodeIndex;

    const scratch = try a.alloc(u8, index.view.scratchBytes());
    var queries: std.ArrayList(Query) = .empty;
    for (std.enums.values(geocode.index.Field)) |field| {
        const span = index.view.header.field_blocks[@backingInt(field)];
        var terms: usize = 0;
        for (try span.get(index.view.blocks)) |block| terms += block.attr.terms;
        const stride = @max(1, terms / 256);
        var iterator = try index.view.prefix(field, "", scratch, .none);
        var ordinal: usize = 0;
        while (try iterator.next(.none)) |term| : (ordinal += 1) {
            if (ordinal % stride != 0) continue;
            var prefix = @min(term.text.len, 1 + (ordinal / stride) % 8);
            while (prefix < term.text.len and term.text[prefix] & 0xc0 == 0x80) : (prefix += 1) {}
            try queries.append(a, .{ .field = field, .prefix = try a.dupe(u8, term.text[0..prefix]) });
        }
    }
    const input = queries.items;
    if (input.len == 0) return error.EmptyGeocodeIndex;
    var state = std.Random.DefaultPrng.init(221);
    state.random().shuffle(Query, input);
    for (input) |query| {
        var cursor = try index.view.prefix(query.field, query.prefix, scratch, .none);
        _ = try cursor.next(.none) orelse return error.MissingGeocodePrefix;
    }
    const rounds = 64;
    const times = try a.alloc(u64, input.len * rounds);
    var total: u64 = 0;
    for (0..rounds) |r| {
        for (input, times[r * input.len ..][0..input.len]) |query, *sample| {
            const timer = io.Timer.start();
            var cursor = try index.view.prefix(query.field, query.prefix, scratch, .none);
            const found = try cursor.next(.none) orelse return error.MissingGeocodePrefix;
            sample.* = timer.read();
            if (!std.mem.startsWith(u8, found.text, query.prefix)) return error.InvalidGeocodePrefix;
            std.mem.doNotOptimizeAway(found.list.count);
            total += sample.*;
        }
    }
    std.mem.sortUnstable(u64, times, {}, std.sort.asc(u64));
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(times.len));
    const p95 = times[(times.len - 1) * 95 / 100];
    const ratio = @as(f64, @floatFromInt(index.mapping.bytes.len)) / @as(f64, @floatFromInt(index.view.header.analyzed_bytes));
    const json = try std.json.Stringify.valueAlloc(a, .{
        .prefixes = input.len,
        .lookups = times.len,
        .mean_ns = mean,
        .p50_ns = times[(times.len - 1) / 2],
        .p95_ns = p95,
        .p99_ns = times[(times.len - 1) * 99 / 100],
        .index_bytes = index.mapping.bytes.len,
        .analyzed_bytes = index.view.header.analyzed_bytes,
        .size_fraction = ratio,
        .terms = index.view.header.terms,
        .postings = index.view.header.postings,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
    if (p95 >= 1_000) return error.GeocodePrefixBudgetExceeded;
    if (ratio > 0.4) return error.GeocodeIndexSizeBudgetExceeded;
}
