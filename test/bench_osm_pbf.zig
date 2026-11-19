//! OSM PBF indexing and inflate throughput over a real extract.

const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const file = routing.build.pbf.file;

const Scan = struct {
    blocks: usize = 0,
    bytes: usize = 0,
    digest: u64 = 0,

    fn collect(self: *Scan, i: usize, data: []const u8) !void {
        self.blocks += 1;
        self.bytes += data.len;
        if (data.len != 0) self.digest +%= i + data[0] + data[data.len - 1];
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return usage();
    const workers = try std.fmt.parseInt(usize, args.next() orelse return usage(), 10);
    const passes = try std.fmt.parseInt(usize, args.next() orelse "1", 10);
    if (passes == 0 or args.next() != null) return usage();

    var timer = io.Timer.start();
    var pbf = try file.File.open(init.gpa, path, .none);
    defer pbf.close();
    const index_ns = timer.lap();
    var scan: Scan = .{};
    for (0..passes) |_| try pbf.index.forEach(init.gpa, workers, .none, &scan, Scan.collect);
    const elapsed_ns = timer.read();
    const elapsed_s: f64 = @as(f64, @floatFromInt(@max(1, elapsed_ns))) / std.time.ns_per_s;
    const arena = init.arena.allocator();
    const json = try std.json.Stringify.valueAlloc(arena, .{
        .file_blocks = 1 + pbf.index.blobs.len + pbf.index.ignored_blocks,
        .data_blocks = pbf.index.blobs.len,
        .ignored_blocks = pbf.index.ignored_blocks,
        .sorted_by_type_and_id = pbf.index.header.sorted_by_type_and_id,
        .replication_timestamp = pbf.index.header.replication_timestamp,
        .workers = workers,
        .passes = passes,
        .index_ns = index_ns,
        .inflate_ns = elapsed_ns,
        .inflated_blocks = scan.blocks,
        .inflated_bytes = scan.bytes,
        .blocks_per_second = @as(f64, @floatFromInt(scan.blocks)) / elapsed_s,
        .peak_rss_bytes = try io.peakRssBytes(),
        .digest = scan.digest,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
}

fn usage() error{InvalidArgument} {
    std.debug.print("usage: zig build bench-osm-pbf -- FILE.osm.pbf THREADS [PASSES]\n", .{});
    return error.InvalidArgument;
}
