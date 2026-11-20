// Ported from src/mjolnir/graphbuilder.cc and src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const checkpoint = @import("checkpoint.zig");
const tags = @import("tags/root.zig");
const Type = @import("../graph/signs.zig").Type;
const Use = @import("../graph/constants.zig").Use;
const Allocator = std.mem.Allocator;
const Id = tags.names.Id;

pub const WayTags = extern struct {
    number: Id = .empty,
    name: Id = .empty,
    branch_ref: Id = .empty,
    branch_street: Id = .empty,
    toward_ref: Id = .empty,
    toward_street: Id = .empty,
    destination: Id = .empty,
    forward: Id = .empty,
    backward: Id = .empty,
};

pub const NodeTags = struct {
    name: []const u8 = "",
    ref: []const u8 = "",
    exit_to: []const u8 = "",
    named: bool = false,
};

const WayEntry = extern struct {
    id: i64,
    tags: WayTags,
    reserved: u32 = 0,
};

const NodeHeader = extern struct {
    id: i64,
    lengths: [3]u32,
    attr: packed struct(u32) {
        named: bool,
        reserved: u31 = 0,
    },
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(WayTags) == 36);
    std.debug.assert(@sizeOf(WayEntry) == 48 and @offsetOf(WayEntry, "tags") == 8 and @offsetOf(WayEntry, "reserved") == 44);
    std.debug.assert(@sizeOf(NodeHeader) == 24 and @offsetOf(NodeHeader, "lengths") == 8 and @offsetOf(NodeHeader, "attr") == 20);
}

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    ways: std.AutoHashMapUnmanaged(i64, WayTags) = .empty,
    nodes: std.AutoHashMapUnmanaged(i64, NodeTags) = .empty,

    pub fn deinit(self: *Catalog, gpa: Allocator) void {
        self.ways.deinit(gpa);
        self.nodes.deinit(gpa);
        self.arena.deinit();
    }

    pub fn addWay(self: *Catalog, gpa: Allocator, id: i64, names: tags.names.Indexed) !void {
        const fields: WayTags = .{
            .number = names.junction_ref.text,
            .name = names.junction_name.text,
            .branch_ref = names.destination_ref.text,
            .branch_street = names.destination_street.text,
            .toward_ref = names.destination_ref_to.text,
            .toward_street = names.destination_street_to.text,
            .destination = names.destination.text,
            .forward = names.destination_forward.text,
            .backward = names.destination_backward.text,
        };
        if (!std.meta.eql(fields, WayTags{})) try self.ways.put(gpa, id, fields);
    }

    pub fn addNode(self: *Catalog, gpa: Allocator, id: i64, attrs: tags.NodeAttrs) !void {
        const junction = attrs.type == .motorway_junction;
        const named = attrs.flags.named_intersection;
        const name = if (named or junction) attrs.name orelse "" else "";
        const ref = if (junction) attrs.ref orelse "" else "";
        const exit_to = if (junction) attrs.exit_to orelse "" else "";
        if (name.len == 0 and ref.len == 0 and exit_to.len == 0) return;
        try self.storeNode(gpa, id, .{ .name = name, .ref = ref, .exit_to = exit_to, .named = named });
    }

    fn storeNode(self: *Catalog, gpa: Allocator, id: i64, node: NodeTags) !void {
        const a = self.arena.allocator();
        try self.nodes.put(gpa, id, .{
            .name = if (node.name.len > 0) try a.dupe(u8, node.name) else "",
            .ref = if (node.ref.len > 0) try a.dupe(u8, node.ref) else "",
            .exit_to = if (node.exit_to.len > 0) try a.dupe(u8, node.exit_to) else "",
            .named = node.named,
        });
    }

    pub fn saveWays(self: *const Catalog, tx: *checkpoint.Transaction) !void {
        if (self.ways.count() == 0) return;
        const file = try tx.create(.way_signs);
        defer file.close();
        var rows: [128]WayEntry = undefined;
        var count: usize = 0;
        var offset: u64 = 0;
        var iter = self.ways.iterator();
        while (iter.next()) |entry| {
            rows[count] = .{ .id = entry.key_ptr.*, .tags = entry.value_ptr.* };
            count += 1;
            if (count < rows.len) continue;
            if (tx.deadline.expired()) return error.DeadlineExceeded;
            try file.pwriteAll(std.mem.asBytes(&rows), offset);
            offset += @sizeOf(@TypeOf(rows));
            count = 0;
        }
        try file.pwriteAll(std.mem.sliceAsBytes(rows[0..count]), offset);
        try file.sync();
    }

    pub fn loadWays(self: *Catalog, gpa: Allocator, saved: *const checkpoint.Existing, strings: *const tags.names.StringTable, deadline: io.Deadline) !void {
        if (saved.manifest.files.get(.way_signs) == null) return;
        const mapping = try saved.map(.way_signs, deadline);
        defer mapping.unmap();
        for (try checkpoint.array(WayEntry, mapping)) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (row.reserved != 0 or self.ways.contains(row.id)) return error.InvalidCheckpoint;
            inline for (@typeInfo(WayTags).@"struct".field_names) |field| {
                if (@backingInt(@field(row.tags, field)) > strings.strings.items.len) return error.InvalidCheckpoint;
            }
            try self.ways.put(gpa, row.id, row.tags);
        }
    }

    pub fn saveNodes(self: *const Catalog, tx: *checkpoint.Transaction) !void {
        if (self.nodes.count() == 0) return;
        const file = try tx.create(.node_signs);
        defer file.close();
        var offset: u64 = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (tx.deadline.expired()) return error.DeadlineExceeded;
            const node = entry.value_ptr.*;
            const strings = [3][]const u8{ node.name, node.ref, node.exit_to };
            var header: NodeHeader = .{ .id = entry.key_ptr.*, .lengths = undefined, .attr = .{ .named = node.named } };
            for (strings, &header.lengths) |value, *len| len.* = std.math.cast(u32, value.len) orelse return error.NameTooLarge;
            try file.pwriteAll(std.mem.asBytes(&header), offset);
            offset += @sizeOf(NodeHeader);
            for (strings) |value| {
                if (value.len == 0) continue;
                try file.pwriteAll(value, offset);
                offset += value.len;
            }
        }
        try file.sync();
    }

    pub fn loadNodes(self: *Catalog, gpa: Allocator, saved: *const checkpoint.Existing, deadline: io.Deadline) !void {
        if (saved.manifest.files.get(.node_signs) == null) return;
        const mapping = try saved.map(.node_signs, deadline);
        defer mapping.unmap();
        var bytes: []const u8 = mapping.bytes;
        while (bytes.len != 0) {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (bytes.len < @sizeOf(NodeHeader)) return error.InvalidCheckpoint;
            const header = std.mem.bytesToValue(NodeHeader, bytes[0..@sizeOf(NodeHeader)]);
            bytes = bytes[@sizeOf(NodeHeader)..];
            if (header.attr.reserved != 0 or self.nodes.contains(header.id)) return error.InvalidCheckpoint;
            var strings: [3][]const u8 = undefined;
            for (header.lengths, &strings) |len, *value| {
                if (len > bytes.len) return error.InvalidCheckpoint;
                value.* = bytes[0..len];
                bytes = bytes[len..];
            }
            try self.storeNode(gpa, header.id, .{
                .name = strings[0],
                .ref = strings[1],
                .exit_to = strings[2],
                .named = header.attr.named,
            });
        }
    }
};

pub const Junction = struct {
    degree: u32,
    links: u32 = 0,
    drivable: u32 = 0,

    pub fn isFork(self: Junction, motorway: bool) bool {
        return self.degree > 2 and self.drivable > 1 and
            (self.links == self.degree or (motorway and (self.links == 0 or
                (self.links == self.drivable and self.degree == self.links + 1))));
    }
};

pub const Selection = struct {
    numbers: []const u8,
    branch: [2][]const u8,
    toward: [3][]const u8,
    exit_to: []const u8,
    names: [2][]const u8,
    guide: bool,
    has_destination: bool,

    pub fn init(way: WayTags, node: NodeTags, strings: *const tags.names.StringTable, forward: bool, use: Use, fork: bool) Selection {
        const ramp_exit = !fork and use == .ramp;
        const destination = if (way.destination != .empty) way.destination else if (forward) way.forward else way.backward;
        const has_destination = way.branch_ref != .empty or way.branch_street != .empty or
            way.toward_ref != .empty or way.toward_street != .empty or destination != .empty;
        return .{
            .numbers = if (way.number != .empty) strings.get(way.number).? else if (ramp_exit) node.ref else "",
            .branch = .{ strings.get(way.branch_ref).?, strings.get(way.branch_street).? },
            .toward = .{ strings.get(way.toward_ref).?, strings.get(way.toward_street).?, strings.get(destination).? },
            .exit_to = if (!has_destination and !fork) node.exit_to else "",
            .names = .{ if (ramp_exit and !node.named) node.name else "", strings.get(way.name).? },
            .guide = use == .turn_channel or (use != .ramp and !fork),
            .has_destination = has_destination,
        };
    }

    pub fn present(self: Selection, junction: Junction, link: bool, fork: bool) bool {
        return (self.has_destination or self.numbers.len != 0 or self.exit_to.len != 0 or
            self.names[0].len != 0 or self.names[1].len != 0) and
            ((link and !(junction.links == 2 and junction.drivable == 1)) or fork or
                (self.guide and self.has_destination));
    }

    pub fn write(self: Selection, sink: anytype, deadline: io.Deadline) !void {
        try writeTokens(self.numbers, .exit_number, false, sink, deadline);
        if (self.guide) {
            try self.writeExitTo(sink, deadline);
            for (self.names) |name| try writeTokens(name, .exit_name, false, sink, deadline);
        }
        for (self.branch, 0..) |text, i|
            try writeTokens(text, if (self.guide) .guide_branch else .exit_branch, i == 0, sink, deadline);
        for (self.toward, 0..) |text, i|
            try writeTokens(text, if (self.guide) .guide_toward else .exit_toward, i == 0, sink, deadline);
        if (!self.guide) {
            try self.writeExitTo(sink, deadline);
            for (self.names) |name| try writeTokens(name, .exit_name, false, sink, deadline);
        }
    }

    fn writeExitTo(self: Selection, sink: anytype, deadline: io.Deadline) !void {
        if (self.exit_to.len == 0) return;
        // The tile builder stably groups branch signs before toward signs.
        for ([_]Type{ .exit_branch, .exit_toward }) |sign_type| {
            var tokens = std.mem.tokenizeScalar(u8, self.exit_to, ';');
            while (tokens.next()) |token| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const sign = try splitExitTo(token, deadline);
                const text = if (sign_type == .exit_branch) sign.branch else sign.toward;
                if (text.len != 0) try sink.add(sign_type, false, text);
            }
        }
    }
};

pub fn writeTokens(text: []const u8, sign_type: Type, route: bool, sink: anytype, deadline: io.Deadline) !void {
    var tokens = std.mem.tokenizeScalar(u8, text, ';');
    while (tokens.next()) |token| {
        if (deadline.expired()) return error.DeadlineExceeded;
        try sink.add(sign_type, route, token);
    }
}

fn splitExitTo(text: []const u8, deadline: io.Deadline) !struct { branch: []const u8 = "", toward: []const u8 } {
    if (std.ascii.startsWithIgnoreCase(text, "to ")) return .{ .toward = text[3..] };
    if (std.ascii.startsWithIgnoreCase(text, "toward ")) return .{ .toward = text[7..] };
    var start: ?usize = null;
    var length: usize = 0;
    for (text, 0..) |char, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (char != ' ') continue;
        const tail = text[i..];
        const separator: usize = if (std.ascii.startsWithIgnoreCase(tail, " to "))
            4
        else if (std.ascii.startsWithIgnoreCase(tail, " toward "))
            8
        else
            continue;
        // Valhalla starts a second same-kind search after the first separator.
        if (start) |prior| {
            if (separator == length and i < prior + length) continue;
            return .{ .toward = text };
        }
        start = i;
        length = separator;
    }
    const index = start orelse return .{ .toward = text };
    return .{ .branch = text[0..index], .toward = text[index + length ..] };
}

// Ported from test/signinfo.cc. These cases exercise the fallback before
// the graph builder applies its directed-access and link rules.
test "Valhalla exit_to parsing and guide selection" {
    const testing = std.testing;
    const Expected = struct {
        sign_type: Type,
        text: []const u8,
        route: bool = false,
    };
    const Sink = struct {
        rows: std.ArrayList(Expected) = .empty,

        pub fn add(self: *@This(), sign_type: Type, route: bool, text: []const u8) !void {
            try self.rows.append(testing.allocator, .{ .sign_type = sign_type, .text = text, .route = route });
        }
    };
    var strings: tags.names.StringTable = .init(testing.allocator);
    defer strings.deinit();
    const ref = try strings.intern("I 495 North");
    const ref_to = try strings.intern("I 695 North");
    const cases: []const struct {
        exit_to: []const u8,
        way: WayTags = .{},
        use: Use = .ramp,
        expected: []const Expected,
    } = &.{
        .{ .exit_to = "US 11;To I 81;Carlisle;Harrisburg", .expected = &.{
            .{ .sign_type = .exit_toward, .text = "US 11" },
            .{ .sign_type = .exit_toward, .text = "I 81" },
            .{ .sign_type = .exit_toward, .text = "Carlisle" },
            .{ .sign_type = .exit_toward, .text = "Harrisburg" },
        } },
        .{ .exit_to = "US 11;Toward I 81;Carlisle;Harrisburg", .expected = &.{
            .{ .sign_type = .exit_toward, .text = "US 11" },
            .{ .sign_type = .exit_toward, .text = "I 81" },
            .{ .sign_type = .exit_toward, .text = "Carlisle" },
            .{ .sign_type = .exit_toward, .text = "Harrisburg" },
        } },
        .{ .exit_to = "I 95 To I 695", .expected = &.{
            .{ .sign_type = .exit_branch, .text = "I 95" },
            .{ .sign_type = .exit_toward, .text = "I 695" },
        } },
        .{ .exit_to = "I 495 Toward I 270", .expected = &.{
            .{ .sign_type = .exit_branch, .text = "I 495" },
            .{ .sign_type = .exit_toward, .text = "I 270" },
        } },
        .{ .exit_to = "I 495 Toward I 270 To I 95", .expected = &.{
            .{ .sign_type = .exit_toward, .text = "I 495 Toward I 270 To I 95" },
        } },
        .{ .exit_to = "fallback", .way = .{ .branch_ref = ref }, .expected = &.{
            .{ .sign_type = .exit_branch, .text = "I 495 North", .route = true },
        } },
        .{ .exit_to = "fallback", .way = .{ .branch_ref = ref }, .use = .turn_channel, .expected = &.{
            .{ .sign_type = .guide_branch, .text = "I 495 North", .route = true },
        } },
        .{ .exit_to = "fallback", .way = .{ .toward_ref = ref_to }, .expected = &.{
            .{ .sign_type = .exit_toward, .text = "I 695 North", .route = true },
        } },
        .{ .exit_to = "fallback", .way = .{ .toward_ref = ref_to }, .use = .turn_channel, .expected = &.{
            .{ .sign_type = .guide_toward, .text = "I 695 North", .route = true },
        } },
    };
    var sink: Sink = .{};
    defer sink.rows.deinit(testing.allocator);
    for (cases) |case| {
        sink.rows.clearRetainingCapacity();
        const selection: Selection = .init(case.way, .{ .exit_to = case.exit_to }, &strings, true, case.use, false);
        try testing.expectEqual(case.use == .turn_channel, selection.guide and selection.has_destination);
        try selection.write(&sink, .none);
        try testing.expectEqual(case.expected.len, sink.rows.items.len);
        for (case.expected, sink.rows.items) |expected, actual| {
            try testing.expectEqual(expected.sign_type, actual.sign_type);
            try testing.expectEqual(expected.route, actual.route);
            try testing.expectEqualStrings(expected.text, actual.text);
        }
    }
    const guide: Selection = .init(.{ .toward_ref = ref_to }, .{ .ref = "5", .name = "Exit name" }, &strings, true, .turn_channel, false);
    try testing.expectEqualStrings("", guide.numbers);
    try testing.expectEqualStrings("", guide.names[0]);
    try testing.expectError(error.DeadlineExceeded, guide.write(&sink, .{ .at_ns = 0 }));
}
