// Ported from src/mjolnir/pbfgraphparser.cc and src/mjolnir/graphbuilder.cc
// (Valhalla 3.9.3). An edge is in OSM way orientation, before CSR assembly.
const std = @import("std");
const geo = @import("../geo/root.zig");
const io = @import("../infra/io.zig");
const node_store = @import("node_store.zig");
const pbf = @import("pbf/root.zig");
const tags = @import("tags/root.zig");
const usage = @import("node_store/usage.zig");
const way_shape = @import("way_shape.zig");

const Allocator = std.mem.Allocator;
const Point = geo.FixedLL;
const NodeFlags = tags.NodeAttrs.Flags;

pub const Edge = extern struct {
    way_id: i64,
    from: i64,
    to: i64,
    /// Index into the fixed-point point stream, including both endpoints.
    shape_offset: u64,
    length_m: f64,
    shape_count: u32,
    flags: Flags,
};

pub const Flags = packed struct(u32) {
    way_begin: bool = false,
    way_end: bool = false,
    traffic_signal: bool = false,
    forward_signal: bool = false,
    backward_signal: bool = false,
    stop_sign: bool = false,
    forward_stop: bool = false,
    backward_stop: bool = false,
    yield_sign: bool = false,
    forward_yield: bool = false,
    backward_yield: bool = false,
    direction: bool = false,
    reserved: u20 = 0,

    fn addControl(self: *Flags, node: NodeFlags) void {
        if (node.traffic_signal) {
            self.traffic_signal = true;
            self.forward_signal = node.forward_signal;
            self.backward_signal = node.backward_signal;
        } else if (node.stop_sign) {
            self.stop_sign = true;
            self.forward_stop = node.forward_stop;
            self.backward_stop = node.backward_stop;
            self.direction = node.direction;
        } else if (node.yield_sign) {
            self.yield_sign = true;
            self.forward_yield = node.forward_yield;
            self.backward_yield = node.backward_yield;
            self.direction = node.direction;
        }
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Edge) == 48);
    std.debug.assert(@offsetOf(Edge, "way_id") == 0 and @offsetOf(Edge, "from") == 8 and @offsetOf(Edge, "to") == 16);
    std.debug.assert(@offsetOf(Edge, "shape_offset") == 24 and @offsetOf(Edge, "length_m") == 32);
    std.debug.assert(@offsetOf(Edge, "shape_count") == 40 and @offsetOf(Edge, "flags") == 44);
    std.debug.assert(@sizeOf(Point) == 8 and @offsetOf(Point, "lat") == 4);
}

pub const Stats = struct {
    nodes: u64 = 0,
    edges: u64 = 0,
    shape_points: u64 = 0,
    too_short_ways: u64 = 0,
    missing_node_refs: u64 = 0,
    unresolved_ways: u64 = 0,
    self_edges: u64 = 0,
    zero_length_edges: u64 = 0,
    duplicate_edges: u64 = 0,
};

pub const Options = struct {
    scratch_dir: []const u8,
    workers: usize = 0,
    include_construction: bool = false,
    include_platforms: bool = false,
    deadline: io.Deadline = .none,
};

pub const Output = struct {
    edges: io.File,
    shapes: io.File,
};

/// Build ordered arrays of Edge and Point in distinct, read/write scratch
/// files. The callback receives way attributes and raw tags whose strings
/// are borrowed until it returns. Publish these results only on success.
/// The allocator must support concurrent use when workers run in parallel.
pub fn build(
    gpa: Allocator,
    source: pbf.file.Stream,
    out: Output,
    options: Options,
    context: anytype,
    comptime consumeWay: fn (@TypeOf(context), i64, tags.WayAttrs, pbf.block.TagIterator) anyerror!void,
) !Stats {
    if (out.edges.fd == out.shapes.fd) return error.InvalidEdgeOutput;
    const store_file = try io.File.temporary(options.scratch_dir);
    defer store_file.close();
    var prep: Preparation = .{
        .gpa = gpa,
        .options = options,
        .cuts = try usage.Usage.init(options.scratch_dir),
    };
    defer prep.deinit();
    const store = try node_store.buildObserving(gpa, source, store_file, .{
        .scratch_dir = options.scratch_dir,
        .deadline = options.deadline,
    }, &prep, Preparation.include, Preparation.observeNode);
    const cuts = try prep.cuts.freeze(options.deadline);

    var used = try usage.Usage.init(options.scratch_dir);
    defer used.deinit();
    try out.edges.truncate(0);
    try out.shapes.truncate(0);
    errdefer {
        out.edges.truncate(0) catch {};
        out.shapes.truncate(0) catch {};
    }

    const requested = if (options.workers == 0) std.Thread.getCpuCount() catch 1 else options.workers;
    const workers = try gpa.alloc(Worker, @min(requested, max_workers));
    defer gpa.free(workers);
    for (workers) |*worker| worker.* = .{ .cuts = cuts.cursor() };
    defer for (workers) |*worker| worker.deinit(gpa);
    const Pass = StreamPass(@TypeOf(context), consumeWay);
    var pass: Pass = .{
        .gpa = gpa,
        .options = options,
        .context = context,
        .out = out,
        .workers = workers,
        .shared = .{ .store = store, .controls = &prep.controls, .options = options },
        .used = &used,
        .stats = .{ .too_short_ways = prep.too_short_ways },
    };
    defer pass.deinit();
    try source.forEach(gpa, options.deadline, &pass, Pass.visit);
    return pass.stats;
}

fn transform(
    scratch: *tags.Scratch,
    way: pbf.block.Way,
    options: Options,
) !?tags.WayAttrs {
    const attrs = try tags.transformWay(scratch, way.tags, options.deadline) orelse return null;
    if (attrs.flags.pedestrian_area) return null;
    if (attrs.use == .construction and !options.include_construction) return null;
    if (attrs.use == .platform and !options.include_platforms) return null;
    return attrs;
}

const Controls = std.AutoHashMapUnmanaged(i64, NodeFlags);
const Refs = std.ArrayList(i64);
const Occurrences = std.AutoHashMapUnmanaged(i64, usize);

fn loadRefs(gpa: Allocator, refs: *Refs, way: pbf.block.Way) !void {
    refs.clearRetainingCapacity();
    var iter = way.refs;
    while (try iter.next()) |id| try refs.append(gpa, id);
}

fn shapeOf(refs: []const i64) way_shape.Shape {
    if (refs.len < 2) return .short;
    return if (refs[0] == refs[refs.len - 1]) .closed else .open;
}

const Preparation = struct {
    gpa: Allocator,
    options: Options,
    cuts: usage.Usage,
    controls: Controls = .empty,
    scratch: tags.Scratch = .{},
    refs: Refs = .empty,
    last: Occurrences = .empty,
    too_short_ways: u64 = 0,

    fn deinit(self: *Preparation) void {
        self.cuts.deinit();
        self.controls.deinit(self.gpa);
        self.refs.deinit(self.gpa);
        self.last.deinit(self.gpa);
    }

    fn include(self: *Preparation, way: *const pbf.block.Way) !bool {
        _ = try transform(&self.scratch, way.*, self.options) orelse return false;
        try loadRefs(self.gpa, &self.refs, way.*);
        const refs = self.refs.items;
        const shape = shapeOf(refs);
        if (shape == .short) {
            self.too_short_ways += 1;
            return false;
        }
        if (!try way_shape.accepts(shape, way.tags)) return false;
        _ = try self.cuts.insert(usage.keyFor(refs[0]));
        _ = try self.cuts.insert(usage.keyFor(refs[refs.len - 1]));
        self.last.clearRetainingCapacity();
        for (refs, 0..) |id, i| {
            try checkDeadline(self.options.deadline, i);
            const seen = try self.last.getOrPut(self.gpa, id);
            if (seen.found_existing) {
                const prev = seen.value_ptr.*;
                const midpoint = refs[prev + (i - prev) / 2];
                _ = try self.cuts.insert(usage.keyFor(midpoint));
            }
            seen.value_ptr.* = i;
        }
        return true;
    }

    fn observeNode(self: *Preparation, node: pbf.block.Node) !void {
        var input = node.tags;
        if (try input.next() == null) return;
        const attrs = (try tags.transformNode(&self.scratch, node.tags, self.options.deadline)).?;
        switch (attrs.type) {
            .gate,
            .bollard,
            .toll_booth,
            .parking,
            .border_control,
            .toll_gantry,
            .sump_buster,
            .building_entrance,
            .elevator,
            => _ = try self.cuts.insert(usage.keyFor(node.id)),
            else => {},
        }
        if (attrs.flags.traffic_signal or attrs.flags.stop_sign or attrs.flags.yield_sign)
            try self.controls.put(self.gpa, node.id, attrs.flags);
    }
};

const max_workers = 16;
const ways_per_worker = 64;

const Shared = struct {
    store: node_store.Store,
    controls: *const Controls,
    options: Options,
};

const WayRecord = struct {
    source: pbf.block.Way,
    attrs: tags.WayAttrs,
};

const Candidate = struct {
    /// A ref seen once at the end of its only way has just one incident edge.
    can_overlap: bool,
    /// Canonical orientation is from the lower to the higher OSM node ID.
    shape_hash: u64,
};

const Worker = struct {
    cuts: usage.Usage.Cursor,
    cursor: node_store.Cursor = .{},
    scratch: tags.Scratch = .{},
    refs: Refs = .empty,
    last: Occurrences = .empty,
    locations: std.ArrayList(?node_store.Location) = .empty,
    doubled_back: std.ArrayList(bool) = .empty,
    ways: std.ArrayList(WayRecord) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    shapes: std.ArrayList(Point) = .empty,
    candidates: std.ArrayList(Candidate) = .empty,
    stats: Stats = .{},
    result: anyerror!void = {},

    fn deinit(self: *Worker, gpa: Allocator) void {
        self.refs.deinit(gpa);
        self.last.deinit(gpa);
        self.locations.deinit(gpa);
        self.doubled_back.deinit(gpa);
        self.ways.deinit(gpa);
        self.edges.deinit(gpa);
        self.shapes.deinit(gpa);
        self.candidates.deinit(gpa);
    }

    fn run(self: *Worker, gpa: Allocator, shared: *const Shared, ways: []const pbf.block.Way) void {
        self.ways.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.candidates.clearRetainingCapacity();
        self.stats = .{};
        self.result = self.process(gpa, shared, ways);
    }

    fn process(self: *Worker, gpa: Allocator, shared: *const Shared, ways: []const pbf.block.Way) !void {
        for (ways) |way| {
            const attrs = try transform(&self.scratch, way, shared.options) orelse continue;
            try loadRefs(gpa, &self.refs, way);
            const refs = self.refs.items;
            if (!try way_shape.accepts(shapeOf(refs), way.tags)) continue;

            try self.locations.resize(gpa, refs.len);
            const locations = self.locations.items;
            const deadline = shared.options.deadline;
            try self.cursor.lookupBatch(shared.store, refs, locations, deadline);
            var missing: usize = 0;
            for (locations, 0..) |loc, i| {
                try checkDeadline(deadline, i);
                missing += @intFromBool(loc == null);
            }
            if (missing > 0) {
                self.stats.missing_node_refs += missing;
                self.stats.unresolved_ways += 1;
                self.stats.too_short_ways += @intFromBool(refs.len - missing < 2);
                continue;
            }
            const start_edge = self.edges.items.len;
            const base = self.shapes.items.len;
            const points = try self.shapes.addManyAsSlice(gpa, refs.len);
            for (points, locations, 0..) |*point, loc, i| {
                try checkDeadline(deadline, i);
                point.* = .{ .lat = loc.?.lat, .lng = loc.?.lon };
            }
            try self.split(gpa, shared, way.id, base);
            if (start_edge == self.edges.items.len) {
                self.shapes.shrinkRetainingCapacity(base);
            } else {
                try self.ways.append(gpa, .{ .source = way, .attrs = attrs });
            }
        }
    }

    fn markFolded(self: *Worker, gpa: Allocator, deadline: io.Deadline) !void {
        const refs = self.refs.items;
        try self.doubled_back.resize(gpa, refs.len);
        self.last.clearRetainingCapacity();
        for (refs, self.doubled_back.items, 0..) |id, *folded, i| {
            try checkDeadline(deadline, i);
            const got = try self.last.getOrPut(gpa, id);
            const prev = if (got.found_existing) got.value_ptr.* else i;
            const flatten = prev > 0 and i + 1 < refs.len and refs[i + 1] == refs[prev - 1];
            const unflatten = i > 0 and prev + 1 < refs.len and refs[i - 1] == refs[prev + 1];
            folded.* = flatten or unflatten;
            got.value_ptr.* = i;
        }
    }

    fn split(self: *Worker, gpa: Allocator, shared: *const Shared, way_id: i64, base: usize) !void {
        const refs = self.refs.items;
        const points = self.shapes.items[base..];
        const locations = self.locations.items;
        const deadline = shared.options.deadline;
        try self.markFolded(gpa, deadline);
        const folded = self.doubled_back.items;

        var start: usize = 0;
        var end: usize = 1;
        var length: f64 = 0;
        var flags: Flags = .{ .way_begin = true };
        while (end < refs.len) : (end += 1) {
            try checkDeadline(deadline, end - 1);
            length += points[end].toPoint().distance(points[end - 1].toPoint());
            const id = refs[end];
            if (end + 1 != refs.len and locations[end].?.uses < 2 and
                !try self.cuts.contains(usage.keyFor(id)))
            {
                if (shared.controls.get(id)) |signal| flags.addControl(signal);
                continue;
            }

            flags.way_end = end + 1 == refs.len;
            self.stats.zero_length_edges += @intFromBool(length == 0);
            if (refs[start] == id) {
                self.stats.self_edges += 1;
            } else {
                const count = std.math.cast(u32, end - start + 1) orelse return error.ShapeTooLarge;
                try self.edges.append(gpa, .{
                    .way_id = way_id,
                    .from = refs[start],
                    .to = id,
                    .shape_offset = base + start,
                    .length_m = length,
                    .shape_count = count,
                    .flags = flags,
                });
                const can_overlap = (start != 0 or locations[start].?.uses > 1) and
                    (end + 1 != refs.len or locations[end].?.uses > 1);
                const hash = if (can_overlap)
                    try hashShape(points[start .. end + 1], refs[start] > id, deadline)
                else
                    0;
                try self.candidates.append(gpa, .{ .can_overlap = can_overlap, .shape_hash = hash });
            }

            // GraphBuilder skips the return side of a folded sequence once
            // it reaches a cut where two consecutive refs are marked folded.
            while (end + 1 < refs.len and folded[end] and folded[end + 1]) {
                try checkDeadline(deadline, end);
                end += 1;
            }
            start = end;
            length = 0;
            flags = .{};
        }
    }
};

fn checkDeadline(deadline: io.Deadline, i: usize) error{DeadlineExceeded}!void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

fn hashShape(shape: []const Point, reverse: bool, deadline: io.Deadline) !u64 {
    var hash = std.hash.Wyhash.init(0);
    for (0..shape.len) |i| {
        try checkDeadline(deadline, i);
        const index = if (reverse) shape.len - 1 - i else i;
        hash.update(std.mem.asBytes(&shape[index]));
    }
    return hash.final();
}

const DuplicateIndex = struct {
    const Key = struct { low: i64, high: i64, hash: u64 };
    const Entry = struct {
        offset: u64,
        count: u32,
        reverse: bool,
        next: ?u32,
    };

    by_key: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *DuplicateIndex, gpa: Allocator) void {
        self.by_key.deinit(gpa);
        self.entries.deinit(gpa);
    }

    fn insert(
        self: *DuplicateIndex,
        gpa: Allocator,
        file: io.File,
        edge: Edge,
        shape: []const Point,
        hash: u64,
        deadline: io.Deadline,
    ) !bool {
        const key: Key = .{ .low = @min(edge.from, edge.to), .high = @max(edge.from, edge.to), .hash = hash };
        const head = try self.by_key.getOrPut(gpa, key);
        const first = if (head.found_existing) head.value_ptr.* else null;
        var current = first;
        const reverse = edge.from > edge.to;
        while (current) |index| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const candidate = self.entries.items[index];
            if (candidate.count == edge.shape_count and
                try sameShape(file, candidate.offset, shape, candidate.reverse != reverse, deadline)) return false;
            current = candidate.next;
        }
        head.value_ptr.* = std.math.cast(u32, self.entries.items.len) orelse return error.TooManyEdges;
        try self.entries.append(gpa, .{
            .offset = edge.shape_offset,
            .count = edge.shape_count,
            .reverse = reverse,
            .next = first,
        });
        return true;
    }
};

fn sameShape(file: io.File, offset: u64, shape: []const Point, reverse: bool, deadline: io.Deadline) !bool {
    var stash: [128]Point = undefined;
    var i: usize = 0;
    while (i < shape.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const count = @min(stash.len, shape.len - i);
        const bytes = std.mem.sliceAsBytes(stash[0..count]);
        try file.preadAll(bytes, (offset + i) * @sizeOf(Point));
        for (stash[0..count], i..) |point, j| {
            const here = shape[if (reverse) shape.len - 1 - j else j];
            if (here.lng != point.lng or here.lat != point.lat) return false;
        }
        i += count;
    }
    return true;
}

fn StreamPass(comptime Context: type, comptime consumeWay: anytype) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        options: Options,
        context: Context,
        out: Output,
        workers: []Worker,
        shared: Shared,
        used: *usage.Usage,
        duplicates: DuplicateIndex = .{},
        stats: Stats,
        scratch: pbf.block.Scratch = .{},
        ways: std.ArrayList(pbf.block.Way) = .empty,

        fn deinit(self: *Self) void {
            self.duplicates.deinit(self.gpa);
            self.scratch.deinit(self.gpa);
            self.ways.deinit(self.gpa);
        }

        fn visit(self: *Self, _: usize, bytes: []const u8) !void {
            const deadline = self.options.deadline;
            const block = try self.scratch.decode(self.gpa, bytes, deadline);
            self.ways.clearRetainingCapacity();
            var iter = block.ways();
            while (try iter.next()) |way| try self.ways.append(self.gpa, way);
            const ways = self.ways.items;
            if (ways.len == 0) return;

            const count = @min(self.workers.len, 1 + (ways.len - 1) / ways_per_worker);
            var threads: [max_workers - 1]std.Thread = undefined;
            var started: usize = 0;
            errdefer for (threads[0..started]) |thread| thread.join();
            var start: usize = 0;
            for (self.workers[0..count], 0..) |*worker, i| {
                const end = start + ways.len / count + @intFromBool(i < ways.len % count);
                if (i + 1 == count) {
                    worker.run(self.gpa, &self.shared, ways[start..end]);
                } else {
                    threads[started] = try std.Thread.spawn(.{}, Worker.run, .{ worker, self.gpa, &self.shared, ways[start..end] });
                    started += 1;
                }
                start = end;
            }
            for (threads[0..started]) |thread| thread.join();
            started = 0;

            for (self.workers[0..count]) |*worker| try worker.result;
            for (self.workers[0..count]) |*worker| try self.publish(worker);
        }

        fn publish(self: *Self, worker: *Worker) !void {
            self.stats.too_short_ways += worker.stats.too_short_ways;
            self.stats.missing_node_refs += worker.stats.missing_node_refs;
            self.stats.unresolved_ways += worker.stats.unresolved_ways;
            self.stats.self_edges += worker.stats.self_edges;
            self.stats.zero_length_edges += worker.stats.zero_length_edges;
            if (worker.edges.items.len == 0) return;

            const deadline = self.options.deadline;
            const base = self.stats.shape_points;
            const shape_bytes = std.mem.sliceAsBytes(worker.shapes.items);
            try self.out.shapes.pwriteAll(shape_bytes, base * @sizeOf(Point));
            for (worker.ways.items, 0..) |way, i| {
                try checkDeadline(deadline, i);
                try consumeWay(self.context, way.source.id, way.attrs, way.source.tags);
            }
            for (worker.edges.items, worker.candidates.items, 0..) |*edge, candidate, i| {
                try checkDeadline(deadline, i);
                const shape = worker.shapes.items[@intCast(edge.shape_offset)..][0..edge.shape_count];
                edge.shape_offset += base;
                self.stats.nodes += @intFromBool(try self.used.insert(usage.keyFor(edge.from)));
                self.stats.nodes += @intFromBool(try self.used.insert(usage.keyFor(edge.to)));
                if (candidate.can_overlap and
                    !try self.duplicates.insert(self.gpa, self.out.shapes, edge.*, shape, candidate.shape_hash, deadline))
                    self.stats.duplicate_edges += 1;
            }
            const edge_bytes = std.mem.sliceAsBytes(worker.edges.items);
            try self.out.edges.pwriteAll(edge_bytes, self.stats.edges * @sizeOf(Edge));
            self.stats.shape_points += worker.shapes.items.len;
            self.stats.edges += worker.edges.items.len;
        }
    };
}
