// Ported from src/sif/dynamiccost.cc and valhalla/sif/dynamiccost.h (Valhalla 3.9.3).
const std = @import("std");
const Deadline = @import("../infra/io.zig").Deadline;
const EdgeId = @import("../graph/format.zig").EdgeId;
const Exclusion = @import("../snap/exclusions.zig").Edge;
const minimum_factor = std.math.floatEps(f64);

pub const Range = struct {
    begin: f32,
    end: f32,
    factor: f64,
};

pub const Edge = struct {
    ranges: std.ArrayList(Range) = .empty,
    allow: bool = false,
    exclude_at: ?f32 = null,
    full: f64 = 1,
    discount: f64 = 0,

    /// Integrate the upstream additive deltas over the actual intersection
    /// of each range with the traversal. Clamp the resulting mean to I3.
    pub noinline fn average(self: *const Edge, begin: f32, end: f32, deadline: Deadline) !f64 {
        if (begin == end) return 1;
        if (begin == 0 and end == 1) return self.full;
        return integrate(self.ranges.items, begin, end, deadline);
    }
};

fn integrate(ranges: []const Range, begin: f32, end: f32, deadline: Deadline) !f64 {
    const length = @as(f64, end) - begin;
    var discount: f64 = 0;
    var surcharge: f64 = 0;
    for (ranges, 0..) |range, i| {
        if (i % 64 == 0 and deadline.expired()) return error.Cancelled;
        const overlap = @as(f64, @min(range.end, end)) - @max(range.begin, begin);
        if (overlap <= 0) continue;
        const change = (overlap / length) * (range.factor - 1);
        discount += @min(change, 0);
        surcharge += @max(change, 0);
    }
    return @max((1 + discount) + surcharge, minimum_factor);
}

pub const Table = struct {
    edges: std.AutoHashMapUnmanaged(EdgeId, Edge) = .empty,
    exclusions: std.ArrayList(Exclusion) = .empty,
    // Conservative for every cut, including coincident discounted ranges.
    // Any open edge invalidates potentials computed on the restricted graph.
    floor: f32 = 1,
    has_allow: bool = false,

    pub fn get(self: *const Table, id: EdgeId) ?*const Edge {
        if (self.edges.count() == 0) return null;
        const edge = self.edges.getPtr(id) orelse return null;
        return if (edge.ranges.items.len == 0) null else edge;
    }

    pub fn allows(self: *const Table, id: EdgeId) bool {
        return self.has_allow and (self.get(id) orelse return false).allow;
    }

    pub fn exclusionAt(self: *const Table, id: EdgeId) ?f32 {
        return if (self.edges.getPtr(id)) |edge| edge.exclude_at else null;
    }

    pub fn append(self: *Table, a: std.mem.Allocator, id: EdgeId, range: Range, allow: bool) !void {
        if (!(range.begin >= 0 and range.end >= range.begin and range.end <= 1 and
            std.math.isFinite(range.factor) and @abs(range.factor) <= std.math.floatMax(f32)))
            return error.InvalidLinearCostRange;
        if (range.factor == 1 and !allow) return;
        const edge = try self.edges.getOrPutValue(a, id, .{});
        if (range.factor == 0) {
            if (edge.value_ptr.exclude_at == null) {
                try self.exclusions.append(a, .{ .id = id, .percent_along = range.begin });
                edge.value_ptr.exclude_at = range.begin;
            }
            return;
        }
        try edge.value_ptr.ranges.append(a, range);
        edge.value_ptr.allow = edge.value_ptr.allow or allow;
        self.has_allow = self.has_allow or allow;
        if (range.end > range.begin) edge.value_ptr.discount += @min(0, range.factor - 1);
    }

    /// Finish once at snap time. The stored factors and exclusions are then
    /// immutable and can be shared by every leg and named recost.
    pub fn finish(self: *Table, deadline: Deadline) !void {
        var values = self.edges.valueIterator();
        while (values.next()) |edge| {
            if (deadline.expired()) return error.Cancelled;
            edge.full = try integrate(edge.ranges.items, 0, 1, deadline);
            const lower = @max(1 + edge.discount, minimum_factor);
            // Round down with a guard for the subsequent f32 edge arithmetic.
            self.floor = @min(self.floor, @as(f32, @floatCast(if (lower < 1) lower * (1 - 0x1p-23) else lower)));
        }
        if (self.has_allow) self.floor = 0;
    }
};
