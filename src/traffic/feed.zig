//! Generic stable edge-key updates for the live traffic overlay.
const std = @import("std");
const io = @import("../infra/io.zig");
const csv = @import("../build/gtfs/csv.zig");
const keys = @import("../graph/edge_keys.zig");
const live = @import("live.zig");
const expiry = @import("expiry.zig");
const EdgeId = @import("../graph/format.zig").EdgeId;
const Allocator = std.mem.Allocator;

pub const Format = enum { csv, jsonl };

const Row = struct {
    edge_key: []const u8,
    speed: i64,
    speed1: ?i64 = null,
    speed2: ?i64 = null,
    speed3: ?i64 = null,
    breakpoint1: ?i64 = null,
    breakpoint2: ?i64 = null,
    congestion1: ?i64 = null,
    congestion2: ?i64 = null,
    congestion3: ?i64 = null,
    observed_at: ?i64 = null,
};
const columns = std.meta.fieldNames(Row);
const max_row_bytes = 4096;

pub const Observation = struct {
    key: keys.Key,
    record: live.Record,
    observed_at: ?u64,
};

pub const Item = union(enum) {
    observation: Observation,
    invalid_row,
    out_of_range,
};

pub const Input = struct {
    rest: []const u8,
    format: Format,
    csv_fields: std.ArrayList(csv.Field) = .empty,
    gpa: Allocator,
    json_storage: std.heap.ArenaAllocator,
    first_row: bool = true,
    lines: usize = 0,

    pub fn init(gpa: Allocator, bytes: []const u8, format: Format) Input {
        const bom = "\xef\xbb\xbf";
        return .{
            .rest = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes,
            .format = format,
            .gpa = gpa,
            .json_storage = .init(gpa),
        };
    }

    pub fn deinit(self: *Input) void {
        self.csv_fields.deinit(self.gpa);
        self.json_storage.deinit();
    }

    pub fn next(self: *Input, deadline: io.Deadline) !?Item {
        while (self.rest.len != 0) {
            if (self.lines % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            self.lines += 1;
            const line = self.takeLine(deadline) catch |err| switch (err) {
                error.TrafficRowTooLong => return .invalid_row,
                error.DeadlineExceeded => return err,
            };
            if (line.len == 0) continue;
            const first = self.first_row;
            self.first_row = false;
            const row = switch (self.format) {
                .csv => (self.readCsv(line, first) catch |err| switch (err) {
                    error.InvalidTrafficRow => return .invalid_row,
                    error.InvalidTrafficValue => return .out_of_range,
                    else => return err,
                }) orelse continue,
                .jsonl => self.readJson(line) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Overflow => return .out_of_range,
                    else => return .invalid_row,
                },
            };
            const key = keys.Key.parse(row.edge_key) catch return .invalid_row;
            const word = encode(row) catch return .out_of_range;
            const timestamp = if (row.observed_at) |time|
                std.math.cast(u64, time) orelse return .out_of_range
            else
                null;
            return .{ .observation = .{ .key = key, .record = word, .observed_at = timestamp } };
        }
        return null;
    }

    fn takeLine(self: *Input, deadline: io.Deadline) error{ TrafficRowTooLong, DeadlineExceeded }![]const u8 {
        var offset: usize = 0;
        while (offset < self.rest.len) {
            const end = @min(self.rest.len, offset +| max_row_bytes);
            if (std.mem.findAny(u8, self.rest[offset..end], "\r\n")) |found| {
                const stop = offset + found;
                const line = self.rest[0..stop];
                self.rest = self.rest[stop + 1 ..];
                if (line.len > max_row_bytes) return error.TrafficRowTooLong;
                return std.mem.trim(u8, line, " \t");
            }
            offset = end;
            if (deadline.expired()) return error.DeadlineExceeded;
        }
        const line = self.rest;
        self.rest = &.{};
        if (line.len > max_row_bytes) return error.TrafficRowTooLong;
        return std.mem.trim(u8, line, " \t");
    }

    fn readCsv(self: *Input, text: []const u8, first: bool) !?Row {
        var input = csv.Reader.init(text, "");
        var diagnostic: csv.Diagnostic = .{};
        // takeLine bounds this scan to max_row_bytes.
        const fields = (input.next(self.gpa, &self.csv_fields, &diagnostic, .none) catch |err| switch (err) {
            error.InvalidQuote => return error.InvalidTrafficRow,
            else => return err,
        }) orelse return error.InvalidTrafficRow;
        if (fields.len < 2 or fields.len > columns.len) return error.InvalidTrafficRow;
        if (first and std.mem.eql(u8, fields[0].raw, columns[0])) {
            for (fields, columns[0..fields.len]) |field, name| {
                if (!std.mem.eql(u8, field.raw, name)) return error.InvalidTrafficRow;
            }
            return null;
        }
        var result: Row = .{ .edge_key = fields[0].raw, .speed = try parseNumber(fields[1]) };
        inline for (columns[2..], 2..) |name, i| {
            if (i < fields.len and fields[i].raw.len != 0)
                @field(result, name) = try parseNumber(fields[i]);
        }
        return result;
    }

    fn readJson(self: *Input, text: []const u8) !Row {
        _ = self.json_storage.reset(.retain_capacity);
        return std.json.parseFromSliceLeaky(Row, self.json_storage.allocator(), text, .{});
    }
};

fn parseNumber(field: csv.Field) error{InvalidTrafficValue}!i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, field.raw, " \t"), 10) catch error.InvalidTrafficValue;
}

fn speedWord(kph: i64) error{InvalidTrafficValue}!u7 {
    if (kph < 0 or kph > 252) return error.InvalidTrafficValue;
    return if (kph == 0) 0 else @intCast(@max(1, @divTrunc(kph, 2)));
}

fn encode(row: Row) error{InvalidTrafficValue}!live.Record {
    const overall = try speedWord(row.speed);
    const first = std.math.cast(u8, row.breakpoint1 orelse 255) orelse return error.InvalidTrafficValue;
    const second = std.math.cast(u8, row.breakpoint2 orelse if (first == 255) @as(i64, 0) else 255) orelse
        return error.InvalidTrafficValue;
    if (first == 0 or (first == 255 and second != 0 and second != 255) or
        (first != 255 and second <= first) or
        (first == 255 and (row.speed2 != null or row.congestion2 != null)) or
        ((first == 255 or second == 255) and (row.speed3 != null or row.congestion3 != null)))
        return error.InvalidTrafficValue;
    const segment1 = if (row.speed1) |value| try speedWord(value) else overall;
    const segment2 = if (row.speed2) |value| try speedWord(value) else live.unknown_speed;
    const segment3 = if (row.speed3) |value| try speedWord(value) else live.unknown_speed;
    return .{
        .overall = overall,
        .speed1 = segment1,
        .speed2 = segment2,
        .speed3 = segment3,
        .breakpoint1 = first,
        .breakpoint2 = second,
        .congestion1 = std.math.cast(u6, row.congestion1 orelse 0) orelse return error.InvalidTrafficValue,
        .congestion2 = std.math.cast(u6, row.congestion2 orelse 0) orelse return error.InvalidTrafficValue,
        .congestion3 = std.math.cast(u6, row.congestion3 orelse 0) orelse return error.InvalidTrafficValue,
    };
}

pub const Report = struct {
    rows: usize = 0,
    applied: usize = 0,
    invalid_rows: usize = 0,
    out_of_range: usize = 0,
    unknown: usize = 0,
    unknown_keys: []const keys.Key = &.{},
    not_drivable: usize = 0,
    older_observations: usize = 0,
    expired: usize = 0,
    metadata: ?live.Metadata = null,

    pub fn deinit(self: Report, a: Allocator) void {
        a.free(self.unknown_keys);
    }
};

pub const Feeder = struct {
    writer: live.Writer,
    ages: expiry.Ages,
    index: keys.View,
    max_age: u64,

    pub fn open(a: Allocator, dir: io.Directory, graph: live.Graph, index: keys.View, max_age: u64, deadline: io.Deadline) !Feeder {
        const writer = live.Writer.open(dir, graph, deadline) catch |err| switch (err) {
            error.FileNotFound => live.Writer.create(dir, graph, deadline) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => try live.Writer.open(dir, graph, deadline),
                else => return create_err,
            },
            else => return err,
        };
        errdefer writer.close();
        return .{ .writer = writer, .ages = try expiry.Ages.open(a, dir, writer.view, deadline), .index = index, .max_age = max_age };
    }

    pub fn close(self: Feeder) void {
        self.ages.close();
        self.writer.close();
    }

    pub fn apply(self: *Feeder, a: Allocator, input: []const u8, kind: Format, now: u64, deadline: io.Deadline) !Report {
        var parser = Input.init(a, input, kind);
        defer parser.deinit();
        var report: Report = .{};
        var batch: ?live.Batch = null;
        var missing: std.AutoArrayHashMapUnmanaged(keys.Key, void) = .empty;
        defer missing.deinit(a);
        try self.ages.prepare(self.writer.view, deadline);
        while (try parser.next(deadline)) |item| {
            report.rows += 1;
            switch (item) {
                .invalid_row => report.invalid_rows += 1,
                .out_of_range => report.out_of_range += 1,
                .observation => |observation| {
                    const timestamp = observation.observed_at orelse now;
                    if (timestamp == 0 or timestamp > now) {
                        report.out_of_range += 1;
                        continue;
                    }
                    const id = (try self.index.find(observation.key)) orelse {
                        report.unknown += 1;
                        _ = try missing.getOrPut(a, observation.key);
                        continue;
                    };
                    const slot = self.writer.view.slot(id) orelse {
                        report.not_drivable += 1;
                        continue;
                    };
                    const existing = self.ages.observed[@backingInt(slot)];
                    if (timestamp < existing) {
                        report.older_observations += 1;
                        continue;
                    }
                    const stale = expiry.isDue(timestamp, now, self.max_age);
                    try self.put(&batch, now, id, if (stale) .unknown else observation.record, if (stale) 0 else timestamp);
                    report.applied += 1;
                    report.expired += @intFromBool(stale);
                },
            }
        }
        report.expired += try self.expireDue(&batch, now, deadline);
        report.unknown_keys = try a.dupe(keys.Key, missing.keys());
        errdefer report.deinit(a);
        report.metadata = try self.finish(&batch, now, deadline);
        return report;
    }

    pub fn expire(self: *Feeder, now: u64, deadline: io.Deadline) !usize {
        try self.ages.prepare(self.writer.view, deadline);
        if (!expiry.isDue(self.ages.oldest, now, self.max_age)) return 0;
        var batch: ?live.Batch = null;
        const count = try self.expireDue(&batch, now, deadline);
        _ = try self.finish(&batch, now, deadline);
        return count;
    }

    fn expireDue(self: *Feeder, batch: *?live.Batch, now: u64, deadline: io.Deadline) !usize {
        if (!expiry.isDue(self.ages.oldest, now, self.max_age)) return 0;
        var expired: usize = 0;
        for (self.writer.view.blocks, self.ages.earliest, 0..) |block, oldest, group| {
            if (group % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!expiry.isDue(oldest, now, self.max_age)) continue;
            var mask = block.mask;
            var slot = block.first;
            while (mask != 0) : ({
                mask &= mask - 1;
                slot += 1;
            }) {
                if (!expiry.isDue(self.ages.observed[slot], now, self.max_age)) continue;
                const edge: EdgeId = @fromBackingInt(@as(u32, @intCast(group * 64 + @ctz(mask))));
                try self.put(batch, now, edge, .unknown, 0);
                expired += 1;
            }
        }
        return expired;
    }

    fn put(self: *Feeder, batch: *?live.Batch, now: u64, edge: EdgeId, record: live.Record, timestamp: u64) !void {
        if (batch.* == null) batch.* = try self.writer.begin(now);
        const slot = try batch.*.?.put(edge, record);
        self.ages.update(slot, edge, timestamp);
    }

    fn finish(self: *Feeder, batch: *?live.Batch, now: u64, deadline: io.Deadline) !?live.Metadata {
        try self.ages.refreshDue(self.writer.view, now, self.max_age, deadline);
        if (deadline.expired()) return error.DeadlineExceeded;
        const metadata = if (batch.*) |*active| active.finish() else return self.writer.view.metadata();
        self.ages.header.epoch = metadata.epoch;
        return metadata;
    }
};
