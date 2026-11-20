//! Encoder and decoder tests for the shared MVT wire format.
const std = @import("std");
const wire = @import("protobuf").wire;
const io = @import("../infra/io.zig");
const mvt = @import("mvt.zig");
const decoder = @import("mvt_decode.zig");
const testing = std.testing;

test "random MVT features round trip geometry, winding, extent and every value type" {
    var rng = std.Random.DefaultPrng.init(0x21520);
    const r = rng.random();
    const a = testing.allocator;
    for (0..320) |_| {
        const grid = @as(u32, 1) << (6 + r.uintLessThan(u5, 7));
        var layer = try mvt.Layer.initExtent(a, "mixed", grid);
        defer layer.deinit();
        var tile: std.ArrayList(u8) = .empty;
        defer tile.deinit(a);
        const x = @as(i32, @intCast(r.uintLessThan(u32, grid))) - 12;
        const y = @as(i32, @intCast(r.uintLessThan(u32, grid))) - 12;
        const w = @as(i32, @intCast(r.uintLessThan(u32, grid))) + 15;
        const h = @as(i32, @intCast(r.uintLessThan(u32, grid))) + 15;
        const points = [_]mvt.Point{ p(x, y), p(x + w, y + h), p(x - w, y + h) };
        const line1 = [_]mvt.Point{ p(x, y), p(x + 3, y + 2), p(x + 6, y - 2), p(x + 8, y + 2) };
        const line2 = [_]mvt.Point{ p(x - 6, y - 1), p(x - 4, y + 4) };
        const exterior_input = [_]mvt.Point{ p(x, y), p(x, y + h), p(x + w, y + h), p(x + w, y), p(x, y) };
        const exterior = [_]mvt.Point{ p(x, y), p(x + w, y), p(x + w, y + h), p(x, y + h) };
        const interior_input = [_]mvt.Point{ p(x + 4, y + 4), p(x + 8, y + 4), p(x + 8, y + 8), p(x + 4, y + 8) };
        const interior = [_]mvt.Point{ p(x + 4, y + 4), p(x + 4, y + 8), p(x + 8, y + 8), p(x + 8, y + 4) };
        const rings = [_]mvt.Ring{ .{ .points = &exterior_input, .winding = .exterior }, .{ .points = &interior_input, .winding = .interior } };
        const props = [_]mvt.Property{
            .{ .key = "name", .value = .{ .string = "tram" } },
            .{ .key = "length", .value = .{ .float = r.float(f32) * 40 } },
            .{ .key = "weight", .value = .{ .double = r.float(f64) * 20 } },
            .{ .key = "floor", .value = .{ .signed = r.int(i64) } },
            .{ .key = "counts", .value = .{ .unsigned = r.int(u64) } },
            .{ .key = "offset", .value = .{ .zigzag = r.int(i64) } },
            .{ .key = "open", .value = .{ .boolean = r.boolean() } },
        };
        try layer.addPoints(10, &points, &props, .none);
        try layer.addLines(11, &.{ &line1, &line2 }, &props, .none);
        try layer.addPolygon(12, &rings, &props, .none);
        try layer.write(&tile, .none);
        try testing.expectError(error.DuplicateLayer, layer.write(&tile, .none));

        var decoded = try decoder.parse(a, tile.items, .none);
        defer decoded.deinit();
        try testing.expectEqual(1, decoded.layers.len);
        const out = decoded.layers[0];
        try testing.expectEqual(grid, out.extent);
        try testing.expectEqual(2, out.version);
        try testing.expectEqualStrings("mixed", out.name);
        try testing.expectEqual(props.len, out.keys.len);
        try testing.expectEqual(props.len, out.values.len);
        try testing.expectEqual(3, out.features.len);
        for (out.features, 0..) |feature, i| {
            try testing.expectEqual(@as(?u64, 10 + i), feature.id);
            try testing.expectEqual(props.len * 2, feature.tags.len);
            for (props, 0..) |prop, j| {
                try testing.expectEqualStrings(prop.key, out.keys[feature.tags[2 * j]]);
                try testing.expectEqualDeep(prop.value, out.values[feature.tags[2 * j + 1]]);
            }
        }
        try testing.expectEqual(.point, out.features[0].kind.?);
        try testing.expectEqualSlices(mvt.Point, &points, out.features[0].parts[0].points);
        try testing.expectEqual(.linestring, out.features[1].kind.?);
        try testing.expectEqualSlices(mvt.Point, &line1, out.features[1].parts[0].points);
        try testing.expectEqualSlices(mvt.Point, &line2, out.features[1].parts[1].points);
        try testing.expectEqual(.polygon, out.features[2].kind.?);
        try testing.expectEqual(.exterior, out.features[2].parts[0].winding.?);
        try testing.expectEqual(.interior, out.features[2].parts[1].winding.?);
        try testing.expectEqualSlices(mvt.Point, &exterior, out.features[2].parts[0].points);
        try testing.expectEqualSlices(mvt.Point, &interior, out.features[2].parts[1].points);
    }
}

test "MVT rounding preserves buffered coordinates and rejects invalid extents and deltas" {
    try testing.expectEqualDeep(p(-1, 1), try mvt.quantize(-0.5 / 4096.0, 0.5 / 4096.0, 4096));
    try testing.expectEqualDeep(p(-128, 4224), try mvt.quantize(-0.03125, 1.03125, 4096));
    try testing.expectError(error.InvalidExtent, mvt.quantize(1, 0, 0));
    try testing.expectError(error.InvalidGeometry, mvt.roundPoint(std.math.inf(f64), 0));
    var layer = mvt.Layer.init(testing.allocator, "bounds");
    defer layer.deinit();
    try testing.expectError(error.InvalidGeometry, layer.addPoint(0, p(std.math.minInt(i32), 0), &.{}, .none));
    try testing.expectError(error.InvalidGeometry, layer.addLine(1, &.{ p(3, 3), p(3, 3) }, &.{}, .none));
}

test "MVT decoder rejects extent zero, malformed commands and a corrupt gzip checksum" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidExtent, decoder.parse(a, &.{ 26, 7, 120, 2, 10, 1, 'x', 40, 0 }, .none));
    var layer = mvt.Layer.init(a, "polygons");
    defer layer.deinit();
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try layer.addPolygon(1, &.{.{ .points = &.{ p(0, 0), p(20, 0), p(20, 20), p(0, 20) }, .winding = .exterior }}, &.{}, .none);
    try layer.write(&raw, .none);

    const gzipped = try mvt.gzip(a, raw.items, .none);
    defer a.free(gzipped);
    const inflated = try io.inflateGzip(a, gzipped, 4096, .none);
    defer a.free(inflated);
    try testing.expectEqualSlices(u8, raw.items, inflated);
    var decoded = try decoder.parse(a, inflated, .none);
    defer decoded.deinit();
    try testing.expectEqual(1, decoded.layers[0].features.len);
    gzipped[gzipped.len - 8] ^= 1;
    try testing.expectError(error.CorruptGzip, io.inflateGzip(a, gzipped, 4096, .none));

    var tile = wire.Reader.init(raw.items);
    var fields = wire.Reader.init((try tile.next(io.Deadline.none)).?.value.length_delimited);
    var changed = false;
    while (try fields.next(io.Deadline.none)) |field| {
        if (field.number != 2) continue;
        var feature = wire.Reader.init(field.value.length_delimited);
        while (try feature.next(io.Deadline.none)) |encoded| {
            if (encoded.number != 4) continue;
            const geometry = encoded.value.length_delimited;
            const offset = @intFromPtr(geometry.ptr) - @intFromPtr(raw.items.ptr) + geometry.len - 1;
            try testing.expectEqual(15, raw.items[offset]);
            raw.items[offset] = 23;
            changed = true;
        }
    }
    try testing.expect(changed);
    try testing.expectError(error.InvalidGeometry, decoder.parse(a, raw.items, .none));
}

fn p(x: i32, y: i32) mvt.Point {
    return .{ .x = x, .y = y };
}
