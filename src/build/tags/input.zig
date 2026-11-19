//! Per-worker tag storage shared by PBF and XML transforms.

const std = @import("std");
const io = @import("../../infra/io.zig");
const pbf = @import("../pbf/root.zig");
const osm = @import("../osm.zig");
const table = @import("table.zig");
const Key = table.Key;
const Value = table.Value;
const TagValue = table.TagValue;
const key_count = @typeInfo(Key).@"enum".field_names.len;

pub const Iterator = union(enum) {
    pbf: pbf.block.TagIterator,
    slice: []const osm.Tag,

    pub fn init(tags: anytype, deadline: io.Deadline) Iterator {
        if (@TypeOf(tags) == pbf.block.TagIterator) {
            var iter = tags;
            iter.deadline = iter.deadline.min(deadline);
            return .{ .pbf = iter };
        }
        return .{ .slice = tags };
    }

    pub fn next(self: *Iterator) pbf.block.Error!?osm.Tag {
        return switch (self.*) {
            .pbf => |*iter| iter.next(),
            .slice => |*remaining| if (remaining.len == 0) null else blk: {
                const tag = remaining.*[0];
                remaining.* = remaining.*[1..];
                break :blk tag;
            },
        };
    }
};

pub const Scratch = struct {
    values: [key_count]?TagValue = @splat(null),
    touched: [key_count]Key = undefined,
    count: usize = 0,

    /// Values borrow input strings. Reusing the scratch clears its index.
    /// Previously returned string slices remain valid while input lives.
    pub fn load(self: *Scratch, tags: anytype, deadline: io.Deadline) pbf.block.Error!void {
        for (self.touched[0..self.count]) |key| self.values[@backingInt(key)] = null;
        self.count = 0;
        if (deadline.expired()) return error.DeadlineExceeded;
        var iter = Iterator.init(tags, deadline);
        var count: usize = 0;
        while (try iter.next()) |tag| : (count += 1) {
            if (count % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            self.put(tag);
        }
    }

    fn put(self: *Scratch, tag: osm.Tag) void {
        const key = table.key(tag.key) orelse return;
        const entry = &self.values[@backingInt(key)];
        if (entry.* == null) {
            self.touched[self.count] = key;
            self.count += 1;
        }
        // Lua table assignment keeps the last occurrence of a key.
        entry.* = TagValue.init(tag.value);
    }

    pub fn get(self: *const Scratch, key: Key) ?TagValue {
        return self.values[@backingInt(key)];
    }

    pub fn id(self: *const Scratch, key: Key) ?Value {
        return (self.get(key) orelse return null).known();
    }

    pub fn text(self: *const Scratch, key: Key) ?[]const u8 {
        return (self.get(key) orelse return null).text();
    }
};

pub fn contains(text: []const u8, needle: []const u8, ignore_case: bool, deadline: io.Deadline) !bool {
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const part = text[i..][0..needle.len];
        if (if (ignore_case) std.ascii.eqlIgnoreCase(part, needle) else std.mem.eql(u8, part, needle))
            return true;
    }
    return false;
}
