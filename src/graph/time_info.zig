// Ported from valhalla/baldr/time_info.h (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const datetime = @import("datetime.zig");
const timezone = @import("timezone.zig");
const reader = @import("reader.zig");
const NodeId = @import("format.zig").NodeId;

pub const invalid_second_of_week: u32 = (1 << 20) - 1;

pub const Display = struct {
    date_time: []const u8,
    time_zone_offset: []const u8,
    time_zone_name: []const u8,
};

pub const TimeInfo = struct {
    valid: bool = false,
    zone: timezone.Id = timezone.unknown,
    unix_time: i64 = 0,
    second_of_week: u32 = invalid_second_of_week,
    seconds_from_now: i64 = 0,

    pub fn local(self: TimeInfo, rules: ?*const timezone.Rules) !?datetime.Local {
        if (!self.valid or self.unix_time == 0) return null;
        const shift = (try offsetAt(rules, self.zone, self.unix_time)) orelse return null;
        return datetime.Local.fromSeconds(try std.math.add(i64, self.unix_time, shift));
    }

    pub fn display(self: TimeInfo, rules: ?*const timezone.Rules, buffer: []u8) !?Display {
        if (!self.valid or self.unix_time == 0) return null;
        const offset = (try offsetAt(rules, self.zone, self.unix_time)) orelse return null;
        const text = try datetime.formatIso(buffer, self.unix_time, offset, true);
        const name = if (rules) |table| (try table.name(self.zone)) orelse "" else "";
        return .{ .date_time = text[0..16], .time_zone_offset = text[16..], .time_zone_name = name };
    }

    pub fn fromNode(view: *const reader.View, node: NodeId, value: []const u8, now: i64, deadline: io.Deadline) !TimeInfo {
        const rules = if (view.tz_rules) |*present| present else null;
        return fromLocal(rules, value, try view.nodeTimezone(node), timezone.utc, now, deadline);
    }

    pub fn fromUnix(view: *const reader.View, node: NodeId, timestamp: i64, now: i64) !TimeInfo {
        const rules = if (view.tz_rules) |*present| present else null;
        const zone = try view.nodeTimezone(node);
        const shift = (try offsetAt(rules, zone, timestamp)) orelse return .{};
        return .{
            .valid = true,
            .zone = zone,
            .unix_time = timestamp,
            .second_of_week = datetime.secondOfWeek(timestamp, shift),
            .seconds_from_now = try std.math.sub(i64, timestamp, now),
        };
    }

    pub fn fromLocal(
        rules: ?*const timezone.Rules,
        value: []const u8,
        zone: timezone.Id,
        fallback: timezone.Id,
        now: i64,
        deadline: io.Deadline,
    ) !TimeInfo {
        if (value.len == 0) return .{};
        const preferred = if (zone == timezone.unknown) fallback else zone;
        const now_minute = @divTrunc(now, 60) * 60;
        const now_shift = try offsetAt(rules, preferred, now_minute);
        const used = if (now_shift != null) preferred else timezone.utc;
        const local_now = try std.math.add(i64, now_minute, now_shift orelse 0);
        const local_time = if (std.mem.eql(u8, value, "current"))
            try std.math.sub(i64, local_now, @mod(local_now, 60))
        else if (datetime.Local.parse(value)) |parsed|
            parsed.seconds()
        else
            return .{};
        const instant = if (used == timezone.utc)
            local_time
        else
            (try rules.?.toUtc(used, local_time, deadline)) orelse return .{};
        const shift = (try offsetAt(rules, used, instant)) orelse return .{};
        const effective = try std.math.add(i64, instant, shift);
        return .{
            .valid = true,
            .zone = used,
            .unix_time = instant,
            .second_of_week = datetime.secondOfWeek(instant, shift),
            .seconds_from_now = try std.math.sub(i64, effective, local_now),
        };
    }

    pub fn forward(self: TimeInfo, rules: ?*const timezone.Rules, seconds: f32, next: timezone.Id) !TimeInfo {
        return self.advance(rules, seconds, next, false);
    }

    pub fn reverse(self: TimeInfo, rules: ?*const timezone.Rules, seconds: f32, next: timezone.Id) !TimeInfo {
        return self.advance(rules, seconds, next, true);
    }

    fn advance(self: TimeInfo, rules: ?*const timezone.Rules, seconds: f32, next: timezone.Id, backwards: bool) !TimeInfo {
        if (!self.valid) return self;
        if (!std.math.isFinite(seconds) or seconds < 0 or seconds >= @as(f32, @floatFromInt(std.math.maxInt(u32))))
            return error.InvalidTimeOffset;
        const elapsed: i64 = @intFromFloat(seconds);
        const delta = if (backwards) -elapsed else elapsed;
        const instant = try std.math.add(i64, self.unix_time, delta);
        // Recalculate the local week at the new instant. Staying in the
        // same zone can still cross a daylight-saving transition.
        const week = if (try offsetAt(rules, next, instant)) |offset|
            datetime.secondOfWeek(instant, offset)
        else
            @as(u32, @intCast(@mod(@as(i64, self.second_of_week) + delta, datetime.seconds_per_week)));
        return .{
            .valid = true,
            .zone = next,
            .unix_time = instant,
            .second_of_week = week,
            .seconds_from_now = try std.math.add(i64, self.seconds_from_now, delta),
        };
    }
};

pub fn timezoneDifference(rules: ?*const timezone.Rules, from: timezone.Id, to: timezone.Id, instant: i64) !i32 {
    if (from == to) return 0;
    const source = (try offsetAt(rules, from, instant)) orelse return 0;
    const target = (try offsetAt(rules, to, instant)) orelse return 0;
    return target - source;
}

fn offsetAt(rules: ?*const timezone.Rules, zone: timezone.Id, instant: i64) timezone.Error!?i32 {
    if (zone == timezone.utc) return 0;
    const table = rules orelse return null;
    const result = (try table.offsetAt(zone, instant)) orelse return null;
    return result.seconds;
}

const Fixture = struct {
    const data = @embedFile("timezones/iana-2026f.ztz");
    const bytes: [data.len]u8 align(8) = data.*;
};

test "TimeInfo chooses the later overlap and skips the DST gap" {
    const testing = std.testing;
    const rules = try timezone.Rules.parse(&Fixture.bytes);
    const ny = try rules.id("America/New_York");
    const cases = [_]struct { local: []const u8, instant: i64, iso: []const u8 }{
        .{ .local = "2016-03-13T01:55", .instant = 1457852100, .iso = "2016-03-13T01:55-05:00" },
        .{ .local = "2016-03-13T02:30", .instant = 1457852400, .iso = "2016-03-13T03:00-04:00" },
        .{ .local = "2016-11-06T00:30", .instant = 1478406600, .iso = "2016-11-06T00:30-04:00" },
        .{ .local = "2016-11-06T01:30", .instant = 1478413800, .iso = "2016-11-06T01:30-05:00" },
        .{ .local = "2426-03-08T02:30", .instant = 14395734000, .iso = "2426-03-08T03:00-04:00" },
    };
    for (cases) |case| {
        const info = try TimeInfo.fromLocal(&rules, case.local, ny, timezone.utc, case.instant, .none);
        try testing.expect(info.valid);
        try testing.expectEqual(case.instant, info.unix_time);
        try testing.expectEqual(0, info.seconds_from_now);
        var text: [22]u8 = undefined;
        try testing.expectEqualStrings(case.iso, try datetime.formatIso(&text, info.unix_time, (try offsetAt(&rules, ny, info.unix_time)).?, true));
    }
}

test "TimeInfo advances in both directions across timezone changes" {
    const testing = std.testing;
    const rules = try timezone.Rules.parse(&Fixture.bytes);
    const ny = try rules.id("America/New_York");
    const la = try rules.id("America/Los_Angeles");
    const start = try TimeInfo.fromLocal(&rules, "2019-11-06T17:15", ny, timezone.unknown, 1573078500, .none);
    try testing.expectEqual(-10800, try timezoneDifference(&rules, ny, la, 1586660072));
    const west = try start.forward(&rules, 183.9, la);
    try testing.expectEqual(1573078683, west.unix_time);
    try testing.expectEqual(start.second_of_week + 183 - 10800, west.second_of_week);
    try testing.expectEqual(183, west.seconds_from_now);
    try testing.expectEqual(start, try west.reverse(&rules, 183.9, ny));
    const sunday = try TimeInfo.fromLocal(null, "2019-11-10T00:00", 0, 0, 1573344000, .none);
    try testing.expectEqual(timezone.utc, sunday.zone);
    try testing.expectEqual(0, sunday.second_of_week);
    try testing.expectEqual(604799, (try sunday.reverse(null, 1, timezone.utc)).second_of_week);
    try testing.expect(!(try TimeInfo.fromLocal(&rules, "2026-02-30T10:00", ny, 0, 0, .none)).valid);
    const current = try TimeInfo.fromLocal(null, "current", 0, 0, 1573344059, .none);
    try testing.expectEqual(sunday, current);
}

test "TimeInfo follows the local clock across DST within one zone" {
    const testing = std.testing;
    const rules = try timezone.Rules.parse(&Fixture.bytes);
    const ny = try rules.id("America/New_York");
    const start = try TimeInfo.fromLocal(&rules, "2016-03-13T01:55", ny, timezone.utc, 1457852100, .none);
    const after = try start.forward(&rules, 600, ny);
    try testing.expectEqual(1457852700, after.unix_time);
    try testing.expectEqual(3 * 3600 + 5 * 60, after.second_of_week);
    var buffer: [22]u8 = undefined;
    const rendered = (try after.display(&rules, &buffer)).?;
    try testing.expectEqualStrings("2016-03-13T03:05", rendered.date_time);
    try testing.expectEqualStrings("-04:00", rendered.time_zone_offset);
    try testing.expectEqualStrings("America/New_York", rendered.time_zone_name);
    try testing.expectEqual(start, try after.reverse(&rules, 600, ny));
}

// Ported from the start and end instants in test/datetime.cc.
test "Valhalla DST response formatting matches every original origin and destination" {
    const testing = std.testing;
    const rules = try timezone.Rules.parse(&Fixture.bytes);
    const ny = try rules.id("America/New_York");
    var rows = std.mem.tokenizeScalar(u8, @embedFile("testdata/datetime-dst.tsv"), '\n');
    while (rows.next()) |row| {
        var fields = std.mem.splitScalar(u8, row, '\t');
        for (0..2) |_| {
            const instant = try std.fmt.parseInt(i64, fields.next().?, 10);
            const expected = fields.next().?;
            var text: [22]u8 = undefined;
            const rendered = try datetime.formatIso(&text, instant, (try offsetAt(&rules, ny, instant)).?, true);
            try testing.expectEqualStrings(expected, rendered);
        }
        try testing.expect(fields.next() == null);
    }
}
