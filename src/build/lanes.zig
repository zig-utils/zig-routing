// Ported from src/mjolnir/pbfgraphparser.cc and src/mjolnir/graphenhancer.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const format = @import("../graph/format.zig");
const lanes = @import("../graph/lanes.zig");
const checkpoint = @import("checkpoint.zig");
const names = @import("tags/names.zig");
const turns = @import("turns.zig");
const Relation = @import("pbf/block.zig").Relation;
const Allocator = std.mem.Allocator;

const masks_by_name = std.StaticStringMap(lanes.Mask).initComptime(.{
    .{ "none", lanes.none },                   .{ "through", lanes.through },               .{ "sharp_left", lanes.sharp_left },
    .{ "left", lanes.left },                   .{ "slight_left", lanes.slight_left },       .{ "slight_right", lanes.slight_right },
    .{ "right", lanes.right },                 .{ "sharp_right", lanes.sharp_right },       .{ "reverse", lanes.reverse },
    .{ "merge_to_left", lanes.merge_to_left }, .{ "merge_to_right", lanes.merge_to_right },
});

pub fn parseTurnLanes(a: Allocator, out: *std.ArrayList(lanes.Mask), text: []const u8, deadline: io.Deadline) !void {
    out.clearRetainingCapacity();
    if (text.len == 0) return;
    var start: usize = 0;
    var mask: lanes.Mask = 0;
    for (text, 0..) |byte, i| {
        try checkDeadline(deadline, i);
        if (byte != ';' and byte != '|') continue;
        mask |= masks_by_name.get(text[start..i]) orelse 0;
        start = i + 1;
        if (byte == '|') {
            try out.append(a, mask);
            mask = 0;
        }
    }
    try out.append(a, mask | (masks_by_name.get(text[start..]) orelse 0));
}

pub fn packConnection(text: []const u8, deadline: io.Deadline) error{ InvalidLaneConnectivity, DeadlineExceeded }!u64 {
    var separated = std.mem.splitScalar(u8, text, '|');
    var mask: u64 = 0;
    var position: usize = 0;
    while (separated.next()) |token| : (position += 1) {
        if (position == lanes.Connection.max_lanes) return error.InvalidLaneConnectivity;
        const digits = if (std.mem.startsWith(u8, token, "+")) token[1..] else token;
        var end: usize = 0;
        while (end < digits.len and std.ascii.isDigit(digits[end])) : (end += 1) try checkDeadline(deadline, end);
        const lane = std.fmt.parseInt(u4, digits[0..end], 10) catch return error.InvalidLaneConnectivity;
        mask |= @as(u64, lane) << @as(u6, @intCast(4 * position));
    }
    return mask;
}

const WayRow = extern struct {
    id: i64,
    tags: [2]names.Id,
};

pub const Link = extern struct {
    to: i64,
    from: u64,
    to_lanes: u64,
    from_lanes: u64,

    fn key(_: void, row: Link) u64 {
        return @intCast(row.to);
    }

    fn compare(id: i64, row: Link) std.math.Order {
        return std.math.order(id, row.to);
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(WayRow) == 16 and @offsetOf(WayRow, "id") == 0 and @offsetOf(WayRow, "tags") == 8);
    std.debug.assert(@sizeOf(Link) == 32 and @offsetOf(Link, "to") == 0 and @offsetOf(Link, "from") == 8);
    std.debug.assert(@offsetOf(Link, "to_lanes") == 16 and @offsetOf(Link, "from_lanes") == 24);
}

pub const Catalog = struct {
    a: Allocator,
    deadline: io.Deadline,
    ways: std.AutoHashMapUnmanaged(i64, [2]names.Id) = .empty,
    links: std.ArrayList(Link) = .empty,

    pub fn deinit(self: *Catalog) void {
        self.ways.deinit(self.a);
        self.links.deinit(self.a);
    }

    pub fn addWay(self: *Catalog, id: i64, forward: names.Id, backward: names.Id) !void {
        if (forward == .empty and backward == .empty) return;
        try self.ways.putNoClobber(self.a, id, .{ forward, backward });
    }

    pub fn addRelation(self: *Catalog, relation: Relation) !void {
        var connectivity = false;
        var from: []const u8 = "";
        var to: []const u8 = "";
        var from_lanes: []const u8 = "";
        var to_lanes: []const u8 = "";
        var tags = relation.tags;
        while (try tags.next()) |tag| {
            if (std.mem.eql(u8, tag.key, "type")) {
                connectivity = connectivity or std.mem.eql(u8, tag.value, "connectivity");
            } else if (std.mem.eql(u8, tag.key, "from")) {
                from = tag.value;
            } else if (std.mem.eql(u8, tag.key, "to")) {
                to = tag.value;
            } else if (std.mem.eql(u8, tag.key, "from:lanes")) {
                from_lanes = tag.value;
            } else if (std.mem.eql(u8, tag.key, "to:lanes")) {
                to_lanes = tag.value;
            }
        }
        if (!connectivity) return;
        if (std.mem.order(u8, from, from_lanes) == .lt) from = from_lanes;
        if (std.mem.order(u8, to, to_lanes) == .lt) to = to_lanes;
        if (from.len == 0 or to.len == 0) return;
        var from_way: i64 = 0;
        var to_way: i64 = 0;
        var members = relation.members;
        while (try members.next()) |member| {
            if (member.type != .way) continue;
            if (std.mem.eql(u8, member.role, "from")) from_way = member.ref;
            if (std.mem.eql(u8, member.role, "to")) to_way = member.ref;
        }
        if (from_way <= 0 or to_way <= 0) return;
        const from_mask = packConnection(from, self.deadline) catch |err| switch (err) {
            error.InvalidLaneConnectivity => null,
            else => return err,
        };
        const to_mask = packConnection(to, self.deadline) catch |err| switch (err) {
            error.InvalidLaneConnectivity => null,
            else => return err,
        };
        // Valhalla omits the destination way's group if any connection fails.
        try self.links.append(self.a, .{
            .to = to_way,
            .from = if (from_mask == null or to_mask == null) 0 else @intCast(from_way),
            .to_lanes = to_mask orelse 0,
            .from_lanes = from_mask orelse 0,
        });
    }

    pub fn prepare(self: *Catalog) !void {
        if (self.links.items.len < 2) return;
        const scratch = try self.a.alloc(Link, self.links.items.len);
        defer self.a.free(scratch);
        try radix.sortByU64(Link, self.a, self.links.items, scratch, {}, Link.key, self.deadline);
    }

    pub fn linksTo(self: *const Catalog, id: i64) []const Link {
        const items = self.links.items;
        const start = std.sort.lowerBound(Link, items, id, Link.compare);
        if (start == items.len or items[start].to != id) return &.{};
        return items[start .. start + std.sort.upperBound(Link, items[start..], id, Link.compare)];
    }

    pub fn saveWays(self: *const Catalog, tx: *checkpoint.Transaction) !void {
        if (self.ways.count() == 0) return;
        const rows = try self.a.alloc(WayRow, self.ways.count());
        defer self.a.free(rows);
        var items = self.ways.iterator();
        for (rows, 0..) |*row, i| {
            try checkDeadline(self.deadline, i);
            const entry = items.next().?;
            row.* = .{ .id = entry.key_ptr.*, .tags = entry.value_ptr.* };
        }
        try tx.writeArray(rows, .way_lanes);
    }

    pub fn loadWays(self: *Catalog, saved: *const checkpoint.Existing, strings: *const names.StringTable) !void {
        if (saved.manifest.files.get(.way_lanes) == null) return;
        const map = try saved.map(.way_lanes, self.deadline);
        defer map.unmap();
        for (try checkpoint.array(WayRow, map), 0..) |row, i| {
            try checkDeadline(self.deadline, i);
            if (self.ways.contains(row.id) or strings.get(row.tags[0]) == null or strings.get(row.tags[1]) == null)
                return error.InvalidCheckpoint;
            try self.addWay(row.id, row.tags[0], row.tags[1]);
        }
    }

    pub fn loadLinks(self: *Catalog, saved: *const checkpoint.Existing) !void {
        if (saved.manifest.files.get(.lane_relations) == null) return;
        const map = try saved.map(.lane_relations, self.deadline);
        defer map.unmap();
        const rows = try checkpoint.array(Link, map);
        for (rows, 0..) |row, i| {
            try checkDeadline(self.deadline, i);
            if (row.to <= 0 or (row.to_lanes | row.from_lanes) >> 60 != 0 or (i != 0 and rows[i - 1].to > row.to))
                return error.InvalidCheckpoint;
        }
        try self.links.appendSlice(self.a, rows);
    }
};

pub const ExitTurns = std.EnumSet(turns.Type);
const left_turns: lanes.Mask = lanes.left | lanes.sharp_left | lanes.slight_left;
const right_turns: lanes.Mask = lanes.right | lanes.sharp_right | lanes.slight_right;

pub fn enhance(masks: []lanes.Mask, scratch: []lanes.Mask, exits: ExitTurns, restricted: bool, deadline: io.Deadline) !bool {
    if (masks.len == 0) return false;
    @memcpy(scratch, masks);
    if (try fillLeft(scratch, true, deadline)) {
        @memcpy(masks, scratch);
        return true;
    }
    if (exits.count() == 0) return false;

    @memcpy(scratch, masks);
    if (try fillLeft(scratch, false, deadline)) {
        if (!restricted and hasSide(exits, .left, .slight_left, .sharp_left))
            addTurns(&scratch[scratch.len - 1], exits, .right, .slight_right, .sharp_right);
        @memcpy(masks, scratch);
        return true;
    }
    if (isGap(masks[0]) and masks[masks.len - 1] & right_turns != 0) {
        @memcpy(scratch, masks);
        if (try fillRight(scratch, deadline)) {
            if (!restricted and hasSide(exits, .right, .slight_right, .sharp_right))
                addTurns(&scratch[0], exits, .left, .slight_left, .sharp_left);
            @memcpy(masks, scratch);
            return true;
        }
    }
    for ([_]bool{ false, true }) |backward| {
        const start = if (backward) masks.len - 1 else 0;
        const end = if (backward) 0 else masks.len - 1;
        if (masks[start] & lanes.through == 0 or !isGap(masks[end])) continue;
        @memcpy(scratch, masks);
        if (try fillStraight(scratch, backward, deadline)) {
            if (!restricted) {
                addTurns(&scratch[0], exits, .left, .slight_left, .sharp_left);
                addTurns(&scratch[scratch.len - 1], exits, .right, .slight_right, .sharp_right);
            }
            @memcpy(masks, scratch);
            return true;
        }
    }
    return true;
}

fn isGap(mask: lanes.Mask) bool {
    return mask == 0 or mask == lanes.none;
}

fn fillLeft(masks: []lanes.Mask, end_on_right: bool, deadline: io.Deadline) !bool {
    var started = false;
    var changed = false;
    for (masks, 0..) |*mask, i| {
        try checkDeadline(deadline, i);
        if (mask.* & (left_turns | lanes.through) != 0) {
            started = true;
        } else if (started and isGap(mask.*)) {
            mask.* = lanes.through;
            changed = true;
        } else {
            return started and end_on_right and mask.* & right_turns != 0;
        }
    }
    return !end_on_right and changed;
}

fn fillRight(masks: []lanes.Mask, deadline: io.Deadline) !bool {
    var started = false;
    var changed = false;
    for (0..masks.len) |i| {
        try checkDeadline(deadline, i);
        const mask = &masks[masks.len - i - 1];
        if (mask.* & (right_turns | lanes.through) != 0) {
            started = true;
        } else if (started and isGap(mask.*)) {
            mask.* = lanes.through;
            changed = true;
        } else return false;
    }
    return changed;
}

fn fillStraight(masks: []lanes.Mask, backward: bool, deadline: io.Deadline) !bool {
    var previous: lanes.Mask = 0;
    var changed = false;
    for (0..masks.len) |i| {
        try checkDeadline(deadline, i);
        const mask = &masks[if (backward) masks.len - i - 1 else i];
        // The pinned reverse pass uses the last lane to test the through bit.
        const through_mask = if (backward) masks[masks.len - 1] else mask.*;
        if (through_mask & lanes.through != 0 and (previous == 0 or previous & lanes.through != 0)) {
            previous = mask.*;
        } else if (previous != 0 and isGap(mask.*)) {
            mask.* = lanes.through;
            changed = true;
        } else return false;
    }
    return changed;
}

fn hasSide(exits: ExitTurns, side: turns.Type, slight: turns.Type, sharp: turns.Type) bool {
    return exits.contains(side) or exits.contains(slight) or exits.contains(sharp);
}

fn addTurns(mask: *lanes.Mask, exits: ExitTurns, comptime side: turns.Type, comptime slight: turns.Type, comptime sharp: turns.Type) void {
    if (mask.* == lanes.through and exits.contains(.straight) and exits.contains(slight)) mask.* |= turnMask(slight);
    if (exits.contains(side)) mask.* |= turnMask(side);
    if (exits.contains(sharp)) mask.* |= turnMask(sharp);
}

fn turnMask(comptime turn: turns.Type) lanes.Mask {
    return switch (turn) {
        .straight => lanes.through,
        else => @field(lanes, @tagName(turn)),
    };
}

pub const Output = struct {
    a: Allocator,
    entries: std.ArrayList(lanes.Entry) = .empty,
    masks: std.ArrayList(lanes.Mask) = .empty,
    connections: std.ArrayList(lanes.Connection) = .empty,
    parsed: std.ArrayList(lanes.Mask) = .empty,
    enhanced: std.ArrayList(lanes.Mask) = .empty,

    pub fn deinit(self: *Output) void {
        self.entries.deinit(self.a);
        self.masks.deinit(self.a);
        self.connections.deinit(self.a);
        self.parsed.deinit(self.a);
        self.enhanced.deinit(self.a);
    }

    pub fn addTurns(self: *Output, edge: u32, exits: ExitTurns, restricted: bool, deadline: io.Deadline) !bool {
        try self.enhanced.resize(self.a, self.parsed.items.len);
        if (!try enhance(self.parsed.items, self.enhanced.items, exits, restricted, deadline)) return false;
        const offset = std.math.cast(u32, self.masks.items.len) orelse return error.TooManyLaneMasks;
        try self.entries.append(self.a, .{ .edge = edge, .offset = offset });
        try self.masks.appendSlice(self.a, self.parsed.items);
        return true;
    }

    pub fn addConnections(self: *Output, edge: u32, links: []const Link, deadline: io.Deadline) !void {
        for (links, 0..) |link, i| {
            try checkDeadline(deadline, i);
            if (link.from == 0) return;
        }
        for (links, 0..) |link, i| {
            try checkDeadline(deadline, i);
            try self.connections.append(self.a, .{ .edge = edge, .from_way = link.from, .to_lanes = link.to_lanes, .from_lanes = link.from_lanes });
        }
    }

    pub fn write(self: *const Output, writer: *format.BundleWriter) !void {
        if (self.entries.items.len != 0) try writer.stream(.turnlanes, self, emitTurns);
        if (self.connections.items.len != 0) try writer.write(.lane_connectivity, self.connections.items);
    }

    fn emitTurns(self: *const Output, writer: *format.SectionWriter(.turnlanes)) !void {
        const count: u32 = @intCast(self.entries.items.len);
        try writer.append(&.{ @truncate(count), @truncate(count >> 16) });
        try writer.append(std.mem.bytesAsSlice(u16, std.mem.sliceAsBytes(self.entries.items)));
        try writer.append(self.masks.items);
    }
};

fn checkDeadline(deadline: io.Deadline, index: usize) error{DeadlineExceeded}!void {
    if (index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

// Ported from test/turnlanes.cc, keeping the bit order and empty positions.
test "Valhalla turn lanes preserve empty lanes and known indications" {
    const testing = std.testing;
    const a = testing.allocator;
    var parsed: std.ArrayList(lanes.Mask) = .empty;
    defer parsed.deinit(a);
    const cases = [_]struct { text: []const u8, masks: []const lanes.Mask }{
        .{ .text = "left|through;right|", .masks = &.{ lanes.left, lanes.through | lanes.right, 0 } },
        .{ .text = "|through;right||none|slight_left|left", .masks = &.{ 0, lanes.through | lanes.right, 0, lanes.none, lanes.slight_left, lanes.left } },
        .{ .text = "merge_to_left||reverse|merge_to_right", .masks = &.{ lanes.merge_to_left, 0, lanes.reverse, lanes.merge_to_right } },
        .{ .text = "none||none||none|", .masks = &.{ lanes.none, 0, lanes.none, 0, lanes.none, 0 } },
        .{ .text = "|blah||none||none|", .masks = &.{ 0, 0, 0, lanes.none, 0, lanes.none, 0 } },
        .{ .text = "blah|blah|", .masks = &.{ 0, 0, 0 } },
        .{ .text = "", .masks = &.{} },
    };
    for (cases) |case| {
        try parseTurnLanes(a, &parsed, case.text, .none);
        try testing.expectEqualSlices(lanes.Mask, case.masks, parsed.items);
    }
}

// Ported from test/laneconnectivity.cc.
test "Valhalla lane connectivity preserves order and rejects invalid lists" {
    const testing = std.testing;
    try testing.expectEqual(0x44321, try packConnection("1|2|3|4|4", .none));
    try testing.expectEqual(0x121, try packConnection("1|2|1", .none));
    try testing.expectEqual(0xF, try packConnection("15", .none));
    try testing.expectEqual(0xFEDCBA987654321, try packConnection("1|2|3|4|5|6|7|8|9|10|11|12|13|14|15", .none));
    for ([_][]const u8{ "1|16", "1|1|1|1|1|1|1|1|1|1|1|1|1|1|1|1", "|1|", "|", "||", "-1" }) |bad|
        try testing.expectError(error.InvalidLaneConnectivity, packConnection(bad, .none));
    try testing.expectEqual(4, lanes.Connection.lane(0x44321, 4));
}
