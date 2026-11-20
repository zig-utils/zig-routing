// Ported from src/odin/maneuversbuilder.cc (Valhalla 3.9.3).
// TripLeg supplies the source dataset ID. Native bundle propagation is tracked in P6.09a.
const std = @import("std");
const trip = @import("../api/trip.zig");
const enhanced = @import("enhanced.zig");
const Maneuver = @import("maneuver.zig").Maneuver;
const GuidanceView = @import("../api/directions.zig").GuidanceView;

const view_edge_limit = 5;
const Image = struct {
    prefix: []const u8,
    suffix: []const u8,

    // The upstream getline loop discards the final empty field.
    fn parse(text: []const u8) ?Image {
        const fields = if (std.mem.endsWith(u8, text, ";")) text[0 .. text.len - 1] else text;
        var parts = std.mem.splitScalar(u8, fields, ';');
        const prefix = parts.next() orelse return null;
        const suffix = parts.next() orelse return null;
        if (parts.next() != null) return null;
        return .{ .prefix = prefix, .suffix = suffix };
    }

    fn id(self: Image, arena: std.mem.Allocator) ![]const u8 {
        return std.mem.concat(arena, u8, &.{ self.prefix, self.suffix });
    }
};

// Ported from ManeuversBuilder::ProcessGuidanceViews.
pub fn process(arena: std.mem.Allocator, leg: enhanced.Leg, values: []Maneuver) !void {
    var data_id: ?[]const u8 = null;
    for (values) |*value| {
        if (leg.deadline.expired()) return error.DeadlineExceeded;
        if (value.travel_mode != .kDrive) continue;
        const start = value.begin_node_index;
        const end = @min(value.end_node_index, start +| view_edge_limit);
        var views: std.ArrayList(GuidanceView) = .empty;
        if (leg.prevEdge(start, 1)) |edge| {
            if (edge.value.sign) |sign| {
                for (sign.guidance_view_junctions) |entry| {
                    if (leg.deadline.expired()) return error.DeadlineExceeded;
                    if (!entry.is_route_number) continue;
                    const base = Image.parse(entry.text) orelse continue;
                    const overlay = try matchJunctionOverlay(leg, start, end, base.prefix) orelse continue;
                    const ids = try arena.alloc([]const u8, 1);
                    ids[0] = try overlay.id(arena);
                    try views.append(arena, .{ .type = .kJunction, .base_id = try base.id(arena), .overlay_ids = ids });
                }
            }
        }
        try appendSignboards(arena, leg, start, end, &views);
        if (views.items.len == 0) continue;
        if (data_id == null) data_id = try std.fmt.allocPrint(arena, "{d}", .{leg.value.osm_changeset});
        for (views.items) |*view| {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            view.data_id = data_id.?;
        }
        value.guidance_views = views.items;
    }
}

// Ported from ManeuversBuilder::MatchGuidanceViewJunctions.
fn matchJunctionOverlay(leg: enhanced.Leg, start: u32, end: u32, prefix: []const u8) !?Image {
    for (start..end) |index| {
        const edge = leg.currEdge(index) orelse continue;
        const sign = edge.value.sign orelse continue;
        for (sign.guidance_view_junctions) |entry| {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            if (entry.is_route_number) continue;
            const overlay = Image.parse(entry.text) orelse continue;
            if (std.mem.eql(u8, prefix, overlay.prefix)) return overlay;
        }
    }
    return null;
}

// Ported from ManeuversBuilder::ProcessGuidanceViewSignboards.
fn appendSignboards(arena: std.mem.Allocator, leg: enhanced.Leg, start: u32, end: u32, views: *std.ArrayList(GuidanceView)) !void {
    for (start..end) |index| {
        const edge = leg.currEdge(index) orelse continue;
        const sign = edge.value.sign orelse continue;
        for (sign.guidance_view_signboards) |entry| {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            if (!entry.is_route_number) continue;
            const base = Image.parse(entry.text) orelse continue;
            try views.append(arena, .{ .type = .kSignboard, .base_id = try base.id(arena) });
        }
    }
}

// Ported from the junction and signboard cases in test/gurka/test_guidance_views*.cc.
test "guidance view signs attach the first matching overlay and signboard" {
    const nodes = [_]trip.Node{
        .{ .edge = .{ .sign = .{ .guidance_view_junctions = &.{.{ .text = "PA717;1", .is_route_number = true }} } } },
        .{ .edge = .{ .sign = .{ .guidance_view_signboards = &.{.{ .text = "SI_53271604;A1", .is_route_number = true }} } } },
        .{ .edge = .{ .sign = .{ .guidance_view_junctions = &.{ .{ .text = "PA715;1" }, .{ .text = "PA717;E" }, .{ .text = "PA717;F" } } } } },
        .{},
    };
    const leg: trip.TripLeg = .{ .osm_changeset = 1001, .node = &nodes };
    var values = [_]Maneuver{
        .{ .type = .kStart, .end_node_index = 1 },
        .{ .type = .kExitRight, .begin_node_index = 1, .end_node_index = 3 },
        .{ .type = .kDestination, .begin_node_index = 3, .end_node_index = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try process(arena.allocator(), .{ .value = &leg }, &values);
    try std.testing.expectEqual(@as(usize, 0), values[0].guidance_views.len);
    try std.testing.expectEqual(@as(usize, 0), values[2].guidance_views.len);
    try std.testing.expectEqualDeep(@as([]const GuidanceView, &.{
        .{ .type = .kJunction, .base_id = "PA7171", .overlay_ids = &.{"PA717E"}, .data_id = "1001" },
        .{ .type = .kSignboard, .base_id = "SI_53271604A1", .data_id = "1001" },
    }), values[1].guidance_views);
}
