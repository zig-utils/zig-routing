//! Common formatting for the pinned Odin debug strings.
const io = @import("../infra/io.zig");

pub fn field(out: *io.Writer, label: []const u8, value: anytype) io.Writer.Error!void {
    try out.print(" | {s}=", .{label});
    switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => try out.print("{d}", .{@backingInt(value)}),
        .bool => try out.print("{d}", .{@intFromBool(value)}),
        .float => try out.print("{d:.6}", .{@as(f64, value)}),
        .int => try out.print("{d}", .{value}),
        .pointer => try out.writeAll(value),
        else => @compileError("unsupported Odin debug field type"),
    }
}

pub fn fields(out: *io.Writer, value: anytype, comptime keys: []const []const u8) io.Writer.Error!void {
    inline for (keys) |key| try field(out, key, @field(value, key));
}

/// Street names and signs use the same slash and pronunciation notation.
pub fn names(out: *io.Writer, values: anytype, comptime key: []const u8, pronounce: bool, deadline: io.Deadline) !void {
    var has_text = false;
    for (values, 0..) |value, index| {
        if (index % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (has_text) try out.writeByte('/');
        const text = @field(value, key);
        try out.writeAll(text);
        has_text = has_text or text.len != 0;
        if (if (pronounce) value.pronunciation else null) |pronunciation| {
            try out.print("({s})", .{pronunciation.value});
            has_text = true;
        }
    }
}
