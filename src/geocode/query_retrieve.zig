//! Intersect unions of field postings in their shared importance order.
const std = @import("std");
const io = @import("../infra/io.zig");
const bundle = @import("bundle.zig");
const format = @import("index_model.zig");
const index = @import("index.zig");
const model = @import("model.zig");
const postings = @import("index_postings.zig");
const edit = @import("query_edit.zig");
const parse = @import("query_parse.zig");
const Allocator = std.mem.Allocator;

pub const weights = struct {
    pub const name = 115;
    pub const street = 107;
    pub const city = 72;
    pub const street_type = 128;
    pub const house_number = 149;
    pub const postal = 150;
    pub const numeric_alternate = 95;
    pub const structured = 150;
    pub const transliteration = 10;
    pub const edit_cost = 40;
    pub const importance_cap = 8192;
    pub const importance_divisor = 128;
    pub const language = 12;
    pub const near = 160;
    pub const near_scale_m = 1500.0;
    pub const layers = [4]u16{ 18, 8, 0, 12 };
    pub const max_layer = 18;
};

pub fn fieldWeight(term: parse.Term, field: format.Field) ?u16 {
    if (term.field) |required| return if (required == field) weights.structured else null;
    return switch (field) {
        .name => weights.name,
        .street => if (term.kind == .street_type or term.kind == .direction) weights.street_type else weights.street,
        .city => weights.city,
        .postcode => switch (term.kind) {
            .postcode => weights.postal,
            .house_number => weights.numeric_alternate,
            else => null,
        },
        .house_number => switch (term.kind) {
            .house_number => weights.house_number,
            .postcode => weights.numeric_alternate,
            else => null,
        },
    };
}

pub fn record(data: bundle.Data, document: format.Document) *const model.Record {
    return switch (document.kind) {
        .place => &data.places[document.row].record,
        .street => &data.streets[document.row].record,
        .address => &data.addresses[document.row].record,
        .poi => &data.pois[document.row].record,
    };
}

pub const Hit = struct {
    id: format.RecordId,
    importance: u16,

    fn order(self: Hit) u64 {
        return @as(u64, std.math.maxInt(u16) - self.importance) << 32 | self.id;
    }
};

const Stream = struct {
    cursor: postings.Iterator,
    current: ?Hit = null,
    strength: u16,

    fn step(self: *Stream, data: bundle.Data, counts: format.RecordCounts) !void {
        const id = try self.cursor.next() orelse {
            self.current = null;
            return;
        };
        const hit: Hit = .{ .id = id, .importance = record(data, counts.document(id).?).attr.importance };
        if (self.current) |prior| if (hit.order() <= prior.order()) return error.InvalidGeocodePostingOrder;
        self.current = hit;
    }

    fn advance(self: *Stream, target: u64, data: bundle.Data, counts: format.RecordCounts, deadline: io.Deadline) !void {
        while (self.current) |hit| {
            if (hit.order() >= target) return;
            const ordinal = self.cursor.ordinal;
            if (ordinal % postings.checkpoint_stride == 0) {
                if (deadline.expired()) return error.DeadlineExceeded;
                if (try self.jump(target, data, counts)) continue;
            }
            try self.step(data, counts);
        }
    }

    fn jump(self: *Stream, target: u64, data: bundle.Data, counts: format.RecordCounts) !bool {
        const stride = postings.checkpoint_stride;
        // Skip the current group when the following restart still precedes
        // the target. The binary search then avoids every intermediate group.
        var low = self.cursor.ordinal / stride + 1;
        var high = (self.cursor.list.count - 1) / stride + 1;
        if (low >= high) return false;
        var best = try self.probe(low * stride, data, counts);
        if (best.current.?.order() > target) return false;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            const tested = try self.probe(middle * stride, data, counts);
            if (tested.current.?.order() <= target) {
                best = tested;
                low = middle;
            } else high = middle;
        }
        self.* = best;
        return true;
    }

    fn probe(self: Stream, ordinal: u32, data: bundle.Data, counts: format.RecordCounts) !Stream {
        var probe_stream = self;
        try probe_stream.cursor.seek(ordinal);
        try probe_stream.step(data, counts);
        return probe_stream;
    }
};

pub const Clause = struct {
    streams: std.ArrayList(Stream) = .empty,
    max_strength: u16 = 0,
    size: u64 = 0,

    pub fn add(self: *Clause, a: Allocator, list: postings.List, strength: u16) !void {
        // Alternate spellings can reach the same term. Keep its best score.
        for (self.streams.items) |*stream| {
            if (stream.cursor.list.bytes.ptr == list.bytes.ptr) {
                stream.strength = @max(stream.strength, strength);
                self.max_strength = @max(self.max_strength, strength);
                return;
            }
        }
        try self.append(a, list, strength);
    }

    fn append(self: *Clause, a: Allocator, list: postings.List, strength: u16) !void {
        try self.streams.append(a, .{ .cursor = list.iterator(), .strength = strength });
        self.max_strength = @max(self.max_strength, strength);
        self.size += list.count;
    }

    pub fn smaller(_: void, a: Clause, b: Clause) bool {
        return a.size < b.size;
    }

    fn first(self: Clause) ?Hit {
        var best: ?Hit = null;
        for (self.streams.items) |stream| if (stream.current) |hit| {
            if (best == null or hit.order() < best.?.order()) best = hit;
        };
        return best;
    }

    fn score(self: Clause, target: u64) u16 {
        var strength: u16 = 0;
        for (self.streams.items) |stream| if (stream.current) |hit| {
            if (hit.order() == target) strength = @max(strength, stream.strength);
        };
        return strength;
    }
};

pub fn exact(
    a: Allocator,
    view: index.View,
    term: parse.Term,
    scratch: []u8,
    deadline: io.Deadline,
) !Clause {
    var clause: Clause = .{};
    for (format.fields) |field| {
        const strength = fieldWeight(term, field) orelse continue;
        try addExact(a, &clause, view, field, term.text, strength, scratch, deadline);
        if (term.latin.len != 0) try addExact(a, &clause, view, field, term.latin, strength - weights.transliteration, scratch, deadline);
        if (term.kind == .postcode and term.field == null and field == .house_number) {
            const house_key = std.mem.trimStart(u8, term.text, "0");
            if (house_key.len < term.text.len)
                try addExact(a, &clause, view, field, if (house_key.len == 0) "0" else house_key, strength, scratch, deadline);
        }
    }
    return clause;
}

pub fn addPrefix(
    a: Allocator,
    clause: *Clause,
    view: index.View,
    field: format.Field,
    text: []const u8,
    strength: u16,
    scratch: []u8,
    deadline: io.Deadline,
) !void {
    var cursor = try view.prefix(field, text, scratch, deadline);
    while (try cursor.next(deadline)) |term| try clause.append(a, term.list, strength);
}

fn addExact(
    a: Allocator,
    clause: *Clause,
    view: index.View,
    field: format.Field,
    text: []const u8,
    strength: u16,
    scratch: []u8,
    deadline: io.Deadline,
) !void {
    var cursor = try view.prefix(field, text, scratch, deadline);
    if (try cursor.next(deadline)) |term| {
        if (std.mem.eql(u8, term.text, text)) try clause.add(a, term.list, strength);
    }
}

pub fn addEdits(
    a: Allocator,
    clause: *Clause,
    view: index.View,
    term: parse.Term,
    scratch: []u8,
    deadline: io.Deadline,
) !void {
    if (term.kind == .house_number or term.kind == .postcode or term.kind == .stop_word) return;
    if (term.field == .house_number or term.field == .postcode) return;
    for (format.fields) |field| {
        const strength = fieldWeight(term, field) orelse continue;
        var matcher = edit.Matcher.init(term.text) orelse return;
        var alias = if (term.latin.len == 0) null else edit.Matcher.init(term.latin);
        var cursor = try view.prefix(field, "", scratch, deadline);
        while (try cursor.next(deadline)) |word| {
            const direct = if (matcher.distance(word.text)) |distance| fuzzyScore(strength, distance, 0) else 0;
            const latin = if (alias) |*latin_matcher| match: {
                const distance = latin_matcher.distance(word.text) orelse break :match 0;
                break :match fuzzyScore(strength, distance, weights.transliteration);
            } else 0;
            if (@max(direct, latin) != 0) try clause.add(a, word.list, @max(direct, latin));
        }
    }
}

fn fuzzyScore(strength: u16, distance: u8, penalty: u16) u16 {
    if (distance == 0) return 0;
    return @max(1, strength -| (@as(u16, distance) * weights.edit_cost + penalty));
}

pub const Intersection = struct {
    clauses: []Clause,
    data: bundle.Data,
    counts: format.RecordCounts,
    previous: ?Hit = null,
    checks: u8 = 0,

    pub fn start(self: *Intersection, deadline: io.Deadline) !void {
        for (self.clauses) |clause| for (clause.streams.items) |*stream| {
            if (deadline.expired()) return error.DeadlineExceeded;
            stream.cursor = stream.cursor.list.iterator();
            stream.current = null;
            try stream.step(self.data, self.counts);
        };
    }

    /// Every returned hit occurs in at least one field of each clause.
    pub fn next(self: *Intersection, deadline: io.Deadline) !?struct { hit: Hit, text_score: u32 } {
        if (self.clauses.len == 0) return null;
        var target: u64 = if (self.previous) |prior| prior.order() + 1 else 0;
        while (true) {
            if (self.checks % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            self.checks +%= 1;
            const before = target;
            for (self.clauses) |clause| {
                for (clause.streams.items) |*stream| try stream.advance(target, self.data, self.counts, deadline);
                const next_hit = clause.first() orelse return null;
                target = next_hit.order();
            }
            if (target == before) {
                const hit = self.clauses[0].first().?;
                self.previous = hit;
                var score: u32 = 0;
                for (self.clauses) |clause| score += clause.score(target);
                return .{ .hit = hit, .text_score = score };
            }
        }
    }
};

test "intersection jumps to sparse hits across importance-ordered restart groups" {
    const t = std.testing;
    const a = t.allocator;
    var places: [512]model.Place = undefined;
    for (&places, 0..) |*place, i| {
        place.* = .{ .kind = .{}, .record = .{
            .osm_id = @intCast(i),
            .coordinate = .{ .lng = 0, .lat = 0 },
            .attr = .{ .source = .node, .importance = if (i % 2 == 1) 7 else 3 },
        } };
    }
    const data: bundle.Data = .{ .places = &places };
    const counts: format.RecordCounts = .{ .place = places.len };
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(a);
    var writer = try postings.Writer.init(a, &all, places.len);
    for (0..2) |pass| for (0..places.len / 2) |i| {
        try writer.append(@intCast(i * 2 + 1 - pass));
    };
    const expected = [_]format.RecordId{ 125, 491, 260, 500 };
    var sparse: std.ArrayList(u8) = .empty;
    defer sparse.deinit(a);
    var sparse_writer = try postings.Writer.init(a, &sparse, expected.len);
    for (expected) |id| try sparse_writer.append(id);
    var clauses: [2]Clause = @splat(.{});
    defer for (&clauses) |*clause| clause.streams.deinit(a);
    try clauses[0].add(a, try postings.List.init(try sparse_writer.finish(), expected.len), 10);
    try clauses[1].add(a, try postings.List.init(try writer.finish(), places.len), 50);
    var matches: Intersection = .{ .clauses = &clauses, .data = data, .counts = counts };
    try matches.start(.none);
    for (expected) |id| {
        const match = (try matches.next(.none)).?;
        try t.expectEqual(id, match.hit.id);
        try t.expectEqual(60, match.text_score);
    }
    try t.expectEqual(null, try matches.next(.none));
}
