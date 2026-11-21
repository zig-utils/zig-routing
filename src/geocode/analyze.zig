//! One deterministic text analyzer for indexed names and queries.
const std = @import("std");
const io = @import("../infra/io.zig");
const unicode = @import("unicode.zig");
const lexicon = @import("analysis_lexicon.zig");
const postal = @import("analysis_postcode.zig");
const transliteration = @import("transliteration.zig");
const house = @import("house_number.zig");
const Span = @import("model.zig").Span;
const Allocator = std.mem.Allocator;
const decode = unicode.decode;

pub const Language = lexicon.Language;
pub const Country = postal.Country;
pub const Kind = lexicon.Kind;

pub const Options = struct {
    language: Language = .und,
    country: Country = .unknown,
    prefix_last: bool = false,

    pub fn forIso(iso: []const u8) Options {
        const country = Country.fromIso(iso);
        return .{
            .country = country,
            .language = switch (country) {
                .us, .ca, .gb => .en,
                .de, .at, .ch, .li => .de,
                else => .und,
            },
        };
    }
};

pub const Token = extern struct {
    text: Span,
    latin: Span = .{},
    attr: packed struct(u32) {
        kind: Kind,
        prefix: bool = false,
        reserved: u23 = 0,
    },
};

comptime {
    std.debug.assert(@sizeOf(Token) == 20);
    std.debug.assert(@offsetOf(Token, "text") == 0 and @offsetOf(Token, "latin") == 8 and @offsetOf(Token, "attr") == 16);
}

pub const Result = struct {
    bytes: []const u8,
    tokens: []const Token,

    pub fn text(self: Result, token: Token) []const u8 {
        return token.text.get(self.bytes) catch unreachable;
    }

    pub fn latin(self: Result, token: Token) []const u8 {
        return token.latin.get(self.bytes) catch unreachable;
    }
};

pub const Scratch = struct {
    folded: std.ArrayList(u8) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    tokens: std.ArrayList(Token) = .empty,

    pub fn deinit(self: *Scratch, allocator: Allocator) void {
        self.folded.deinit(allocator);
        self.bytes.deinit(allocator);
        self.tokens.deinit(allocator);
    }

    /// The result borrows scratch storage until the next analysis. All growth
    /// uses the supplied allocator, typically the request arena.
    pub fn analyze(self: *Scratch, allocator: Allocator, input: []const u8, options: Options, deadline: io.Deadline) !Result {
        self.clear();
        errdefer self.clear();
        if (deadline.expired()) return error.DeadlineExceeded;
        try foldInput(&self.folded, allocator, input, deadline);
        const folded = self.folded.items;
        var offset: usize = 0;
        var next_check: usize = 0;
        var seen_name = false;
        while (offset < folded.len) {
            try checkAt(offset, &next_check, deadline);
            const scalar = try decode(folded[offset..]);
            const group = groupOf(scalar.cp);
            if (group == .separator) {
                offset += scalar.len;
                continue;
            }
            if (options.prefix_last and try wordEnd(folded, offset + scalar.len, group, deadline) == folded.len) {
                const kind: Kind = if (scalar.cp >= '0' and scalar.cp <= '9') .house_number else .word;
                try self.emitWord(allocator, folded[offset..], kind, deadline);
                self.tokens.items[self.tokens.items.len - 1].attr.prefix = true;
                break;
            }
            if (scalar.cp < 0x80 and options.country != .unknown) {
                if (try postal.match(options.country, folded[offset..], self.tokens.items.len == 0, deadline)) |code| {
                    const start = self.bytes.items.len;
                    try self.bytes.appendSlice(allocator, code.first);
                    try self.bytes.appendSlice(allocator, code.second);
                    try self.push(allocator, start, .postcode);
                    offset += code.consumed;
                    continue;
                }
            }
            const end = try wordEnd(folded, offset + scalar.len, group, deadline);
            if (scalar.cp <= '9' and scalar.cp >= '0') {
                if (try numberAt(folded, offset, end, deadline)) |number| {
                    try self.emitNumber(allocator, number.label);
                    offset = number.end;
                    continue;
                }
            }
            const word = folded[offset..end];
            const initial_saint = options.language == .en and !seen_name and std.mem.eql(u8, word, "st") and
                try nextName(folded[end..], deadline);
            const expansion = lexicon.expand(options.language, word, initial_saint);
            if (expansion) |mapped| {
                try self.emitWord(allocator, mapped.text, mapped.kind, deadline);
                seen_name = seen_name or mapped.kind != .stop_word;
            } else if (lexicon.compoundStreetType(options.language, word)) |compound| {
                try self.emitWord(allocator, compound.stem, .word, deadline);
                try self.emitWord(allocator, compound.suffix.text, compound.suffix.kind, deadline);
                seen_name = true;
            } else {
                try self.emitWord(allocator, word, .word, deadline);
                seen_name = true;
            }
            offset = end;
        }
        return .{ .bytes = self.bytes.items, .tokens = self.tokens.items };
    }

    fn clear(self: *Scratch) void {
        self.folded.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.tokens.clearRetainingCapacity();
    }

    fn emitWord(self: *Scratch, allocator: Allocator, word: []const u8, kind: Kind, deadline: io.Deadline) !void {
        const start = self.bytes.items.len;
        var non_ascii = false;
        var check: usize = 0;
        var parts = std.mem.splitScalar(u8, word, '\'');
        while (parts.next()) |part| {
            try checkAt(parts.index orelse word.len, &check, deadline);
            try self.bytes.appendSlice(allocator, part);
            non_ascii = non_ascii or !try asciiWord(part, deadline);
        }
        const text = try Span.init(start, self.bytes.items.len - start);
        const alias = if (non_ascii) try self.latinAlias(allocator, word, deadline) else Span{};
        try self.tokens.append(allocator, .{ .text = text, .latin = alias, .attr = .{ .kind = kind } });
    }

    fn latinAlias(self: *Scratch, allocator: Allocator, word: []const u8, deadline: io.Deadline) !Span {
        const start = self.bytes.items.len;
        var offset: usize = 0;
        var next_check: usize = 0;
        while (offset < word.len) {
            try checkAt(offset, &next_check, deadline);
            const scalar = try decode(word[offset..]);
            if (scalar.cp < 0x80) {
                if (scalar.cp != '\'') try self.bytes.append(allocator, @intCast(scalar.cp));
            } else if (transliteration.latin(scalar.cp)) |mapped| {
                try self.bytes.appendSlice(allocator, mapped);
            } else {
                self.bytes.shrinkRetainingCapacity(start);
                return .{};
            }
            offset += scalar.len;
        }
        return if (self.bytes.items.len == start) .{} else Span.init(start, self.bytes.items.len - start);
    }

    fn emitNumber(self: *Scratch, allocator: Allocator, label: house.Label) !void {
        var buffer: [160]u8 = undefined;
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(allocator, try numberText(&buffer, label.first));
        if (label.last) |last| {
            try self.bytes.append(allocator, '-');
            try self.bytes.appendSlice(allocator, try numberText(&buffer, last));
        }
        try self.push(allocator, start, .house_number);
    }

    fn push(self: *Scratch, allocator: Allocator, start: usize, kind: Kind) !void {
        try self.tokens.append(allocator, .{
            .text = try Span.init(start, self.bytes.items.len - start),
            .attr = .{ .kind = kind },
        });
    }
};

fn foldInput(output: *std.ArrayList(u8), allocator: Allocator, input: []const u8, deadline: io.Deadline) !void {
    try output.ensureUnusedCapacity(allocator, input.len);
    var offset: usize = 0;
    var next_check: usize = 0;
    while (offset < input.len) {
        try checkAt(offset, &next_check, deadline);
        if (input[offset] < 0x80) {
            var end = offset + 1;
            while (end < @min(input.len, next_check) and input[end] < 0x80) : (end += 1) {}
            const target = try output.addManyAsSlice(allocator, end - offset);
            _ = std.ascii.lowerString(target, input[offset..end]);
            offset = end;
            continue;
        }
        const scalar = try decode(input[offset..]);
        offset += scalar.len;
        if (unicode.fold(scalar.cp)) |folded| {
            if (isFraction(scalar.cp) and output.items.len != 0 and std.ascii.isDigit(output.items[output.items.len - 1]))
                try output.append(allocator, ' ');
            if (isAscii(folded)) {
                try output.appendSlice(allocator, folded);
            } else {
                var cursor: usize = 0;
                while (cursor < folded.len) {
                    const replacement = try decode(folded[cursor..]);
                    try appendScalar(output, allocator, replacement.cp);
                    cursor += replacement.len;
                }
            }
        } else {
            var buffer: [3]u21 = undefined;
            const hangul = unicode.decomposeHangul(scalar.cp, &buffer);
            if (hangul.len != 0) {
                for (hangul) |jamo| try appendScalar(output, allocator, jamo);
            } else {
                try appendScalar(output, allocator, scalar.cp);
            }
        }
    }
}

fn appendScalar(output: *std.ArrayList(u8), allocator: Allocator, cp: u21) !void {
    const canonical: u21 = switch (cp) {
        0x02bc, 0x2018, 0x2019, 0x201b => '\'',
        0x2010...0x2015, 0x2212 => '-',
        0x2044, 0x2215 => '/',
        0x0085, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => ' ',
        else => cp,
    };
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(canonical, &bytes) catch return error.InvalidUtf8;
    try output.appendSlice(allocator, bytes[0..len]);
}

fn isFraction(cp: u21) bool {
    return cp >= 0x00bc and cp <= 0x00be or cp >= 0x2150 and cp <= 0x215f;
}

const Group = enum { separator, word, han, kana, hangul };

inline fn groupOf(cp: u21) Group {
    if (cp < 0x80) return if (std.ascii.isAlphanumeric(@intCast(cp))) .word else .separator;
    return switch (unicode.class(cp)) {
        .separator => .separator,
        .word, .greek, .cyrillic => .word,
        .han => .han,
        .kana => .kana,
        .hangul => .hangul,
    };
}

fn wordEnd(input: []const u8, first_end: usize, group: Group, deadline: io.Deadline) !usize {
    if (group == .han) return first_end;
    var end = first_end;
    var next_check = first_end +| 1024;
    while (end < input.len) {
        try checkAt(end, &next_check, deadline);
        if (group == .word and input[end] == '\'' and end + 1 < input.len) {
            const next = try decode(input[end + 1 ..]);
            if (groupOf(next.cp) == .word) {
                end += 1 + next.len;
                continue;
            }
        }
        const scalar = try decode(input[end..]);
        if (groupOf(scalar.cp) != group) break;
        end += scalar.len;
    }
    return end;
}

fn nextName(input: []const u8, deadline: io.Deadline) !bool {
    var i: usize = 0;
    while (i < input.len and (std.ascii.isWhitespace(input[i]) or input[i] == '.')) : (i += 1) {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
    }
    if (i == input.len or std.ascii.isDigit(input[i])) return false;
    return groupOf((try decode(input[i..])).cp) != .separator;
}

const Number = struct { end: usize, label: house.Label };

fn numberAt(input: []const u8, start: usize, end: usize, deadline: io.Deadline) !?Number {
    const basic = house.parse(input[start..end], "") catch return null;
    const suffix = basic.first.letters;
    if (std.mem.eql(u8, suffix, "st") or std.mem.eql(u8, suffix, "nd") or
        std.mem.eql(u8, suffix, "rd") or std.mem.eql(u8, suffix, "th"))
        return null;
    if (end < input.len and input[end] == '-') {
        const next = asciiEnd(input, end + 1, false);
        const length = next - (end + 1);
        if (length != 0 and (std.ascii.isDigit(input[end + 1]) or length == 1)) {
            const parsed: ?house.Label = house.parse(input[start..next], "") catch null;
            if (parsed) |label| return .{ .end = next, .label = label };
        }
    }
    if (end < input.len and std.ascii.isWhitespace(input[end]) and suffix.len == 0) {
        const numerator_start = try skipSpace(input, end, deadline);
        const slash = try skipSpace(input, asciiEnd(input, numerator_start, true), deadline);
        if (slash < input.len and input[slash] == '/') {
            const denominator_start = try skipSpace(input, slash + 1, deadline);
            const next = asciiEnd(input, denominator_start, true);
            if (next > denominator_start and (next == input.len or !std.ascii.isAlphanumeric(input[next]))) {
                const parsed: ?house.Label = house.parse(input[start..next], "") catch null;
                if (parsed) |label| return .{ .end = next, .label = label };
            }
        }
    }
    return .{ .end = end, .label = basic };
}

fn asciiEnd(input: []const u8, first: usize, digits_only: bool) usize {
    var end = first;
    const limit = @min(input.len, first +| 128);
    while (end < limit and (if (digits_only) std.ascii.isDigit(input[end]) else std.ascii.isAlphanumeric(input[end]))) : (end += 1) {}
    return end;
}

fn skipSpace(input: []const u8, first: usize, deadline: io.Deadline) !usize {
    var end = first;
    var next_check = first +| 1024;
    while (end < input.len and std.ascii.isWhitespace(input[end])) : (end += 1)
        try checkAt(end, &next_check, deadline);
    return end;
}

fn numberText(output: []u8, key: house.Key) ![]const u8 {
    if (key.fraction.numerator != 0)
        return std.fmt.bufPrint(output, "{d} {d}/{d}", .{ key.number, key.fraction.numerator, key.fraction.denominator });
    return std.fmt.bufPrint(output, "{d}{s}", .{ key.number, key.letters });
}

fn isAscii(input: []const u8) bool {
    for (input) |byte| if (byte >= 0x80) return false;
    return true;
}

fn asciiWord(input: []const u8, deadline: io.Deadline) !bool {
    var offset: usize = 0;
    while (offset < input.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const end = @min(input.len, offset +| 1024);
        if (!isAscii(input[offset..end])) return false;
        offset = end;
    }
    return true;
}

inline fn checkAt(offset: usize, next: *usize, deadline: io.Deadline) !void {
    if (offset < next.*) return;
    if (deadline.expired()) return error.DeadlineExceeded;
    next.* = offset +| 1024;
}

test "word classes expansions and aliases share one result" {
    const t = std.testing;
    const a = t.allocator;
    var scratch: Scratch = .{};
    defer scratch.deinit(a);
    const en = try scratch.analyze(a, "12½ St. John’s Rd, NW 84101-1234", .{ .language = .en, .country = .us }, .none);
    const words = [_][]const u8{ "12 1/2", "saint", "johns", "road", "northwest", "84101-1234" };
    const kinds = [_]Kind{ .house_number, .word, .word, .street_type, .direction, .postcode };
    try t.expectEqual(words.len, en.tokens.len);
    for (en.tokens, words, kinds) |token, word, kind| {
        try t.expectEqualStrings(word, en.text(token));
        try t.expectEqual(kind, token.attr.kind);
    }
    const de = try scratch.analyze(a, "Am Hauptstr. 008B, 10115 Berlin", .{ .language = .de, .country = .de }, .none);
    try t.expectEqualStrings("haupt", de.text(de.tokens[1]));
    try t.expectEqualStrings("strasse", de.text(de.tokens[2]));
    try t.expectEqualStrings("8b", de.text(de.tokens[3]));
    try t.expectEqual(.postcode, de.tokens[4].attr.kind);
    const worlds = try scratch.analyze(a, "Αθήνα Москва 東京タワー 한글", .{}, .none);
    try t.expectEqualStrings("athina", worlds.latin(worlds.tokens[0]));
    try t.expectEqualStrings("moskva", worlds.latin(worlds.tokens[1]));
    try t.expectEqualStrings("東", worlds.text(worlds.tokens[2]));
    try t.expectEqualStrings("京", worlds.text(worlds.tokens[3]));
    try t.expectEqualStrings("タワー", worlds.text(worlds.tokens[4]));
    try t.expectEqualStrings("한글", worlds.text(worlds.tokens[5]));
    try t.expectError(error.InvalidUtf8, scratch.analyze(a, "a\xff", .{}, .none));
    try t.expectError(error.DeadlineExceeded, scratch.analyze(a, "valid", .{}, .fromNow(0)));
}

test "autocomplete preserves an unfinished token and expands completed tokens" {
    const t = std.testing;
    const a = t.allocator;
    var scratch: Scratch = .{};
    defer scratch.deinit(a);
    const opts: Options = .{ .language = .en, .country = .us, .prefix_last = true };
    const partial = try scratch.analyze(a, "12 N Main St", opts, .none);
    try t.expectEqual(4, partial.tokens.len);
    try t.expectEqualStrings("north", partial.text(partial.tokens[1]));
    try t.expectEqualStrings("st", partial.text(partial.tokens[3]));
    try t.expect(partial.tokens[3].attr.prefix);
    const complete = try scratch.analyze(a, "12 N Main St ", opts, .none);
    try t.expectEqualStrings("street", complete.text(complete.tokens[3]));
    try t.expect(!complete.tokens[3].attr.prefix);
    const unicode_prefix = try scratch.analyze(a, "Αθήνα Μό", opts, .none);
    try t.expectEqualStrings("mo", unicode_prefix.latin(unicode_prefix.tokens[1]));
    try t.expect(unicode_prefix.tokens[1].attr.prefix);
}
