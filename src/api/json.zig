//! JSON request documents with upstream's access semantics.
//!
//! Requests are small next to responses, so they are parsed into a value
//! tree in the request arena (as upstream parses into a rapidjson Document)
//! and read with JSON pointers. `getOptional` reproduces
//! valhalla/baldr/rapidjson_utils.h `get_optional<T>`: numbers convert
//! between types, numeric strings parse as the target type (boost
//! lexical_cast rules: the whole string must parse), and booleans become
//! 0 or 1. Strings are only returned for string values.

const std = @import("std");
pub const Value = std.json.Value;

pub const ParseError = error{InvalidJson} || std.mem.Allocator.Error;

/// Parses a request body. Duplicate keys keep the first occurrence, as a
/// rapidjson pointer lookup would find it.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .duplicate_field_behavior = .use_first }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

/// RFC 6901 pointer lookup ("/a/b/0"; "~1" is "/" and "~0" is "~").
pub fn pointer(root: Value, path: []const u8) ?Value {
    if (path.len == 0) return root;
    if (path[0] != '/') return null;
    var cur = root;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    var buf: [128]u8 = undefined;
    while (it.next()) |raw_token| {
        const token = unescape(raw_token, &buf) orelse return null;
        switch (cur) {
            .object => |o| cur = o.get(token) orelse return null,
            .array => |a| {
                const idx = std.fmt.parseInt(usize, token, 10) catch return null;
                if (idx >= a.items.len) return null;
                cur = a.items[idx];
            },
            else => return null,
        }
    }
    return cur;
}

fn unescape(token: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, token, '~') == null) return token;
    var n: usize = 0;
    var i: usize = 0;
    while (i < token.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (token[i] == '~' and i + 1 < token.len) {
            buf[n] = if (token[i + 1] == '1') '/' else '~';
            i += 1;
        } else buf[n] = token[i];
        n += 1;
    }
    return buf[0..n];
}

/// `rapidjson::get_optional<T>(doc, path)`.
pub fn getOptional(comptime T: type, root: Value, path: []const u8) ?T {
    const v = pointer(root, path) orelse return null;
    return convert(T, v);
}

/// `rapidjson::get<T>(doc, path, default)`.
pub fn get(comptime T: type, root: Value, path: []const u8, default: T) T {
    return getOptional(T, root, path) orelse default;
}

/// Converts one value as upstream's get_optional would.
pub fn convert(comptime T: type, v: Value) ?T {
    if (T == []const u8) return switch (v) {
        .string => |s| s,
        else => null,
    };
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .bool => |b| b,
            .integer => |i| i != 0,
            .float => |f| f != 0,
            // boost::lexical_cast<bool> accepts exactly "0" and "1".
            .string => |s| if (std.mem.eql(u8, s, "1")) true else if (std.mem.eql(u8, s, "0")) false else null,
            else => null,
        },
        .int => return switch (v) {
            .integer => |i| castInt(T, i),
            .float => |f| floatToInt(T, f),
            .bool => |b| @intFromBool(b),
            .string => |s| std.fmt.parseInt(T, s, 10) catch null,
            .number_string => |s| std.fmt.parseInt(T, s, 10) catch if (std.fmt.parseFloat(f64, s)) |f| floatToInt(T, f) else |_| null,
            else => null,
        },
        .float => return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .bool => |b| @floatFromInt(@intFromBool(b)),
            .string => |s| parseFloatStrict(T, s),
            .number_string => |s| std.fmt.parseFloat(T, s) catch null,
            else => null,
        },
        else => @compileError("unsupported conversion target " ++ @typeName(T)),
    }
}

/// C++ static_cast between integer types wraps; out-of-range request values
/// are treated as absent here instead (the default applies).
fn castInt(comptime T: type, i: i64) ?T {
    return std.math.cast(T, i);
}

fn floatToInt(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (t < @as(f64, @floatFromInt(std.math.minInt(T))) or t > @as(f64, @floatFromInt(std.math.maxInt(T)))) return null;
    return @intFromFloat(t);
}

fn parseFloatStrict(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(T, s) catch null;
}

/// An array at `path`, if there is one.
pub fn array(root: Value, path: []const u8) ?[]const Value {
    const v = pointer(root, path) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn object(root: Value, path: []const u8) ?std.json.ObjectMap {
    const v = pointer(root, path) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pointer and lenient conversions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try parse(a, "{\"locations\":[{\"lat\":40.5,\"lon\":\"-76.25\"}],\"range\":1,\"verbose\":\"1\",\"units\":\"mi\",\"a/b\":7,\"n\":12345678901234567890,\"id\":5,\"id\":6}");
    try testing.expectEqual(@as(f64, 40.5), getOptional(f64, doc, "/locations/0/lat").?);
    try testing.expectEqual(@as(f64, -76.25), getOptional(f64, doc, "/locations/0/lon").?);
    try testing.expect(getOptional(bool, doc, "/range").?);
    try testing.expect(getOptional(bool, doc, "/verbose").?);
    try testing.expectEqualStrings("mi", getOptional([]const u8, doc, "/units").?);
    try testing.expectEqual(@as(?[]const u8, null), getOptional([]const u8, doc, "/range"));
    try testing.expectEqual(@as(i64, 7), getOptional(i64, doc, "/a~1b").?);
    try testing.expectEqual(@as(u32, 2), get(u32, doc, "/missing", 2));
    try testing.expectEqual(@as(?f64, null), getOptional(f64, doc, "/locations/1/lat"));
    try testing.expectEqual(@as(u64, 12345678901234567890), getOptional(u64, doc, "/n").?);
    try testing.expectEqual(@as(i64, 5), getOptional(i64, doc, "/id").?); // first duplicate wins
    try testing.expectEqual(@as(?u32, null), getOptional(u32, doc, "/units"));
}

test "invalid json is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.InvalidJson, parse(arena_state.allocator(), "{\"a\":"));
}
