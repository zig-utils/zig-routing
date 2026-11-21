// Ported from src/mjolnir/pbfgraphparser.cc and lua/graph.lua (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const pbf = @import("pbf/root.zig");
const Access = @import("../graph/constants.zig").AccessMask;
const time_parsing = @import("time_parsing.zig");
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
        probability: u7 = 0,
        reserved: u4 = 0,
    },
    reserved: u32 = 0,

    pub fn kind(self: Record) !Kind {
        if (self.reserved != 0 or self.attr.reserved != 0 or self.attr.modes & 0xf800 != 0 or self.attr.probability > 100 or
            self.via == 0 or self.from == 0 or self.to == 0 or
            (!self.attr.mode_specific and (self.attr.modes != simple_modes or self.attr.probability != 0)))
            return error.InvalidCheckpoint;
        return std.enums.fromInt(Kind, self.attr.kind) orelse error.InvalidCheckpoint;
    }
};

pub const Complex = extern struct {
    from: i64,
    to: i64,
    first_via: u32,
    attr: packed struct(u32) {
        modes: u16,
        kind: u4,
        via_count: u5,
        probability: u7 = 0,
    },

    pub fn kind(self: Complex) !Kind {
        if (self.from == 0 or self.to == 0 or self.attr.via_count == 0 or self.attr.probability > 100 or
            self.attr.modes & 0xf800 != 0) return error.InvalidCheckpoint;
        return std.enums.fromInt(Kind, self.attr.kind) orelse error.InvalidCheckpoint;
    }

    pub fn vias(self: Complex, ways: []const i64) ![]const i64 {
        const first: usize = self.first_via;
        const end = first + self.attr.via_count;
        if (end > ways.len) return error.InvalidCheckpoint;
        return ways[first..end];
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
    complex: u64 = 0,
    invalid_condition: u64 = 0,
    invalid_probability: u64 = 0,
};

pub const Source = struct {
    entries: []const Record = &.{},
    stats: Stats = .{},
    complex: []const Complex = &.{},
    via_ways: []const i64 = &.{},
    simple_domains: []const u64 = &.{},
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
    complex: std.ArrayList(Complex) = .empty,
    via_ways: std.ArrayList(i64) = .empty,
    simple_domains: std.ArrayList(u64) = .empty,
    parsed_domains: std.ArrayList(u64) = .empty,
    condition_text: std.ArrayList(u8) = .empty,
    time_parser: ?time_parsing.Parser = null,
    seen: std.AutoHashMapUnmanaged(i64, void) = .empty,
    stats: Stats = .{},

    pub fn deinit(self: *Catalog) void {
        self.entries.deinit(self.a);
        self.complex.deinit(self.a);
        self.via_ways.deinit(self.a);
        self.simple_domains.deinit(self.a);
        self.parsed_domains.deinit(self.a);
        self.condition_text.deinit(self.a);
        if (self.time_parser) |*parser| parser.deinit();
        self.seen.deinit(self.a);
    }

    pub fn source(self: *const Catalog) Source {
        return .{
            .entries = self.entries.items,
            .stats = self.stats,
            .complex = self.complex.items,
            .via_ways = self.via_ways.items,
            .simple_domains = self.simple_domains.items,
        };
    }

    pub noinline fn add(self: *Catalog, relation: pbf.block.Relation) !void {
        var tags = relation.tags;
        var is_restriction = false;
        var preferred_tag = false;
        var conditional: ?Annotated = null;
        var probable_text: ?[]const u8 = null;
        var legacy: Legacy = .{};
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
                preferred_tag = true;
                ordinary = std.meta.stringToEnum(Kind, tag.value);
            } else if (std.mem.startsWith(u8, tag.key, "restriction:")) {
                const name = tag.key["restriction:".len..];
                if (eql(name, "conditional")) {
                    preferred_tag = true;
                    conditional = try annotated(tag.value, self.deadline);
                } else if (eql(name, "probable")) {
                    probable_text = tag.value;
                } else if (mode_names.get(name)) |mode| {
                    if (std.meta.stringToEnum(Kind, tag.value)) |kind| {
                        modes.getPtr(kind).* |= mode;
                        has_modes = true;
                    }
                }
            } else if (std.meta.stringToEnum(LegacyKey, tag.key)) |key| {
                legacy.fields.getPtr(key).* = tag.value;
                legacy.present = true;
            }
        }
        if (!is_restriction and conditional == null and probable_text == null) return;
        const entry = try self.seen.getOrPut(self.a, relation.id);
        if (entry.found_existing) return;
        self.stats.parsed += 1;
        var probability: u7 = 0;
        if (!preferred_tag) {
            if (probable_text) |text| {
                const tag = (try annotated(text, self.deadline)) orelse {
                    self.stats.invalid_probability += 1;
                    return;
                };
                probability = (try parseProbability(tag.condition, self.deadline)) orelse {
                    self.stats.invalid_probability += 1;
                    return;
                };
                ordinary = tag.kind;
            }
        }
        if (ordinary == null and conditional != null) ordinary = conditional.?.kind;
        if (ordinary == null and !has_modes) {
            self.stats.unsupported_type += 1;
            return;
        }
        var row: Record = .{ .relation = relation.id, .via = 0, .from = 0, .to = 0, .attr = undefined };
        var members = relation.members;
        var via_nodes: usize = 0;
        var via_ways: [31]i64 = undefined;
        var via_count: usize = 0;
        while (try members.next()) |member| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (member.type == .way and eql(member.role, "from")) {
                row.from = member.ref;
            } else if (member.type == .way and eql(member.role, "to")) {
                if (row.to == 0) row.to = member.ref;
            } else if (eql(member.role, "via")) {
                if (member.type == .way) {
                    if (via_count == via_ways.len or member.ref == 0) {
                        self.stats.invalid_members += 1;
                        return;
                    }
                    via_ways[via_count] = member.ref;
                    via_count += 1;
                }
                if (member.type == .node) {
                    row.via = member.ref;
                    via_nodes += 1;
                }
            }
        }
        if (via_nodes > 1 and via_count == 0) {
            self.stats.deferred += 1;
            return;
        }
        if (row.from == 0 or row.to == 0 or (row.via == 0 and via_count == 0) or (via_nodes != 0 and via_count != 0)) {
            self.stats.invalid_members += 1;
            return;
        }
        const timed = conditional != null or legacy.present;
        // The pinned parser writes a date domain when it promotes a
        // via-node relation. Via-way relations use the ordinary sequence.
        const domains = if (timed and via_count == 0) try self.parseDomains(conditional, legacy) else &[_]u64{0};
        if (domains.len == 0) {
            self.stats.invalid_condition += 1;
            return;
        }
        const first = std.math.cast(u32, self.via_ways.items.len) orelse return error.TooManyRestrictionVias;
        if (via_count != 0) {
            try self.via_ways.appendSlice(self.a, via_ways[0..via_count]);
            self.stats.complex += 1;
        }
        if (has_modes) {
            for (std.enums.values(Kind), modes.values) |kind, mask| {
                if (mask == 0) continue;
                row.attr = .{ .kind = @backingInt(kind), .modes = mask, .mode_specific = true, .probability = probability };
                try self.appendDomains(row, first, @intCast(via_count), domains);
            }
        } else {
            const predicate = timed or probability != 0;
            row.attr = .{
                .kind = @backingInt(ordinary.?),
                .modes = if (exceptions.len == 0) (if (predicate) general_modes else simple_modes) else try exceptModes(exceptions, self.deadline),
                .mode_specific = exceptions.len != 0 or predicate,
                .probability = probability,
            };
            try self.appendDomains(row, first, @intCast(via_count), domains);
        }
    }

    noinline fn appendDomains(self: *Catalog, row: Record, first: u32, count: u5, domains: []const u64) !void {
        for (domains, 0..) |domain, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (count == 0) {
                try self.appendDomain(&self.simple_domains, self.entries.items.len, domain);
                try self.entries.append(self.a, row);
            } else {
                try self.complex.append(self.a, .{
                    .from = row.from,
                    .to = row.to,
                    .first_via = first,
                    .attr = .{
                        .via_count = count,
                        .kind = row.attr.kind,
                        .modes = if (row.attr.mode_specific) row.attr.modes else general_modes,
                        .probability = row.attr.probability,
                    },
                });
            }
        }
    }

    fn appendDomain(self: *Catalog, output: *std.ArrayList(u64), preceding: usize, domain: u64) !void {
        if (domain == 0 and output.items.len == 0) return;
        try output.appendNTimes(self.a, 0, preceding - output.items.len);
        try output.append(self.a, domain);
    }

    noinline fn parseDomains(self: *Catalog, annotated_tag: ?Annotated, legacy: Legacy) ![]const u64 {
        if (self.time_parser == null) self.time_parser = .{ .a = self.a, .deadline = self.deadline };
        self.parsed_domains.clearRetainingCapacity();
        const explicit = if (annotated_tag) |tag| tag.condition else "";
        const condition = if (explicit.len != 0) explicit else try self.legacyCondition(legacy);
        try self.time_parser.?.parse(condition, &self.parsed_domains);
        return self.parsed_domains.items;
    }

    fn legacyCondition(self: *Catalog, legacy: Legacy) ![]const u8 {
        const text = &self.condition_text;
        text.clearRetainingCapacity();
        const day_on = legacy.fields.get(.day_on);
        const day_off = legacy.fields.get(.day_off);
        if (day_on.len != 0 and day_off.len != 0) try self.appendRange(day_on, day_off);
        const hour_on = legacy.fields.get(.hour_on);
        const hour_off = legacy.fields.get(.hour_off);
        if (std.mem.indexOfScalar(u8, hour_on, ';') != null) {
            var starts = std.mem.tokenizeScalar(u8, hour_on, ';');
            var ends = std.mem.tokenizeScalar(u8, hour_off, ';');
            var count: usize = 0;
            try text.append(self.a, ' ');
            while (starts.next()) |begin| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                const end = ends.next() orelse return "";
                if (count != 0) try text.append(self.a, ',');
                try self.appendRange(begin, end);
                count += 1;
            }
            if (count < 2 or ends.next() != null) return "";
        } else if (hour_on.len != 0 and hour_off.len != 0) {
            try text.append(self.a, ' ');
            try self.appendRange(hour_on, hour_off);
        }
        return text.items;
    }

    fn appendRange(self: *Catalog, begin: []const u8, end: []const u8) !void {
        try self.condition_text.appendSlice(self.a, begin);
        try self.condition_text.append(self.a, '-');
        try self.condition_text.appendSlice(self.a, end);
    }
};

const LegacyKey = enum { day_on, day_off, hour_on, hour_off };
const Legacy = struct { fields: std.EnumArray(LegacyKey, []const u8) = .initFill(""), present: bool = false };
const Annotated = struct { kind: Kind, condition: []const u8 };

fn annotated(text: []const u8, deadline: io.Deadline) !?Annotated {
    for (text, 0..) |char, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (char == '@') {
            const kind = std.meta.stringToEnum(Kind, std.mem.trimEnd(u8, text[0..i], " ")) orelse return null;
            return .{ .kind = kind, .condition = text[i + 1 ..] };
        }
    }
    return null;
}

fn parseProbability(text: []const u8, deadline: io.Deadline) !?u7 {
    const tag = std.mem.trimStart(u8, text, " \t");
    const name = "probability";
    if (!std.mem.startsWith(u8, tag, name)) return null;
    const assignment = std.mem.trim(u8, tag[name.len..], " \t");
    if (assignment.len == 0 or assignment[0] != '=') return null;
    const digits = std.mem.trimStart(u8, assignment[1..], " \t");
    var value: u16 = 0;
    for (digits, 0..) |char, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!std.ascii.isDigit(char)) return null;
        value = value * 10 + char - '0';
        if (value > 100) return null;
    }
    return if (value == 0) null else @intCast(value);
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
    std.debug.assert(@sizeOf(Complex) == 24 and @offsetOf(Complex, "first_via") == 16 and @offsetOf(Complex, "attr") == 20);
}

test "probability tags accept integers from one to one hundred" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u7, 1), try parseProbability("probability=1", .none));
    try testing.expectEqual(@as(?u7, 100), try parseProbability(" probability = 100 ", .none));
    for ([_][]const u8{ "probability=0", "probability=-1", "probability=101", "probability=999999", "probability=1.5", "probability=", "limit=75" }) |text| {
        try testing.expectEqual(@as(?u7, null), try parseProbability(text, .none));
    }
}
