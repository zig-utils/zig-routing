const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const build = routing.build;
const edge = build.edges;
const class_table = routing.graph.class_table;

const WayClasses = struct {
    by_direction: [2]class_table.EdgeClass,
    oneway: bool,
};

const Collector = struct {
    allocator: std.mem.Allocator,
    drive_side: build.edge_class.DriveSide,
    ways: std.AutoHashMapUnmanaged(i64, WayClasses) = .empty,

    fn collect(self: *Collector, id: i64, attrs: build.tags.WayAttrs, _: build.pbf.block.TagIterator) !void {
        try self.ways.put(self.allocator, id, .{
            .by_direction = .{
                try build.edge_class.fromWay(attrs, true, self.drive_side),
                try build.edge_class.fromWay(attrs, false, self.drive_side),
            },
            .oneway = attrs.flags.oneway,
        });
    }

    fn count(self: *Collector, file: io.File, edge_count: usize) !struct { classes: usize, hash: u64 } {
        const mapped = try io.Mapping.mapFd(file, .read_only);
        defer mapped.unmap();
        const records = try mapped.slice(edge.Edge, 0, edge_count);
        var table = class_table.Interner.init(self.allocator);
        defer table.deinit();
        for (records) |segment| {
            const way = self.ways.get(segment.way_id) orelse return error.MissingWayAttributes;
            for (way.by_direction, 0..) |base, direction| {
                var directed = base;
                build.edge_class.applySegmentControls(&directed, segment.flags, direction == 0, way.oneway);
                _ = try table.intern(directed);
            }
        }
        var sorted = try table.finish(.none);
        defer sorted.deinit();
        return .{ .classes = sorted.classes.len, .hash = std.hash.XxHash3.hash(0, std.mem.sliceAsBytes(sorted.classes)) };
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input = args.next() orelse return usage();
    const scratch = args.next() orelse return usage();
    const workers = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 0;
    const drive_side = if (args.next()) |text|
        std.meta.stringToEnum(build.edge_class.DriveSide, text) orelse return usage()
    else
        .right;
    if (args.next() != null) return usage();

    const file = try io.File.open(input, .read_only);
    defer file.close();
    const edges = try io.File.temporary(scratch);
    defer edges.close();
    const shapes = try io.File.temporary(scratch);
    defer shapes.close();
    var collector: Collector = .{ .allocator = init.gpa, .drive_side = drive_side };
    defer collector.ways.deinit(init.gpa);
    const start = io.Timer.start();
    const stats = try edge.build(init.gpa, try build.pbf.file.Stream.init(file), .{
        .edges = edges,
        .shapes = shapes,
    }, .{ .scratch_dir = scratch, .workers = workers }, &collector, Collector.collect);
    const elapsed_ns = start.read();
    const classes = try collector.count(edges, @intCast(stats.edges));

    var buf: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buf);
    try std.json.Stringify.value(.{
        .stats = stats,
        .elapsed_ns = elapsed_ns,
        .edge_bytes = try edges.size(),
        .shape_bytes = try shapes.size(),
        .edge_hash = try checksum(edges),
        .shape_hash = try checksum(shapes),
        .drive_side = drive_side,
        .distinct_classes = classes.classes,
        .class_hash = classes.hash,
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

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build check-edges -- INPUT.osm.pbf SCRATCH_DIR [WORKERS] [right|left]\n", .{});
    return error.InvalidArguments;
}
