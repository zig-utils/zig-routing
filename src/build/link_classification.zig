// Ported from src/mjolnir/linkclassification.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const graph = @import("../graph/constants.zig");
const RoadClass = graph.RoadClass;
const Allocator = std.mem.Allocator;
const no_class: u4 = 8;
const no_arc = std.math.maxInt(u32);
const max_turn_channel_m: f32 = 200;

pub const Options = struct {
    reclassify: bool,
    infer_turn_channels: bool,
    deadline: io.Deadline,
};

/// One value for both directions of the physical segment.
pub const Result = packed struct(u8) {
    road_class: u3 = 0,
    processed: bool = false,
    turn_channel: bool = false,
    reserved: u3 = 0,
};

pub const Arc = struct {
    /// The low bit is set when traversing against the OSM way direction.
    ref: u32,
    head: u32,
    road_class: RoadClass,
    link: bool,
    named: bool,
    outbound: bool,
    inbound: bool,

    fn segment(self: Arc) u32 {
        return self.ref / 2;
    }

    fn forwardLink(self: Arc) bool {
        return self.link and self.outbound;
    }

    fn drivableRoad(self: Arc) bool {
        return !self.link and (self.outbound or self.inbound) and self.road_class != .service_other;
    }

    fn rank(self: Arc) u5 {
        return graph.incidentEdgeRank(self.outbound, @intCast(@backingInt(self.road_class)), self.named);
    }
};

pub const Road = struct {
    way: i64,
    name: []const u8,
    ref: []const u8,
    destination_refs: []const u8,

    fn sameRoad(self: Road, other: Road) bool {
        return matchRefs(self.ref, other.ref);
    }

    fn empty(self: Road) bool {
        return self.ref.len == 0 and self.destination_refs.len == 0;
    }

    fn matchesName(self: Road, other: Road) bool {
        return self.way == other.way or (self.name.len != 0 and std.mem.eql(u8, self.name, other.name)) or
            (self.ref.len != 0 and std.mem.eql(u8, self.ref, other.ref));
    }
};

fn matchRefs(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    return len != 0 and std.mem.eql(u8, a[0..len], b[0..len]);
}

fn destination(ref: []const u8, road: Road, deadline: io.Deadline) !bool {
    if (ref.len == 0) return false;
    var tokens = std.mem.tokenizeScalar(u8, road.destination_refs, ';');
    while (tokens.next()) |token| {
        try check(deadline);
        if (matchRefs(ref, token)) return true;
    }
    return false;
}

fn commonDestination(first: Road, second: Road, third: ?Road, deadline: io.Deadline) !bool {
    var tokens = std.mem.tokenizeScalar(u8, first.destination_refs, ';');
    while (tokens.next()) |token| {
        try check(deadline);
        if (!try destination(token, second, deadline)) continue;
        if (third) |other| if (!try destination(token, other, deadline)) continue;
        return true;
    }
    return false;
}

const Intersection = struct {
    best: u4 = no_class,
    link_count: u32 = 0,
    roads: bool = false,
    exits: u32 = 0,
};

fn intersection(arcs: []const Arc, deadline: io.Deadline) !Intersection {
    var info: Intersection = .{};
    for (arcs, 0..) |arc, i| {
        if (i % 256 == 0) try check(deadline);
        info.link_count += @intFromBool(arc.link);
        info.exits += @intFromBool(arc.forwardLink());
        info.roads = info.roads or !arc.link;
        if (arc.drivableRoad()) info.best = @min(info.best, @as(u4, @intCast(@backingInt(arc.road_class))));
    }
    return info;
}

const Exit = struct {
    node: u32,
    class: u4,
    osm_order: u64,
    key: u64,
};

/// Source supplies logical junctions (including all aliases), oriented
/// physical arcs in encounter order, and their geometry and OSM tags.
pub fn classify(a: Allocator, source: anytype, results: []Result, options: Options) !void {
    if (results.len == 0 or (!options.reclassify and !options.infer_turn_channels)) return;
    var self: Classifier(@TypeOf(source)) = .{ .a = a, .source = source, .results = results, .options = options };
    defer self.deinit();
    var exits: std.ArrayList(Exit) = .empty;
    defer exits.deinit(a);
    for (0..source.nodeCount()) |i| {
        try check(options.deadline);
        const node: u32 = @intCast(i);
        self.arcs.clearRetainingCapacity();
        try source.appendArcs(node, &self.arcs, a);
        const info = try intersection(self.arcs.items, options.deadline);
        if (info.best == no_class or info.exits == 0) continue;
        const order = source.nodeOrder(node);
        const exit: Exit = .{
            .node = node,
            .class = info.best,
            .osm_order = order.osm,
            .key = (@as(u64, info.best) << 56) | order.geography,
        };
        try exits.appendNTimes(a, exit, info.exits);
    }
    const scratch = try a.alloc(Exit, exits.items.len);
    defer a.free(scratch);
    try radix.sortByU64(Exit, a, exits.items, scratch, {}, exitOsmKey, options.deadline);
    try radix.sortByU64(Exit, a, exits.items, scratch, {}, exitSpatialKey, options.deadline);
    for (exits.items) |exit| {
        try check(options.deadline);
        try self.build(exit);
        try self.apply(exit.class);
    }
}

fn exitOsmKey(_: void, exit: Exit) u64 {
    return exit.osm_order;
}

fn exitSpatialKey(_: void, exit: Exit) u64 {
    return exit.key;
}

const Visit = struct {
    graph_index: u32,
    active: bool,
};

const GraphNode = struct {
    node: u32,
    class: u4,
    link_count: u32,
    has_road: bool,
    has_exit: bool,
    first_parent: u32 = no_arc,
    last_parent: u32 = no_arc,
    parent_count: u32 = 0,
    child_count: u32 = 0,
    children_done: u32 = 0,
};

const Parent = struct {
    node: u32,
    ref: u32,
    next: u32 = no_arc,
};

const Frame = struct {
    node: u32,
    start: usize,
    cursor: usize,
    end: usize,
};

fn Classifier(comptime Source: type) type {
    return struct {
        const Self = @This();
        const Set = std.AutoHashMapUnmanaged(u32, void);

        a: Allocator,
        source: Source,
        results: []Result,
        options: Options,
        graph: std.ArrayList(GraphNode) = .empty,
        parents: std.ArrayList(Parent) = .empty,
        visited: std.AutoHashMapUnmanaged(u32, Visit) = .empty,
        stack: std.ArrayList(Frame) = .empty,
        arcs: std.ArrayList(Arc) = .empty,
        nearby: std.ArrayList(Arc) = .empty,
        sort_scratch: std.ArrayList(Arc) = .empty,
        queue: std.ArrayList(u32) = .empty,
        reached: Set = .empty,
        walk: Set = .empty,
        reverse_walk: Set = .empty,
        chain: std.ArrayList(u32) = .empty,

        fn deinit(self: *Self) void {
            self.chain.deinit(self.a);
            self.reverse_walk.deinit(self.a);
            self.walk.deinit(self.a);
            self.reached.deinit(self.a);
            self.queue.deinit(self.a);
            self.sort_scratch.deinit(self.a);
            self.nearby.deinit(self.a);
            self.arcs.deinit(self.a);
            self.stack.deinit(self.a);
            self.visited.deinit(self.a);
            self.parents.deinit(self.a);
            self.graph.deinit(self.a);
        }

        fn sortedArcs(self: *Self, node: u32, out: *std.ArrayList(Arc)) ![]const Arc {
            const start = out.items.len;
            try self.source.appendArcs(node, out, self.a);
            const arcs = out.items[start..];
            var offsets: [32]usize = @splat(0);
            for (arcs, 0..) |*arc, i| {
                if (i % 256 == 0) try check(self.options.deadline);
                const result = self.results[arc.segment()];
                if (result.processed) arc.road_class = @fromBackingInt(@as(u8, result.road_class));
                offsets[arc.rank()] += 1;
            }
            var offset: usize = 0;
            for (&offsets) |*position| {
                const count = position.*;
                position.* = offset;
                offset += count;
            }
            try self.sort_scratch.resize(self.a, arcs.len);
            for (arcs, 0..) |arc, i| {
                if (i % 256 == 0) try check(self.options.deadline);
                const position = &offsets[arc.rank()];
                self.sort_scratch.items[position.*] = arc;
                position.* += 1;
            }
            @memcpy(arcs, self.sort_scratch.items);
            return arcs;
        }

        fn build(self: *Self, exit: Exit) !void {
            self.graph.clearRetainingCapacity();
            self.parents.clearRetainingCapacity();
            self.visited.clearRetainingCapacity();
            self.stack.clearRetainingCapacity();
            self.arcs.clearRetainingCapacity();
            const arc_slice = try self.sortedArcs(exit.node, &self.arcs);
            const root = try self.addNode(exit.node, try intersection(arc_slice, self.options.deadline));
            self.graph.items[root].class = exit.class;
            try self.enter(root, 0);

            var root_road: Road = .{ .way = 0, .name = "", .ref = "", .destination_refs = "" };
            while (self.stack.items.len != 0) {
                try check(self.options.deadline);
                const frame = &self.stack.items[self.stack.items.len - 1];
                const parent = frame.node;
                if (frame.cursor == frame.end) {
                    self.visited.getPtr(self.graph.items[parent].node).?.active = false;
                    self.arcs.shrinkRetainingCapacity(frame.start);
                    _ = self.stack.pop();
                    continue;
                }
                const arc = self.arcs.items[frame.cursor];
                frame.cursor += 1;
                if (!arc.forwardLink()) continue;
                if (self.results[arc.segment()].processed) {
                    if (parent != root) self.graph.items[parent].class = @min(self.graph.items[parent].class, @as(u4, @intCast(@backingInt(arc.road_class))));
                    continue;
                }
                if (parent == root and @backingInt(arc.road_class) <= @backingInt(RoadClass.trunk))
                    root_road = try self.source.road(arc.ref);

                if (self.visited.get(arc.head)) |seen| {
                    if (!seen.active) try self.addParent(seen.graph_index, parent, arc.ref);
                    continue;
                }

                const start = self.arcs.items.len;
                const next = try self.sortedArcs(arc.head, &self.arcs);
                const info = try intersection(next, self.options.deadline);
                const child = try self.addNode(arc.head, info);
                try self.addParent(child, parent, arc.ref);
                if (info.best <= @backingInt(RoadClass.residential) and
                    !try self.through(arc, root_road, next))
                {
                    self.arcs.shrinkRetainingCapacity(start);
                    continue;
                }
                try self.enter(child, start);
            }
        }

        fn addNode(self: *Self, node: u32, info: Intersection) !u32 {
            const id = std.math.cast(u32, self.graph.items.len) orelse return error.TooManyLinkNodes;
            try self.graph.append(self.a, .{
                .node = node,
                .class = info.best,
                .link_count = info.link_count,
                .has_road = info.roads,
                .has_exit = self.source.hasExit(node),
            });
            return id;
        }

        fn enter(self: *Self, node: u32, start: usize) !void {
            try self.visited.put(self.a, self.graph.items[node].node, .{ .graph_index = node, .active = true });
            try self.stack.append(self.a, .{ .node = node, .start = start, .cursor = start, .end = self.arcs.items.len });
        }

        fn addParent(self: *Self, child: u32, parent: u32, ref: u32) !void {
            const index = std.math.cast(u32, self.parents.items.len) orelse return error.TooManyLinkArcs;
            if (index == no_arc) return error.TooManyLinkArcs;
            try self.parents.append(self.a, .{ .node = parent, .ref = ref });
            self.graph.items[parent].child_count += 1;
            if (self.graph.items[parent].child_count >= 32) return error.TooManyLinkChildren;
            const node = &self.graph.items[child];
            if (node.first_parent == no_arc)
                node.first_parent = index
            else
                self.parents.items[node.last_parent].next = index;
            node.last_parent = index;
            node.parent_count += 1;
        }

        fn destinationNode(self: *const Self, road: Road, arcs: []const Arc) !bool {
            if (road.empty()) return false;
            for (arcs) |arc| {
                try check(self.options.deadline);
                if (!arc.drivableRoad()) continue;
                const other = try self.source.road(arc.ref);
                if (other.sameRoad(road) or try destination(other.ref, road, self.options.deadline)) return true;
            }
            return false;
        }

        fn through(self: *Self, arc: Arc, root: Road, next: []const Arc) !bool {
            const inbound = try self.source.road(arc.ref);
            if (inbound.empty() or try self.destinationNode(root, next)) return false;
            if (!root.sameRoad(inbound) and !try commonDestination(root, inbound, null, self.options.deadline)) return false;
            var common = false;
            for (next) |outbound_arc| {
                try check(self.options.deadline);
                if (!outbound_arc.forwardLink()) continue;
                const outbound = try self.source.road(outbound_arc.ref);
                if (outbound.sameRoad(inbound) and inbound.sameRoad(root)) return true;
                if (!common) common = try commonDestination(outbound, inbound, root, self.options.deadline);
            }
            return common and try self.reachesDestination(arc.head, root);
        }

        fn reachesDestination(self: *Self, start: u32, root: Road) !bool {
            self.queue.clearRetainingCapacity();
            self.reached.clearRetainingCapacity();
            try self.queue.append(self.a, start);
            var cursor: usize = 0;
            while (cursor < self.queue.items.len) : (cursor += 1) {
                try check(self.options.deadline);
                const at = self.queue.items[cursor];
                if (self.visited.get(at)) |present| if (present.active) continue;
                const reached = try self.reached.getOrPut(self.a, at);
                if (reached.found_existing) continue;
                self.nearby.clearRetainingCapacity();
                try self.source.appendArcs(at, &self.nearby, self.a);
                if (try self.destinationNode(root, self.nearby.items)) return true;
                for (self.nearby.items) |arc| {
                    try check(self.options.deadline);
                    if (arc.forwardLink()) try self.queue.append(self.a, arc.head);
                }
            }
            return false;
        }

        fn apply(self: *Self, exit_class: u4) !void {
            self.queue.clearRetainingCapacity();
            for (self.graph.items, 0..) |node, i| {
                try check(self.options.deadline);
                if (node.child_count == 0) try self.queue.append(self.a, @intCast(i));
            }
            var cursor: usize = 0;
            while (cursor < self.queue.items.len) : (cursor += 1) {
                try check(self.options.deadline);
                const leaf_id = self.queue.items[cursor];
                const leaf = self.graph.items[leaf_id];
                var parent_link = leaf.first_parent;
                while (parent_link != no_arc) : (parent_link = self.parents.items[parent_link].next) {
                    try check(self.options.deadline);
                    var parent_index = self.parents.items[parent_link].node;
                    var current = leaf_id;
                    var has_fork = false;
                    var has_exit = leaf.has_exit;
                    self.chain.clearRetainingCapacity();

                    while (self.graph.items[current].parent_count != 0) {
                        try check(self.options.deadline);
                        const link = try self.findParent(current, parent_index);
                        try self.chain.append(self.a, link.ref);
                        const parent = &self.graph.items[parent_index];
                        parent.children_done += 1;
                        has_fork = has_fork or parent.link_count > 2;
                        has_exit = has_exit or parent.has_exit;
                        current = parent_index;
                        if (parent.class != no_class or parent.child_count > 1 or parent.parent_count != 1) {
                            parent.class = @min(parent.class, leaf.class);
                            if (parent.children_done == parent.child_count) try self.queue.append(self.a, parent_index);
                            break;
                        }
                        parent_index = self.parents.items[parent.first_parent].node;
                    }

                    const endpoint = self.graph.items[current];
                    const leaf_class = if (leaf.class == no_class) endpoint.class else leaf.class;
                    const class = @max(exit_class, leaf_class);
                    if (class == no_class) continue;
                    const is_channel = self.options.infer_turn_channels and class > @backingInt(RoadClass.trunk) and
                        !has_fork and !has_exit and leaf.has_road and endpoint.has_road and
                        try self.isTurnChannel();

                    for (self.chain.items) |ref| {
                        try check(self.options.deadline);
                        const raw = (try self.source.arc(ref)).road_class;
                        const result = &self.results[ref / 2];
                        const old: u3 = if (result.processed) result.road_class else @intCast(@backingInt(raw));
                        const reclass = self.options.reclassify and class > old;
                        result.* = .{
                            .road_class = if (!reclass)
                                old
                            else if (class < @backingInt(RoadClass.unclassified))
                                @intCast(class)
                            else
                                @intCast(@backingInt(RoadClass.tertiary)),
                            .processed = true,
                            .turn_channel = result.turn_channel or is_channel,
                        };
                    }
                }
            }
        }

        fn findParent(self: *const Self, child: u32, parent: u32) !Parent {
            var index = self.graph.items[child].first_parent;
            while (index != no_arc) {
                try check(self.options.deadline);
                const edge = self.parents.items[index];
                if (edge.node == parent) return edge;
                index = edge.next;
            }
            return error.InvalidLinkGraph;
        }

        fn isTurnChannel(self: *Self) !bool {
            var length: f32 = 0;
            for (self.chain.items) |ref| {
                try check(self.options.deadline);
                const arc = try self.source.arc(ref);
                if (arc.outbound and arc.inbound) return false;
                length = @floatCast(@as(f64, length) + self.source.length(ref));
            }
            if (length < max_turn_channel_m) return true;

            // The chain is stored from leaf to root. Walk the two nonlink
            // approaches towards their intersection to recognize longer slip lanes.
            const first = self.chain.items[self.chain.items.len - 1];
            const last = self.chain.items[0];
            const start = (try self.source.arc(first ^ 1)).head;
            const end = (try self.source.arc(last)).head;
            const fork = (try self.closestRoad(start, first, true)) orelse return false;
            const merge = (try self.closestRoad(end, last ^ 1, false)) orelse return false;
            const threshold: f64 = @as(f64, length) * 2;
            self.walk.clearRetainingCapacity();
            self.reverse_walk.clearRetainingCapacity();
            _ = try self.walkRoads(start, fork, true, threshold, &self.walk, null);
            return self.walkRoads(end, merge, false, threshold, &self.reverse_walk, &self.walk);
        }

        fn closestRoad(self: *Self, node: u32, ref: u32, forward: bool) !?Arc {
            self.nearby.clearRetainingCapacity();
            const arcs = try self.sortedArcs(node, &self.nearby);
            const heading = try self.source.heading(ref);
            var best: ?Arc = null;
            var best_angle: f64 = 360;
            for (arcs) |arc| {
                try check(self.options.deadline);
                if (arc.link or !(if (forward) arc.outbound else arc.inbound)) continue;
                const delta = @abs(heading - try self.source.heading(arc.ref));
                const angle = @min(delta, 360 - delta);
                if (angle < best_angle) {
                    best_angle = angle;
                    best = arc;
                }
            }
            return best;
        }

        fn walkRoads(self: *Self, start: u32, first: Arc, forward: bool, threshold: f64, visited: *Set, other: ?*const Set) !bool {
            var previous = first;
            var length = self.source.length(previous.ref);
            try visited.put(self.a, start, {});
            if (other) |opposite| if (opposite.contains(start)) return true;
            while (true) {
                try check(self.options.deadline);
                const node = previous.head;
                try visited.put(self.a, node, {});
                if (other) |opposite| if (opposite.contains(node)) return true;
                if (length >= threshold) return false;

                self.nearby.clearRetainingCapacity();
                const arcs = try self.sortedArcs(node, &self.nearby);
                const prev_road = try self.source.road(previous.ref);
                var count: usize = 0;
                var first_road: ?Arc = null;
                var matching_name: ?Arc = null;
                for (arcs) |arc| {
                    try check(self.options.deadline);
                    if (arc.link or !(if (forward) arc.outbound else arc.inbound) or visited.contains(arc.head)) continue;
                    count += 1;
                    if (first_road == null) first_road = arc;
                    if (matching_name == null and prev_road.matchesName(try self.source.road(arc.ref)))
                        matching_name = arc;
                }
                const continuation = if (count == 1) first_road else matching_name;
                previous = continuation orelse return false;
                length += self.source.length(previous.ref);
            }
        }
    };
}

fn check(deadline: io.Deadline) error{DeadlineExceeded}!void {
    if (deadline.expired()) return error.DeadlineExceeded;
}
