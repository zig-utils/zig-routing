// Ported from lua/graph.lua, lines 5-396 and 699-790 (Valhalla 3.9.3).

const std = @import("std");
const attr = @import("../../graph/attributes.zig");
const io = @import("../../infra/io.zig");
const table = @import("table.zig");
const Value = table.Value;
const TagValue = table.TagValue;
const DeadlineError = error{DeadlineExceeded};

pub const Highway = struct {
    road_class: attr.RoadClass = .service_other,
    access: attr.AccessMask,
};

pub const street: attr.AccessMask = .{
    .auto = true,
    .pedestrian = true,
    .bicycle = true,
    .truck = true,
    .taxi = true,
    .bus = true,
    .moped = true,
    .motorcycle = true,
};

const freeway: attr.AccessMask = .{ .auto = true, .truck = true, .taxi = true, .bus = true, .motorcycle = true };

pub fn highway(value: ?Value) ?Highway {
    return switch (value orelse return null) {
        .motorway, .motorway_link => .{ .road_class = .motorway, .access = freeway },
        .trunk, .trunk_link => .{ .road_class = .trunk, .access = street },
        .primary, .primary_link => .{ .road_class = .primary, .access = street },
        .secondary, .secondary_link => .{ .road_class = .secondary, .access = street },
        .tertiary, .tertiary_link => .{ .road_class = .tertiary, .access = street },
        .unclassified => .{ .road_class = .unclassified, .access = street },
        .residential, .residential_link => .{ .road_class = .residential, .access = street },
        .service, .road, .track, .living_street => .{ .access = street },
        .ladder, .footway, .pedestrian, .corridor, .elevator, .platform, .via_ferrata => .{ .access = .{ .pedestrian = true } },
        .steps, .path => .{ .access = .{ .pedestrian = true, .bicycle = true } },
        .cycleway => .{ .access = .{ .bicycle = true } },
        .busway, .bus_guideway => .{ .access = .{ .bus = true } },
        .bridleway, .undefined, .unknown => .{ .access = .{} },
        else => null,
    };
}

pub fn speed(road_class: attr.RoadClass) u8 {
    return switch (road_class) {
        .motorway => 105,
        .trunk => 90,
        .primary => 75,
        .secondary => 60,
        .tertiary => 50,
        .unclassified => 40,
        .residential => 35,
        .service_other => 25,
        .invalid => 0,
    };
}

pub const Boolean = enum {
    access,
    motor_vehicle,
    truck,
    bus_taxi,
    psv,
    foot,
    bicycle,
    cycleway,
    moped,
    oneway,
};

fn known(value: Value, comptime yes: []const Value, comptime no: []const Value) ?bool {
    const allowed = comptime std.EnumSet(Value).initMany(yes);
    const denied = comptime std.EnumSet(Value).initMany(no);
    if (allowed.contains(value)) return true;
    if (denied.contains(value)) return false;
    return null;
}

const motor_allowed = [_]Value{ .yes, .private, .permissive, .delivery, .designated, .destination, .customers, .official, .public, .restricted, .allowed, .permit, .residents };
const motor_denied = [_]Value{ .no, .agricultural, .discouraged, .forestry };
const bike_allowed = [_]Value{ .yes, .designated, .use_sidepath, .permissive, .destination, .dismount, .lane, .track, .shared, .shared_lane, .sidepath, .share_busway, .allowed, .private };

/// Match a single value in the corresponding graph.lua table.
pub fn single(kind: Boolean, value: ?Value) ?bool {
    const v = value orelse return null;
    return switch (kind) {
        .access => known(v, &(motor_allowed ++ .{ .use_sidepath, .dismount }), &(motor_denied ++ .{ .emergency, .psv })),
        .motor_vehicle => known(v, &motor_allowed, &motor_denied),
        .truck => known(v, &.{ .designated, .yes, .destination, .delivery, .local, .private, .permissive, .official, .permit, .residents }, &(motor_denied ++ .{.unsuitable})),
        .bus_taxi => known(v, &.{ .yes, .designated, .urban, .permissive, .restricted, .destination, .official, .permit }, &.{ .no, .delivery }),
        .psv => known(v, &.{ .bus, .taxi, .yes, .designated, .permissive, .@"1", .@"2" }, &.{.no}),
        .foot => known(v, &(motor_allowed ++ .{ .use_sidepath, .crossing, .sidewalk, .passable, .footway }), &motor_denied),
        .bicycle => known(v, &(bike_allowed ++ .{ .official, .permit, .residents }), &.{ .no, .none }),
        .cycleway => known(v, &(bike_allowed ++ .{ .cyclestreet, .crossing }), &.{}),
        .moped => known(v, &.{ .yes, .designated, .private, .permissive, .destination, .delivery, .dismount, .permit, .residents }, &.{ .no, .unknown, .agricultural }),
        .oneway => known(v, &.{ .@"-1", .yes, .true, .@"1" }, &.{ .no, .false, .reversible, .alternating }),
    };
}

/// Port of any_in. The first allowed item wins. Denials are remembered
/// while scanning the remaining semicolon-separated, whitespace-sensitive items.
pub fn any(kind: Boolean, input: ?TagValue, deadline: io.Deadline) DeadlineError!?bool {
    return switch (input orelse return null) {
        .id => |id| single(kind, id),
        .raw => |bytes| blk: {
            var deny = false;
            var start: usize = 0;
            for (bytes, 0..) |byte, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (byte != ';') continue;
                if (single(kind, table.value(bytes[start..i]))) |choice| {
                    if (choice) break :blk true;
                    deny = true;
                }
                start = i + 1;
            }
            if (single(kind, table.value(bytes[start..]))) |choice| {
                if (choice) break :blk true;
                deny = true;
            }
            break :blk if (deny) false else null;
        },
    };
}

/// Port of numeric_prefix. The caller specifies whether the first decimal
/// point is part of the token.
pub fn numericPrefix(bytes: []const u8, decimals: bool, deadline: io.Deadline) DeadlineError![]const u8 {
    var dot = false;
    for (bytes, 0..) |byte, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (byte == '.' and decimals and !dot) {
            dot = true;
        } else if (!std.ascii.isDigit(byte)) {
            return bytes[0..i];
        }
    }
    return bytes;
}

pub fn normalizeSpeed(bytes: []const u8, deadline: io.Deadline) DeadlineError!?f64 {
    const prefix = try numericPrefix(bytes, false, deadline);
    var num = std.fmt.parseFloat(f64, prefix) catch return null;
    if (!std.math.isFinite(num)) return null;
    if (std.mem.endsWith(u8, bytes, "mph")) num = @round(num * 1.609344);
    return if (num >= 10 and std.math.isFinite(num)) num else null;
}

test "graph.lua boolean lists, highway defaults and speed prefixes" {
    const testing = std.testing;
    try testing.expectEqual(@as(?bool, true), try any(.access, TagValue.init("no;yes"), .none));
    try testing.expectEqual(@as(?bool, false), try any(.access, TagValue.init("no; yes"), .none));
    try testing.expectEqual(@as(?bool, null), try any(.motor_vehicle, TagValue.init("unknown;psv"), .none));
    try testing.expectEqual(@as(?bool, false), single(.bus_taxi, .delivery));
    try testing.expectEqual(@as(?bool, true), single(.truck, .delivery));
    try testing.expectEqual(.motorway, highway(.motorway_link).?.road_class);
    try testing.expect(!highway(.motorway_link).?.access.pedestrian);
    try testing.expect(highway(.steps).?.access.bicycle);
    try testing.expectEqual(35, speed(.residential));
    try testing.expectEqualStrings("7.2", try numericPrefix("7.2.3m", true, .none));
    try testing.expectEqual(@as(?f64, 48), try normalizeSpeed("30 mph", .none));
    try testing.expectEqual(@as(?f64, 30), try normalizeSpeed("30.5", .none));
    try testing.expectEqual(null, try normalizeSpeed("9", .none));
    try testing.expectEqual(null, try normalizeSpeed(" 30mph", .none));
}
