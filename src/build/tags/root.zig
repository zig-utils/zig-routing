// Ported from lua/graph.lua, ways_proc and nodes_proc (Valhalla 3.9.3).

const std = @import("std");
const io = @import("../../infra/io.zig");
const pbf = @import("../pbf/root.zig");
const osm = @import("../osm.zig");
const attrs = @import("attrs.zig");
const access = @import("access.zig");
const bike_foot = @import("bike_foot.zig");
const highway = @import("highway.zig");
const selection = @import("selection.zig");
pub const speed = @import("speed.zig");
pub const names = @import("names.zig");

pub const table = @import("table.zig");
pub const defaults = @import("defaults.zig");
pub const Scratch = @import("input.zig").Scratch;
pub const WayAttrs = attrs.WayAttrs;
pub const NodeAttrs = attrs.NodeAttrs;

/// The input is an OSM tag slice or a PBF TagIterator. The scratch is private
/// to the worker and the returned refs borrow the input, including PBF bytes.
pub fn transformWay(scratch: *Scratch, tags: anytype, deadline: io.Deadline) !?WayAttrs {
    try scratch.load(tags, deadline);
    const selected = try selection.select(scratch, deadline) orelse return null;
    var result: WayAttrs = .{
        .road_class = selected.road_class,
        .forward_access = selected.forward,
        .backward_access = selected.backward,
        .bicycle = try bike_foot.readMountainBike(scratch, deadline),
        .flags = .{
            .oneway = selected.oneway,
            .oneway_reverse = selected.oneway_reverse,
            .roundabout = selected.roundabout,
            .ferry = selected.ferry,
            .rail = selected.rail,
            .pedestrian_area = selected.pedestrian_area,
        },
        .names = names.read(scratch),
    };
    try highway.classify(scratch, selected, deadline, &result);
    try access.applyWay(scratch, selected, deadline, &result);
    try bike_foot.applyWay(&result, scratch, selected, deadline);
    try speed.apply(&result, scratch, selected.road_class, deadline);
    return result;
}

pub const IndexedWay = struct {
    attributes: WayAttrs,
    names: names.Indexed,
};

/// Own the names for graph construction while retaining the other attributes.
pub fn transformIndexedWay(
    scratch: *Scratch,
    strings: *names.StringTable,
    tags: anytype,
    options: names.Options,
    deadline: io.Deadline,
) !?IndexedWay {
    const way = try transformWay(scratch, tags, deadline) orelse return null;
    return .{ .attributes = way, .names = try strings.indexWay(way, tags, options, deadline) };
}

/// nodes_proc returns keep even for untagged nodes. The node usage pass
/// independently decides which coordinates the graph needs.
pub fn transformNode(scratch: *Scratch, tags: anytype, deadline: io.Deadline) !?NodeAttrs {
    try scratch.load(tags, deadline);
    var result: NodeAttrs = .{ .name = scratch.text(.name), .ref = scratch.text(.ref), .exit_to = scratch.text(.exit_to) };
    try access.applyNode(scratch, deadline, &result);
    try bike_foot.applyNode(&result, scratch, deadline);
    return result;
}

/// Selection callback for the node store's way usage pass.
pub fn includePbfWay(scratch: *Scratch, way: *const pbf.block.Way) !bool {
    const deadline = way.tags.deadline;
    try scratch.load(way.tags, deadline);
    return try selection.select(scratch, deadline) != null;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("access_test.zig");
    _ = @import("speed_names_test.zig");
    _ = @import("bike_foot_test.zig");
}

test "ways_proc keeps exactly the routable ways and the upstream exceptions" {
    const testing = std.testing;
    const cases = [_]struct { tags: []const osm.Tag, keep: bool }{
        .{ .tags = &.{}, .keep = false },
        .{ .tags = &.{.{ .key = "name", .value = "Path to nowhere" }}, .keep = false },
        .{ .tags = &.{.{ .key = "highway", .value = "unknown" }}, .keep = false },
        .{ .tags = &.{.{ .key = "highway", .value = "cycleway" }}, .keep = true },
        .{ .tags = &.{.{ .key = "highway", .value = "footway" }}, .keep = true },
        .{ .tags = &.{.{ .key = "highway", .value = "construction" }}, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "construction" }, .{ .key = "construction", .value = "primary" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "construction" }, .{ .key = "construction", .value = "proposed" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "proposed" }, .{ .key = "route", .value = "ferry" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "area", .value = "yes" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "pedestrian" }, .{ .key = "area", .value = "yes" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "residential" }, .{ .key = "area", .value = "true" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "bridleway" }, .{ .key = "access", .value = "no" } }, .keep = true },
        .{ .tags = &.{.{ .key = "railway", .value = "tram" }}, .keep = false },
        .{ .tags = &.{.{ .key = "route", .value = "shuttle_train" }}, .keep = true },
        .{ .tags = &.{.{ .key = "route", .value = "ferry" }}, .keep = true },
        .{ .tags = &.{ .{ .key = "route", .value = "ferry" }, .{ .key = "access", .value = "no" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "route", .value = "ferry" }, .{ .key = "access", .value = "no" }, .{ .key = "foot", .value = "yes" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "unknown" }, .{ .key = "emergency", .value = "yes" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "road" }, .{ .key = "access", .value = "no" }, .{ .key = "taxi", .value = "yes" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "road" }, .{ .key = "access", .value = "no" }, .{ .key = "bus", .value = "yes" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "access", .value = "no" }, .{ .key = "foot:forward", .value = "unrecognised" } }, .keep = true },
        .{ .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "access", .value = "permissive" }, .{ .key = "oneway", .value = "reversible" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "road" }, .{ .key = "access", .value = "permissive" }, .{ .key = "oneway", .value = "reversible" } }, .keep = true },
        .{ .tags = &.{.{ .key = "service", .value = "driveway" }}, .keep = true },
        .{ .tags = &.{.{ .key = "lanes:bus", .value = "1" }}, .keep = true },
        .{ .tags = &.{.{ .key = "lanes:psv", .value = "1" }}, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "foot", .value = "no" } }, .keep = false },
        .{ .tags = &.{ .{ .key = "highway", .value = "footway" }, .{ .key = "foot", .value = "no;yes" } }, .keep = true },
    };
    var scratch: Scratch = .{};
    for (cases, 0..) |case, i| {
        const got = (try transformWay(&scratch, case.tags, .none)) != null;
        if (got != case.keep) std.debug.print("way retention case {d}: {any}\n", .{ i, case.tags });
        try testing.expectEqual(case.keep, got);
    }
}

test "tag scratch reuse, name refs, duplicate keys and node retention" {
    const testing = std.testing;
    const empty: []const osm.Tag = &.{};
    const way: []const osm.Tag = &.{
        .{ .key = "highway", .value = "motorway" },
        .{ .key = "highway", .value = "residential" },
        .{ .key = "name", .value = "Oude Gracht" },
        .{ .key = "ref", .value = "N430" },
        .{ .key = "oneway", .value = "-1" },
        .{ .key = "source", .value = "survey" },
    };
    var scratch: Scratch = .{};
    const attrs_before = (try transformWay(&scratch, way, .none)).?;
    try testing.expectEqual(.residential, attrs_before.road_class);
    try testing.expectEqual(35, attrs_before.speed);
    try testing.expect(attrs_before.flags.oneway_reverse);
    try testing.expect(!attrs_before.forward_access.auto);
    try testing.expect(attrs_before.backward_access.auto);
    try testing.expectEqual(null, try transformWay(&scratch, empty, .none));
    try testing.expectEqualStrings("Oude Gracht", attrs_before.names.name.?);
    try testing.expectEqualStrings("N430", attrs_before.names.ref.?);
    const untagged = (try transformNode(&scratch, empty, .none)).?;
    try testing.expectEqual(.street_intersection, untagged.type);
    try testing.expect(untagged.access.pedestrian);
    try testing.expectError(error.DeadlineExceeded, transformWay(&scratch, way, .{ .at_ns = 0 }));
}

test "classification covers every highway in the Valhalla default table" {
    const testing = std.testing;
    const constants = @import("../../graph/constants.zig");
    const cases = [_]struct {
        highway: []const u8,
        class: ?constants.RoadClass = .service_other,
        use: constants.Use = .road,
        surface: constants.Surface = .paved_smooth,
        link: bool = false,
    }{
        .{ .highway = "motorway", .class = .motorway },
        .{ .highway = "motorway_link", .class = .motorway, .link = true },
        .{ .highway = "trunk", .class = .trunk },
        .{ .highway = "trunk_link", .class = .trunk, .link = true },
        .{ .highway = "primary", .class = .primary },
        .{ .highway = "primary_link", .class = .primary, .link = true },
        .{ .highway = "secondary", .class = .secondary },
        .{ .highway = "secondary_link", .class = .secondary, .link = true },
        .{ .highway = "tertiary", .class = .tertiary },
        .{ .highway = "tertiary_link", .class = .tertiary, .link = true },
        .{ .highway = "residential", .class = .residential },
        .{ .highway = "residential_link", .class = .residential, .link = true },
        .{ .highway = "unclassified", .class = .unclassified },
        .{ .highway = "road" },
        .{ .highway = "service", .use = .service_road },
        .{ .highway = "track", .use = .track, .surface = .dirt },
        .{ .highway = "living_street", .use = .living_street },
        .{ .highway = "undefined", .class = null },
        .{ .highway = "unknown", .class = null },
        .{ .highway = "ladder", .use = .ladder, .surface = .paved },
        .{ .highway = "footway", .use = .footway, .surface = .compacted },
        .{ .highway = "pedestrian", .use = .pedestrian, .surface = .compacted },
        .{ .highway = "steps", .use = .steps, .surface = .paved },
        .{ .highway = "bridleway", .use = .bridleway, .surface = .compacted },
        .{ .highway = "cycleway", .use = .cycleway, .surface = .paved },
        .{ .highway = "path", .use = .path, .surface = .compacted },
        .{ .highway = "bus_guideway" },
        .{ .highway = "busway" },
        .{ .highway = "corridor", .use = .pedestrian, .surface = .compacted },
        .{ .highway = "elevator", .use = .elevator, .surface = .paved },
        .{ .highway = "platform", .use = .platform, .surface = .paved },
        .{ .highway = "via_ferrata", .use = .pedestrian, .surface = .path },
    };
    var scratch: Scratch = .{};
    for (cases) |case| {
        const input: []const osm.Tag = &.{.{ .key = "highway", .value = case.highway }};
        const result = try transformWay(&scratch, input, .none);
        if (case.class) |class| {
            const way = result orelse return error.UnexpectedWayDrop;
            try testing.expectEqual(class, way.road_class);
            try testing.expectEqual(case.use, way.use);
            try testing.expectEqual(case.surface, way.surface);
            try testing.expectEqual(case.link, way.flags.link);
        } else {
            try testing.expectEqual(null, result);
        }
    }
}

test "way surfaces preserve precedence, case folding and defaults" {
    const testing = std.testing;
    const constants = @import("../../graph/constants.zig");
    const cases = [_]struct { tags: []const osm.Tag, surface: constants.Surface }{
        .{ .tags = &.{.{ .key = "surface", .value = "AsPhaLt;UnPaved" }}, .surface = .gravel },
        .{ .tags = &.{.{ .key = "surface", .value = "CONCRETE:PLATES" }}, .surface = .paved_smooth },
        .{ .tags = &.{.{ .key = "surface", .value = "grass_paver" }}, .surface = .paved },
        .{ .tags = &.{.{ .key = "surface", .value = "Stone" }}, .surface = .paved_rough },
        .{ .tags = &.{.{ .key = "surface", .value = "pebblestone" }}, .surface = .gravel },
        .{ .tags = &.{.{ .key = "surface", .value = "boardwalk" }}, .surface = .compacted },
        .{ .tags = &.{.{ .key = "surface", .value = "laterite" }}, .surface = .dirt },
        .{ .tags = &.{.{ .key = "surface", .value = "stepping_stones" }}, .surface = .path },
        .{ .tags = &.{ .{ .key = "surface", .value = "unknown" }, .{ .key = "tracktype", .value = "grade1" } }, .surface = .compacted },
        .{ .tags = &.{ .{ .key = "tracktype", .value = "foo" }, .{ .key = "smoothness", .value = "good" } }, .surface = .compacted },
        .{ .tags = &.{ .{ .key = "tracktype", .value = "grade1" }, .{ .key = "smoothness", .value = "good" } }, .surface = .paved_rough },
        .{ .tags = &.{.{ .key = "tracktype", .value = "grade2" }}, .surface = .compacted },
        .{ .tags = &.{.{ .key = "tracktype", .value = "grade3" }}, .surface = .dirt },
        .{ .tags = &.{.{ .key = "tracktype", .value = "grade4" }}, .surface = .gravel },
        .{ .tags = &.{.{ .key = "tracktype", .value = "grade5" }}, .surface = .path },
        .{ .tags = &.{.{ .key = "smoothness", .value = "impassable" }}, .surface = .impassable },
        .{ .tags = &.{.{ .key = "sac_scale", .value = "hiking" }}, .surface = .path },
        .{ .tags = &.{ .{ .key = "surface", .value = "cobblestone" }, .{ .key = "mtb:scale", .value = "+1+" } }, .surface = .gravel },
        .{ .tags = &.{ .{ .key = "mtb:scale", .value = "-1" }, .{ .key = "mtb:scale:uphill", .value = "5" } }, .surface = .compacted },
        .{ .tags = &.{.{ .key = "mtb:scale:uphill", .value = "5" }}, .surface = .path },
    };
    var scratch: Scratch = .{};
    for (cases) |case| {
        var input: [4]osm.Tag = undefined;
        input[0] = .{ .key = "highway", .value = "path" };
        @memcpy(input[1..][0..case.tags.len], case.tags);
        const way = (try transformWay(&scratch, input[0 .. case.tags.len + 1], .none)).?;
        try testing.expectEqual(case.surface, way.surface);
    }
}

test "transport uses, service priorities and classification flags" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    const service: []const osm.Tag = &.{
        .{ .key = "highway", .value = "service" },
        .{ .key = "service", .value = "drive-through" },
        .{ .key = "bridge", .value = "1" },
        .{ .key = "tunnel", .value = "building_passage" },
        .{ .key = "junction", .value = "intersection" },
        .{ .key = "turn_channel", .value = "true" },
    };
    const way = (try transformWay(&scratch, service, .none)).?;
    try testing.expectEqual(.drive_through, way.use);
    try testing.expect(way.flags.destination_only and way.flags.destination_only_hgv);
    try testing.expect(way.flags.bridge and way.flags.tunnel);
    try testing.expect(way.flags.tagged_internal_intersection and way.flags.turn_channel);
    try testing.expect(!way.flags.no_thru_traffic);

    const thru: []const osm.Tag = &.{
        .{ .key = "highway", .value = "residential" },
        .{ .key = "junction", .value = "roundabout" },
        .{ .key = "access", .value = "permissive;customers" },
    };
    const restricted = (try transformWay(&scratch, thru, .none)).?;
    try testing.expect(restricted.flags.roundabout and restricted.flags.no_thru_traffic);
    try testing.expect(restricted.flags.destination_only and restricted.flags.destination_only_hgv);

    const ferry: []const osm.Tag = &.{.{ .key = "route", .value = "ferry" }};
    const rail: []const osm.Tag = &.{.{ .key = "route", .value = "shuttle_train" }};
    try testing.expectEqual(.ferry, (try transformWay(&scratch, ferry, .none)).?.edgeUse());
    try testing.expectEqual(.rail_ferry, (try transformWay(&scratch, rail, .none)).?.edgeUse());

    const construction: []const osm.Tag = &.{
        .{ .key = "highway", .value = "construction" },
        .{ .key = "construction", .value = "tertiary_link" },
        .{ .key = "route", .value = "ferry" },
    };
    const work = (try transformWay(&scratch, construction, .none)).?;
    try testing.expectEqual(.primary, work.road_class);
    try testing.expectEqual(.construction, work.edgeUse());
    try testing.expect(work.flags.link);
}
