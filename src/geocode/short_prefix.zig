//! Materialize one- and two-scalar prefixes and their best unqualified hits.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const distance = @import("../geo/constants.zig");
const bundle = @import("bundle.zig");
const model = @import("model.zig");
const format = @import("index_model.zig");
const index = @import("index.zig");
const postings = @import("index_postings.zig");
const parse = @import("query_parse.zig");
const rank = @import("query_rank.zig");
const retrieve = @import("query_retrieve.zig");
const sort = @import("sort_runs.zig").sort;
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

pub const Cell = struct {
    key: u32,
    hits: []const rank.Ranked,
};

pub const Row = struct {
    lists: [format.fields.len]?postings.List = @splat(null),
    top: []const rank.Ranked = &.{},
    cells: []const Cell = &.{},
};

pub const Cache = struct {
    owned: std.heap.ArenaAllocator,
    rows: std.StringHashMapUnmanaged(Row),

    pub fn init(a: Allocator, data: bundle.Data, view: index.View, max_results: usize, deadline: io.Deadline) !Cache {
        var memory: std.heap.ArenaAllocator = .init(a);
        errdefer memory.deinit();
        const owned = memory.allocator();
        var rows: std.StringHashMapUnmanaged(Row) = .empty;
        var builder: Builder = .{ .a = a, .owned = owned, .data = data, .counts = view.header.records, .rows = &rows };
        defer builder.deinit();
        const scratch = try a.alloc(u8, view.scratchBytes());
        defer a.free(scratch);
        for (format.fields) |field| try builder.collectField(view, field, scratch, deadline);

        var working: std.heap.ArenaAllocator = .init(a);
        defer working.deinit();
        var iterator = rows.iterator();
        while (iterator.next()) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            _ = working.reset(.retain_capacity);
            try buildRankOrder(working.allocator(), owned, data, view.header.records, entry.key_ptr.*, entry.value_ptr, max_results, deadline);
        }
        return .{ .owned = memory, .rows = rows };
    }

    pub fn deinit(self: *Cache) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

const PrefixBounds = struct { first: usize, second: usize };

fn prefixBounds(term: []const u8) !PrefixBounds {
    const first = (try unicode.decode(term)).len;
    const second = if (first == term.len) first else @as(usize, first) + (try unicode.decode(term[first..])).len;
    return .{ .first = first, .second = second };
}

pub fn isShort(term: []const u8) bool {
    const width = prefixBounds(term) catch return false;
    return term.len == width.second;
}

const MemberSet = struct {
    key: [8]u8 = undefined,
    len: usize = 0,
    ids: std.AutoHashMapUnmanaged(format.RecordId, void) = .empty,
};

const Builder = struct {
    a: Allocator,
    owned: Allocator,
    data: bundle.Data,
    counts: format.RecordCounts,
    rows: *std.StringHashMapUnmanaged(Row),
    members: [2]MemberSet = @splat(.{}),
    hits: std.ArrayList(retrieve.Hit) = .empty,
    sort_space: std.ArrayList(retrieve.Hit) = .empty,

    fn deinit(self: *Builder) void {
        for (&self.members) |*set| set.ids.deinit(self.a);
        self.hits.deinit(self.a);
        self.sort_space.deinit(self.a);
    }

    fn collectField(self: *Builder, view: index.View, field: format.Field, scratch: []u8, deadline: io.Deadline) !void {
        var terms = try view.prefix(field, "", scratch, deadline);
        while (try terms.next(deadline)) |term| {
            const width = try prefixBounds(term.text);
            try self.change(field, &self.members[0], term.text[0..width.first], deadline);
            try self.change(field, &self.members[1], if (width.first == width.second) "" else term.text[0..width.second], deadline);
            var cursor = term.list.iterator();
            while (try cursor.next()) |id| {
                if (cursor.ordinal % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                try self.members[0].ids.put(self.a, id, {});
                if (width.first != width.second) try self.members[1].ids.put(self.a, id, {});
            }
        }
        for (&self.members) |*set| try self.change(field, set, "", deadline);
    }

    fn change(self: *Builder, field: format.Field, set: *MemberSet, key: []const u8, deadline: io.Deadline) !void {
        if (std.mem.eql(u8, set.key[0..set.len], key)) return;
        if (set.ids.count() != 0) try self.save(field, set, deadline);
        set.ids.clearRetainingCapacity();
        @memcpy(set.key[0..key.len], key);
        set.len = key.len;
    }

    fn save(self: *Builder, field: format.Field, set: *MemberSet, deadline: io.Deadline) !void {
        var records = set.ids.keyIterator();
        self.hits.clearRetainingCapacity();
        try self.hits.ensureTotalCapacity(self.a, set.ids.count());
        while (records.next()) |id| {
            if (self.hits.items.len % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const feature = retrieve.record(self.data, self.counts.document(id.*).?);
            self.hits.appendAssumeCapacity(.{ .id = id.*, .importance = feature.attr.importance });
        }
        try sort(retrieve.Hit, self.a, self.hits.items, &self.sort_space, hitLess, deadline);
        var encoded: std.ArrayList(u8) = .empty;
        var writer = try postings.Writer.init(self.owned, &encoded, @intCast(self.hits.items.len));
        for (self.hits.items, 0..) |hit, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try writer.append(hit.id);
        }
        const row = try self.rows.getOrPut(self.owned, set.key[0..set.len]);
        if (!row.found_existing) {
            row.key_ptr.* = try self.owned.dupe(u8, set.key[0..set.len]);
            row.value_ptr.* = .{};
        }
        row.value_ptr.lists[@backingInt(field)] = try postings.List.init(try writer.finish(), @intCast(self.hits.items.len));
    }
};

fn hitLess(_: void, a: retrieve.Hit, b: retrieve.Hit) bool {
    if (a.importance != b.importance) return a.importance > b.importance;
    return a.id < b.id;
}

const Located = struct {
    cell: u32,
    hit: rank.Ranked,

    fn less(_: void, a: Located, b: Located) bool {
        if (a.cell != b.cell) return a.cell < b.cell;
        return a.hit.before(b.hit);
    }
};

fn buildRankOrder(
    a: Allocator,
    owned: Allocator,
    data: bundle.Data,
    counts: format.RecordCounts,
    key: []const u8,
    row: *Row,
    max_results: usize,
    deadline: io.Deadline,
) !void {
    var clauses: [1]retrieve.Clause = .{.{}};
    const token: parse.Term = .{ .text = key, .kind = if (std.ascii.isDigit(key[0])) .house_number else .word, .prefix = true };
    for (format.fields, row.lists) |field, list| {
        const strength = retrieve.fieldWeight(token, field) orelse continue;
        if (list) |value| try clauses[0].add(a, value, strength);
    }
    var search: retrieve.Intersection = .{ .clauses = &clauses, .data = data, .counts = counts };
    try search.start(deadline);
    var top: rank.Top = .{ .entries = try a.alloc(rank.Ranked, max_results) };
    var located: std.ArrayList(Located) = .empty;
    while (try search.next(deadline)) |match| {
        const candidate = (try rank.evaluate(data, counts, match.hit, match.text_score, .unknown, .{}, deadline)).?;
        top.add(candidate);
        try located.append(a, .{ .cell = gridKey(retrieve.record(data, candidate.document).coordinate), .hit = candidate });
    }
    row.top = try owned.dupe(rank.Ranked, top.entries[0..top.len]);
    var scratch: std.ArrayList(Located) = .empty;
    try sort(Located, a, located.items, &scratch, Located.less, deadline);

    const hits = try owned.alloc(rank.Ranked, located.items.len);
    var cells: std.ArrayList(Cell) = .empty;
    var first: usize = 0;
    for (located.items, hits, 0..) |entry, *hit, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        hit.* = entry.hit;
        if (i == 0 or entry.cell == located.items[i - 1].cell) continue;
        try cells.append(owned, .{ .key = located.items[first].cell, .hits = hits[first..i] });
        first = i;
    }
    if (first < hits.len) try cells.append(owned, .{ .key = located.items[first].cell, .hits = hits[first..] });
    row.cells = cells.items;
}

const cell_step = 250_000;
const cell_degrees = @as(f64, cell_step) / 1e7;
// A meridian segment plus a parallel segment bounds the cell's radius.
const cell_radius = cell_degrees * distance.rad_per_deg_d * distance.rad_earth_meters_d + 0.01;

fn gridKey(point: model.Coordinate) u32 {
    const x: u32 = @intCast(@min(@divFloor(@as(i64, point.lng) + 1_800_000_000, cell_step), 360 * 10_000_000 / cell_step - 1));
    const y: u32 = @intCast(@min(@divFloor(@as(i64, point.lat) + 900_000_000, cell_step), 180 * 10_000_000 / cell_step - 1));
    return y << 16 | x;
}

fn center(key: u32) geo.PointLL {
    return .init((@as(f64, @floatFromInt(key & 0xffff)) + 0.5) * cell_degrees - 180, (@as(f64, @floatFromInt(key >> 16)) + 0.5) * cell_degrees - 90);
}

fn overlaps(midpoint: geo.PointLL, filter: rank.Bounds) bool {
    const half = cell_degrees / 2 + 1e-10;
    if (midpoint.lat + half < filter.south or midpoint.lat - half > filter.north) return false;
    return if (filter.west <= filter.east)
        midpoint.lng + half >= filter.west and midpoint.lng - half <= filter.east
    else
        midpoint.lng + half >= filter.west or midpoint.lng - half <= filter.east;
}

const Bounded = struct {
    cell: Cell,
    upper: u32,
    bonus: u32,

    fn less(_: void, a: Bounded, b: Bounded) bool {
        if (a.upper != b.upper) return a.upper > b.upper;
        return a.cell.key < b.cell.key;
    }
};

pub fn collect(
    a: Allocator,
    row: Row,
    data: bundle.Data,
    counts: format.RecordCounts,
    filters: rank.Filters,
    penalty: u32,
    top: *rank.Top,
    deadline: io.Deadline,
) !void {
    if (filters.near == null and filters.bounds == null and filters.language.len == 0 and
        filters.layers.count() == std.enums.values(format.Kind).len)
    {
        for (row.top[0..@min(row.top.len, top.entries.len)]) |hit| {
            var adjusted = hit;
            adjusted.score -|= penalty;
            top.add(adjusted);
        }
        return;
    }
    const bounds = try a.alloc(Bounded, row.cells.len);
    var count: usize = 0;
    for (row.cells, 0..) |cell, i| {
        if (i % 32 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const midpoint = center(cell.key);
        if (filters.bounds) |box| if (!overlaps(midpoint, box)) continue;
        var bonus: u32 = if (filters.language.len != 0) retrieve.weights.language else 0;
        if (filters.near) |near| bonus += rank.nearBonus(@max(0, near.distance(midpoint) - cell_radius));
        const upper = (cell.hits[0].score -| penalty) + bonus;
        if (!top.canImprove(upper)) continue;
        bounds[count] = .{ .cell = cell, .upper = upper, .bonus = bonus };
        count += 1;
    }
    var sort_space: std.ArrayList(Bounded) = .empty;
    defer sort_space.deinit(a);
    try sort(Bounded, a, bounds[0..count], &sort_space, Bounded.less, deadline);
    var checks: u8 = 0;
    for (bounds[0..count]) |cell| {
        if (!top.canImprove(cell.upper)) break;
        for (cell.cell.hits) |hit| {
            if (checks % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
            checks +%= 1;
            if (!top.canImprove((hit.score -| penalty) + cell.bonus)) break;
            const text_score = hit.score - rank.importance(hit.hit.importance) - retrieve.weights.layers[@backingInt(hit.document.kind)];
            if (try rank.evaluate(data, counts, hit.hit, text_score -| penalty, .unknown, filters, deadline)) |candidate|
                top.add(candidate);
        }
    }
}
