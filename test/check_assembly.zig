const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const graph = routing.graph;
const open_budget_ns = 50 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input = args.next() orelse return usage();
    const output = args.next() orelse return usage();
    const scratch = args.next() orelse return usage();
    const workers = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 0;
    const drive_side = if (args.next()) |text|
        std.meta.stringToEnum(build.edge_class.DriveSide, text) orelse return usage()
    else
        .right;
    if (args.next() != null) return usage();

    const file = try io.File.open(input, .read_only);
    defer file.close();
    const uuid = try datasetId(file, drive_side);
    var writer = try graph.format.BundleWriter.init(output, uuid, .none);
    defer writer.deinit();

    const timer = io.Timer.start();
    const stats = try build.assemble.build(init.gpa, try build.pbf.file.Stream.init(file), &writer, .{
        .scratch_dir = scratch,
        .drive_side = drive_side,
        .workers = workers,
    });
    try writer.commit();
    const elapsed_ns = timer.read();
    {
        var warm = try graph.reader.Bundle.open(output);
        defer warm.close();
        try warm.view.verify(.none, null);
        try build.assemble.validate(warm.view.first_edge, warm.view.edges, warm.view.coordinates.?, warm.view.classes.?, .none);
    }

    var times: [32]u64 = undefined;
    for (&times) |*sample| {
        const start = io.Timer.start();
        var bundle = try graph.reader.Bundle.open(output);
        sample.* = start.read();
        bundle.close();
    }
    std.mem.sortUnstable(u64, &times, {}, std.sort.asc(u64));

    var buf: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buf);
    try std.json.Stringify.value(.{
        .stats = stats,
        .elapsed_ns = elapsed_ns,
        .edges_per_second = rate(stats.directed_edges, stats.assembly_ns),
        .peak_rss_bytes = try io.peakRssBytes(),
        .warm_open_median_ns = times[times.len / 2],
        .warm_open_max_ns = times[times.len - 1],
        .validation_errors = @as(u32, 0),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (times[times.len - 1] >= open_budget_ns) return error.BundleOpenTooSlow;
}

fn datasetId(file: io.File, side: build.edge_class.DriveSide) !graph.format.DatasetUuid {
    const mapped = try io.Mapping.mapFd(file, .read_only);
    defer mapped.unmap();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(side));
    hash.update(mapped.bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var id = digest[0..16].*;
    id[6] = (id[6] & 0x0f) | 0x80;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

fn rate(count: u32, ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) * std.time.ns_per_s / @as(f64, @floatFromInt(@max(ns, 1)));
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build check-assembly -- INPUT.osm.pbf OUTPUT_BUNDLE SCRATCH_DIR [WORKERS] [right|left]\n", .{});
    return error.InvalidArguments;
}
