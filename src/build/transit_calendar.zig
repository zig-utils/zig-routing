// Ported from src/mjolnir/convert_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const transit = @import("../graph/transit.zig");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const gtfs = @import("gtfs/model.zig");
const Allocator = std.mem.Allocator;
const ServiceId = gtfs.Id(.service);

pub const Calendars = struct {
    start_day: i32,
    schedules: []const transit.Schedule,
    days: []const transit.DayWord,
    exceptions: []const transit.Exception,
    /// One starting ID per feed, followed by the total service count.
    feed_offsets: []const u32,

    pub fn scheduleId(self: Calendars, feed: usize, service: ServiceId) !u32 {
        if (feed >= self.feed_offsets.len - 1) return error.InvalidTransitFeed;
        const first = self.feed_offsets[feed];
        if (service.value >= self.feed_offsets[feed + 1] - first) return error.InvalidTransitService;
        return first + service.value;
    }
};

const Service = struct {
    first: i32 = std.math.maxInt(i32),
    last: i32 = std.math.minInt(i32),
    weekdays: u7 = 0,
    exception_end: i32 = std.math.minInt(i32),
};

const ExceptionRow = struct {
    schedule: u32,
    absolute_day: i32,
    active: bool,
};

/// Build service-date bitsets in a common civil-day range. The output is
/// owned by the caller's build arena. Civil dates are independent of the
/// timezone offsets used by the stops served by each trip.
pub fn compile(a: Allocator, feeds: []const gtfs.Feed, deadline: io.Deadline) !Calendars {
    const offsets = try a.alloc(u32, feeds.len + 1);
    errdefer a.free(offsets);
    offsets[0] = 0;
    var exception_count: usize = 0;
    for (feeds, 0..) |*feed, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const count = std.math.cast(u32, feed.ids.getPtrConst(.service).names.items.len) orelse return error.TooManyTransitSchedules;
        offsets[i + 1] = std.math.add(u32, offsets[i], count) catch return error.TooManyTransitSchedules;
        exception_count = std.math.add(usize, exception_count, feed.calendar_dates.len) catch return error.TooManyTransitExceptions;
    }
    if (exception_count > std.math.maxInt(u32)) return error.TooManyTransitExceptions;
    const schedules = try a.alloc(transit.Schedule, offsets[feeds.len]);
    errdefer a.free(schedules);
    const services = try a.alloc(Service, schedules.len);
    defer a.free(services);
    @memset(services, .{});
    const exception_rows = try a.alloc(ExceptionRow, exception_count);
    defer a.free(exception_rows);

    var start_day: i32 = std.math.maxInt(i32);
    var exception_pos: usize = 0;
    for (feeds, 0..) |feed, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const service_slice = services[offsets[i]..offsets[i + 1]];
        for (feed.calendar) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (row.service_id.value >= service_slice.len) return error.InvalidTransitService;
            const service = &service_slice[row.service_id.value];
            if (service.first != std.math.maxInt(i32)) return error.DuplicateTransitCalendar;
            service.first = try civilDay(row.start_date);
            service.last = try civilDay(row.end_date);
            if (service.first > service.last) return error.InvalidTransitDateRange;
            service.weekdays = weekdayMask(row);
            start_day = @min(start_day, service.first);
        }
        for (feed.calendar_dates) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (row.service_id.value >= service_slice.len) return error.InvalidTransitService;
            const day = try civilDay(row.date);
            const service = &service_slice[row.service_id.value];
            service.exception_end = @max(service.exception_end, day);
            start_day = @min(start_day, day);
            exception_rows[exception_pos] = .{
                .schedule = offsets[i] + row.service_id.value,
                .absolute_day = day,
                .active = row.exception_type == .added,
            };
            exception_pos += 1;
        }
    }
    if (start_day == std.math.maxInt(i32)) start_day = 0;

    if (exception_rows.len > 1) {
        const scratch = try a.alloc(ExceptionRow, exception_rows.len);
        defer a.free(scratch);
        try radix.sortByU64(ExceptionRow, a, exception_rows, scratch, start_day, exceptionKey, deadline);
    }
    const exceptions = try a.alloc(transit.Exception, exception_rows.len);
    errdefer a.free(exceptions);
    var word_count: u32 = 0;
    var next_exception: usize = 0;
    for (services, schedules, 0..) |service, *schedule, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const last = @max(service.last, service.exception_end);
        const count: u32 = if (last < start_day) 0 else @intCast(last - start_day + 1);
        const words = count / 32 + @as(u32, @intFromBool(count % 32 != 0));
        const exception_first = next_exception;
        var previous: i32 = -1;
        while (next_exception < exception_rows.len and exception_rows[next_exception].schedule == i) : (next_exception += 1) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const entry = exception_rows[next_exception];
            const day = entry.absolute_day - start_day;
            if (day == previous) return error.DuplicateTransitCalendarDate;
            exceptions[next_exception] = .{ .day = day, .flags = .{ .active = entry.active } };
            previous = day;
        }
        schedule.* = .{
            .days = .{ .first = word_count, .count = words },
            .day_count = count,
            .exceptions = .{ .first = @intCast(exception_first), .count = @intCast(next_exception - exception_first) },
            .flags = .{ .weekdays = if (service.first == service.last) 0 else service.weekdays },
        };
        word_count = std.math.add(u32, word_count, words) catch return error.TooManyTransitCalendarDays;
    }

    const days = try a.alloc(transit.DayWord, word_count);
    @memset(days, .{ .bits = 0 });
    for (services, schedules) |service, schedule| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (service.first > service.last or service.weekdays == 0) continue;
        const words = days[schedule.days.first..][0..schedule.days.count];
        const first: u32 = @intCast(service.first - start_day);
        const last: u32 = @intCast(service.last - start_day);
        var weekday: u3 = @intCast(@mod(service.first + 4, 7));
        for (first..last + 1) |day| {
            if (day % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (service.weekdays & (@as(u7, 1) << weekday) != 0)
                words[day / 32].bits |= @as(u32, 1) << @as(u5, @truncate(day));
            weekday = if (weekday == 6) 0 else weekday + 1;
        }
    }
    return .{
        .start_day = start_day,
        .schedules = schedules,
        .days = days,
        .exceptions = exceptions,
        .feed_offsets = offsets,
    };
}

fn exceptionKey(start_day: i32, row: ExceptionRow) u64 {
    return @as(u64, row.schedule) << 32 | @as(u32, @intCast(row.absolute_day - start_day));
}

fn civilDay(value: gtfs.Date) !i32 {
    return @intCast((try value.civil()).days());
}

fn weekdayMask(row: gtfs.Calendar) u7 {
    const days = [_]bool{ row.sunday, row.monday, row.tuesday, row.wednesday, row.thursday, row.friday, row.saturday };
    var mask: u7 = 0;
    for (days, 0..) |active, i| mask |= @as(u7, @intFromBool(active)) << @as(u3, @intCast(i));
    return mask;
}

test "service IDs are feed-scoped and calendar rows cover dates beyond 64 days" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feeds = [_]gtfs.Feed{ .init(a), .init(a) };
    const first = try feeds[0].internId(.service, "weekday");
    const second = try feeds[1].internId(.service, "weekday");
    const first_dates = [_]gtfs.CalendarDate{
        .{ .service_id = first, .date = .{ .yyyymmdd = 20260408 }, .exception_type = .removed },
        .{ .service_id = first, .date = .{ .yyyymmdd = 20260102 }, .exception_type = .added },
    };
    const second_dates = [_]gtfs.CalendarDate{
        .{ .service_id = second, .date = .{ .yyyymmdd = 20260101 }, .exception_type = .added },
    };
    const regular = [_]gtfs.Calendar{.{
        .service_id = first,
        .monday = true,
        .tuesday = false,
        .wednesday = true,
        .thursday = false,
        .friday = false,
        .saturday = false,
        .sunday = false,
        .start_date = .{ .yyyymmdd = 20260105 },
        .end_date = .{ .yyyymmdd = 20260430 },
    }};
    feeds[0].calendar = &regular;
    feeds[0].calendar_dates = &first_dates;
    feeds[1].calendar_dates = &second_dates;
    const calendar = try compile(a, &feeds, .none);
    try testing.expectEqual(0, try calendar.scheduleId(0, first));
    try testing.expectEqual(1, try calendar.scheduleId(1, second));
    try testing.expectError(error.InvalidTransitFeed, calendar.scheduleId(2, first));
    try testing.expectEqual(20454, calendar.start_day);
    try testing.expectEqual(120, calendar.schedules[0].day_count);
    try testing.expectEqual(0b0001010, calendar.schedules[0].flags.weekdays);
    try testing.expectEqual(0, calendar.schedules[1].flags.weekdays);
    try testing.expectEqual(0b1010000101000010100001010000, calendar.days[0].bits);
    try testing.expectEqualDeep(transit.Exception{ .day = 1, .flags = .{ .active = true } }, calendar.exceptions[0]);
    try testing.expectEqualDeep(transit.Exception{ .day = 97, .flags = .{ .active = false } }, calendar.exceptions[1]);
    try testing.expectEqualDeep(transit.Exception{ .day = 0, .flags = .{ .active = true } }, calendar.exceptions[2]);
}
