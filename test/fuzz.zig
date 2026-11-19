//! Fuzz targets for the parsers that read untrusted input (P1.20).
//!
//!   zig build fuzz                                  run every target's seeds once
//!   zig build fuzz -Dfuzz-target=lz4 --fuzz         fuzz one target until stopped
//!   zig build fuzz -Dfuzz-target=lz4 --fuzz=50M     ... for a number of runs
//!
//! Targets: `request` (the API request parser), `http` (request head, query
//! string, percent decoding), `polyline` (polyline 5/6/7 and varint
//! decoders), `lz4` (block and frame decoders, plus a compress round trip),
//! `dem` (the packed elevation block decoder), and `protobuf` (wire records
//! and generated message views), `config` (Valhalla JSON settings), and
//! `osm-pbf` (file framing, block inflation and OSM primitives), and
//! `node-store` (the build-time coordinate index format) and `graph-bundle`
//! (section headers, checksums and typed topology access).
//!
//! The contract for every parser: malformed input returns an error, never
//! panics, overflows or reads out of bounds. The fuzz step builds ReleaseSafe
//! so bounds and overflow checks stay on at full speed. A crasher becomes a
//! test in `test/fuzz/regressions.zig`, committed with its fix.
//!
//! Each target draws one byte slice. A seed is that slice prefixed with its
//! length as a little-endian u32, which is how `std.testing.Smith` reads it.

const std = @import("std");
const routing = @import("routing");
const lz4 = @import("lz4");
const protobuf = @import("protobuf");
const http = routing.server.http;
const request = routing.api.request;
const polyline = routing.geo.polyline;
const dem = routing.elevation.@"packed";
const Smith = std.testing.Smith;

/// Largest input a target draws.
const max_input = 64 * 1024;

fn draw(s: *Smith, buf: []u8, comptime hash: u32) []u8 {
    return buf[0..s.sliceWithHash(buf, hash)];
}

/// A seed in Smith's encoding for one slice draw.
fn seed(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, out[0..4], @intCast(bytes.len), .little);
    @memcpy(out[4..], bytes);
    return out;
}

fn seeds(gpa: std.mem.Allocator, raw: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, raw.len);
    for (out, raw) |*o, r| o.* = try seed(gpa, r);
    return out;
}

const graph = routing.graph;
const graph_fixture = @import("graph_fixture.zig");
const graph_kinds = std.enums.values(graph.format.SectionKind);
const graph_header_size = @sizeOf(graph.format.SectionHeader);

fn fuzzGraphBundle(baseline: *const graph.reader.Files, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const input = draw(s, &buf, 0x6772_6170);
    if (input.len == 0) return;
    const kind = graph_kinds[input[0] % graph_kinds.len];
    const raw = input[1..];
    var files = baseline.*;
    var section: [graph.format.payload_offset + max_input]u8 align(8) = undefined;
    if (raw.len < graph_header_size) {
        files.set(kind, raw);
    } else {
        const payload = raw[graph_header_size..];
        @memcpy(section[0..graph_header_size], raw[0..graph_header_size]);
        @memcpy(section[graph.format.payload_offset..][0..payload.len], payload);
        files.set(kind, section[0 .. graph.format.payload_offset + payload.len]);
    }
    const view = graph.reader.View.parse(files, null) catch return;
    view.verify(.none, null) catch {};
    const gpa = std.testing.allocator;
    const arbitrary = if (raw.len >= 4) std.mem.readInt(u32, raw[0..4], .little) else std.math.maxInt(u32);
    for ([_]u32{ 0, 1, arbitrary }) |id| {
        _ = view.node(@fromBackingInt(@intCast(id))) catch null;
        _ = view.edge(@fromBackingInt(@intCast(id))) catch null;
        _ = view.outEdges(@fromBackingInt(@intCast(id))) catch null;
        _ = view.turnRow(@fromBackingInt(@intCast(id)), @truncate(input[input.len - 1])) catch null;
        _ = view.class(@truncate(id)) catch null;
        const edge: graph.format.EdgeId = @fromBackingInt(id);
        _ = view.wayId(edge) catch null;
        _ = view.edgeSlopes(edge) catch null;
        if (view.shape(edge, gpa)) |shape| gpa.free(shape) else |_| {}
        if (view.names(edge)) |names| {
            for (0..names.count()) |i| _ = names.at(i) catch null;
        } else |_| {}
        if (view.oppEdge(@fromBackingInt(@intCast(id)))) |other| {
            try std.testing.expect(@backingInt(other) < view.edges.len);
        } else |_| {}
    }
}

test "fuzz graph-bundle" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var baseline: graph.reader.Files = .initFill(null);
    var candidates: [graph_kinds.len + 1][]const u8 = undefined;
    candidates[0] = &.{};
    inline for (graph_kinds, 0..) |kind, i| {
        const data = std.mem.sliceAsBytes(graph_fixture.records(kind));
        const header = graph_fixture.header(kind);
        const prefix = std.mem.asBytes(&header);
        const section = try a.alignedAlloc(u8, .of(u64), graph.format.payload_offset + data.len);
        @memcpy(section[0..prefix.len], prefix);
        @memcpy(section[graph.format.payload_offset..], data);
        baseline.set(kind, section);
        const raw = try a.alloc(u8, 1 + prefix.len + data.len);
        raw[0] = i;
        @memcpy(raw[1..][0..prefix.len], prefix);
        @memcpy(raw[1 + prefix.len ..], data);
        candidates[i + 1] = raw;
    }
    try std.testing.fuzz(&baseline, fuzzGraphBundle, .{ .corpus = try seeds(a, &candidates) });
}

fn fuzzOsmPbf(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const input = draw(s, &buf, 0x6f73_6d70);
    var memory: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var index = routing.build.pbf.file.Index.init(fixed.allocator(), input, .none) catch return;
    defer index.deinit();
    var scratch: [max_input]u8 = undefined;
    var primitives: routing.build.pbf.block.Scratch = .{};
    defer primitives.deinit(fixed.allocator());
    for (index.blobs, 0..) |blob, i| {
        const decoded = index.inflateInto(i, &scratch, .none) catch continue;
        try std.testing.expectEqual(blob.raw_size, decoded.len);
        try expectBorrowed(if (blob.compression == .raw) input else &scratch, decoded);
        const block = primitives.decode(fixed.allocator(), decoded, .none) catch continue;
        visitPrimitives(block, fixed.allocator()) catch {};
    }
}

fn visitTags(tags: routing.build.pbf.block.TagIterator) !void {
    var it = tags;
    while (try it.next()) |_| {}
}

fn visitPrimitives(block: routing.build.pbf.block.Block, gpa: std.mem.Allocator) !void {
    const tags = routing.build.tags;
    var tag_scratch: tags.Scratch = .{};
    var strings = tags.names.StringTable.init(gpa);
    defer strings.deinit();
    var nodes = block.nodes();
    while (try nodes.next()) |node| _ = try tags.transformNode(&tag_scratch, node.tags, .none);
    var ways = block.ways();
    while (try ways.next()) |item| {
        var way = item;
        _ = try tags.transformIndexedWay(&tag_scratch, &strings, way.tags, .{}, .none);
        while (try way.refs.next()) |_| {}
    }
    var relations = block.relations();
    while (try relations.next()) |item| {
        var relation = item;
        try visitTags(relation.tags);
        while (try relation.members.next()) |_| {}
    }
}

fn osmPrimitiveSeed(buffer: []u8) ![]const u8 {
    const pbf = routing.build.pbf.schema;
    const none = protobuf.no_deadline;
    var raw: [256]u8 = undefined;
    const data = try pbf.PrimitiveBlock.encode(&raw, .{
        .stringtable = .{ .s = &.{ "", "name", "A", "highway", "residential", "maxspeed", "30 mph", "name:en", "Avenue" } },
        .primitivegroup = &.{
            .{ .dense = .{ .id = &.{1}, .lat = &.{-2}, .lon = &.{3}, .keys_vals = &.{ 1, 2, 0 } } },
            .{ .nodes = &.{.{ .id = 2, .lat = 0, .lon = 0 }} },
            .{ .ways = &.{.{ .id = 3, .refs = &.{ 2, -1 }, .keys = &.{ 1, 3, 5, 7 }, .vals = &.{ 2, 4, 6, 8 } }} },
            .{ .relations = &.{.{ .id = 4, .roles_sid = &.{2}, .memids = &.{3}, .types = &.{1} }} },
        },
    }, none);
    const blob: pbf.Blob.Values = .{ .raw = data };
    const header = try pbf.BlobHeader.encode(buffer[4..], .{
        .type = "OSMData",
        .datasize = @intCast(try pbf.Blob.encodedSize(blob, none)),
    }, none);
    std.mem.writeInt(u32, buffer[0..4], @intCast(header.len), .big);
    const frame = try pbf.Blob.encode(buffer[4 + header.len ..], blob, none);
    return buffer[0 .. 4 + header.len + frame.len];
}

test "fuzz osm-pbf" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const header = "\x00\x00\x00\x0d\x0a\x09OSMHeader\x18\x12\x0a\x10\x22\x0eOsmSchema-V0.6";
    const raw = "\x00\x00\x00\x0b\x0a\x07OSMData\x18\x06\x0a\x04\x0a\x02\x0a\x00";
    const zlib = "\x00\x00\x00\x0b\x0a\x07OSMData\x18\x10\x1a\x0cx\x9c\xe3b\xe2b\x00\x00\x00F\x00\x17\x10\x04";
    const lz4_blob = "\x00\x00\x00\x0b\x0a\x07OSMData\x18\x09\x32\x05\x40\x0a\x02\x0a\x00\x10\x04";
    var primitive_frame: [256]u8 = undefined;
    const framed_primitives = try osmPrimitiveSeed(&primitive_frame);
    const primitive_file = try std.mem.concat(state.allocator(), u8, &.{ header, framed_primitives });
    try std.testing.fuzz({}, fuzzOsmPbf, .{ .corpus = try seeds(state.allocator(), &.{
        "",
        header,
        header ++ raw,
        header ++ zlib,
        header ++ lz4_blob,
        header ++ raw ++ zlib ++ lz4_blob,
        primitive_file,
        header ++ "\x00\x01\x00\x00",
    }) });
}

const NodeStoreFuzz = struct {
    file: routing.infra.io.File,
    mutex: routing.infra.io.Mutex = .{},
};

fn fuzzNodeStore(ctx: *NodeStoreFuzz, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const input = draw(s, &buf, 0x6e6f_6465);
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const file = ctx.file;
    try file.truncate(input.len);
    try file.pwriteAll(input, 0);
    const nodes = routing.build.node_store;
    const store = nodes.Store.open(file) catch return;
    var cursor: nodes.Cursor = .{};
    for ([_]i64{ 0, 1, 2, -1 }) |id| _ = cursor.lookup(store, id, .none) catch return;
}

test "fuzz node-store" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    var ctx: NodeStoreFuzz = .{ .file = try routing.infra.io.File.temporary(".") };
    defer ctx.file.close();
    // One block with ID 1 at (0, 0) and ID 2 at (+1, -1).
    var record: [76]u8 = @splat(0);
    record[0..8].* = "ZRNODE01".*;
    std.mem.writeInt(u64, record[8..16], 44, .little);
    std.mem.writeInt(u64, record[16..24], 2, .little);
    std.mem.writeInt(u64, record[24..32], 1, .little);
    record[40..44].* = .{ 1, 2, 1, 9 };
    std.mem.writeInt(u64, record[44..52], 0x8000_0000_0000_0001, .little);
    std.mem.writeInt(u64, record[52..60], 0x8000_0000_0000_0002, .little);
    std.mem.writeInt(u64, record[60..68], 32, .little);
    std.mem.writeInt(u32, record[68..72], 12, .little);
    std.mem.writeInt(u16, record[72..74], 2, .little);
    try std.testing.fuzz(&ctx, fuzzNodeStore, .{ .corpus = try seeds(state.allocator(), &.{
        "",
        &record,
        record[0 .. record.len - 1],
    }) });
}

fn fuzzConfig(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const input = draw(s, &buf, 0x636f_6e66);
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const loaded = routing.infra.config.decode(state.allocator(), input, "", null, null) catch return;
    _ = try loaded.config.httpConfig();
    try std.testing.expect(loaded.config.loki.actions.len != 0);
}

test "fuzz config" {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    try std.testing.fuzz({}, fuzzConfig, .{ .corpus = try seeds(state.allocator(), &.{
        "",
        "[]",
        "{}",
        \\{"httpd":{"service":{"listen":"tcp://*:0","timeout_seconds":5}},"loki":{"actions":["height"]}}
        ,
        \\{"service_limits":{"skadi":{"max_shape":18446744073709551616.0,"min_resample":1e100}}}
        ,
    }) });
}

const ProtoChild = protobuf.Message(&.{
    .{ .number = 1, .name = "id", .kind = .sint64, .presence = .required },
    .{ .number = 2, .name = "body", .kind = .bytes, .presence = .optional },
});
const ProtoInput = protobuf.Message(&.{
    .{ .number = 1, .name = "child", .kind = .message, .presence = .optional, .message = ProtoChild },
    .{ .number = 2, .name = "title", .kind = .string, .presence = .optional },
    .{ .number = 3, .name = "deltas", .kind = .sint32, .presence = .repeated, .packed_encoding = true },
    .{ .number = 4, .name = "fixed", .kind = .fixed32, .presence = .repeated },
    .{ .number = 5, .name = "children", .kind = .message, .presence = .repeated, .message = ProtoChild },
});

fn expectBorrowed(input: []const u8, field: []const u8) !void {
    const start = @intFromPtr(input.ptr);
    const address = @intFromPtr(field.ptr);
    try std.testing.expect(address >= start and address - start <= input.len);
    try std.testing.expect(field.len <= input.len - (address - start));
}

fn checkProtoChild(input: []const u8, child: ProtoChild.View) !void {
    _ = try child.get("id", protobuf.no_deadline);
    if (try child.get("body", protobuf.no_deadline)) |bytes| try expectBorrowed(input, bytes);
}

pub fn fuzzProtobuf(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const input = draw(s, &buf, 0x7072_6f74);
    const deadline = protobuf.no_deadline;
    var reader = protobuf.wire.Reader.init(input);
    while (reader.next(deadline) catch return) |field| {
        if (field.value == .length_delimited) try expectBorrowed(input, field.value.length_delimited);
    }
    const message = ProtoInput.decode(input, deadline) catch return;
    if (try message.get("title", deadline)) |title| try expectBorrowed(input, title);
    if (try message.get("child", deadline)) |child| try checkProtoChild(input, child);
    var children = try message.get("children", deadline);
    var count: usize = 0;
    while (try children.next(deadline)) |child| {
        try checkProtoChild(input, child);
        count += 1;
        try std.testing.expect(count <= input.len);
    }
    inline for (.{ "deltas", "fixed" }) |name| {
        var entries = try message.get(name, deadline);
        count = 0;
        while (try entries.next(deadline)) |_| {
            count += 1;
            try std.testing.expect(count <= input.len);
        }
    }
}

const protobuf_seeds = [_][]const u8{
    "",
    "\x0a\x02\x08\x07\x0a\x03\x12\x01A\x12\x02hi\x18\x01\x1a\x03\x00\x80\x01",
    "\x22\x04\x99\x88\x77\x66\x25\x01\x00\x00\x00\x2a\x02\x08\x04",
    "\x3b\x43\x08\x00\x44\x3c\x1a\x00",
    "\x1a\x01\x80",
    "\x12\x01\xff",
    "\x12\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
    "\x08\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02",
    "\x3b\x44",
};

test "fuzz protobuf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzProtobuf, .{ .corpus = try seeds(arena_state.allocator(), &protobuf_seeds) });
}

// ---------------------------------------------------------------------------
// request: the first byte picks the action path and whether the document
// comes from the body or a `?json=` query string; the rest is the document.

const paths = [_][]const u8{ "/route", "/height", "/locate", "/sources_to_targets", "/optimized_route", "/isochrone", "/trace_route", "/trace_attributes", "/status", "/expansion", "/centroid", "/tile", "/nope", "/" };

pub fn fuzzRequest(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const in = draw(s, &buf, 0x7265_7175);
    if (in.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = paths[in[0] % paths.len];
    const doc = in[1..];
    const via_query = in[0] & 0x80 != 0;
    const query: []const request.QueryParam = if (via_query) &.{
        .{ .key = "json", .value = doc },
        .{ .key = "id", .value = "fuzz" },
    } else &.{};
    const body = if (via_query) "" else doc;
    const fast = try request.parseHttp(arena, path, query, body);
    // The /height shape fast path must agree with the general parser.
    if (std.mem.eql(u8, path, "/height")) {
        const reference = try request.parseHttpReference(arena, path, query, body);
        try std.testing.expect(request.resultsEqual(fast, reference));
        try std.testing.expect(request.resultsEqual(try request.parseHttpForHeight(arena, path, query, body), reference));
    }
}

const request_seeds = [_][]const u8{
    "\x00{\"locations\":[{\"lat\":47.066161,\"lon\":9.569393},{\"lat\":47.115521,\"lon\":9.63313}],\"costing\":\"pedestrian\",\"costing_options\":{\"pedestrian\":{\"walkway_factor\":0.6,\"sidewalk_factor\":1,\"use_tracks\":0.8,\"max_hiking_difficulty\":3}},\"directions_type\":\"none\"}",
    "\x00{\"locations\":[{\"lat\":52.09,\"lon\":5.1,\"type\":\"via\"},{\"lat\":52.1,\"lon\":5.12,\"heading\":90}],\"costing\":\"bicycle\",\"costing_options\":{\"bicycle\":{\"use_roads\":0.2,\"use_hills\":0.4}},\"units\":\"miles\",\"date_time\":{\"type\":1,\"value\":\"2026-11-17T08:00\"}}",
    "\x01{\"shape\":[{\"lat\":47.1,\"lon\":9.5},{\"lat\":47.2,\"lon\":9.6}],\"range\":true,\"height_precision\":2,\"resample_distance\":30}",
    "\x01{\"shape\":[{\"lat\":47.242754,\"lon\":9.574113},{\"lat\":47.244662,\"lon\":9.566932},{\"lon\":9.560015,\"lat\":47.246979},{\"lat\":-0,\"lon\":1.5e2},{\"lat\":47.254214, \"lon\" : 9.548967}],\"range\":false}",
    "\x81{\"encoded_polyline\":\"_p~iF~ps|U_ulLnnqC_mqNvxq`@\",\"shape_format\":\"polyline5\",\"range\":false}",
    "\x08{\"verbose\":true}",
    "\x00{\"locations\":[]}",
    "\x00[1,2,3]",
    "\x00{\"locations\":[{\"lat\":\"x\",\"lon\":1e999}],\"costing\":7}",
};

test "fuzz request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzRequest, .{ .corpus = try seeds(arena_state.allocator(), &request_seeds) });
}

// ---------------------------------------------------------------------------
// http: the whole input is a request head; when it parses, its target is
// split into path and query and percent-decoded as the server does.

pub fn fuzzHttp(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const in = draw(s, &buf, 0x6874_7470);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = (http.parseHead(in, 16 * 1024, 1 << 20) catch return) orelse return;
    // Every slice the parser hands out lies inside the input.
    try std.testing.expect(head.head_len <= in.len);
    try std.testing.expect(head.headers_start <= head.head_len);
    const t0 = @intFromPtr(head.target.ptr) - @intFromPtr(in.ptr);
    try std.testing.expect(t0 + head.target.len <= head.head_len);
    try std.testing.expect(head.content_length <= 1 << 20);
    const q = std.mem.indexOfScalar(u8, head.target, '?');
    const path = try http.urlDecode(arena, if (q) |i| head.target[0..i] else head.target);
    try std.testing.expect(path.len <= head.target.len);
    if (q) |i| {
        for (try http.parseQuery(arena, head.target[i + 1 ..])) |p| {
            try std.testing.expect(p.key.len + p.value.len <= head.target.len);
        }
    }
}

const http_seeds = [_][]const u8{
    "POST /route HTTP/1.1\r\nHost: 127.0.0.1:8002\r\nContent-Type: application/json\r\nContent-Length: 14\r\n\r\n{\"range\":true}",
    "GET /height?json=%7B%22shape%22%3A%5B%5D%7D&id=a+b HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\n\r\n",
    "GET /status HTTP/1.0\r\n\r\n",
    "POST /route HTTP/1.1\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n",
    "GET /%zz%4?=%&&==%2 HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n",
    "GET  HTTP/1.1\r\n\r\n",
};

test "fuzz http" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzHttp, .{ .corpus = try seeds(arena_state.allocator(), &http_seeds) });
}

// ---------------------------------------------------------------------------
// polyline: the first byte picks the decoder (polyline at 5, 6 or 7 digits,
// or varint), the rest is the encoded line. A decoded line re-encodes and
// decodes back to the same points.

pub fn fuzzPolyline(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const in = draw(s, &buf, 0x706f_6c79);
    if (in.len == 0) return;
    const gpa = std.testing.allocator;
    switch (in[0] % 5) {
        0 => try roundTrip(.polyline, 5, gpa, in[1..]),
        1 => try roundTrip(.polyline, 6, gpa, in[1..]),
        2 => try roundTrip(.polyline, 7, gpa, in[1..]),
        3 => try roundTrip(.varint, 6, gpa, in[1..]),
        else => {
            var d = polyline.IntDecoder(i32).init(in[1..]);
            var n: usize = 0;
            while (d.next() catch null) |_| n += 1;
            try std.testing.expect(n <= in.len);
        },
    }
}

fn roundTrip(comptime format: polyline.Format, comptime digits: u8, gpa: std.mem.Allocator, bytes: []const u8) !void {
    const pts = polyline.decodeAlloc(gpa, format, digits, bytes) catch return;
    defer gpa.free(pts);
    // Every point takes at least two bytes (two varints).
    try std.testing.expect(pts.len * 2 <= bytes.len);
    const encoded = polyline.encodeAlloc(gpa, format, digits, pts) catch return;
    defer gpa.free(encoded);
    const again = try polyline.decodeAlloc(gpa, format, digits, encoded);
    defer gpa.free(again);
    try std.testing.expectEqual(pts.len, again.len);
    const eps = 1.0 / polyline.factor(digits);
    for (pts, again) |p, q| {
        try std.testing.expect(@abs(p.lat - q.lat) <= eps and @abs(p.lng - q.lng) <= eps);
    }
}

const polyline_seeds = [_][]const u8{
    "\x00_p~iF~ps|U_ulLnnqC_mqNvxq`@",
    "\x01{c`|yAqfqoQhAz@",
    "\x02??",
    "\x03\x80\x01\x02\xff\xff\xff\xff\x0f\x01",
    "\x04\x02\x04\x06\x81\x80\x80\x80\x80\x01",
    "\x00~~~~~~~~",
    "\x01@",
};

test "fuzz polyline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzPolyline, .{ .corpus = try seeds(arena_state.allocator(), &polyline_seeds) });
}

// ---------------------------------------------------------------------------
// lz4: the first byte picks the mode and the output size; the rest is the
// compressed input (block or frame), or plain data for a compress round trip.

pub fn fuzzLz4(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const in = draw(s, &buf, 0x6c7a_3421);
    if (in.len == 0) return;
    const gpa = std.testing.allocator;
    const data = in[1..];
    // Output sizes from tiny (to hit every bound check) to generous.
    const sizes = [_]usize{ 0, 1, 7, 15, 64, 4096, 1 << 18 };
    const dst = try gpa.alloc(u8, sizes[(in[0] >> 2) % sizes.len]);
    defer gpa.free(dst);
    switch (in[0] & 3) {
        0 => {
            const out = lz4.decompressBlock(data, dst) catch return;
            try std.testing.expect(out.len <= dst.len);
        },
        1 => {
            const r = lz4.decompressFrames(data, dst) catch return;
            try std.testing.expect(r.written <= dst.len and r.consumed <= data.len);
        },
        2 => {
            const out = lz4.decompressAlloc(gpa, data, 1 << 20) catch return;
            defer gpa.free(out);
            try std.testing.expect(out.len <= 1 << 20);
        },
        else => {
            const packed_bytes = try lz4.compressAlloc(gpa, data, .{});
            defer gpa.free(packed_bytes);
            const back = try lz4.decompressAlloc(gpa, packed_bytes, data.len + 1);
            defer gpa.free(back);
            try std.testing.expectEqualSlices(u8, data, back);
        },
    }
}

fn lz4Seeds(gpa: std.mem.Allocator) ![]const []const u8 {
    const samples = [_][]const u8{
        "Valhalla tiles, polylines and elevation rows compress well when they repeat: repeat repeat repeat repeat.",
        &@as([300]u8, @splat(0)),
        "{\"height\":[512,513,514,515,516,517,518,519,520]}",
    };
    var list: std.ArrayList([]const u8) = .empty;
    for (samples) |sample| {
        const frame = try lz4.compressAlloc(gpa, sample, .{});
        // Frame decoders on a real frame (several output sizes).
        for ([_]u8{ 0x01, 0x15, 0x19 }) |mode| try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{mode}, frame })));
        // The same bytes as plain data for the round trip.
        try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{0x03}, sample })));
        // A raw block: the frame's first block, after the 7-byte header and 4-byte size.
        if (frame.len > 15) {
            const block_len = std.mem.readInt(u32, frame[7..11], .little) & 0x7fff_ffff;
            if (11 + block_len <= frame.len) try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{0x18}, frame[11 .. 11 + block_len] })));
        }
    }
    try list.append(gpa, try seed(gpa, "\x00\xff\xff\xff\xff\x00"));
    try list.append(gpa, try seed(gpa, "\x01\x04\x22\x4d\x18\x64\x40\xa7"));
    return list.items;
}

test "fuzz lz4" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzLz4, .{ .corpus = try lz4Seeds(arena_state.allocator()) });
}

// ---------------------------------------------------------------------------
// dem: the packed elevation block decoder on arbitrary payloads, at the
// first byte's block size and predictor. A block that decodes re-encodes to
// a payload that decodes to the same posts.

pub fn fuzzDem(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const in = draw(s, &buf, 0x6465_6d21);
    if (in.len == 0) return;
    const sizes = [_]usize{ 64, 17, 1, 5 };
    const w = sizes[in[0] & 3];
    const h = sizes[(in[0] >> 2) & 3];
    const kind: dem.BlockKind = @fromBackingInt(@intCast((in[0] >> 4) & 3));
    var posts: [dem.block_dim * dem.block_dim]i16 = undefined;
    dem.decodeBlock(kind, in[1..], w, h, &posts) catch return;
    var out: [dem.max_block_payload]u8 = undefined;
    const len = dem.encodeBlock(.med, posts[0 .. w * h], w, h, &out);
    var back: [dem.block_dim * dem.block_dim]i16 = undefined;
    try dem.decodeBlockWith(.med, out[0..len], w, h, &back);
    try std.testing.expectEqualSlices(i16, posts[0 .. w * h], back[0 .. w * h]);
}

fn demSeeds(gpa: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var posts: [dem.block_dim * dem.block_dim]i16 = undefined;
    for (&posts, 0..) |*p, i| p.* = @intCast(@as(i32, @intCast(i % 64)) * 3 + @as(i32, @intCast(i / 64)) * 2 + 400 + @as(i32, @intCast(i % 7)));
    var out: [dem.max_block_payload]u8 = undefined;
    const med = dem.encodeBlock(.med, &posts, 64, 64, &out);
    try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{0x10}, out[0..med] })));
    const plane = dem.encodeBlock(.plane, &posts, 64, 64, &out);
    try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{0x20}, out[0..plane] })));
    const small = dem.encodeBlock(.med, posts[0 .. 17 * 17], 17, 17, &out);
    try list.append(gpa, try seed(gpa, try std.mem.concat(gpa, u8, &.{ &.{0x15}, out[0..small] })));
    try list.append(gpa, try seed(gpa, "\x10\xff\xff\xff"));
    return list.items;
}

test "fuzz dem" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.fuzz({}, fuzzDem, .{ .corpus = try demSeeds(arena_state.allocator()) });
}

test {
    _ = @import("fuzz/regressions.zig");
}
