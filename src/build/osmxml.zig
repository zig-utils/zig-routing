//! OSM XML input (P3.03): `<osm>` files with `<node>`, `<way>` (`<nd ref>`)
//! and `<relation>` (`<member type ref role>`), each with `<tag k v>`, read
//! into the element model of `osm.zig`. For fixtures and upstream's XML test
//! data, not for planet builds, so clarity wins over speed.
//!
//! `zig-xml` tokenizes leniently (it never fails), so structure is checked
//! here: the root must be `<osm>`, elements nest as OSM defines and close in
//! order, nothing but whitespace sits between them, required attributes are
//! present and well formed, and elements come sorted (nodes, ways,
//! relations, each by id). Any violation is an error with the line and
//! column it was found at, in `Reader.diagnostic`.
//!
//! Elements marked `visible="false"` (deleted objects in history files) are
//! skipped. `<bounds>`, `<meta>` and `<note>` under `<osm>` are accepted and
//! ignored. Attribute values are entity-decoded (`&amp;`, `&#x20AC;`, ...).

const std = @import("std");
const xml = @import("xml");
const osm = @import("osm.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{InvalidOsmXml} || Allocator.Error;

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
};

pub const Reader = struct {
    gpa: Allocator,
    tokens: xml.Reader,
    /// Strings, tags, refs and members of the current element; reset per element.
    element_arena: std.heap.ArenaAllocator,
    diagnostic: ?Diagnostic = null,
    message_buf: [256]u8 = undefined,

    // Position bookkeeping for line numbers (counted incrementally).
    line: usize = 1,
    line_start: usize = 0,
    counted_to: usize = 0,

    state: enum { prolog, in_osm, done } = .prolog,
    last: ?struct { kind: osm.Kind, id: i64 } = null,

    pub fn init(gpa: Allocator, text: []const u8) Reader {
        return .{ .gpa = gpa, .tokens = xml.Reader.init(gpa, text), .element_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Reader) void {
        self.tokens.deinit();
        self.element_arena.deinit();
    }

    /// The next element, or null at the end of the file. Slices in the
    /// element stay valid until the next call.
    pub fn next(self: *Reader) Error!?osm.Element {
        _ = self.element_arena.reset(.retain_capacity);
        while (true) {
            const at = self.tokens.pos;
            const ev = (try self.tokens.next()) orelse {
                if (self.state != .done) return self.fail(at, "unexpected end of file: <osm> is not closed", .{});
                return null;
            };
            switch (self.state) {
                .prolog => switch (ev) {
                    .processing_instruction, .comment, .declaration => {},
                    .text => |t| try self.expectBlank(at, t),
                    .open => |e| {
                        if (!std.mem.eql(u8, e.name, "osm")) return self.fail(at, "root element is <{s}>, expected <osm>", .{e.name});
                        self.state = .in_osm;
                    },
                    .self_closing => |e| {
                        if (!std.mem.eql(u8, e.name, "osm")) return self.fail(at, "root element is <{s}>, expected <osm>", .{e.name});
                        self.state = .done;
                    },
                    else => return self.fail(at, "unexpected content before <osm>", .{}),
                },
                .in_osm => switch (ev) {
                    .comment => {},
                    .text => |t| try self.expectBlank(at, t),
                    .close => |name| {
                        if (!std.mem.eql(u8, name, "osm")) return self.fail(at, "</{s}> closes <osm>", .{name});
                        self.state = .done;
                    },
                    .open, .self_closing => |e| {
                        const closed = ev == .self_closing;
                        if (std.mem.eql(u8, e.name, "node")) {
                            if (try self.readNode(at, e, closed)) |n| return n;
                        } else if (std.mem.eql(u8, e.name, "way")) {
                            if (try self.readWay(at, e, closed)) |w| return w;
                        } else if (std.mem.eql(u8, e.name, "relation")) {
                            if (try self.readRelation(at, e, closed)) |r| return r;
                        } else if (std.mem.eql(u8, e.name, "bounds") or std.mem.eql(u8, e.name, "meta") or std.mem.eql(u8, e.name, "note")) {
                            if (!closed) try self.skipElement(e.name);
                        } else return self.fail(at, "unexpected <{s}> in <osm>", .{e.name});
                    },
                    else => return self.fail(at, "unexpected markup in <osm>", .{}),
                },
                .done => switch (ev) {
                    .comment, .processing_instruction => {},
                    .text => |t| try self.expectBlank(at, t),
                    else => return self.fail(at, "content after </osm>", .{}),
                },
            }
        }
    }

    // ------------------------------------------------------------------
    // Elements

    fn readNode(self: *Reader, at: usize, e: xml.Element, closed: bool) Error!?osm.Element {
        if (hidden(e)) return self.skipHidden("node", closed);
        const a = self.element_arena.allocator();
        const id = try self.idAttr(at, e, "id");
        const lat = osm.parseCoordinate(try self.attr(at, e, "lat"), 90) orelse return self.fail(at, "node {d}: lat is not a coordinate in [-90, 90]", .{id});
        const lon = osm.parseCoordinate(try self.attr(at, e, "lon"), 180) orelse return self.fail(at, "node {d}: lon is not a coordinate in [-180, 180]", .{id});
        try self.checkOrder(at, .node, id);
        var tags: std.ArrayList(osm.Tag) = .empty;
        if (!closed) try self.readChildren("node", &tags, null, null);
        return .{ .node = .{ .id = id, .lat = lat, .lon = lon, .tags = try tags.toOwnedSlice(a) } };
    }

    fn readWay(self: *Reader, at: usize, e: xml.Element, closed: bool) Error!?osm.Element {
        if (hidden(e)) return self.skipHidden("way", closed);
        const a = self.element_arena.allocator();
        const id = try self.idAttr(at, e, "id");
        try self.checkOrder(at, .way, id);
        var tags: std.ArrayList(osm.Tag) = .empty;
        var refs: std.ArrayList(i64) = .empty;
        if (!closed) try self.readChildren("way", &tags, &refs, null);
        return .{ .way = .{ .id = id, .refs = try refs.toOwnedSlice(a), .tags = try tags.toOwnedSlice(a) } };
    }

    fn readRelation(self: *Reader, at: usize, e: xml.Element, closed: bool) Error!?osm.Element {
        if (hidden(e)) return self.skipHidden("relation", closed);
        const a = self.element_arena.allocator();
        const id = try self.idAttr(at, e, "id");
        try self.checkOrder(at, .relation, id);
        var tags: std.ArrayList(osm.Tag) = .empty;
        var members: std.ArrayList(osm.Member) = .empty;
        if (!closed) try self.readChildren("relation", &tags, null, &members);
        return .{ .relation = .{ .id = id, .members = try members.toOwnedSlice(a), .tags = try tags.toOwnedSlice(a) } };
    }

    /// Reads the children of a node, way or relation up to its close tag.
    fn readChildren(self: *Reader, parent: []const u8, tags: *std.ArrayList(osm.Tag), refs: ?*std.ArrayList(i64), members: ?*std.ArrayList(osm.Member)) Error!void {
        const a = self.element_arena.allocator();
        while (true) {
            const at = self.tokens.pos;
            const ev = (try self.tokens.next()) orelse return self.fail(at, "unexpected end of file: <{s}> is not closed", .{parent});
            switch (ev) {
                .comment => {},
                .text => |t| try self.expectBlank(at, t),
                .close => |name| {
                    if (!std.mem.eql(u8, name, parent)) return self.fail(at, "</{s}> closes <{s}>", .{ name, parent });
                    return;
                },
                .self_closing, .open => |e| {
                    if (ev == .open) {
                        // Children of these elements are always empty.
                        const close_at = self.tokens.pos;
                        const close = (try self.tokens.next()) orelse return self.fail(close_at, "unexpected end of file: <{s}> is not closed", .{e.name});
                        if (close != .close or !std.mem.eql(u8, close.close, e.name)) return self.fail(close_at, "<{s}> must be empty", .{e.name});
                    }
                    if (std.mem.eql(u8, e.name, "tag")) {
                        const k = try self.decoded(at, e, "k");
                        const v = try self.decoded(at, e, "v");
                        try tags.append(a, .{ .key = k, .value = v });
                    } else if (refs != null and std.mem.eql(u8, e.name, "nd")) {
                        try refs.?.append(a, try self.idAttr(at, e, "ref"));
                    } else if (members != null and std.mem.eql(u8, e.name, "member")) {
                        const t = try self.attr(at, e, "type");
                        const kind = std.meta.stringToEnum(osm.MemberType, t) orelse return self.fail(at, "member type \"{s}\" is not node, way or relation", .{t});
                        try members.?.append(a, .{ .type = kind, .ref = try self.idAttr(at, e, "ref"), .role = try self.decodedOr(e, "role", "") });
                    } else return self.fail(at, "unexpected <{s}> in <{s}>", .{ e.name, parent });
                },
                else => return self.fail(at, "unexpected markup in <{s}>", .{parent}),
            }
        }
    }

    fn hidden(e: xml.Element) bool {
        const v = e.attribute("visible") orelse return false;
        return std.mem.eql(u8, v, "false");
    }

    fn skipHidden(self: *Reader, name: []const u8, closed: bool) Error!?osm.Element {
        if (!closed) try self.skipElement(name);
        return null;
    }

    /// Skips to the close tag of an element just opened, checking nesting.
    fn skipElement(self: *Reader, name: []const u8) Error!void {
        var depth: usize = 1;
        var stack: [64][]const u8 = undefined;
        stack[0] = name;
        while (depth > 0) {
            const at = self.tokens.pos;
            const ev = (try self.tokens.next()) orelse return self.fail(at, "unexpected end of file: <{s}> is not closed", .{stack[depth - 1]});
            switch (ev) {
                .open => |e| {
                    if (depth == stack.len) return self.fail(at, "elements nested too deeply", .{});
                    stack[depth] = e.name;
                    depth += 1;
                },
                .close => |n| {
                    if (!std.mem.eql(u8, n, stack[depth - 1])) return self.fail(at, "</{s}> closes <{s}>", .{ n, stack[depth - 1] });
                    depth -= 1;
                },
                else => {},
            }
        }
    }

    // ------------------------------------------------------------------
    // Attributes and checks

    fn attr(self: *Reader, at: usize, e: xml.Element, name: []const u8) Error![]const u8 {
        return e.attribute(name) orelse self.fail(at, "<{s}> has no {s} attribute", .{ e.name, name });
    }

    fn idAttr(self: *Reader, at: usize, e: xml.Element, name: []const u8) Error!i64 {
        const s = try self.attr(at, e, name);
        return std.fmt.parseInt(i64, s, 10) catch self.fail(at, "<{s}> {s}=\"{s}\" is not an integer id", .{ e.name, name, s });
    }

    fn decoded(self: *Reader, at: usize, e: xml.Element, name: []const u8) Error![]const u8 {
        return xml.decode(self.element_arena.allocator(), try self.attr(at, e, name));
    }

    fn decodedOr(self: *Reader, e: xml.Element, name: []const u8, default: []const u8) Error![]const u8 {
        const raw = e.attribute(name) orelse return default;
        return xml.decode(self.element_arena.allocator(), raw);
    }

    fn checkOrder(self: *Reader, at: usize, kind: osm.Kind, id: i64) Error!void {
        if (self.last) |l| if (!osm.inOrder(l.kind, l.id, kind, id))
            return self.fail(at, "{t} {d} after {t} {d}: input must be sorted (nodes, ways, relations, each by id)", .{ kind, id, l.kind, l.id });
        self.last = .{ .kind = kind, .id = id };
    }

    fn expectBlank(self: *Reader, at: usize, t: []const u8) Error!void {
        for (t, 0..) |c, i| if (c != ' ' and c != '\t' and c != '\r' and c != '\n')
            return self.fail(at + i, "unexpected text \"{s}\"", .{t[i..@min(t.len, i + 20)]});
    }

    fn fail(self: *Reader, at: usize, comptime fmt: []const u8, args: anytype) Error {
        const input = self.tokens.input;
        const pos = @min(at, input.len);
        if (pos < self.counted_to) {
            self.line = 1;
            self.line_start = 0;
            self.counted_to = 0;
        }
        for (input[self.counted_to..pos], self.counted_to..) |c, i| if (c == '\n') {
            self.line += 1;
            self.line_start = i + 1;
        };
        self.counted_to = pos;
        const message = std.fmt.bufPrint(&self.message_buf, fmt, args) catch self.message_buf[0..];
        self.diagnostic = .{ .line = self.line, .column = pos - self.line_start + 1, .message = message };
        return error.InvalidOsmXml;
    }
};

/// Reads every element of an OSM XML document into memory owned by `arena`
/// (for tests and small fixtures).
pub fn readAll(arena: Allocator, text: []const u8) Error![]osm.Element {
    var r = Reader.init(arena, text);
    var out: std.ArrayList(osm.Element) = .empty;
    while (try r.next()) |e| try out.append(arena, try clone(arena, e));
    return out.items;
}

/// A deep copy of an element whose slices outlive the reader's next call.
pub fn clone(arena: Allocator, e: osm.Element) Allocator.Error!osm.Element {
    const dupTags = struct {
        fn f(a: Allocator, tags: []const osm.Tag) Allocator.Error![]osm.Tag {
            const out = try a.alloc(osm.Tag, tags.len);
            for (out, tags) |*o, t| o.* = .{ .key = try a.dupe(u8, t.key), .value = try a.dupe(u8, t.value) };
            return out;
        }
    }.f;
    return switch (e) {
        .node => |n| .{ .node = .{ .id = n.id, .lat = n.lat, .lon = n.lon, .tags = try dupTags(arena, n.tags) } },
        .way => |w| .{ .way = .{ .id = w.id, .refs = try arena.dupe(i64, w.refs), .tags = try dupTags(arena, w.tags) } },
        .relation => |r| blk: {
            const members = try arena.alloc(osm.Member, r.members.len);
            for (members, r.members) |*m, src| m.* = .{ .type = src.type, .ref = src.ref, .role = try arena.dupe(u8, src.role) };
            break :blk .{ .relation = .{ .id = r.id, .members = members, .tags = try dupTags(arena, r.tags) } };
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const fixture = @embedFile("testdata/tiny.osm");

test "a fixture reads into nodes, ways and relations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const els = try readAll(arena_state.allocator(), fixture);
    try testing.expectEqual(@as(usize, 7), els.len);

    const n1 = els[0].node;
    try testing.expectEqual(@as(i64, -1), n1.id);
    try testing.expectEqual(@as(i32, 471000000), n1.lat);
    try testing.expectEqual(@as(i32, 95000000), n1.lon);
    try testing.expectEqual(@as(usize, 0), n1.tags.len);
    const n2 = els[1].node;
    try testing.expectEqual(@as(i64, -3), n2.id);
    try testing.expectEqual(@as(i32, 471000001), n2.lat);
    try testing.expectEqual(@as(i32, -1234568), n2.lon); // -0.12345675 rounds away from zero
    try testing.expectEqualStrings("Café & \"Bar\" <1> €", els[2].tag("name").?);
    try testing.expectEqualStrings("yes", els[2].tag("amenity").?);

    const way = els[4].way;
    try testing.expectEqual(@as(i64, 10), way.id);
    try testing.expectEqualSlices(i64, &.{ -3, -1, 5, -3 }, way.refs);
    try testing.expectEqualStrings("footway", els[4].tag("highway").?);
    try testing.expectEqual(@as(usize, 0), els[5].way.refs.len); // an empty way still parses

    const rel = els[6].relation;
    try testing.expectEqual(@as(usize, 3), rel.members.len);
    try testing.expectEqual(osm.MemberType.way, rel.members[0].type);
    try testing.expectEqual(@as(i64, 10), rel.members[0].ref);
    try testing.expectEqualStrings("from", rel.members[0].role);
    try testing.expectEqualStrings("", rel.members[2].role); // role is optional
    try testing.expectEqualStrings("restriction", els[6].tag("type").?);
}

fn expectFailure(text: []const u8, line: usize, needle: []const u8) !void {
    var r = Reader.init(testing.allocator, text);
    defer r.deinit();
    while (true) {
        const e = r.next() catch |err| {
            try testing.expectEqual(error.InvalidOsmXml, err);
            const d = r.diagnostic.?;
            if (d.line != line or std.mem.indexOf(u8, d.message, needle) == null) {
                std.debug.print("got line {d}: {s}\n", .{ d.line, d.message });
                return error.TestUnexpectedResult;
            }
            return;
        };
        if (e == null) return error.TestExpectedError;
    }
}

test "malformed and unsorted input fails with a line number" {
    try expectFailure("<osm>\n<node id=\"1\" lat=\"1\" lon=\"2\">\n<tag k=\"a\" v=\"b\"/>\n</way>\n</osm>", 4, "</way> closes <node>");
    try expectFailure("<osm>\n<node id=\"1\" lat=\"1\" lon=\"2\"/>\n<node id=\"1\" lat=\"1\" lon=\"2\"/>\n</osm>", 3, "must be sorted");
    try expectFailure("<osm>\n<way id=\"5\"/>\n<node id=\"6\" lat=\"1\" lon=\"2\"/>\n</osm>", 3, "must be sorted");
    try expectFailure("<osm>\n<node id=\"x\" lat=\"1\" lon=\"2\"/>\n</osm>", 2, "not an integer id");
    try expectFailure("<osm>\n\n<node id=\"1\" lat=\"91\" lon=\"2\"/>\n</osm>", 3, "lat is not a coordinate");
    try expectFailure("<osm>\n<node id=\"1\" lon=\"2\"/>\n</osm>", 2, "no lat attribute");
    try expectFailure("<osm>\n<way id=\"1\">\n<nd/>\n</way>\n</osm>", 3, "no ref attribute");
    try expectFailure("<osm>\n<relation id=\"1\">\n<member type=\"area\" ref=\"1\"/>\n</relation>\n</osm>", 3, "not node, way or relation");
    try expectFailure("<osm>\n<node id=\"1\" lat=\"1\" lon=\"2\">\n<nd ref=\"3\"/>\n</node>\n</osm>", 3, "unexpected <nd> in <node>");
    try expectFailure("<osm>\n<node id=\"1\" lat=\"1\" lon=\"2\"/>\nstray\n</osm>", 3, "unexpected text");
    try expectFailure("<osm>\n<node id=\"1\" lat=\"1\" lon=\"2\">\n<tag k=\"a\" v=\"b\"/>", 3, "is not closed");
    try expectFailure("<?xml version=\"1.0\"?>\n<gpx/>", 2, "expected <osm>");
    try expectFailure("<osm>\n<changeset id=\"1\"/>\n</osm>", 2, "unexpected <changeset>");
    try expectFailure("<osm>\n</osm>\n<node id=\"1\" lat=\"1\" lon=\"2\"/>", 3, "content after </osm>");
    // The column points at the offending tag.
    var r = Reader.init(testing.allocator, "<osm>\n  <bogus/>\n</osm>");
    defer r.deinit();
    try testing.expectError(error.InvalidOsmXml, r.next());
    try testing.expectEqual(@as(usize, 3), r.diagnostic.?.column);
}

test "hidden elements, bounds and comments are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const els = try readAll(arena_state.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- generated -->
        \\<osm version="0.6" generator="test">
        \\  <bounds minlat="47" minlon="9" maxlat="48" maxlon="10"/>
        \\  <node id="1" visible="false"/>
        \\  <node id="2" lat="47.5" lon="9.5" visible="true" version="3" user="x &amp; y"><!-- c --></node>
        \\  <way id="3" visible="false"><nd ref="1"/></way>
        \\</osm>
        \\
    );
    try testing.expectEqual(@as(usize, 1), els.len);
    try testing.expectEqual(@as(i64, 2), els[0].node.id);
}

test "an empty osm document has no elements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try readAll(arena_state.allocator(), "<osm version=\"0.6\"/>")).len);
}
