//! Compare transit costing against samples emitted by the pinned Valhalla library.
const std = @import("std");
const routing = @import("routing");
const costing = routing.costing;
const io = routing.infra.io;
const transit = routing.graph.transit;
const Use = routing.graph.constants.Use;
const Cost = costing.compiled.Cost;

const Sample = struct {
    options: std.json.Value,
    use: Use,
    departure: u32,
    current: u32,
    elapsed: u32,
    from_walk: bool,
    warnings: usize,
    mode_factor: f32,
    walking_factor: f32,
    walking_limit: u32,
    transfer_limit: u32,
    use_bus: f32,
    use_rail: f32,
    use_transfers: f32,
    wheelchair: bool,
    bicycle: bool,
    edge: Cost,
    transition: Cost,
    transfer: Cost,
    default_transfer: Cost,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingReference;
    if (args.next() != null) return error.ExtraArguments;
    const input = try io.Mapping.mapFile(path, .read_only);
    defer input.unmap();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var count: usize = 0;
    var max_error: f64 = 0;
    var lines = std.mem.tokenizeScalar(u8, input.bytes, '\n');
    while (lines.next()) |line| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const sample = (try std.json.parseFromSlice(Sample, a, line, .{})).value;
        var warnings: std.ArrayList(costing.base.Warning) = .empty;
        const options = try costing.multimodal.parse(a, sample.options, &warnings, .none);
        const profile = try costing.transit.Profile.init(options.transit);
        count += 1;
        if (warnings.items.len != sample.warnings or
            profile.mode_factor != sample.mode_factor or options.pedestrian.mode_factor != sample.walking_factor or
            options.pedestrian.transit_start_end_max_distance != sample.walking_limit or
            options.pedestrian.transit_transfer_max_distance != sample.transfer_limit or
            options.transit.use_bus != sample.use_bus or options.transit.use_rail != sample.use_rail or
            options.transit.use_transfers != sample.use_transfers or profile.flags.wheelchair != sample.wheelchair or
            profile.flags.bicycle != sample.bicycle)
        {
            std.debug.print("Transit option mismatch on sample {d}\n{s}\n", .{ count, line });
            return error.OptionParityMismatch;
        }
        const departure: transit.Departure = .{
            .line = 0,
            .route = 0,
            .trip = 1,
            .block = 0,
            .schedule = 0,
            .start_time = sample.departure,
            .elapsed_time = sample.elapsed,
            .flags = .{ .wheelchair = true, .bicycle = true },
        };
        const match: transit.NextDeparture = .{ .departure = &departure, .time = sample.departure };
        try compare(count, "edge", profile.edgeCost(sample.use, match, sample.current), sample.edge, &max_error);
        try compare(count, "transition", profile.transitionCost(sample.use, sample.from_walk), sample.transition, &max_error);
        try compare(count, "transfer", profile.transferCost(), sample.transfer, &max_error);
        try compare(count, "default transfer", profile.defaultTransferCost(), sample.default_transfer, &max_error);
    }
    if (count == 0) return error.EmptyReference;
    std.debug.print("{d} option samples, {d} costing calls, max relative error {e}\n", .{ count, count * 4, max_error });
}

fn compare(row: usize, kind: []const u8, actual: Cost, expected: Cost, max_error: *f64) !void {
    const delta = @max(relative(actual.cost, expected.cost), relative(actual.secs, expected.secs));
    if (delta > 1e-5) {
        std.debug.print("Sample {d} {s}: expected ({d}, {d}), got ({d}, {d})\n", .{
            row, kind, expected.cost, expected.secs, actual.cost, actual.secs,
        });
        return error.CostParityMismatch;
    }
    max_error.* = @max(max_error.*, delta);
}

fn relative(actual: f32, expected: f32) f64 {
    if (actual == expected) return 0;
    if (!std.math.isFinite(actual) or !std.math.isFinite(expected) or expected == 0)
        return std.math.inf(f64);
    return @abs(@as(f64, actual) - expected) / @abs(@as(f64, expected));
}
