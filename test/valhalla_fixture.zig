//! Two local Valhalla tiles describing opposing directions of one named edge.
const std = @import("std");
const routing = @import("routing");
const source = routing.cli.import_valhalla.tile_format;

pub const first_tile = 519_120;
pub const way: u64 = 0x0615_0123_4567_89ab;
pub const name = "Cycle Track";
pub const reverse_name = "Cycle Trail";
pub const left: routing.geo.FixedLL = .{ .lng = 2_499_000, .lat = 50_000 };
pub const right: routing.geo.FixedLL = .{ .lng = 2_501_000, .lat = 50_200 };

pub fn tile(reverse: bool) [512]u8 {
    const node_offset = @sizeOf(source.Header);
    const edge_offset = node_offset + @sizeOf(source.Node);
    const info_offset = edge_offset + @sizeOf(source.Edge);
    const id = first_tile + @as(u22, @intFromBool(reverse));
    const start = if (reverse) right else left;
    const lng = start.lng - if (reverse) @as(i32, 2_500_000) else 0;
    var header = std.mem.zeroes(source.Header);
    header.tile.id = .{ .tile = id };
    header.tile.elevation = true;
    header.base_ll = .{ if (reverse) 0.25 else 0, 0 };
    @memcpy(header.version[0..5], "3.9.3");
    header.counts.nodes = 1;
    header.counts.edges = 1;
    header.forward_restriction_offset = info_offset;
    header.reverse_restriction_offset = info_offset;
    header.edge_info_offset = info_offset;
    header.tile_size = 512;

    var node = std.mem.zeroes(source.Node);
    node.position.lng = @intCast(@divTrunc(lng, 10));
    node.position.lat = @intCast(@divTrunc(start.lat, 10));
    node.position.access = 7;
    node.edges.count = 1;
    node.edges.density = 4;
    node.flags.drive_on_right = true;

    var edge = std.mem.zeroes(source.Edge);
    edge.endpoint.node = .{ .tile = if (reverse) first_tile else first_tile + 1 };
    edge.endpoint.forward = !reverse;
    edge.endpoint.leaves_tile = true;
    edge.access.forward = 7;
    edge.access.reverse = 7;
    edge.access.max_up_slope = 12;
    edge.speed.base = 27;
    edge.speed.name_consistency = 1;
    edge.geometry.turn_types = 4;
    edge.geometry.length = 23;
    edge.geometry.grade = 6;
    edge.local.named = true;
    edge.local.stop_impacts = 3;
    edge.local.edge_to_right = 1;

    var data: [512]u8 = @splat(0);
    @memcpy(data[node_offset..][0..@sizeOf(source.Node)], std.mem.asBytes(&node));
    @memcpy(data[edge_offset..][0..@sizeOf(source.Edge)], std.mem.asBytes(&edge));
    var temp: [10]u8 = undefined;
    const zero: routing.geo.FixedLL = .{ .lng = 0, .lat = 0 };
    const a: routing.geo.FixedLL = .{ .lng = @divTrunc(left.lng, 10), .lat = @divTrunc(left.lat, 10) };
    const b: routing.geo.FixedLL = .{ .lng = @divTrunc(right.lng, 10), .lat = @divTrunc(right.lat, 10) };
    const shape_start = info_offset + 12 + 3 * 4;
    const front = routing.geo.polyline.encodeFixedVarint(a, zero, &temp);
    @memcpy(data[shape_start..][0..front.len], front);
    const back = routing.geo.polyline.encodeFixedVarint(b, a, &temp);
    const shape_len = front.len + back.len;
    const extra_start = shape_start + shape_len;
    @memcpy(data[shape_start + front.len ..][0..back.len], back);
    data[extra_start] = 0x15;
    data[extra_start + 1] = 0x06;
    header.text_offset = @intCast(extra_start + 2);
    header.lane_connectivity_offset = 512;
    header.predicted_speed_offset = 512;
    @memcpy(data[0..@sizeOf(source.Header)], std.mem.asBytes(&header));
    std.mem.writeInt(u32, data[info_offset..][0..4], @truncate(way), .little);
    std.mem.writeInt(u32, data[info_offset + 4 ..][0..4], 310 | (5 << 12) | (42 << 16) | (0x23 << 24), .little);
    std.mem.writeInt(u32, data[info_offset + 8 ..][0..4], 3 | (@as(u32, @intCast(shape_len)) << 4) | (0x01 << 20) | (2 << 28), .little);
    std.mem.writeInt(u32, data[info_offset + 12 ..][0..4], 1 << 28, .little);
    std.mem.writeInt(u32, data[info_offset + 16 ..][0..4], (1 << 29) | (name.len + 1), .little);
    std.mem.writeInt(u32, data[info_offset + 20 ..][0..4], (1 << 29) | (name.len + 4), .little);
    const text = data[header.text_offset..];
    // Route name, layer 2, and one indoor range from 1.0 to 2.5.
    @memcpy(text[0..name.len], if (reverse) reverse_name else name);
    @memcpy(text[name.len + 1 ..][0..9], "\x01\x02\x00\x08\x06\x02\x14\x32\x00");
    return data;
}

pub fn archive() [4096]u8 {
    var bytes: [4096]u8 = @splat(0);
    tarHeader(bytes[0..512], "index.bin", "00000000040");
    const a: source.ArchiveEntry = .{ .offset = 1536, .tile_id = (first_tile << 3) | 2, .size = 512 };
    const b: source.ArchiveEntry = .{ .offset = 2560, .tile_id = ((first_tile + 1) << 3) | 2, .size = 512 };
    @memcpy(bytes[512..528], std.mem.asBytes(&a));
    @memcpy(bytes[528..544], std.mem.asBytes(&b));
    tarHeader(bytes[1024..1536], "2/000/519/120.gph", "00000001000");
    tarHeader(bytes[2048..2560], "2/000/519/121.gph", "00000001000");
    @memcpy(bytes[1536..2048], &tile(false));
    @memcpy(bytes[2560..3072], &tile(true));
    return bytes;
}

fn tarHeader(out: []u8, filename: []const u8, size: []const u8) void {
    @memcpy(out[0..filename.len], filename);
    @memcpy(out[124..135], size);
    out[156] = '0';
    @memcpy(out[257..262], "ustar");
    var checksum: u32 = 8 * ' ';
    for (out) |byte| checksum += byte;
    _ = std.fmt.bufPrint(out[148..154], "{o:0>6}", .{checksum}) catch unreachable;
    out[155] = ' ';
}
