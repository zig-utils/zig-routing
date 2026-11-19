//! Protocol Buffers wire primitives. Field views borrow the input.
const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Error = error{
    Truncated,
    VarintOverflow,
    InvalidTag,
    InvalidWireType,
    UnexpectedEndGroup,
    GroupMismatch,
    NestingLimit,
    DeadlineExceeded,
    MissingRequired,
    InvalidUtf8,
    SizeOverflow,
    NoSpace,
};

pub const NoDeadline = struct {
    pub fn expired(_: NoDeadline) bool {
        return false;
    }
};
pub const no_deadline: NoDeadline = .{};

pub fn checkAt(deadline: anytype, i: usize) Error!void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

pub const max_depth = 64;
pub const FieldNumber = u29;
const Tag = struct { number: FieldNumber, wire_type: WireType };

pub const Value = union(WireType) {
    varint: u64,
    fixed64: u64,
    length_delimited: []const u8,
    start_group: void,
    end_group: void,
    fixed32: u32,
};

pub const FieldView = struct {
    number: FieldNumber,
    value: Value,

    pub fn wireType(self: FieldView) WireType {
        return self.value;
    }
};

pub const Reader = struct {
    remaining: []const u8,

    pub fn init(input: []const u8) Reader {
        return .{ .remaining = input };
    }

    pub fn readVarint(self: *Reader) Error!u64 {
        const input = self.remaining;
        var value: u64 = 0;
        for (input[0..@min(input.len, 10)], 0..) |byte, i| {
            if (i == 9 and byte > 1) return error.VarintOverflow;
            value |= @as(u64, byte & 0x7f) << @as(u6, @intCast(i * 7));
            if (byte & 0x80 == 0) {
                self.remaining = input[i + 1 ..];
                return value;
            }
        }
        return error.Truncated;
    }

    fn take(self: *Reader, size: u64) Error![]const u8 {
        if (size > self.remaining.len) return error.Truncated;
        const count: usize = @intCast(size);
        const bytes = self.remaining[0..count];
        self.remaining = self.remaining[count..];
        return bytes;
    }

    pub fn readFixed32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    pub fn readFixed64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    pub fn readBytes(self: *Reader) Error![]const u8 {
        const size = try self.readVarint();
        return self.take(size);
    }

    fn readTag(self: *Reader) Error!Tag {
        const value = try self.readVarint();
        const number = value >> 3;
        if (number == 0 or number > std.math.maxInt(FieldNumber)) return error.InvalidTag;
        return .{
            .number = @intCast(number),
            .wire_type = switch (@as(u3, @truncate(value))) {
                0 => .varint,
                1 => .fixed64,
                2 => .length_delimited,
                3 => .start_group,
                4 => .end_group,
                5 => .fixed32,
                else => return error.InvalidWireType,
            },
        };
    }

    fn readValue(self: *Reader, wire_type: WireType) Error!Value {
        return switch (wire_type) {
            .varint => .{ .varint = try self.readVarint() },
            .fixed64 => .{ .fixed64 = try self.readFixed64() },
            .length_delimited => .{ .length_delimited = try self.readBytes() },
            .fixed32 => .{ .fixed32 = try self.readFixed32() },
            .start_group, .end_group => unreachable,
        };
    }

    fn skipGroup(self: *Reader, number: FieldNumber, deadline: anytype) Error!void {
        var groups: [max_depth]FieldNumber = undefined;
        groups[0] = number;
        var depth: usize = 1;
        var steps: usize = 0;
        while (depth != 0) : (steps += 1) {
            try checkAt(deadline, steps);
            const tag = try self.readTag();
            switch (tag.wire_type) {
                .start_group => {
                    if (depth == groups.len) return error.NestingLimit;
                    groups[depth] = tag.number;
                    depth += 1;
                },
                .end_group => {
                    depth -= 1;
                    if (groups[depth] != tag.number) return error.GroupMismatch;
                },
                else => _ = try self.readValue(tag.wire_type),
            }
        }
    }

    /// Read one field, including skipping the body of a legacy unknown group.
    pub fn next(self: *Reader, deadline: anytype) Error!?FieldView {
        if (self.remaining.len == 0) return null;
        const tag = try self.readTag();
        const value: Value = switch (tag.wire_type) {
            .start_group => group: {
                try self.skipGroup(tag.number, deadline);
                break :group .{ .start_group = {} };
            },
            .end_group => return error.UnexpectedEndGroup,
            else => try self.readValue(tag.wire_type),
        };
        return .{ .number = tag.number, .value = value };
    }
};

pub fn zigzagEncode(comptime S: type, value: S) @Int(.unsigned, @bitSizeOf(S)) {
    const U = @Int(.unsigned, @bitSizeOf(S));
    const bits: U = @bitCast(value);
    return (bits << 1) ^ @as(U, @bitCast(value >> (@bitSizeOf(S) - 1)));
}

pub fn zigzagDecode(comptime S: type, value: @Int(.unsigned, @bitSizeOf(S))) S {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

pub fn varintSize(value: u64) usize {
    return @max(1, (64 - @clz(value) + 6) / 7);
}

pub fn tagValue(number: FieldNumber, wire_type: WireType) u64 {
    return (@as(u64, number) << 3) | @as(u64, @backingInt(wire_type));
}

pub fn writeVarint(writer: anytype, value: u64) !void {
    var buf: [10]u8 = undefined;
    var rest = value;
    var i: usize = 0;
    while (rest >= 128) : (i += 1) {
        buf[i] = @as(u8, @truncate(rest)) | 0x80;
        rest >>= 7;
    }
    buf[i] = @intCast(rest);
    try writer.writeAll(buf[0 .. i + 1]);
}

pub fn writeFixed(comptime T: type, writer: anytype, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

pub const BufferWriter = struct {
    buffer: []u8,
    written: usize = 0,

    pub fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer };
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) Error!void {
        if (bytes.len > self.buffer.len - self.written) return error.NoSpace;
        @memcpy(self.buffer[self.written..][0..bytes.len], bytes);
        self.written += bytes.len;
    }
};

test "varint boundaries, zigzag extrema, and malformed lengths" {
    for ([_]u64{ 0, 1, 127, 128, 16383, 16384, std.math.maxInt(u32), std.math.maxInt(u64) }) |value| {
        var encoded: [10]u8 = undefined;
        var writer = BufferWriter.init(&encoded);
        try writeVarint(&writer, value);
        try std.testing.expectEqual(varintSize(value), writer.written);
        var reader = Reader.init(encoded[0..writer.written]);
        try std.testing.expectEqual(value, try reader.readVarint());
        try std.testing.expectEqual(0, reader.remaining.len);
    }
    inline for (.{ i32, i64 }) |T| {
        for ([_]T{ std.math.minInt(T), -2, -1, 0, 1, 2, std.math.maxInt(T) }) |value|
            try std.testing.expectEqual(value, zigzagDecode(T, zigzagEncode(T, value)));
    }
    var short = Reader.init("\x80");
    try std.testing.expectError(error.Truncated, short.readVarint());
    var overflow = Reader.init("\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02");
    try std.testing.expectError(error.VarintOverflow, overflow.readVarint());
    var length = Reader.init("\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01\x01");
    try std.testing.expectError(error.Truncated, length.readBytes());
}

test "unknown nested groups are skipped with matching end tags" {
    var reader = Reader.init("\x3b\x43\x08\x2a\x44\x3c\x08\x01");
    try std.testing.expectEqual(@as(FieldNumber, 7), (try reader.next(no_deadline)).?.number);
    try std.testing.expectEqual(1, (try reader.next(no_deadline)).?.value.varint);
    try std.testing.expectEqual(null, try reader.next(no_deadline));
    var mismatch = Reader.init("\x3b\x44");
    try std.testing.expectError(error.GroupMismatch, mismatch.next(no_deadline));
    var ending = Reader.init("\x3c");
    try std.testing.expectError(error.UnexpectedEndGroup, ending.next(no_deadline));
}
