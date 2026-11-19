//! Line-delimited OSM tag records for inspection and oracle comparison.

const std = @import("std");
const io = @import("../infra/io.zig");
const constants = @import("../graph/constants.zig");
const osm = @import("../build/osm.zig");
const pbf = @import("../build/pbf/root.zig");
const tags = @import("../build/tags/root.zig");
const way_shape = @import("../build/way_shape.zig");

pub fn dump(gpa: std.mem.Allocator, path: []const u8, raw: bool, out: *io.Writer, deadline: io.Deadline) !void {
    const file = try io.File.open(path, .read_only);
    defer file.close();
    const source = try pbf.file.Stream.init(file);
    var state: State = .{
        .gpa = gpa,
        .out = out,
        .deadline = deadline,
        .raw = raw,
        .strings = .init(gpa),
    };
    defer state.strings.deinit();
    defer state.block.deinit(gpa);
    defer state.raw_tags.deinit(gpa);
    try source.forEach(gpa, deadline, &state, State.visit);
}

const NodeFields = struct {
    access: u16 = @bitCast(constants.AccessMask.all_tag_modes),
    node_type: u4 = 0,
    named_intersection: bool = false,
    traffic_signal: bool = false,
    forward_signal: bool = false,
    backward_signal: bool = false,
    stop_sign: bool = false,
    forward_stop: bool = false,
    backward_stop: bool = false,
    yield_sign: bool = false,
    forward_yield: bool = false,
    backward_yield: bool = false,
    minor: bool = false,
    direction: bool = false,
    tagged_access: bool = false,
    private_access: bool = false,
    step_count: ?u32 = null,
    tactile_paving: ?[]const u8 = null,
};

const State = struct {
    gpa: std.mem.Allocator,
    out: *io.Writer,
    raw: bool,
    deadline: io.Deadline,
    block: pbf.block.Scratch = .{},
    scratch: tags.Scratch = .{},
    strings: tags.names.StringTable,
    raw_tags: std.ArrayList(osm.Tag) = .empty,

    fn visit(self: *State, _: usize, bytes: []const u8) !void {
        const block = try self.block.decode(self.gpa, bytes, self.deadline);
        var nodes = block.nodes();
        while (try nodes.next()) |node| {
            if (self.raw) {
                try self.record(.{ .kind = osm.Kind.node, .id = node.id, .tags = try self.rawTags(node.tags) });
            } else {
                try self.nodeRecord(node);
            }
        }
        var ways = block.ways();
        while (try ways.next()) |way| {
            const shape = try way_shape.inspect(way.refs);
            if (self.raw) {
                try self.record(.{ .kind = osm.Kind.way, .id = way.id, .shape = shape, .tags = try self.rawTags(way.tags) });
            } else {
                try self.wayRecord(way, try way_shape.accepts(shape, way.tags));
            }
        }
    }

    fn record(self: *State, value: anytype) !void {
        try std.json.Stringify.value(value, .{}, self.out);
        try self.out.writeByte('\n');
    }

    fn rawTags(self: *State, source: pbf.block.TagIterator) ![]const osm.Tag {
        self.raw_tags.clearRetainingCapacity();
        var iter = source;
        while (try iter.next()) |tag| try self.raw_tags.append(self.gpa, tag);
        return self.raw_tags.items;
    }

    fn nodeRecord(self: *State, node: pbf.block.Node) !void {
        const a = (try tags.transformNode(&self.scratch, node.tags, self.deadline)).?;
        const fields: NodeFields = .{
            .access = @bitCast(a.access),
            .node_type = @backingInt(a.type),
            .named_intersection = a.flags.named_intersection,
            .traffic_signal = a.flags.traffic_signal,
            .forward_signal = a.flags.forward_signal,
            .backward_signal = a.flags.backward_signal,
            .stop_sign = a.flags.stop_sign,
            .forward_stop = a.flags.forward_stop,
            .backward_stop = a.flags.backward_stop,
            .yield_sign = a.flags.yield_sign,
            .forward_yield = a.flags.forward_yield,
            .backward_yield = a.flags.backward_yield,
            .minor = a.flags.minor,
            .direction = a.flags.direction,
            .tagged_access = a.flags.tagged_access,
            .private_access = a.flags.private_access,
            .step_count = a.step_count,
            .tactile_paving = optionalName(a.tactile_paving),
        };
        const compact: ?NodeFields = if (std.meta.eql(fields, NodeFields{})) null else fields;
        try self.record(.{ .kind = osm.Kind.node, .id = node.id, .eligible = true, .kept = true, .attributes = compact });
    }

    fn wayRecord(self: *State, way: pbf.block.Way, eligible: bool) !void {
        const result = if (eligible)
            try tags.transformIndexedWay(&self.scratch, &self.strings, way.tags, .{ .allow_alt_name = true }, self.deadline)
        else
            null;
        if (result) |selected| {
            const a = selected.attributes;
            const n = selected.names;
            try self.record(.{
                .kind = osm.Kind.way,
                .id = way.id,
                .eligible = true,
                .kept = true,
                .attributes = .{
                    .road_class = @backingInt(a.road_class),
                    .use = @backingInt(a.use),
                    .surface = @backingInt(a.surface),
                    .forward_access = @as(u16, @bitCast(a.forward_access)),
                    .backward_access = @as(u16, @bitCast(a.backward_access)),
                    .speed = a.speed,
                    .speed_limit = a.speed_limit,
                    .forward_speed = a.forward_speed,
                    .backward_speed = a.backward_speed,
                    .truck_speed = a.truck_speed,
                    .lanes = a.lanes,
                    .forward_lanes = a.forward_lanes,
                    .backward_lanes = a.backward_lanes,
                    .lane_left = @backingInt(a.bicycle.lane_left),
                    .lane_right = @backingInt(a.bicycle.lane_right),
                    .sac_scale = @backingInt(a.pedestrian.sac_scale),
                    .bike_network = a.bicycle.network.costingMask(),
                    .oneway = a.flags.oneway,
                    .oneway_reverse = a.flags.oneway_reverse,
                    .roundabout = a.flags.roundabout,
                    .link = a.flags.link,
                    .turn_channel = a.flags.turn_channel,
                    .ferry = a.flags.ferry,
                    .rail = a.flags.rail,
                    .pedestrian_area = a.flags.pedestrian_area,
                    .bridge = a.flags.bridge,
                    .tunnel = a.flags.tunnel,
                    .lit = a.flags.lit,
                    .indoor = a.flags.indoor,
                    .destination_only = a.flags.destination_only,
                    .destination_only_hgv = a.flags.destination_only_hgv,
                    .no_thru_traffic = a.flags.no_thru_traffic,
                    .tagged_speed = a.flags.tagged_speed,
                    .forward_tagged_speed = a.flags.forward_tagged_speed,
                    .backward_tagged_speed = a.flags.backward_tagged_speed,
                    .tagged_lanes = a.flags.tagged_lanes,
                    .forward_tagged_lanes = a.flags.forward_tagged_lanes,
                    .backward_tagged_lanes = a.flags.backward_tagged_lanes,
                    .wheelchair = a.flags.wheelchair,
                    .wheelchair_tag = a.flags.wheelchair_tag,
                    .sidewalk_left = a.flags.sidewalk_left,
                    .sidewalk_right = a.flags.sidewalk_right,
                    .shoulder_left = a.flags.shoulder_left,
                    .shoulder_right = a.flags.shoulder_right,
                    .tagged_internal_intersection = a.flags.tagged_internal_intersection,
                    .left_opposite = a.bicycle.left_opposite,
                    .right_opposite = a.bicycle.right_opposite,
                    .use_sidepath = a.bicycle.use_sidepath,
                    .dismount = a.bicycle.dismount,
                    .name = self.string(n.name.text),
                    .name_language = self.string(n.name.language),
                    .alt_name = self.string(n.alt_name.text),
                    .alt_name_language = self.string(n.alt_name.language),
                    .official_name = self.string(n.official_name.text),
                    .official_name_language = self.string(n.official_name.language),
                    .ref = self.string(n.ref.text),
                    .ref_language = self.string(n.ref.language),
                    .int_ref = self.string(n.int_ref.text),
                    .int_ref_language = self.string(n.int_ref.language),
                    .tunnel_name = self.string(n.tunnel_name.text),
                    .tunnel_name_language = self.string(n.tunnel_name.language),
                    .destination = self.string(n.destination.text),
                    .destination_language = self.string(n.destination.language),
                    .destination_forward = self.string(n.destination_forward.text),
                    .destination_forward_language = self.string(n.destination_forward.language),
                    .destination_backward = self.string(n.destination_backward.text),
                    .destination_backward_language = self.string(n.destination_backward.language),
                    .destination_ref = self.string(n.destination_ref.text),
                    .destination_ref_language = self.string(n.destination_ref.language),
                    .destination_ref_to = self.string(n.destination_ref_to.text),
                    .destination_ref_to_language = self.string(n.destination_ref_to.language),
                    .destination_street = self.string(n.destination_street.text),
                    .destination_street_language = self.string(n.destination_street.language),
                    .destination_street_to = self.string(n.destination_street_to.text),
                    .destination_street_to_language = self.string(n.destination_street_to.language),
                    .junction_ref = self.string(n.junction_ref.text),
                    .junction_ref_language = self.string(n.junction_ref.language),
                    .junction_name = self.string(n.junction_name.text),
                    .junction_name_language = self.string(n.junction_name.language),
                    .destination_int_ref = self.string(n.destination_int_ref),
                    .destination_int_ref_to = self.string(n.destination_int_ref_to),
                    .turn_lanes_forward = self.string(n.turn_lanes_forward),
                    .turn_lanes_backward = self.string(n.turn_lanes_backward),
                    .speed_zone = a.speed_zone,
                    .bridge_name = self.string(n.bridge_name),
                    .mtb_scale = a.bicycle.mtb_scale,
                    .mtb_uphill_scale = a.bicycle.mtb_uphill_scale,
                    .icn = a.bicycle.network.icn,
                    .step_count = a.pedestrian.step_count,
                    .trail_visibility = optionalName(a.pedestrian.trail_visibility),
                    .tactile_paving = optionalName(a.pedestrian.tactile_paving),
                    .foot = a.pedestrian.foot,
                },
            });
        } else {
            const kept = if (eligible) false else try tags.includePbfWay(&self.scratch, &way);
            try self.record(.{ .kind = osm.Kind.way, .id = way.id, .eligible = eligible, .kept = kept, .attributes = null });
        }
    }

    fn string(self: *const State, id: tags.names.Id) []const u8 {
        return self.strings.get(id) orelse unreachable;
    }
};

fn optionalName(value: anytype) ?[]const u8 {
    return if (value) |item| @tagName(item) else null;
}
