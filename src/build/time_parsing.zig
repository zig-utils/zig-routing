// Ported from src/mjolnir/timeparsing.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const TimeDomain = @import("../graph/time_domain.zig").TimeDomain;
const Allocator = std.mem.Allocator;

const Kind = enum {
    month,
    weekday,
    number,
    year,
    time,
    nth,
    dash,
    comma,
    separator,
    plus,
    always,
    holiday,
    sun_event,
    off,
    filler,
    unknown,
    end,
};

const Token = struct { kind: Kind, value: i32 = 0 };

const words = std.StaticStringMap(Token).initComptime([_]struct { []const u8, Token }{
    .{ "jan", .{ .kind = .month, .value = 1 } },        .{ "january", .{ .kind = .month, .value = 1 } },
    .{ "feb", .{ .kind = .month, .value = 2 } },        .{ "february", .{ .kind = .month, .value = 2 } },
    .{ "mar", .{ .kind = .month, .value = 3 } },        .{ "march", .{ .kind = .month, .value = 3 } },
    .{ "apr", .{ .kind = .month, .value = 4 } },        .{ "april", .{ .kind = .month, .value = 4 } },
    .{ "may", .{ .kind = .month, .value = 5 } },        .{ "jun", .{ .kind = .month, .value = 6 } },
    .{ "june", .{ .kind = .month, .value = 6 } },       .{ "jul", .{ .kind = .month, .value = 7 } },
    .{ "july", .{ .kind = .month, .value = 7 } },       .{ "aug", .{ .kind = .month, .value = 8 } },
    .{ "august", .{ .kind = .month, .value = 8 } },     .{ "sep", .{ .kind = .month, .value = 9 } },
    .{ "sept", .{ .kind = .month, .value = 9 } },       .{ "september", .{ .kind = .month, .value = 9 } },
    .{ "oct", .{ .kind = .month, .value = 10 } },       .{ "october", .{ .kind = .month, .value = 10 } },
    .{ "nov", .{ .kind = .month, .value = 11 } },       .{ "november", .{ .kind = .month, .value = 11 } },
    .{ "dec", .{ .kind = .month, .value = 12 } },       .{ "december", .{ .kind = .month, .value = 12 } },
    .{ "su", .{ .kind = .weekday, .value = 1 } },       .{ "sun", .{ .kind = .weekday, .value = 1 } },
    .{ "sunday", .{ .kind = .weekday, .value = 1 } },   .{ "mo", .{ .kind = .weekday, .value = 2 } },
    .{ "mon", .{ .kind = .weekday, .value = 2 } },      .{ "monday", .{ .kind = .weekday, .value = 2 } },
    .{ "tu", .{ .kind = .weekday, .value = 3 } },       .{ "tue", .{ .kind = .weekday, .value = 3 } },
    .{ "tues", .{ .kind = .weekday, .value = 3 } },     .{ "tuesday", .{ .kind = .weekday, .value = 3 } },
    .{ "we", .{ .kind = .weekday, .value = 4 } },       .{ "wed", .{ .kind = .weekday, .value = 4 } },
    .{ "weds", .{ .kind = .weekday, .value = 4 } },     .{ "wednesday", .{ .kind = .weekday, .value = 4 } },
    .{ "th", .{ .kind = .weekday, .value = 5 } },       .{ "thu", .{ .kind = .weekday, .value = 5 } },
    .{ "thur", .{ .kind = .weekday, .value = 5 } },     .{ "thurs", .{ .kind = .weekday, .value = 5 } },
    .{ "thursday", .{ .kind = .weekday, .value = 5 } }, .{ "fr", .{ .kind = .weekday, .value = 6 } },
    .{ "fri", .{ .kind = .weekday, .value = 6 } },      .{ "friday", .{ .kind = .weekday, .value = 6 } },
    .{ "sa", .{ .kind = .weekday, .value = 7 } },       .{ "sat", .{ .kind = .weekday, .value = 7 } },
    .{ "saturday", .{ .kind = .weekday, .value = 7 } }, .{ "ph", .{ .kind = .holiday } },
    .{ "sh", .{ .kind = .holiday } },                   .{ "off", .{ .kind = .off } },
    .{ "closed", .{ .kind = .off } },                   .{ "sunrise", .{ .kind = .sun_event } },
    .{ "sunset", .{ .kind = .sun_event } },             .{ "dawn", .{ .kind = .sun_event } },
    .{ "dusk", .{ .kind = .sun_event } },               .{ "and", .{ .kind = .filler } },
});

const Lexer = struct {
    text: []const u8,
    deadline: io.Deadline,
    at: usize = 0,

    noinline fn next(self: *Lexer) !?Token {
        const text = self.text;
        while (self.at < text.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const start = self.at;
            const char = text[start];
            self.at += 1;
            switch (char) {
                ' ', '\t', '(', ')', ':' => continue,
                '-' => return .{ .kind = .dash },
                ',' => return .{ .kind = .comma },
                ';', '|' => return .{ .kind = .separator },
                '+' => return .{ .kind = .plus },
                '"' => try self.skipQuote("\""),
                '&' => {
                    if (!std.mem.startsWith(u8, text[start..], "&quot;")) return .{ .kind = .unknown };
                    self.at = start + "&quot;".len;
                    try self.skipQuote("&quot;");
                },
                '[' => return self.nth(),
                '0'...'9' => {
                    self.at = start;
                    return self.number();
                },
                'A'...'Z', 'a'...'z' => {
                    while (self.at < text.len and std.ascii.isAlphabetic(text[self.at])) : (self.at += 1) {
                        try check(self.deadline, self.at);
                    }
                    const word = text[start..self.at];
                    var folded: [9]u8 = undefined;
                    if (word.len > folded.len) return .{ .kind = .unknown };
                    const token = words.get(std.ascii.lowerString(&folded, word)) orelse return .{ .kind = .unknown };
                    if (token.kind == .filler) continue;
                    return token;
                },
                else => {
                    const bytes = text[start..];
                    if (std.mem.startsWith(u8, bytes, "\xe2\x80\x93") or std.mem.startsWith(u8, bytes, "\xe2\x80\x94") or
                        std.mem.startsWith(u8, bytes, "\xe2\x88\x92"))
                    {
                        self.at = start + 3;
                        return .{ .kind = .dash };
                    }
                    if (std.mem.startsWith(u8, bytes, "\xc2\xa0")) {
                        self.at = start + 2;
                        continue;
                    }
                    return .{ .kind = .unknown };
                },
            }
        }
        return null;
    }

    fn skipQuote(self: *Lexer, delimiter: []const u8) !void {
        while (self.at < self.text.len) : (self.at += 1) {
            try check(self.deadline, self.at);
            if (std.mem.startsWith(u8, self.text[self.at..], delimiter)) {
                self.at += delimiter.len;
                return;
            }
        }
    }

    fn nth(self: *Lexer) Token {
        const start = self.at;
        const minus = self.at < self.text.len and self.text[self.at] == '-';
        self.at += @intFromBool(minus);
        const digits_at = self.at;
        const value = self.digits(2);
        if (self.at != digits_at and self.at < self.text.len and self.text[self.at] == ']') {
            self.at += 1;
            return .{ .kind = .nth, .value = if (minus) -value else value };
        }
        // Unrecognized bracket lists are skipped as a unit if they are short.
        const prefix = self.text[start..][0..@min(8, self.text.len - start)];
        self.at = if (std.mem.indexOfScalar(u8, prefix, ']')) |close| start + close + 1 else start;
        return .{ .kind = .unknown };
    }

    fn digits(self: *Lexer, max: usize) i32 {
        const end = self.at + @min(max, self.text.len - self.at);
        var value: i32 = 0;
        while (self.at < end and std.ascii.isDigit(self.text[self.at])) : (self.at += 1) {
            value = value * 10 + (self.text[self.at] - '0');
        }
        return value;
    }

    fn number(self: *Lexer) Token {
        const start = self.at;
        var value = self.digits(6);
        const width = self.at - start;
        const tail = self.text[self.at..];
        if (tail.len >= 2 and tail[0] == ':' and std.ascii.isDigit(tail[1])) {
            self.at += 1;
            const minute = self.digits(2);
            const suffix = self.text[self.at..];
            if (suffix.len >= 2 and (std.ascii.toLower(suffix[0]) == 'a' or std.ascii.toLower(suffix[0]) == 'p') and std.ascii.toLower(suffix[1]) == 'm') {
                if (value >= 1 and value <= 12) value = @mod(value, 12) + (if (std.ascii.toLower(suffix[0]) == 'p') @as(i32, 12) else 0);
                self.at += 2;
            }
            if (value > 48 or minute > 59) return .{ .kind = .unknown };
            return .{ .kind = .time, .value = value * 60 + minute };
        }
        if (value == 24 and std.mem.startsWith(u8, tail, "/7") and (tail.len == 2 or !std.ascii.isDigit(tail[2]))) {
            self.at += 2;
            return .{ .kind = .always };
        }
        return .{ .kind = if (width == 4 and value >= 1900 and value < 3000) .year else .number, .value = value };
    }
};

const DatePoint = struct { month: u4 = 0, day: u5 = 0, weekday: u3 = 0, week: u3 = 0, year: bool = false };
const DateRange = struct { begin: DatePoint = .{}, end: DatePoint = .{} };
const TimeRange = struct { begin: u16, end: u16 };
const Weekdays = struct { mask: u7 = 0, week: u3 = 0 };

pub const Parser = struct {
    a: Allocator,
    deadline: io.Deadline,
    tokens: std.ArrayList(Token) = .empty,
    dates: std.ArrayList(DateRange) = .empty,
    times: std.ArrayList(TimeRange) = .empty,

    pub fn deinit(self: *Parser) void {
        self.tokens.deinit(self.a);
        self.dates.deinit(self.a);
        self.times.deinit(self.a);
    }

    /// Append one packed domain for each representable date and time pair.
    /// Invalid and unrepresentable rules are skipped at the next separator.
    pub noinline fn parse(self: *Parser, text: []const u8, output: *std.ArrayList(u64)) !void {
        self.tokens.clearRetainingCapacity();
        var lex: Lexer = .{ .text = text, .deadline = self.deadline };
        while (try lex.next()) |token| try self.tokens.append(self.a, token);
        var cursor: Cursor = .{ .tokens = self.tokens.items, .deadline = self.deadline };
        while (cursor.kind(0) != .end) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (cursor.ruleEnd()) {
                cursor.at += 1;
                continue;
            }
            const start = output.items.len;
            self.parseRule(&cursor, output) catch |err| switch (err) {
                error.InvalidRule, error.UnsupportedRule => {
                    output.shrinkRetainingCapacity(start);
                    try cursor.skipRule();
                },
                else => return err,
            };
        }
    }

    fn parseRule(self: *Parser, cursor: *Cursor, output: *std.ArrayList(u64)) !void {
        self.dates.clearRetainingCapacity();
        self.times.clearRetainingCapacity();
        if (cursor.kind(0) == .holiday and !(cursor.kind(1) == .comma and cursor.kind(2) == .weekday)) return cursor.skipRule();
        if (cursor.kind(0) == .sun_event) return error.UnsupportedRule;
        var weekdays: Weekdays = .{};
        while (true) {
            try check(self.deadline, cursor.at);
            if (cursor.startsDates(0)) {
                try self.parseDates(cursor);
            } else if (cursor.kind(0) == .weekday) {
                try cursor.parseWeekdays(&weekdays);
            } else if (cursor.kind(0) == .comma and (cursor.kind(1) == .time or cursor.ignorable(1) or
                (cursor.kind(1) == .weekday and weekdays.mask == 0) or
                (cursor.startsDates(1) and self.dates.items.len == 0)))
            {
                cursor.at += 1;
            } else if (cursor.ignorable(0)) {
                cursor.at += 1;
            } else break;
        }
        if (cursor.kind(0) == .always) {
            cursor.at += 1;
            if (self.dates.items.len == 0 and weekdays.mask == 0) weekdays.mask = 127;
        }
        if (cursor.kind(0) == .time) try self.parseTimes(cursor);
        while (!try cursor.startsAnotherRule()) {
            if (cursor.kind(0) == .weekday and weekdays.mask == 0) {
                try cursor.parseWeekdays(&weekdays);
            } else if (cursor.startsDates(0) and self.dates.items.len == 0) {
                try self.parseDates(cursor);
            } else break;
        }
        if (cursor.kind(0) == .off) return error.UnsupportedRule;
        if (self.dates.items.len == 0 and self.times.items.len == 0 and weekdays.mask == 0) return error.InvalidRule;
        if (!cursor.ruleEnd()) {
            if (self.times.items.len == 0) return error.InvalidRule;
            switch (cursor.kind(0)) {
                .weekday, .month, .time => {},
                else => try cursor.skipRule(),
            }
        }
        const dates = if (self.dates.items.len != 0) self.dates.items else &[_]DateRange{.{}};
        for (dates, 0..) |date, i| {
            try check(self.deadline, i);
            try self.emit(weekdays, date, output);
        }
    }

    fn parseDates(self: *Parser, cursor: *Cursor) !void {
        while (true) {
            try check(self.deadline, cursor.at);
            try self.dates.append(self.a, try cursor.dateRange());
            if (cursor.kind(0) != .comma or !cursor.startsDates(1)) return;
            cursor.at += 1;
        }
    }

    noinline fn parseTimes(self: *Parser, cursor: *Cursor) !void {
        const minutes_per_day = 24 * 60;
        while (true) {
            try check(self.deadline, cursor.at);
            const begin = cursor.eat();
            const end = switch (cursor.kind(0)) {
                .dash => end: {
                    cursor.at += 1;
                    if (cursor.kind(0) == .sun_event) return error.UnsupportedRule;
                    if (cursor.kind(0) != .time) return error.InvalidRule;
                    break :end cursor.eat();
                },
                .plus => end: {
                    cursor.at += 1;
                    break :end minutes_per_day;
                },
                else => return error.InvalidRule,
            };
            if (end - begin > minutes_per_day) return error.UnsupportedRule;
            try self.times.append(self.a, .{ .begin = @intCast(@mod(begin, minutes_per_day)), .end = @intCast(@mod(end, minutes_per_day)) });
            if (cursor.kind(0) == .time) continue;
            if (cursor.kind(0) != .comma or cursor.kind(1) != .time) return;
            cursor.at += 1;
        }
    }

    noinline fn emit(self: *Parser, weekdays: Weekdays, date: DateRange, output: *std.ArrayList(u64)) !void {
        const nth_date = date.begin.weekday != 0 or date.end.weekday != 0;
        var domain: TimeDomain = .{
            .nth_weekday = nth_date or weekdays.week != 0,
            .dow = if (nth_date and weekdays.mask == 0) 127 else weekdays.mask,
            .begin_month = date.begin.month,
            .end_month = date.end.month,
            .begin_day = if (date.begin.weekday != 0) date.begin.weekday else date.begin.day,
            .end_day = if (date.end.weekday != 0) date.end.weekday else date.end.day,
            .begin_week = if (nth_date) date.begin.week else weekdays.week,
            .end_week = if (nth_date) date.end.week else 0,
        };
        if (!domain.valid()) return error.InvalidRule;
        if (self.times.items.len == 0) return output.append(self.a, @bitCast(domain));
        for (self.times.items, 0..) |time, i| {
            try check(self.deadline, i);
            domain.begin_hour = @intCast(time.begin / 60);
            domain.begin_minute = @intCast(time.begin % 60);
            domain.end_hour = @intCast(time.end / 60);
            domain.end_minute = @intCast(time.end % 60);
            try output.append(self.a, @bitCast(domain));
        }
    }
};

const Cursor = struct {
    tokens: []const Token,
    deadline: io.Deadline,
    at: usize = 0,

    fn kind(self: Cursor, ahead: usize) Kind {
        return if (ahead < self.tokens.len - self.at) self.tokens[self.at + ahead].kind else .end;
    }

    fn eat(self: *Cursor) i32 {
        const value = self.tokens[self.at].value;
        self.at += 1;
        return value;
    }

    fn ruleEnd(self: Cursor) bool {
        return switch (self.kind(0)) {
            .comma, .separator, .end => true,
            else => false,
        };
    }

    fn skipRule(self: *Cursor) !void {
        while (self.kind(0) != .separator and self.kind(0) != .end) : (self.at += 1) try check(self.deadline, self.at);
    }

    fn startsDates(self: Cursor, ahead: usize) bool {
        const first = self.kind(ahead);
        return first == .month or ((first == .year or first == .number) and self.kind(ahead + 1) == .month);
    }

    fn startsAnotherRule(self: Cursor) !bool {
        var ahead: usize = 0;
        while (true) : (ahead += 1) {
            try check(self.deadline, ahead);
            switch (self.kind(ahead)) {
                .weekday, .month, .number, .year, .nth, .holiday, .comma, .dash => {},
                .time, .always, .off => return true,
                else => return false,
            }
        }
    }

    fn ignorable(self: Cursor, ahead: usize) bool {
        return switch (self.kind(ahead)) {
            .unknown, .number, .holiday => true,
            else => false,
        };
    }

    fn day(self: *Cursor) !u5 {
        const value = self.eat();
        if (value < 1 or value > 31) return error.InvalidRule;
        return @intCast(value);
    }

    fn datePoint(self: *Cursor, month_expected: bool) !DatePoint {
        var point: DatePoint = .{};
        if (month_expected) {
            if (self.kind(0) == .year) {
                self.at += 1;
                point.year = true;
            }
            if (self.kind(0) == .number and self.kind(1) == .month) point.day = try self.day();
            if (self.kind(0) != .month) return error.InvalidRule;
            point.month = @intCast(self.eat());
            if (point.day != 0) return point;
        }
        if (self.kind(0) == .number) {
            point.day = try self.day();
            if (self.kind(0) == .year) {
                self.at += 1;
                point.year = true;
            }
        } else if (self.kind(0) == .weekday and self.kind(1) == .nth) {
            point.weekday = @intCast(self.eat());
            point.week = try week(self.eat());
        }
        return point;
    }

    fn dateRange(self: *Cursor) !DateRange {
        const begin = try self.datePoint(true);
        var end: DatePoint = .{ .month = begin.month, .day = begin.day, .week = begin.week };
        if (self.kind(0) == .dash) {
            self.at += 1;
            if (self.startsDates(0)) {
                end = try self.datePoint(true);
            } else if (self.kind(0) == .number and begin.day != 0) {
                end = try self.datePoint(false);
                end.month = begin.month;
            } else return error.InvalidRule;
        }
        if (begin.year and end.year) return error.UnsupportedRule;
        return .{ .begin = begin, .end = end };
    }

    fn parseWeekdays(self: *Cursor, weekdays: *Weekdays) !void {
        while (true) {
            try check(self.deadline, self.at);
            const first = self.eat();
            weekdays.mask |= weekdayMask(first);
            switch (self.kind(0)) {
                .nth => weekdays.week = try week(self.eat()),
                .dash => {
                    self.at += 1;
                    if (self.kind(0) != .weekday) return error.InvalidRule;
                    const last = self.eat();
                    var current = first;
                    while (current != last) {
                        current = @mod(current, 7) + 1;
                        weekdays.mask |= weekdayMask(current);
                    }
                },
                else => {},
            }
            while (self.kind(0) == .comma and self.kind(1) == .holiday) : (self.at += 2) try check(self.deadline, self.at);
            if (self.kind(0) != .comma or self.kind(1) != .weekday) return;
            self.at += 1;
        }
    }
};

fn week(value: i32) !u3 {
    if (value == -1) return 5;
    if (value < 1 or value > 5) return error.UnsupportedRule;
    return @intCast(value);
}

fn weekdayMask(day: i32) u7 {
    return @as(u7, 1) << @intCast(day - 1);
}

fn check(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

// Ported from test/timeparsing.cc, with conditions from the pinned extracts.
test "time conditions have the exact Valhalla domain encodings" {
    const t = std.testing;
    var parser: Parser = .{ .a = t.allocator, .deadline = .none };
    defer parser.deinit();
    var domains: std.ArrayList(u64) = .empty;
    defer domains.deinit(t.allocator);
    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/time-parsing.tsv"), '\n');
    while (lines.next()) |line| {
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t').?;
        const condition = line[0..tab];
        var values = std.mem.tokenizeAny(u8, line[tab + 1 ..], ",-");
        domains.clearRetainingCapacity();
        try parser.parse(condition, &domains);
        errdefer std.debug.print("condition = {s}\n", .{condition});
        var count: usize = 0;
        while (values.next()) |expected| : (count += 1) {
            try t.expect(count < domains.items.len);
            try t.expectEqual(try std.fmt.parseInt(u64, expected, 10), domains.items[count]);
        }
        try t.expectEqual(count, domains.items.len);
    }
}
