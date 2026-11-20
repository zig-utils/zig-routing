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
const cold_idx = [_]u32{ 0, 0x8000_0000 };
const slopes = [_]u16{ 0, 0x024f };
const spatial = "\x01\x00\x00\x00\x00\x00\x00\x00\x00\xb4\x90\x7e\x00\x00\x00\x00\x00";
const metadata = [_]format.Metadata{.{ .ordering_kind = 1, .order_hash = 0x1234_5678_9abc_def0 }};
const empty_admins: routing.graph.admin.Header = .{
    .regions = 0,
    .cells = 0,
    .pieces = 0,
    .rings = 0,
    .vertices = 0,
    .string_bytes = 0,
};
// One chunk, one record, one name. The shape encodes both coordinates above.
const cold_bytes =
    "\x01\x00\x00\x00\x01\x00\x00\x00\x4e\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x2e\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x1e\x00\x00\x00\x00\x00\x00\x00" ++
    "\xef\xcd\xab\x89\x67\x45\x23\x01\x06\x00\x00\x00\x02\x00\x00\x00\x0c\xfe\x23\x01" ++
    "\x00\x00\x00\xc0\x9a\x0c\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00Main";

pub fn records(comptime kind: format.SectionKind) []const kind.Record() {
    return switch (kind) {
        .nodes => &nodes,
        .edges => &edges,
        .first_edge => &first_edge,
        .turns => &turns,
        .classes => &classes,
        .coordinates => &coordinates,
        .cold_idx => &cold_idx,
        .cold => cold_bytes,
        .slopes => &slopes,
        .spatial => spatial,
        .metadata => &metadata,
        .components => &.{ 0, 0 },
        .turn_sides => &.{ 3, 0, 0 },
        .coverage => &.{.{ .west = 0, .south = 0, .east = 100000, .north = 0 }},
        .admins => std.mem.asBytes(&empty_admins),
        .node_admins => &.{ 0, 0 },
        .node_timezones => &.{ 292, 0 },
        .timezone_rules => @embedFile("fuzz/seeds/timezone-rules.bin"),
        .turn_restrictions => &.{},
        .restriction_automaton => &.{
            .{ .edge = std.math.maxInt(u32), .first = 2, .end = 3, .failure = 0 },
            .{ .edge = std.math.maxInt(u32), .first = 3, .end = 4, .failure = 1, .attr = .{ .reverse = true } },
            .{ .edge = 0, .first = 4, .end = 5, .failure = 0, .attr = .{ .depth = 1 } },
            .{ .edge = 1, .first = 5, .end = 6, .failure = 1, .attr = .{ .depth = 1, .reverse = true } },
            .{ .edge = 1, .first = 6, .end = 6, .failure = 0, .attr = .{ .depth = 2, .forbidden = 1 } },
            .{ .edge = 0, .first = 6, .end = 6, .failure = 1, .attr = .{ .depth = 2, .reverse = true, .forbidden = 1 } },
        },
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
