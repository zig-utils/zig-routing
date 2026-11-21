//! Interpret forward geocoder fields with the same analyzer as the index.
const std = @import("std");
const io = @import("../infra/io.zig");
const analysis = @import("analyze.zig");
const postal = @import("postcode.zig");
const format = @import("index_model.zig");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 4096;
pub const max_tokens = 64;

pub const Structured = struct {
    name: []const u8 = "",
    street: []const u8 = "",
    city: []const u8 = "",
    postcode: []const u8 = "",
    house_number: []const u8 = "",
    country: []const u8 = "",

    pub fn byteCount(self: Structured) usize {
        var count: usize = 0;
        inline for (@typeInfo(Structured).@"struct".field_names) |name| count +|= @field(self, name).len;
        return count;
    }
};

pub const Text = union(enum) {
    free: []const u8,
    structured: Structured,
};

pub const Term = struct {
    text: []const u8,
    latin: []const u8 = "",
    kind: analysis.Kind = .word,
    prefix: bool = false,
    /// A structured field is a constraint. Free text can match several roles.
    field: ?format.Field = null,
};

pub fn checkText(text: Text) !void {
    const count = switch (text) {
        .free => |value| value.len,
        .structured => |value| value.byteCount(),
    };
    if (count > max_input_bytes) return error.GeocodeQueryTooLong;
    switch (text) {
        .free => |value| if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8,
        .structured => |value| {
            inline for (@typeInfo(Structured).@"struct".field_names) |name| {
                if (!std.unicode.utf8ValidateSlice(@field(value, name))) return error.InvalidUtf8;
            }
        },
    }
}

pub fn parse(
    a: Allocator,
    text: Text,
    locale: analysis.Options,
    iso: []const u8,
    scratch: *analysis.Scratch,
    deadline: io.Deadline,
) ![]const Term {
    var terms: std.ArrayList(Term) = .empty;
    switch (text) {
        .free => |value| try analyze(a, &terms, scratch, value, null, locale, deadline),
        .structured => |value| {
            try analyze(a, &terms, scratch, value.name, .name, locale, deadline);
            try analyze(a, &terms, scratch, value.street, .street, locale, deadline);
            try analyze(a, &terms, scratch, value.city, .city, locale, deadline);
            try analyze(a, &terms, scratch, value.house_number, .house_number, .{}, deadline);
            if (value.postcode.len != 0) {
                const normalized = postal.Code.normalize(value.postcode, iso) orelse return error.InvalidGeocodePostcode;
                const key = try a.alloc(u8, normalized.len);
                _ = std.ascii.lowerString(key, normalized.bytes());
                try terms.append(a, .{ .text = key, .kind = .postcode, .field = .postcode });
            }
        },
    }
    if (terms.items.len > max_tokens) return error.TooManyGeocodeTokens;
    return terms.items;
}

fn analyze(
    a: Allocator,
    terms: *std.ArrayList(Term),
    scratch: *analysis.Scratch,
    value: []const u8,
    field: ?format.Field,
    locale: analysis.Options,
    deadline: io.Deadline,
) !void {
    if (value.len == 0) return;
    const parsed = try scratch.analyze(a, value, locale, deadline);
    if (terms.items.len + parsed.tokens.len > max_tokens) return error.TooManyGeocodeTokens;
    const bytes = try a.dupe(u8, parsed.bytes);
    const target = try terms.addManyAsSlice(a, parsed.tokens.len);
    for (parsed.tokens, target) |token, *term| term.* = .{
        .text = try token.text.get(bytes),
        .latin = try token.latin.get(bytes),
        .kind = token.attr.kind,
        .prefix = token.attr.prefix,
        .field = field,
    };
}

pub fn sameSequence(a: []const Term, b: []const Term) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.mem.eql(u8, left.text, right.text)) continue;
        const same_alias = (left.latin.len != 0 and
            (std.mem.eql(u8, left.latin, right.text) or std.mem.eql(u8, left.latin, right.latin))) or
            (right.latin.len != 0 and std.mem.eql(u8, left.text, right.latin));
        if (!same_alias) return false;
    }
    return true;
}
