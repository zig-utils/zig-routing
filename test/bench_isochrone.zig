//! Time the isochrone grid stage with the same inputs as the Valhalla oracle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const memory = routing.infra.arena;
const iso = routing.search.isochrone;
const queue = routing.search.queue;
const snap = routing.snap.candidates;
const Candidate = routing.search.endpoints.Candidate;
const View = routing.graph.reader.View;
const Foot = @import("pedestrian_search_kernel.zig").Foot;
const Auto = @import("auto_search_kernel.zig").Auto;
const pedestrian = routing.costing.pedestrian;
const auto = routing.costing.auto;

const Mode = enum { auto, pedestrian };
const Traversal = enum { baseline, ordered_queue, label_activity, compact };
const Location = struct { lat: f64, lon: f64 };
const Contour = struct { time: ?f32 = null, distance: ?f32 = null };
const Row = struct {
    locations: []const Location,
    contours: []const Contour,
    costing: Mode,
    reverse: bool = false,
    date_time_utc: ?[]const u8 = null,
};

const Visit = routing.search.expand.Visit;

fn LayoutObserver(comptime Observer: type) type {
    return struct {
        layout: *const iso.MovementLayout,
        observer: Observer,

        pub fn movementLayout(self: @This()) *const iso.MovementLayout {
            return self.layout;
        }

        pub fn observe(self: @This(), event: Visit) !void {
            if (Observer != void) try self.observer.observe(event);
        }
    };
}

fn observed(layout: anytype, observer: anytype) if (@TypeOf(layout) == void) @TypeOf(observer) else LayoutObserver(@TypeOf(observer)) {
    return if (@TypeOf(layout) == void) observer else .{ .layout = layout, .observer = observer };
}

const Replay = struct {
    a: std.mem.Allocator,
    events: std.ArrayList(Visit) = .empty,

    pub fn observe(self: *Replay, event: Visit) !void {
        try self.events.append(self.a, event);
    }
};

const Trace = struct {
    a: std.mem.Allocator,
    labels: union(enum) {
        basic: std.ArrayList(BasicEntry),
        state: std.ArrayList(StateEntry),
    },

    const BasicEntry = extern struct {
        index: u32,
        edge: u32,
        previous: u32,
        seconds: f32,
        cost: f32,
        metres: u32,
    };

    const StateEntry = extern struct {
        unix_time: i64,
        seconds_from_now: i64,
        label: routing.search.search.Label,
        index: u32,
        node: u32,
        cut_begin: f32,
        cut_end: f32,
        second_of_week: u32,
        zone_and_valid: u32,
    };

    comptime {
        std.debug.assert(@sizeOf(BasicEntry) == 24 and @sizeOf(StateEntry) == 72);
        std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    }

    pub fn observe(self: *Trace, event: routing.search.expand.Visit) !void {
        switch (self.labels) {
            .basic => |*entries| try entries.append(self.a, .{
                .index = event.index,
                .edge = event.label.edge,
                .previous = event.label.pred,
                .seconds = event.label.secs,
                .cost = event.label.cost,
                .metres = event.label.dist_m,
            }),
            .state => |*entries| try entries.append(self.a, .{
                .unix_time = event.time.unix_time,
                .seconds_from_now = event.time.seconds_from_now,
                .label = event.label,
                .index = event.index,
                .node = @backingInt(event.node),
                .cut_begin = event.cut.begin,
                .cut_end = event.cut.end,
                .second_of_week = event.time.second_of_week,
                .zone_and_valid = @as(u32, event.time.zone) << 1 | @intFromBool(event.time.valid),
            }),
        }
    }

    fn write(self: Trace, file: io.File) !void {
        switch (self.labels) {
            inline else => |entries| {
                const count: u32 = @intCast(entries.items.len);
                try file.writeAll(std.mem.asBytes(&count));
                try file.writeAll(std.mem.sliceAsBytes(entries.items));
            },
        }
    }
};

const StageClock = struct {
    const Stage = routing.search.search.ExpansionStage;
    phase: Stage = .queue,
    active: bool = false,
    started: u64 = 0,
    samples: usize = 0,
    read_overhead: u64 = 0,
    totals: std.EnumArray(Stage, u64) = .initFill(0),

    fn init() StageClock {
        var overhead: u64 = std.math.maxInt(u64);
        for (0..8) |_| {
            const start = io.monotonicNs();
            for (0..63) |_| _ = io.monotonicNs();
            overhead = @min(overhead, (io.monotonicNs() - start) / 64);
        }
        return .{ .read_overhead = overhead };
    }

    pub fn observe(_: *StageClock, _: routing.search.expand.Visit) !void {}

    pub fn expansionSample(self: *StageClock, popped: usize) void {
        self.finish();
        // Sample about one in 32 labels without locking to periodic queue traffic.
        const mixed = @as(u64, popped) *% 0x9e3779b97f4a7c15;
        self.active = (mixed >> 48) & 31 == 0;
        if (self.active) {
            self.samples += 1;
            self.phase = .queue;
            self.started = io.monotonicNs();
        }
    }

    pub fn expansionStage(self: *StageClock, phase: Stage) void {
        if (!self.active or phase == self.phase) return;
        const now = io.monotonicNs();
        self.totals.getPtr(self.phase).* += (now - self.started) -| self.read_overhead;
        self.started = now;
        self.phase = phase;
    }

    fn finish(self: *StageClock) void {
        if (!self.active) return;
        self.totals.getPtr(self.phase).* += (io.monotonicNs() - self.started) -| self.read_overhead;
        self.active = false;
    }
};

const Measurement = struct {
    view: *const View,
    arena: *memory.Arena,
    backing: *memory.CountingAllocator,
    index: usize,
    log: *std.Io.Writer,
    grids: io.File,
    traces: ?io.File,
    trace_states: bool,
    profile: bool,
    stages: bool,
    measure_memory: bool,
    scratch: std.mem.Allocator,
    layout: ?*const iso.MovementLayout,

    fn run(self: Measurement, engine: anytype, kernel: anytype, request: iso.Request) !void {
        if (self.layout) |layout|
            try self.measure(engine, kernel, request, layout)
        else
            try self.measure(engine, kernel, request, {});
    }

    fn measure(self: Measurement, engine: anytype, kernel: anytype, request: iso.Request, layout: anytype) !void {
        const arena = self.arena;
        const backing = self.backing;
        arena.reset();
        _ = try engine.runObserved(arena, kernel, request, observed(layout, {}), .{});
        backing.resetCounts();
        arena.reset();
        arena.high_water = 0;
        var clock: StageClock = if (self.profile and !self.stages) .init() else .{};
        const start = io.monotonicNs();
        const result = if (self.profile and !self.stages)
            try engine.runObserved(arena, kernel, request, &clock, .{})
        else
            try engine.runObserved(arena, kernel, request, observed(layout, {}), .{});
        const elapsed = io.monotonicNs() - start;
        const full_bytes = @max(arena.high_water, arena.used);
        clock.finish();
        if (backing.calls() != 0) return error.IsochroneAllocatedAfterWarmup;
        const tiles = result.grid.tiles;
        const bounds = tiles.bounds;
        try self.log.print("{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
            self.index,          elapsed,     tiles.ncolumns, tiles.nrows, @as(f64, tiles.tilesize),
            bounds.minx,         bounds.miny, bounds.maxx,    bounds.maxy, result.stats.settled,
            result.stats.popped,
        });
        if (self.measure_memory) try self.log.print("\t{d}", .{full_bytes});
        try self.grids.writeAll(std.mem.sliceAsBytes(result.grid.data));
        if (self.stages) {
            const expected = try self.scratch.dupe(u8, std.mem.sliceAsBytes(result.grid.data));
            arena.reset();
            var replay: Replay = .{ .a = self.scratch };
            const recorded = try engine.runTraversal(arena, kernel, request, observed(layout, &replay), .{});
            if (!std.meta.eql(result.stats, recorded)) return error.DifferentBoundedTraversal;
            backing.resetCounts();
            arena.reset();
            arena.high_water = 0;
            const traversal_start = io.monotonicNs();
            const traversal = try engine.runTraversal(arena, kernel, request, observed(layout, {}), .{});
            const traversal_ns = io.monotonicNs() - traversal_start;
            const traversal_bytes = @max(arena.high_water, arena.used);
            if (backing.calls() != 0) return error.TraversalAllocatedAfterWarmup;
            if (!std.meta.eql(result.stats, traversal)) return error.DifferentBoundedTraversal;
            arena.reset();
            _ = try iso.rasterize(self.view, arena, request, replay.events.items, .{});
            arena.reset();
            backing.resetCounts();
            arena.high_water = 0;
            const raster_start = io.monotonicNs();
            const raster = try iso.rasterize(self.view, arena, request, replay.events.items, .{});
            const raster_ns = io.monotonicNs() - raster_start;
            const raster_bytes = @max(arena.high_water, arena.used);
            if (backing.calls() != 0) return error.RasterAllocatedAfterWarmup;
            if (!std.mem.eql(u8, expected, std.mem.sliceAsBytes(raster.data))) return error.DifferentRasterReplay;
            try self.log.print("\t{d}\t{d}", .{ traversal_ns, raster_ns });
            if (self.measure_memory) try self.log.print("\t{d}\t{d}", .{ traversal_bytes, raster_bytes });
            if (self.profile) {
                arena.reset();
                clock = .init();
                const profiled = try engine.runTraversal(arena, kernel, request, &clock, .{});
                if (!std.meta.eql(result.stats, profiled)) return error.DifferentBoundedTraversal;
                clock.finish();
            }
        }
        if (self.profile) {
            try self.log.print("\t{d}", .{clock.samples});
            for (std.enums.values(StageClock.Stage)) |stage| try self.log.print("\t{d}", .{clock.totals.get(stage)});
        }
        try self.log.writeByte('\n');
        if (self.traces) |file| {
            arena.reset();
            var trace: Trace = .{ .a = self.scratch, .labels = if (self.trace_states) .{ .state = .empty } else .{ .basic = .empty } };
            _ = try engine.runObserved(arena, kernel, request, observed(layout, &trace), .{});
            try trace.write(file);
        }
    }
};

fn correlate(view: *const View, a: std.mem.Allocator, row: Row) ![]const iso.Origin {
    const access: snap.Access = .{ .mask = switch (row.costing) {
        .auto => .{ .auto = true },
        .pedestrian => .{ .pedestrian = true },
    } };
    const origins = try a.alloc(iso.Origin, row.locations.len);
    for (row.locations, origins) |location, *origin| {
        const path = try snap.search(view, a, .{ .lat = location.lat, .lng = location.lon }, .{}, access, .none);
        const seeds = try a.alloc(Candidate, path.edges.len);
        for (path.edges, seeds) |edge, *seed| {
            seed.* = .{
                .edge = edge.id,
                .fraction = edge.percent_along,
                .score = @floatCast(edge.distance),
                .begin_node = edge.node == .begin,
                .end_node = edge.node == .end,
            };
        }
        origin.* = .{ .location = .init(location.lon, location.lat), .seed = .{ .edges = seeds } };
    }
    return origins;
}

fn prepareHeadings(view: *const View, allocator: std.mem.Allocator) ![]const u8 {
    const headings = try allocator.alloc(u8, view.edges.len);
    errdefer allocator.free(headings);
    var scratch = memory.Arena.init(allocator, .{});
    defer scratch.deinit();
    for (headings, 0..) |*heading, i| {
        heading.* = try auto.Turn.encodedHeading(view, @fromBackingInt(@as(u32, @intCast(i))), scratch.allocator(), .none);
        scratch.reset();
    }
    return headings;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const graph_path = args.next() orelse return error.MissingBundle;
    const input_path = args.next() orelse return error.MissingCorpus;
    const output_path = args.next() orelse return error.MissingGridOutput;
    var trace_path: ?[]const u8 = null;
    var trace_states = false;
    var profile = false;
    var stages = false;
    var prepare_layout = false;
    var prepare_headings = false;
    var rss = false;
    var measure_memory = false;
    var traversal: ?Traversal = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile") and !profile) {
            profile = true;
        } else if (std.mem.eql(u8, arg, "--stages") and !stages) {
            stages = true;
        } else if (std.mem.eql(u8, arg, "--layout") and !prepare_layout) {
            prepare_layout = true;
        } else if (std.mem.eql(u8, arg, "--headings-only") and !prepare_headings) {
            prepare_headings = true;
        } else if (std.mem.eql(u8, arg, "--rss") and !rss) {
            rss = true;
        } else if (std.mem.eql(u8, arg, "--memory") and !measure_memory) {
            measure_memory = true;
        } else if (std.mem.eql(u8, arg, "--trace-states") and !trace_states) {
            trace_states = true;
        } else if (std.mem.startsWith(u8, arg, "--traversal=") and traversal == null) {
            traversal = std.meta.stringToEnum(Traversal, arg["--traversal=".len..]) orelse return error.InvalidTraversal;
        } else if (trace_path == null) {
            trace_path = arg;
        } else return error.InvalidArguments;
    }
    if ((profile and (prepare_layout or prepare_headings)) or (prepare_layout and prepare_headings) or
        (trace_states and trace_path == null)) return error.InvalidArguments;
    const input = try io.File.open(input_path, .read_only);
    defer input.close();
    const data = try init.arena.allocator().alloc(u8, @intCast(try input.size()));
    try input.preadAll(data, 0);
    const grids = try io.File.open(output_path, .create_truncate);
    defer grids.close();
    const traces = if (trace_path) |path| try io.File.open(path, .create_truncate) else null;
    defer if (traces) |file| file.close();

    var bundle = try routing.graph.reader.Bundle.open(graph_path);
    defer bundle.close();
    var graph_view = bundle.view;
    const view = &graph_view;
    const headings = if (prepare_headings) blk: {
        if (view.headings != null) return error.BundleAlreadyHasHeadings;
        const start = io.monotonicNs();
        const ready = try prepareHeadings(view, init.gpa);
        std.debug.print("headings_ns={d} headings_bytes={d}\n", .{ io.monotonicNs() - start, ready.len });
        break :blk ready;
    } else null;
    defer if (headings) |ready| init.gpa.free(ready);
    if (headings) |ready| view.headings = ready;
    const layout: ?iso.MovementLayout = if (prepare_layout) blk: {
        const start = io.monotonicNs();
        const ready = try iso.MovementLayout.init(init.gpa, view, .none);
        std.debug.print("layout_ns={d} layout_bytes={d} edges={d} movements={d}\n", .{
            io.monotonicNs() - start, ready.residentBytes(), ready.opposite.len, ready.movements.len,
        });
        break :blk ready;
    } else null;
    defer if (layout) |ready| ready.deinit(init.gpa);
    switch (traversal orelse .baseline) {
        inline else => |variant| try runCorpus(variant, init, view, data, grids, traces, trace_states, profile, stages, measure_memory, if (layout) |*ready| ready else null),
    }
    if (rss) std.debug.print("peak_rss_bytes={d}\n", .{try io.peakRssBytes()});
}

fn runCorpus(
    comptime traversal: Traversal,
    init: std.process.Init,
    view: *const View,
    data: []const u8,
    grids: io.File,
    traces: ?io.File,
    trace_states: bool,
    profile: bool,
    stages: bool,
    measure_memory: bool,
    layout: ?*const iso.MovementLayout,
) !void {
    const Q = switch (traversal) {
        .baseline => queue.RadixQueue,
        .ordered_queue => queue.OrderedRadixQueue,
        .label_activity => queue.LabelActivityQueue,
        .compact => queue.CompactQueue,
    };
    var backing = memory.CountingAllocator.init(init.gpa);
    var walker = try iso.IsochroneWithQueue(Foot, Q).init(backing.allocator(), view);
    defer walker.deinit();
    var motorist = try iso.IsochroneWithQueue(Auto, Q).init(backing.allocator(), view);
    defer motorist.deinit();
    var walk_cache = try pedestrian.Cache.init(init.gpa, view.classes.?, 1);
    defer walk_cache.deinit();
    var drive_cache = try auto.Cache.init(init.gpa, view.classes.?, 1);
    defer drive_cache.deinit();
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    defer warnings.deinit(init.gpa);
    var walk = try walk_cache.acquire(try pedestrian.parse(init.gpa, .null, &warnings, .none), .none);
    defer walk.release();
    var drive = try drive_cache.acquire(try auto.parse(init.gpa, .auto, .null, &warnings, .none), .none);
    defer drive.release();

    var output_buffer: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &output_buffer);
    var request_memory = memory.Arena.init(backing.allocator(), .{});
    defer request_memory.deinit();
    var rows = std.mem.tokenizeScalar(u8, data, '\n');
    var index: usize = 0;
    while (rows.next()) |line| : (index += 1) {
        var storage: std.heap.ArenaAllocator = .init(init.gpa);
        defer storage.deinit();
        const a = storage.allocator();
        const row = try std.json.parseFromSliceLeaky(Row, a, line, .{ .ignore_unknown_fields = true });
        var contours: std.ArrayList(iso.Interval) = .empty;
        for (row.contours) |contour| {
            if (contour.time) |value| try contours.append(a, .{ .metric = iso.time_metric, .value = value });
            if (contour.distance) |value| try contours.append(a, .{ .metric = iso.distance_metric, .value = value });
        }
        const origins = try correlate(view, a, row);
        const request: iso.Request = .{
            .origins = origins,
            .contours = contours.items,
            .direction = if (row.reverse) .reverse else .forward,
            .timing = .{ .start = if (row.date_time_utc) |value|
                try routing.graph.time_info.TimeInfo.fromLocal(null, value, routing.graph.timezone.utc, routing.graph.timezone.utc, 0, .none)
            else
                .{} },
            .mode = switch (row.costing) {
                .auto => .motor,
                .pedestrian => .pedestrian,
            },
            .unit_size = switch (row.costing) {
                .auto => drive.tables().unit_size,
                .pedestrian => walk.tables().unit_size,
            },
        };
        const measurement: Measurement = .{
            .view = view,
            .arena = &request_memory,
            .backing = &backing,
            .index = index,
            .log = &output.interface,
            .grids = grids,
            .traces = traces,
            .trace_states = trace_states,
            .profile = profile,
            .stages = stages,
            .measure_memory = measure_memory,
            .scratch = a,
            .layout = layout,
        };
        switch (row.costing) {
            .auto => try measurement.run(&motorist, Auto{ .profile = drive.profile(), .tables = drive.tables(), .arena = request_memory.allocator() }, request),
            .pedestrian => try measurement.run(&walker, Foot{ .profile = walk.profile(), .tables = walk.tables() }, request),
        }
    }
    try output.interface.flush();
}
