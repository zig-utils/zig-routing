// Ported from src/baldr/datetime.cc (Valhalla 3.9.3).
// Valhalla's stable indices identify the rules in this mmap-friendly table.
const std = @import("std");
const io = @import("../infra/io.zig");
const Span = @import("polygon_grid.zig").Span;

pub const Id = u16;
pub const unknown: Id = 0;
pub const utc: Id = 291;
pub const base_bits = 9;
pub const max_id: Id = (1 << (base_bits + 1)) - 1;
pub const attribution = "Timezone boundaries from timezone-boundary-builder (ODbL)";
pub const Error = error{InvalidTimezoneRules};
const rules_file = @embedFile("timezones/iana-2026f.ztz");
pub const bundled_rules: [rules_file.len]u8 align(8) = rules_file.*;

const Header = extern struct {
    magic: [8]u8,
    version: [8]u8,
    zones: u32,
    transitions: u32,
    names: u32,
    string_bytes: u32,
};

const ZoneId = packed struct(u32) {
    id: u10,
    reserved: u22 = 0,
};

pub const Offset = packed struct(u32) {
    seconds: i24,
    daylight_saving: bool,
    reserved: u7 = 0,
};

const MonthRule = packed struct(u32) {
    month: u4,
    week: u3,
    weekday: u3,
    seconds: i21,
    reserved: u1 = 0,

    fn valid(self: MonthRule) bool {
        return self.month >= 1 and self.month <= 12 and self.week >= 1 and self.week <= 5 and
            self.weekday <= 6 and self.reserved == 0;
    }

    fn instant(self: MonthRule, year: i32, offset: Offset) i64 {
        const starts = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
        const lengths = [_]u6{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const leap = std.time.epoch.isLeapYear(@intCast(year));
        const first = january1(year) + starts[self.month - 1] + @intFromBool(leap and self.month > 2);
        const length = lengths[self.month - 1] + @intFromBool(leap and self.month == 2);
        // 2000-01-01 was Saturday. POSIX Sunday has weekday zero.
        const weekday = @mod(first + 6, 7);
        var day = @mod(@as(i32, self.weekday) - weekday, 7) + (@as(i32, self.week) - 1) * 7;
        if (day >= length) day -= 7;
        return @as(i64, first + day) * seconds_per_day + self.seconds - offset.seconds;
    }
};

const Zone = extern struct {
    tag: ZoneId,
    transitions: Span,
    initial: Offset,
    standard: Offset,
    daylight: Offset,
    start: MonthRule,
    end: MonthRule,
    name: Span,

    fn recurring(self: Zone, instant: i64) Error!Offset {
        if (@as(u32, @bitCast(self.start)) == 0 and @as(u32, @bitCast(self.end)) == 0) return self.standard;
        if (!self.start.valid() or !self.end.valid()) return error.InvalidTimezoneRules;

        // Gregorian weekdays and leap years repeat every 400 years.
        const normalized = inCycle(instant);
        const year = cycleYear(normalized);
        var latest: i64 = std.math.minInt(i64);
        var present = self.standard;
        // Rule times can move a January or December change into the adjacent year.
        for ([_]i32{ year - 1, year, year + 1 }) |candidate| {
            const start = self.start.instant(candidate, self.standard);
            const end = self.end.instant(candidate, self.daylight);
            if (start <= normalized and start > latest) {
                latest = start;
                present = self.daylight;
            }
            if (end <= normalized and end > latest) {
                latest = end;
                present = self.standard;
            }
        }
        return present;
    }
};

const seconds_per_day: i64 = 86400;
const epoch_2000: i64 = 946684800;
const cycle_seconds: i64 = 146097 * seconds_per_day;

fn inCycle(instant: i64) i64 {
    return @mod(@mod(instant, cycle_seconds) - epoch_2000, cycle_seconds);
}

fn cycleYear(normalized: i64) i32 {
    const days: i32 = @intCast(@divFloor(normalized, seconds_per_day));
    const year = 2000 + @divFloor(days, 365);
    return if (days < january1(year)) year - 1 else year;
}

fn january1(year: i32) i32 {
    const last = year - 1;
    const leaps = @divFloor(last, 4) - @divFloor(last, 100) + @divFloor(last, 400);
    return (year - 2000) * 365 + leaps - 484;
}

const Name = extern struct {
    text: Span,
    tag: ZoneId,
};

pub const Rules = struct {
    version: []const u8,
    starts: []const i64,
    shifts: []const Offset,
    zones: []const Zone,
    names: []const Name,
    strings: []const u8,

    pub fn parse(bytes: []const u8) Error!Rules {
        if (bytes.len < @sizeOf(Header) or !std.mem.isAligned(@intFromPtr(bytes.ptr), @alignOf(i64)))
            return error.InvalidTimezoneRules;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &header.magic, "ZRTZBIN1") or header.zones > max_id)
            return error.InvalidTimezoneRules;
        const payload: []align(8) const u8 = @alignCast(bytes[@sizeOf(Header)..]);
        const start_size = @as(u64, header.transitions) * @sizeOf(i64);
        if (start_size > payload.len) return error.InvalidTimezoneRules;
        const split: usize = @intCast(start_size);
        const starts = std.mem.bytesAsSlice(i64, payload[0..split]);
        var rest: []align(4) const u8 = @alignCast(payload[split..]);
        const shifts = try take(Offset, header.transitions, &rest);
        const zones = try take(Zone, header.zones, &rest);
        const names = try take(Name, header.names, &rest);
        if (rest.len != header.string_bytes) return error.InvalidTimezoneRules;
        const version = std.mem.sliceTo(bytes[8..16], 0);
        if (version.len != 5 or !std.ascii.isLower(version[4]) or
            !std.ascii.isDigit(version[0]) or !std.ascii.isDigit(version[1]) or
            !std.ascii.isDigit(version[2]) or !std.ascii.isDigit(version[3]))
            return error.InvalidTimezoneRules;
        return .{ .version = version, .starts = starts, .shifts = shifts, .zones = zones, .names = names, .strings = rest };
    }

    pub fn id(self: Rules, zone_name: []const u8) Error!Id {
        var lo: usize = 0;
        var hi = self.names.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const row = self.names[mid];
            switch (std.mem.order(u8, zone_name, try self.text(row.text))) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return row.tag.id,
            }
        }
        return unknown;
    }

    pub fn name(self: Rules, tz: Id) Error!?[]const u8 {
        const zone = self.find(tz) orelse return null;
        return try self.text(zone.name);
    }

    pub fn offsetAt(self: Rules, tz: Id, epoch_seconds: i64) Error!?Offset {
        const zone = self.find(tz) orelse return null;
        return try self.zoneOffset(zone, epoch_seconds);
    }

    fn zoneOffset(self: Rules, zone: *const Zone, epoch_seconds: i64) Error!Offset {
        const starts = zone.transitions.get(self.starts) catch return error.InvalidTimezoneRules;
        if (starts.len == 0 or epoch_seconds > starts[starts.len - 1])
            return try zone.recurring(epoch_seconds);
        if (epoch_seconds < starts[0]) return zone.initial;

        const shifts = zone.transitions.get(self.shifts) catch return error.InvalidTimezoneRules;
        return shifts[after(starts, epoch_seconds) - 1];
    }

    /// Choose the later UTC instant for an overlap. A local time skipped
    /// by a forward jump resolves to the transition's UTC instant.
    pub fn toUtc(self: Rules, tz: Id, local_seconds: i64, deadline: io.Deadline) !?i64 {
        if (deadline.expired()) return error.DeadlineExceeded;
        const zone = self.find(tz) orelse return null;
        const starts = zone.transitions.get(self.starts) catch return error.InvalidTimezoneRules;
        const shifts = zone.transitions.get(self.shifts) catch return error.InvalidTimezoneRules;
        const reach = 1 << 23;
        const lower = local_seconds -| reach;
        const upper = local_seconds +| reach;
        var resolve: Resolve = .{ .rules = self, .zone = zone, .local = local_seconds };
        var previous = try self.zoneOffset(zone, lower);
        try resolve.candidate(previous);
        const start = after(starts, lower);
        for (starts[start..], shifts[start..], 0..) |at, next, i| {
            if (at > upper) break;
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try resolve.candidate(next);
            resolve.jump(at, previous, next);
            previous = next;
        }
        const latest = if (starts.len == 0) std.math.minInt(i64) else starts[starts.len - 1];
        if (upper > latest) try resolve.recurring(latest);
        return resolve.match orelse resolve.gap;
    }

    pub fn verify(self: Rules, deadline: io.Deadline) !void {
        var previous: Id = unknown;
        var step_count: usize = 0;
        for (self.zones, 0..) |zone, i| {
            if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (zone.tag.reserved != 0 or zone.tag.id <= previous or zone.transitions.first != step_count or
                zone.initial.reserved != 0 or zone.standard.reserved != 0 or zone.daylight.reserved != 0)
                return error.InvalidTimezoneRules;
            const no_rules = @as(u32, @bitCast(zone.start)) == 0 and @as(u32, @bitCast(zone.end)) == 0;
            if (!no_rules and (!zone.start.valid() or !zone.end.valid() or zone.standard.daylight_saving or !zone.daylight.daylight_saving))
                return error.InvalidTimezoneRules;
            if (try self.id(try self.text(zone.name)) != zone.tag.id) return error.InvalidTimezoneRules;
            const starts = zone.transitions.get(self.starts) catch return error.InvalidTimezoneRules;
            const shifts = zone.transitions.get(self.shifts) catch return error.InvalidTimezoneRules;
            for (starts, shifts, 0..) |at, shift, j| {
                if (j % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (shift.reserved != 0 or (j != 0 and starts[j - 1] >= at)) return error.InvalidTimezoneRules;
            }
            previous = zone.tag.id;
            step_count += starts.len;
        }
        if (step_count != self.starts.len) return error.InvalidTimezoneRules;
        var last_name: []const u8 = "";
        for (self.names, 0..) |row, i| {
            if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const current = try self.text(row.text);
            if (row.tag.reserved != 0 or self.find(row.tag.id) == null or std.mem.order(u8, last_name, current) != .lt)
                return error.InvalidTimezoneRules;
            last_name = current;
        }
    }

    fn text(self: Rules, span: Span) Error![]const u8 {
        return span.get(self.strings) catch error.InvalidTimezoneRules;
    }

    fn find(self: Rules, tz: Id) ?*const Zone {
        var lo: usize = 0;
        var hi = self.zones.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const zone = &self.zones[mid];
            if (tz == zone.tag.id) return zone;
            if (tz < zone.tag.id) hi = mid else lo = mid + 1;
        }
        return null;
    }
};

fn after(starts: []const i64, epoch_seconds: i64) usize {
    var lo: usize = 0;
    var hi = starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= epoch_seconds) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const Resolve = struct {
    rules: Rules,
    zone: *const Zone,
    local: i64,
    match: ?i64 = null,
    gap: ?i64 = null,

    fn candidate(self: *Resolve, offset: Offset) Error!void {
        const instant = std.math.sub(i64, self.local, offset.seconds) catch return;
        if (self.match) |found| if (instant <= found) return;
        if ((try self.rules.zoneOffset(self.zone, instant)).seconds == offset.seconds) self.match = instant;
    }

    fn jump(self: *Resolve, instant: i64, prior: Offset, next: Offset) void {
        const relative = @as(i128, self.local) - instant;
        if (relative >= prior.seconds and relative < next.seconds) self.gap = instant;
    }

    fn recurring(self: *Resolve, latest: i64) Error!void {
        const zone = self.zone;
        try self.candidate(zone.standard);
        if (@as(u32, @bitCast(zone.start)) == 0 and @as(u32, @bitCast(zone.end)) == 0) return;
        if (!zone.start.valid() or !zone.end.valid()) return error.InvalidTimezoneRules;
        try self.candidate(zone.daylight);
        // A resolved instant takes precedence over any skipped local time.
        if (self.match != null) return;
        const normalized = inCycle(self.local);
        const base = @as(i128, self.local) - normalized;
        const year = cycleYear(normalized);
        for ([_]i32{ year - 1, year, year + 1 }) |y| {
            if (std.math.cast(i64, base + zone.start.instant(y, zone.standard))) |at| {
                if (at > latest) self.jump(at, zone.standard, zone.daylight);
            }
            if (std.math.cast(i64, base + zone.end.instant(y, zone.daylight))) |at| {
                if (at > latest) self.jump(at, zone.daylight, zone.standard);
            }
        }
    }
};

fn take(comptime T: type, count: u32, bytes: *[]align(4) const u8) Error![]const T {
    const size = @as(u64, count) * @sizeOf(T);
    if (size > bytes.len) return error.InvalidTimezoneRules;
    const end: usize = @intCast(size);
    const items = std.mem.bytesAsSlice(T, bytes.*[0..end]);
    bytes.* = @alignCast(bytes.*[end..]);
    return items;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 32 and @offsetOf(Header, "zones") == 16 and @offsetOf(Header, "string_bytes") == 28);
    std.debug.assert(@sizeOf(Zone) == 40 and @offsetOf(Zone, "transitions") == 4 and @offsetOf(Zone, "initial") == 12);
    std.debug.assert(@offsetOf(Zone, "start") == 24 and @offsetOf(Zone, "name") == 32);
    std.debug.assert(@sizeOf(Name) == 12 and @offsetOf(Name, "tag") == 8);
}

test "pinned IANA instants include historical, fractional and recurring offsets" {
    const testing = std.testing;
    const data = @embedFile("timezones/iana-2026f.ztz");
    const aligned: [data.len]u8 align(8) = data.*;
    const rules = try Rules.parse(&aligned);
    try rules.verify(.none);
    try testing.expectEqualStrings("2026f", rules.version);
    try testing.expectEqual(@as(Id, 117 | (1 << base_bits)), try rules.id("America/Ciudad_Juarez"));
    try testing.expectEqual(try rules.id("Europe/Kiev"), try rules.id("Europe/Kyiv"));
    try testing.expectEqualStrings("Europe/Kyiv", (try rules.name(try rules.id("Europe/Kiev"))).?);
    try testing.expectEqual(@as(Id, 0), try rules.id("Unknown/Zone"));
    try testing.expectEqual(@as(?Offset, null), try rules.offsetAt(unknown, 0));
    const cases = [_]struct { zone: []const u8, instant: i64, seconds: i24, dst: bool }{
        .{ .zone = "America/New_York", .instant = -2717650801, .seconds = -17762, .dst = false },
        .{ .zone = "America/New_York", .instant = -2717650800, .seconds = -18000, .dst = false },
        .{ .zone = "America/New_York", .instant = 1772953199, .seconds = -18000, .dst = false },
        .{ .zone = "America/New_York", .instant = 1772953200, .seconds = -14400, .dst = true },
        .{ .zone = "America/New_York", .instant = 14395734000, .seconds = -14400, .dst = true },
        .{ .zone = "Europe/Dublin", .instant = 1767268800, .seconds = 0, .dst = true },
        .{ .zone = "Europe/Dublin", .instant = 1782907200, .seconds = 3600, .dst = false },
        .{ .zone = "Europe/Dublin", .instant = 14390049600, .seconds = 0, .dst = true },
        .{ .zone = "Asia/Kathmandu", .instant = 504901799, .seconds = 19800, .dst = false },
        .{ .zone = "Asia/Kathmandu", .instant = 504901800, .seconds = 20700, .dst = false },
        .{ .zone = "Pacific/Chatham", .instant = 14390049600, .seconds = 49500, .dst = true },
        .{ .zone = "Pacific/Chatham", .instant = 14405688000, .seconds = 45900, .dst = false },
        .{ .zone = "America/Coyhaique", .instant = 1793512799, .seconds = -10800, .dst = false },
    };
    for (cases) |case| {
        const id = try rules.id(case.zone);
        const offset = (try rules.offsetAt(id, case.instant)).?;
        try testing.expectEqual(case.seconds, offset.seconds);
        try testing.expectEqual(case.dst, offset.daylight_saving);
    }
}

test "recurring local times resolve gaps and choose the later overlap" {
    const testing = std.testing;
    const local = @import("datetime.zig").Local;
    const rules = try Rules.parse(&bundled_rules);
    const zone = try rules.id("America/New_York");
    const skipped = local.parse("2426-03-08T02:05").?.seconds();
    try testing.expectEqual(@as(?i64, 1772953200 + cycle_seconds), try rules.toUtc(zone, skipped, .none));

    const repeated = local.parse("2426-11-01T01:30").?.seconds();
    try testing.expectEqual(@as(?i64, repeated + 5 * 3600), try rules.toUtc(zone, repeated, .none));
}
