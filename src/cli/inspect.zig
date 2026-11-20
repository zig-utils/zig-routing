//! Report graph bundle sections and selected records.
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("../graph/format.zig");
const reader = @import("../graph/reader.zig");
const edge_keys = @import("../graph/edge_keys.zig");
const kinds = std.enums.values(format.SectionKind);

pub fn parseEdgeKey(text: []const u8) !edge_keys.Key {
    var parts = std.mem.splitScalar(u8, text, ',');
    var key: edge_keys.Key = .{
        .way_id = try parseKeyPart(i64, parts.next()),
        .begin_node = try parseKeyPart(i64, parts.next()),
        .end_node = try parseKeyPart(i64, parts.next()),
    };
    const direction = parts.next() orelse return error.InvalidEdgeKey;
    key.flags.reversed = if (std.mem.eql(u8, direction, "reverse"))
        true
    else if (std.mem.eql(u8, direction, "forward"))
        false
    else
        return error.InvalidEdgeKey;
    if (parts.next()) |occurrence| key.flags.occurrence = try parseKeyPart(u32, occurrence);
    if (parts.next()) |kind| key.flags.kind = std.meta.stringToEnum(edge_keys.Kind, kind) orelse return error.InvalidEdgeKey;
    if (!key.valid() or parts.next() != null) return error.InvalidEdgeKey;
    return key;
}

fn parseKeyPart(comptime T: type, part: ?[]const u8) !T {
    return std.fmt.parseInt(T, part orelse return error.InvalidEdgeKey, 10) catch error.InvalidEdgeKey;
}

const Key = struct {
    way_id: i64,
    begin_node: i64,
    end_node: i64,
    direction: enum { forward, reverse },
    occurrence: u32,
    kind: edge_keys.Kind,

    fn read(key: edge_keys.Key) Key {
        return .{
            .way_id = key.way_id,
            .begin_node = key.begin_node,
            .end_node = key.end_node,
            .direction = if (key.flags.reversed) .reverse else .forward,
            .occurrence = key.flags.occurrence,
            .kind = key.flags.kind,
        };
    }

    fn write(self: Key, out: *io.Writer) !void {
        try out.print("{d},{d},{d},{s},{d},{s}", .{
            self.way_id, self.begin_node, self.end_node, @tagName(self.direction), self.occurrence, @tagName(self.kind),
        });
    }
};

pub fn writeEdgeKey(index: edge_keys.View, out: *io.Writer, json: bool, lookup: union(enum) { key: edge_keys.Key, edge: u32 }) !void {
    const result = switch (lookup) {
        .key => |key| .{ @backingInt((try index.find(key)) orelse return error.EdgeKeyNotFound), Key.read(key) },
        .edge => |id| .{ id, Key.read(try index.key(@fromBackingInt(id))) },
    };
    if (json) {
        try std.json.Stringify.value(.{ .edge = result[0], .key = result[1] }, .{}, out);
    } else {
        try result[1].write(out);
        try out.print(" edge {d}", .{result[0]});
    }
    try out.writeByte('\n');
}

pub fn diffEdgeKeys(old: edge_keys.View, new: edge_keys.View, out: *io.Writer, json: bool, deadline: io.Deadline) !void {
    const Status = enum { added, removed, changed };
    const Change = struct { status: Status, key: Key, old_edge: ?u32, new_edge: ?u32 };
    var counts = std.EnumArray(Status, usize).initFill(0);
    var left: usize = 0;
    var right: usize = 0;
    var separator: []const u8 = "";
    if (json) try out.writeAll("{\"changes\":[");
    while (left < old.records.len or right < new.records.len) {
        if ((left +% right) % 1024 < 2 and deadline.expired()) return error.DeadlineExceeded;
        const order: std.math.Order = if (left == old.records.len)
            .gt
        else if (right == new.records.len)
            .lt
        else
            old.records[left].key.order(new.records[right].key);
        const before = if (order != .gt) old.records[left] else null;
        const after = if (order != .lt) new.records[right] else null;
        left += @intFromBool(before != null);
        right += @intFromBool(after != null);
        if (before != null and after != null and before.?.edge == after.?.edge) continue;
        const key = if (before) |row| row.key else after.?.key;
        if (!key.valid()) return error.InvalidEdgeKey;
        const change: Change = .{
            .status = switch (order) {
                .lt => .removed,
                .gt => .added,
                .eq => .changed,
            },
            .key = Key.read(key),
            .old_edge = if (before) |row| row.edge else null,
            .new_edge = if (after) |row| row.edge else null,
        };
        counts.getPtr(change.status).* += 1;
        if (json) {
            try out.writeAll(separator);
            try std.json.Stringify.value(change, .{}, out);
            separator = ",";
        } else {
            try out.print("{s} ", .{@tagName(change.status)});
            try change.key.write(out);
            if (change.old_edge) |id| try out.print(" old edge {d}", .{id});
            if (change.new_edge) |id| try out.print(" new edge {d}", .{id});
            try out.writeByte('\n');
        }
    }
    if (json)
        try out.print("],\"added\":{d},\"removed\":{d},\"changed\":{d}}}\n", .{ counts.get(.added), counts.get(.removed), counts.get(.changed) })
    else
        try out.print("{d} added, {d} removed, {d} changed\n", .{ counts.get(.added), counts.get(.removed), counts.get(.changed) });
}

test "edge key diff reports membership changes and dense edge moves" {
    const first = try parseEdgeKey("1,10,20,forward");
    const retained = try parseEdgeKey("2,10,20,reverse,1");
    const added = try parseEdgeKey("3,10,20,forward,0,transit");
    const old: edge_keys.View = .{ .records = &.{ .{ .key = first, .edge = 0 }, .{ .key = retained, .edge = 1 } }, .inverse = &.{ 0, 1 } };
    const new: edge_keys.View = .{ .records = &.{ .{ .key = retained, .edge = 0 }, .{ .key = added, .edge = 1 } }, .inverse = &.{ 0, 1 } };
    var buffer: [1024]u8 = undefined;
    var writer: io.Writer = .fixed(&buffer);
    try diffEdgeKeys(old, new, &writer, false, .none);
    try std.testing.expectEqualStrings(
        "removed 1,10,20,forward,0,osm old edge 0\n" ++
            "changed 2,10,20,reverse,1,osm old edge 1 new edge 0\n" ++
            "added 3,10,20,forward,0,transit new edge 1\n" ++
            "1 added, 1 removed, 1 changed\n",
        writer.buffered(),
    );
    try std.testing.expectError(error.InvalidEdgeKey, parseEdgeKey("1,10,20,left"));
    try std.testing.expectError(error.InvalidEdgeKey, parseEdgeKey("1,10,20,reverse,0,transit,1"));
}

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
    const coverage = if (graph.coverage) |records| records[0] else null;
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
            .coverage_e7 = coverage,
            .sections = sections[0..count],
            .edge = edge_record,
            .node = node_record,
        }, .{}, out);
        try out.writeByte('\n');
        return;
    }

    try out.print("Graph bundle v{d}  {s}\n", .{ format.version, uuid });
    if (ordering) |value| try out.print("Ordering {s}  {s}\n", .{ @tagName(value.kind), value.xxh3 });
    if (coverage) |value| try out.print("Coverage E7 west {d} south {d} east {d} north {d}\n", .{ value.west, value.south, value.east, value.north });
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
