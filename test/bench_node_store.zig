//! Build the node store for an extract and resolve every way ref in order.
//! The second node pass independently compares each stored position with
//! the raw PBF. Report unresolved refs so they can be compared to the
//! corresponding references to absent nodes in the source extract.

const std = @import("std");
const routing = @import("routing");
const pbf = routing.build.pbf;
const nodes = routing.build.node_store;
const io = routing.infra.io;

fn allWays(_: void, _: *const pbf.block.Way) !bool {
    return true;
}

const Scan = struct {
    gpa: std.mem.Allocator,
    store: nodes.Store,
    scratch: pbf.block.Scratch = .{},
    cursor: nodes.Cursor = .{},
    workers: usize,
    ids: [8192]i64 = undefined,
    locations: [8192]?nodes.Location = undefined,
    pending: usize = 0,
    compared: u64 = 0,
    refs: u64 = 0,
    unresolved_refs: u64 = 0,
    unresolved_checksum: u64 = 0,
    lookup_ns: u64 = 0,
    digest: u64 = 0,

    fn checkNodes(self: *Scan, _: usize, bytes: []const u8) !void {
        const block = try self.scratch.decode(self.gpa, bytes, .none);
        var iter = block.nodes();
        while (try iter.next()) |node| {
            const loc = try self.cursor.lookup(self.store, node.id, .none) orelse continue;
            if (loc.lat != node.lat or loc.lon != node.lon) return error.CoordinateMismatch;
            self.compared += 1;
        }
    }

    fn checkWays(self: *Scan, _: usize, bytes: []const u8) !void {
        const block = try self.scratch.decode(self.gpa, bytes, .none);
        var iter = block.ways();
        while (try iter.next()) |value| {
            var way = value;
            while (try way.refs.next()) |id| {
                self.ids[self.pending] = id;
                self.pending += 1;
                if (self.pending == self.ids.len) try self.resolve();
            }
        }
    }

    fn resolve(self: *Scan) !void {
        const batch = self.ids[0..self.pending];
        const out = self.locations[0..self.pending];
        const timer = io.Timer.start();
        try self.store.lookupBatch(batch, out, self.workers, .none);
        self.lookup_ns += timer.read();
        for (batch, out) |id, result| {
            if (result) |loc| {
                self.digest = (self.digest ^ @as(u32, @bitCast(loc.lat))) *% 1099511628211;
                self.digest = (self.digest ^ @as(u32, @bitCast(loc.lon))) *% 1099511628211;
            } else {
                self.unresolved_refs += 1;
                self.unresolved_checksum = (self.unresolved_checksum ^ @as(u64, @bitCast(id))) *% 1099511628211;
            }
        }
        self.refs += self.pending;
        self.pending = 0;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingExtractPath;
    const scratch_dir = args.next() orelse return error.MissingScratchDirectory;
    const workers = try std.fmt.parseInt(usize, args.next() orelse "1", 10);
    if (args.next() != null) return error.UnexpectedArgument;

    const input = try io.File.open(path, .read_only);
    defer input.close();
    const source = try pbf.file.Stream.init(input);
    const output = try io.File.temporary(scratch_dir);
    defer output.close();
    const timer = io.Timer.start();
    _ = try nodes.build(init.gpa, source, output, .{
        .scratch_dir = scratch_dir,
    }, {}, allWays);
    const build_ns = timer.read();
    const build_rss = try io.peakRssBytes();
    var scan: Scan = .{ .gpa = init.gpa, .store = try nodes.Store.open(output), .workers = workers };
    defer scan.scratch.deinit(init.gpa);
    try source.forEach(init.gpa, .none, &scan, Scan.checkNodes);
    if (scan.compared != scan.store.nodeCount()) return error.NodeCountMismatch;
    try source.forEach(init.gpa, .none, &scan, Scan.checkWays);
    try scan.resolve();

    const bytes = try output.size();
    const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .workers = workers,
        .verified_nodes = scan.compared,
        .verified_way_refs = scan.refs - scan.unresolved_refs,
        .unresolved_way_refs = scan.unresolved_refs,
        .unresolved_ref_checksum = scan.unresolved_checksum,
        .store_bytes = bytes,
        .bytes_per_node = ratio(bytes, scan.compared),
        .build_ns = build_ns,
        .lookup_ns = scan.lookup_ns,
        .lookups_per_second = ratio(scan.refs, scan.lookup_ns) * std.time.ns_per_s,
        .build_peak_rss_bytes = build_rss,
        .peak_rss_bytes = try io.peakRssBytes(),
        .coordinate_checksum = scan.digest,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
}

fn ratio(numerator: u64, denominator: u64) f64 {
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(@max(1, denominator)));
}
