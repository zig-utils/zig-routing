//! Dataset-bound snapshots of weekly speed profiles and static traffic speeds.
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("../graph/format.zig");
const live = @import("live.zig");
const codec = @import("predicted_codec.zig");

pub const filename = "traffic-pred.bin";
pub const no_profile = std.math.maxInt(u32);
const magic = "ZRPRED\x00\x00".*;
const version: u32 = 1;

pub const Header = extern struct {
    tag: [8]u8 = magic,
    dataset_uuid: format.DatasetUuid,
    version: u32,
    edge_count: u32,
    record_count: u32,
    profile_count: u32,
    payload_hash: u64,
    reserved: [16]u8 = @splat(0),
};

pub const EdgeData = extern struct {
    profile: u32 = no_profile,
    free_flow: u8 = 0,
    constrained: u8 = 0,
    reserved: u16 = 0,

    pub fn present(self: EdgeData) bool {
        return self.profile != no_profile or self.free_flow != 0 or self.constrained != 0;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 64 and @alignOf(Header) == 8);
    std.debug.assert(@offsetOf(Header, "tag") == 0 and @offsetOf(Header, "dataset_uuid") == 8);
    std.debug.assert(@offsetOf(Header, "version") == 24 and @offsetOf(Header, "edge_count") == 28);
    std.debug.assert(@offsetOf(Header, "record_count") == 32 and @offsetOf(Header, "profile_count") == 36);
    std.debug.assert(@offsetOf(Header, "payload_hash") == 40 and @offsetOf(Header, "reserved") == 48);
    std.debug.assert(@sizeOf(EdgeData) == 8);
    std.debug.assert(@offsetOf(EdgeData, "profile") == 0 and @offsetOf(EdgeData, "free_flow") == 4);
    std.debug.assert(@offsetOf(EdgeData, "constrained") == 5 and @offsetOf(EdgeData, "reserved") == 6);
    std.debug.assert(@sizeOf(codec.Profile) == 400 and @alignOf(codec.Profile) == 2);
}

const Layout = struct {
    block_count: usize,
    records_offset: usize,
    profiles_offset: usize,
    len: usize,

    fn init(edges: u32, records: u32, profiles: u32) !Layout {
        const blocks = blockCount(edges);
        const records_offset = @as(u64, blocks) * @sizeOf(live.RankBlock) + @sizeOf(Header);
        const profiles_offset = records_offset + @as(u64, records) * @sizeOf(EdgeData);
        const len = profiles_offset + @as(u64, profiles) * @sizeOf(codec.StoredProfile);
        return .{
            .block_count = blocks,
            .records_offset = std.math.cast(usize, records_offset) orelse return error.PredictedTrafficTooLarge,
            .profiles_offset = std.math.cast(usize, profiles_offset) orelse return error.PredictedTrafficTooLarge,
            .len = std.math.cast(usize, len) orelse return error.PredictedTrafficTooLarge,
        };
    }
};

pub fn blockCount(edges: u32) u32 {
    return edges / 64 + @intFromBool(edges % 64 != 0);
}

pub const View = struct {
    blocks: []const live.RankBlock,
    records: []const EdgeData,
    profiles: []const codec.StoredProfile,
    decoder: codec.Codec,

    pub fn parse(bytes: []const u8, uuid: format.DatasetUuid, edge_count: usize, deadline: io.Deadline) !View {
        if (deadline.expired()) return error.DeadlineExceeded;
        const header = (try io.typedSlice(Header, bytes, 0, 1))[0];
        if (!std.mem.eql(u8, &header.tag, &magic) or header.version != version or
            !std.mem.allEqual(u8, &header.reserved, 0))
            return error.InvalidPredictedTrafficHeader;
        if (!std.mem.eql(u8, &header.dataset_uuid, &uuid)) return error.PredictedTrafficDatasetUuidMismatch;
        if (header.edge_count != edge_count or header.record_count > edge_count or header.profile_count > header.record_count)
            return error.InvalidPredictedTrafficCount;
        const layout = try Layout.init(header.edge_count, header.record_count, header.profile_count);
        if (bytes.len != layout.len) return error.InvalidPredictedTrafficLength;
        var hash = std.hash.XxHash3.init(0);
        try streamPayload(&hash, null, bytes[@sizeOf(Header)..], deadline);
        if (header.payload_hash != hash.final()) return error.PredictedTrafficHashMismatch;
        const blocks = try io.typedSlice(live.RankBlock, bytes, @sizeOf(Header), layout.block_count);
        const records = try io.typedSlice(EdgeData, bytes, layout.records_offset, header.record_count);
        const profiles = try io.typedSlice(codec.StoredProfile, bytes, layout.profiles_offset, header.profile_count);
        try validate(blocks, records, profiles, header.edge_count, deadline);
        return .{ .blocks = blocks, .records = records, .profiles = profiles, .decoder = try codec.Codec.init(deadline) };
    }

    pub inline fn entry(self: View, edge: format.EdgeId) ?EdgeData {
        const row = live.rankSlot(self.blocks, edge) orelse return null;
        return self.records[@backingInt(row)];
    }

    pub fn profile(self: View, data: EdgeData) ?*const codec.StoredProfile {
        if (data.profile == no_profile) return null;
        return &self.profiles[data.profile];
    }

    pub fn speed(self: View, edge: format.EdgeId, seconds_of_week: u64) ?f32 {
        const stored = self.entry(edge) orelse return null;
        const coefficients = self.profile(stored) orelse return null;
        return self.decoder.speed(coefficients, seconds_of_week);
    }

    /// Read an edge's traffic record without writing to the base topology.
    pub fn applyStatic(self: View, edge: format.EdgeId, base: format.EdgeHot) format.EdgeHot {
        const stored = self.entry(edge) orelse return base;
        var result = base;
        if (stored.free_flow != 0) result.speed[1] = stored.free_flow;
        if (stored.constrained != 0) result.speed[2] = stored.constrained;
        if (stored.profile != no_profile) result.cls.pred_speed = 1;
        return result;
    }
};

pub const Reader = struct {
    mapping: io.Mapping,
    view: View,

    pub fn open(dir: io.Directory, uuid: format.DatasetUuid, edge_count: usize, deadline: io.Deadline) !?Reader {
        const file = dir.readFile(filename) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();
        const mapping = try io.Mapping.mapFd(file, .read_only);
        errdefer mapping.unmap();
        return .{ .mapping = mapping, .view = try View.parse(mapping.bytes, uuid, edge_count, deadline) };
    }

    pub fn close(self: Reader) void {
        self.mapping.unmap();
    }
};

/// Publish a checked snapshot, leaving existing mappings attached to their original inode.
pub fn write(dir: io.Directory, uuid: format.DatasetUuid, edge_count: u32, blocks: []const live.RankBlock, records: []const EdgeData, profiles: []const codec.StoredProfile, deadline: io.Deadline) !void {
    try validate(blocks, records, profiles, edge_count, deadline);
    const staged = try dir.temporaryFile();
    defer staged.file.close();
    errdefer dir.deleteFile(&staged.name) catch {};
    var header: Header = .{
        .dataset_uuid = uuid,
        .version = version,
        .edge_count = edge_count,
        .record_count = @intCast(records.len),
        .profile_count = @intCast(profiles.len),
        .payload_hash = 0,
    };
    try staged.file.writeAll(std.mem.asBytes(&header));
    var hash = std.hash.XxHash3.init(0);
    try streamPayload(&hash, staged.file, std.mem.sliceAsBytes(blocks), deadline);
    try streamPayload(&hash, staged.file, std.mem.sliceAsBytes(records), deadline);
    try streamPayload(&hash, staged.file, std.mem.sliceAsBytes(profiles), deadline);
    header.payload_hash = hash.final();
    try staged.file.pwriteAll(std.mem.asBytes(&header), 0);
    try staged.file.sync();
    if (deadline.expired()) return error.DeadlineExceeded;
    try dir.replaceFile(&staged.name, filename);
    try dir.sync();
}

fn streamPayload(hash: *std.hash.XxHash3, file: ?io.File, payload: []const u8, deadline: io.Deadline) !void {
    var offset: usize = 0;
    while (offset < payload.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const chunk = payload[offset..@min(offset +| (1 << 20), payload.len)];
        io.updateFileHash(hash, chunk);
        if (file) |out| try out.writeAll(chunk);
        offset += chunk.len;
    }
}

fn validate(blocks: []const live.RankBlock, records: []const EdgeData, profiles: []const codec.StoredProfile, edge_count: u32, deadline: io.Deadline) !void {
    if (blocks.len != blockCount(edge_count) or records.len > edge_count or profiles.len > records.len)
        return error.InvalidPredictedTrafficCount;
    var seen: usize = 0;
    const last_bits: u6 = @truncate(edge_count);
    for (blocks, 0..) |block, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (block.first != seen or block.reserved != 0 or
            (i + 1 == blocks.len and last_bits != 0 and block.mask >> last_bits != 0))
            return error.InvalidPredictedTrafficBitmap;
        seen += @popCount(block.mask);
    }
    if (seen != records.len) return error.InvalidPredictedTrafficBitmap;
    for (records, 0..) |record, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!record.present() or record.reserved != 0 or
            (record.profile != no_profile and record.profile >= profiles.len))
            return error.InvalidPredictedTrafficRecord;
    }
    for (profiles, 0..) |*profile, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!profile.valid()) return error.InvalidPredictedTrafficProfile;
    }
}
