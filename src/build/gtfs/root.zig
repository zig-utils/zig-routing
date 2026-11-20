// Ported from src/mjolnir/ingest_transit.cc's feed input model (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../../infra/io.zig");
pub const csv = @import("csv.zig");
pub const model = @import("model.zig");
const table = @import("table.zig");
pub const Feed = model.Feed;
pub const Diagnostic = csv.Diagnostic;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Zero selects the machine's available CPU count.
    workers: usize = 0,
    max_member_bytes: usize = std.math.maxInt(usize),
    deadline: io.Deadline = .none,
};

pub const Stats = struct {
    stop_times_ns: u64 = 0,
    stop_times_workers: usize = 0,
};

pub fn read(a: Allocator, path: []const u8, options: Options, diagnostic: *Diagnostic, stats: ?*Stats) !Feed {
    diagnostic.* = .{};
    if (stats) |result| result.* = .{};
    const file = try io.File.open(path, .read_only);
    defer file.close();
    return readArchive(a, file, options, diagnostic, stats);
}

fn readArchive(a: Allocator, file: io.File, options: Options, diagnostic: *Diagnostic, stats: ?*Stats) !Feed {
    var file_buffer: [64 * 1024]u8 = undefined;
    var zip: io.Zip = .init(file, &file_buffer);
    var entries = try zip.entries();
    var members: std.EnumArray(model.Table, ?io.Zip.Entry) = .initFill(null);
    var name_buffer: [std.math.maxInt(u16)]u8 = undefined;
    while (try entries.next()) |entry| {
        if (options.deadline.expired()) return error.DeadlineExceeded;
        const name = try zip.filename(entry, &name_buffer);
        const kind = tableName(name) orelse continue;
        if (members.get(kind) != null) {
            diagnostic.set(fileName(kind), 0, 0, "");
            return error.DuplicateMember;
        }
        members.set(kind, entry);
    }
    for ([_]model.Table{ .agency, .stops, .routes, .trips, .stop_times }) |kind| {
        if (members.get(kind) == null) {
            diagnostic.set(fileName(kind), 0, 0, "");
            return error.MissingMember;
        }
    }
    if (members.get(.calendar) == null and members.get(.calendar_dates) == null) {
        diagnostic.set("calendar.txt", 0, 0, "calendar_dates.txt");
        return error.MissingServiceCalendar;
    }

    var feed: Feed = .init(a);
    errdefer feed.deinit();
    inline for (std.enums.values(model.Table)) |kind| {
        if (members.get(kind)) |entry| {
            var temporary: std.heap.ArenaAllocator = .init(a);
            defer temporary.deinit();
            const scratch = temporary.allocator();
            if (entry.uncompressed_size > options.max_member_bytes) {
                diagnostic.set(kind.name(), 0, 0, "");
                return error.MemberTooLarge;
            }
            const bytes = try scratch.alloc(u8, @intCast(entry.uncompressed_size));
            zip.read(entry, bytes, options.deadline) catch |err| {
                diagnostic.set(kind.name(), 0, 0, "");
                return err;
            };
            if (kind == .stop_times) {
                const start = io.monotonicNs();
                const workers = try stopTimes(&feed, scratch, bytes, options, diagnostic);
                if (stats) |result| {
                    result.stop_times_ns = io.monotonicNs() - start;
                    result.stop_times_workers = workers;
                }
            } else {
                @field(feed, @tagName(kind)) = try regular(kind, &feed, scratch, bytes, diagnostic, options.deadline);
            }
        }
    }
    return feed;
}

fn tableName(name: []const u8) ?model.Table {
    inline for (std.enums.values(model.Table)) |kind| {
        if (std.mem.eql(u8, name, kind.name())) return kind;
    }
    return null;
}

fn fileName(kind: model.Table) []const u8 {
    return switch (kind) {
        inline else => |known| known.name(),
    };
}

fn header(
    comptime kind: model.Table,
    reader: *csv.Reader,
    scratch: *table.Scratch,
    diagnostic: *Diagnostic,
    deadline: io.Deadline,
) !table.Columns(kind) {
    const fields = (try reader.next(scratch.a, &scratch.fields, diagnostic, deadline)) orelse {
        diagnostic.set(kind.name(), 1, 1, "");
        return error.MissingHeader;
    };
    return table.Columns(kind).fromHeader(fields, reader.row, diagnostic, deadline);
}

fn regular(
    comptime kind: model.Table,
    feed: *Feed,
    allocator: Allocator,
    bytes: []const u8,
    diagnostic: *Diagnostic,
    deadline: io.Deadline,
) ![]const kind.rowType() {
    var scratch: table.Scratch = .{ .a = allocator };
    defer scratch.deinit();
    var parser = csv.Reader.init(bytes, kind.name());
    const columns = try header(kind, &parser, &scratch, diagnostic, deadline);
    const context: table.Context = .{ .feed = feed };
    const persistent = feed.arena.allocator();
    var values: std.ArrayList(kind.rowType()) = .empty;
    while (try parser.next(allocator, &scratch.fields, diagnostic, deadline)) |row| {
        const item = try columns.decode(row, parser.row, context, &scratch, diagnostic, deadline);
        try values.append(persistent, item);
    }
    return values.items;
}

const StopJob = struct {
    bytes: []const u8,
    columns: table.Columns(.stop_times),
    context: table.Context,
    output: std.MultiArrayList(model.StopTime).Slice,
    row_offset: usize,
    begin: usize,
    limit: usize,
    deadline: io.Deadline,
    work: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    text_values: []const []const u8 = &.{},
    written: usize = 0,
    diagnostic: Diagnostic = .{},
    failure: ?anyerror = null,

    fn run(self: *StopJob) void {
        self.parse() catch |err| {
            self.failure = err;
        };
    }

    fn parse(self: *StopJob) !void {
        var scratch: table.Scratch = .{ .a = self.work.allocator() };
        var parser: csv.Reader = .{ .bytes = self.bytes, .file = model.Table.stop_times.name(), .row = self.row_offset };
        while (try parser.next(scratch.a, &scratch.fields, &self.diagnostic, self.deadline)) |row| {
            if (self.written == self.limit) return error.StopTimePartitionMismatch;
            const item = try self.columns.decode(row, parser.row, self.context, &scratch, &self.diagnostic, self.deadline);
            if (item.stop_id == null and item.location_id == null and item.location_group_id == null) {
                const stop_column = self.columns.indexOf("stop_id");
                self.diagnostic.set(parser.file, parser.row, if (stop_column < row.len) stop_column + 1 else row.len + 1, "stop_id");
                return error.MissingStopLocation;
            }
            self.output.set(self.begin + self.written, item);
            self.written += 1;
        }
        self.text_values = scratch.text_values.items;
    }

    fn remapText(self: StopJob, feed: *Feed, a: Allocator) !void {
        if (self.text_values.len == 0) return;
        const ids = try a.alloc(model.Text, self.text_values.len);
        defer a.free(ids);
        for (ids, self.text_values) |*id, text| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            id.* = try feed.internText(text);
        }
        const fields = @typeInfo(model.StopTime).@"struct";
        inline for (fields.field_names, fields.field_types) |name, Field| {
            if (Field == ?model.Text and self.columns.indexOf(name) < self.columns.width) {
                const column = self.output.items(@field(std.MultiArrayList(model.StopTime).Field, name));
                for (column[self.begin..][0..self.written], 0..) |*value, i| {
                    if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
                    if (value.*) |id| value.* = ids[@backingInt(id)];
                }
            }
        }
    }
};

fn stopTimes(feed: *Feed, a: Allocator, bytes: []const u8, options: Options, diagnostic: *Diagnostic) !usize {
    var parser = csv.Reader.init(bytes, model.Table.stop_times.name());
    var scratch: table.Scratch = .{ .a = a };
    defer scratch.deinit();
    const columns = try header(.stop_times, &parser, &scratch, diagnostic, options.deadline);
    const workers = if (options.workers == 0) std.Thread.getCpuCount() catch 1 else options.workers;
    const chunks = try csv.partition(a, bytes[parser.position..], workers, options.deadline);
    defer a.free(chunks);
    if (chunks.len == 0) return 0;

    const final = chunks[chunks.len - 1];
    try feed.stop_times.resize(feed.arena.allocator(), final.row_offset + final.records);
    const context: table.Context = .{ .feed = feed, .local_text = true };
    const jobs = try a.alloc(StopJob, chunks.len);
    defer a.free(jobs);
    var prepared: usize = 0;
    defer for (jobs[0..prepared]) |*job| job.work.deinit();
    for (jobs, chunks) |*job, chunk| {
        if (options.deadline.expired()) return error.DeadlineExceeded;
        job.* = .{
            .bytes = chunk.bytes,
            .columns = columns,
            .context = context,
            .output = feed.stop_times.slice(),
            .row_offset = parser.row + chunk.row_offset,
            .begin = chunk.row_offset,
            .limit = chunk.records,
            .deadline = options.deadline,
        };
        prepared += 1;
    }
    {
        const threads = try a.alloc(std.Thread, chunks.len - 1);
        defer a.free(threads);
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (threads, jobs[1..]) |*thread, *job| {
            if (options.deadline.expired()) return error.DeadlineExceeded;
            thread.* = try std.Thread.spawn(.{}, StopJob.run, .{job});
            started += 1;
        }
        jobs[0].run();
    }
    var count: usize = 0;
    for (jobs) |job| {
        if (options.deadline.expired()) return error.DeadlineExceeded;
        if (job.failure) |err| {
            diagnostic.* = job.diagnostic;
            return err;
        }
        try job.remapText(feed, a);
        if (count != job.begin) {
            for (0..job.written) |i| {
                if (i % 256 == 0 and options.deadline.expired()) return error.DeadlineExceeded;
                feed.stop_times.set(count + i, feed.stop_times.get(job.begin + i));
            }
        }
        count += job.written;
    }
    feed.stop_times.shrinkRetainingCapacity(count);
    return jobs.len;
}

test "GTFS typed records intern IDs, match reordered headers and report invalid fields" {
    const a = std.testing.allocator;
    var feed = Feed.init(a);
    defer feed.deinit();
    var diagnostic: Diagnostic = .{};
    const stops = try regular(.stops, &feed, a, "unknown,stop_name,stop_id\n1,\"West, Station\",west\n", &diagnostic, .none);
    try std.testing.expectEqual(1, stops.len);
    try std.testing.expectEqualStrings("West, Station", feed.text(stops[0].stop_name.?));
    try std.testing.expectEqualStrings("west", feed.idName(stops[0].stop_id));
    try std.testing.expectEqual(null, stops[0].stop_lat);
    try std.testing.expectError(error.InvalidEnum, regular(.routes, &feed, a, "route_type,route_id\n127,x", &diagnostic, .none));
    try std.testing.expectEqualStrings("routes.txt", diagnostic.file);
    try std.testing.expectEqualStrings("route_type", diagnostic.field);
    try std.testing.expectEqual(2, diagnostic.row);
    try std.testing.expectEqual(1, diagnostic.column);
}

test "parallel stop times keep file order across escaped records and blank rows" {
    const a = std.testing.allocator;
    var feed = Feed.init(a);
    defer feed.deinit();
    _ = try feed.internId(.trip, "trip");
    _ = try feed.internId(.stop, "stop");
    var diagnostic: Diagnostic = .{};
    const input = "stop_id,arrival_time,trip_id,stop_sequence,stop_headsign\r\n" ++
        "stop,24:50:10,trip,1,\"first\r\nline\"\r\n\r\n" ++
        "stop,25:01:00,trip,2,second\r\n" ++
        "stop,25:02:00,trip,3,third";
    const workers = try stopTimes(&feed, a, input, .{ .workers = 3 }, &diagnostic);
    try std.testing.expect(workers > 1);
    try std.testing.expectEqual(3, feed.stop_times.len);
    try std.testing.expectEqual(89_410, feed.stop_times.get(0).arrival_time.?.seconds);
    try std.testing.expectEqualStrings("first\r\nline", feed.text(feed.stop_times.get(0).stop_headsign.?));
    try std.testing.expectEqual(3, feed.stop_times.get(2).stop_sequence);
    var serial = Feed.init(a);
    defer serial.deinit();
    _ = try serial.internId(.trip, "trip");
    _ = try serial.internId(.stop, "stop");
    _ = try stopTimes(&serial, a, input, .{ .workers = 1 }, &diagnostic);
    try std.testing.expectEqualSlices(?model.Text, serial.stop_times.items(.stop_headsign), feed.stop_times.items(.stop_headsign));
}

test "GTFS reads a compressed archive and rejects a mismatched member CRC" {
    const a = std.testing.allocator;
    const input = @embedFile("fixtures/minimal.zip");
    const valid = try io.File.temporary(".");
    defer valid.close();
    try valid.writeAll(input);
    var diagnostic: Diagnostic = .{};
    var feed = try readArchive(a, valid, .{ .workers = 2 }, &diagnostic, null);
    defer feed.deinit();
    try std.testing.expectEqual(2, feed.count(.stop_times));
    try std.testing.expectEqual(1, feed.calendar_dates.len);
    try std.testing.expectEqual(87_090, feed.stop_times.get(1).departure_time.?.seconds);
    try std.testing.expectEqualStrings("B", feed.idName(feed.stop_times.get(1).stop_id.?));

    var corrupted: [input.len]u8 = input[0..input.len].*;
    const central = std.mem.find(u8, &corrupted, "PK\x01\x02").?;
    corrupted[14] ^= 1;
    corrupted[central + 16] ^= 1;
    const invalid = try io.File.temporary(".");
    defer invalid.close();
    try invalid.writeAll(&corrupted);
    try std.testing.expectError(error.ZipCrcMismatch, readArchive(a, invalid, .{}, &diagnostic, null));
    try std.testing.expectEqualStrings("agency.txt", diagnostic.file);
}

test {
    std.testing.refAllDecls(@This());
}
