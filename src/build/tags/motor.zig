// Ported from lua/graph.lua and src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../../infra/io.zig");
const restriction = @import("../../graph/access_restriction.zig");
const defaults = @import("defaults.zig");
const Key = @import("table.zig").Key;
const Scratch = @import("input.zig").Scratch;
const WayAttrs = @import("attrs.zig").WayAttrs;

pub fn apply(tags: *const Scratch, deadline: io.Deadline, way: *WayAttrs) !void {
    way.flags.truck_route = tags.get(.@"hgv:national_network") != null or
        tags.get(.@"hgv:state_network") != null or
        (try defaults.any(.truck_route, tags.get(.hgv), deadline)) == true;

    inline for (.{ .both, .forward, .backward }) |direction| {
        inline for (.{ .hazmat, .maxheight, .maxwidth, .maxlength, .maxweight, .maxaxleload, .maxaxles }) |kind| {
            if (direction == .both or (kind != .maxaxleload and kind != .maxaxles))
                try append(tags, &way.motor_limits, kind, direction, deadline);
        }
    }
}

fn append(tags: *const Scratch, result: *restriction.Set, comptime kind: restriction.Kind, comptime direction: restriction.Direction, deadline: io.Deadline) !void {
    const suffix = if (direction == .both) "" else ":" ++ @tagName(direction);
    const key = @tagName(kind) ++ suffix;
    const raw = tags.text(@field(Key, key));
    const normalized = switch (kind) {
        .hazmat => hazmat(tags, suffix),
        .maxweight, .maxaxleload => try weight(raw, deadline),
        .maxaxles => if (raw) |value| try number(value, deadline) else null,
        else => try dimension(raw, deadline) orelse
            if (direction == .both and (kind == .maxheight or kind == .maxwidth))
                try dimension(tags.text(@field(Key, @tagName(kind) ++ ":physical")), deadline)
            else
                null,
    } orelse return;

    // The graph parser parses the normalized number as float before
    // scaling. The stored integer truncates the resulting float.
    const parsed: f32 = @floatCast(normalized);
    const value = if (kind == .hazmat or kind == .maxaxles) parsed else parsed * 100;
    if (!(value >= 0 and value < 0x1p64)) return;
    const exemption = tags.text(@field(Key, key ++ ":conditional"));
    result.items[result.len] = .{
        .value = @intFromFloat(value),
        .attr = .{
            .kind = kind,
            .direction = direction,
            .except_destination = (direction == .both or raw != null) and if (exemption) |text|
                oneOf(text, .{ "none @ destination", "none @ delivery", "no @ destination", "none @ (destination)" })
            else
                false,
        },
    };
    result.len += 1;
}

fn hazmat(tags: *const Scratch, comptime direction: []const u8) ?f64 {
    inline for (.{ "", ":water", ":A", ":B", ":C", ":D", ":E" }) |category| {
        if (tags.id(@field(Key, "hazmat" ++ category ++ direction))) |id| {
            switch (id) {
                .designated, .yes => return 1,
                .no, .destination, .delivery => return 0,
                else => {},
            }
        }
    }
    return null;
}

fn oneOf(value: []const u8, comptime options: anytype) bool {
    inline for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

fn roundHundredths(value: f64) f64 {
    return @floor(value * 100 + 0.5) / 100;
}

fn number(value: []const u8, deadline: io.Deadline) !?f64 {
    return parseNumber(value, false, deadline);
}

fn parseNumber(value: []const u8, commas: bool, deadline: io.Deadline) !?f64 {
    var comma: ?usize = null;
    for (value, 0..) |byte, i| {
        try checkDeadline(deadline, i);
        if (byte == '_') return null;
        if (byte != ',') continue;
        if (!commas or comma != null) return null;
        comma = i;
    }
    var buffer: [128]u8 = undefined;
    var allocated: ?[]u8 = null;
    defer if (allocated) |bytes| std.heap.page_allocator.free(bytes);
    const normalized = if (comma) |i| blk: {
        if (value.len > buffer.len) allocated = try std.heap.page_allocator.alloc(u8, value.len);
        const normalized = allocated orelse buffer[0..value.len];
        @memcpy(normalized, value);
        normalized[i] = '.';
        break :blk normalized;
    } else value;
    const parsed = std.fmt.parseFloat(f64, std.mem.trim(u8, normalized, " \t\n\r\x0b\x0c")) catch return null;
    return if (std.math.isFinite(parsed)) parsed else null;
}

fn dimension(raw: ?[]const u8, deadline: io.Deadline) !?f64 {
    const text = raw orelse return null;
    if (try parseNumber(text, true, deadline)) |value| return roundHundredths(value);

    // Lua's unanchored match consumes digits, an optional decimal, ASCII
    // spaces and a unit. Text between those matches is ignored.
    var i: usize = 0;
    var sum: f64 = 0;
    var found = false;
    while (i < text.len) {
        try checkDeadline(deadline, i);
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i = try scan(text, i + 1, std.ascii.isDigit, deadline);
        if (i < text.len and (text[i] == '.' or text[i] == ','))
            i = try scan(text, i + 1, std.ascii.isDigit, deadline);
        const item = try parseNumber(text[start..i], true, deadline) orelse return null;
        const unit = try scan(text, i, isSpace, deadline);
        i = try scan(text, unit, isUnit, deadline);
        const scale = dimensionUnit(text[unit..i]) orelse return null;
        sum += item * scale;
        found = true;
    }
    return if (found) roundHundredths(sum) else null;
}

fn dimensionUnit(unit: []const u8) ?f64 {
    inline for (.{
        .{ 1.0, .{ "m", "meter", "meters" } },
        .{ 0.01, .{"cm"} },
        .{ 0.3048, .{ "ft", "feet", "foot", "'" } },
        .{ 0.0254, .{ "in", "inches", "inch", "\"", "''" } },
    }) |group| {
        inline for (group[1]) |name| {
            if (std.ascii.eqlIgnoreCase(unit, name)) return group[0];
        }
    }
    return null;
}

fn weight(raw: ?[]const u8, deadline: io.Deadline) !?f64 {
    const text = raw orelse return null;
    var whitespace: usize = 0;
    for (text, 0..) |byte, i| {
        try checkDeadline(deadline, i);
        if (isLuaWhitespace(byte)) whitespace += 1;
    }
    var buffer: [128]u8 = undefined;
    var allocated: ?[]u8 = null;
    defer if (allocated) |bytes| std.heap.page_allocator.free(bytes);
    const compact = if (whitespace == 0) text else blk: {
        const len = text.len - whitespace;
        if (len > buffer.len) allocated = try std.heap.page_allocator.alloc(u8, len);
        const compact = allocated orelse buffer[0..len];
        var next: usize = 0;
        for (text, 0..) |byte, i| {
            try checkDeadline(deadline, i);
            if (isLuaWhitespace(byte)) continue;
            compact[next] = byte;
            next += 1;
        }
        break :blk compact;
    };
    const prefix = try defaults.numericPrefix(compact, true, deadline);
    const parsed = std.fmt.parseFloat(f64, prefix) catch return null;
    const unit = compact[prefix.len..];
    const divisor: f64 = if (oneOf(unit, .{ "lb", "lbs" })) 2000 else if (std.mem.eql(u8, unit, "kg")) 1000 else 1;
    return roundHundredths(parsed / divisor);
}

fn scan(text: []const u8, start: usize, comptime match: fn (u8) bool, deadline: io.Deadline) !usize {
    var i = start;
    while (i < text.len and match(text[i])) : (i += 1) try checkDeadline(deadline, i);
    return i;
}

fn isSpace(byte: u8) bool {
    return byte == ' ';
}

fn isLuaWhitespace(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '\x0b' or byte == '\x0c';
}

fn isUnit(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '"' or byte == '\'';
}

fn checkDeadline(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

test "Valhalla dimensions and weights accept compound, decimal and legacy values" {
    const expect = std.testing.expectEqual;
    try expect(@as(?f64, 4.11), try dimension("13'6\"", .none));
    try expect(@as(?f64, 1.07), try dimension("3FT 6Inches", .none));
    try expect(@as(?f64, 2.25), try dimension("225 cm", .none));
    try expect(@as(?f64, 2.75), try dimension(" 2,75 ", .none));
    try expect(@as(?f64, 1.83), try dimension("height approximately 6ft", .none));
    try expect(@as(?f64, 0.61), try dimension("2ft-", .none));
    try expect(null, try dimension("2ft 5 yards", .none));
    try expect(null, try dimension("4 m; 3", .none));
    try expect(null, try dimension("default", .none));
    try expect(@as(?f64, 3), try weight(" 6 000 l b s ", .none));
    try expect(@as(?f64, 3.58), try weight("3575 kg", .none));
    try expect(@as(?f64, 12.3), try weight("12.30 tonnes", .none));
    try expect(@as(?f64, 7.5), try weight("7.5 tons", .none));
    try expect(@as(?f64, 7.5), try weight("7.5 tonnes; 6", .none));
    try expect(@as(?f64, 7), try weight("7,5", .none));
    try expect(null, try weight("-2", .none));
    try expect(null, try weight("none", .none));
    try std.testing.expectError(error.DeadlineExceeded, weight("1228 kg", .{ .at_ns = 0 }));
    try std.testing.expectError(error.DeadlineExceeded, dimension("12 foot", .{ .at_ns = 0 }));
}
