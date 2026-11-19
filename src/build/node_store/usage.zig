//! Disk-backed node usage bitplanes. A sparse radix directory allocates
//! leaves only for ID ranges used by ways; the in-memory cache is fixed-size.

const std = @import("std");
const io = @import("../../infra/io.zig");

const leaf_bits = 8;
const leaf_size = 1 << leaf_bits;
const radix = 256;
const levels = (64 - leaf_bits) / 8;
const cache_size = 512;

pub const Coordinates = extern struct {
    lat: i32,
    lon: i32,
};

const Leaf = extern struct {
    low: [leaf_size / 64]u64 = @splat(0),
    high: [leaf_size / 64]u64 = @splat(0),
    // Used only by the unsorted path to distinguish missing nodes.
    located: [leaf_size / 64]u64 = @splat(0),
};

const Branch = [radix]u64;
const empty_branch: Branch = @splat(0);

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Coordinates) == 8 and @offsetOf(Coordinates, "lon") == 4);
    std.debug.assert(@sizeOf(Leaf) == 96 and @offsetOf(Leaf, "high") == 32 and @offsetOf(Leaf, "located") == 64);
}

const Slot = struct {
    key: u64 = 0,
    page: u64 = 0,
    known: bool = false,
    dirty: bool = false,
    data: Leaf = .{},
};

const Bits = struct {
    word: usize,
    bit: u64,

    fn init(index: u8) Bits {
        return .{ .word = index / 64, .bit = @as(u64, 1) << @as(u6, @truncate(index)) };
    }

    fn count(self: Bits, leaf: *const Leaf) u2 {
        const low: u2 = @intFromBool(leaf.low[self.word] & self.bit != 0);
        const high: u2 = @intFromBool(leaf.high[self.word] & self.bit != 0);
        return low | (high << 1);
    }
};

/// The numeric order matches osm.inOrder for a fixed primitive type. There
/// is one key for every i64, including minInt and the negative-ID namespace.
pub fn keyFor(id: i64) u64 {
    return if (id <= 0) @abs(id) else (@as(u64, 1) << 63) | @as(u64, @intCast(id));
}

pub const Usage = struct {
    dir: io.File,
    leaves: io.File,
    branches: u64 = 1,
    pages: u64 = 0,
    cache: [cache_size]Slot = @splat(.{}),

    pub fn init(scratch_dir: []const u8) !Usage {
        const dir = try io.File.temporary(scratch_dir);
        errdefer dir.close();
        const leaves = try io.File.temporary(scratch_dir);
        errdefer leaves.close();
        try dir.pwriteAll(std.mem.asBytes(&empty_branch), 0);
        return .{ .dir = dir, .leaves = leaves };
    }

    pub fn deinit(self: *Usage) void {
        self.leaves.close();
        self.dir.close();
    }

    pub fn mark(self: *Usage, key: u64) !void {
        const slot = (try self.get(key >> leaf_bits, true)).?;
        const bits: Bits = .init(@truncate(key));
        const before = bits.count(&slot.data);
        if (before == 3) return;
        if (before == 1) {
            slot.data.low[bits.word] &= ~bits.bit;
            slot.data.high[bits.word] |= bits.bit;
        } else {
            slot.data.low[bits.word] |= bits.bit;
        }
        slot.dirty = true;
    }

    pub fn count(self: *Usage, key: u64) !u2 {
        const slot = try self.get(key >> leaf_bits, false) orelse return 0;
        return (Bits.init(@truncate(key))).count(&slot.data);
    }

    /// Set membership without incrementing an existing count.
    pub fn insert(self: *Usage, key: u64) !bool {
        const slot = (try self.get(key >> leaf_bits, true)).?;
        const bits: Bits = .init(@truncate(key));
        if (bits.count(&slot.data) != 0) return false;
        slot.data.low[bits.word] |= bits.bit;
        slot.dirty = true;
        return true;
    }

    /// Finish writes before creating independent concurrent cursors. The
    /// owner keeps the files open and immutable while a cursor is in use.
    pub fn freeze(self: *Usage, deadline: io.Deadline) !View {
        try self.flushAll(deadline);
        return .{ .dir = self.dir, .leaves = self.leaves };
    }

    pub const View = struct {
        dir: io.File,
        leaves: io.File,

        pub fn cursor(self: View) Cursor {
            return .{ .usage = .{ .dir = self.dir, .leaves = self.leaves } };
        }
    };

    pub const Cursor = struct {
        usage: Usage,

        pub fn contains(self: *Cursor, key: u64) !bool {
            return (try self.usage.count(key)) != 0;
        }
    };

    /// Save by ID when the source is unsorted. One position slot per used
    /// leaf index. This never creates entries for unreferenced nodes.
    pub fn locate(self: *Usage, positions: io.File, key: u64, coordinates: Coordinates) !bool {
        const slot = try self.get(key >> leaf_bits, false) orelse return false;
        const index: u8 = @truncate(key);
        const bits: Bits = .init(index);
        if (bits.count(&slot.data) == 0) return false;
        if (slot.data.located[bits.word] & bits.bit != 0) return error.DuplicateNode;
        try positions.pwriteAll(std.mem.asBytes(&coordinates), try positionOffset(slot.page, index));
        slot.data.located[bits.word] |= bits.bit;
        slot.dirty = true;
        return true;
    }

    pub fn emitLocated(self: *Usage, positions: io.File, deadline: io.Deadline, context: anytype, comptime emit: anytype) !void {
        try self.flushAll(deadline);
        try self.emitBranch(0, 0, levels, positions, deadline, context, emit);
    }

    fn flushAll(self: *Usage, deadline: io.Deadline) !void {
        for (&self.cache) |*slot| {
            if (deadline.expired()) return error.DeadlineExceeded;
            try self.flush(slot);
        }
    }

    fn emitBranch(self: *const Usage, branch: u64, prefix: u64, level: usize, positions: io.File, deadline: io.Deadline, context: anytype, comptime emit: anytype) !void {
        var children: Branch = undefined;
        try self.dir.preadAll(std.mem.asBytes(&children), branch * @sizeOf(Branch));
        for (children, 0..) |child, index| {
            if (child == 0) continue;
            if (deadline.expired()) return error.DeadlineExceeded;
            const key = (prefix << 8) | index;
            if (level != 1) {
                try self.emitBranch(child - 1, key, level - 1, positions, deadline, context, emit);
                continue;
            }
            var leaf: Leaf = undefined;
            try self.leaves.preadAll(std.mem.asBytes(&leaf), (child - 1) * @sizeOf(Leaf));
            for (leaf.located, 0..) |located, word| {
                var bits = located;
                while (bits != 0) : (bits &= bits - 1) {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    const offset: u8 = @intCast(word * 64 + @ctz(bits));
                    var coordinates: Coordinates = undefined;
                    try positions.preadAll(std.mem.asBytes(&coordinates), try positionOffset(child, offset));
                    try emit(context, (key << leaf_bits) | offset, coordinates, (Bits.init(offset)).count(&leaf));
                }
            }
        }
    }

    fn positionOffset(page: u64, index: u8) !u64 {
        const span = leaf_size * @sizeOf(Coordinates);
        if (page - 1 > (std.math.maxInt(i64) - span) / span) return error.StoreTooLarge;
        return (page - 1) * span + @as(u64, index) * @sizeOf(Coordinates);
    }

    fn flush(self: *Usage, slot: *Slot) !void {
        if (!slot.dirty) return;
        try self.leaves.pwriteAll(std.mem.asBytes(&slot.data), (slot.page - 1) * @sizeOf(Leaf));
        slot.dirty = false;
    }

    fn get(self: *Usage, key: u64, create: bool) !?*Slot {
        const index = (key ^ (key >> 9) ^ (key >> 18)) % cache_size;
        const slot = &self.cache[index];
        if (slot.known and slot.key == key) {
            if (slot.page != 0) return slot;
            if (!create) return null;
        }
        const page = try self.find(key, create);
        try self.flush(slot);
        if (page == 0) {
            slot.* = .{ .key = key, .known = true };
            return null;
        }
        var leaf: Leaf = undefined;
        try self.leaves.preadAll(std.mem.asBytes(&leaf), (page - 1) * @sizeOf(Leaf));
        slot.* = .{ .key = key, .page = page, .known = true, .data = leaf };
        return slot;
    }

    fn find(self: *Usage, key: u64, create: bool) !u64 {
        var branch: u64 = 0;
        var remaining: usize = levels;
        while (remaining != 0) {
            remaining -= 1;
            const index: u8 = @truncate(key >> @as(u6, @intCast(remaining * 8)));
            const offset = branch * @sizeOf(Branch) + @as(u64, index) * @sizeOf(u64);
            var child: u64 = undefined;
            try self.dir.preadAll(std.mem.asBytes(&child), offset);
            if (child == 0) {
                if (!create) return 0;
                if (remaining == 0) {
                    if (self.pages >= std.math.maxInt(i64) / @sizeOf(Leaf)) return error.StoreTooLarge;
                    const empty: Leaf = .{};
                    try self.leaves.pwriteAll(std.mem.asBytes(&empty), self.pages * @sizeOf(Leaf));
                    self.pages += 1;
                    child = self.pages;
                } else {
                    if (self.branches >= std.math.maxInt(i64) / @sizeOf(Branch)) return error.StoreTooLarge;
                    try self.dir.pwriteAll(std.mem.asBytes(&empty_branch), self.branches * @sizeOf(Branch));
                    self.branches += 1;
                    child = self.branches;
                }
                try self.dir.pwriteAll(std.mem.asBytes(&child), offset);
            }
            branch = child - 1;
        }
        return branch + 1;
    }
};
