//! Warm measurement correlation benchmark for the pinned Meili oracle.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const candidates = routing.match.candidates;
const auto = routing.costing.auto;

const AutoAccess = struct {
    profile: *const auto.Profile,

    pub fn allowed(self: AutoAccess, edge: routing.snap.candidates.DirectedEdge) bool {
        return self.profile.allowedCandidate(edge.class, .{}, .{}, false);
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const graph_path = args.next() orelse return error.MissingBundle;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const dump_path = args.next() orelse return error.MissingCandidateOutput;
    if (args.next() != null) return error.InvalidArguments;
    const a = init.arena.allocator();
    const data = try io.readFileAlloc(a, corpus_path, 64 * 1024 * 1024);
    var rows = std.mem.tokenizeScalar(u8, data, '\n');
    var measurements: std.ArrayList(candidates.Measurement) = .empty;
    while (rows.next()) |row| {
        var fields = std.mem.tokenizeAny(u8, row, "\t ");
        const lat = try parse(f64, &fields);
        const lng = try parse(f64, &fields);
        try measurements.append(a, .{
            .point = .init(lng, lat),
            .search_radius = try parse(f32, &fields),
            .gps_accuracy = try parse(f32, &fields),
        });
        if (fields.next() != null) return error.InvalidMeasurementRow;
    }

    var bundle = try routing.graph.reader.Bundle.open(graph_path);
    defer bundle.close();
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const profile = try auto.Model.canonicalize(try auto.parse(a, .auto, .null, &warnings, .none));
    const access: AutoAccess = .{ .profile = &profile };
    var request_memory = routing.infra.arena.Arena.init(init.gpa, .{});
    defer request_memory.deinit();
    var finder = candidates.Finder.init(&bundle.view, request_memory.allocator(), .{});
    defer finder.deinit();
    for (measurements.items) |input| _ = try finder.query(input, access, .none);

    const dump = try io.File.open(dump_path, .create_truncate);
    defer dump.close();
    var output_buffer: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &output_buffer);
    var row_buffer: [256]u8 = undefined;
    for (measurements.items, 0..) |input, i| {
        const start = io.monotonicNs();
        const found = try finder.query(input, access, .none);
        const elapsed = io.monotonicNs() - start;
        try output.interface.print("{d}\t{d}\t{d}\n", .{ i, elapsed, found.len });
        for (found) |*candidate| {
            const node = if (candidate.node) |id| @as(i64, @backingInt(id)) else -1;
            for (candidate.arcs()) |arc| {
                try dump.writeAll(try std.fmt.bufPrint(&row_buffer, "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
                    i, node, @backingInt(arc.edge), arc.percent_along, candidate.point.lat, candidate.point.lng, candidate.squared_distance,
                }));
            }
        }
    }
    try output.interface.flush();
}

fn parse(comptime T: type, fields: anytype) !T {
    return std.fmt.parseFloat(T, fields.next() orelse return error.InvalidMeasurementRow);
}
