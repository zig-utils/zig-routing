// Ported from lua/graph.lua, ways_proc and nodes_proc (Valhalla 3.9.3).

const std = @import("std");
const io = @import("../../infra/io.zig");
const pbf = @import("../pbf/root.zig");
const osm = @import("../osm.zig");
const attrs = @import("attrs.zig");
const selection = @import("selection.zig");

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
    const base_speed = defaults.speed(selected.road_class);
    return .{
        .road_class = selected.road_class,
        .forward_access = selected.forward,
        .backward_access = selected.backward,
        .speed = if (scratch.id(.service) == .driveway) base_speed / 2 else base_speed,
        .flags = .{
            .oneway = selected.oneway,
            .oneway_reverse = selected.oneway_reverse,
            .roundabout = selected.roundabout,
            .ferry = selected.ferry,
            .rail = selected.rail,
            .pedestrian_area = selected.pedestrian_area,
            .tagged_internal_intersection = scratch.id(.junction) == .intersection,
        },
        .names = .{
            .name = scratch.text(.name),
            .alt_name = scratch.text(.alt_name),
            .official_name = scratch.text(.official_name),
            .ref = scratch.text(.ref),
            .int_ref = scratch.text(.int_ref),
            .destination = scratch.text(.destination),
            .destination_forward = scratch.text(.@"destination:forward"),
            .destination_backward = scratch.text(.@"destination:backward"),
            .destination_ref = scratch.text(.@"destination:ref"),
            .destination_street = scratch.text(.@"destination:street"),
            .junction_ref = scratch.text(.junction_ref),
            .junction_name = scratch.text(.junction_name),
        },
    };
}

/// nodes_proc returns keep even for untagged nodes. The node usage pass
/// independently decides which coordinates the graph needs.
pub fn transformNode(scratch: *Scratch, tags: anytype, deadline: io.Deadline) !?NodeAttrs {
    try scratch.load(tags, deadline);
    return .{ .name = scratch.text(.name), .ref = scratch.text(.ref), .exit_to = scratch.text(.exit_to) };
}

/// Selection callback for the node store's way usage pass.
pub fn includePbfWay(scratch: *Scratch, way: *const pbf.block.Way) !bool {
    const deadline = way.tags.deadline;
    try scratch.load(way.tags, deadline);
    return try selection.select(scratch, deadline) != null;
}

test {
    std.testing.refAllDecls(@This());
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
