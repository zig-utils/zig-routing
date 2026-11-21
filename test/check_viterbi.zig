//! Compare native Meili candidate sequences with the pinned Valhalla probe.
const std = @import("std");
const routing = @import("routing");
const auto = routing.costing.auto;
const memory = routing.infra.arena;
const io = routing.infra.io;
const match = routing.match;
const viterbi = match.viterbi;
const Kernel = @import("check_trace_transitions.zig").Kernel;
const Tokens = std.mem.TokenIterator(u8, .any);

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const bundle_name = args.next() orelse return error.MissingBundle;
    const corpus_name = args.next() orelse return error.MissingCorpus;
    const segments_only = if (args.next()) |mode| mode: {
        if (!std.mem.eql(u8, mode, "--segments")) return error.InvalidArguments;
        break :mode true;
    } else false;
    if (args.next() != null) return error.InvalidArguments;
    var bundle = try routing.graph.reader.Bundle.open(bundle_name);
    defer bundle.close();
    const corpus = try io.Mapping.mapFile(corpus_name, .read_only);
    defer corpus.unmap();
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    defer warnings.deinit(init.gpa);
    const options = try auto.parse(init.gpa, .auto, .null, &warnings, .none);
    var cache = try auto.Cache.init(init.gpa, bundle.view.classes orelse return error.MissingClassTable, 1);
    defer cache.deinit();
    var lease = try cache.acquire(options, .none);
    defer lease.release();
    const kernel: Kernel = .{ .profile = lease.profile(), .tables = lease.tables() };
    var finder = match.candidates.Finder.init(&bundle.view, init.gpa, .{});
    defer finder.deinit();
    const Router = match.routing.Router(Kernel);
    var router = try Router.init(init.gpa, &bundle.view, Router.default_scratch_bytes);
    defer router.deinit();
    var arena = memory.Arena.init(init.gpa, .{});
    defer arena.deinit();
    const observations = try match.emission.Model.init(match.emission.Model.default_sigma_z);
    const movements = try match.transition.Model.init(.{});

    var tokens = std.mem.tokenizeAny(u8, corpus.bytes, "\t \r\n");
    var bytes: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &bytes);
    var case: usize = 0;
    while (tokens.next()) |token| : (case += 1) {
        const k = try std.fmt.parseInt(u32, token, 10);
        const count = try std.fmt.parseInt(u32, try field(&tokens), 10);
        arena.reset();
        const measurements = try arena.allocator().alloc(match.candidates.Measurement, count);
        for (measurements) |*measurement| {
            const lat = try std.fmt.parseFloat(f64, try field(&tokens));
            const lon = try std.fmt.parseFloat(f64, try field(&tokens));
            const epoch = try std.fmt.parseFloat(f64, try field(&tokens));
            measurement.* = .{ .point = .init(lon, lat), .search_radius = 35, .epoch_time = epoch };
        }
        if (segments_only) {
            const results = try match.route.resolve(&arena, &finder, &router, kernel, measurements, observations, movements, .{ .shape_match = .map_snap }, .{});
            try output.interface.print("{d}", .{case});
            for (results[0].segments) |segment| {
                try output.interface.print("\t{d},{d},{d},{d}", .{
                    @backingInt(segment.path.edge), segment.path.begin, segment.path.end, @intFromBool(segment.discontinuity),
                });
            }
            try output.interface.writeByte('\n');
            continue;
        }
        var states: viterbi.StateContainer = .{};
        for (measurements) |measurement| {
            _ = try states.append(arena.allocator(), measurement, try finder.query(measurement, kernel, .none));
        }
        var search = try states.startSearch(&arena, .{});
        var model = try viterbi.RoutingCosts(Kernel).init(&arena, &states, &router, kernel, observations, movements, .{});
        const paths = try search.bestPaths(&arena, &model, k, .{});
        for (paths, 0..) |path, rank| {
            try output.interface.print("{d}\t{d}\t{d}\t{d}", .{ case, rank, @intFromBool(path.broken), path.cost });
            for (path.states) |state| {
                if (state.valid()) {
                    try output.interface.print("\t{d}", .{state.id});
                } else try output.interface.writeAll("\t-1");
            }
            try output.interface.writeByte('\n');
        }
    }
    try output.interface.flush();
}

fn field(tokens: *Tokens) ![]const u8 {
    return tokens.next() orelse error.IncompleteTrace;
}
