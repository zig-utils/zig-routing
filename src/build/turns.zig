// Ported from src/baldr/turn.cc, src/mjolnir/util.cc and
// src/mjolnir/graphenhancer.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const constants = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const names = @import("tags/names.zig");
const DriveSide = @import("edge_class.zig").DriveSide;

pub const Type = enum(u3) {
    straight,
    slight_right,
    right,
    sharp_right,
    reverse,
    sharp_left,
    left,
    slight_left,
};

pub fn turnType(degrees: u32) Type {
    return switch (degrees % 360) {
        0...10, 350...359 => .straight,
        11...44 => .slight_right,
        45...135 => .right,
        136...159 => .sharp_right,
        160...200 => .reverse,
        201...224 => .sharp_left,
        225...315 => .left,
        316...349 => .slight_left,
        else => unreachable,
    };
}

pub fn encode(kind: Type, stop: u3, consistent: bool) u8 {
    return @as(u8, @backingInt(kind)) | (@as(u8, stop) << 3) | (@as(u8, @intFromBool(consistent)) << 6);
}

/// Turn headings are stored and recovered using Valhalla's NodeInfo byte
/// quantization, even though the bundle only retains the resulting turn.
pub fn heading(points: []const geo.FixedLL, forward: bool, class: *const EdgeClass, deadline: io.Deadline) !u16 {
    if (points.len < 2) return error.InvalidSegmentShape;
    const dist = constants.headingOffset(class.category.road_class, class.category.use);
    const start = points[if (forward) 0 else points.len - 1].toPoint();
    var target = points[if (forward) points.len - 1 else 0].toPoint();
    var previous = start;
    var travelled: f64 = 0;
    for (1..points.len) |i| {
        if (points.len == 2 or travelled >= dist) break;
        if ((i - 1) % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const next = points[if (forward) i else points.len - 1 - i].toPoint();
        const length = previous.distance(next);
        if (travelled + length > dist) {
            const fraction = (dist - travelled) / length;
            target = .{
                .lng = previous.lng + (next.lng - previous.lng) * fraction,
                .lat = previous.lat + (next.lat - previous.lat) * fraction,
            };
            break;
        }
        travelled += length;
        previous = next;
    }
    const rounded = @as(u16, @intFromFloat(@round(start.heading(target)))) % 360;
    const shrink: f32 = 255.0 / 359.0;
    const expand: f32 = 359.0 / 255.0;
    const stored: f32 = @round(@as(f32, @floatFromInt(rounded)) * shrink);
    return @intFromFloat(@round(stored * expand));
}

pub const Approach = struct {
    bearing: u16,
    class: *const EdgeClass,
    names: []const names.Id,
};

pub const max_degree = 32;
pub const max_matrix_size = max_degree * max_degree;

pub fn matrix(approaches: []const Approach, signal: bool, side: DriveSide, out: []u8, deadline: io.Deadline) !void {
    const degree = approaches.len;
    if (degree > max_degree or out.len != degree * degree) return error.InvalidTurnMatrix;
    var all_links = true;
    var physical_count: usize = 0;
    for (approaches) |edge| {
        if (edge.class.flags.node_connector) continue;
        physical_count += 1;
        all_links = all_links and edge.class.flags.link;
    }
    for (approaches, 0..) |from, in_local| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const from_heading = (from.bearing + 180) % 360;
        for (approaches, 0..) |to, out_local| {
            const entry = &out[in_local * degree + out_local];
            if (from.class.flags.node_connector or to.class.flags.node_connector) {
                entry.* = encode(.straight, 0, true);
                continue;
            }
            const degrees = (to.bearing + 360 - from_heading) % 360;
            const kind = turnType(degrees);
            const stop = stopImpact(approaches, in_local, out_local, kind, signal, all_links, physical_count, side);
            entry.* = encode(kind, stop, try sameNames(from.names, to.names, deadline));
        }
    }
}

fn sameNames(a: []const names.Id, b: []const names.Id, deadline: io.Deadline) !bool {
    if (a.len == 0 or b.len == 0) return a.len == b.len;
    if (a.ptr == b.ptr) return true;
    for (a) |name| {
        for (b, 0..) |other, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (name == other) return true;
        }
    }
    return false;
}

fn isUse(class: *const EdgeClass, use: constants.Use) bool {
    return class.category.use == @backingInt(use);
}

fn stopImpact(approaches: []const Approach, from: usize, to: usize, kind: Type, signal: bool, all_links: bool, physical_count: usize, side: DriveSide) u3 {
    const entry = approaches[from].class;
    const exit = approaches[to].class;
    if (entry.flags.roundabout and exit.flags.roundabout) return 0;

    // Pencil-point and cycleway U-turn refinements need the later costing data.

    const unclassified = @backingInt(constants.RoadClass.unclassified);
    var best: u8 = unclassified;
    var competing = false;
    for (approaches, 0..) |other, i| {
        if (i == from or i == to or other.class.flags.node_connector) continue;
        if (other.class.reverseAccess().auto) {
            const rc: u8 = other.class.category.road_class;
            best = @min(best, rc + @as(u8, if (other.class.flags.roundabout) 2 else 0));
        }
        competing = competing or other.class.forwardAccess().auto or other.class.reverseAccess().auto;
    }
    if (!competing and from != to) return 0;

    const from_class: u8 = @min(entry.category.road_class, unclassified);
    if (isUse(entry, .turn_channel) and isUse(exit, .turn_channel) and best < unclassified) return 7;

    var stop: u8 = @intCast(@max(0, @as(i16, from_class) - @as(i16, best) + 3));
    const sharp = kind == .sharp_left or kind == .sharp_right or kind == .reverse;
    const slight = kind == .straight or kind == .slight_left or kind == .slight_right;
    const controlled = signal or entry.flags.traffic_signal or entry.flags.stop_sign;
    if (all_links) {
        stop = if (sharp) stop + 2 else if (slight) stop / 2 else stop -| 1;
    } else if (isUse(entry, .ramp) and isUse(exit, .ramp) and best < unclassified) {
        if (controlled) {
            stop = 4;
        } else if (physical_count > 3) {
            stop += 2;
        }
    } else if (isUse(entry, .ramp) and !isUse(exit, .ramp) and !entry.flags.internal and !exit.flags.internal) {
        stop += if (sharp) @as(u8, 3) else if (slight) 1 else 2;
    } else if (isUse(entry, .turn_channel)) {
        stop = if (sharp) stop + 2 else if (isUse(exit, .ramp)) stop + 1 else if (slight) stop / 2 else stop -| 1;
    } else if (isUse(entry, .parking_aisle) and isUse(exit, .parking_aisle)) {
        stop -|= 1;
    } else {
        const crosses_traffic = if (side == .right) kind == .sharp_left or kind == .left else kind == .sharp_right or kind == .right;
        const to_class = exit.category.road_class;
        if (crosses_traffic and from_class != to_class and !isUse(exit, .ramp) and !isUse(exit, .turn_channel)) {
            if (controlled) {
                stop += 2;
            } else if (@abs(@as(i16, from_class) - @as(i16, to_class)) > 1) {
                stop += 1;
            }
        }
    }
    return @intCast(@min(7, stop));
}

pub const Pool = struct {
    storage: std.heap.ArenaAllocator,
    indices: std.StringHashMapUnmanaged(u32) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .storage = .init(allocator) };
    }

    pub fn deinit(self: *Pool) void {
        self.indices.deinit(self.storage.child_allocator);
        self.bytes.deinit(self.storage.child_allocator);
        self.storage.deinit();
    }

    pub fn intern(self: *Pool, value: []const u8) !u32 {
        if (self.indices.get(value)) |offset| return offset;
        const offset = std.math.cast(u32, self.bytes.items.len) orelse return error.TurnPoolTooLarge;
        if (value.len > std.math.maxInt(u32) - offset) return error.TurnPoolTooLarge;
        const gpa = self.storage.child_allocator;
        try self.indices.ensureUnusedCapacity(gpa, 1);
        try self.bytes.ensureUnusedCapacity(gpa, value.len);
        const owned = try self.storage.allocator().dupe(u8, value);
        self.indices.putAssumeCapacityNoClobber(owned, offset);
        self.bytes.appendSliceAssumeCapacity(value);
        return offset;
    }
};

test "Valhalla turn threshold boundaries" {
    const limits = [_]u32{ 0, 10, 11, 28, 44, 45, 90, 135, 136, 148, 159, 160, 180, 200, 201, 213, 224, 225, 270, 315, 316, 333, 349, 350, 359, 360, 450, 810 };
    const expected = [_]Type{
        .straight,    .straight, .slight_right, .slight_right, .slight_right, .right,      .right, .right, .sharp_right, .sharp_right, .sharp_right,
        .reverse,     .reverse,  .reverse,      .sharp_left,   .sharp_left,   .sharp_left, .left,  .left,  .left,        .slight_left, .slight_left,
        .slight_left, .straight, .straight,     .straight,     .right,        .right,
    };
    for (limits, expected) |angle, kind| try std.testing.expectEqual(kind, turnType(angle));
}

test "turn headings follow the local polyline in each orientation" {
    const shape = [_]geo.FixedLL{
        .{ .lng = 0, .lat = 0 },
        .{ .lng = 0, .lat = 3000 },
        .{ .lng = 4000, .lat = 3000 },
    };
    const class: EdgeClass = .{ .category = .{ .road_class = @backingInt(constants.RoadClass.primary) } };
    try std.testing.expectEqual(0, try heading(&shape, true, &class, .none));
    try std.testing.expectEqual(270, try heading(&shape, false, &class, .none));
}

test "turn pool deduplicates complete identical matrices" {
    var pool = Pool.init(std.testing.allocator);
    defer pool.deinit();
    try std.testing.expectEqual(0, try pool.intern(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(4, try pool.intern(&.{ 7, 6, 5, 4 }));
    try std.testing.expectEqual(0, try pool.intern(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 7, 6, 5, 4 }, pool.bytes.items);
}
