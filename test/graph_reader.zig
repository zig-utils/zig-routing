const std = @import("std");
const routing = @import("routing");
const format = routing.graph.format;
const reader = routing.graph.reader;
const io = routing.infra.io;
const testing = std.testing;
const sample = @import("graph_fixture.zig");
const edges = sample.records(.edges);

const Fixture = struct {
    parent: io.Directory,
    root: io.Directory,
    name: io.Directory.TempName,

    fn create() !Fixture {
        const parent = try io.Directory.open(".");
        errdefer parent.close();
        const root = try parent.temporaryChild();
        errdefer {
            root.dir.close();
            parent.deleteDir(&root.name) catch {};
        }
        const fixture: Fixture = .{ .parent = parent, .root = root.dir, .name = root.name };
        var buf: [80]u8 = undefined;
        try sample.write(fixture.path(&buf));
        return fixture;
    }

    fn path(self: *const Fixture, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/bundle", .{self.name}) catch unreachable;
    }

    fn section(self: *const Fixture, file: format.SectionKind) !io.File {
        var buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{s}/bundle/{s}", .{ self.name, file.filename() });
        return io.File.open(name, .read_write);
    }

    fn deinit(self: Fixture) void {
        if (self.root.child("bundle")) |dir| {
            for (std.enums.values(format.SectionKind)) |kind| dir.deleteFile(kind.filename()) catch {};
            dir.close();
            self.root.deleteDir("bundle") catch {};
        } else |_| {}
        self.root.close();
        self.parent.deleteDir(&self.name) catch {};
        self.parent.close();
    }
};

test "mapped records have checked typed accessors and offline checksums" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    var bundle = try reader.Bundle.open(fixture.path(&buf));
    defer bundle.close();
    const view = &bundle.view;
    try view.verify(.none, null);
    try testing.expectEqual(sample.header(.nodes).dataset_uuid, view.dataset_uuid);
    try testing.expectEqual(1234, (try view.edge(@fromBackingInt(@intCast(0)))).geom.len_m);
    try testing.expectEqual(5, (try view.node(@fromBackingInt(@intCast(1)))).attr.density);
    try testing.expectEqualSlices(format.EdgeHot, edges[1..], try view.outEdges(@fromBackingInt(@intCast(1))));
    try testing.expectEqual(@as(format.EdgeId, @fromBackingInt(@intCast(1))), try view.oppEdge(@fromBackingInt(@intCast(0))));
    try testing.expectEqual(@as(format.EdgeId, @fromBackingInt(@intCast(0))), try view.oppEdge(@fromBackingInt(@intCast(1))));
    try testing.expectEqualSlices(u8, &.{0x72}, try view.turnRow(@fromBackingInt(@intCast(1)), 0));
    try testing.expectError(error.InvalidNodeId, view.node(@fromBackingInt(@intCast(2))));
    try testing.expectError(error.InvalidEdgeId, view.edge(@fromBackingInt(@intCast(2))));
    try testing.expectError(error.InvalidLocalEdge, view.turnRow(@fromBackingInt(@intCast(1)), 1));
}

test "reader rejects wrong magic, version, section kind, mixed UUIDs and sizes" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path_name = fixture.path(&buf);
    const file = try fixture.section(.edges);
    defer file.close();
    const good = sample.header(.edges);

    const mutations = [_]struct { off: usize, data: []const u8, failure: anyerror }{
        .{ .off = @offsetOf(format.SectionHeader, "magic_tag"), .data = "X", .failure = error.InvalidMagic },
        .{ .off = @offsetOf(format.SectionHeader, "format_version"), .data = "\x02", .failure = error.UnsupportedFormatVersion },
        .{ .off = @offsetOf(format.SectionHeader, "kind"), .data = "\x01", .failure = error.InvalidSectionKind },
        .{ .off = @offsetOf(format.SectionHeader, "dataset_uuid"), .data = "\xff", .failure = error.DatasetUuidMismatch },
        .{ .off = @offsetOf(format.SectionHeader, "record_size"), .data = "\x08", .failure = error.InvalidRecordSize },
        .{ .off = @offsetOf(format.SectionHeader, "reserved"), .data = "\x01", .failure = error.InvalidReservedBytes },
        .{ .off = @offsetOf(format.SectionHeader, "count"), .data = &@as([8]u8, @splat(0xff)), .failure = error.SectionSizeOverflow },
    };
    for (mutations) |mutation| {
        try file.pwriteAll(mutation.data, mutation.off);
        var diagnostic: reader.Diagnostic = .{};
        try testing.expectError(mutation.failure, reader.Bundle.openDescribed(path_name, &diagnostic));
        try testing.expectEqual(@as(?format.SectionKind, .edges), diagnostic.section);
        try file.pwriteAll(std.mem.asBytes(&good), 0);
    }
    const size = try file.size();
    try file.truncate(size + 1);
    try testing.expectError(error.TrailingSectionData, reader.Bundle.open(path_name));
    try file.truncate(size - 1);
    try testing.expectError(error.TruncatedSection, reader.Bundle.open(path_name));
    try file.truncate(8);
    try testing.expectError(error.TruncatedHeader, reader.Bundle.open(path_name));
}

test "startup skips hashing while accessors safely reject corrupt payloads" {
    const fixture = try Fixture.create();
    defer fixture.deinit();
    var buf: [80]u8 = undefined;
    const path_name = fixture.path(&buf);

    const offsets = try fixture.section(.first_edge);
    defer offsets.close();
    try offsets.pwriteAll(&.{ 0xff, 0xff, 0xff, 0xff }, format.payload_offset + @sizeOf(u32));
    {
        var bundle = try reader.Bundle.open(path_name);
        defer bundle.close();
        var diagnostic: reader.Diagnostic = .{};
        try testing.expectError(error.PayloadHashMismatch, bundle.view.verify(.none, &diagnostic));
        try testing.expectEqual(@as(?format.SectionKind, .first_edge), diagnostic.section);
        try testing.expectError(error.InvalidCsrRange, bundle.view.outEdges(@fromBackingInt(@intCast(0))));
        try testing.expectError(error.InvalidCsrRange, bundle.view.oppEdge(@fromBackingInt(@intCast(1))));
    }
    try offsets.pwriteAll(std.mem.sliceAsBytes(sample.records(.first_edge)), format.payload_offset);
    const node_file = try fixture.section(.nodes);
    defer node_file.close();
    try node_file.pwriteAll(&.{ 0xff, 0xff, 0xff, 0xff }, format.payload_offset);
    const edge_file = try fixture.section(.edges);
    defer edge_file.close();
    var bad = edges[0];
    bad.cls.opp_local = 31;
    try edge_file.pwriteAll(std.mem.asBytes(&bad), format.payload_offset);

    var bundle = try reader.Bundle.open(path_name);
    defer bundle.close();
    try testing.expectError(error.InvalidTurnOffset, bundle.view.turnRow(@fromBackingInt(@intCast(0)), 0));
    try testing.expectError(error.InvalidOpposingEdge, bundle.view.oppEdge(@fromBackingInt(@intCast(0))));
}
