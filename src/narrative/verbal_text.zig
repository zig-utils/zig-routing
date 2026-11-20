// Ported from src/baldr/verbal_text_formatter*.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");
const markup = @import("markup.zig");

pub const Style = enum {
    generic,
    us,
    colorado,
    texas,

    pub fn forAdmin(country: []const u8, state: []const u8) Style {
        if (!std.mem.eql(u8, country, "US")) return .generic;
        if (std.mem.eql(u8, state, "CO")) return .colorado;
        if (std.mem.eql(u8, state, "TX")) return .texas;
        return .us;
    }
};

/// Scratch is shared by all names and signs in a leg. Successive substitutions
/// alternate buffers so their order matches the upstream formatter.
pub const Formatter = struct {
    buffers: [2]io.Writer.Allocating,
    next: usize = 0,
    markup_formatter: markup.Formatter = .{},
    deadline: io.Deadline = .none,

    pub fn init(arena: std.mem.Allocator, markup_formatter: markup.Formatter, deadline: io.Deadline) Formatter {
        return .{
            .buffers = .{ .init(arena), .init(arena) },
            .markup_formatter = markup_formatter,
            .deadline = deadline,
        };
    }

    pub fn deinit(self: *Formatter) void {
        for (&self.buffers) |*buffer| buffer.deinit();
    }

    pub fn write(self: *Formatter, out: *io.Writer, style: Style, text: []const u8, pronunciation: ?trip.Pronunciation) !void {
        if (try self.markup_formatter.write(out, text, pronunciation, self.deadline)) return;
        try out.writeAll(try self.format(style, text));
    }

    fn format(self: *Formatter, style: Style, text: []const u8) ![]const u8 {
        if (style == .generic) return text;
        var source = text;
        if (style == .texas) {
            source = try self.replace(source, .{ .route = farm_to_market });
            source = try self.replace(source, .{ .route = ranch_to_market });
        }
        source = try self.replace(source, .{ .route = interstate });
        source = try self.replace(source, .{ .route = us_highway });
        source = try self.states(source, style);
        source = try self.firstRoute(source, &county_routes);
        source = try self.roundNumbers(source, 3);
        source = try self.roundNumbers(source, 2);
        source = try self.splitNumbers(source, true);
        return self.replace(source, .leading_oh);
    }

    fn states(self: *Formatter, source: []const u8, style: Style) ![]const u8 {
        if (style == .colorado) {
            const expanded = try self.replace(source, .{ .route = colorado });
            if (expanded.ptr != source.ptr) return expanded;
        }
        return self.firstRoute(source, &state_routes);
    }

    fn firstRoute(self: *Formatter, source: []const u8, rules: []const RouteRule) ![]const u8 {
        for (rules) |rule| {
            const expanded = try self.replace(source, .{ .route = rule });
            if (expanded.ptr != source.ptr) return expanded;
        }
        return source;
    }

    fn roundNumbers(self: *Formatter, source: []const u8, zeroes: usize) ![]const u8 {
        var current = source;
        for ([_]RoundEnding{ .end, .ordinal, .space_or_hyphen, .other }) |ending| {
            current = try self.replace(current, .{ .round = .{ .zeroes = zeroes, .ending = ending } });
        }
        return current;
    }

    fn replace(self: *Formatter, source: []const u8, rule: Replacement) ![]const u8 {
        const buffer = &self.buffers[self.next];
        buffer.clearRetainingCapacity();
        var scan: usize = 0;
        var copied: usize = 0;
        var next_deadline_check: usize = 0;
        while (scan < source.len) {
            if (scan >= next_deadline_check) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                next_deadline_check = scan +| 64;
            }
            const match = rule.match(source, scan) orelse {
                scan += 1;
                continue;
            };
            try buffer.writer.writeAll(source[copied..scan]);
            for (match.parts) |part| try buffer.writer.writeAll(part);
            scan = match.end;
            copied = scan;
        }
        if (copied == 0) return source;
        try buffer.writer.writeAll(source[copied..]);
        self.next ^= 1;
        return buffer.written();
    }

    fn splitNumbers(self: *Formatter, source: []const u8, keep_ordinals: bool) ![]const u8 {
        const buffer = &self.buffers[self.next];
        buffer.clearRetainingCapacity();
        var scan: usize = 0;
        var copied: usize = 0;
        var next_deadline_check: usize = 0;
        while (scan < source.len) {
            if (scan >= next_deadline_check) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                next_deadline_check = scan +| 64;
            }
            if (!std.ascii.isDigit(source[scan])) {
                scan += 1;
                continue;
            }
            const start = scan;
            while (scan < source.len and std.ascii.isDigit(source[scan])) : (scan += 1) {
                if (scan % 64 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            }
            const count = scan - start;
            if (count <= 2 or (keep_ordinals and ordinalSuffix(source[scan..]))) continue;
            const first = if (count % 2 == 0) @as(usize, 2) else 1;
            try buffer.writer.writeAll(source[copied .. start + first]);
            var digits = start + first;
            while (digits < scan) : (digits += 2) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try buffer.writer.writeByte(' ');
                try buffer.writer.writeAll(source[digits..][0..2]);
            }
            copied = scan;
        }
        if (copied == 0) return source;
        try buffer.writer.writeAll(source[copied..]);
        self.next ^= 1;
        return buffer.written();
    }
};

const Match = struct { end: usize, parts: [3][]const u8 };
const Replacement = union(enum) {
    route: RouteRule,
    round: RoundRule,
    leading_oh,

    fn match(self: Replacement, source: []const u8, start: usize) ?Match {
        return switch (self) {
            .route => |route| route.match(source, start),
            .round => |round| round.match(source, start),
            .leading_oh => matchLeadingOh(source, start),
        };
    }
};

const RouteRule = struct {
    code: []const u8,
    spoken: []const u8,
    separator: enum { required, optional, absent } = .required,
    numbers: usize = 3,
    prefix: []const u8 = "",
    letters_before: usize = 0,
    letters_after: usize = 0,
    word_end: bool = false,
    split_code: bool = false,

    fn match(self: RouteRule, source: []const u8, start: usize) ?Match {
        if (start != 0 and word(source[start - 1])) return null;
        var pos = start;
        if (self.split_code) {
            if (std.ascii.toUpper(source[pos]) != self.code[0]) return null;
            pos += 1;
            if (pos < source.len and isSeparator(source[pos])) pos += 1;
            if (pos == source.len or std.ascii.toUpper(source[pos]) != self.code[1]) return null;
            pos += 1;
        } else {
            if (!startsWithIgnoreCase(source[pos..], self.code)) return null;
            pos += self.code.len;
        }
        if (self.separator != .absent) {
            if (pos < source.len and isSeparator(source[pos])) {
                pos += 1;
            } else if (self.separator == .required) return null;
        }
        const capture = pos;
        if (startsWithIgnoreCase(source[pos..], self.prefix)) pos += self.prefix.len;
        pos += leadingLetters(source[pos..], self.letters_before);
        if (self.numbers == 0) {
            if (pos == capture) return null;
        } else {
            var digits: usize = 0;
            for (source[pos..][0..@min(self.numbers, source.len - pos)]) |byte| {
                if (!std.ascii.isDigit(byte)) break;
                digits += 1;
            }
            if (digits == 0) return null;
            pos += digits;
            pos += leadingLetters(source[pos..], self.letters_after);
        }
        if (self.word_end and pos < source.len and word(source[pos])) return null;
        return .{ .end = pos, .parts = .{ self.spoken, source[capture..pos], "" } };
    }
};

fn leadingLetters(source: []const u8, max: usize) usize {
    for (source[0..@min(max, source.len)], 0..) |byte, index| {
        if (!std.ascii.isAlphabetic(byte)) return index;
    }
    return @min(max, source.len);
}

fn isSeparator(byte: u8) bool {
    return byte == ' ' or byte == '-';
}

fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn startsWithIgnoreCase(source: []const u8, prefix: []const u8) bool {
    return source.len >= prefix.len and std.ascii.eqlIgnoreCase(source[0..prefix.len], prefix);
}

fn ordinalSuffix(source: []const u8) bool {
    return startsWithIgnoreCase(source, "st") or startsWithIgnoreCase(source, "nd") or
        startsWithIgnoreCase(source, "rd") or startsWithIgnoreCase(source, "th");
}

fn matchLeadingOh(source: []const u8, start: usize) ?Match {
    const bytes = source[start..];
    if (bytes.len < 3 or bytes[0] != ' ' or bytes[1] != '0' or bytes[2] < '1' or bytes[2] > '9') return null;
    return .{ .end = start + 3, .parts = .{ " o", bytes[2..3], "" } };
}

const RoundEnding = enum { end, ordinal, space_or_hyphen, other };
const RoundRule = struct {
    zeroes: usize,
    ending: RoundEnding,

    fn match(self: RoundRule, source: []const u8, start: usize) ?Match {
        // The regex consumes a non-digit before the number, or matches at
        // the beginning of the original string.
        const first = if (!std.ascii.isDigit(source[start])) start + 1 else if (start == 0) start else return null;
        if (source.len - first <= self.zeroes or source[first] < '1' or source[first] > '9') return null;
        var nonzero: usize = 1;
        if (source[first + 1] >= '1' and source[first + 1] <= '9') nonzero = 2;
        const tail = first + nonzero + self.zeroes;
        if (tail > source.len) return null;
        for (source[first + nonzero .. tail]) |byte| {
            if (byte != '0') return null;
        }
        const base = source[start .. first + nonzero];
        const spoken = if (self.zeroes == 3) " thousand" else " hundred";
        const rest = source[tail..];
        return switch (self.ending) {
            .end => if (rest.len == 0) .{ .end = tail, .parts = .{ base, spoken, "" } } else null,
            .ordinal => if (startsWithIgnoreCase(rest, "th")) .{
                .end = tail + 2,
                .parts = .{ base, if (self.zeroes == 3) " thousandth" else " hundredth", "" },
            } else null,
            .space_or_hyphen => if (rest.len != 0 and isSeparator(rest[0])) .{
                .end = tail + 1,
                .parts = .{ base, if (self.zeroes == 3) " thousand " else " hundred ", "" },
            } else null,
            .other => if (rest.len != 0 and !std.ascii.isDigit(rest[0])) .{
                .end = tail + 1,
                .parts = .{ base, if (self.zeroes == 3) " thousand " else " hundred ", rest[0..1] },
            } else null,
        };
    }
};

const interstate: RouteRule = .{ .code = "I", .spoken = "Interstate ", .prefix = "H" };
const us_highway: RouteRule = .{ .code = "US", .spoken = "U.S. ", .prefix = "Highway " };
const colorado: RouteRule = .{ .code = "CO", .spoken = "Colorado " };
const farm_to_market: RouteRule = .{ .code = "FM", .spoken = "Farm to Market Road ", .separator = .optional, .numbers = 4, .split_code = true };
const ranch_to_market: RouteRule = .{ .code = "RM", .spoken = "Ranch to Market Road ", .separator = .optional, .numbers = 4, .split_code = true };

const county_routes = [_]RouteRule{
    .{ .code = "CR", .spoken = "County Route ", .separator = .absent, .numbers = 4, .letters_after = 2, .word_end = true },
    .{ .code = "CR", .spoken = "County Route ", .numbers = 4, .letters_before = 2, .letters_after = 2, .word_end = true },
    .{ .code = "CR", .spoken = "County Route ", .numbers = 0, .letters_before = 2, .word_end = true },
    .{ .code = "C R", .spoken = "County Route ", .separator = .absent, .numbers = 4, .letters_after = 2, .word_end = true },
    .{ .code = "C R", .spoken = "County Route ", .numbers = 4, .letters_before = 2, .letters_after = 2, .word_end = true },
    .{ .code = "C R", .spoken = "County Route ", .numbers = 0, .letters_before = 2, .word_end = true },
    .{ .code = "CO", .spoken = "County Road ", .separator = .optional, .numbers = 4, .letters_after = 2, .word_end = true },
};

const state_routes = [_]RouteRule{
    .{ .code = "SR", .spoken = "State Route ", .separator = .optional, .numbers = 4 },
    .{ .code = "SH", .spoken = "State Highway ", .separator = .optional, .numbers = 4 },
    .{ .code = "CA", .spoken = "California " },
    .{ .code = "TX", .spoken = "Texas " },
    .{ .code = "FL", .spoken = "Florida ", .prefix = "A" },
    .{ .code = "NY", .spoken = "New York " },
    .{ .code = "IL", .spoken = "Illinois " },
    .{ .code = "PA", .spoken = "Pennsylvania " },
    .{ .code = "OH", .spoken = "Ohio " },
    .{ .code = "GA", .spoken = "Georgia " },
    .{ .code = "NC", .spoken = "North Carolina " },
    .{ .code = "M", .spoken = "Michigan " },
    .{ .code = "NJ", .spoken = "New Jersey " },
    .{ .code = "VA", .spoken = "Virginia " },
    .{ .code = "WA", .spoken = "Washington " },
    .{ .code = "MA", .spoken = "Massachusetts " },
    .{ .code = "AZ", .spoken = "Arizona " },
    .{ .code = "IN", .spoken = "Indiana " },
    .{ .code = "TN", .spoken = "Tennessee " },
    .{ .code = "MO", .spoken = "Missouri " },
    .{ .code = "MO", .spoken = "Missouri ", .numbers = 0, .letters_before = 2, .word_end = true },
    .{ .code = "MD", .spoken = "Maryland " },
    .{ .code = "WI", .spoken = "Wisconsin " },
    .{ .code = "MN", .spoken = "Minnesota " },
    .{ .code = "AL", .spoken = "Alabama " },
    .{ .code = "SC", .spoken = "South Carolina " },
    .{ .code = "LA", .spoken = "Louisiana ", .numbers = 4 },
    .{ .code = "KY", .spoken = "Kentucky ", .numbers = 4 },
    .{ .code = "OR", .spoken = "Oregon " },
    .{ .code = "OK", .spoken = "Oklahoma " },
    .{ .code = "CT", .spoken = "Connecticut " },
    .{ .code = "IA", .spoken = "Iowa " },
    .{ .code = "MS", .spoken = "Mississippi " },
    .{ .code = "AR", .spoken = "Arkansas " },
    .{ .code = "UT", .spoken = "Utah " },
    .{ .code = "KS", .spoken = "Kansas " },
    .{ .code = "NV", .spoken = "Nevada " },
    .{ .code = "NM", .spoken = "New Mexico ", .numbers = 4 },
    .{ .code = "NE", .spoken = "Nebraska " },
    .{ .code = "WV", .spoken = "West Virginia " },
    .{ .code = "ID", .spoken = "Idaho " },
    .{ .code = "HI", .spoken = "Hawaii ", .numbers = 4 },
    .{ .code = "ME", .spoken = "Maine " },
    .{ .code = "NH", .spoken = "New Hampshire " },
    .{ .code = "RI", .spoken = "Rhode Island " },
    .{ .code = "MT", .spoken = "Montana " },
    .{ .code = "DE", .spoken = "Delaware " },
    .{ .code = "SD", .spoken = "South Dakota ", .numbers = 4 },
    .{ .code = "ND", .spoken = "North Dakota ", .numbers = 4 },
    .{ .code = "AK", .spoken = "Alaska " },
    .{ .code = "DC", .spoken = "D C " },
    .{ .code = "VT", .spoken = "Vermont " },
    .{ .code = "WY", .spoken = "Wyoming " },
};

test "Valhalla verbal text formatter snapshots" {
    const snapshot = @import("reference_snapshot.zig");
    var formatter = Formatter.init(std.testing.allocator, .{}, .none);
    defer formatter.deinit();
    for (@import("verbal_text_fixtures.zig").cases) |fixture| {
        const actual = switch (fixture.stage) {
            .full => try formatter.format(fixture.style, fixture.input),
            .interstate => try formatter.replace(fixture.input, .{ .route = interstate }),
            .us_highway => try formatter.replace(fixture.input, .{ .route = us_highway }),
            .states => try formatter.states(fixture.input, fixture.style),
            .counties => try formatter.firstRoute(fixture.input, &county_routes),
            .thousands => try formatter.roundNumbers(fixture.input, 3),
            .hundreds => try formatter.roundNumbers(fixture.input, 2),
            .split => try formatter.splitNumbers(fixture.input, fixture.style != .generic),
            .leading_oh => try formatter.replace(fixture.input, .leading_oh),
            .farm_to_market => try formatter.replace(fixture.input, .{ .route = farm_to_market }),
            .ranch_to_market => try formatter.replace(fixture.input, .{ .route = ranch_to_market }),
        };
        snapshot.match(@tagName(fixture.stage), fixture.expected, actual) catch |err| {
            std.debug.print("{s} {s}: {s}\n", .{ @tagName(fixture.style), @tagName(fixture.stage), fixture.input });
            return err;
        };
    }
}

test "Valhalla phoneme markup replaces route number speech" {
    const testing = std.testing;
    var out = io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    var formatter = Formatter.init(testing.allocator, .{
        .enabled = true,
        .phoneme_format = "<TEXTUAL_STRING> (<span class=<QUOTES>phoneme<QUOTES>>/<VERBAL_STRING>/</span>)",
    }, .none);
    defer formatter.deinit();
    const style = Style.forAdmin("US", "OH");
    try formatter.write(&out.writer, style, "SR 37", .{ .alphabet = .kIpa, .value = "ˈsinjər 37" });
    try testing.expectEqualStrings("SR 37 (<span class=\"phoneme\">/ˈsinjər 37/</span>)", out.written());
    out.clearRetainingCapacity();
    try formatter.write(&out.writer, style, "SR 37", null);
    try testing.expectEqualStrings("State Route 37", out.written());
    out.clearRetainingCapacity();
    formatter.markup_formatter.phoneme_format = "<phoneme alphabet=<QUOTES><PHONETIC_ALPHABET><QUOTES> ph=<QUOTES><VERBAL_STRING><QUOTES>><TEXTUAL_STRING></phoneme>";
    try formatter.write(&out.writer, .generic, "道路", .{ .alphabet = .kNtSampa, .value = "doro:" });
    try testing.expectEqualStrings("<phoneme alphabet='nt-sampa' ph='doro:'>道路</phoneme>", out.written());
    out.clearRetainingCapacity();
    formatter.markup_formatter.enabled = false;
    try formatter.write(&out.writer, style, "SR 37", .{ .alphabet = .kIpa, .value = "ˈsinjər 37" });
    try testing.expectEqualStrings("State Route 37", out.written());
}
