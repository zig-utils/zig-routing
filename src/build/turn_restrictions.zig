// Ported from src/mjolnir/pbfgraphparser.cc and lua/graph.lua (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const pbf = @import("pbf/root.zig");
const Access = @import("../graph/constants.zig").AccessMask;
const Allocator = std.mem.Allocator;

pub const Kind = enum(u4) {
    no_left_turn,
    no_right_turn,
    no_straight_on,
    no_u_turn,
    only_right_turn,
    only_left_turn,
    only_straight_on,
    no_entry,
    no_exit,
    no_turn,

    pub fn only(self: Kind) bool {
        return switch (self) {
            .only_right_turn, .only_left_turn, .only_straight_on => true,
            else => false,
        };
    }
};

pub const Record = extern struct {
    relation: i64,
    via: i64,
    from: i64,
    to: i64,
    attr: packed struct(u32) {
        modes: u16,
        kind: u4,
        mode_specific: bool,
        reserved: u11 = 0,
    },
    reserved: u32 = 0,

    pub fn kind(self: Record) !Kind {
        if (self.reserved != 0 or self.attr.reserved != 0 or self.attr.modes & 0xf800 != 0 or
            self.via == 0 or self.from == 0 or self.to == 0 or
            (!self.attr.mode_specific and self.attr.modes != simple_modes))
            return error.InvalidCheckpoint;
        return std.enums.fromInt(Kind, self.attr.kind) orelse error.InvalidCheckpoint;
    }
};

pub const Stats = struct {
    parsed: u64 = 0,
    resolved: u64 = 0,
    invalid_members: u64 = 0,
    unsupported_type: u64 = 0,
    deferred: u64 = 0,
    missing_via: u64 = 0,
    missing_from: u64 = 0,
    missing_to: u64 = 0,
    mask_truncated: u64 = 0,
};

pub const Source = struct {
    entries: []const Record = &.{},
    stats: Stats = .{},
};

const general_modes = bits(.{
    .auto = true,
    .moped = true,
    .taxi = true,
    .bus = true,
    .bicycle = true,
    .truck = true,
    .emergency = true,
    .motorcycle = true,
});
pub const simple_modes = general_modes | bits(.{ .hov = true });

const mode_names = std.StaticStringMap(u16).initComptime(.{
    .{ "motorcar", bits(.{ .auto = true, .moped = true }) },
    .{ "motorcycle", bits(.{ .motorcycle = true }) },
    .{ "taxi", bits(.{ .taxi = true }) },
    .{ "bus", bits(.{ .bus = true }) },
    .{ "bicycle", bits(.{ .bicycle = true }) },
    .{ "hgv", bits(.{ .truck = true }) },
    .{ "hazmat", bits(.{ .truck = true }) },
    .{ "emergency", bits(.{ .emergency = true }) },
    .{ "foot", bits(.{ .pedestrian = true, .wheelchair = true }) },
});

fn bits(mask: Access) u16 {
    return @bitCast(mask);
}

pub const Catalog = struct {
    a: Allocator,
    deadline: io.Deadline,
    entries: std.ArrayList(Record) = .empty,
    seen: std.AutoHashMapUnmanaged(i64, void) = .empty,
    stats: Stats = .{},

    pub fn deinit(self: *Catalog) void {
        self.entries.deinit(self.a);
        self.seen.deinit(self.a);
    }

    pub fn add(self: *Catalog, relation: pbf.block.Relation) !void {
        var tags = relation.tags;
        var is_restriction = false;
        var timed = false;
        var probable = false;
        var legacy_time = false;
        var ordinary: ?Kind = null;
        var modes: std.EnumArray(Kind, u16) = .initFill(0);
        var has_modes = false;
        var exceptions: []const u8 = "";
        while (try tags.next()) |tag| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (eql(tag.key, "type")) {
                is_restriction = eql(tag.value, "restriction");
            } else if (eql(tag.key, "except")) {
                exceptions = tag.value;
            } else if (eql(tag.key, "restriction")) {
                ordinary = std.meta.stringToEnum(Kind, tag.value);
            } else if (std.mem.startsWith(u8, tag.key, "restriction:")) {
                const name = tag.key["restriction:".len..];
                if (eql(name, "conditional")) {
                    timed = try annotated(tag.value, self.deadline);
                } else if (eql(name, "probable")) {
                    probable = try annotated(tag.value, self.deadline);
                } else if (mode_names.get(name)) |mode| {
                    if (std.meta.stringToEnum(Kind, tag.value)) |kind| {
                        modes.getPtr(kind).* |= mode;
                        has_modes = true;
                    }
                }
            } else if (eql(tag.key, "hour_on") or eql(tag.key, "hour_off") or
                eql(tag.key, "day_on") or eql(tag.key, "day_off"))
            {
                legacy_time = true;
            }
        }
        if (!is_restriction and !timed and !probable) return;
        const entry = try self.seen.getOrPut(self.a, relation.id);
        if (entry.found_existing) return;
        self.stats.parsed += 1;
        if (timed or legacy_time or (ordinary == null and probable)) {
            self.stats.deferred += 1;
            return;
        }
        if (ordinary == null and !has_modes) {
            self.stats.unsupported_type += 1;
            return;
        }
        var row: Record = .{ .relation = relation.id, .via = 0, .from = 0, .to = 0, .attr = undefined };
        var members = relation.members;
        var via_count: usize = 0;
        while (try members.next()) |member| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (member.type == .way and eql(member.role, "from")) {
                row.from = member.ref;
            } else if (member.type == .way and eql(member.role, "to")) {
                if (row.to == 0) row.to = member.ref;
            } else if (eql(member.role, "via")) {
                if (member.type == .way) {
                    self.stats.deferred += 1;
                    return;
                }
                if (member.type == .node) {
                    row.via = member.ref;
                    via_count += 1;
                }
            }
        }
        if (via_count > 1) {
            self.stats.deferred += 1;
            return;
        }
        if (row.via == 0 or row.from == 0 or row.to == 0) {
            self.stats.invalid_members += 1;
            return;
        }
        if (has_modes) {
            for (std.enums.values(Kind), modes.values) |kind, mask| {
                if (mask == 0) continue;
                row.attr = .{ .kind = @backingInt(kind), .modes = mask, .mode_specific = true };
                try self.entries.append(self.a, row);
            }
        } else {
            row.attr = .{
                .kind = @backingInt(ordinary.?),
                .modes = if (exceptions.len == 0) simple_modes else try exceptModes(exceptions, self.deadline),
                .mode_specific = exceptions.len != 0,
            };
            try self.entries.append(self.a, row);
        }
    }
};

fn annotated(text: []const u8, deadline: io.Deadline) !bool {
    for (text, 0..) |char, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (char == '@') return std.meta.stringToEnum(Kind, std.mem.trimEnd(u8, text[0..i], " ")) != null;
    }
    return false;
}

fn exceptModes(text: []const u8, deadline: io.Deadline) !u16 {
    var modes: u16 = general_modes;
    var tokens = std.mem.tokenizeScalar(u8, text, ';');
    while (tokens.next()) |token| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const name = std.mem.trim(u8, token, " \t");
        if (eql(name, "psv")) {
            modes &= ~bits(.{ .taxi = true, .bus = true });
        } else if (!eql(name, "hazmat")) {
            modes &= ~(mode_names.get(name) orelse 0);
        }
    }
    return modes;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Record) == 40 and @offsetOf(Record, "via") == 8 and @offsetOf(Record, "attr") == 32);
}
