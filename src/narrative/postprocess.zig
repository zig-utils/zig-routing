// Ported from src/odin/maneuversbuilder.cc and src/odin/narrativebuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const trip = @import("../api/trip.zig");
const enhanced = @import("enhanced.zig");
const Maneuver = @import("maneuver.zig").Maneuver;
const io = @import("../infra/io.zig");

// Ported from ManeuversBuilder::AddLandmarksFromTripLegToManeuvers.
pub fn attachLandmarks(arena: std.mem.Allocator, leg: enhanced.Leg, values: []Maneuver) !void {
    for (1..values.len) |index| {
        if (leg.deadline.expired()) return error.DeadlineExceeded;
        const approach = &values[index - 1];
        var landmarks: std.ArrayList(trip.RouteLandmark) = .empty;
        const distance: f64 = @as(f32, approach.length_km * 1000);
        var distance_before_edge: f64 = 0;
        for (approach.begin_node_index..approach.end_node_index) |node| {
            if (leg.deadline.expired()) return error.DeadlineExceeded;
            const edge = leg.currEdge(node) orelse return error.InvalidTripLeg;
            for (edge.value.landmarks, 0..) |landmark, i| {
                if (i % 64 == 0 and leg.deadline.expired()) return error.DeadlineExceeded;
                var adjusted = landmark;
                adjusted.distance = distance - landmark.distance - distance_before_edge;
                try landmarks.append(arena, adjusted);
            }
            distance_before_edge += @as(f32, edge.value.length_km * 1000);
        }
        values[index].landmarks = landmarks.items;
    }
}

// Ported from ManeuversBuilder::ProcessVerbalSuccinctTransitionInstruction.
pub fn markLongStreetNames(values: []Maneuver, deadline: io.Deadline) !void {
    for (values) |*value| {
        if (deadline.expired()) return error.DeadlineExceeded;
        value.has_long_street_name = try containsLongName(value.street_names, deadline) or
            (value.type == .kRoundaboutEnter and try containsLongName(value.roundabout_exit_street_names, deadline));
    }
}

fn containsLongName(names: []const trip.StreetName, deadline: io.Deadline) !bool {
    for (names[0..@min(names.len, 2)]) |name| {
        var words: usize = 0;
        var code_points: usize = 0;
        var in_word = false;
        for (name.value, 0..) |byte, i| {
            if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const starts_word = !std.ascii.isWhitespace(byte) and !std.ascii.isPunctuation(byte);
            words += @intFromBool(starts_word and !in_word);
            in_word = starts_word;
            code_points += @intFromBool(byte & 0xc0 != 0x80);
            if (words > 5 or code_points > 25) return true;
        }
    }
    return false;
}

/// Ported from NarrativeBuilder::FormVerbalMultiCue. Run after populating the individual cues.
pub fn setVerbalMultiCueFlags(values: []Maneuver, deadline: io.Deadline) !void {
    var previous: ?*Maneuver = null;
    for (values) |*next| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (next.pedestrian_type == .kBlind) continue;
        if (previous) |value| _ = markVerbalMultiCue(value, next);
        previous = next;
    }
}

pub fn markVerbalMultiCue(value: *Maneuver, next: *const Maneuver) bool {
    if (!canCombineCues(value, next)) return false;
    const distant = switch (next.type) {
        .kSlightRight, .kRight, .kSharpRight, .kUturnRight, .kRampRight, .kExitRight, .kStayRight => value.has_right_traversable_outbound_intersecting_edge,
        .kSlightLeft, .kLeft, .kSharpLeft, .kUturnLeft, .kRampLeft, .kExitLeft, .kStayLeft => value.has_left_traversable_outbound_intersecting_edge,
        .kDestination, .kDestinationLeft, .kDestinationRight => value.has_left_traversable_outbound_intersecting_edge or value.has_right_traversable_outbound_intersecting_edge,
        else => false,
    };
    value.distant_verbal_multi_cue = distant;
    value.imminent_verbal_multi_cue = !distant;
    return true;
}

fn canCombineCues(value: *const Maneuver, next: *const Maneuver) bool {
    const threshold: f64 = if (value.isStartType()) 39 else 13;
    return value.verbal_pre_transition_instruction.len != 0 and
        (next.verbal_transition_alert_instruction.len != 0 or next.verbal_pre_transition_instruction.len != 0) and
        value.basic_time < threshold and !next.isMergeType() and
        (!value.roundabout or value.has_combined_enter_exit_roundabout) and
        !(value.type == .kRoundaboutExit and next.roundabout) and
        !value.isTransit() and !next.isTransit() and !value.transit_connection and !next.transit_connection;
}

test "succinct transitions count separators and UTF-8 characters on the first two names" {
    const short_name: [25][2]u8 = @splat(.{ 0xc3, 0x89 });
    const long_name: [26][2]u8 = @splat(.{ 0xc3, 0x89 });
    var values = [_]Maneuver{
        .{ .street_names = &.{ .{ .value = "rue Bellevue" }, .{ .value = "N 725" }, .{ .value = "Rue de la très longue troisième place" } } },
        .{ .street_names = &.{.{ .value = "A / B-C D E F" }} },
        .{ .street_names = &.{.{ .value = std.mem.asBytes(&short_name) }} },
        .{ .type = .kRoundaboutEnter, .roundabout_exit_street_names = &.{.{ .value = std.mem.asBytes(&long_name) }} },
    };
    try markLongStreetNames(&values, .none);
    try std.testing.expect(!values[0].has_long_street_name);
    try std.testing.expect(values[1].has_long_street_name);
    try std.testing.expect(!values[2].has_long_street_name);
    try std.testing.expect(values[3].has_long_street_name);
}

test "verbal multi-cue flags depend on time and crossings in the following direction" {
    var values = [_]Maneuver{
        .{ .type = .kStart, .basic_time = 39, .verbal_pre_transition_instruction = "Walk east" },
        .{ .type = .kRight, .basic_time = 9, .verbal_pre_transition_instruction = "Turn right", .has_left_traversable_outbound_intersecting_edge = true },
        .{ .type = .kLeft, .basic_time = 4, .verbal_pre_transition_instruction = "Turn left" },
        .{ .type = .kDestination, .verbal_transition_alert_instruction = "Destination" },
    };
    try setVerbalMultiCueFlags(&values, .none);
    try std.testing.expect(!values[0].imminent_verbal_multi_cue and !values[0].distant_verbal_multi_cue);
    try std.testing.expect(values[1].distant_verbal_multi_cue);
    try std.testing.expect(values[2].imminent_verbal_multi_cue);
}
