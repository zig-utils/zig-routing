// Ported from src/odin/signs.cc and ManeuversBuilder::CountAndSortSigns.
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");
const Maneuver = @import("maneuver.zig").Maneuver;

pub fn countAndSort(arena: std.mem.Allocator, values: []Maneuver, deadline: io.Deadline) !void {
    var index = values.len;
    while (index > 1) {
        index -= 1;
        if (deadline.expired()) return error.DeadlineExceeded;
        const previous = &values[index - 1];
        const current = &values[index];
        if (previous.signs.exit_onto_streets.len != 0 and !current.hasExitSign() and current.street_names.len != 0) {
            previous.signs.exit_onto_streets = try rankBranch(arena, previous.signs.exit_onto_streets, current.street_names, deadline);
        } else if (previous.signs.guide_onto_streets.len != 0 and !current.hasGuideSign() and current.street_names.len != 0) {
            previous.signs.guide_onto_streets = try rankBranch(arena, previous.signs.guide_onto_streets, current.street_names, deadline);
        } else if (previous.hasSigns() and current.hasSigns()) {
            inline for (.{ "exit_numbers", "exit_onto_streets", "exit_toward_locations", "exit_names", "guide_onto_streets", "guide_toward_locations", "junction_names" }) |key| {
                try rankAdjacent(arena, &@field(previous.signs, key), &@field(current.signs, key), deadline);
            }
        }
    }
}

fn rankBranch(arena: std.mem.Allocator, signs: []const trip.SignElement, names: []const trip.StreetName, deadline: io.Deadline) ![]const trip.SignElement {
    const ranked = try arena.dupe(trip.SignElement, signs);
    for (ranked) |*sign| {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (names, 0..) |name, index| {
            if (index % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (std.mem.eql(u8, sign.text, name.value)) sign.consecutive_count += 1;
        }
    }
    try sort(ranked, deadline);
    return ranked;
}

fn rankAdjacent(arena: std.mem.Allocator, previous: *[]const trip.SignElement, current: *[]const trip.SignElement, deadline: io.Deadline) !void {
    if (previous.len == 0 and current.len == 0) return;
    const earlier = try arena.dupe(trip.SignElement, previous.*);
    const later = try arena.dupe(trip.SignElement, current.*);
    for (later) |*sign| {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (earlier, 0..) |*prior, index| {
            if (index % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!std.mem.eql(u8, sign.text, prior.text)) continue;
            sign.consecutive_count += 1;
            prior.consecutive_count = sign.consecutive_count;
        }
    }
    try sort(earlier, deadline);
    try sort(later, deadline);
    previous.* = earlier;
    current.* = later;
}

fn sort(signs: []trip.SignElement, deadline: io.Deadline) !void {
    for (signs, 0..) |sign, index| {
        if (deadline.expired()) return error.DeadlineExceeded;
        var target = index;
        while (target > 0 and signs[target - 1].consecutive_count < sign.consecutive_count) : (target -= 1) {
            if (target % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            signs[target] = signs[target - 1];
        }
        signs[target] = sign;
    }
}

// Ported from Maneuversbuilder.TestCountAndSortExitSigns.
test "consecutive exit signs rank matching branches and destinations" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const route_names: []const trip.StreetName = &.{.{ .value = "US 322 West", .is_route_number = true }};
    const branches = [_]trip.SignElement{
        .{ .text = "US 22 East", .is_route_number = true },
        .{ .text = "PA 230 East", .is_route_number = true },
        .{ .text = "US 22 West", .is_route_number = true },
        .{ .text = "US 322 West", .is_route_number = true },
        .{ .text = "Cameron Street" },
    };
    const destinations = [_]trip.SignElement{
        .{ .text = "Harrisburg" },
        .{ .text = "Lewistown" },
        .{ .text = "State College" },
    };
    var values = [_]Maneuver{
        .{ .type = .kStart },
        .{ .type = .kExitRight, .street_names = route_names, .signs = .{
            .exit_numbers = &.{.{ .text = "67A-B" }},
            .exit_onto_streets = &branches,
            .exit_toward_locations = &destinations,
        } },
        .{ .type = .kExitRight, .street_names = route_names, .signs = .{
            .exit_numbers = &.{.{ .text = "67B" }},
            .exit_onto_streets = branches[2..4],
            .exit_toward_locations = destinations[1..],
        } },
        .{ .type = .kMergeLeft, .street_names = route_names },
        .{ .type = .kDestination },
    };
    try countAndSort(arena.allocator(), &values, .none);
    const ranked_branches = [_]trip.SignElement{
        .{ .text = "US 322 West", .is_route_number = true, .consecutive_count = 2 },
        .{ .text = "US 22 West", .is_route_number = true, .consecutive_count = 1 },
        branches[0],
        branches[1],
        branches[4],
    };
    const ranked_destinations = [_]trip.SignElement{
        .{ .text = "Lewistown", .consecutive_count = 1 },
        .{ .text = "State College", .consecutive_count = 1 },
        destinations[0],
    };
    try testing.expectEqualDeep(&ranked_branches, values[1].signs.exit_onto_streets);
    try testing.expectEqualDeep(ranked_branches[0..2], values[2].signs.exit_onto_streets);
    try testing.expectEqualDeep(&ranked_destinations, values[1].signs.exit_toward_locations);
    try testing.expectEqualDeep(ranked_destinations[0..2], values[2].signs.exit_toward_locations);
    try testing.expectEqualDeep(@as([]const trip.SignElement, &.{.{ .text = "67A-B" }}), values[1].signs.exit_numbers);
    try testing.expectEqualDeep(@as([]const trip.SignElement, &.{.{ .text = "67B" }}), values[2].signs.exit_numbers);
}
