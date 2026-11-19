// Ported from lua/graph.lua's speed and lane normalization and
// src/mjolnir/pbfgraphparser.cc's speed selection (Valhalla 3.9.3).

const std = @import("std");
const constants = @import("../../graph/constants.zig");
const io = @import("../../infra/io.zig");
const attrs = @import("attrs.zig");
const defaults = @import("defaults.zig");
const Scratch = @import("input.zig").Scratch;
const DeadlineError = error{DeadlineExceeded};

pub const Limit = union(enum) {
    kph: f32,
    unlimited,
    zone: []const u8,
};

pub fn parseLimit(text: []const u8, deadline: io.Deadline) DeadlineError!?Limit {
    if (std.mem.eql(u8, text, "walk")) return .{ .kph = 5 };
    if (std.mem.eql(u8, text, "none")) return .unlimited;
    if (try numeric(text, deadline)) |value| return .{ .kph = value };
    if (try isZone(text, deadline)) return .{ .zone = text };
    return null;
}

fn isZone(text: []const u8, deadline: io.Deadline) DeadlineError!bool {
    if (text.len < 4 or text[2] != ':' or !std.ascii.isAlphabetic(text[0]) or
        !std.ascii.isAlphabetic(text[1]))
        return false;
    for (text[3..], 0..) |byte, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != ':' and byte != '-')
            return false;
    }
    return true;
}

fn numeric(text: []const u8, deadline: io.Deadline) DeadlineError!?f32 {
    const value = try defaults.normalizeSpeed(text, deadline) orelse return null;
    const converted: f32 = @floatCast(value);
    return if (std.math.isFinite(converted)) converted else null;
}

pub fn laneCount(text: []const u8, deadline: io.Deadline) DeadlineError!?u4 {
    const prefix = try defaults.numericPrefix(text, false, deadline);
    const count = std.fmt.parseInt(u8, prefix, 10) catch return null;
    return if (count <= constants.max_lane_count) @intCast(count) else null;
}

/// Valhalla reads colon-delimited ferry durations as hours and minutes,
/// with an optional seconds field.
pub fn ferryDuration(text: []const u8, deadline: io.Deadline) DeadlineError!u32 {
    var delimiters: usize = 0;
    for (text, 0..) |c, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        delimiters += @intFromBool(c == ':');
        if (delimiters > 2) return 0;
    }
    if (delimiters == 0) return 0;
    const units = [_]u32{ 3600, 60, 1 };
    var rest = text;
    var seconds: u32 = 0;
    for (units[0 .. delimiters + 1]) |unit| {
        rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
        if (rest.len == 0) break;
        const signed = rest[0] == '-' or rest[0] == '+';
        const negative = rest[0] == '-';
        const digits = try defaults.numericPrefix(rest[@intFromBool(signed)..], false, deadline);
        if (digits.len == 0) break;
        const value = std.fmt.parseInt(u32, digits, 10) catch {
            seconds +%= std.math.maxInt(u32) *% unit;
            break;
        };
        seconds +%= (if (negative) 0 -% value else value) *% unit;
        const end = digits.len + @as(usize, @intFromBool(signed));
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    return seconds;
}

fn clamped(value: f32) u8 {
    return @intFromFloat(@min(constants.max_assumed_speed, value + 0.5));
}

fn classifiedSpeed(tags: *const Scratch, road_class: constants.RoadClass) u8 {
    // Track grades override the road-class and driveway defaults.
    if (tags.id(.highway) == .track) return switch (tags.id(.tracktype) orelse .unknown) {
        .grade1 => 20,
        .grade2 => 15,
        .grade3 => 12,
        .grade4 => 10,
        else => 5,
    };
    const base = defaults.speed(road_class);
    return if (tags.id(.service) == .driveway) base / 2 else base;
}

pub fn apply(way: *attrs.WayAttrs, tags: *const Scratch, road_class: constants.RoadClass, deadline: io.Deadline) DeadlineError!void {
    if (way.flags.ferry) {
        if (tags.text(.duration)) |text| way.ferry_duration_s = try ferryDuration(text, deadline);
    }
    const base = classifiedSpeed(tags, road_class);
    const limit = try parseLimit(tags.text(.maxspeed) orelse "", deadline);
    const tagged_limit: ?f32 = if (limit) |limit_value| switch (limit_value) {
        .kph => |value| value,
        .unlimited => constants.unlimited_speed_limit,
        // Keep the country label. Valhalla uses the classified speed for it.
        .zone => |value| blk: {
            way.speed_zone = value;
            break :blk null;
        },
    } else null;

    const practical = try numeric(tags.text(.@"maxspeed:practical") orelse "", deadline);
    const advisory = try numeric(tags.text(.@"maxspeed:advisory") orelse "", deadline);
    const forward = try numeric(tags.text(.@"maxspeed:forward") orelse "", deadline);
    const backward = try numeric(tags.text(.@"maxspeed:backward") orelse "", deadline);
    const truck = try numeric(tags.text(.@"maxspeed:hgv") orelse "", deadline);
    const ordinary_limit = if (tagged_limit != constants.unlimited_speed_limit) tagged_limit else null;
    const travel = practical orelse advisory orelse ordinary_limit;
    way.flags.tagged_speed = practical != null or advisory != null or tagged_limit != null;
    way.speed = if (travel) |value| clamped(value) else if (forward == null and backward == null) base else 0;
    way.speed_limit = if (tagged_limit) |value|
        if (value == constants.unlimited_speed_limit) constants.unlimited_speed_limit else clamped(value)
    else
        0;
    way.forward_speed = if (forward) |value| clamped(value) else 0;
    way.backward_speed = if (backward) |value| clamped(value) else 0;
    way.truck_speed = if (truck) |value| clamped(value) else 0;
    way.flags.forward_tagged_speed = forward != null;
    way.flags.backward_tagged_speed = backward != null;

    if (way.flags.forward_tagged_speed != way.flags.backward_tagged_speed) {
        if (way.flags.oneway) {
            way.speed = base;
        } else if (way.flags.forward_tagged_speed) {
            way.backward_speed = way.forward_speed;
            way.flags.backward_tagged_speed = true;
        } else {
            way.forward_speed = way.backward_speed;
            way.flags.forward_tagged_speed = true;
        }
    }

    if (try laneCount(tags.text(.lanes) orelse "", deadline)) |count| {
        way.lanes = count;
        way.flags.tagged_lanes = true;
    }
    if (try laneCount(tags.text(.@"lanes:forward") orelse "", deadline)) |count| {
        way.forward_lanes = count;
        way.flags.forward_tagged_lanes = true;
    }
    if (try laneCount(tags.text(.@"lanes:backward") orelse "", deadline)) |count| {
        way.backward_lanes = count;
        way.flags.backward_tagged_lanes = true;
    }
    way.turn_lanes = .{
        .general = tags.text(.@"turn:lanes"),
        .forward = tags.text(.@"turn:lanes:forward"),
        .backward = tags.text(.@"turn:lanes:backward"),
    };
}

test "Valhalla ferry durations accept hours, minutes and optional seconds" {
    const testing = std.testing;
    try testing.expectEqual(5400, try ferryDuration("01:30", .none));
    try testing.expectEqual(5415, try ferryDuration("01:30:15", .none));
    try testing.expectEqual(300, try ferryDuration("0:5", .none));
    try testing.expectEqual(3600, try ferryDuration("01:", .none));
    try testing.expectEqual(0, try ferryDuration("30", .none));
    try testing.expectEqual(0, try ferryDuration("0:1:2:3", .none));
}

test "Valhalla maxspeed formats" {
    const testing = std.testing;
    const numeric_cases = [_]struct { tag: []const u8, speed: f32 }{
        .{ .tag = "50", .speed = 50 },
        .{ .tag = "80 kph", .speed = 80 },
        .{ .tag = "60 km/h", .speed = 60 },
        .{ .tag = "30 mph", .speed = 48 },
        .{ .tag = "45mph", .speed = 72 },
        .{ .tag = "walk", .speed = 5 },
        .{ .tag = "30.5", .speed = 30 },
    };
    for (numeric_cases) |case| {
        try testing.expectEqual(case.speed, (try parseLimit(case.tag, .none)).?.kph);
    }
    try testing.expectEqual(Limit.unlimited, (try parseLimit("none", .none)).?);
    for ([_][]const u8{ "DE:urban", "GB:nsl_single", "AT:rural" }) |zone|
        try testing.expectEqualStrings(zone, (try parseLimit(zone, .none)).?.zone);
    for ([_][]const u8{ "", "variable", "signals", " 50", "-10", "5mph", "9", "none ", "DE:" }) |invalid|
        try testing.expectEqual(null, try parseLimit(invalid, .none));
    try testing.expectEqual(@as(?u4, 0), try laneCount("0", .none));
    try testing.expectEqual(@as(?u4, 2), try laneCount("2;3", .none));
    try testing.expectEqual(@as(?u4, 15), try laneCount("15", .none));
    try testing.expectEqual(null, try laneCount("16", .none));
    try testing.expectEqual(null, try laneCount(" 2", .none));
}
