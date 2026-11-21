// Ported from valhalla/baldr/transit*.h (Valhalla 3.9.3).
const std = @import("std");
const Deadline = @import("../infra/io.zig").Deadline;

pub const Departure = extern struct {
    ids: packed struct(u64) { line: u20, route: u12, trip: u32 },
    attrs: packed struct(u64) {
        block: u20,
        schedule: u12,
        headsign: u24,
        kind: u2,
        wheelchair: bool,
        bicycle: bool,
        spare: u4,
    },
    times: u64,

    const Fixed = packed struct(u64) { start: u17, elapsed: u17, spare: u30 };
    pub const Frequency = packed struct(u64) { start: u17, end: u17, headway: u13, elapsed: u17 };

    pub fn start(self: Departure) u32 {
        return @as(Fixed, @bitCast(self.times)).start;
    }

    pub fn elapsed(self: Departure) u32 {
        return if (self.attrs.kind == 0)
            @as(Fixed, @bitCast(self.times)).elapsed
        else
            @as(Frequency, @bitCast(self.times)).elapsed;
    }

    pub fn frequency(self: Departure) ?Frequency {
        return if (self.attrs.kind == 1) @bitCast(self.times) else null;
    }
};

pub const Stop = extern struct {
    attrs: packed struct(u64) {
        one_stop: u24,
        name: u24,
        generated: bool,
        traversability: u2,
        spare: u13,
    },
};

pub const Route = extern struct {
    color: u32,
    text_color: u32,
    id: packed struct(u64) { vehicle: u8, one_stop: u24, spare: u32 },
    operator: packed struct(u64) { one_stop: u24, name: u24, spare: u16 },
    website: packed struct(u64) { url: u24, short_name: u24, spare: u16 },
    details: packed struct(u64) { long_name: u24, description: u24, spare: u16 },
};

pub const Schedule = extern struct {
    days: u64,
    attrs: packed struct(u64) { weekdays: u7, end_day: u6, spare: u51 },
};

pub const Transfer = extern struct {
    from: u32,
    to: u32,
    attrs: packed struct(u32) { kind: u4, minimum_time: u16, spare: u12 },
};

pub const Counts = struct {
    departures: usize,
    stops: usize,
    routes: usize,
    schedules: usize,
    transfers: usize,
};

pub const Tables = struct {
    departures: []align(1) const Departure,
    stops: []align(1) const Stop,
    routes: []align(1) const Route,
    schedules: []align(1) const Schedule,
    transfers: []align(1) const Transfer,

    pub fn parse(bytes: *[]const u8, counts: Counts) !Tables {
        return .{
            .departures = try take(Departure, bytes, counts.departures),
            .stops = try take(Stop, bytes, counts.stops),
            .routes = try take(Route, bytes, counts.routes),
            .schedules = try take(Schedule, bytes, counts.schedules),
            .transfers = try take(Transfer, bytes, counts.transfers),
        };
    }

    pub fn verify(self: Tables, text: []const u8, deadline: Deadline) !void {
        if (self.departures.len == 0 and self.stops.len == 0 and self.routes.len == 0 and
            self.schedules.len == 0 and self.transfers.len == 0) return;
        const text_limit = try textLimit(text, deadline);
        var previous_line: u20 = 0;
        var previous_time: u32 = 0;
        for (self.departures, 0..) |row, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (row.ids.route >= self.routes.len or row.attrs.schedule >= self.schedules.len or row.attrs.kind > 1)
                return error.InvalidValhallaTransitDeparture;
            if (row.attrs.headsign >= text_limit) return error.InvalidValhallaTransitText;
            if (row.ids.line < previous_line or (row.ids.line == previous_line and row.start() < previous_time))
                return error.UnsortedValhallaTransitDepartures;
            if (row.frequency()) |time| {
                if (time.headway == 0 or time.end <= time.start) return error.InvalidValhallaTransitDeparture;
            }
            previous_line = row.ids.line;
            previous_time = row.start();
        }
        for (self.stops, 0..) |stop, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (stop.attrs.name >= text_limit or stop.attrs.one_stop >= text_limit) return error.InvalidValhallaTransitText;
        }
        for (self.routes, 0..) |route, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (route.id.one_stop >= text_limit or route.operator.one_stop >= text_limit or
                route.operator.name >= text_limit or route.website.url >= text_limit or
                route.website.short_name >= text_limit or route.details.long_name >= text_limit or
                route.details.description >= text_limit) return error.InvalidValhallaTransitText;
        }
        for (self.transfers, 0..) |transfer, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (transfer.from >= self.stops.len or transfer.to >= self.stops.len or transfer.attrs.kind > 3)
                return error.InvalidValhallaTransitTransfer;
        }
    }
};

fn textLimit(text: []const u8, deadline: Deadline) !usize {
    var end = text.len;
    while (end != 0) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const start = end -| 4096;
        if (std.mem.lastIndexOfScalar(u8, text[start..end], 0)) |offset| return start + offset + 1;
        end = start;
    }
    return 0;
}

fn take(comptime T: type, bytes: *[]const u8, count: usize) ![]align(1) const T {
    if (count > bytes.len / @sizeOf(T)) return error.TruncatedValhallaTransit;
    const length = count * @sizeOf(T);
    const records = std.mem.bytesAsSlice(T, bytes.*[0..length]);
    bytes.* = bytes.*[length..];
    return records;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Departure) == 24 and @offsetOf(Departure, "attrs") == 8 and @offsetOf(Departure, "times") == 16);
    std.debug.assert(@sizeOf(Stop) == 8 and @offsetOf(Stop, "attrs") == 0);
    std.debug.assert(@sizeOf(Route) == 40 and @offsetOf(Route, "id") == 8 and @offsetOf(Route, "details") == 32);
    std.debug.assert(@sizeOf(Schedule) == 16 and @offsetOf(Schedule, "attrs") == 8);
    std.debug.assert(@sizeOf(Transfer) == 12 and @offsetOf(Transfer, "attrs") == 8);
}
