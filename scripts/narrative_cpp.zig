//! Read the C++ fixture syntax used by the pinned Valhalla test files.
const std = @import("std");

pub const Token = struct {
    pub const Kind = enum { identifier, literal, punctuation, string };

    kind: Kind,
    text: []const u8,
    start: usize,
    end: usize,

    pub fn is(self: Token, value: []const u8) bool {
        return std.mem.eql(u8, self.text, value);
    }
};

pub const Scanner = struct {
    source: []const u8,
    cursor: usize = 0,

    pub fn next(self: *Scanner) !?Token {
        while (self.cursor < self.source.len) {
            const remaining = self.source[self.cursor..];
            if (std.ascii.isWhitespace(remaining[0])) {
                self.cursor += 1;
            } else if (std.mem.startsWith(u8, remaining, "//")) {
                self.cursor += std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
            } else if (std.mem.startsWith(u8, remaining, "/*")) {
                const end = std.mem.indexOfPos(u8, remaining, 2, "*/") orelse return error.UnterminatedComment;
                self.cursor += end + 2;
            } else break;
        }
        if (self.cursor == self.source.len) return null;

        const start = self.cursor;
        const first = self.source[start];
        self.cursor += 1;
        const kind: Token.Kind = switch (first) {
            'a'...'z', 'A'...'Z', '_' => blk: {
                while (self.cursor < self.source.len and word(self.source[self.cursor])) self.cursor += 1;
                break :blk .identifier;
            },
            '0'...'9' => blk: {
                while (self.cursor < self.source.len and (word(self.source[self.cursor]) or self.source[self.cursor] == '.')) self.cursor += 1;
                break :blk .literal;
            },
            '"', '\'' => blk: {
                while (self.cursor < self.source.len) {
                    const char = self.source[self.cursor];
                    self.cursor += 1;
                    if (char == first) break :blk if (first == '"') .string else .literal;
                    if (char == '\\') {
                        if (self.cursor == self.source.len) return error.UnterminatedString;
                        self.cursor += 1;
                    }
                }
                return error.UnterminatedString;
            },
            else => .punctuation,
        };
        return .{ .kind = kind, .text = self.source[start..self.cursor], .start = start, .end = self.cursor };
    }

    pub fn group(self: *Scanner, opening: Token) ![]const u8 {
        const closing = closingToken(opening) orelse return error.ExpectedGroup;
        var depth: usize = 1;
        while (try self.next()) |token| {
            if (closingToken(token) != null) {
                depth += 1;
            } else if (isClosing(token)) {
                depth -= 1;
                if (depth == 0) {
                    if (!token.is(closing)) return error.UnbalancedGroup;
                    return self.source[opening.end..token.start];
                }
            }
        }
        return error.UnbalancedGroup;
    }
};

fn word(char: u8) bool {
    return char == '_' or std.ascii.isAlphanumeric(char);
}

fn isClosing(token: Token) bool {
    return token.is(")") or token.is("}") or token.is("]");
}

fn closingToken(token: Token) ?[]const u8 {
    if (token.is("(")) return ")";
    if (token.is("{")) return "}";
    if (token.is("[")) return "]";
    return null;
}

pub const Call = struct { name: []const u8, arguments: []const u8 };

/// Search successive calls to one function or a family of fixture helpers.
pub fn nextCall(scanner: *Scanner, name: []const u8, use_prefix: bool) !?Call {
    while (try scanner.next()) |token| {
        if (token.kind != .identifier) continue;
        const matches = if (use_prefix) std.mem.startsWith(u8, token.text, name) else token.is(name);
        if (!matches) continue;
        var lookahead = scanner.*;
        const opening = (try lookahead.next()) orelse return null;
        if (!opening.is("(")) continue;
        const argument_text = try lookahead.group(opening);
        scanner.* = lookahead;
        return .{ .name = token.text, .arguments = argument_text };
    }
    return null;
}

pub fn definition(source: []const u8, name: []const u8) ![]const u8 {
    var scanner: Scanner = .{ .source = source };
    while (try nextCall(&scanner, name, false)) |_| {
        var lookahead = scanner;
        const opening = (try lookahead.next()) orelse break;
        if (opening.is("{")) return lookahead.group(opening);
    }
    return error.MissingDefinition;
}

pub fn arguments(arena: std.mem.Allocator, source: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var scanner: Scanner = .{ .source = source };
    var start: ?usize = null;
    var end: usize = 0;
    while (try scanner.next()) |token| {
        if (token.is(",")) {
            const first = start orelse return error.MissingArgument;
            try result.append(arena, source[first..end]);
            start = null;
            continue;
        }
        if (start == null) start = token.start;
        if (closingToken(token) != null) _ = try scanner.group(token);
        end = scanner.cursor;
    }
    if (start) |first| try result.append(arena, source[first..end]);
    return result.toOwnedSlice(arena);
}

pub fn callArguments(arena: std.mem.Allocator, body: []const u8, name: []const u8) ![][]const u8 {
    var scanner: Scanner = .{ .source = body };
    const call = (try nextCall(&scanner, name, false)) orelse return error.MissingCall;
    return arguments(arena, call.arguments);
}

/// A fixture expression may concatenate adjacent C++ string literals.
pub fn strings(arena: std.mem.Allocator, expression: []const u8) ![]const u8 {
    var scanner: Scanner = .{ .source = expression };
    var result: std.ArrayList(u8) = .empty;
    while (try scanner.next()) |token| {
        if (token.kind != .string) continue;
        const bytes = try std.zig.string_literal.parseAlloc(arena, token.text);
        try result.appendSlice(arena, bytes);
    }
    return result.toOwnedSlice(arena);
}

pub fn stringValue(arena: std.mem.Allocator, source: []const u8, name: []const u8) ![]const u8 {
    var scanner: Scanner = .{ .source = source };
    while (try scanner.next()) |token| {
        if (!token.is(name)) continue;
        const equals = (try scanner.next()) orelse return error.MissingValue;
        if (!equals.is("=")) continue;
        const literal = (try scanner.next()) orelse return error.MissingValue;
        if (literal.kind != .string) return error.ExpectedString;
        return std.zig.string_literal.parseAlloc(arena, literal.text);
    }
    return error.MissingValue;
}

pub fn tail(expression: []const u8, delimiter: []const u8) []const u8 {
    const start = std.mem.lastIndexOf(u8, expression, delimiter) orelse return expression;
    return expression[start + delimiter.len ..];
}

test "fixture scanner preserves nested call and quoted comment text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\void Example() {
        \\  // Expected("wrong")
        \\  Expected(Build({{"City/*", false}}, 1), "Exit (" "North).");
        \\}
    ;
    const body = try definition(source, "Example");
    const args = try callArguments(a, body, "Expected");
    try std.testing.expectEqual(2, args.len);
    try std.testing.expectEqualStrings("Build({{\"City/*\", false}}, 1)", args[0]);
    try std.testing.expectEqualStrings("Exit (North).", try strings(a, args[1]));
}
