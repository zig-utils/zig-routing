//! Writer-owned observation times, indexed by live traffic slot.
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("../graph/format.zig");
const live = @import("live.zig");
const Allocator = std.mem.Allocator;

pub const filename = "traffic-expiry.bin";
const magic = "ZRAGE\x00\x00\x00".*;
const version: u32 = 1;
const interrupted_epoch = std.math.maxInt(u64);

pub const Header = extern struct {
    magic_tag: [8]u8 = magic,
    dataset_uuid: format.DatasetUuid,
    format_version: u32 = version,
    count: u32,
    epoch: u64,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 40 and @alignOf(Header) == 8);
    std.debug.assert(@offsetOf(Header, "magic_tag") == 0 and @offsetOf(Header, "dataset_uuid") == 8 and
        @offsetOf(Header, "format_version") == 24 and @offsetOf(Header, "count") == 28 and @offsetOf(Header, "epoch") == 32);
}

pub const Ages = struct {
    mapping: io.Mapping,
    header: *Header,
    observed: []u64,
    earliest: []u64,
    needs_reindex: bool = false,
    oldest: u64 = 0,
    gpa: Allocator,

    /// The caller holds the live-overlay writer lock for this mapping's lifetime.
    pub fn open(a: Allocator, dir: io.Directory, overlay: live.View, deadline: io.Deadline) !Ages {
        const file = dir.readWriteFile(filename) catch |err| switch (err) {
            error.FileNotFound => return create(a, dir, overlay, deadline),
            else => return err,
        };
        defer file.close();
        const mapping = try io.Mapping.mapFd(file, .shared_writable);
        errdefer mapping.unmap();
        var ages = try parse(a, mapping, overlay);
        errdefer a.free(ages.earliest);
        ages.needs_reindex = true;
        try ages.prepare(overlay, deadline);
        return ages;
    }

    fn create(a: Allocator, dir: io.Directory, overlay: live.View, deadline: io.Deadline) !Ages {
        const staged = try dir.temporaryFile();
        defer staged.file.close();
        errdefer dir.deleteFile(&staged.name) catch {};
        try staged.file.truncate(try size(overlay.records.len));
        const mapping = try io.Mapping.mapFd(staged.file, .shared_writable);
        errdefer mapping.unmap();
        const metadata = overlay.metadata();
        const header = &(try mapping.sliceMut(Header, 0, 1))[0];
        header.* = .{
            .dataset_uuid = overlay.header.dataset_uuid,
            .count = @intCast(overlay.records.len),
            .epoch = if (metadata) |m| m.epoch else interrupted_epoch,
        };
        var ages = try parse(a, mapping, overlay);
        errdefer a.free(ages.earliest);
        const timestamp = if (metadata) |m| m.last_update else 1;
        for (ages.observed, 0..) |*stamp, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const record = overlay.load(@fromBackingInt(@as(u32, @intCast(i)))).?;
            stamp.* = if (record.validSpeed()) @max(timestamp, 1) else 0;
        }
        try ages.reindex(overlay, false, deadline);
        try staged.file.sync();
        if (deadline.expired()) return error.DeadlineExceeded;
        try dir.renameExclusive(&staged.name, filename);
        try dir.sync();
        return ages;
    }

    pub fn validate(bytes: []const u8, uuid: format.DatasetUuid, count: usize) !void {
        const header = &(try io.typedSlice(Header, bytes, 0, 1))[0];
        if (!std.mem.eql(u8, &header.magic_tag, &magic) or header.format_version != version)
            return error.InvalidTrafficExpiryHeader;
        if (!std.mem.eql(u8, &header.dataset_uuid, &uuid)) return error.TrafficExpiryDatasetUuidMismatch;
        if (header.count != count or bytes.len != try size(count)) return error.InvalidTrafficExpiryLength;
    }

    fn parse(a: Allocator, mapping: io.Mapping, overlay: live.View) !Ages {
        try validate(mapping.bytes, overlay.header.dataset_uuid, overlay.records.len);
        return .{
            .mapping = mapping,
            .header = &(try mapping.sliceMut(Header, 0, 1))[0],
            .observed = try mapping.sliceMut(u64, @sizeOf(Header), overlay.records.len),
            .earliest = try a.alloc(u64, overlay.blocks.len),
            .gpa = a,
        };
    }

    fn size(records: usize) !usize {
        const payload = std.math.mul(usize, records, @sizeOf(u64)) catch return error.TrafficExpirySizeOverflow;
        return std.math.add(usize, @sizeOf(Header), payload) catch return error.TrafficExpirySizeOverflow;
    }

    pub fn close(self: Ages) void {
        self.mapping.unmap();
        self.gpa.free(self.earliest);
    }

    pub fn prepare(self: *Ages, overlay: live.View, deadline: io.Deadline) !void {
        const epoch = if (overlay.metadata()) |metadata| metadata.epoch else interrupted_epoch;
        const incomplete = self.header.epoch != epoch;
        if (self.needs_reindex or incomplete) try self.reindex(overlay, incomplete, deadline);
        self.header.epoch = epoch;
    }

    fn reindex(self: *Ages, overlay: live.View, repair: bool, deadline: io.Deadline) !void {
        self.needs_reindex = true;
        self.oldest = 0;
        for (overlay.blocks, self.earliest, 0..) |block, *minimum, group| {
            if (group % 16 == 0 and deadline.expired()) return error.DeadlineExceeded;
            minimum.* = 0;
            const slots = self.observed[block.first..][0..@popCount(block.mask)];
            for (slots, block.first..) |*timestamp, index| {
                if (repair) {
                    const record = overlay.load(@fromBackingInt(@as(u32, @intCast(index)))).?;
                    timestamp.* = if (record.validSpeed()) @max(timestamp.*, 1) else 0;
                }
                minimum.* = minTime(minimum.*, timestamp.*);
            }
            self.oldest = minTime(self.oldest, minimum.*);
        }
        self.needs_reindex = false;
    }

    pub fn update(self: *Ages, slot: live.Slot, edge: format.EdgeId, timestamp: u64) void {
        self.observed[@backingInt(slot)] = timestamp;
        const minimum = &self.earliest[@backingInt(edge) >> 6];
        minimum.* = minTime(minimum.*, timestamp);
        self.oldest = minTime(self.oldest, timestamp);
    }

    pub fn refreshDue(self: *Ages, overlay: live.View, now: u64, max_age: u64, deadline: io.Deadline) !void {
        if (!isDue(self.oldest, now, max_age)) return;
        self.needs_reindex = true;
        self.oldest = 0;
        for (overlay.blocks, self.earliest, 0..) |block, *minimum, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (isDue(minimum.*, now, max_age)) {
                minimum.* = 0;
                const times = self.observed[block.first..][0..@popCount(block.mask)];
                for (times) |timestamp| minimum.* = minTime(minimum.*, timestamp);
            }
            self.oldest = minTime(self.oldest, minimum.*);
        }
        self.needs_reindex = false;
    }
};

fn minTime(left: u64, right: u64) u64 {
    if (left == 0) return right;
    if (right == 0) return left;
    return @min(left, right);
}

pub fn isDue(timestamp: u64, now: u64, max_age: u64) bool {
    return timestamp != 0 and now > timestamp and now - timestamp > max_age;
}
