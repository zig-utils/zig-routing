// Ported from valhalla/baldr/traffictile.h (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("../graph/format.zig");
const speed = @import("../graph/speed.zig");
const constants = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;

pub const filename = "traffic-live.bin";
pub const default_max_age_seconds = 300;
pub const unknown_speed: u7 = speed.unknown_traffic_speed;
pub const unknown_congestion: u6 = 0;
pub const max_congestion: u6 = 63;
const magic = "ZRLIVE\x00\x00".*;
const version: u32 = 1;
pub const Subsegment = enum { first, second, third };

pub const Record = packed struct(u64) {
    overall: u7 = unknown_speed,
    speed1: u7 = unknown_speed,
    speed2: u7 = unknown_speed,
    speed3: u7 = unknown_speed,
    breakpoint1: u8 = 0,
    breakpoint2: u8 = 0,
    congestion1: u6 = unknown_congestion,
    congestion2: u6 = unknown_congestion,
    congestion3: u6 = unknown_congestion,
    has_incidents: bool = false,
    reserved: bool = false,

    pub const unknown: Record = .{};

    pub fn validSpeed(self: Record) bool {
        return self.breakpoint1 != 0 and self.overall != unknown_speed;
    }

    pub fn closed(self: Record) bool {
        return self.breakpoint1 != 0 and self.overall == 0;
    }

    pub fn subsegmentClosed(self: Record, segment: Subsegment) bool {
        if (!self.validSpeed()) return false;
        return switch (segment) {
            .first => self.speed1 == 0 or self.congestion1 == max_congestion,
            .second => self.breakpoint1 < 255 and (self.speed2 == 0 or self.congestion2 == max_congestion),
            .third => self.breakpoint2 < 255 and (self.speed3 == 0 or self.congestion3 == max_congestion),
        };
    }

    pub fn overallKph(self: Record) u8 {
        return @as(u8, self.overall) << 1;
    }

    pub fn subsegmentKph(self: Record, segment: Subsegment) u8 {
        const encoded: u7 = if (self.validSpeed()) switch (segment) {
            .first => self.speed1,
            .second => self.speed2,
            .third => self.speed3,
        } else unknown_speed;
        return @as(u8, encoded) << 1;
    }

    fn observation(self: Record) ?speed.Live {
        if (!self.validSpeed()) return null;
        return .{
            .overall = self.overall,
            .segments = .{ self.speed1, self.speed2, self.speed3 },
            .breakpoints = .{ self.breakpoint1, self.breakpoint2 },
        };
    }

    fn maxKph(self: Record) u8 {
        if (!self.validSpeed()) return 0;
        var maximum = self.overall;
        for ([_]u7{ self.speed1, self.speed2, self.speed3 }) |part|
            if (part != unknown_speed) {
                maximum = @max(maximum, part);
            };
        return @as(u8, maximum) << 1;
    }
};

pub const Header = extern struct {
    tag: [8]u8 = magic,
    dataset_uuid: format.DatasetUuid,
    version: u32,
    edge_count: u32,
    record_count: u32,
    reserved: u32 = 0,
    sequence: u64 = 0,
    last_update: u64 = 0,
    live_to_bound_bits: u64 = @bitCast(@as(f64, 1)),
};

pub const RankBlock = extern struct {
    mask: u64 = 0,
    first: u32,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Record) == 8 and @bitSizeOf(Record) == 64);
    std.debug.assert(@bitOffsetOf(Record, "overall") == 0 and @bitOffsetOf(Record, "speed3") == 21);
    std.debug.assert(@bitOffsetOf(Record, "breakpoint1") == 28 and @bitOffsetOf(Record, "breakpoint2") == 36);
    std.debug.assert(@bitOffsetOf(Record, "congestion1") == 44 and @bitOffsetOf(Record, "has_incidents") == 62);
    std.debug.assert(@sizeOf(Header) == 64 and @alignOf(Header) == 8);
    std.debug.assert(@offsetOf(Header, "dataset_uuid") == 8 and @offsetOf(Header, "version") == 24 and
        @offsetOf(Header, "edge_count") == 28 and @offsetOf(Header, "record_count") == 32 and @offsetOf(Header, "reserved") == 36);
    std.debug.assert(@offsetOf(Header, "sequence") == 40 and @offsetOf(Header, "last_update") == 48 and @offsetOf(Header, "live_to_bound_bits") == 56);
    std.debug.assert(@sizeOf(RankBlock) == 16 and @offsetOf(RankBlock, "mask") == 0 and
        @offsetOf(RankBlock, "first") == 8 and @offsetOf(RankBlock, "reserved") == 12);
}

const Layout = struct {
    block_count: usize,
    records_offset: usize,
    size: usize,

    fn init(edges: u32, records: u32) !Layout {
        const blocks = (@as(u64, edges) + 63) / 64;
        const offset = @sizeOf(Header) + blocks * @sizeOf(RankBlock);
        const bytes = offset + @as(u64, records) * @sizeOf(u64);
        return .{
            .block_count = @intCast(blocks),
            .records_offset = std.math.cast(usize, offset) orelse return error.LiveTrafficSizeOverflow,
            .size = std.math.cast(usize, bytes) orelse return error.LiveTrafficSizeOverflow,
        };
    }
};

pub const Metadata = struct {
    epoch: u64,
    last_update: u64,
    live_to_bound: f64,
};

pub const Slot = enum(u32) { _ };

pub const View = struct {
    header: *const Header,
    blocks: []const RankBlock,
    records: []const u64,

    pub fn parse(bytes: []const u8, uuid: format.DatasetUuid, edge_count: usize, deadline: io.Deadline) !View {
        if (deadline.expired()) return error.DeadlineExceeded;
        const view_header = &(try io.typedSlice(Header, bytes, 0, 1))[0];
        if (!std.mem.eql(u8, &view_header.tag, &magic) or view_header.version != version or view_header.reserved != 0)
            return error.InvalidLiveTrafficHeader;
        if (!std.mem.eql(u8, &view_header.dataset_uuid, &uuid)) return error.LiveTrafficDatasetUuidMismatch;
        if (view_header.edge_count != edge_count or view_header.record_count > edge_count)
            return error.LiveTrafficEdgeCountMismatch;
        const layout = try Layout.init(view_header.edge_count, view_header.record_count);
        if (bytes.len != layout.size) return error.InvalidLiveTrafficLength;
        const blocks = try io.typedSlice(RankBlock, bytes, @sizeOf(Header), layout.block_count);
        var count: u32 = 0;
        const last_bits: u6 = @truncate(view_header.edge_count);
        for (blocks, 0..) |block, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (block.first != count or block.reserved != 0 or
                (i + 1 == blocks.len and last_bits != 0 and block.mask >> last_bits != 0))
                return error.InvalidLiveTrafficBitmap;
            count += @popCount(block.mask);
        }
        if (count != view_header.record_count) return error.InvalidLiveTrafficBitmap;
        if (!validRatio(@bitCast(@atomicLoad(u64, &view_header.live_to_bound_bits, .seq_cst))))
            return error.InvalidLiveTrafficRatio;
        return .{
            .header = view_header,
            .blocks = blocks,
            .records = try io.typedSlice(u64, bytes, layout.records_offset, view_header.record_count),
        };
    }

    pub inline fn slot(self: View, edge: format.EdgeId) ?Slot {
        const id = @backingInt(edge);
        const group = id >> 6;
        if (group >= self.blocks.len) return null;
        const block = &self.blocks[group];
        const bit = @as(u64, 1) << @as(u6, @truncate(id));
        const bits = block.mask;
        if (bits & bit == 0) return null;
        return @fromBackingInt(block.first + @popCount(bits & (bit - 1)));
    }

    pub inline fn load(self: View, index: Slot) ?Record {
        const id = @backingInt(index);
        if (id >= self.records.len) return null;
        return @bitCast(@atomicLoad(u64, &self.records[id], .monotonic));
    }

    pub inline fn record(self: View, edge: format.EdgeId) ?Record {
        return self.load(self.slot(edge) orelse return null);
    }

    /// Read once when binding live traffic for a request. An in-progress
    /// batch can change observations independently, one complete word at a time.
    pub fn metadata(self: View) ?Metadata {
        const version_before = @atomicLoad(u64, &self.header.sequence, .seq_cst);
        if (version_before & 1 != 0) return null;
        const time = @atomicLoad(u64, &self.header.last_update, .seq_cst);
        const ratio: f64 = @bitCast(@atomicLoad(u64, &self.header.live_to_bound_bits, .seq_cst));
        if (version_before != @atomicLoad(u64, &self.header.sequence, .seq_cst) or !validRatio(ratio))
            return null;
        return .{ .epoch = version_before >> 1, .last_update = time, .live_to_bound = ratio };
    }
};

pub const Reader = struct {
    mapping: io.Mapping,
    view: View,

    pub fn open(dir: io.Directory, uuid: format.DatasetUuid, edges: usize, deadline: io.Deadline) !?Reader {
        const file = dir.readFile(filename) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();
        const mapping = try io.Mapping.mapFd(file, .read_only);
        errdefer mapping.unmap();
        return .{ .mapping = mapping, .view = try View.parse(mapping.bytes, uuid, edges, deadline) };
    }

    pub fn close(self: Reader) void {
        self.mapping.unmap();
    }
};

pub const Overlays = struct {
    view: ?View = null,

    pub fn init(view: ?View, now: u64, max_age_seconds: u64) Overlays {
        const data = view orelse return .{};
        const state = data.metadata() orelse return .{};
        if (state.last_update == 0 or state.last_update > now or now - state.last_update > max_age_seconds)
            return .{};
        return .{ .view = data };
    }

    pub inline fn live(self: Overlays, edge: format.EdgeId) ?speed.Live {
        const view = self.view orelse return null;
        const item = view.record(edge) orelse return null;
        return item.observation();
    }

    pub fn predicted(_: Overlays, _: format.EdgeId, _: speed.Bucket) ?f32 {
        return null;
    }
};

pub const Graph = struct {
    uuid: format.DatasetUuid,
    edges: []const format.EdgeHot,
    classes: []const EdgeClass,
    bounds: ?[]const u8,

    fn edgeCount(self: Graph) !u32 {
        if (self.bounds) |bounds| if (bounds.len != self.edges.len) return error.InvalidLiveTrafficBound;
        return std.math.cast(u32, self.edges.len) orelse error.LiveTrafficEdgeCountMismatch;
    }

    fn drivable(self: Graph, edge: format.EdgeHot) !bool {
        const motor_modes: constants.AccessMask = .{
            .auto = true,
            .truck = true,
            .emergency = true,
            .taxi = true,
            .bus = true,
            .hov = true,
            .moped = true,
            .motorcycle = true,
        };
        if (edge.cls.class_id >= self.classes.len) return error.InvalidClassId;
        const class = self.classes[edge.cls.class_id];
        return !class.flags.node_connector and class.access.forward & @as(u16, @bitCast(motor_modes)) != 0;
    }

    fn bound(self: Graph, id: u32) u8 {
        return if (self.bounds) |bounds| bounds[id] else speed.upperBound(self.edges[id]);
    }
};

pub const Update = struct {
    edge: format.EdgeId,
    record: Record,
};

/// One owner holds the file's exclusive lock while readers use their own maps.
pub const Writer = struct {
    file: io.File,
    mapping: io.Mapping,
    view: View,
    graph: Graph,

    pub fn create(dir: io.Directory, graph: Graph, deadline: io.Deadline) !Writer {
        const edges = try graph.edgeCount();
        var count: u32 = 0;
        for (graph.edges, 0..) |edge, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            count += @intFromBool(try graph.drivable(edge));
        }
        const layout = try Layout.init(edges, count);
        const staged = try dir.temporaryFile();
        const file = staged.file;
        errdefer file.close();
        errdefer dir.deleteFile(&staged.name) catch {};
        try takeWriterLock(file);
        try file.truncate(layout.size);
        const mapping = try io.Mapping.mapFd(file, .shared_writable);
        errdefer mapping.unmap();
        const header = &(try mapping.sliceMut(Header, 0, 1))[0];
        header.* = .{ .dataset_uuid = graph.uuid, .version = version, .edge_count = edges, .record_count = count };
        const blocks = try mapping.sliceMut(RankBlock, @sizeOf(Header), layout.block_count);
        var first: u32 = 0;
        for (blocks, 0..) |*block, i| {
            if (i % 16 == 0 and deadline.expired()) return error.DeadlineExceeded;
            block.* = .{ .first = first };
            const start = i * 64;
            for (graph.edges[start..@min(start + 64, graph.edges.len)], 0..) |edge, bit| {
                if (try graph.drivable(edge)) block.mask |= @as(u64, 1) << @as(u6, @intCast(bit));
            }
            first += @popCount(block.mask);
        }
        const records = try mapping.sliceMut(u64, layout.records_offset, count);
        var rest = records;
        while (rest.len != 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const chunk = @min(rest.len, 16 * 1024);
            @memset(rest[0..chunk], @bitCast(Record.unknown));
            rest = rest[chunk..];
        }
        try file.sync();
        if (deadline.expired()) return error.DeadlineExceeded;
        try dir.renameExclusive(&staged.name, filename);
        try dir.sync();
        return .{ .file = file, .mapping = mapping, .view = .{ .header = header, .blocks = blocks, .records = records }, .graph = graph };
    }

    pub fn open(dir: io.Directory, graph: Graph, deadline: io.Deadline) !Writer {
        const edges = try graph.edgeCount();
        const file = try dir.readWriteFile(filename);
        errdefer file.close();
        try takeWriterLock(file);
        const mapping = try io.Mapping.mapFd(file, .shared_writable);
        errdefer mapping.unmap();
        return .{
            .file = file,
            .mapping = mapping,
            .view = try View.parse(mapping.bytes, graph.uuid, edges, deadline),
            .graph = graph,
        };
    }

    pub fn close(self: Writer) void {
        self.mapping.unmap();
        self.file.close();
    }

    /// Publish a bulk update. Repeated entries for an edge are applied in order.
    /// A deadline during publication leaves the sequence odd. A subsequent batch
    /// can recover it while readers fall back to the next available speed source.
    pub fn update(self: *Writer, updates: []const Update, timestamp: u64, deadline: io.Deadline) !Metadata {
        if (deadline.expired()) return error.DeadlineExceeded;
        const header = @constCast(self.view.header);
        const prev_time = @atomicLoad(u64, &header.last_update, .seq_cst);
        if (timestamp == 0 or timestamp < prev_time) return error.InvalidLiveTrafficTime;
        var ratio: f64 = @bitCast(@atomicLoad(u64, &header.live_to_bound_bits, .seq_cst));
        if (!validRatio(ratio)) return error.InvalidLiveTrafficRatio;
        for (updates, 0..) |entry, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (self.view.slot(entry.edge) == null) return error.EdgeNotDrivable;
            if (entry.record.reserved) return error.InvalidLiveTrafficRecord;
            const bound = self.graph.bound(@backingInt(entry.edge));
            if (bound == 0) return error.InvalidLiveTrafficBound;
            const kph: f64 = @floatFromInt(entry.record.maxKph());
            ratio = @max(ratio, kph / @as(f64, @floatFromInt(bound)));
        }
        const previous = @atomicLoad(u64, &header.sequence, .seq_cst) & ~@as(u64, 1);
        const next = std.math.add(u64, previous, 2) catch return error.LiveTrafficEpochExhausted;
        @atomicStore(u64, &header.sequence, previous + 1, .seq_cst);
        @atomicStore(u64, &header.live_to_bound_bits, @bitCast(ratio), .seq_cst);
        const records = @constCast(self.view.records);
        for (updates, 0..) |entry, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const index = @backingInt(self.view.slot(entry.edge).?);
            @atomicStore(u64, &records[index], @bitCast(entry.record), .monotonic);
        }
        @atomicStore(u64, &header.last_update, timestamp, .seq_cst);
        @atomicStore(u64, &header.sequence, next, .seq_cst);
        return .{ .epoch = next >> 1, .last_update = timestamp, .live_to_bound = ratio };
    }
};

fn validRatio(ratio: f64) bool {
    return std.math.isFinite(ratio) and ratio >= 1;
}

fn takeWriterLock(file: io.File) !void {
    file.lockExclusive() catch |err| return if (err == error.WouldBlock) error.LiveTrafficWriterBusy else err;
}

// Ported from test/traffictile.cc.
test "traffic words match Valhalla's 2 kph encoding and closure semantics" {
    const testing = std.testing;
    var traffic: Record = .{ .overall = 49, .speed1 = 49, .breakpoint1 = 255 };
    try testing.expect(traffic.validSpeed());
    try testing.expect(!traffic.closed());
    try testing.expectEqual(98, traffic.overallKph());
    try testing.expectEqual(98, traffic.subsegmentKph(.first));
    try testing.expectEqual(254, traffic.subsegmentKph(.second));
    traffic.has_incidents = true;
    try testing.expectEqual(@as(u64, 49 | (49 << 7) | (127 << 14) | (127 << 21) | (255 << 28) | (1 << 62)), @as(u64, @bitCast(traffic)));
    traffic.congestion1 = max_congestion;
    traffic.speed2 = 0;
    try testing.expect(traffic.subsegmentClosed(.first));
    try testing.expect(!traffic.subsegmentClosed(.second));
    traffic.overall = 0;
    try testing.expect(traffic.closed());
    traffic.overall = unknown_speed;
    try testing.expect(!traffic.validSpeed());
    try testing.expect(!traffic.closed());
    try testing.expect(!traffic.subsegmentClosed(.first));
    try testing.expectEqual(254, traffic.subsegmentKph(.first));
}
