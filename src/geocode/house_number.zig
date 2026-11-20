//! Normalize stored OSM house numbers for the per-street index.
const std = @import("std");

pub const Fraction = struct {
    numerator: u16 = 0,
    denominator: u16 = 1,
};

pub const Key = struct {
    number: u32,
    letters: []const u8 = "",
    fraction: Fraction = .{},

    pub fn order(left: Key, right: Key) std.math.Order {
        const numbers = std.math.order(left.number, right.number);
        if (numbers != .eq) return numbers;
        const fractions = std.math.order(
            @as(u32, left.fraction.numerator) * right.fraction.denominator,
            @as(u32, right.fraction.numerator) * left.fraction.denominator,
        );
        if (fractions != .eq) return fractions;
        return std.ascii.orderIgnoreCase(left.letters, right.letters);
    }
};

pub const Label = struct {
    first: Key,
    last: ?Key = null,
    unit: []const u8 = "",
};

pub const Error = error{InvalidHouseNumber};

/// Keys borrow the original strings. Comparisons fold ASCII letter case and
/// compare fractions by their rational value. The source label stays intact.
pub fn parse(raw: []const u8, explicit_unit: []const u8) Error!Label {
    if (raw.len > 128 or explicit_unit.len > 128) return error.InvalidHouseNumber;
    const separator = std.mem.indexOfScalar(u8, raw, '#');
    const number = trim(raw[0 .. separator orelse raw.len]);
    const tagged_unit = trim(explicit_unit);
    const unit = if (tagged_unit.len != 0) tagged_unit else if (separator) |i| trim(raw[i + 1 ..]) else "";
    const range = findRange(number) orelse return .{ .first = try key(number), .unit = unit };
    var first = try key(trim(number[0..range.start]));
    const right = trim(number[range.end..]);
    var last: Key = if (lettersOnly(right))
        .{ .number = first.number, .letters = right }
    else
        try key(right);
    if (first.order(last) == .gt) std.mem.swap(Key, &first, &last);
    return .{ .first = first, .last = last, .unit = unit };
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn findRange(text: []const u8) ?struct { start: usize, end: usize } {
    for ([_][]const u8{ "-", "–", "—" }) |separator| {
        if (std.mem.indexOf(u8, text, separator)) |start| return .{ .start = start, .end = start + separator.len };
    }
    return null;
}

fn key(text: []const u8) Error!Key {
    const digits = digitEnd(text);
    if (digits == 0) return error.InvalidHouseNumber;
    const number = std.fmt.parseInt(u32, text[0..digits], 10) catch return error.InvalidHouseNumber;
    const suffix = trim(text[digits..]);
    if (suffix.len == 0 or lettersOnly(suffix)) return .{ .number = number, .letters = suffix };
    if (unicode_fractions.get(suffix)) |fraction| return .{ .number = number, .fraction = fraction };
    if (digits == text.len or !std.ascii.isWhitespace(text[digits])) return error.InvalidHouseNumber;
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse return error.InvalidHouseNumber;
    const numerator = try fractionComponent(trim(suffix[0..slash]));
    const denominator = try fractionComponent(trim(suffix[slash + 1 ..]));
    if (numerator == 0 or numerator >= denominator) return error.InvalidHouseNumber;
    const divisor = std.math.gcd(numerator, denominator);
    return .{ .number = number, .fraction = .{ .numerator = numerator / divisor, .denominator = denominator / divisor } };
}

fn digitEnd(text: []const u8) usize {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    return end;
}

fn lettersOnly(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return true;
}

fn fractionComponent(text: []const u8) Error!u16 {
    if (text.len == 0 or digitEnd(text) != text.len) return error.InvalidHouseNumber;
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidHouseNumber;
}

const unicode_fractions = std.StaticStringMap(Fraction).initComptime(.{
    .{ "¼", Fraction{ .numerator = 1, .denominator = 4 } },
    .{ "½", Fraction{ .numerator = 1, .denominator = 2 } },
    .{ "¾", Fraction{ .numerator = 3, .denominator = 4 } },
    .{ "⅓", Fraction{ .numerator = 1, .denominator = 3 } },
    .{ "⅔", Fraction{ .numerator = 2, .denominator = 3 } },
    .{ "⅛", Fraction{ .numerator = 1, .denominator = 8 } },
    .{ "⅜", Fraction{ .numerator = 3, .denominator = 8 } },
    .{ "⅝", Fraction{ .numerator = 5, .denominator = 8 } },
    .{ "⅞", Fraction{ .numerator = 7, .denominator = 8 } },
});

test "house number keys normalize letters, units, ranges and fractions" {
    const t = std.testing;
    const single = try parse(" 0012a # Floor 2 ", "");
    try t.expectEqual(.eq, single.first.order(.{ .number = 12, .letters = "A" }));
    try t.expectEqualStrings("Floor 2", single.unit);
    const range = try parse("20–12b", " Flat 7 ");
    try t.expectEqual(.eq, range.first.order(.{ .number = 12, .letters = "B" }));
    try t.expectEqual(20, range.last.?.number);
    try t.expectEqualStrings("Flat 7", range.unit);
    const fractions = try parse("7 2/4", "");
    try t.expectEqual(.eq, fractions.first.order((try parse("7½", "")).first));
    try t.expectEqual(.lt, (try parse("7a", "")).first.order(fractions.first));
    try t.expectEqual(.eq, (try parse("2a-D", "")).last.?.order(.{ .number = 2, .letters = "d" }));
    try t.expectError(error.InvalidHouseNumber, parse("12/2", ""));
    try t.expectError(error.InvalidHouseNumber, parse("2 1/0", ""));
    try t.expectError(error.InvalidHouseNumber, parse("4294967296", ""));
}
