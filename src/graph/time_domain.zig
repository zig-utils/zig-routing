// Ported from valhalla/baldr/timedomain.h and src/baldr/datetime.cc (Valhalla 3.9.3).
const std = @import("std");
const datetime = @import("datetime.zig");

pub const TimeDomain = packed struct(u64) {
    nth_weekday: bool = false,
    dow: u7 = 0,
    begin_hour: u5 = 0,
    begin_minute: u6 = 0,
    begin_month: u4 = 0,
    begin_day: u5 = 0,
    begin_week: u3 = 0,
    end_hour: u5 = 0,
    end_minute: u6 = 0,
    end_month: u4 = 0,
    end_day: u5 = 0,
    end_week: u3 = 0,
    reserved: u10 = 0,

    pub fn valid(self: TimeDomain) bool {
        return self.reserved == 0 and self.begin_hour < 24 and self.end_hour < 24 and
            self.begin_minute < 60 and self.end_minute < 60 and self.begin_month <= 12 and self.end_month <= 12 and
            self.begin_week <= 5 and self.end_week <= 5 and (!self.nth_weekday or (self.begin_day <= 7 and self.end_day <= 7));
    }

    pub fn active(self: TimeDomain, local: datetime.Local) bool {
        if (self.dow != 0 and self.dow & (@as(u7, 1) << local.date.weekday()) == 0) return false;
        const now = @as(u16, local.hour) * 60 + local.minute;
        const begin = @as(u16, self.begin_hour) * 60 + self.begin_minute;
        const end = @as(u16, self.end_hour) * 60 + self.end_minute;
        if (begin != 0 or end != 0) {
            if (self.begin_hour > self.end_hour) {
                // Upstream excludes both endpoints of an overnight interval.
                if (end <= now and now <= begin) return false;
            } else if (now < begin or now > end) return false;
        }
        return self.activeDate(local.date);
    }

    fn activeDate(self: TimeDomain, date: datetime.Date) bool {
        var begin = Point{ .month = self.begin_month, .day = self.begin_day, .week = self.begin_week };
        var end = Point{ .month = self.end_month, .day = self.end_day, .week = self.end_week };
        if (self.nth_weekday) {
            if (begin.week != 0 and begin.day == 0 and begin.month == 0) {
                begin.month = date.month;
                if (end.week == 0 and end.day == 0 and end.month == 0) {
                    begin.day = self.dow;
                    end = begin;
                }
            }
            if (end.week != 0 and end.day == 0 and end.month == 0) end.month = date.month;
            if (begin.month == 0 or begin.day == 0 or end.month == 0 or end.day == 0) return true;
        } else {
            if (begin.month != 0 and end.month != 0 and begin.day == 0 and end.day == 0) {
                begin.day = 1;
                end.day = datetime.daysInMonth(date.year, end.month);
            }
            if (begin.month == 0 or begin.day == 0) return true;
        }

        var begin_year = date.year;
        var end_year = date.year;
        if (begin.month > end.month) {
            if (date.month < begin.month) begin_year -|= 1 else end_year +|= 1;
        }
        const first = begin.epochDay(begin_year, self.nth_weekday, true);
        const last = end.epochDay(end_year, self.nth_weekday, false);
        const day = date.days();
        return if (begin.month == end.month and begin.day > end.day)
            day >= first or day <= last
        else
            first <= day and day <= last;
    }
};

const Point = struct {
    month: u8,
    day: u8,
    week: u3,

    fn epochDay(self: Point, year: u16, nth_weekday: bool, first: bool) i64 {
        const month = datetime.Date{ .year = year, .month = self.month, .day = 1 };
        if (!nth_weekday or self.week == 0) return month.days() + @as(i64, self.day) - 1;
        const weekday: i64 = @as(i64, self.day) - 1;
        var day = 1 + @mod(weekday - month.weekday(), 7) + (@as(i64, self.week) - 1) * 7;
        // The pinned evaluator adjusts the first bound when week five is
        // absent. The last bound retains its computed day in the next month.
        if (first and self.week == 5 and day > datetime.daysInMonth(year, self.month)) day -= 7;
        return month.days() + day - 1;
    }
};

comptime {
    std.debug.assert(@bitSizeOf(TimeDomain) == 64 and @sizeOf(TimeDomain) == 8);
    std.debug.assert(@bitOffsetOf(TimeDomain, "dow") == 1 and @bitOffsetOf(TimeDomain, "end_hour") == 31);
}

test "overnight domain uses the local weekday and excludes both boundaries" {
    const domain: TimeDomain = .{ .dow = 0b0111110, .begin_hour = 19, .end_hour = 6 };
    try std.testing.expect(domain.active(datetime.Local.parse("2026-11-16T05:59").?));
    try std.testing.expect(!domain.active(datetime.Local.parse("2026-11-16T06:00").?));
    try std.testing.expect(!domain.active(datetime.Local.parse("2026-11-16T19:00").?));
    try std.testing.expect(domain.active(datetime.Local.parse("2026-11-16T19:01").?));
    try std.testing.expect(!domain.active(datetime.Local.parse("2026-11-15T19:01").?));
}

// Ported from test/datetime.cc (Valhalla 3.9.3).
test "time domain matches the upstream local calendar and clock cases" {
    const rules = [_]struct { u64, []const []const u8 }{
        .{ 23_622_321_788, &.{
            "-2018-04-17T05:00", "+2018-04-17T06:00", "+2018-04-17T10:00",
            "+2018-04-17T11:00", "-2018-04-17T11:11",
        } },
        .{ 40_802_435_968, &.{
            "-2018-04-17T11:11", "-2018-04-21T03:00", "+2018-04-21T11:11",
        } },
        .{ 36_507_225_218, &.{
            "-2018-04-27T13:00", "+2018-04-21T13:00",
        } },
        .{ 39_610_337_986_940, &.{
            "+2018-04-27T13:00", "-2018-02-27T12:00", "-2018-09-30T13:00",
            "+2018-09-26T13:00",
        } },
        .{ 1_106_007_905_274_112, &.{
            "-2018-10-10T11:00", "+2018-10-16T11:00",
        } },
        .{ 23_622_321_664, &.{
            "+2018-10-10T11:00", "+2018-10-16T11:00", "-2018-10-16T05:59",
            "+2018-10-16T06:04", "-2018-10-16T11:01",
        } },
        .{ 9_372_272_830_712_067, &.{
            "-2018-10-21T09:01", "+2018-10-28T09:01", "+2019-01-20T16:00",
            "-2019-01-20T16:01", "-2019-03-28T11:00", "-2019-03-29T11:00",
        } },
        .{ 34_359_740_674, &.{
            "+2018-10-21T09:01", "+2018-10-28T09:01", "-2018-10-29T09:01",
            "+2019-01-20T16:00", "-2019-01-20T16:01", "-2019-03-28T11:00",
            "-2019-03-29T11:00",
        } },
        .{ 268_435_459, &.{
            "+2018-10-07T09:01", "-2018-10-14T09:01", "+2018-11-04T09:01",
            "+2019-01-06T16:00", "-2019-01-13T16:01",
        } },
        .{ 52_776_564_424_704, &.{
            "+2018-12-12T16:01", "+2019-12-12T16:01", "-2019-11-12T16:01",
            "-2019-01-12T16:01",
        } },
        .{ 11_311_813_490_642_943, &.{
            "+2018-12-30T15:01", "-2018-12-30T14:01", "-2018-12-23T14:01",
            "-2019-12-29T14:01", "+2019-12-29T15:01",
        } },
        .{ 1_066_423_339_714_816, &.{
            "-2018-11-15T09:01", "+2018-11-16T09:01", "-2019-02-16T09:01",
            "+2019-02-15T09:01", "-2019-02-15T16:31", "+2019-02-15T16:30",
            "-2019-07-04T16:30",
        } },
        .{ 1_079_606_730_295_552, &.{
            "+2018-05-15T09:01", "-2018-05-15T12:00",
        } },
        .{ 29_497_840_232_464, &.{
            "-2019-01-01T08:30", "+2019-01-02T08:30", "-2019-07-03T08:30",
            "-2019-06-30T09:30", "+2019-06-26T08:30",
        } },
        .{ 224_301_728_923_777, &.{
            "-2018-12-31T08:30", "+2019-01-05T08:30", "-2019-01-06T08:30",
            "+2019-03-02T08:30", "-2019-03-03T08:30",
        } },
        .{ 74_766_824_773_372, &.{
            "-2020-01-03T22:21", "-2020-01-03T21:21", "-2020-01-05T22:21",
            "-2020-01-05T21:21", "+2020-01-06T22:21", "-2020-01-06T21:21",
            "+2020-01-01T22:21", "-2020-01-01T21:21", "+2020-01-04T22:21",
            "-2020-01-04T21:21", "-2020-03-01T22:21", "-2020-03-01T21:21",
            "+2020-03-02T22:21", "-2020-03-02T21:21",
        } },
        .{ 74_766_824_767_740, &.{
            "-2020-01-03T22:21", "-2021-01-03T21:21", "-2020-01-05T23:00",
            "-2020-01-05T20:00", "-2020-03-01T23:00", "+2020-01-06T21:21",
            "+2020-01-01T22:21", "+2020-01-04T20:00", "+2020-03-02T16:00",
        } },
        .{ 74_766_824_773_120, &.{
            "-2020-01-03T22:21", "-2021-01-03T21:21", "+2020-01-05T22:30",
            "-2020-01-05T16:00", "+2020-01-01T22:21", "-2020-01-01T21:21",
            "+2020-03-01T22:21", "-2020-03-01T21:21",
        } },
        .{ 74_766_824_767_488, &.{
            "-2020-01-03T22:21", "-2020-01-03T21:21", "+2020-01-05T23:59",
            "+2020-01-05T08:00", "+2021-01-01T00:00", "+2022-01-01T22:00",
            "+2020-03-10T22:00", "+2020-06-20T16:30",
        } },
        .{ 124, &.{
            "+2021-04-22T05:00", "+2021-04-22T23:58", "+2021-04-23T10:00",
            "-2021-04-24T11:00", "+2021-04-26T01:11",
        } },
        .{ 20, &.{
            "+2021-04-21T08:00", "-2021-04-20T08:00", "-2021-04-18T16:00",
            "+2021-04-26T18:00",
        } },
        .{ 21_990_234_128_384, &.{
            "+2021-04-03T08:00", "+2020-03-15T23:59", "+2022-05-10T16:00",
            "-2021-02-18T16:00", "-2021-06-26T19:00",
        } },
        .{ 2_128_654_663_942_144, &.{
            "+2021-04-03T08:00", "+2021-03-21T20:00", "+2021-04-30T23:59",
            "-2020-03-15T16:00", "-2022-05-10T16:00", "-2021-02-18T16:00",
            "-2021-06-26T16:00",
        } },
        .{ 35_184_375_234_560, &.{
            "-2024-04-03T08:00", "-2024-05-31T21:00", "+2024-06-01T00:01",
            "+2024-06-15T16:00", "+2024-07-10T16:00", "+2024-08-18T16:00",
            "+2024-08-31T23:59", "-2024-09-01T00:01",
        } },
    };
    for (rules) |rule| {
        const domain: TimeDomain = @bitCast(rule[0]);
        for (rule[1]) |entry| {
            const active = domain.active(datetime.Local.parse(entry[1..]).?);
            try std.testing.expectEqual(entry[0] == '+', active);
        }
    }
}
