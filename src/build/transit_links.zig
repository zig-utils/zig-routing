// Ported from src/mjolnir/convert_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const constants = @import("../graph/constants.zig");
const io = @import("../infra/io.zig");
const gtfs = @import("gtfs/model.zig");
const places = @import("transit_places.zig");
const transit = @import("../graph/transit.zig");
const Allocator = std.mem.Allocator;
pub const Access = constants.AccessMask;

pub const Link = struct {
    from: u32,
    to: u32,
    use: constants.Use,
    access: [2]Access,
    meters: f64,
    seconds: ?u32 = null,
};

pub const Links = struct {
    paths: []const Link,
    missing_pathway_endpoints: u64,
};

/// Stations with supplied pathways use their directed topology. Stations
/// without pathways connect their entrances and platforms through the hub.
pub fn compile(a: Allocator, feeds: []const gtfs.Feed, model: places.Places, deadline: io.Deadline) !Links {
    if (feeds.len != model.feeds.len) return error.InvalidTransitFeed;
    const explicit = try a.alloc(bool, model.stations.len);
    defer a.free(explicit);
    @memset(explicit, false);
    var paths: std.ArrayList(Link) = .empty;
    errdefer paths.deinit(a);
    var missing: u64 = 0;
    for (feeds, model.feeds) |feed, refs| {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (feed.pathways) |row| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (row.from_stop_id.value >= refs.locations.len or row.to_stop_id.value >= refs.locations.len)
                return error.InvalidTransitPathway;
            const from = refs.locations[row.from_stop_id.value];
            const to = refs.locations[row.to_stop_id.value];
            if (from) |location| explicit[model.stationOf(location)] = true;
            if (to) |location| explicit[model.stationOf(location)] = true;
            if (from == null or to == null) {
                missing += 1;
                continue;
            }
            if (from.? == .station or to.? == .station or model.stationOf(from.?) != model.stationOf(to.?))
                return error.InvalidTransitPathway;
            const use: constants.Use = switch (row.pathway_mode) {
                .stairs => .steps,
                .escalator => .escalator,
                .elevator => .elevator,
                .walkway, .moving_walkway, .fare_gate, .exit_gate => .platform_connection,
            };
            const first = model.place(from.?);
            const last = model.place(to.?);
            if (first.graph_node == last.graph_node) return error.InvalidTransitPathway;
            const bidirectional = row.is_bidirectional and row.pathway_mode != .exit_gate;
            try paths.append(a, try link(first, last, use, bidirectional, row.length, row.traversal_time));
        }
    }
    for (model.egresses) |*entrance| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!explicit[entrance.station])
            try paths.append(a, try link(&entrance.place, &model.stations[entrance.station].place, .egress_connection, true, null, null));
    }
    for (model.stops) |*stop| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!explicit[stop.station])
            try paths.append(a, try link(&stop.place, &model.stations[stop.station].place, .platform_connection, true, null, null));
    }
    return .{ .paths = try paths.toOwnedSlice(a), .missing_pathway_endpoints = missing };
}

fn link(first: *const transit.Place, last: *const transit.Place, use: constants.Use, bidirectional: bool, length: ?f64, seconds: ?u32) !Link {
    const grade_accessible = use != .steps and use != .escalator;
    const access: Access = .{
        .pedestrian = true,
        .bicycle = true,
        .wheelchair = grade_accessible and first.flags.wheelchair_boarding and last.flags.wheelchair_boarding,
    };
    const meters = length orelse first.coordinate.toPoint().distance(last.coordinate.toPoint());
    if (!std.math.isFinite(meters) or meters < 0) return error.InvalidTransitPathway;
    return .{
        .from = first.graph_node,
        .to = last.graph_node,
        .use = use,
        .access = .{ access, if (bidirectional) access else .{} },
        .meters = @max(1, meters),
        .seconds = seconds,
    };
}

pub const Adjacency = struct {
    const Arc = struct { head: u32, seconds: ?u32 };
    offsets: []const u32,
    arcs: []const Arc,

    pub fn init(a: Allocator, paths: []const Link, nodes: usize, reverse: bool, deadline: io.Deadline) !Adjacency {
        if (paths.len > std.math.maxInt(u32) / 2) return error.TooManyTransitPathways;
        const offsets = try a.alloc(u32, nodes + 1);
        errdefer a.free(offsets);
        @memset(offsets, 0);
        for (paths) |path| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (path.from >= nodes or path.to >= nodes) return error.InvalidTransitPathway;
            const from = if (reverse) path.to else path.from;
            const to = if (reverse) path.from else path.to;
            if (path.access[0].pedestrian) offsets[from + 1] += 1;
            if (path.access[1].pedestrian) offsets[to + 1] += 1;
        }
        for (offsets[1..], 0..) |*offset, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            offset.* = std.math.add(u32, offset.*, offsets[i]) catch return error.TooManyTransitPathways;
        }
        const arcs = try a.alloc(Arc, offsets[nodes]);
        errdefer a.free(arcs);
        const next = try a.dupe(u32, offsets[0..nodes]);
        defer a.free(next);
        for (paths) |path| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const from = if (reverse) path.to else path.from;
            const to = if (reverse) path.from else path.to;
            if (path.access[0].pedestrian) {
                arcs[next[from]] = .{ .head = to, .seconds = path.seconds };
                next[from] += 1;
            }
            if (path.access[1].pedestrian) {
                arcs[next[to]] = .{ .head = from, .seconds = path.seconds };
                next[to] += 1;
            }
        }
        return .{ .offsets = offsets, .arcs = arcs };
    }

    pub fn mark(self: Adjacency, a: Allocator, seeds: []const u32, marks: []u32, stamp: u32, todo: *std.ArrayList(u32), deadline: io.Deadline) !void {
        todo.clearRetainingCapacity();
        if (marks.len + 1 != self.offsets.len or stamp == 0) return error.InvalidTransitPathway;
        for (seeds) |seed| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (seed >= marks.len) return error.InvalidTransitPathway;
            if (marks[seed] == stamp) continue;
            marks[seed] = stamp;
            try todo.append(a, seed);
        }
        var i: usize = 0;
        while (i < todo.items.len) : (i += 1) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const node = todo.items[i];
            for (self.arcs[self.offsets[node]..self.offsets[node + 1]], 0..) |arc, j| {
                if (j % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (marks[arc.head] == stamp) continue;
                marks[arc.head] = stamp;
                try todo.append(a, arc.head);
            }
        }
    }

    const TimedNode = struct {
        id: u32,
        seconds: u64,

        fn compare(_: void, left: TimedNode, right: TimedNode) std.math.Order {
            return std.math.order(left.seconds, right.seconds);
        }
    };
    pub const TimeQueue = std.PriorityQueue(TimedNode, void, TimedNode.compare);

    pub fn shortestTimes(self: Adjacency, a: Allocator, origin: u32, marks: []u32, stamp: u32, times: []u64, queue: *TimeQueue, deadline: io.Deadline) !void {
        marks[origin] = stamp;
        times[origin] = 0;
        try queue.push(a, .{ .id = origin, .seconds = 0 });
        while (queue.pop()) |current| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (current.seconds != times[current.id]) continue;
            for (self.arcs[self.offsets[current.id]..self.offsets[current.id + 1]], 0..) |arc, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const seconds = current.seconds + (arc.seconds orelse return error.MissingPathwayTraversalTime);
                if (marks[arc.head] == stamp and seconds >= times[arc.head]) continue;
                marks[arc.head] = stamp;
                times[arc.head] = seconds;
                try queue.push(a, .{ .id = arc.head, .seconds = seconds });
            }
        }
    }
};

test "a supplied one-way pathway controls station reachability" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: gtfs.Feed = .init(a);
    feed.pathways = &.{.{
        .pathway_id = .{ .value = 0 },
        .from_stop_id = .{ .value = 0 },
        .to_stop_id = .{ .value = 1 },
        .pathway_mode = .escalator,
        .is_bidirectional = false,
        .traversal_time = 20,
    }};
    var platform: transit.Place = .{ .coordinate = .{ .lng = 0, .lat = 0 }, .name = .none, .one_stop_id = .none, .graph_node = 0 };
    platform.flags.wheelchair_boarding = true;
    var station = platform;
    station.graph_node = 1;
    var egress = platform;
    egress.graph_node = 2;
    egress.coordinate.lat = 1000;
    var platforms = [_]transit.Stop{.{ .place = platform, .station = 0 }};
    var stations = [_]transit.Station{.{ .place = station }};
    var egresses = [_]transit.Egress{.{ .place = egress, .station = 0 }};
    const locations: places.Places = .{
        .stops = &platforms,
        .stations = &stations,
        .egresses = &egresses,
        .passages = &.{},
        .routes = &.{},
        .nodes = &.{ .{ .stop = 0 }, .{ .station = 0 }, .{ .egress = 0 } },
        .feeds = &.{.{
            .locations = &.{ .{ .egress = 0 }, .{ .stop = 0 } },
            .timetable_ids = .{ .stops = &.{ transit.no_id, 0 }, .coordinates = &.{ egress.coordinate, platform.coordinate }, .routes = &.{} },
        }},
        .platforms_without_coordinates = 0,
    };
    const links = try compile(a, &.{feed}, locations, .none);
    try testing.expectEqual(1, links.paths.len);
    try testing.expectEqual(.escalator, links.paths[0].use);
    try testing.expectEqual(20, links.paths[0].seconds.?);
    try testing.expect(links.paths[0].access[0].pedestrian and !links.paths[0].access[0].wheelchair);
    try testing.expect(!links.paths[0].access[1].pedestrian);
    const forward = try Adjacency.init(a, links.paths, locations.nodes.len, false, .none);
    var marks: [3]u32 = @splat(0);
    var queue: std.ArrayList(u32) = .empty;
    try forward.mark(a, &.{2}, &marks, 1, &queue, .none);
    try testing.expectEqual([_]u32{ 1, 0, 1 }, marks);
    try forward.mark(a, &.{0}, &marks, 2, &queue, .none);
    try testing.expectEqual([_]u32{ 2, 0, 1 }, marks);
}
