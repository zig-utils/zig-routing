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
    placement: format.Placement,
    resident_bytes: ?usize,
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

pub fn write(bundle: *const reader.Bundle, out: *io.Writer, json: bool, verified: bool, edge_id: ?u32, node_id: ?u32) !void {
    const graph = &bundle.view;
    var sections: [kinds.len]Section = undefined;
    var count: usize = 0;
    for (kinds) |kind| {
        const header = graph.header(kind) orelse continue;
        const section = &sections[count];
        count += 1;
        section.* = .{
            .kind = kind,
            .file = kind.filename(),
            .count = header.count,
            .record_size = header.record_size,
            .bytes = format.payload_offset + header.count * header.record_size,
            .xxh3 = undefined,
            .placement = kind.placement(),
            .resident_bytes = bundle.residentBytes(kind, .none) catch null,
        };
        _ = std.fmt.bufPrint(&section.xxh3, "{x:0>16}", .{header.payload_hash}) catch unreachable;
    }
    const uuid = std.fmt.bytesToHex(graph.dataset_uuid, .lower);
    const edge_record = if (edge_id) |id| try Edge.read(graph, id) else null;
    const node_record = if (node_id) |id| try Node.read(graph, id) else null;
    const ordering = if (graph.metadata) |metadata| .{
        .kind = metadata[0].ordering().?,
        .xxh3 = std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u64, metadata[0].order_hash)), .lower),
    } else null;

    if (json) {
        try std.json.Stringify.value(.{
            .version = format.version,
            .dataset_uuid = uuid,
            .verified = verified,
            .ordering = ordering,
            .sections = sections[0..count],
            .edge = edge_record,
            .node = node_record,
        }, .{}, out);
        try out.writeByte('\n');
        return;
    }

    try out.print("Graph bundle v{d}  {s}\n", .{ format.version, uuid });
    if (ordering) |value| try out.print("Ordering {s}  {s}\n", .{ @tagName(value.kind), value.xxh3 });
    try out.print("{s: <16} {s: >12} {s: >11} {s: >14}  {s: <4} {s: >14}  {s}\n", .{
        "File", "Records", "Record size", "File bytes", "Use", "Resident bytes", "XXH3-64",
    });
    for (sections[0..count]) |section| {
        var buffer: [24]u8 = undefined;
        const resident = if (section.resident_bytes) |bytes| try std.fmt.bufPrint(&buffer, "{d}", .{bytes}) else "unavailable";
        try out.print("{s: <16} {d: >12} {d: >11} {d: >14}  {s: <4} {s: >14}  {s}\n", .{
            section.file, section.count, section.record_size, section.bytes, @tagName(section.placement), resident, section.xxh3,
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
