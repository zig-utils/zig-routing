//! Print per-kind OSM counts and a checksum for comparison with libosmium.
//! Hash the signed ID and each tag (key then value, each length-prefixed).
//! An all-ones length terminates each object. Integers are little-endian u64.

const std = @import("std");
const routing = @import("routing");
const pbf = routing.build.pbf;
const io = routing.infra.io;

const Digest = struct {
    objects: u64 = 0,
    tags: u64 = 0,
    fnv1a: u64 = 14695981039346656037,

    fn bytes(self: *Digest, data: []const u8) void {
        for (data) |byte| self.fnv1a = (self.fnv1a ^ byte) *% 1099511628211;
    }

    fn int(self: *Digest, value: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        self.bytes(&buf);
    }

    fn object(self: *Digest, id: i64, tags: *pbf.block.TagIterator) !void {
        self.objects += 1;
        self.int(@bitCast(id));
        while (try tags.next()) |tag| {
            self.tags += 1;
            self.int(tag.key.len);
            self.bytes(tag.key);
            self.int(tag.value.len);
            self.bytes(tag.value);
        }
        self.int(std.math.maxInt(u64));
    }
};

const Scan = struct {
    gpa: std.mem.Allocator,
    scratch: pbf.block.Scratch = .{},
    nodes: Digest = .{},
    ways: Digest = .{},
    relations: Digest = .{},

    fn collect(self: *Scan, _: usize, bytes: []const u8) !void {
        const block = try self.scratch.decode(self.gpa, bytes, .none);
        var nodes = block.nodes();
        while (try nodes.next()) |value| {
            var node = value;
            try self.nodes.object(node.id, &node.tags);
        }
        var ways = block.ways();
        while (try ways.next()) |value| {
            var way = value;
            try self.ways.object(way.id, &way.tags);
            while (try way.refs.next()) |_| {}
        }
        var relations = block.relations();
        while (try relations.next()) |value| {
            var relation = value;
            try self.relations.object(relation.id, &relation.tags);
            while (try relation.members.next()) |_| {}
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingExtractPath;
    if (args.next() != null) return error.UnexpectedArgument;
    var src = try pbf.file.File.open(init.gpa, path, .none);
    defer src.close();
    var scan: Scan = .{ .gpa = init.gpa };
    defer scan.scratch.deinit(init.gpa);
    try src.index.forEach(init.gpa, 1, .none, &scan, Scan.collect);
    const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .nodes = scan.nodes,
        .ways = scan.ways,
        .relations = scan.relations,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
}
