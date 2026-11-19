const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const edge = build.edges;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input = args.next() orelse return usage();
    const scratch = args.next() orelse return usage();
    const workers = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 0;
    if (args.next() != null) return usage();

    const file = try io.File.open(input, .read_only);
    defer file.close();
    const edges = try io.File.temporary(scratch);
    defer edges.close();
    const shapes = try io.File.temporary(scratch);
    defer shapes.close();
    const start = io.Timer.start();
    const stats = try edge.build(init.gpa, try build.pbf.file.Stream.init(file), .{
        .edges = edges,
        .shapes = shapes,
    }, .{ .scratch_dir = scratch, .workers = workers }, {}, ignoreWay);

    var buf: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buf);
    try std.json.Stringify.value(.{
        .stats = stats,
        .elapsed_ns = start.read(),
        .edge_bytes = try edges.size(),
        .shape_bytes = try shapes.size(),
        .edge_hash = try checksum(edges),
        .shape_hash = try checksum(shapes),
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn checksum(file: io.File) !u64 {
    if (try file.size() == 0) return std.hash.Wyhash.hash(0, "");
    const mapped = try io.Mapping.mapFd(file, .read_only);
    defer mapped.unmap();
    return std.hash.Wyhash.hash(0, mapped.bytes);
}

fn ignoreWay(_: void, _: i64, _: build.tags.WayAttrs, _: build.pbf.block.TagIterator) !void {}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build check-edges -- INPUT.osm.pbf SCRATCH_DIR [WORKERS]\n", .{});
    return error.InvalidArguments;
}
