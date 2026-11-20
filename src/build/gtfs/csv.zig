//! RFC 4180 records with UTF-8 BOM and Unix line-ending support.
const std = @import("std");
const Deadline = @import("../../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    file: []const u8 = "",
    row: usize = 0,
    column: usize = 0,
    field: []const u8 = "",

    pub fn set(self: *Diagnostic, file: []const u8, row: usize, column: usize, field: []const u8) void {
        self.* = .{ .file = file, .row = row, .column = column, .field = field };
    }
};

pub const Field = struct {
    raw: []const u8,
    escaped: bool = false,

    /// The result borrows either the input or the caller's reusable scratch.
    pub fn text(self: Field, a: Allocator, scratch: *std.ArrayList(u8), deadline: Deadline) ![]const u8 {
        if (!self.escaped) return self.raw;
        scratch.clearRetainingCapacity();
        try scratch.ensureTotalCapacity(a, self.raw.len);
        var i: usize = 0;
        var next_check: usize = 0;
        while (i < self.raw.len) : (i += 1) {
            if (i >= next_check) {
                if (deadline.expired()) return error.DeadlineExceeded;
                next_check = i +| 256;
            }
            const byte = self.raw[i];
            if (byte == '"') i += 1;
            scratch.appendAssumeCapacity(byte);
        }
        return scratch.items;
    }
};

pub const Reader = struct {
    bytes: []const u8,
    file: []const u8,
    position: usize = 0,
    row: usize = 0,

    pub fn init(bytes: []const u8, file: []const u8) Reader {
        const bom = "\xef\xbb\xbf";
        return .{
            .bytes = bytes,
            .file = file,
            .position = if (std.mem.startsWith(u8, bytes, bom)) bom.len else 0,
        };
    }

    /// Advances past one logical record. Empty records are skipped. Embedded
    /// line endings within quoted fields are retained byte for byte.
    pub fn next(self: *Reader, a: Allocator, fields: *std.ArrayList(Field), diagnostic: *Diagnostic, deadline: Deadline) !?[]const Field {
        fields.clearRetainingCapacity();
        while (self.position < self.bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            self.row += 1;
            if (!self.endLine()) break;
        } else return null;

        while (true) {
            if (fields.items.len % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const value = self.take(deadline) catch |err| switch (err) {
                error.DeadlineExceeded => return err,
                error.InvalidQuote => {
                    diagnostic.set(self.file, self.row, fields.items.len + 1, "");
                    return err;
                },
            };
            try fields.append(a, value);
            if (self.position == self.bytes.len or self.endLine()) return fields.items;
            // take leaves the cursor at a field separator, line ending or EOF.
            self.position += 1;
        }
    }

    fn take(self: *Reader, deadline: Deadline) error{ InvalidQuote, DeadlineExceeded }!Field {
        const start = self.position;
        if (start == self.bytes.len) return .{ .raw = self.bytes[start..] };
        if (self.bytes[start] != '"') {
            self.position = try find(self.bytes, start, ",\r\n\"", deadline);
            if (self.position < self.bytes.len and self.bytes[self.position] == '"') return error.InvalidQuote;
            return .{ .raw = self.bytes[start..self.position] };
        }

        var cursor = start + 1;
        var escaped = false;
        while (true) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const quote = try find(self.bytes, cursor, "\"", deadline);
            if (quote == self.bytes.len) return error.InvalidQuote;
            cursor = quote + 1;
            if (cursor == self.bytes.len or separator(self.bytes[cursor])) {
                self.position = cursor;
                return .{ .raw = self.bytes[start + 1 .. quote], .escaped = escaped };
            }
            if (self.bytes[cursor] != '"') return error.InvalidQuote;
            escaped = true;
            cursor += 1;
        }
    }

    fn endLine(self: *Reader) bool {
        switch (self.bytes[self.position]) {
            '\n' => self.position += 1,
            '\r' => {
                self.position += 1;
                if (self.position < self.bytes.len and self.bytes[self.position] == '\n') self.position += 1;
            },
            else => return false,
        }
        return true;
    }
};

fn separator(byte: u8) bool {
    return byte == ',' or byte == '\r' or byte == '\n';
}

fn find(bytes: []const u8, start: usize, choices: []const u8, deadline: Deadline) error{DeadlineExceeded}!usize {
    var offset = start;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset +| 4096);
        if (std.mem.findAny(u8, bytes[offset..end], choices)) |pos| return offset + pos;
        offset = end;
        if (deadline.expired()) return error.DeadlineExceeded;
    }
    return offset;
}

pub const Part = struct {
    bytes: []const u8,
    row_offset: usize,
    records: usize,
};

/// Splits at logical record boundaries and counts records ahead of the
/// parallel parser. The count includes blank rows for stable diagnostics.
pub fn partition(a: Allocator, bytes: []const u8, workers: usize, deadline: Deadline) ![]Part {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (bytes.len == 0) return &.{};
    const target = (bytes.len - 1) / @max(1, workers) + 1;
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(a);
    if (try find(bytes, 0, "\r\"", deadline) == bytes.len) {
        var start: usize = 0;
        var rows_before: usize = 0;
        while (start < bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const newline = try find(bytes, @min(bytes.len, start +| target - 1), "\n", deadline);
            const end = @min(bytes.len, newline +| 1);
            const data = bytes[start..end];
            var records: usize = @intFromBool(data[data.len - 1] != '\n');
            var offset: usize = 0;
            while (offset < data.len) {
                if (deadline.expired()) return error.DeadlineExceeded;
                const limit = @min(data.len, offset +| 64 * 1024);
                records += std.mem.countScalar(u8, data[offset..limit], '\n');
                offset = limit;
            }
            try parts.append(a, .{ .bytes = data, .row_offset = rows_before, .records = records });
            rows_before += records;
            start = end;
        }
    } else {
        var start: usize = 0;
        var cursor: usize = 0;
        var last_end: usize = 0;
        var rows_before: usize = 0;
        var records: usize = 0;
        var quoted = false;
        while (cursor < bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const special = try find(bytes, cursor, "\r\n\"", deadline);
            if (special == bytes.len) break;
            cursor = special + 1;
            if (bytes[special] == '"') {
                quoted = !quoted;
            } else if (!quoted) {
                if (bytes[special] == '\r' and cursor < bytes.len and bytes[cursor] == '\n') cursor += 1;
                records += 1;
                last_end = cursor;
                if (cursor - start >= target) {
                    try parts.append(a, .{ .bytes = bytes[start..cursor], .row_offset = rows_before, .records = records });
                    rows_before += records;
                    records = 0;
                    start = cursor;
                }
            }
        }
        if (start < bytes.len) {
            if (last_end < bytes.len) records += 1;
            try parts.append(a, .{ .bytes = bytes[start..], .row_offset = rows_before, .records = records });
        }
    }
    return parts.toOwnedSlice(a);
}

test "CSV reads BOM, quoted separators, escaped quotes and embedded lines" {
    const a = std.testing.allocator;
    var reader = Reader.init("\xef\xbb\xbf" ++ "name,id,comment\r\n\"A, B\",10,\"a\"\"b\r\nline\"\r\n\r\nC,20,", "stops.txt");
    var diagnostic: Diagnostic = .{};
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(a);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    const header = (try reader.next(a, &fields, &diagnostic, .none)).?;
    try std.testing.expectEqualStrings("comment", header[2].raw);
    const quoted = (try reader.next(a, &fields, &diagnostic, .none)).?;
    try std.testing.expectEqualStrings("A, B", quoted[0].raw);
    try std.testing.expectEqualStrings("a\"b\r\nline", try quoted[2].text(a, &scratch, .none));
    const last = (try reader.next(a, &fields, &diagnostic, .none)).?;
    try std.testing.expectEqualStrings("C", last[0].raw);
    try std.testing.expectEqualStrings("", last[2].raw);
    try std.testing.expectEqual(null, try reader.next(a, &fields, &diagnostic, .none));
}

test "CSV quote errors identify the file, record and field" {
    const a = std.testing.allocator;
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(a);
    for ([_][]const u8{ "a,b\nx,\"no end", "a,b\nx,\"closed\"junk", "a,b\nx,un\"quoted" }) |bytes| {
        var diagnostic: Diagnostic = .{};
        var reader = Reader.init(bytes, "agency.txt");
        _ = try reader.next(a, &fields, &diagnostic, .none);
        try std.testing.expectError(error.InvalidQuote, reader.next(a, &fields, &diagnostic, .none));
        try std.testing.expectEqualStrings("agency.txt", diagnostic.file);
        try std.testing.expectEqual(2, diagnostic.row);
        try std.testing.expectEqual(2, diagnostic.column);
    }
}
