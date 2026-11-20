//! Postal token patterns for the country attached to an analysis.
const std = @import("std");
const io = @import("../infra/io.zig");
const unicode = @import("unicode.zig");

pub const Country = enum {
    unknown,
    us,
    ca,
    gb,
    de,
    at,
    ch,
    li,
    lu,
    fr,
    nl,
    be,

    pub fn fromIso(iso: []const u8) Country {
        if (iso.len != 2) return .unknown;
        const lower = [_]u8{ std.ascii.toLower(iso[0]), std.ascii.toLower(iso[1]) };
        return std.meta.stringToEnum(Country, &lower) orelse .unknown;
    }
};

pub const Match = struct {
    consumed: usize,
    first: []const u8,
    second: []const u8 = "",
};

pub fn match(country: Country, input: []const u8, initial: bool, deadline: io.Deadline) !?Match {
    if (country == .unknown or input.len == 0) return null;
    var stem = input;
    const iso = @tagName(country);
    const prefixed = if (input.len >= 3 and input[2] == '-' and std.mem.eql(u8, input[0..2], iso))
        @as(usize, 3)
    else if (country == .lu and std.mem.startsWith(u8, input, "l-"))
        @as(usize, 2)
    else
        0;
    stem = stem[prefixed..];
    const first = stem[0..wordLength(stem)];
    if (first.len == 0 or first.len > 9) return null;
    var found: Match = undefined;
    switch (country) {
        .gb, .ca, .nl => {
            found = try mixed(country, stem, first, deadline) orelse return null;
        },
        else => {
            const digits: usize = if (country == .us or country == .de or country == .fr) 5 else 4;
            if (first.len != digits or !matchMask(first, if (digits == 5) "00000" else "0000")) return null;
            found = .{ .first = first, .consumed = first.len };
            if (country == .us and first.len < stem.len and stem[first.len] == '-') {
                const rest = stem[first.len + 1 ..];
                if (!matchMask(rest[0..wordLength(rest)], "0000")) return null;
                found = .{ .first = stem[0 .. first.len + 5], .consumed = first.len + 5 };
            } else if (initial and prefixed == 0 and try hasText(stem[first.len..], deadline)) {
                return null;
            }
        },
    }
    if (found.consumed < stem.len) {
        const next = stem[found.consumed];
        if (next == '-' or next == '/' or next == '\'') return null;
        if (next >= 0x80 and unicode.class((try unicode.decode(stem[found.consumed..])).cp) != .separator)
            return null;
    }
    found.consumed += prefixed;
    return found;
}

fn mixed(country: Country, input: []const u8, first: []const u8, deadline: io.Deadline) !?Match {
    if (mixedPattern(country, first)) return .{ .consumed = first.len, .first = first };
    var next = first.len;
    while (next < input.len and std.ascii.isWhitespace(input[next])) : (next += 1) {
        if (next % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
    }
    if (next == first.len) return null;
    const last = input[next..][0..wordLength(input[next..])];
    if (last.len == 0 or first.len + last.len > 9) return null;
    var joined: [9]u8 = undefined;
    @memcpy(joined[0..first.len], first);
    @memcpy(joined[first.len..][0..last.len], last);
    if (!mixedPattern(country, joined[0 .. first.len + last.len])) return null;
    return .{ .consumed = next + last.len, .first = first, .second = last };
}

fn mixedPattern(country: Country, code: []const u8) bool {
    return switch (country) {
        .ca => canadian(code),
        .nl => matchMask(code, "0000aa") and code[0] != '0',
        .gb => british(code),
        else => unreachable,
    };
}

fn british(code: []const u8) bool {
    if (std.mem.eql(u8, code, "gir0aa")) return true;
    if (code.len < 5 or code.len > 7) return false;
    if (!matchMask(code[code.len - 3 ..], "0aa")) return false;
    const outward = code[0 .. code.len - 3];
    return matchMask(outward, "a0") or matchMask(outward, "a00") or matchMask(outward, "a0a") or
        matchMask(outward, "aa0") or matchMask(outward, "aa00") or matchMask(outward, "aa0a");
}

fn canadian(code: []const u8) bool {
    if (!matchMask(code, "a0a0a0") or code[0] == 'w' or code[0] == 'z') return false;
    for ([_]usize{ 0, 2, 4 }) |i| {
        if (std.mem.indexOfScalar(u8, "dfioqu", code[i]) != null) return false;
    }
    return true;
}

fn matchMask(value: []const u8, mask: []const u8) bool {
    if (value.len != mask.len) return false;
    for (value, mask) |byte, key| {
        if (key == '0') {
            if (!std.ascii.isDigit(byte)) return false;
        } else if (!std.ascii.isLower(byte)) return false;
    }
    return true;
}

fn wordLength(input: []const u8) usize {
    var i: usize = 0;
    const limit = @min(input.len, 10);
    while (i < limit and std.ascii.isAlphanumeric(input[i])) : (i += 1) {}
    return i;
}

fn hasText(input: []const u8, deadline: io.Deadline) !bool {
    var offset: usize = 0;
    var next_check: usize = 0;
    while (offset < input.len) {
        if (offset >= next_check) {
            if (deadline.expired()) return error.DeadlineExceeded;
            next_check = offset +| 1024;
        }
        const scalar = try unicode.decode(input[offset..]);
        if (unicode.class(scalar.cp) != .separator) return true;
        offset += scalar.len;
    }
    return false;
}

test "country patterns recognize joined and separated postal codes" {
    const t = std.testing;
    const sw = (try match(.gb, "sw1a 1aa, london", false, .none)).?;
    try t.expectEqualStrings("sw1a", sw.first);
    try t.expectEqualStrings("1aa", sw.second);
    try t.expectEqual(8, sw.consumed);
    try t.expectEqualStrings("k1a0b1", (try match(.ca, "k1a0b1", true, .none)).?.first);
    try t.expectEqualStrings("84101-1234", (try match(.us, "84101-1234", true, .none)).?.first);
    try t.expectEqualStrings("2449", (try match(.lu, "l-2449", true, .none)).?.first);
    try t.expectEqual(null, try match(.de, "12345 west strasse", true, .none));
    try t.expectEqual(null, try match(.ca, "d1a 0b1", false, .none));
    try t.expectEqual(null, try match(.nl, "0123 ab", false, .none));
}
