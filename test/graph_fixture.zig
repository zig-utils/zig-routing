//! Tiny v1 graph for the mmap, inspection and fuzz tests.
const std = @import("std");
const routing = @import("routing");
const format = routing.graph.format;

const uuid: format.DatasetUuid = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

const nodes = [_]format.NodeHot{
    .{ .turn_off = 0, .attr = .{ .access = 3, .type = 1, .density = 2, .signal = 0 } },
    .{ .turn_off = 1, .attr = .{ .access = 7, .type = 0, .density = 5, .signal = 1 } },
};
const edges = [_]format.EdgeHot{
    .{
        .head = 1,
        .geom = .{ .len_m = 1234, .grade = 2, .curvature = 1 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 1, .pred_speed = 0 },
        .speed = .{ 140, 50, 35, 40 },
    },
    .{
        .head = 0,
        .geom = .{ .len_m = 1234, .grade = 1, .curvature = 3 },
        .cls = .{ .class_id = 1, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 1 },
        .speed = .{ 40, 45, 30, 35 },
    },
};
const first_edge = [_]format.FirstEdge{ 0, 1, 2 };
const turns = [_]format.TurnEntry{ 0xb9, 0x72 };
const classes = [_]routing.graph.class_table.EdgeClass{
    .{ .access = .{ .forward = 3, .reverse = 7 } },
    .{ .access = .{ .forward = 7, .reverse = 3 } },
};
const coordinates = [_]format.Coordinate{ .{ .lng = 0, .lat = 0 }, .{ .lng = 100000, .lat = 0 } };

pub fn records(comptime kind: format.SectionKind) []const kind.Record() {
    return switch (kind) {
        .nodes => &nodes,
        .edges => &edges,
        .first_edge => &first_edge,
        .turns => &turns,
        .classes => &classes,
        .coordinates => &coordinates,
    };
}

pub fn header(comptime kind: format.SectionKind) format.SectionHeader {
    const data = records(kind);
    return .{
        .kind = @backingInt(kind),
        .dataset_uuid = uuid,
        .record_size = kind.recordSize(),
        .count = data.len,
        .payload_hash = std.hash.XxHash3.hash(0, std.mem.sliceAsBytes(data)),
    };
}

pub fn write(path: []const u8) !void {
    var writer = try format.BundleWriter.init(path, uuid, .none);
    defer writer.deinit();
    inline for (std.enums.values(format.SectionKind)) |kind| try writer.write(kind, records(kind));
    try writer.commit();
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const output = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.ExtraArguments;
    const path = try std.fs.path.join(init.arena.allocator(), &.{ output, "bundle" });
    try write(path);
}
