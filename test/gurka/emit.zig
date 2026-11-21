//! Emit a Gurka fixture for the Valhalla oracle's tile builder.

const std = @import("std");
const routing = @import("routing");
const examples = @import("examples.zig");
const gurka = @import("gurka.zig");
const lane_examples = @import("lane_examples.zig");
const narrative = @import("narrative_examples.zig");
const pbf = @import("pbf.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: zig build gurka-pbf -- FILE.osm.pbf [FIXTURE [PROFILES.jsonl]]\n", .{});
        return error.MissingOutputPath;
    };
    const arena = init.arena.allocator();
    const scenario = args.next();
    const metadata: ?pbf.Metadata = if (scenario) |name| blk: {
        if (std.mem.eql(u8, name, "dataset-sparse")) break :blk .sparse;
        if (std.mem.eql(u8, name, "dataset-dense")) break :blk .dense;
        if (std.mem.eql(u8, name, "dataset-absent")) break :blk .absent;
        break :blk null;
    } else null;
    const lane_example = if (scenario) |name| try lane_examples.find(arena, name) else null;
    const fixture = if (lane_example) |example| example.map else if (scenario) |name| blk: {
        if (metadata != null) break :blk try examples.datasetMetadata(arena);
        if (std.mem.eql(u8, name, "guidance-views")) break :blk try examples.guidanceViews(arena);
        if (std.mem.eql(u8, name, "motor-vehicle")) break :blk try examples.motorVehicle(arena);
        if (std.mem.eql(u8, name, "admin-boundaries")) break :blk try examples.adminBoundaries(arena);
        if (std.mem.eql(u8, name, "country-access")) break :blk try examples.countryAccess(arena);
        if (std.mem.eql(u8, name, "simple-turns")) break :blk try examples.simpleTurns(arena);
        if (std.mem.eql(u8, name, "only-turns")) break :blk try examples.onlyTurns(arena, .many_neighbours);
        if (std.mem.eql(u8, name, "multi-via-turns")) break :blk try examples.multiViaTurns(arena);
        if (std.mem.eql(u8, name, "timed-access")) break :blk try examples.conditionalAccess(arena);
        if (std.mem.eql(u8, name, "timed-access-detour")) break :blk try examples.timedAccessDetour(arena);
        if (std.mem.eql(u8, name, "access-regions")) break :blk try examples.accessRegions(arena);
        if (std.mem.eql(u8, name, "signs")) break :blk try examples.signs(arena);
        if (std.mem.eql(u8, name, "turn-lanes")) break :blk try examples.turnLanes(arena);
        if (std.mem.eql(u8, name, "split-lanes")) break :blk try narrative.splitLanes(arena);
        if (std.mem.eql(u8, name, "indoor")) break :blk try narrative.indoor(arena);
        if (std.mem.eql(u8, name, "level-change")) break :blk try narrative.levelChange(arena);
        if (std.mem.eql(u8, name, "ferry")) break :blk try narrative.ferry(arena);
        if (std.mem.eql(u8, name, "street-linguistics")) break :blk try examples.streetLinguistics(arena);
        if (std.mem.eql(u8, name, "turn-names-us")) break :blk try examples.turnNames(arena, true);
        if (std.mem.eql(u8, name, "turn-names-ca")) break :blk try examples.turnNames(arena, false);
        if (std.mem.eql(u8, name, "driving-side")) break :blk try examples.drivingSide(arena);
        if (std.meta.stringToEnum(examples.LinkCase, name)) |link_case| break :blk try examples.links(arena, link_case);
        if (std.mem.eql(u8, name, "timed-turns")) break :blk try examples.timedTurns(arena, false);
        if (std.mem.eql(u8, name, "probable-turns")) break :blk try examples.probableTurns(arena);
        return error.UnknownFixture;
    } else try examples.intersection(arena);
    if (scenario) |name| {
        if (args.next()) |requests| {
            if (lane_example) |example| {
                try narrative.corpus(arena, fixture, requests, "auto", example.routes);
            } else if (metadata != null) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{.{ .from = "A", .to = "C" }});
            } else if (std.mem.eql(u8, name, "guidance-views")) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{.{ .from = "A", .to = "G" }});
            } else if (std.mem.eql(u8, name, "multi-via-turns")) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{
                    .{ .from = "A", .to = "E", .date_time = .{ .type = 1, .value = "2026-11-16T12:00" } },
                    .{ .from = "A", .to = "E", .date_time = .{ .type = 2, .value = "2026-11-16T12:00" } },
                    .{ .from = "M", .to = "E", .date_time = .{ .type = 1, .value = "2026-11-16T12:00" } },
                    .{ .from = "M", .to = "E", .date_time = .{ .type = 2, .value = "2026-11-16T12:00" } },
                });
            } else if (std.mem.eql(u8, name, "timed-turns")) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{
                    .{ .from = "A", .to = "F", .date_time = .{ .type = 1, .value = "2026-11-16T12:00" } },
                    .{ .from = "A", .to = "F", .date_time = .{ .type = 2, .value = "2026-11-16T12:00" } },
                    .{ .from = "A", .to = "F", .date_time = .{ .type = 1, .value = "2026-11-16T23:00" } },
                    .{ .from = "A", .to = "F", .date_time = .{ .type = 2, .value = "2026-11-16T23:00" } },
                });
            } else if (std.mem.eql(u8, name, "timed-access")) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{
                    .{ .from = "R", .to = "U", .date_time = .{ .type = 1, .value = "2026-03-09T06:00" } },
                    .{ .from = "R", .to = "U", .date_time = .{ .type = 2, .value = "2026-03-09T06:00" } },
                    .{ .from = "R", .to = "U", .date_time = .{ .type = 1, .value = "2026-01-12T08:00" } },
                    .{ .from = "R", .to = "U", .date_time = .{ .type = 2, .value = "2026-01-12T08:00" } },
                });
            } else if (std.mem.eql(u8, name, "timed-access-detour")) {
                try narrative.corpus(arena, fixture, requests, "auto", &.{
                    .{ .from = "A", .to = "D", .date_time = .{ .type = 1, .value = "2026-11-16T12:00" } },
                    .{ .from = "A", .to = "D", .date_time = .{ .type = 2, .value = "2026-11-16T12:00" } },
                    .{ .from = "A", .to = "D", .date_time = .{ .type = 1, .value = "2026-11-16T23:00" } },
                    .{ .from = "A", .to = "D", .date_time = .{ .type = 2, .value = "2026-11-16T23:00" } },
                });
            } else if (std.mem.eql(u8, name, "access-regions")) {
                try accessProfiles(arena, fixture, requests);
            } else if (std.mem.eql(u8, name, "indoor")) {
                try narrative.corpus(arena, fixture, requests, "pedestrian", narrative.indoor_routes);
            } else if (std.mem.eql(u8, name, "turn-lanes")) {
                try narrative.corpus(arena, fixture, requests, "auto", narrative.lane_routes);
            } else if (std.mem.eql(u8, name, "split-lanes")) {
                try narrative.corpus(arena, fixture, requests, "auto", narrative.split_routes);
            } else if (std.mem.eql(u8, name, "level-change")) {
                try narrative.corpus(arena, fixture, requests, "pedestrian", narrative.level_change_routes);
            } else if (std.mem.eql(u8, name, "ferry")) {
                try narrative.corpus(arena, fixture, requests, "auto", narrative.ferry_routes);
            } else return error.ExtraArguments;
        }
    }
    if (args.next() != null) return error.ExtraArguments;
    if (metadata) |mode| {
        try routing.infra.io.writeFile(path, try pbf.encodeWithMetadata(arena, fixture.osm, mode));
    } else {
        try fixture.osm.writePbf(init.gpa, path);
    }
}

fn accessProfiles(arena: std.mem.Allocator, fixture: gurka.Map, path: []const u8) !void {
    const Location = struct { lat: f64, lon: f64, minimum_reachability: u32 = 0 };
    const Request = struct {
        locations: [2]Location,
        costing: []const u8 = "auto",
        directions_type: []const u8 = "none",
        costing_options: struct { auto: Options },
    };
    const cases = [_]struct { from: []const u8, to: []const u8, penalty: f32 }{
        .{ .from = "AB", .to = "EF", .penalty = 0 },
        .{ .from = "FE", .to = "BA", .penalty = 0 },
        .{ .from = "AB", .to = "EF", .penalty = 600 },
        .{ .from = "AB", .to = "CD", .penalty = 600 },
        .{ .from = "DC", .to = "BA", .penalty = 600 },
        .{ .from = "KL", .to = "MN", .penalty = 600 },
        .{ .from = "NM", .to = "LK", .penalty = 600 },
        .{ .from = "KL", .to = "LP", .penalty = 600 },
        .{ .from = "PL", .to = "LK", .penalty = 600 },
    };
    var lines: std.ArrayList(u8) = .empty;
    for (cases) |case| {
        var endpoints: [2]Location = undefined;
        for ([_][]const u8{ case.from, case.to }, &endpoints) |edge, *endpoint| {
            const first = fixture.layout.get(edge[0..1]).?;
            const last = fixture.layout.get(edge[1..2]).?;
            endpoint.* = .{ .lat = (first.lat + last.lat) * 0.5, .lon = (first.lng + last.lng) * 0.5 };
        }
        const options: Options = .{ .destination_only_penalty = case.penalty };
        const request: Request = .{ .locations = endpoints, .costing_options = .{ .auto = options } };
        const line = try std.json.Stringify.valueAlloc(arena, .{ .mode = "auto", .options = options, .paths = .{request} }, .{});
        try lines.appendSlice(arena, line);
        try lines.append(arena, '\n');
    }
    try routing.infra.io.writeFile(path, lines.items);
}

const Options = struct { destination_only_penalty: f32 };
