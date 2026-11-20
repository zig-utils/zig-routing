//! Country-specific street and locality lines for geocoding results.
const std = @import("std");
const postcode = @import("postcode.zig");

pub const Components = struct {
    street: []const u8 = "",
    number: []const u8 = "",
    unit: []const u8 = "",
    postcode: []const u8 = "",
    locality: []const u8 = "",
};

pub const Lines = struct {
    street: []const u8,
    locality: []const u8,
};

pub const Format = struct {
    street_order: enum { number_first, number_comma, street_first } = .number_first,
    unit_separator: []const u8 = ", ",
    postcode_prefix: []const u8 = "",

    pub fn forCountry(iso: []const u8) Format {
        if (iso.len != 2) return .{};
        const uppercase = [_]u8{ std.ascii.toUpper(iso[0]), std.ascii.toUpper(iso[1]) };
        return formats.get(&uppercase) orelse .{};
    }
};

// Postal operator examples are listed in docs/design/geocoder-addresses.md.
const street_number: Format = .{ .street_order = .street_first, .unit_separator = "/" };
const formats = std.StaticStringMap(Format).initComptime(.{
    .{ "AT", street_number },
    .{ "CH", street_number },
    .{ "LI", street_number },
    .{ "LU", Format{ .street_order = .number_comma, .postcode_prefix = "L-" } },
});

/// Formats two nonempty lines into caller-owned storage. Missing components
/// are omitted along with their separators.
pub fn render(iso: []const u8, fields: Components, street_buffer: []u8, locality_buffer: []u8) !Lines {
    const rules = Format.forCountry(iso);
    var street: Line = .{ .buffer = street_buffer };
    var locality: Line = .{ .buffer = locality_buffer };
    if (rules.street_order == .street_first) {
        try street.add(" ", fields.street);
        try street.add(" ", fields.number);
        try street.add(if (fields.number.len == 0) " " else rules.unit_separator, fields.unit);
    } else {
        try street.add(" ", fields.number);
        try street.add(if (rules.street_order == .number_comma) ", " else " ", fields.street);
        try street.add(rules.unit_separator, fields.unit);
    }
    const code = if (rules.street_order == .number_first) null else postcode.Code.normalize(fields.postcode, iso);
    if (code) |normalized| {
        try locality.add("", rules.postcode_prefix);
        try locality.add("", normalized.bytes());
    } else {
        try locality.add("", fields.postcode);
    }
    try locality.add(" ", fields.locality);
    return .{ .street = street.bytes(), .locality = locality.bytes() };
}

const Line = struct {
    buffer: []u8,
    used: usize = 0,

    fn add(self: *Line, separator: []const u8, component: []const u8) !void {
        if (component.len == 0) return;
        const join = if (self.used != 0) separator else "";
        const available = self.buffer.len - self.used;
        if (join.len > available or component.len > available - join.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.used..][0..join.len], join);
        self.used += join.len;
        @memcpy(self.buffer[self.used..][0..component.len], component);
        self.used += component.len;
    }

    fn bytes(self: Line) []const u8 {
        return self.buffer[0..self.used];
    }
};

test "address rendering follows country-specific street and postcode ordering" {
    const t = std.testing;
    var street: [80]u8 = undefined;
    var locality: [80]u8 = undefined;
    const lu = try render("lu", .{ .street = "rue du Verger", .number = "12", .postcode = "L-1500", .locality = "Luxembourg" }, &street, &locality);
    try t.expectEqualStrings("12, rue du Verger", lu.street);
    try t.expectEqualStrings("L-1500 Luxembourg", lu.locality);
    const ch = try render("CH", .{ .street = "Lindenstrasse", .number = "4A", .unit = "2", .postcode = "8000", .locality = "Zürich" }, &street, &locality);
    try t.expectEqualStrings("Lindenstrasse 4A/2", ch.street);
    try t.expectEqualStrings("8000 Zürich", ch.locality);
    const generic = try render("", .{ .street = "Main Street", .number = "16", .locality = "Town" }, &street, &locality);
    try t.expectEqualStrings("16 Main Street", generic.street);
    try t.expectEqualStrings("Town", generic.locality);
}
