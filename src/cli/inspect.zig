//! Report graph bundle sections and selected records.
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("../graph/format.zig");
const reader = @import("../graph/reader.zig");
const kinds = std.enums.values(format.SectionKind);

const Section = struct {
    kind: format.SectionKind,
    file: []const u8,
    count: u64,
    record_size: u32,
    bytes: u64,
    xxh3: [16]u8,
};

const Edge = struct {
    id: u32,
    head: u32,
    opposing: u32,
    len_m: u24,
    grade: u4,
    curvature: u4,
    class_id: u20,
    local: u5,
    opp_local: u5,
    cold_checks: bool,
    pred_speed: bool,
    speeds: struct {
        speed: u8,
        free_flow: u8,
        constrained: u8,
        truck: u8,
    },

    fn read(graph: *const reader.View, id: u32) !Edge {
        const item = try graph.edge(@fromBackingInt(@intCast(id)));
        return .{
            .id = id,
            .head = item.head,
            .opposing = @backingInt(try graph.oppEdge(@fromBackingInt(@intCast(id)))),
            .len_m = item.geom.len_m,
            .grade = item.geom.grade,
            .curvature = item.geom.curvature,
            .class_id = item.cls.class_id,
            .local = item.cls.local,
            .opp_local = item.cls.opp_local,
            .cold_checks = item.cls.cold_checks != 0,
            .pred_speed = item.cls.pred_speed != 0,
            .speeds = .{
                .speed = item.speed[0],
                .free_flow = item.speed[1],
                .constrained = item.speed[2],
                .truck = item.speed[3],
            },
        };
    }
};

const Node = struct {
    id: u32,
    first_edge: u32,
    degree: u32,
    turn_off: u32,
    access: u16,
    type: u4,
    density: u4,
    signal: bool,

    fn read(graph: *const reader.View, id: u32) !Node {
        const node = try graph.node(@fromBackingInt(@intCast(id)));
        const range = try graph.outEdgeRange(@fromBackingInt(@intCast(id)));
        return .{
            .id = id,
            .first_edge = range.first,
            .degree = range.count(),
            .turn_off = node.turn_off,
            .access = node.attr.access,
            .type = node.attr.type,
            .density = node.attr.density,
            .signal = node.attr.signal != 0,
        };
    }
};

pub fn write(graph: *const reader.View, out: *io.Writer, json: bool, verified: bool, edge_id: ?u32, node_id: ?u32) !void {
    var sections: [kinds.len]Section = undefined;
    for (kinds, &sections) |kind, *section| {
        const header = graph.header(kind);
        section.* = .{
            .kind = kind,
            .file = kind.filename(),
            .count = header.count,
            .record_size = header.record_size,
            .bytes = format.payload_offset + header.count * header.record_size,
            .xxh3 = undefined,
        };
        _ = std.fmt.bufPrint(&section.xxh3, "{x:0>16}", .{header.payload_hash}) catch unreachable;
    }
    const uuid = std.fmt.bytesToHex(graph.dataset_uuid, .lower);
    const edge_record = if (edge_id) |id| try Edge.read(graph, id) else null;
    const node_record = if (node_id) |id| try Node.read(graph, id) else null;

    if (json) {
        try std.json.Stringify.value(.{
            .version = format.version,
            .dataset_uuid = uuid,
            .verified = verified,
            .sections = sections,
            .edge = edge_record,
            .node = node_record,
        }, .{}, out);
        try out.writeByte('\n');
        return;
    }

    try out.print("Graph bundle v{d}  {s}\n", .{ format.version, uuid });
    try out.print("{s: <16} {s: >12} {s: >11} {s: >14}  {s}\n", .{ "File", "Records", "Record size", "File bytes", "XXH3-64" });
    for (sections) |section| {
        try out.print("{s: <16} {d: >12} {d: >11} {d: >14}  {s}\n", .{
            section.file, section.count, section.record_size, section.bytes, section.xxh3,
        });
    }
    if (verified) try out.writeAll("All section checksums verified.\n");
    if (edge_record) |entry| {
        try out.print("Edge {d}\n", .{entry.id});
        try std.json.Stringify.value(entry, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
    }
    if (node_record) |entry| {
        try out.print("Node {d}\n", .{entry.id});
        try std.json.Stringify.value(entry, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
    }
}
