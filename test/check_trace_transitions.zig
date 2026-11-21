//! Instrumented auto trace columns for the pinned Valhalla comparison.
const std = @import("std");
const routing = @import("routing");
const graph = routing.graph;
const io = routing.infra.io;
const cost = routing.costing;
const auto = cost.auto;
const core = routing.search.search;
const match = routing.match;

const Kernel = struct {
    profile: *const auto.Profile,
    tables: *const cost.compiled.Compiled,

    pub fn allowed(self: Kernel, edge: routing.snap.candidates.DirectedEdge) bool {
        return self.profile.allowedCandidate(edge.class, .{}, .{}, false);
    }

    pub fn allowedNode(self: Kernel, node: *const graph.format.NodeHot) bool {
        return self.profile.allowedNode(node);
    }

    pub fn restrictionPermission(self: Kernel) cost.base.Permission {
        return self.profile.permission;
    }

    pub fn edgeCost(self: Kernel, view: *const graph.reader.View, id: graph.format.EdgeId, edge: *const graph.format.EdgeHot, _: core.Direction) !cost.compiled.Cost {
        const directed = try routing.snap.candidates.DirectedEdge.read(view, id);
        if (!self.allowed(directed) or directed.class.category.use == @backingInt(graph.constants.Use.transit_connection))
            return .forbidden;
        return auto.Kernel.edgeCost(self.profile, self.tables, directed.class, edge.*, self.profile.untimedSpeed(edge.*), .{});
    }

    pub fn allowedTurn(self: Kernel, view: *const graph.reader.View, turn: core.Transition, previous: core.Label, _: core.Direction) !bool {
        const from = try view.class(turn.incoming_edge.cls.class_id);
        const to = try view.class(turn.outgoing_edge.cls.class_id);
        const access = try auto.Kernel.allowed(self.profile, from, to, .{ .row = turn.row }, .{
            .backtrack = turn.incoming_edge.cls.opp_local == turn.outgoing_edge.cls.local,
            .previous_dead_end = try turn.predecessorAtDeadEnd(view, from),
            .previous_access = previous.accessState(),
        }, .none);
        return access.allowed;
    }

    pub fn turnCost(_: Kernel, _: *const graph.reader.View, _: core.Transition, _: core.Label, _: core.Direction) !cost.compiled.Cost {
        return .{};
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const graph_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    if (args.next() != null) return error.InvalidArguments;
    var bundle = try graph.reader.Bundle.open(graph_path);
    defer bundle.close();
    const corpus = try io.Mapping.mapFile(corpus_path, .read_only);
    defer corpus.unmap();
    const a = init.arena.allocator();
    var warnings: std.ArrayList(cost.base.Warning) = .empty;
    const options = try auto.parse(a, .auto, .null, &warnings, .none);
    var cache = try auto.Cache.init(a, bundle.view.classes orelse return error.MissingClassTable, 1);
    defer cache.deinit();
    var lease = try cache.acquire(options, .none);
    defer lease.release();
    const kernel: Kernel = .{ .profile = lease.profile(), .tables = lease.tables() };
    var counted = routing.infra.arena.CountingAllocator.init(init.gpa);
    var memory = routing.infra.arena.Arena.init(counted.allocator(), .{});
    defer memory.deinit();
    var find = match.candidates.Finder.init(&bundle.view, a, .{});
    defer find.deinit();
    const Router = match.routing.Router(Kernel);
    var routes = try Router.init(counted.allocator(), &bundle.view, Router.default_scratch_bytes);
    defer routes.deinit();
    const emission = try match.emission.Model.init(match.emission.Model.default_sigma_z);
    const transition = try match.transition.Model.init(.{});
    var buffer: [16_384]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buffer);
    var lines = std.mem.tokenizeScalar(u8, corpus.bytes, '\n');
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        var fields = std.mem.tokenizeAny(u8, line, "\t ");
        const left_lat = try field(f64, &fields);
        const left_lng = try field(f64, &fields);
        const right_lat = try field(f64, &fields);
        const right_lng = try field(f64, &fields);
        const radius = try field(f32, &fields);
        const seconds = try field(f64, &fields);
        if (fields.next() != null) return error.InvalidRow;
        memory.reset();
        const measurements: match.routing.Measurements = .{
            .left = .{ .point = .init(left_lng, left_lat), .search_radius = radius, .epoch_time = 0 },
            .right = .{ .point = .init(right_lng, right_lat), .search_radius = radius, .epoch_time = seconds },
        };
        const first = try memory.allocator().dupe(match.candidates.Candidate, try find.query(measurements.left, kernel, .none));
        const second = try find.query(measurements.right, kernel, .none);
        const origin_mark = memory.mark();
        for (first, 0..) |candidate, from| {
            defer memory.rewind(origin_mark);
            var found = try routes.connect(&memory, kernel, &transition, .{ .candidate = candidate }, second, measurements, .{});
            if (row == 0 and from == 0) {
                memory.rewind(origin_mark);
                counted.resetCounts();
                found = try routes.connect(&memory, kernel, &transition, .{ .candidate = candidate }, second, measurements, .{});
                if (counted.calls() != 0) return error.TraceReallocatedAfterWarmup;
            }
            for (second, found, 0..) |target, path, to| {
                try output.interface.print("{d}\t{d}\t{d}\t{d}\t{d}", .{
                    row, from, to, emission.cost(candidate.squared_distance), emission.cost(target.squared_distance),
                });
                if (path) |p| {
                    try output.interface.print("\t{d}\t{d}\t{d}\t{d}\t", .{ p.metres, p.seconds, p.turn_cost, p.score });
                    for (p.segments, 0..) |segment, i| {
                        if (i != 0) try output.interface.writeByte(',');
                        try output.interface.print("{d}", .{@backingInt(segment.edge)});
                    }
                    try output.interface.writeByte('\n');
                } else {
                    try output.interface.writeAll("\t-1\t-1\t-1\t-1\n");
                }
            }
        }
    }
    try output.interface.flush();
}

fn field(comptime T: type, fields: *std.mem.TokenIterator(u8, .any)) !T {
    return std.fmt.parseFloat(T, fields.next() orelse return error.InvalidRow);
}
