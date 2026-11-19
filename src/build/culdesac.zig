// Ported from culdesac_processor in src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;

const Candidate = struct {
    way_id: i64,
    nodes_start: usize,
    nodes_end: usize,
};

const Owner = struct {
    first_road: ?i64 = null,
    multiple_roads: bool = false,
};

pub const Occurrence = struct {
    node_id: i64,
    way_id: i64,
};

pub const Tracker = struct {
    candidates: std.ArrayList(Candidate) = .empty,
    refs: std.ArrayList(i64) = .empty,
    owners: std.AutoHashMapUnmanaged(i64, Owner) = .empty,

    pub fn deinit(self: *Tracker, gpa: Allocator) void {
        self.owners.deinit(gpa);
        self.refs.deinit(gpa);
        self.candidates.deinit(gpa);
    }

    pub fn candidate(self: *Tracker, gpa: Allocator, way_id: i64, refs: []const i64, last: *const std.AutoHashMapUnmanaged(i64, usize), deadline: io.Deadline) !void {
        const start = self.refs.items.len;
        for (refs, 0..) |id, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (last.get(id).? != i) continue;
            try self.refs.append(gpa, id);
            const entry = try self.owners.getOrPut(gpa, id);
            if (!entry.found_existing) entry.value_ptr.* = .{};
        }
        try self.candidates.append(gpa, .{ .way_id = way_id, .nodes_start = start, .nodes_end = self.refs.items.len });
    }

    pub fn track(self: *const Tracker, id: i64) bool {
        return self.owners.contains(id);
    }

    pub fn observe(self: *Tracker, seen: Occurrence) void {
        const owner = self.owners.getPtr(seen.node_id).?;
        if (owner.first_road) |first| {
            owner.multiple_roads = owner.multiple_roads or first != seen.way_id;
        } else {
            owner.first_road = seen.way_id;
        }
    }

    pub fn finish(self: *const Tracker, context: anytype, comptime useCuldesac: fn (@TypeOf(context), i64) anyerror!void, deadline: io.Deadline) !void {
        for (self.candidates.items) |loop| {
            var intersections: u2 = 0;
            for (self.refs.items[loop.nodes_start..loop.nodes_end], 0..) |id, i| {
                if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const owner = self.owners.get(id).?;
                intersections += @intFromBool(owner.multiple_roads or (owner.first_road orelse loop.way_id) != loop.way_id);
                if (intersections == 2) break;
            } else {
                try useCuldesac(context, loop.way_id);
            }
        }
    }
};
