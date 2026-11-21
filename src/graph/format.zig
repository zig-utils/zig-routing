//! Graph bundle v1. See docs/design/engine-and-format.md, Q2.
const std = @import("std");
const io = @import("../infra/io.zig");
const class_table = @import("class_table.zig");
const constants = @import("constants.zig");
const turn_restrictions = @import("turn_restrictions.zig");
const restriction_automaton = @import("restriction_automaton.zig");
const transit = @import("transit.zig");
const edge_keys = @import("edge_keys.zig");

pub const magic = "ZRGRAPH\x00".*;
pub const version: u32 = 1;
pub const payload_offset = 64 * 1024;
pub const DatasetUuid = [16]u8;
pub const Bounds = @import("coverage.zig").Bounds;
pub const Coordinate = @import("../geo/point.zig").FixedLL;

pub const NodeId = enum(u32) { _ };
pub const EdgeId = enum(u32) { _ };

pub const EdgeHot = extern struct {
    head: u32,
    geom: packed struct(u32) {
        len_m: u24,
        grade: u4,
        curvature: u4,
    },
    cls: packed struct(u32) {
        class_id: class_table.ClassId,
        local: u5,
        opp_local: u5,
        cold_checks: u1,
        pred_speed: u1,
    },
    /// Speed, free flow, constrained and truck speed, in km/h.
    speed: [4]u8,
};

pub const NodeHot = extern struct {
    turn_off: u32,
    attr: packed struct(u32) {
        access: u16,
        type: u4,
        density: u4,
        signal: u1,
        intersection: constants.IntersectionType = .regular,
        drive_on_left: bool = false,
        tagged_access: bool = false,
        private_access: bool = false,
        cash_only_toll: bool = false,
        has_turn_restrictions: bool = false,
    },
};

/// CSR offsets indexed by node, including a sentinel after the last node.
pub const FirstEdge = u32;

/// Low to high: turn type (3), stop impact (3), name consistent (1), restricted (1).
pub const TurnEntry = u8;

/// Two Valhalla 5-bit quantized slopes in low-to-high up/down order.
pub const Slopes = struct {
    code: u16,

    pub const flat: Slopes = .{ .code = 0 };
    pub const unavailable = std.math.maxInt(u16);

    pub fn init(up: u5, down: u5) Slopes {
        return .{ .code = @as(u16, up) | (@as(u16, down) << 5) };
    }

    pub fn maxUp(self: Slopes) i8 {
        return expand(@truncate(self.code));
    }

    pub fn maxDown(self: Slopes) i8 {
        return -expand(@truncate(self.code >> 5));
    }

    fn expand(code: u5) i8 {
        return if (code < 16) @intCast(code) else 16 + @as(i8, @intCast(code & 0xf)) * 4;
    }
};

pub const OrderingKind = enum(u32) { encounter = 0, hilbert = 1 };

pub const Metadata = extern struct {
    order_hash: u64,
    ordering_kind: u32,
    reserved: u32 = 0,

    pub fn ordering(self: Metadata) ?OrderingKind {
        return std.enums.fromInt(OrderingKind, self.ordering_kind);
    }
};

pub const Placement = enum { hot, warm, cold };

pub const SectionKind = enum(u32) {
    nodes = 1,
    edges = 2,
    first_edge = 3,
    turns = 4,
    classes = 5,
    coordinates = 6,
    cold_idx = 7,
    cold = 8,
    slopes = 9,
    spatial = 10,
    metadata = 11,
    components = 12,
    turn_sides = 13,
    coverage = 14,
    admins = 15,
    node_admins = 16,
    node_timezones = 17,
    timezone_rules = 18,
    turn_restrictions = 19,
    restriction_automaton = 20,
    restriction_conditions = 21,
    signs = 22,
    headings = 23,
    lb_speeds = 24,
    turnlanes = 25,
    lane_connectivity = 26,
    transit_metadata = 27,
    transit_stops = 28,
    transit_stations = 29,
    transit_egresses = 30,
    transit_routes = 31,
    transit_lines = 32,
    transit_departures = 33,
    transit_occurrences = 34,
    transit_schedules = 35,
    transit_days = 36,
    transit_exceptions = 37,
    transit_transfers = 38,
    edge_keys = 39,
    edge_key_inverse = 40,
    edge_key_hash_header = 41,
    edge_key_hash_buckets = 42,
    edge_key_hash_slots = 43,
    dataset_id = 44,
    snap_bins = 45,

    pub fn placement(kind: SectionKind) Placement {
        return switch (kind) {
            .nodes, .edges, .first_edge, .turns, .classes, .turn_sides, .headings => .hot,
            .coordinates, .spatial, .components, .metadata, .coverage, .admins, .node_admins, .node_timezones, .timezone_rules, .lb_speeds => .warm,
            .turn_restrictions, .restriction_automaton, .restriction_conditions, .dataset_id, .snap_bins => .warm,
            .transit_metadata, .transit_stops, .transit_stations, .transit_egresses, .transit_routes, .transit_lines, .transit_departures, .transit_occurrences, .transit_schedules, .transit_days, .transit_exceptions, .transit_transfers => .warm,
            .cold_idx, .cold, .slopes, .signs, .turnlanes, .lane_connectivity => .cold,
            .edge_keys, .edge_key_inverse, .edge_key_hash_header, .edge_key_hash_buckets, .edge_key_hash_slots => .cold,
        };
    }

    pub noinline fn filename(self: SectionKind) [:0]const u8 {
        return switch (self) {
            .nodes => "nodes.bin",
            .edges => "edges.bin",
            .first_edge => "first_edge.bin",
            .turns => "turns.bin",
            .classes => "classes.bin",
            .coordinates => "coordinates.bin",
            .cold_idx => "cold_idx.bin",
            .cold => "cold.bin",
            .slopes => "slopes.bin",
            .spatial => "spatial.bin",
            .metadata => "metadata.bin",
            .components => "components.bin",
            .turn_sides => "turn_sides.bin",
            .coverage => "coverage.bin",
            .admins => "admins.bin",
            .node_admins => "node_admins.bin",
            .node_timezones => "node_timezones.bin",
            .timezone_rules => "timezone_rules.bin",
            .turn_restrictions => "turn_restrictions.bin",
            .restriction_automaton => "restr.bin",
            .restriction_conditions => "restr_domains.bin",
            .signs => "signs.bin",
            .headings => "headings.bin",
            .lb_speeds => "lb_speeds.bin",
            .turnlanes => "turnlanes.bin",
            .lane_connectivity => "lane_connectivity.bin",
            .transit_metadata => "transit_metadata.bin",
            .transit_stops => "transit_stops.bin",
            .transit_stations => "transit_stations.bin",
            .transit_egresses => "transit_egresses.bin",
            .transit_routes => "transit_routes.bin",
            .transit_lines => "transit_lines.bin",
            .transit_departures => "transit_departures.bin",
            .transit_occurrences => "transit_occurrences.bin",
            .transit_schedules => "transit_schedules.bin",
            .transit_days => "transit_days.bin",
            .transit_exceptions => "transit_exceptions.bin",
            .transit_transfers => "transit_transfers.bin",
            .edge_keys => "edge_keys.bin",
            .edge_key_inverse => "edge_key_inverse.bin",
            .edge_key_hash_header => "edge_key_hash_header.bin",
            .edge_key_hash_buckets => "edge_key_hash_buckets.bin",
            .edge_key_hash_slots => "edge_key_hash_slots.bin",
            .dataset_id => "dataset_id.bin",
            .snap_bins => "snap_bins.bin",
        };
    }

    pub fn Record(comptime self: SectionKind) type {
        return switch (self) {
            .nodes => NodeHot,
            .edges => EdgeHot,
            .first_edge => FirstEdge,
            .turns => TurnEntry,
            .classes => class_table.EdgeClass,
            .coordinates => Coordinate,
            .cold_idx => u32,
            .cold => u8,
            .slopes, .turnlanes => u16,
            .spatial => u8,
            .metadata => Metadata,
            .dataset_id => u64,
            .snap_bins => u32,
            .coverage => Bounds,
            .admins, .timezone_rules => u8,
            .node_admins, .node_timezones => u16,
            .components, .turn_sides, .edge_key_inverse, .edge_key_hash_slots => u32,
            .turn_restrictions => turn_restrictions.Entry,
            .restriction_automaton => restriction_automaton.State,
            .restriction_conditions => restriction_automaton.Condition,
            .signs => @import("signs.zig").Entry,
            .lane_connectivity => @import("lanes.zig").Connection,
            .headings, .lb_speeds => u8,
            .transit_metadata => transit.Metadata,
            .transit_stops => transit.Stop,
            .transit_stations => transit.Station,
            .transit_egresses => transit.Egress,
            .transit_routes => transit.Route,
            .transit_lines => transit.Line,
            .transit_departures => transit.Departure,
            .transit_occurrences => transit.Occurrence,
            .transit_schedules => transit.Schedule,
            .transit_days => transit.DayWord,
            .transit_exceptions => transit.Exception,
            .transit_transfers => transit.Transfer,
            .edge_keys => edge_keys.Record,
            .edge_key_hash_header => edge_keys.HashHeader,
            .edge_key_hash_buckets => u64,
        };
    }

    pub fn recordSize(self: SectionKind) u32 {
        return switch (self) {
            inline else => |kind| @sizeOf(kind.Record()),
        };
    }
};

pub const core_sections = [_]SectionKind{ .nodes, .edges, .first_edge, .turns };
pub const required_sections = std.EnumSet(SectionKind).initMany(&core_sections);
pub const transit_sections = [_]SectionKind{
    .transit_metadata,   .transit_stops,       .transit_stations,  .transit_egresses, .transit_routes,     .transit_lines,
    .transit_departures, .transit_occurrences, .transit_schedules, .transit_days,     .transit_exceptions, .transit_transfers,
};

/// File header at offset 0. Zero padding runs up to payload_offset.
pub const SectionHeader = extern struct {
    magic_tag: [8]u8 = magic,
    format_version: u32 = version,
    /// Integer encoding of SectionKind, so corrupt bytes can be validated safely.
    kind: u32,
    dataset_uuid: DatasetUuid,
    record_size: u32,
    reserved: u32 = 0,
    count: u64,
    /// Seedless XXH3-64 of payload only.
    payload_hash: u64,
    reserved_tail: [8]u8 = @splat(0),
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(SectionHeader) == 64);
    std.debug.assert(@offsetOf(SectionHeader, "magic_tag") == 0);
    std.debug.assert(@offsetOf(SectionHeader, "format_version") == 8);
    std.debug.assert(@offsetOf(SectionHeader, "kind") == 12);
    std.debug.assert(@offsetOf(SectionHeader, "dataset_uuid") == 16);
    std.debug.assert(@offsetOf(SectionHeader, "record_size") == 32);
    std.debug.assert(@offsetOf(SectionHeader, "reserved") == 36);
    std.debug.assert(@offsetOf(SectionHeader, "count") == 40);
    std.debug.assert(@offsetOf(SectionHeader, "payload_hash") == 48);
    std.debug.assert(@offsetOf(SectionHeader, "reserved_tail") == 56);

    std.debug.assert(@sizeOf(EdgeHot) == 16 and @alignOf(EdgeHot) == 4);
    std.debug.assert(@offsetOf(EdgeHot, "head") == 0 and @offsetOf(EdgeHot, "geom") == 4);
    std.debug.assert(@offsetOf(EdgeHot, "cls") == 8 and @offsetOf(EdgeHot, "speed") == 12);
    std.debug.assert(@sizeOf(NodeHot) == 8 and @alignOf(NodeHot) == 4);
    std.debug.assert(@offsetOf(NodeHot, "turn_off") == 0 and @offsetOf(NodeHot, "attr") == 4);
    std.debug.assert(@sizeOf(NodeId) == 4 and @sizeOf(EdgeId) == 4);
    std.debug.assert(@sizeOf(Coordinate) == 8);
    std.debug.assert(@offsetOf(Coordinate, "lng") == 0 and @offsetOf(Coordinate, "lat") == 4);
    std.debug.assert(@sizeOf(FirstEdge) == 4 and @sizeOf(TurnEntry) == 1);
    std.debug.assert(@sizeOf(SectionKind.slopes.Record()) == 2);
    std.debug.assert(@sizeOf(Metadata) == 16 and @offsetOf(Metadata, "order_hash") == 0);
    std.debug.assert(@offsetOf(Metadata, "ordering_kind") == 8 and @offsetOf(Metadata, "reserved") == 12);
    std.debug.assert(payload_offset % @alignOf(EdgeHot) == 0);
    std.debug.assert(payload_offset % @alignOf(NodeHot) == 0);
}

/// Writes a new immutable bundle. Call deinit after init even if writing or
/// committing fails. The destination's parent must exist.
pub const BundleWriter = struct {
    parent: io.Directory,
    staging: io.Directory,
    temp_name: io.Directory.TempName,
    target: [std.fs.max_name_bytes:0]u8,
    target_len: usize,
    uuid: DatasetUuid,
    deadline: io.Deadline,
    written: std.EnumSet(SectionKind) = .empty,
    committed: bool = false,

    pub fn init(path: []const u8, uuid: DatasetUuid, deadline: io.Deadline) !BundleWriter {
        if (deadline.expired()) return error.DeadlineExceeded;
        const name = std.fs.path.basename(path);
        if (name.len == 0 or name.len > std.fs.max_name_bytes or
            std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidArgument;
        const parent = try io.Directory.open(std.fs.path.dirname(path) orelse ".");
        errdefer parent.close();
        const staged = try parent.temporaryChild();
        var target: [std.fs.max_name_bytes:0]u8 = @splat(0);
        @memcpy(target[0..name.len], name);
        return .{
            .parent = parent,
            .staging = staged.dir,
            .temp_name = staged.name,
            .target = target,
            .target_len = name.len,
            .uuid = uuid,
            .deadline = deadline,
        };
    }

    pub fn deinit(self: *BundleWriter) void {
        if (!self.committed) {
            var iter = self.written.iterator();
            while (iter.next()) |kind| self.staging.deleteFile(kind.filename()) catch {};
            self.parent.deleteDir(&self.temp_name) catch {};
        }
        self.staging.close();
        self.parent.close();
        self.* = undefined;
    }

    pub fn write(self: *BundleWriter, comptime kind: SectionKind, records: []const kind.Record()) !void {
        try self.writeBytes(kind, std.mem.sliceAsBytes(records));
    }

    noinline fn writeBytes(self: *BundleWriter, kind: SectionKind, bytes: []const u8) !void {
        const file = try self.startSection(kind);
        errdefer self.staging.deleteFile(kind.filename()) catch {};
        defer file.close();
        var payload: PayloadWriter = .{ .file = file, .deadline = self.deadline };
        try payload.append(bytes);
        try self.finishSection(kind, &payload, null);
    }

    /// Produce a section in bounded batches. If producing it fails, that
    /// section can be retried before commit.
    pub fn stream(
        self: *BundleWriter,
        comptime kind: SectionKind,
        context: anytype,
        comptime produce: fn (@TypeOf(context), *SectionWriter(kind)) anyerror!void,
    ) !void {
        const file = try self.startSection(kind);
        errdefer self.staging.deleteFile(kind.filename()) catch {};
        defer file.close();
        var payload: PayloadWriter = .{ .file = file, .deadline = self.deadline };
        var section: SectionWriter(kind) = .{ .payload = &payload };
        try produce(context, &section);
        try self.finishSection(kind, &payload, null);
    }

    noinline fn startSection(self: *BundleWriter, kind: SectionKind) !io.File {
        if (self.committed) return error.BundleCommitted;
        if (self.written.contains(kind)) return error.DuplicateSection;
        if (self.deadline.expired()) return error.DeadlineExceeded;
        return self.staging.createFile(kind.filename());
    }

    noinline fn finishSection(self: *BundleWriter, kind: SectionKind, payload: *PayloadWriter, expected_hash: ?u64) !void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
        const hash = payload.hash.final();
        if (expected_hash) |expected| {
            if (hash != expected) return error.PayloadHashMismatch;
        }
        const record_size = kind.recordSize();
        const header: SectionHeader = .{
            .kind = @backingInt(kind),
            .dataset_uuid = self.uuid,
            .record_size = record_size,
            .count = (payload.offset - payload_offset) / record_size,
            .payload_hash = hash,
        };
        try payload.file.pwriteAll(std.mem.asBytes(&header), 0);
        try payload.file.truncate(payload.offset);
        try payload.file.sync();
        self.written.insert(kind);
    }

    pub fn copySection(self: *BundleWriter, kind: SectionKind, input: io.File) !void {
        var header: SectionHeader = undefined;
        try input.preadAll(std.mem.asBytes(&header), 0);
        const record_size = kind.recordSize();
        if (!std.mem.eql(u8, &header.magic_tag, &magic) or header.format_version != version or
            header.record_size != record_size or header.kind != @backingInt(kind) or header.reserved != 0 or
            !std.mem.allEqual(u8, &header.reserved_tail, 0) or !std.mem.eql(u8, &header.dataset_uuid, &self.uuid))
            return error.InvalidSectionHeader;
        const size = std.math.mul(u64, header.count, record_size) catch return error.SectionTooLarge;
        const end = std.math.add(u64, payload_offset, size) catch return error.SectionTooLarge;
        if (try input.size() != end) return error.InvalidSectionSize;

        const file = try self.startSection(kind);
        errdefer self.staging.deleteFile(kind.filename()) catch {};
        defer file.close();
        var payload: PayloadWriter = .{ .file = file, .deadline = self.deadline };
        var buffer: [128 * 1024]u8 = undefined;
        while (payload.offset < end) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const bytes = buffer[0..@intCast(@min(buffer.len, end - payload.offset))];
            try input.preadAll(bytes, payload.offset);
            try payload.append(bytes);
        }
        try self.finishSection(kind, &payload, header.payload_hash);
    }

    /// Publish every section together. A bundle already at the destination
    /// keeps its name and contents.
    pub fn commit(self: *BundleWriter) !void {
        if (self.committed) return error.BundleCommitted;
        if (!required_sections.subsetOf(self.written)) return error.MissingSection;
        if (self.written.contains(.cold) != self.written.contains(.cold_idx)) return error.MissingSection;
        if (self.written.contains(.admins) != self.written.contains(.node_admins)) return error.MissingSection;
        if (self.written.contains(.timezone_rules) != self.written.contains(.node_timezones)) return error.MissingSection;
        if (self.deadline.expired()) return error.DeadlineExceeded;
        try self.staging.sync();
        if (self.deadline.expired()) return error.DeadlineExceeded;
        try self.parent.renameExclusive(&self.temp_name, self.target[0..self.target_len :0]);
        self.committed = true;
        try self.parent.sync();
    }
};

pub fn SectionWriter(comptime kind: SectionKind) type {
    return struct {
        const Self = @This();
        payload: *PayloadWriter,

        pub fn append(self: *Self, records: []const kind.Record()) !void {
            try self.payload.append(std.mem.sliceAsBytes(records));
        }

        pub fn deadline(self: Self) io.Deadline {
            return self.payload.deadline;
        }

        pub fn payloadBytes(self: Self) u64 {
            return self.payload.offset - payload_offset;
        }
    };
}

const PayloadWriter = struct {
    file: io.File,
    deadline: io.Deadline,
    offset: u64 = payload_offset,
    hash: std.hash.XxHash3 = .init(0),

    noinline fn append(self: *PayloadWriter, bytes: []const u8) !void {
        if (bytes.len > @as(u64, std.math.maxInt(i64)) - self.offset) return error.SectionTooLarge;
        var remaining = bytes;
        while (remaining.len != 0) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const chunk = remaining[0..@min(1024 * 1024, remaining.len)];
            try self.file.pwriteAll(chunk, self.offset);
            io.updateFileHash(&self.hash, chunk);
            self.offset += chunk.len;
            remaining = remaining[chunk.len..];
        }
    }
};

const testing = std.testing;
const fixture_uuid: DatasetUuid = .{
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
};

const fixture_nodes: []const NodeHot = &.{
    .{ .turn_off = 0, .attr = .{ .access = 0x0147, .type = 1, .density = 7, .signal = 1 } },
    .{ .turn_off = 1, .attr = .{ .access = 0x0206, .type = 0, .density = 0, .signal = 0 } },
};

const fixture_edges: []const EdgeHot = &.{
    .{
        .head = 1,
        .geom = .{ .len_m = 1234, .grade = 2, .curvature = 1 },
        .cls = .{ .class_id = 0x456, .local = 0, .opp_local = 0, .cold_checks = 1, .pred_speed = 0 },
        .speed = .{ 45, 50, 35, 40 },
    },
    .{
        .head = 0,
        .geom = .{ .len_m = 1234, .grade = 1, .curvature = 3 },
        .cls = .{ .class_id = 0x789, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 1 },
        .speed = .{ 40, 45, 30, 35 },
    },
};

fn bundlePath(parent_name: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "{s}/bundle", .{parent_name});
}

fn removeTestBundle(parent: io.Directory) void {
    const dir = parent.child("bundle") catch return;
    var kinds = required_sections.iterator();
    while (kinds.next()) |kind| dir.deleteFile(kind.filename()) catch {};
    dir.close();
    parent.deleteDir("bundle") catch {};
}

test "v1 bundle matches independently packed section hex and publishes together" {
    const cwd = try io.Directory.open(".");
    defer cwd.close();
    const root = try cwd.temporaryChild();
    defer {
        removeTestBundle(root.dir);
        root.dir.close();
        cwd.deleteDir(&root.name) catch {};
    }

    var path: [128]u8 = undefined;
    var writer = try BundleWriter.init(try bundlePath(&root.name, &path), fixture_uuid, .none);
    defer writer.deinit();
    try writer.write(.nodes, fixture_nodes);
    try writer.write(.edges, fixture_edges);
    try writer.write(.first_edge, &.{ 0, 1, 2 });
    try testing.expectError(error.DuplicateSection, writer.write(.nodes, fixture_nodes));
    try testing.expectError(error.MissingSection, writer.commit());
    try testing.expectError(error.FileNotFound, root.dir.child("bundle"));
    try writer.write(.turns, &.{ 0xb9, 0x72 });
    try writer.commit();
    try testing.expectError(error.BundleCommitted, writer.commit());

    const published = try root.dir.child("bundle");
    defer published.close();
    try testing.expectError(error.FileNotFound, root.dir.child(&writer.temp_name));

    const fixture = @embedFile("testdata/bundle-v1.hex");
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    for (core_sections) |kind| {
        var line = std.mem.splitScalar(u8, lines.next().?, ' ');
        try testing.expectEqualStrings(kind.filename(), line.next().?);
        var expected: [128]u8 = undefined;
        const encoded = try std.fmt.hexToBytes(&expected, line.next().?);

        const file = try published.readFile(kind.filename());
        defer file.close();
        const mapped = try io.Mapping.mapFd(file, .read_only);
        defer mapped.unmap();
        const prefix = @sizeOf(SectionHeader);
        try testing.expectEqual(payload_offset + encoded.len - prefix, mapped.bytes.len);
        try testing.expectEqualSlices(u8, encoded[0..prefix], mapped.bytes[0..prefix]);
        try testing.expectEqualSlices(u8, encoded[prefix..], mapped.bytes[payload_offset..]);
        for (mapped.bytes[prefix..payload_offset]) |byte| try testing.expectEqual(0, byte);
    }
}

const Producer = struct {
    fn fail(_: void, out: *SectionWriter(.turns)) !void {
        try out.append(&.{0xff});
        return error.FixtureFailed;
    }

    fn emit(input: []const u8, out: *SectionWriter(.turns)) !void {
        try out.append(input[0..1]);
        try out.append(input[1..257]);
        try out.append(input[257..961]);
        try out.append(input[961..]);
    }
};

test "streaming XXH3, aborted sections and exclusive commit" {
    const cwd = try io.Directory.open(".");
    defer cwd.close();
    const root = try cwd.temporaryChild();
    defer {
        removeTestBundle(root.dir);
        root.dir.close();
        cwd.deleteDir(&root.name) catch {};
    }
    var path_buf: [128]u8 = undefined;
    const path = try bundlePath(&root.name, &path_buf);
    var writer = try BundleWriter.init(path, fixture_uuid, .none);
    defer writer.deinit();
    try writer.write(.nodes, fixture_nodes);
    try writer.write(.edges, fixture_edges);
    try writer.write(.first_edge, &.{ 0, 1, 2 });
    try testing.expectError(error.FixtureFailed, writer.stream(.turns, {}, Producer.fail));
    try testing.expectError(error.FileNotFound, writer.staging.readFile("turns.bin"));
    try testing.expectError(error.FileNotFound, root.dir.child("bundle"));

    var bytes: [1025]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 17 + 23);
    try writer.stream(.turns, @as([]const u8, &bytes), Producer.emit);
    try writer.commit();

    const published = try root.dir.child("bundle");
    defer published.close();
    const turns = try published.readFile("turns.bin");
    defer turns.close();
    var header: SectionHeader = undefined;
    try turns.preadAll(std.mem.asBytes(&header), 0);
    try testing.expectEqual(1025, header.count);
    try testing.expectEqual(0x302790b7acce9817, header.payload_hash);

    const other_temp = blk: {
        var other = try BundleWriter.init(path, @splat(0), .none);
        defer other.deinit();
        try other.write(.nodes, &.{});
        try other.write(.edges, &.{});
        try other.write(.first_edge, &.{0});
        try other.write(.turns, &.{});
        const empty = try other.staging.readFile("nodes.bin");
        defer empty.close();
        var empty_header: SectionHeader = undefined;
        try empty.preadAll(std.mem.asBytes(&empty_header), 0);
        try testing.expectEqual(payload_offset, try empty.size());
        try testing.expectEqual(0, empty_header.count);
        try testing.expectEqual(0x2d06800538d394c2, empty_header.payload_hash);
        try testing.expectError(error.PathAlreadyExists, other.commit());
        break :blk other.temp_name;
    };
    try testing.expectError(error.FileNotFound, root.dir.child(&other_temp));

    // Reopen via the final name so a changed directory entry would be caught.
    const preserved = try root.dir.child("bundle");
    defer preserved.close();
    const preserved_turns = try preserved.readFile("turns.bin");
    defer preserved_turns.close();
    try preserved_turns.preadAll(std.mem.asBytes(&header), 0);
    try testing.expectEqual(fixture_uuid, header.dataset_uuid);
    try testing.expectEqual(0x302790b7acce9817, header.payload_hash);
}
