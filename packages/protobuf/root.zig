//! Allocation-free Protocol Buffers wire codec and comptime schemas.
const std = @import("std");

pub const wire = @import("wire.zig");
pub const Error = wire.Error;
pub const no_deadline = wire.no_deadline;

pub const Kind = enum {
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    float,
    double,
    bool,
    enumeration,
    string,
    bytes,
    message,

    fn wireType(self: Kind) wire.WireType {
        return switch (self) {
            .fixed32, .sfixed32, .float => .fixed32,
            .fixed64, .sfixed64, .double => .fixed64,
            .string, .bytes, .message => .length_delimited,
            else => .varint,
        };
    }
};

pub const Presence = enum { implicit, optional, required, repeated };

pub const Default = union(enum) {
    integer: i128,
    floating: f64,
    boolean: bool,
    bytes: []const u8,
};

pub const Field = struct {
    name: [:0]const u8,
    number: wire.FieldNumber,
    kind: Kind,
    presence: Presence = .implicit,
    packed_encoding: bool = false,
    message: type = void,
    enum_type: type = i32,
    default_value: ?Default = null,
    // Protobuf map entries explicitly write scalar keys and values.
    encode_default: bool = false,
};

fn native(comptime field: Field, comptime encoding: bool) type {
    return switch (field.kind) {
        .int32, .sint32, .sfixed32 => i32,
        .enumeration => field.enum_type,
        .int64, .sint64, .sfixed64 => i64,
        .uint32, .fixed32 => u32,
        .uint64, .fixed64 => u64,
        .float => f32,
        .double => f64,
        .bool => bool,
        .string, .bytes => []const u8,
        .message => if (encoding) field.message.Values else field.message.View,
    };
}

fn enumValue(comptime T: type, number: i32) T {
    return if (T == i32) number else @fromBackingInt(number);
}

fn enumNumber(value: anytype) i32 {
    return if (@TypeOf(value) == i32) value else @backingInt(value);
}

fn defaultValue(comptime field: Field) native(field, true) {
    if (field.default_value) |value| {
        return switch (field.kind) {
            .bool => value.boolean,
            .float => @floatCast(value.floating),
            .double => value.floating,
            .string, .bytes => value.bytes,
            .enumeration => enumValue(field.enum_type, @intCast(value.integer)),
            .message => @compileError("an embedded message cannot have a scalar default"),
            else => @intCast(value.integer),
        };
    }
    return switch (field.kind) {
        .bool => false,
        .string, .bytes => "",
        .enumeration => enumValue(field.enum_type, 0),
        .message => @compileError("message fields must have explicit presence"),
        else => 0,
    };
}

fn defaultPtr(comptime T: type, comptime value: T) *const anyopaque {
    return @ptrCast(&value);
}

fn valuesType(comptime fields: []const Field) type {
    @setEvalBranchQuota(1_000_000);
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    for (fields, 0..) |field, i| {
        const T = native(field, true);
        names[i] = field.name;
        types[i] = switch (field.presence) {
            .implicit, .required => T,
            .optional => ?T,
            .repeated => []const T,
        };
        attrs[i].default_value_ptr = switch (field.presence) {
            .implicit => defaultPtr(T, defaultValue(field)),
            .optional => defaultPtr(?T, null),
            .required => null,
            .repeated => defaultPtr([]const T, &.{}),
        };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn canonical(comptime description: []const Field) [description.len]Field {
    @setEvalBranchQuota(1_000_000);
    var fields = description[0..description.len].*;
    for (fields, 0..) |field, i| {
        if (field.name.len == 0 or field.number == 0 or (field.number >= 19_000 and field.number <= 19_999))
            @compileError("invalid Protobuf field");
        if ((field.kind == .message) != (field.message != void))
            @compileError("message field must name its schema");
        if (field.kind == .message and field.presence == .implicit)
            @compileError("message field must have explicit presence");
        if (field.enum_type != i32) {
            if (field.kind != .enumeration)
                @compileError("an enum type is only valid for an enumeration field");
            if (@typeInfo(field.enum_type) != .@"enum" or
                @typeInfo(field.enum_type).@"enum".tag_type != i32 or
                @typeInfo(field.enum_type).@"enum".mode != .nonexhaustive)
                @compileError("a Protobuf enumeration needs a nonexhaustive enum(i32)");
        }
        if (field.encode_default and field.presence != .implicit)
            @compileError("encode_default requires implicit presence");
        if (field.default_value != null) {
            if (field.presence != .optional or field.kind == .message)
                @compileError("a Protobuf default is only used for an optional scalar, string, or bytes");
            const value = defaultValue(field);
            if (field.kind == .string and !std.unicode.utf8ValidateSlice(value))
                @compileError("a Protobuf string default must be UTF-8");
        }
        if (field.packed_encoding and !acceptsPacked(field))
            @compileError("packed fields must be repeated numeric or boolean values");
        for (fields[0..i]) |other| {
            if (field.number == other.number or std.mem.eql(u8, field.name, other.name))
                @compileError("duplicate Protobuf field");
        }
    }
    // Schemas are small and ordered once by the compiler.
    for (1..@max(fields.len, 1)) |i| {
        var j = i;
        while (j > 0 and fields[j].number < fields[j - 1].number) : (j -= 1)
            std.mem.swap(Field, &fields[j], &fields[j - 1]);
    }
    return fields;
}

fn acceptsPacked(comptime field: Field) bool {
    return field.presence == .repeated and field.kind.wireType() != .length_delimited;
}

/// A singular embedded message can appear several times. The current
/// message then consists of the matching byte slices in input order.
const Source = struct {
    bytes: []const u8,
    path: [wire.max_depth]wire.FieldNumber = undefined,
    path_len: usize = 0,
    depth: usize = 0,

    fn child(self: Source, field: wire.FieldNumber, first: []const u8, merged: bool) Error!Source {
        if (self.depth == wire.max_depth) return error.NestingLimit;
        if (!merged) return .{ .bytes = first, .depth = self.depth + 1 };
        var result = self;
        result.path[result.path_len] = field;
        result.path_len += 1;
        result.depth += 1;
        return result;
    }
};

const Fields = struct {
    source: Source,
    readers: [wire.max_depth + 1]wire.Reader = undefined,
    level: usize = 0,
    visited: usize = 0,

    fn init(source: Source) Fields {
        var self: Fields = .{ .source = source };
        self.readers[0] = .init(source.bytes);
        return self;
    }

    fn next(self: *Fields, deadline: anytype) Error!?wire.FieldView {
        while (true) : (self.visited += 1) {
            try wire.checkAt(deadline, self.visited);
            if (try self.readers[self.level].next(deadline)) |field| {
                if (self.level == self.source.path_len) {
                    self.visited += 1;
                    return field;
                }
                if (field.number == self.source.path[self.level] and field.wireType() == .length_delimited) {
                    self.level += 1;
                    self.readers[self.level] = .init(field.value.length_delimited);
                }
            } else {
                if (self.level == 0) return null;
                self.level -= 1;
            }
        }
    }
};

const Occurrence = struct {
    last: ?wire.Value = null,
    merged: bool = false,

    fn remember(self: *Occurrence, value: wire.Value) void {
        self.merged = self.last != null;
        self.last = value;
    }

    fn asChild(self: Occurrence, parent: Source, number: wire.FieldNumber) Error!Source {
        return parent.child(number, self.last.?.length_delimited, self.merged);
    }
};

fn scalar(comptime field: Field, value: wire.Value) native(field, false) {
    return switch (field.kind) {
        .int32 => @bitCast(@as(u32, @truncate(value.varint))),
        .enumeration => enumValue(field.enum_type, @bitCast(@as(u32, @truncate(value.varint)))),
        .int64 => @bitCast(value.varint),
        .uint32 => @truncate(value.varint),
        .uint64 => value.varint,
        .sint32 => wire.zigzagDecode(i32, @truncate(value.varint)),
        .sint64 => wire.zigzagDecode(i64, value.varint),
        .fixed32 => value.fixed32,
        .fixed64 => value.fixed64,
        .sfixed32, .float => @bitCast(value.fixed32),
        .sfixed64, .double => @bitCast(value.fixed64),
        .bool => value.varint != 0,
        .string, .bytes => value.length_delimited,
        .message => unreachable,
    };
}

fn packedValue(comptime field: Field, reader: *wire.Reader) Error!wire.Value {
    return switch (comptime field.kind.wireType()) {
        .varint => .{ .varint = try reader.readVarint() },
        .fixed32 => .{ .fixed32 = try reader.readFixed32() },
        .fixed64 => .{ .fixed64 = try reader.readFixed64() },
        else => unreachable,
    };
}

fn validatePacked(comptime field: Field, input: []const u8, deadline: anytype) Error!void {
    switch (comptime field.kind.wireType()) {
        .fixed32 => if (input.len % 4 != 0) return error.Truncated,
        .fixed64 => if (input.len % 8 != 0) return error.Truncated,
        .varint => {
            var reader = wire.Reader.init(input);
            var count: usize = 0;
            while (reader.remaining.len != 0) : (count += 1) {
                try wire.checkAt(deadline, count);
                _ = try reader.readVarint();
            }
        },
        else => unreachable,
    }
}

fn Repeated(comptime field: Field) type {
    return struct {
        fields: Fields,
        packed_input: wire.Reader = .init(""),

        pub fn next(self: *@This(), deadline: anytype) Error!?native(field, false) {
            if (comptime acceptsPacked(field)) {
                if (self.packed_input.remaining.len != 0)
                    return scalar(field, try packedValue(field, &self.packed_input));
            }
            while (try self.fields.next(deadline)) |item| {
                if (item.number != field.number) continue;
                if (item.wireType() == field.kind.wireType()) {
                    if (comptime field.kind == .message) {
                        return .{ .source = try self.fields.source.child(field.number, item.value.length_delimited, false) };
                    } else {
                        return scalar(field, item.value);
                    }
                }
                if (comptime acceptsPacked(field)) {
                    if (item.wireType() != .length_delimited or item.value.length_delimited.len == 0) continue;
                    self.packed_input = .init(item.value.length_delimited);
                    return scalar(field, try packedValue(field, &self.packed_input));
                }
            }
            return null;
        }
    };
}

fn getType(comptime field: Field) type {
    return switch (field.presence) {
        .implicit, .required => native(field, false),
        .optional => ?native(field, false),
        .repeated => Repeated(field),
    };
}

fn varintValue(comptime field: Field, value: native(field, true)) u64 {
    return switch (field.kind) {
        .int32, .int64 => @bitCast(@as(i64, value)),
        .enumeration => @bitCast(@as(i64, enumNumber(value))),
        .uint32, .uint64 => value,
        .sint32 => wire.zigzagEncode(i32, value),
        .sint64 => wire.zigzagEncode(i64, value),
        .bool => @intFromBool(value),
        else => unreachable,
    };
}

fn isDefault(comptime field: Field, value: native(field, true)) bool {
    return switch (field.kind) {
        .bool => !value,
        .float => @as(u32, @bitCast(value)) == 0,
        .double => @as(u64, @bitCast(value)) == 0,
        .bytes, .string => value.len == 0,
        .enumeration => enumNumber(value) == 0,
        else => value == 0,
    };
}

fn addSize(a: usize, b: usize) Error!usize {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.SizeOverflow;
    return sum;
}

fn bodySize(comptime field: Field, value: native(field, true), deadline: anytype) Error!usize {
    return switch (field.kind) {
        .message => field.message.encodedSize(value, deadline),
        .string => if (std.unicode.utf8ValidateSlice(value)) value.len else error.InvalidUtf8,
        .bytes => value.len,
        else => switch (comptime field.kind.wireType()) {
            .varint => wire.varintSize(varintValue(field, value)),
            .fixed32 => 4,
            .fixed64 => 8,
            else => unreachable,
        },
    };
}

fn recordSize(comptime field: Field, value: native(field, true), deadline: anytype) Error!usize {
    const wire_type = comptime field.kind.wireType();
    const size = try bodySize(field, value, deadline);
    const header = wire.varintSize(wire.tagValue(field.number, wire_type)) +
        if (wire_type == .length_delimited) wire.varintSize(size) else @as(usize, 0);
    return addSize(header, size);
}

fn payloadSize(comptime field: Field, items: []const native(field, true), deadline: anytype) Error!usize {
    var size: usize = 0;
    for (items, 0..) |item, i| {
        try wire.checkAt(deadline, i);
        size = try addSize(size, try bodySize(field, item, deadline));
    }
    return size;
}

fn writeBody(comptime field: Field, writer: anytype, value: native(field, true), deadline: anytype) anyerror!void {
    switch (field.kind) {
        .message => try field.message.writeFields(writer, value, deadline),
        .bytes, .string => try writer.writeAll(value),
        else => switch (comptime field.kind.wireType()) {
            .varint => try wire.writeVarint(writer, varintValue(field, value)),
            .fixed32 => try wire.writeFixed(u32, writer, @bitCast(value)),
            .fixed64 => try wire.writeFixed(u64, writer, @bitCast(value)),
            else => unreachable,
        },
    }
}

fn writeRecord(comptime field: Field, writer: anytype, value: native(field, true), deadline: anytype) anyerror!void {
    const wire_type = comptime field.kind.wireType();
    try wire.writeVarint(writer, wire.tagValue(field.number, wire_type));
    if (wire_type == .length_delimited) try wire.writeVarint(writer, try bodySize(field, value, deadline));
    try writeBody(field, writer, value, deadline);
}

/// Describe a message at comptime. Use `.optional` for true presence or
/// `.implicit` for a default-valued proto3 scalar. Enum numbers use i32.
pub fn Message(comptime description: []const Field) type {
    const fields = comptime canonical(description);
    return struct {
        pub const schema = fields;
        pub const Values = valuesType(&fields);
        const FieldName = std.meta.FieldEnum(Values);

        fn fieldNamed(comptime name: []const u8) Field {
            return fields[@backingInt(@field(FieldName, name))];
        }

        /// A validated borrow of the encoded message. Keep the input alive
        /// and immutable while using the view or its iterators.
        pub const View = struct {
            source: Source,

            pub fn get(self: View, comptime name: []const u8, deadline: anytype) Error!getType(fieldNamed(name)) {
                const field = comptime fieldNamed(name);
                if (comptime field.presence == .repeated) return .{ .fields = .init(self.source) };

                var cursor = Fields.init(self.source);
                var seen: Occurrence = .{};
                while (try cursor.next(deadline)) |item| {
                    if (item.number == field.number and item.wireType() == field.kind.wireType())
                        seen.remember(item.value);
                }
                if (seen.last) |value| {
                    if (comptime field.kind == .message) {
                        return .{ .source = try seen.asChild(self.source, field.number) };
                    } else {
                        return scalar(field, value);
                    }
                }
                return switch (field.presence) {
                    .implicit => defaultValue(field),
                    .optional => null,
                    .required => error.MissingRequired,
                    .repeated => unreachable,
                };
            }

            /// Read the explicit value, or the schema default when absent.
            /// Use get to distinguish absence from explicitly encoding it.
            pub fn getOrDefault(self: View, comptime name: []const u8, deadline: anytype) Error!native(fieldNamed(name), false) {
                const field = comptime fieldNamed(name);
                if (field.presence != .optional or field.kind == .message)
                    @compileError("getOrDefault requires an optional scalar, string, or bytes");
                return (try self.get(name, deadline)) orelse defaultValue(field);
            }
        };

        fn validate(source: Source, deadline: anytype) Error!void {
            var cursor = Fields.init(source);
            var seen: [fields.len]Occurrence = @splat(.{});
            while (try cursor.next(deadline)) |item| {
                inline for (fields, 0..) |field, i| {
                    if (item.number == field.number) {
                        if (item.wireType() == field.kind.wireType()) {
                            switch (field.kind) {
                                .string => if (!std.unicode.utf8ValidateSlice(item.value.length_delimited)) return error.InvalidUtf8,
                                .message => if (field.presence == .repeated) {
                                    try field.message.validate(try source.child(field.number, item.value.length_delimited, false), deadline);
                                },
                                else => {},
                            }
                            if (field.presence == .required or (field.kind == .message and field.presence != .repeated))
                                seen[i].remember(item.value);
                        } else if (comptime acceptsPacked(field)) {
                            if (item.wireType() == .length_delimited)
                                try validatePacked(field, item.value.length_delimited, deadline);
                        }
                    }
                }
            }
            inline for (fields, 0..) |field, i| {
                if (field.presence == .required and seen[i].last == null) return error.MissingRequired;
                if (field.kind == .message and field.presence != .repeated and seen[i].last != null)
                    try field.message.validate(try seen[i].asChild(source, field.number), deadline);
            }
        }

        pub fn decode(bytes: []const u8, deadline: anytype) Error!View {
            const source: Source = .{ .bytes = bytes };
            try validate(source, deadline);
            return .{ .source = source };
        }

        pub fn encodedSize(input: Values, deadline: anytype) Error!usize {
            var size: usize = 0;
            inline for (fields) |field| {
                const value = @field(input, field.name);
                switch (field.presence) {
                    .required => size = try addSize(size, try recordSize(field, value, deadline)),
                    .implicit => if (field.encode_default or !isDefault(field, value)) {
                        size = try addSize(size, try recordSize(field, value, deadline));
                    },
                    .optional => if (value) |item| {
                        size = try addSize(size, try recordSize(field, item, deadline));
                    },
                    .repeated => if (field.packed_encoding) {
                        if (value.len != 0) {
                            const payload = try payloadSize(field, value, deadline);
                            size = try addSize(size, wire.varintSize(wire.tagValue(field.number, .length_delimited)) + wire.varintSize(payload));
                            size = try addSize(size, payload);
                        }
                    } else {
                        for (value, 0..) |item, i| {
                            try wire.checkAt(deadline, i);
                            size = try addSize(size, try recordSize(field, item, deadline));
                        }
                    },
                }
            }
            return size;
        }

        fn writeFields(writer: anytype, input: Values, deadline: anytype) anyerror!void {
            inline for (fields) |field| {
                const value = @field(input, field.name);
                switch (field.presence) {
                    .required => try writeRecord(field, writer, value, deadline),
                    .implicit => if (field.encode_default or !isDefault(field, value)) {
                        try writeRecord(field, writer, value, deadline);
                    },
                    .optional => if (value) |item| {
                        try writeRecord(field, writer, item, deadline);
                    },
                    .repeated => {
                        if (field.packed_encoding and value.len != 0) {
                            try wire.writeVarint(writer, wire.tagValue(field.number, .length_delimited));
                            try wire.writeVarint(writer, try payloadSize(field, value, deadline));
                        }
                        for (value, 0..) |item, i| {
                            try wire.checkAt(deadline, i);
                            if (field.packed_encoding) try writeBody(field, writer, item, deadline) else try writeRecord(field, writer, item, deadline);
                        }
                    },
                }
            }
        }

        /// Write directly to a sink implementing writeAll, without a staging
        /// buffer. Nested and packed lengths are computed before their bodies.
        pub fn write(writer: anytype, input: Values, deadline: anytype) !void {
            _ = try encodedSize(input, deadline);
            try writeFields(writer, input, deadline);
        }

        /// The output buffer must be disjoint from the input byte slices.
        pub fn encode(output: []u8, input: Values, deadline: anytype) ![]u8 {
            const size = try encodedSize(input, deadline);
            if (size > output.len) return error.NoSpace;
            var writer = wire.BufferWriter.init(output);
            try writeFields(&writer, input, deadline);
            std.debug.assert(writer.written == size);
            return output[0..size];
        }
    };
}

test {
    _ = wire;
}

const testing = std.testing;

// Encoded by protoc 29.6 using fixtures/scalars.proto and scalars.textproto.
const reference = @embedFile("fixtures/scalars.bin");
const Child = Message(&.{
    .{ .number = 1, .name = "id", .kind = .sint64, .presence = .required },
    .{ .number = 2, .name = "payload", .kind = .bytes, .presence = .optional },
});
const Scalars = Message(&.{
    // Schema declaration order is intentionally different from wire order.
    .{ .number = 23, .name = "zero", .kind = .int32, .presence = .optional },
    .{ .number = 1, .name = "signed32", .kind = .int32, .presence = .required },
    .{ .number = 2, .name = "signed64", .kind = .int64, .presence = .optional },
    .{ .number = 3, .name = "unsigned32", .kind = .uint32, .presence = .optional },
    .{ .number = 4, .name = "unsigned64", .kind = .uint64, .presence = .optional },
    .{ .number = 5, .name = "zigzag32", .kind = .sint32, .presence = .optional },
    .{ .number = 6, .name = "zigzag64", .kind = .sint64, .presence = .optional },
    .{ .number = 7, .name = "fixed_32", .kind = .fixed32, .presence = .optional },
    .{ .number = 8, .name = "fixed_64", .kind = .fixed64, .presence = .optional },
    .{ .number = 9, .name = "signed_fixed32", .kind = .sfixed32, .presence = .optional },
    .{ .number = 10, .name = "signed_fixed64", .kind = .sfixed64, .presence = .optional },
    .{ .number = 11, .name = "f32", .kind = .float, .presence = .optional },
    .{ .number = 12, .name = "f64", .kind = .double, .presence = .optional },
    .{ .number = 13, .name = "flag", .kind = .bool, .presence = .optional },
    .{ .number = 14, .name = "text", .kind = .string, .presence = .optional },
    .{ .number = 15, .name = "blob", .kind = .bytes, .presence = .optional },
    .{ .number = 16, .name = "child", .kind = .message, .presence = .optional, .message = Child },
    .{ .number = 17, .name = "numbers", .kind = .uint64, .presence = .repeated, .packed_encoding = true },
    .{ .number = 18, .name = "words", .kind = .fixed32, .presence = .repeated, .packed_encoding = true },
    .{ .number = 19, .name = "deltas", .kind = .sint32, .presence = .repeated },
    .{ .number = 20, .name = "children", .kind = .message, .presence = .repeated, .message = Child },
    .{ .number = 21, .name = "choice", .kind = .enumeration, .presence = .optional },
    .{ .number = 22, .name = "wide", .kind = .fixed64, .presence = .repeated, .packed_encoding = true },
});

test "all scalar and nested types round trip with byte-exact protoc output" {
    const input: Scalars.Values = .{
        .signed32 = -1,
        .signed64 = std.math.minInt(i64),
        .unsigned32 = std.math.maxInt(u32),
        .unsigned64 = std.math.maxInt(u64),
        .zigzag32 = std.math.minInt(i32),
        .zigzag64 = std.math.maxInt(i64),
        .fixed_32 = 0x01020304,
        .fixed_64 = 0x0102030405060708,
        .signed_fixed32 = -12_345_678,
        .signed_fixed64 = -123_456_789_012_345,
        .f32 = 1.5,
        .f64 = -2.25,
        .flag = false,
        .text = "Grüezi",
        .blob = "\x00\xff\n",
        .child = .{ .id = -3, .payload = "nested" },
        .numbers = &.{ 0, 127, 128, 16384 },
        .words = &.{ 0, 0x01020304 },
        .deltas = &.{ -1, 0, 1 },
        .children = &.{ .{ .id = 10 }, .{ .id = 12, .payload = "" } },
        .choice = -1,
        .wide = &.{ 42, std.math.maxInt(u64) },
        .zero = 0,
    };
    try testing.expectEqual(reference.len, try Scalars.encodedSize(input, no_deadline));
    var output: [reference.len]u8 = @splat(0xab);
    try testing.expectError(error.NoSpace, Scalars.encode(output[0 .. output.len - 1], input, no_deadline));
    try testing.expectEqual(@as([reference.len]u8, @splat(0xab)), output);
    const encoded = try Scalars.encode(&output, input, no_deadline);
    try testing.expectEqualSlices(u8, reference, encoded);

    var stream_buffer: [reference.len]u8 = undefined;
    var writer = wire.BufferWriter.init(&stream_buffer);
    try Scalars.write(&writer, input, no_deadline);
    try testing.expectEqualSlices(u8, reference, stream_buffer[0..writer.written]);

    const decoded = try Scalars.decode(encoded, no_deadline);
    inline for (.{
        "signed32", "signed64", "unsigned32",     "unsigned64",     "zigzag32", "zigzag64",
        "fixed_32", "fixed_64", "signed_fixed32", "signed_fixed64", "f32",      "f64",
        "flag",     "choice",   "zero",
    }) |name| try testing.expectEqual(@field(input, name), try decoded.get(name, no_deadline));
    inline for (.{ "text", "blob" }) |name| {
        const bytes = (try decoded.get(name, no_deadline)).?;
        try testing.expectEqualStrings(@field(input, name).?, bytes);
        const offset = @intFromPtr(bytes.ptr) - @intFromPtr(encoded.ptr);
        try testing.expect(offset + bytes.len <= encoded.len);
    }
    const child = (try decoded.get("child", no_deadline)).?;
    try testing.expectEqual(-3, try child.get("id", no_deadline));
    try testing.expectEqualStrings("nested", (try child.get("payload", no_deadline)).?);
    inline for (.{ "numbers", "words", "deltas", "wide" }) |name| {
        var it = try decoded.get(name, no_deadline);
        for (@field(input, name)) |expected| try testing.expectEqual(expected, (try it.next(no_deadline)).?);
        try testing.expectEqual(null, try it.next(no_deadline));
    }
    var children = try decoded.get("children", no_deadline);
    const first = (try children.next(no_deadline)).?;
    const second = (try children.next(no_deadline)).?;
    try testing.expectEqual(10, try first.get("id", no_deadline));
    try testing.expectEqual(null, try first.get("payload", no_deadline));
    try testing.expectEqual(12, try second.get("id", no_deadline));
    try testing.expectEqualStrings("", (try second.get("payload", no_deadline)).?);
    try testing.expectEqual(null, try children.next(no_deadline));
}

test "implicit defaults are omitted while explicit defaults retain presence" {
    const Test = Message(&.{
        .{ .number = 1, .name = "implicit", .kind = .int32 },
        .{ .number = 2, .name = "explicit", .kind = .int32, .presence = .optional },
        .{ .number = 3, .name = "name", .kind = .string },
        .{ .number = 4, .name = "marker", .kind = .float },
        .{ .number = 5, .name = "granularity", .kind = .int32, .presence = .optional, .default_value = .{ .integer = 100 } },
    });
    var buffer: [32]u8 = undefined;
    try testing.expectEqual(0, (try Test.encode(&buffer, .{}, no_deadline)).len);
    const absent = try Test.decode("", no_deadline);
    try testing.expectEqual(0, try absent.get("implicit", no_deadline));
    try testing.expectEqual(null, try absent.get("explicit", no_deadline));
    try testing.expectEqualStrings("", try absent.get("name", no_deadline));
    try testing.expectEqual(null, try absent.get("granularity", no_deadline));
    try testing.expectEqual(100, try absent.getOrDefault("granularity", no_deadline));
    const encoded = try Test.encode(&buffer, .{ .explicit = 0, .marker = -0.0 }, no_deadline);
    try testing.expectEqualSlices(u8, "\x10\x00\x25\x00\x00\x00\x80", encoded);
    try testing.expectEqual(@as(?i32, 0), try (try Test.decode(encoded, no_deadline)).get("explicit", no_deadline));
}

test "singular messages merge split required fields, repeated values and nested occurrences" {
    const Leaf = Message(&.{
        .{ .number = 1, .name = "left", .kind = .string, .presence = .required },
        .{ .number = 2, .name = "right", .kind = .uint32, .presence = .required },
        .{ .number = 3, .name = "items", .kind = .uint32, .presence = .repeated },
    });
    const Middle = Message(&.{
        .{ .number = 1, .name = "leaf", .kind = .message, .presence = .required, .message = Leaf },
    });
    const Top = Message(&.{
        .{ .number = 1, .name = "middle", .kind = .message, .presence = .optional, .message = Middle },
    });
    const bytes = "\x0a\x07\x0a\x05\x0a\x01A\x18\x06" ++
        "\x0a\x08\x0a\x06\x10\x01\x10\x02\x18\x07";
    const top = try Top.decode(bytes, no_deadline);
    const middle = (try top.get("middle", no_deadline)).?;
    const leaf = try middle.get("leaf", no_deadline);
    try testing.expectEqualStrings("A", try leaf.get("left", no_deadline));
    try testing.expectEqual(2, try leaf.get("right", no_deadline));
    var it = try leaf.get("items", no_deadline);
    try testing.expectEqual(@as(?u32, 6), try it.next(no_deadline));
    try testing.expectEqual(@as(?u32, 7), try it.next(no_deadline));
    try testing.expectEqual(null, try it.next(no_deadline));
    try testing.expectError(error.MissingRequired, Top.decode("\x0a\x07\x0a\x05\x0a\x01A\x18\x06", no_deadline));
}

test "packing fragments and unknown records are handled together" {
    const Sample = Message(&.{
        .{ .number = 1, .name = "samples", .kind = .sint32, .presence = .repeated },
        .{ .number = 2, .name = "fixed", .kind = .fixed32, .presence = .repeated, .packed_encoding = true },
        .{ .number = 3, .name = "text", .kind = .string, .presence = .optional },
    });
    const good = "\x08\x01\x0a\x02\x02\x06\x38\x01\x0a\x00\x3b\x43\x44\x3c\x08\x08";
    var it = try (try Sample.decode(good, no_deadline)).get("samples", no_deadline);
    for ([_]i32{ -1, 1, 3, 4 }) |expected| try testing.expectEqual(@as(?i32, expected), try it.next(no_deadline));
    try testing.expectEqual(null, try it.next(no_deadline));
    try testing.expectError(error.Truncated, Sample.decode("\x0a\x01\x80", no_deadline));
    try testing.expectError(error.Truncated, Sample.decode("\x12\x03ABC", no_deadline));
    try testing.expectError(error.Truncated, Sample.decode("\x1a\x80\x01", no_deadline));
    try testing.expectError(error.InvalidUtf8, Sample.decode("\x1a\x01\xff", no_deadline));
    try testing.expectError(error.InvalidWireType, Sample.decode("\x0e", no_deadline));
    try testing.expectError(error.InvalidTag, Sample.decode("\x00", no_deadline));
    try testing.expectError(error.InvalidTag, Sample.decode("\x80\x80\x80\x80\x10\x00", no_deadline));
    const expired = struct {
        pub fn expired(_: @This()) bool {
            return true;
        }
    }{};
    try testing.expectError(error.DeadlineExceeded, Sample.decode(good, expired));
}
