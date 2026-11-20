// Ported from src/baldr/turn.cc, src/mjolnir/util.cc and
// src/mjolnir/graphenhancer.cc (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/point.zig");
const io = @import("../infra/io.zig");
const constants = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const names = @import("tags/names.zig");
const DriveSide = @import("edge_class.zig").DriveSide;
const turn_sides = @import("../graph/turn_sides.zig");
const headings = @import("../graph/headings.zig");

const turn = @import("../graph/turn.zig");
pub const Type = turn.Type;
pub const turnType = turn.classify;

pub fn encode(kind: Type, stop: u3, consistent: bool) u8 {
    return @as(u8, @backingInt(kind)) | (@as(u8, stop) << 3) | (@as(u8, @intFromBool(consistent)) << 6);
}

pub fn heading(points: []const geo.FixedLL, forward: bool, class: *const EdgeClass, deadline: io.Deadline) !u16 {
    return storedHeading(try rawHeading(points, forward, class, deadline));
}

pub const rawHeading = headings.sample;

pub fn storedHeading(rounded: u16) u16 {
    return headings.decode(headings.encode(rounded));
}

pub const Approach = struct {
    bearing: u16,
    length: u24,
    class: *const EdgeClass,
    names: []const names.Id,
};

pub const max_degree = 32;
pub const max_matrix_size = max_degree * max_degree;

pub fn matrix(approaches: []const Approach, signal: bool, side: DriveSide, out: []u8, sides: []u2, deadline: io.Deadline) !void {
    const degree = approaches.len;
    if (degree > max_degree or out.len != degree * degree or sides.len != out.len) return error.InvalidTurnMatrix;
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
            const index = in_local * degree + out_local;
            const entry = &out[index];
            if (from.class.flags.node_connector or to.class.flags.node_connector) {
                entry.* = encode(.straight, 0, true);
                sides[index] = 0;
                continue;
            }
            const degrees = (to.bearing + 360 - from_heading) % 360;
            const kind = turnType(degrees);
            const consistent = try sameNames(from.names, to.names, deadline);
            const crossing = edgeSides(approaches, physical_count, in_local, out_local, from_heading, degrees);
            const stop = if (from.class.flags.roundabout and to.class.flags.roundabout)
                0
            else if (uTurnStop(from, to, degrees, side, crossing, consistent))
                7
            else
                stopImpact(approaches, in_local, out_local, kind, signal, all_links, physical_count, side);
            entry.* = encode(kind, stop, consistent);
            sides[index] = @bitCast(crossing);
        }
    }
}

// ProcessEdgeTransitions classifies sides relative to both the incoming
// heading and the selected outgoing edge. Construction is not a crossing.
fn edgeSides(approaches: []const Approach, physical_count: usize, from: usize, to: usize, heading_from: u16, turn_degrees: u16) turn_sides.Sides {
    var result: turn_sides.Sides = .{};
    if (physical_count <= 2) return result;
    for (approaches, 0..) |edge, index| {
        if (index == from or index == to or edge.class.flags.node_connector or isUse(edge.class, .construction)) continue;
        const degrees = (edge.bearing + 360 - heading_from) % 360;
        if (turn_degrees > 180) {
            result.right = result.right or degrees > turn_degrees or degrees < 180;
            result.left = result.left or (degrees < turn_degrees and degrees > 180);
        } else {
            result.right = result.right or (degrees > turn_degrees and degrees < 180);
            result.left = result.left or degrees < turn_degrees or degrees > 180;
        }
        if (result.left and result.right) break;
    }
    return result;
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

fn uTurnStop(from: Approach, to: Approach, degrees: u16, side: DriveSide, crossing: turn_sides.Sides, consistent: bool) bool {
    const short = from.length < 50 or to.length < 50;
    const angle_matches = switch (side) {
        .right => degrees >= 180 and degrees < @as(u16, if (short) 226 else 211),
        .left => degrees > @as(u16, if (short) 134 else 149) and degrees <= 180,
    };
    if (!angle_matches) return false;
    if (isUse(from.class, .cycleway) and isUse(to.class, .cycleway) and crossing.left and crossing.right) return true;
    const across = switch (side) {
        .right => crossing.right and !crossing.left,
        .left => crossing.left and !crossing.right,
    };
    return across and consistent and
        !from.class.forwardAccess().auto and from.class.reverseAccess().auto and
        to.class.forwardAccess().auto and !to.class.reverseAccess().auto;
}

fn stopImpact(approaches: []const Approach, from: usize, to: usize, kind: Type, signal: bool, all_links: bool, physical_count: usize, side: DriveSide) u3 {
    const entry = approaches[from].class;
    const exit = approaches[to].class;

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

test "Valhalla pencil-point and cycleway U-turn stop impacts" {
    const testing = std.testing;
    const enter: EdgeClass = .{ .access = .{ .reverse = @bitCast(constants.AccessMask{ .auto = true }) } };
    const exit: EdgeClass = .{ .access = .{ .forward = @bitCast(constants.AccessMask{ .auto = true }) } };
    const crossing: EdgeClass = .{ .access = .{ .forward = @bitCast(constants.AccessMask{ .auto = true }) } };
    var approaches = [_]Approach{
        .{ .bearing = 0, .length = 40, .class = &enter, .names = &.{} },
        .{ .bearing = 39, .length = 70, .class = &exit, .names = &.{} },
        .{ .bearing = 90, .length = 70, .class = &crossing, .names = &.{} },
    };
    var entries: [9]u8 = undefined;
    var sides: [9]u2 = undefined;
    try matrix(&approaches, false, .right, &entries, &sides, .none);
    try testing.expectEqual(7, (entries[1] >> 3) & 7);
    approaches[0].length = 50;
    try matrix(&approaches, false, .right, &entries, &sides, .none);
    try testing.expectEqual(4, (entries[1] >> 3) & 7);

    const cycleway: EdgeClass = .{ .category = .{ .use = @backingInt(constants.Use.cycleway) } };
    const cycleways = [_]Approach{
        .{ .bearing = 0, .length = 40, .class = &cycleway, .names = &.{} },
        .{ .bearing = 39, .length = 70, .class = &cycleway, .names = &.{} },
        .{ .bearing = 90, .length = 70, .class = &crossing, .names = &.{} },
        .{ .bearing = 8, .length = 70, .class = &crossing, .names = &.{} },
    };
    var cycle_entries: [16]u8 = undefined;
    var cycle_sides: [16]u2 = undefined;
    try matrix(&cycleways, false, .right, &cycle_entries, &cycle_sides, .none);
    try testing.expectEqual(7, (cycle_entries[1] >> 3) & 7);
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

/// A sparse rank directory and a deduplicated pool of 2-bit turn matrices.
/// Append nodes in CSR order. Nodes without side data consume no reference.
pub const SidePool = struct {
    gpa: std.mem.Allocator,
    directory: []u32,
    references: std.ArrayList(u32) = .empty,
    matrices: Pool,

    pub fn init(gpa: std.mem.Allocator, nodes: usize) !SidePool {
        const directory = try gpa.alloc(u32, turn_sides.directoryEnd(nodes));
        @memset(directory, 0);
        return .{ .gpa = gpa, .directory = directory, .matrices = .init(gpa) };
    }

    pub fn deinit(self: *SidePool) void {
        self.gpa.free(self.directory);
        self.references.deinit(self.gpa);
        self.matrices.deinit();
    }

    pub fn append(self: *SidePool, node: usize, sides: []const u2) !void {
        if (std.mem.allEqual(u2, sides, 0)) return;
        var words: [max_matrix_size / turn_sides.entries_per_word]u32 = @splat(0);
        for (sides, 0..) |side, i| {
            const shift: u5 = @intCast(i % turn_sides.entries_per_word * 2);
            words[i / turn_sides.entries_per_word] |= @as(u32, side) << shift;
        }
        const count = (sides.len + turn_sides.entries_per_word - 1) / turn_sides.entries_per_word;
        const offset = try self.matrices.intern(std.mem.sliceAsBytes(words[0..count]));
        const block = 1 + (node / turn_sides.block_nodes) * 2;
        if (self.directory[block] == 0)
            self.directory[block + 1] = std.math.cast(u32, self.directory.len + self.references.items.len) orelse return error.TurnPoolTooLarge;
        self.directory[block] |= @as(u32, 1) << @as(u5, @truncate(node));
        try self.references.append(self.gpa, offset / @sizeOf(u32));
    }

    pub fn finish(self: *const SidePool, deadline: io.Deadline) ![]u32 {
        const matrices_start = self.directory.len + self.references.items.len;
        const count = matrices_start + self.matrices.bytes.items.len / @sizeOf(u32);
        if (count > std.math.maxInt(u32)) return error.TurnPoolTooLarge;
        const words = try self.gpa.alloc(u32, count);
        errdefer self.gpa.free(words);
        @memcpy(words[0..self.directory.len], self.directory);
        words[0] = @intCast(matrices_start);
        for (words[self.directory.len..matrices_start], self.references.items, 0..) |*slot, offset, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            slot.* = @intCast(matrices_start + offset);
        }
        @memcpy(std.mem.sliceAsBytes(words[matrices_start..]), self.matrices.bytes.items);
        return words;
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
