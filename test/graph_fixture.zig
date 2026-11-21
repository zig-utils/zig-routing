//! Tiny v1 graph for the mmap, inspection and fuzz tests.
const std = @import("std");
const routing = @import("routing");
const format = routing.graph.format;
const transit = routing.graph.transit;
const edge_keys = routing.graph.edge_keys;

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
const keys = [_]edge_keys.Record{
    .{ .key = .{ .way_id = 12, .begin_node = 42, .end_node = 43 }, .edge = 0 },
    .{ .key = .{ .way_id = 12, .begin_node = 43, .end_node = 42, .flags = .{ .reversed = true } }, .edge = 1 },
};
const hash_seed = blk: {
    var seed: u64 = 0;
    while (keys[0].key.hash(seed) % 2 == keys[1].key.hash(seed) % 2) : (seed += 1) {}
    break :blk seed;
};
const hash_buckets = blk: {
    var buckets: [2]u64 = undefined;
    for (keys, 0..) |row, i| buckets[row.key.hash(hash_seed) % 2] = edge_keys.singleton_bucket | i;
    break :blk buckets;
};
const turns = [_]format.TurnEntry{ 0xb9, 0x72 };
const classes = [_]routing.graph.class_table.EdgeClass{
    .{ .access = .{ .forward = 3, .reverse = 7 }, .flags = .{ .sign = true, .turnlanes = true, .lane_conn = true } },
    .{ .access = .{ .forward = 7, .reverse = 3 } },
};
const coordinates = [_]format.Coordinate{ .{ .lng = 0, .lat = 0 }, .{ .lng = 100000, .lat = 0 } };
const cold_idx = [_]u32{ 0, 0x8000_0000 };
const slopes = [_]u16{ 0, 0x024f };
const headings = [_]u8{ routing.graph.headings.encode(90), routing.graph.headings.encode(270) };
const lb_speeds = [_]u8{ routing.graph.speed.upperBound(edges[0]), routing.graph.speed.upperBound(edges[1]) };
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
    "\x01\x00\x00\x00\x01\x00\x00\x00\x6a\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x4a\x00\x00\x00\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x3a\x00\x00\x00\x00\x00\x00\x00" ++
    "\xef\xcd\xab\x89\x67\x45\x23\x01\x06\x00\x00\x00\x02\x00\x00\x00\x0c\xfe\x23\x01" ++
    "\x00\x00\x00\xc0\x9a\x0c\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x60\x10\x00\x00\x00" ++
    "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x16\x05\x00" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00Main";

const main_text: transit.Text = @fromBackingInt(0);
const platform: transit.Place = .{
    .coordinate = coordinates[0],
    .name = main_text,
    .one_stop_id = main_text,
    .timezone = main_text,
    .graph_node = 0,
    .flags = .{ .traversability = .forward, .generated = true, .wheelchair_boarding = true },
};
const departures = [_]transit.Departure{
    .{ .line = 0, .route = 0, .trip = 1 << 20, .block = 1 << 22, .schedule = 0, .headsign = main_text, .start_time = 100, .end_time = 131, .headway = 10, .elapsed_time = 25, .flags = .{ .kind = .frequency, .wheelchair = true, .bicycle = true } },
    .{ .line = 0, .route = 0, .trip = 41, .block = 18, .schedule = 0, .headsign = main_text, .start_time = 105, .end_time = 130, .headway = 12, .elapsed_time = 38, .flags = .{ .kind = .frequency, .bicycle = true } },
    .{ .line = 0, .route = 0, .trip = 42, .block = 19, .schedule = 0, .headsign = main_text, .start_time = 109, .elapsed_time = 40, .flags = .{ .wheelchair = true } },
    .{ .line = 0, .route = 0, .trip = 43, .block = 20, .schedule = 0, .headsign = main_text, .start_time = 120, .elapsed_time = 41 },
    .{ .line = 1, .route = 0, .trip = 44, .block = 21, .schedule = 0, .headsign = main_text, .start_time = 90062, .elapsed_time = 61 },
};

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
        .dataset_id => &.{1001},
        .snap_bins => &([_]u32{ 1, 818660 } ++ (@as([25]u32, @splat(1))) ++ [_]u32{ 0, @bitCast(routing.graph.snap_bins.Circle.absent) }),
        .components => &.{ 0, 0 },
        .turn_sides => &.{ 3, 0, 0 },
        .headings => &headings,
        .lb_speeds => &lb_speeds,
        .turnlanes => &.{ 1, 0, 0, 0, 0, 0, 8, 66, 0 },
        .lane_connectivity => &.{.{ .edge = 0, .from_way = 0x1234_5678_9abc, .to_lanes = 0x21, .from_lanes = 0x31 }},
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
            .{ .edge = 1, .first = 6, .end = 6, .failure = 0, .attr = .{ .depth = 2, .forbidden = 1, .timed = true, .probable = true } },
            .{ .edge = 0, .first = 6, .end = 6, .failure = 1, .attr = .{ .depth = 2, .reverse = true, .forbidden = 1, .timed = true, .probable = true } },
        },
        .signs => &.{
            .{ .cell = 0x7e90b400, .owner = 0, .text_ref = 0, .attr = .{ .sign_type = .exit_branch, .route_number = true } },
            .{ .cell = 0x7e90b400, .owner = 0, .text_ref = 0, .attr = .{ .sign_type = .junction_name, .tagged = true } },
        },
        .restriction_conditions => &.{
            .{ .state = 4, .attr = .{ .modes = 4, .probability = 75 }, .domain = 0 },
            .{ .state = 4, .attr = .{ .modes = 4 }, .domain = 23622321788 },
            .{ .state = 5, .attr = .{ .modes = 4, .probability = 75 }, .domain = 0 },
            .{ .state = 5, .attr = .{ .modes = 4 }, .domain = 23622321788 },
        },
        .transit_metadata => &.{.{ .start_day = 20864 }},
        .transit_stops => &.{
            .{ .place = platform, .station = 0 },
            .{ .place = .{ .coordinate = coordinates[1], .name = .none, .one_stop_id = main_text, .graph_node = 1 } },
        },
        .transit_stations => &.{.{ .place = platform }},
        .transit_egresses => &.{.{
            .place = platform,
            .station = 0,
            .connecting_way = 0x0123_4567_89ab_cdef,
            .connecting_point = .{ .lng = -123, .lat = 456 },
            .flags = .{ .has_connecting_way = true, .has_connecting_point = true },
        }},
        .transit_routes => &.{.{
            .one_stop_id = main_text,
            .operator_one_stop_id = main_text,
            .operator_name = main_text,
            .operator_website = main_text,
            .short_name = main_text,
            .long_name = main_text,
            .description = main_text,
            .color = main_text,
            .text_color = main_text,
            .flags = .{ .vehicle = .rail },
        }},
        .transit_lines => &.{
            .{ .origin = 0, .destination = 1, .route = 0, .shape = 87, .departures = .{ .count = 4 }, .occurrences = .{ .count = 9 } },
            .{ .origin = 1, .destination = 0, .route = 0, .departures = .{ .first = 4, .count = 1 }, .occurrences = .{ .first = 9 } },
        },
        .transit_departures => &departures,
        .transit_occurrences => &.{
            .{ .time = 100, .departure = 0 }, .{ .time = 105, .departure = 1 },
            .{ .time = 109, .departure = 2 }, .{ .time = 110, .departure = 0 },
            .{ .time = 117, .departure = 1 }, .{ .time = 120, .departure = 0 },
            .{ .time = 120, .departure = 3 }, .{ .time = 129, .departure = 1 },
            .{ .time = 130, .departure = 0 },
        },
        .transit_schedules => &.{.{ .days = .{ .count = 4 }, .day_count = 100, .exceptions = .{ .count = 2 }, .flags = .{ .weekdays = 0b0111110 } }},
        .transit_days => &.{ .{ .bits = 1 }, .{ .bits = 0 }, .{ .bits = 0x21 }, .{ .bits = 8 } },
        .transit_exceptions => &.{ .{ .day = -4, .flags = .{ .active = true } }, .{ .day = 69, .flags = .{ .active = false } } },
        .transit_transfers => &.{
            .{ .origin = 1, .destination = 0, .origin_route = 0, .destination_route = 0, .minimum_time = 180, .flags = .{ .kind = .minimum_time } },
            .{ .origin_trip = 42, .destination_trip = 44, .flags = .{ .kind = .in_seat } },
        },
        .edge_keys => &keys,
        .edge_key_inverse, .edge_key_hash_slots => &.{ 0, 1 },
        .edge_key_hash_header => &.{.{ .seed = hash_seed }},
        .edge_key_hash_buckets => &hash_buckets,
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
    try writeFixture(path, null);
}

pub fn writeTransit(a: std.mem.Allocator, path: []const u8) !void {
    const index = try transit.indexDepartures(a, records(.transit_lines), &departures, .none);
    defer index.deinit(a);
    try writeFixture(path, index);
}

fn writeFixture(path: []const u8, index: ?transit.Indexed) !void {
    var writer = try format.BundleWriter.init(path, uuid, .none);
    defer writer.deinit();
    inline for (std.enums.values(format.SectionKind)) |kind| {
        if (comptime std.mem.indexOfScalar(format.SectionKind, &format.transit_sections, kind) != null) {
            if (index) |table| try writer.write(kind, switch (kind) {
                .transit_lines => table.lines,
                .transit_occurrences => table.occurrences,
                else => records(kind),
            });
        } else try writer.write(kind, records(kind));
    }
    try writer.commit();
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const output = args.next() orelse return error.MissingOutputPath;
    if (args.next() != null) return error.ExtraArguments;
    const path = try std.fs.path.join(init.arena.allocator(), &.{ output, "bundle" });
    try writeTransit(init.arena.allocator(), path);
}
