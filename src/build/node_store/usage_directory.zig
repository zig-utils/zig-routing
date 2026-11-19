//! Sequential checkpoint encoding for an append-only usage radix directory.
//! A branch stores its occupied slot gaps and one-based child IDs as varints.
const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../../infra/io.zig");

pub const Branch = [256]u64;
pub const magic = "ZRUDIR01".*;
const header_bytes = magic.len + @sizeOf(u64);
const max_child = std.math.maxInt(i64) / @sizeOf(Branch);
const max_record_bytes = 2 + @typeInfo(Branch).array.len * (2 + 10);
const batch = 64;

pub const DirectoryReader = struct {
    input: wire.Reader,
    remaining: u64,

    pub fn init(bytes: []const u8) !DirectoryReader {
        if (bytes.len < header_bytes or !std.mem.startsWith(u8, bytes, &magic)) return error.InvalidUsageDirectory;
        const branches = std.mem.readInt(u64, bytes[magic.len..][0..@sizeOf(u64)], .little);
        if (branches == 0 or branches > max_child or branches > bytes.len - header_bytes) return error.InvalidUsageDirectory;
        return .{ .input = .init(bytes[header_bytes..]), .remaining = branches };
    }

    pub fn next(self: *DirectoryReader, branch: *Branch) !bool {
        if (self.remaining == 0) {
            if (self.input.remaining.len != 0) return error.InvalidUsageDirectory;
            return false;
        }
        const count = try self.input.readVarint();
        if (count > branch.len) return error.InvalidUsageDirectory;
        branch.* = @splat(0);
        var slot: usize = 0;
        for (0..count) |_| {
            const gap = try self.input.readVarint();
            if (gap >= branch.len - slot) return error.InvalidUsageDirectory;
            slot += @intCast(gap);
            const value = try self.input.readVarint();
            if (value == 0 or value > max_child) return error.InvalidUsageDirectory;
            branch[slot] = value;
            slot += 1;
        }
        self.remaining -= 1;
        return true;
    }
};

pub fn write(source: io.File, output: io.File, deadline: io.Deadline) !void {
    const size = try source.size();
    if (size == 0 or size % @sizeOf(Branch) != 0) return error.InvalidUsageDirectory;
    var branches: [batch]Branch = undefined;
    var buffer: [128 * 1024]u8 = undefined;
    var writer: io.Writer = .fixed(&buffer);
    try writer.writeAll(&magic);
    try wire.writeFixed(u64, &writer, size / @sizeOf(Branch));
    var written: u64 = 0;
    var read: u64 = 0;
    while (read < size) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const n: usize = @intCast(@min((size - read) / @sizeOf(Branch), branches.len));
        const input = std.mem.sliceAsBytes(branches[0..n]);
        try source.preadAll(input, read);
        read += input.len;
        for (branches[0..n]) |*branch| {
            if (buffer.len - writer.end < max_record_bytes) {
                try output.pwriteAll(writer.buffered(), written);
                written += writer.end;
                writer.end = 0;
            }
            var count: u64 = 0;
            for (branch) |child| count += @intFromBool(child != 0);
            try wire.writeVarint(&writer, count);
            var next: usize = 0;
            for (branch, 0..) |child, i| {
                if (child == 0) continue;
                try wire.writeVarint(&writer, i - next);
                try wire.writeVarint(&writer, child);
                next = i + 1;
            }
        }
    }
    try output.pwriteAll(writer.buffered(), written);
    try output.truncate(written + writer.end);
}

/// Returns false for a checkpoint created before the compact encoding.
pub fn restore(source: io.File, output: io.File, max_branches: u64, deadline: io.Deadline) !bool {
    var prefix: [magic.len]u8 = undefined;
    if (try source.size() < prefix.len) return false;
    try source.preadAll(&prefix, 0);
    if (!std.mem.eql(u8, &prefix, &magic)) return false;
    const mapping = try io.Mapping.mapFd(source, .read_only);
    defer mapping.unmap();
    var reader = try DirectoryReader.init(mapping.bytes);
    if (reader.remaining > max_branches) return error.InvalidUsageDirectory;
    var branches: [batch]Branch = undefined;
    var written: u64 = 0;
    while (true) {
        if (deadline.expired()) return error.DeadlineExceeded;
        var count: usize = 0;
        while (count < branches.len and try reader.next(&branches[count])) : (count += 1) {}
        const bytes = std.mem.sliceAsBytes(branches[0..count]);
        try output.pwriteAll(bytes, written);
        written += bytes.len;
        if (count < branches.len) break;
    }
    try output.truncate(written);
    return true;
}

test "compact usage directories round trip and bound their expansion" {
    const raw = try io.File.temporary(".");
    defer raw.close();
    const encoded = try io.File.temporary(".");
    defer encoded.close();
    const restored = try io.File.temporary(".");
    defer restored.close();
    var source: [2]Branch = @splat(@splat(0));
    source[0][1] = 2;
    source[1][128] = 1;
    source[1][255] = 23_456;
    try raw.pwriteAll(std.mem.asBytes(&source), 0);
    try write(raw, encoded, .none);
    try std.testing.expect(try encoded.size() < @sizeOf(@TypeOf(source)));
    try std.testing.expectError(error.InvalidUsageDirectory, restore(encoded, restored, 1, .none));
    try std.testing.expect(try restore(encoded, restored, 2, .none));
    var copy: [2]Branch = undefined;
    try restored.preadAll(std.mem.asBytes(&copy), 0);
    try std.testing.expectEqual(source, copy);
    try std.testing.expect(!try restore(raw, restored, 2, .none));
}
