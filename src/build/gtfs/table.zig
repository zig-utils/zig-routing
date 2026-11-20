//! Maps GTFS headers to typed columns and diagnoses malformed records.
const std = @import("std");
const csv = @import("csv.zig");
const model = @import("model.zig");
const io = @import("../../infra/io.zig");
const Allocator = std.mem.Allocator;
const no_column = std.math.maxInt(usize);

pub const Scratch = struct {
    a: Allocator,
    fields: std.ArrayList(csv.Field) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    text_ids: std.StringHashMapUnmanaged(model.Text) = .empty,
    text_values: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Scratch) void {
        self.fields.deinit(self.a);
        self.bytes.deinit(self.a);
        self.text_ids.deinit(self.a);
        self.text_values.deinit(self.a);
    }

    fn internText(self: *Scratch, bytes: []const u8) !model.Text {
        if (self.text_ids.get(bytes)) |id| return id;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
        const id: model.Text = @fromBackingInt(std.math.cast(u32, self.text_values.items.len) orelse return error.TooManyStrings);
        const stable = try self.a.dupe(u8, bytes);
        try self.text_values.append(self.a, stable);
        try self.text_ids.put(self.a, stable, id);
        return id;
    }
};

pub fn Columns(comptime table: model.Table) type {
    const Row = table.rowType();
    const fields = @typeInfo(Row).@"struct";
    return struct {
        const Self = @This();
        width: usize,
        positions: [fields.field_names.len]usize = @splat(no_column),

        pub fn fromHeader(header: []const csv.Field, row: usize, diagnostic: *csv.Diagnostic, deadline: io.Deadline) !Self {
            var result: Self = .{ .width = header.len };
            inline for (fields.field_names, fields.field_types, 0..) |name, Field, i| {
                for (header, 0..) |item, col| {
                    if (col % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                    if (item.escaped or !std.mem.eql(u8, name, item.raw)) continue;
                    if (result.positions[i] != no_column) {
                        diagnostic.set(table.name(), row, col + 1, name);
                        return error.DuplicateColumn;
                    }
                    result.positions[i] = col;
                }
                if (@typeInfo(Field) != .optional and result.positions[i] == no_column) {
                    diagnostic.set(table.name(), row, header.len + 1, name);
                    return error.MissingColumn;
                }
            }
            return result;
        }

        pub fn indexOf(self: Self, comptime name: []const u8) usize {
            inline for (fields.field_names, 0..) |field, i| {
                if (comptime std.mem.eql(u8, field, name)) return self.positions[i];
            }
            @compileError("unknown GTFS field " ++ name);
        }

        pub fn decode(self: Self, values: []const csv.Field, row: usize, context: Context, scratch: *Scratch, diagnostic: *csv.Diagnostic, deadline: io.Deadline) !Row {
            if (values.len != self.width) {
                diagnostic.set(table.name(), row, @min(values.len, self.width) + 1, "");
                return error.FieldCountMismatch;
            }
            var out: Row = undefined;
            inline for (fields.field_names, fields.field_types, self.positions) |name, Field, col| {
                const raw: csv.Field = if (col == no_column) .{ .raw = "" } else values[col];
                @field(out, name) = context.fieldValue(Field, raw, scratch, deadline) catch |err| {
                    if (err != error.OutOfMemory and err != error.DeadlineExceeded)
                        diagnostic.set(table.name(), row, if (col == no_column) self.width + 1 else col + 1, name);
                    return err;
                };
            }
            return out;
        }
    };
}

pub const Context = struct {
    feed: *model.Feed,
    /// Parallel jobs read entity indexes and intern text into local scratch.
    /// The loader remaps those text IDs after joining the jobs.
    local_text: bool = false,

    pub fn fieldValue(self: Context, comptime T: type, field: csv.Field, scratch: *Scratch, deadline: io.Deadline) !T {
        if (comptime @typeInfo(T) == .optional) {
            if (field.raw.len == 0) return null;
            return try self.fieldValue(@typeInfo(T).optional.child, field, scratch, deadline);
        }
        if (field.raw.len == 0) return error.MissingValue;
        const bytes = try field.text(scratch.a, &scratch.bytes, deadline);
        if (T == model.Text) {
            if (self.local_text) return scratch.internText(bytes);
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
            return self.feed.internText(bytes);
        }
        if (T == model.Time) return time(bytes);
        if (T == model.Date) return date(bytes);
        if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "namespace")) {
            if (self.local_text) return self.feed.findId(T.namespace, bytes) orelse error.UnknownId;
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
            return self.feed.internId(T.namespace, bytes);
        }
        return switch (@typeInfo(T)) {
            .bool => if (bytes.len != 1 or bytes[0] < '0' or bytes[0] > '1') error.InvalidEnum else bytes[0] == '1',
            .int => |integer| if (integer.signedness == .signed)
                std.fmt.parseInt(T, bytes, 10) catch error.InvalidNumber
            else
                unsigned(T, bytes),
            .float => blk: {
                const value = std.fmt.parseFloat(T, bytes) catch return error.InvalidNumber;
                if (!std.math.isFinite(value)) return error.InvalidNumber;
                break :blk value;
            },
            .@"enum" => |enumeration| std.enums.fromInt(T, unsigned(enumeration.tag_type, bytes) catch return error.InvalidEnum) orelse error.InvalidEnum,
            else => @compileError("unsupported GTFS attribute type " ++ @typeName(T)),
        };
    }
};

fn unsigned(comptime T: type, bytes: []const u8) error{InvalidNumber}!T {
    var value: T = 0;
    for (bytes) |c| {
        const digit = c -% '0';
        if (digit > 9) return error.InvalidNumber;
        const scaled = @mulWithOverflow(value, 10);
        if (scaled[1] != 0) return error.InvalidNumber;
        const next = @addWithOverflow(scaled[0], @as(T, @intCast(digit)));
        if (next[1] != 0) return error.InvalidNumber;
        value = next[0];
    }
    return value;
}

fn two(bytes: *const [2]u8) ?u32 {
    const high = bytes[0] -% '0';
    const low = bytes[1] -% '0';
    if (high > 9 or low > 9) return null;
    return @as(u32, high) * 10 + low;
}

pub fn time(bytes: []const u8) error{InvalidTime}!model.Time {
    if (bytes.len < 7) return error.InvalidTime;
    const separator = bytes.len - 6;
    if (bytes[separator] != ':' or bytes[bytes.len - 3] != ':') return error.InvalidTime;
    const hour = if (separator == 2)
        two(bytes[0..2]) orelse return error.InvalidTime
    else
        unsigned(u32, bytes[0..separator]) catch return error.InvalidTime;
    const minute = two(bytes[separator + 1 ..][0..2]) orelse return error.InvalidTime;
    const second = two(bytes[bytes.len - 2 ..][0..2]) orelse return error.InvalidTime;
    if (minute >= 60 or second >= 60) return error.InvalidTime;
    const seconds = @as(u64, hour) * 3600 + minute * 60 + second;
    return .{ .seconds = std.math.cast(u32, seconds) orelse return error.InvalidTime };
}

pub fn date(bytes: []const u8) error{InvalidDate}!model.Date {
    if (bytes.len != 8) return error.InvalidDate;
    const value = unsigned(u32, bytes) catch return error.InvalidDate;
    const year = value / 10_000;
    const month = value / 100 % 100;
    const day = value % 100;
    if (year == 0 or month == 0 or month > 12 or day == 0) return error.InvalidDate;
    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    if (day > lengths[month - 1] + @intFromBool(month == 2 and leap)) return error.InvalidDate;
    return .{ .yyyymmdd = value };
}

test "GTFS times extend past midnight and dates follow Gregorian months" {
    const testing = std.testing;
    try testing.expectEqual(90_123, (try time("25:02:03")).seconds);
    try testing.expectEqual(3_600, (try time("1:00:00")).seconds);
    try testing.expectError(error.InvalidTime, time("24:60:00"));
    try testing.expectError(error.InvalidTime, time("999999999:59:00"));
    try testing.expectEqual(20240229, (try date("20240229")).yyyymmdd);
    try testing.expectError(error.InvalidDate, date("19000229"));
}
