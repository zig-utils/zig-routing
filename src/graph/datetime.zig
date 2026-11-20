// Ported from src/baldr/datetime.cc and valhalla/baldr/datetime.h (Valhalla 3.9.3).
const std = @import("std");

pub const seconds_per_day: i64 = 86400;
pub const seconds_per_week: i64 = 7 * seconds_per_day;
const pivot_day = daysFromCivil(2014, 1, 1);

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn days(self: Date) i64 {
        return daysFromCivil(self.year, self.month, self.day);
    }

    pub fn weekday(self: Date) u3 {
        return @intCast(@mod(self.days() + 4, 7));
    }

    pub fn weekdayMask(self: Date) u7 {
        return if (self.days() < pivot_day) 0 else @as(u7, 1) << self.weekday();
    }

    pub fn daysFromPivot(self: Date) u32 {
        return @intCast(@max(0, self.days() - pivot_day));
    }

    pub fn weekOfMonth(self: Date) u3 {
        return @intCast(1 + (self.day - 1) / 7);
    }

    pub fn withinMonths(self: Date, first: MonthDay, last: MonthDay) bool {
        const today: MonthDay = .{ .month = self.month, .day = self.day };
        const from = first.order();
        const through = last.order();
        const now = today.order();
        return if (from <= through) from <= now and now <= through else now >= from or now <= through;
    }
};

pub const MonthDay = struct {
    month: u8,
    day: u8,

    fn order(self: MonthDay) u16 {
        return @as(u16, self.month) * 32 + self.day;
    }
};

pub const Local = struct {
    date: Date,
    hour: u8,
    minute: u8,

    pub fn fromSeconds(local: i64) ?Local {
        const date = civilFromDays(@divFloor(local, seconds_per_day)) orelse return null;
        const minutes: u16 = @intCast(@divTrunc(@mod(local, seconds_per_day), 60));
        return .{ .date = date, .hour = @intCast(minutes / 60), .minute = @intCast(minutes % 60) };
    }

    pub fn parse(text: []const u8) ?Local {
        if (text.len != 10 and text.len != 16) return null;
        const date = parseDate(text[0..10]) orelse return null;
        if (date.day > daysInMonth(date.year, date.month)) return null;
        if (text.len == 10) return .{ .date = date, .hour = 0, .minute = 0 };
        const clock = parseClock(text[10..16]) orelse return null;
        return .{ .date = date, .hour = clock.hour, .minute = clock.minute };
    }

    pub fn seconds(self: Local) i64 {
        return self.date.days() * seconds_per_day + @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60;
    }
};

/// The request validator follows the pinned service's C-locale parser.
pub fn validRequest(text: []const u8) bool {
    if (text.len != 16) return false;
    const date = parseDate(text[0..10]) orelse return false;
    return date.year > 1900 and parseClock(text[10..16]) != null;
}

fn parseDate(text: *const [10]u8) ?Date {
    if (text[4] != '-' or text[7] != '-') return null;
    const year = digits(text[0..4]) orelse return null;
    const month = digits(text[5..7]) orelse return null;
    const day = digits(text[8..10]) orelse return null;
    if (month == 0 or month > 12 or day == 0 or day > 31) return null;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

fn parseClock(text: *const [6]u8) ?struct { hour: u8, minute: u8 } {
    if (text[0] != 'T' or text[3] != ':') return null;
    const hour = digits(text[1..3]) orelse return null;
    // The last conversion may consume one minute digit and leave a suffix.
    const minute = if (std.ascii.isDigit(text[5])) digits(text[4..6]) else digits(text[4..5]);
    const value = minute orelse return null;
    if (hour > 23 or value > 59) return null;
    return .{ .hour = @intCast(hour), .minute = @intCast(value) };
}

fn digits(text: []const u8) ?u16 {
    var value: u16 = 0;
    for (text) |char| {
        if (!std.ascii.isDigit(char)) return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

pub fn secondsFromMidnight(text: []const u8) ?u32 {
    if (text.len > 32) return null;
    const clock = if (std.mem.lastIndexOfScalar(u8, text, 'T')) |split| text[split + 1 ..] else text;
    var fields = std.mem.splitScalar(u8, clock, ':');
    const hours = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const mins = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const secs = if (fields.next()) |field| std.fmt.parseInt(u32, field, 10) catch return null else 0;
    if (fields.next() != null or mins > 59 or secs > 59) return null;
    return std.math.cast(u32, @as(u64, hours) * 3600 + mins * 60 + secs);
}

pub fn secondOfWeek(instant: i64, offset: i32) u32 {
    const local = @mod(instant, seconds_per_week) + offset;
    return @intCast(@mod(local + 4 * seconds_per_day, seconds_per_week));
}

pub fn formatIso(buffer: []u8, instant: i64, offset: i32, with_offset: bool) error{ NoSpaceLeft, DateOutOfRange }![]const u8 {
    if (instant == 0) return buffer[0..0];
    const len: usize = if (with_offset) 22 else 16;
    if (buffer.len < len) return error.NoSpaceLeft;
    const local = std.math.add(i64, instant, offset) catch return error.DateOutOfRange;
    const date = civilFromDays(@divFloor(local, seconds_per_day)) orelse return error.DateOutOfRange;
    const time: u32 = @intCast(@mod(local, seconds_per_day));
    @memcpy(buffer[0..16], "0000-00-00T00:00");
    storeDigits(buffer[0..4], date.year);
    storeDigits(buffer[5..7], date.month);
    storeDigits(buffer[8..10], date.day);
    storeDigits(buffer[11..13], time / 3600);
    storeDigits(buffer[14..16], time / 60 % 60);
    if (with_offset) {
        const magnitude = @abs(offset);
        if (magnitude / 3600 > 99) return error.DateOutOfRange;
        buffer[16] = if (offset < 0) '-' else '+';
        storeDigits(buffer[17..19], magnitude / 3600);
        buffer[19] = ':';
        storeDigits(buffer[20..22], magnitude / 60 % 60);
    }
    return buffer[0..len];
}

fn storeDigits(buffer: []u8, value: u32) void {
    var remaining = value;
    var at = buffer.len;
    while (at != 0) {
        at -= 1;
        buffer[at] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
}

pub fn daysInMonth(year: u16, month: u8) u8 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return lengths[month - 1] + @intFromBool(month == 2 and std.time.epoch.isLeapYear(year));
}

// Gregorian dates in 400-year eras, relative to 1970-01-01.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const shifted_year = year - @intFromBool(month <= 2);
    const era = @divFloor(shifted_year, 400);
    const yoe = @mod(shifted_year, 400);
    const shifted_month = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}

fn civilFromDays(days: i64) ?Date {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const doe = @mod(shifted, 146097);
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const shifted_month = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    if (year < 0 or year > 9999) return null;
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

test "Valhalla request dates and Gregorian dates are distinct" {
    const testing = std.testing;
    try testing.expect(validRequest("2026-02-30T10:00"));
    try testing.expect(Local.parse("2026-02-30T10:00") == null);
    try testing.expect(validRequest("2015-05-06T01:0A"));
    try testing.expect(!validRequest("1900-02-01T10:00"));
    try testing.expect(!validRequest("2015-05-06T24:00"));
    try testing.expect(!validRequest("2015-05-06T23:60"));
    try testing.expect(!validRequest("2015-05-06T-3:-9"));
    try testing.expect(!validRequest("2015-05/06T01:00"));
    try testing.expect(validRequest("2015-05-06T23:59"));
    try testing.expect(Local.parse("2000-02-29") != null);
    try testing.expect(Local.parse("1900-02-29") == null);
}

test "Valhalla calendar helpers use Sunday, the pivot date and extended clocks" {
    const testing = std.testing;
    try testing.expectEqual(490, Local.parse("2015-05-06T08:00").?.date.daysFromPivot());
    try testing.expectEqual(0, Local.parse("1999-01-01").?.date.weekdayMask());
    try testing.expectEqual(8, Local.parse("2014-01-01T07:01").?.date.weekdayMask());
    try testing.expectEqual(16, Local.parse("2014-01-02T15:00").?.date.weekdayMask());
    try testing.expectEqual(0, Local.parse("2018-07-22T10:00").?.date.weekday());
    try testing.expectEqual(4, Local.parse("2018-07-26T10:00").?.date.weekday());
    try testing.expectEqual(4, Local.parse("2018-07-26").?.date.weekOfMonth());
    try testing.expectEqual(94561, secondsFromMidnight("26:16:01").?);
    try testing.expectEqual(130560, secondsFromMidnight("2015-05-06T36:16").?);
    try testing.expectEqual(86461, secondsFromMidnight("2015-05-06T24:01:01").?);
    const winter = Local.parse("2026-01-01").?.date;
    try testing.expect(winter.withinMonths(.{ .month = 10, .day = 20 }, .{ .month = 3, .day = 5 }));
    try testing.expectEqual(3 * 86400 + 17 * 3600 + 15 * 60, secondOfWeek(1573078500, -18000));
    try testing.expectEqual(3 * 86400 + 6 * 3600 + 7 * 60 + 42, secondOfWeek(408193662, -18000));
    try testing.expectEqual(11 * 3600 + 11 * 60 + 11, secondOfWeek(3380544671, -18000));
}
