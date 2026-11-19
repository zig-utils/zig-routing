// Ported from culdesac_processor in src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;

pub const Candidate = extern struct {
    way_id: i64,
    nodes_start: u64,
    nodes_end: u64,
};

const Owner = struct {
    first_road: ?i64 = null,
    multiple_roads: bool = false,
};

pub const Occurrence = struct {
    node_id: i64,
    way_id: i64,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Candidate) == 24);
    std.debug.assert(@offsetOf(Candidate, "way_id") == 0 and @offsetOf(Candidate, "nodes_start") == 8 and @offsetOf(Candidate, "nodes_end") == 16);
}

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

    pub fn restore(self: *Tracker, gpa: Allocator, loops: []const Candidate, refs: []const i64, deadline: io.Deadline) !void {
        for (loops, 0..) |loop, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (loop.nodes_start > loop.nodes_end or loop.nodes_end > refs.len) return error.InvalidLoopCheckpoint;
        }
        try self.candidates.appendSlice(gpa, loops);
        try self.refs.appendSlice(gpa, refs);
        for (refs, 0..) |id, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const owner = try self.owners.getOrPut(gpa, id);
            if (!owner.found_existing) owner.value_ptr.* = .{};
        }
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
            for (self.refs.items[@intCast(loop.nodes_start)..@intCast(loop.nodes_end)], 0..) |id, i| {
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
