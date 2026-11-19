// Ported from src/mjolnir/graphtilebuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const cold = @import("../graph/cold.zig");
const format = @import("../graph/format.zig");
const names = @import("tags/names.zig");
const Allocator = std.mem.Allocator;

pub const Builder = struct {
    gpa: Allocator,
    strings: *const names.StringTable,
    deadline: io.Deadline,
    scratch: io.File,
    scratch_size: u64 = 0,
    payload_bytes: u64 = 0,
    record_count: u32 = 0,
    chunk_offsets: std.ArrayList(u64) = .empty,
    record_offsets: [cold.chunk_size + 1]u64 = undefined,
    chunk_records: usize = 0,
    chunk_bytes: std.ArrayList(u8) = .empty,
    name_ids: std.AutoHashMapUnmanaged(names.Id, u31) = .empty,
    name_order: std.ArrayList(names.Id) = .empty,

    pub fn init(gpa: Allocator, strings: *const names.StringTable, dir: []const u8, deadline: io.Deadline) !Builder {
        return .{ .gpa = gpa, .strings = strings, .deadline = deadline, .scratch = try io.File.temporary(dir) };
    }

    pub fn deinit(self: *Builder) void {
        self.name_order.deinit(self.gpa);
        self.name_ids.deinit(self.gpa);
        self.chunk_bytes.deinit(self.gpa);
        self.chunk_offsets.deinit(self.gpa);
        self.scratch.close();
    }

    pub fn nameRef(self: *Builder, id: names.Id, route: bool) !u32 {
        if (self.name_ids.get(id)) |index| return cold.nameRef(index, route);
        const index = std.math.cast(u31, self.name_order.items.len) orelse return error.TooManyStrings;
        try self.name_ids.ensureUnusedCapacity(self.gpa, 1);
        try self.name_order.append(self.gpa, id);
        self.name_ids.putAssumeCapacityNoClobber(id, index);
        return cold.nameRef(index, route);
    }

    pub fn append(self: *Builder, way_id: u64, speed_limit: u8, shape: []const format.Coordinate, refs: []const u32) !u31 {
        const id = std.math.cast(u31, self.record_count) orelse return error.TooManyColdRecords;
        if (self.chunk_records == cold.chunk_size) try self.flushChunk();
        const offset = self.chunk_bytes.items.len;
        try cold.appendRecord(&self.chunk_bytes, self.gpa, way_id, speed_limit, shape, refs, self.deadline);
        self.record_offsets[self.chunk_records] = offset;
        self.chunk_records += 1;
        self.record_count += 1;
        return id;
    }

    fn flushChunk(self: *Builder) !void {
        if (self.chunk_records == 0) return;
        if (self.deadline.expired()) return error.DeadlineExceeded;
        self.record_offsets[self.chunk_records] = self.chunk_bytes.items.len;
        const index = std.mem.sliceAsBytes(self.record_offsets[0 .. self.chunk_records + 1]);
        const end = std.math.add(u64, self.scratch_size, index.len + self.chunk_bytes.items.len) catch return error.ColdSectionTooLarge;
        if (end > std.math.maxInt(i64)) return error.ColdSectionTooLarge;
        try self.chunk_offsets.ensureUnusedCapacity(self.gpa, 1);
        try self.scratch.pwriteAll(index, self.scratch_size);
        try self.scratch.pwriteAll(self.chunk_bytes.items, self.scratch_size + index.len);
        self.scratch_size = end;
        self.chunk_offsets.appendAssumeCapacity(end);
        self.chunk_records = 0;
        self.chunk_bytes.clearRetainingCapacity();
    }

    pub fn write(self: *Builder, bundle: *format.BundleWriter) !u64 {
        try self.flushChunk();
        try bundle.stream(.cold, self, writePayload);
        return self.payload_bytes;
    }

    const Out = format.SectionWriter(.cold);
    fn writePayload(self: *Builder, out: *Out) !void {
        const directory_size = (self.chunk_offsets.items.len + 1) * @sizeOf(u64);
        const header: cold.Header = .{
            .record_count = self.record_count,
            .name_count = @intCast(self.name_order.items.len),
            .names_offset = @sizeOf(cold.Header) + directory_size + self.scratch_size,
        };
        const zero: u64 = 0;
        try out.append(std.mem.asBytes(&header));
        try out.append(std.mem.asBytes(&zero));
        try out.append(std.mem.sliceAsBytes(self.chunk_offsets.items));

        var buf: [64 * 1024]u8 = undefined;
        var pos: u64 = 0;
        while (pos < self.scratch_size) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const bytes = buf[0..@min(buf.len, self.scratch_size - pos)];
            try self.scratch.preadAll(bytes, pos);
            try out.append(bytes);
            pos += bytes.len;
        }
        try self.writeNames(out);
        self.payload_bytes = out.offset - format.payload_offset;
    }

    fn writeNames(self: *Builder, out: *Out) !void {
        defer self.chunk_bytes.clearRetainingCapacity();
        var offsets: [1024]u64 = undefined;
        offsets[0] = 0;
        var used: usize = 1;
        var offset: u64 = 0;
        for (self.name_order.items) |id| {
            offset = std.math.add(u64, offset, self.strings.get(id).?.len) catch return error.ColdSectionTooLarge;
            offsets[used] = offset;
            used += 1;
            if (used == offsets.len) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try out.append(std.mem.sliceAsBytes(&offsets));
                used = 0;
            }
        }
        try out.append(std.mem.sliceAsBytes(offsets[0..used]));

        for (self.name_order.items, 0..) |id, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            const text = self.strings.get(id).?;
            if (text.len > 64 * 1024 - self.chunk_bytes.items.len) {
                try out.append(self.chunk_bytes.items);
                self.chunk_bytes.clearRetainingCapacity();
            }
            if (text.len > 64 * 1024) {
                try out.append(text);
            } else {
                try self.chunk_bytes.appendSlice(self.gpa, text);
            }
        }
        try out.append(self.chunk_bytes.items);
    }
};
