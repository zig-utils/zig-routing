// Ported from src/loki/trace_route_action.cc and
// src/thor/trace_attributes_action.cc (Valhalla 3.9.3).
const std = @import("std");
const costing = @import("../costing/root.zig");
const graph = @import("../graph/root.zig");
const geo = @import("../geo/root.zig");
const match = @import("../match/root.zig");
const kernels = @import("../match/kernel.zig");
const snap = @import("../snap/search.zig");
const linear = @import("../costing/linear.zig");
const linear_snap = @import("../snap/linear.zig");
const http = @import("../server/http.zig");
const Arena = @import("../infra/arena.zig").Arena;
const io = @import("../infra/io.zig");
const traffic_live = @import("../traffic/live.zig");
const search = @import("../search/search.zig");
const endpoints = @import("../search/endpoints.zig");
const legs = @import("../search/legs.zig");
const tripleg = @import("../search/tripleg.zig");
const service = @import("service.zig");
const model = @import("trip.zig");
const request = @import("request.zig");
const serializer = @import("trace_serializer.zig");
const errors = @import("errors.zig");
const Attributes = @import("attributes.zig").Controller;
const Api = @import("proto/api.zig").Api;
const Warning = @import("proto/info.zig").CodedDescription.Values;
const mirror = @import("model_schema.zig");
const Allocator = std.mem.Allocator;
const View = graph.reader.View;

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *request.Options, res: *http.Response) Allocator.Error!?errors.Failure {
    const view = svc.graph orelse return .{ .code = 171 };
    return run(svc, view, ctx, options, res) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled, error.DeadlineExceeded => blk: {
            res.body.clearRetainingCapacity();
            res.status = 504;
            break :blk null;
        },
        error.NoEdgeWalk => .{ .code = 443, .extra = "edge_walk algorithm failed to find exact route match.  Try using shape_match:'walk_or_snap' to fallback to map-matching algorithm" },
        error.NoMatch, error.InvalidTraceRoute, error.InvalidTracePath, error.DisconnectedPath, error.TransitionMemoryLimit => .{ .code = 444, .extra = switch (options.trace.shape_match) {
            .map_snap => "map_snap algorithm failed to snap the shape points to the correct shape.",
            else => "walk_or_snap algorithm failed to snap the shape points to the correct shape.",
        } },
        error.InvalidMeasurement, error.InvalidSigmaZ => .{ .code = 424 },
        error.InvalidInterpolationDistance, error.InvalidTransitionOption => .{ .code = 158 },
        else => .{ .code = 171 },
    };
}

fn run(svc: *const service.Service, view: *const View, ctx: *http.Ctx, options: *request.Options, res: *http.Response) !?errors.Failure {
    const a = ctx.arena.allocator();
    const control: search.Control = .{ .deadline = ctx.deadline };
    if (try validate(a, options, svc.limits.trace, svc.trace.default.breakage_distance, control)) |failure| return failure;
    const resolved: linear_snap.Resolved = if (options.linear_cost_factors.len == 0)
        .{}
    else blk: {
        var local_scratch = Arena.init(ctx.arena.backing, ctx.arena.options);
        defer local_scratch.deinit();
        const scratch = ctx.scratch orelse &local_scratch;
        switch (try linear_snap.resolve(view, a, scratch, options.linear_cost_factors, svc.limits.linear_costs, control)) {
            .ok => |features| break :blk features,
            .failure => |failure| return failure,
        }
    };
    const features: ?*const linear.Table = if (options.linear_cost_factors.len == 0) null else &resolved.costs;
    const attrs = try options.tripAttributes(true, control.deadline);
    const values = options.costing_options orelse .null;
    const object = if (values == .object) values.object.get(@tagName(options.costing)) orelse .null else .null;
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    const trip = switch (options.costing) {
        .auto, .bus, .taxi, .auto_pedestrian => |mode| try motorTrip(
            costing.auto,
            view,
            ctx,
            options,
            attrs,
            svc.trace,
            try costing.auto.parse(a, switch (mode) {
                .bus => .bus,
                .taxi => .taxi,
                else => .auto,
            }, object, &warnings, control.deadline),
            if (mode == .bus) .kAutoBus else .kCar,
            features,
            control,
        ),
        .truck => try motorTrip(costing.truck, view, ctx, options, attrs, svc.trace, try costing.truck.parse(a, object, &warnings, control.deadline), .kTruck, features, control),
        .motorcycle, .motor_scooter => |mode| try motorTrip(costing.motorcycle, view, ctx, options, attrs, svc.trace, try costing.motorcycle.parse(a, if (mode == .motorcycle) .motorcycle else .motor_scooter, object, &warnings, control.deadline), if (mode == .motorcycle) .kMotorcycle else .kMotorScooter, features, control),
        .bicycle => blk: {
            var raw = try costing.bicycle.parse(a, object, &warnings, control.deadline);
            if (features) |costs| raw.may_allow_edges = costs.has_allow;
            const profile = try costing.bicycle.Model.canonicalize(raw);
            const tables = try compile(costing.bicycle, view, a, profile, control);
            const kernel: kernels.Active(costing.bicycle) = .{ .profile = &profile, .tables = &tables, .features = features };
            const travel: model.BicycleType = @fromBackingInt(@backingInt(profile.bicycle_type));
            break :blk try matchTrip(view, ctx, options, attrs, svc.trace, kernel, .{ .bicycle = travel }, control);
        },
        .pedestrian, .bikeshare, .transit => |mode| blk: {
            const walk_opts = if (values == .object) values.object.get("pedestrian") orelse .null else .null;
            var raw = try costing.pedestrian.parse(a, walk_opts, &warnings, control.deadline);
            if (features) |costs| raw.may_allow_edges = costs.has_allow;
            const profile = try costing.pedestrian.Model.canonicalize(raw);
            const tables = try compile(costing.pedestrian, view, a, profile, control);
            const kernel: kernels.Active(costing.pedestrian) = .{ .profile = &profile, .tables = &tables, .bikeshare = mode == .bikeshare, .features = features };
            const travel: model.PedestrianType = @fromBackingInt(@backingInt(profile.transport));
            break :blk try matchTrip(view, ctx, options, attrs, svc.trace, kernel, .{ .pedestrian = travel }, control);
        },
        .multimodal => return .{ .code = 140, .extra = "trace_attributes" },
        .none => unreachable,
    };
    const standard_warnings = options.warnings.items.len + warnings.items.len;
    const failed_lines = resolved.failed.len != 0;
    const response_warnings = try a.alloc(Warning, standard_warnings + @intFromBool(failed_lines));
    for (options.warnings.items, response_warnings[0..options.warnings.items.len]) |code, *out| {
        try control.check();
        out.* = .{ .code = code, .description = errors.warningText(code) orelse "" };
    }
    for (warnings.items, response_warnings[options.warnings.items.len..standard_warnings]) |warning, *out| {
        try control.check();
        out.* = .{ .code = costing.base.Warning.code, .description = try warning.description(a) };
    }
    if (failed_lines) response_warnings[standard_warnings] = .{
        .code = 216,
        .description = try std.fmt.allocPrint(a, "{s}{s}", .{ errors.warningText(216).?, resolved.failed }),
    };
    if (options.format == .pbf) {
        const wire: Api.Values = .{
            .trip = try mirror.values(a, trip, control.deadline),
            .info = if (response_warnings.len != 0) .{ .warnings = response_warnings } else null,
        };
        const body = try a.alloc(u8, try Api.encodedSize(wire, control.deadline));
        const encoded = try Api.encode(body, wire, control.deadline);
        res.body = .fromOwnedSlice(encoded);
        res.content_type = "application/x-protobuf";
    } else {
        try serializer.json(a, &res.body, trip, options, attrs, response_warnings, control.deadline);
    }
    return null;
}

fn motorTrip(comptime m: type, view: *const View, ctx: *http.Ctx, options: *const request.Options, attrs: Attributes, settings: service.TraceSettings, options_raw: m.Model.Options, vehicle: model.VehicleType, features: ?*const linear.Table, control: search.Control) !model.Trip {
    const a = ctx.arena.allocator();
    var raw = options_raw;
    if (features) |costs| raw.may_allow_edges = costs.has_allow;
    const profile = try m.Model.canonicalize(raw);
    const tables = try compile(m, view, a, profile, control);
    const kernel: kernels.Motor(m) = .{
        .profile = &profile,
        .tables = &tables,
        .arena = a,
        .control = control,
        .features = features,
        .traffic = .{
            .observations = view.speedOverlays(@intCast(@max(0, io.wallSeconds())), traffic_live.default_max_age_seconds),
            .forecasts = view.predicted_traffic,
        },
    };
    return matchTrip(view, ctx, options, attrs, settings, kernel, .{ .drive = vehicle }, control);
}

fn compile(comptime m: type, view: *const View, a: Allocator, profile: m.Profile, control: search.Control) !costing.compiled.Compiled {
    const classes = view.classes orelse return error.MissingClassTable;
    const factors = try a.alloc(f32, classes.len);
    return costing.compiled.compileInto(m.Model, profile, classes, factors, control.deadline);
}

fn validate(a: Allocator, options: *request.Options, limits: service.TraceLimits, default_breakage: f32, control: search.Control) !?errors.Failure {
    if (options.costing == .none) return .{ .code = 124 };
    const size = options.shape.len;
    if (size == 0) return .{ .code = 114 };
    if (size == 1) return .{ .code = 123 };
    const max_shape = limits.max_shape;
    if (size > max_shape)
        return .{ .code = 153, .extra = try std.fmt.allocPrint(a, "({d}). The limit is {d}", .{ size, max_shape }) };
    const max_distance = limits.max_distance * @as(f32, if (options.trace.shape_match == .edge_walk) 5 else 1);
    const breakage = options.trace.breakage_distance orelse default_breakage;
    var crow_distance: f32 = 0;
    var can_match = false;
    for (options.shape[0 .. size - 1], options.shape[1..], 0..) |start, end, i| {
        if (i % 256 == 0) try control.check();
        const from = geo.PointLL.init(start.lng, start.lat);
        const to = geo.PointLL.init(end.lng, end.lat);
        const distance: f32 = @floatCast(from.distance(to));
        crow_distance += distance;
        can_match = can_match or distance <= breakage;
        if (crow_distance > max_distance)
            return .{ .code = 154, .extra = try std.fmt.allocPrint(a, "{d} meters", .{@trunc(max_distance)}) };
    }
    if (!can_match) return .{ .code = 172, .extra = try std.fmt.allocPrint(a, "{d} meters", .{@trunc(@max(0, breakage))}) };
    options.trace.alternates = @min(options.trace.alternates, @min(limits.max_alternates, std.math.maxInt(u32) - 1));
    const max_alternate_shape = limits.max_alternates_shape;
    if (options.trace.shape_match == .map_snap and options.trace.alternates != 0 and size > max_alternate_shape)
        return .{ .code = 153, .extra = try std.fmt.allocPrint(a, "({d}). The best paths shape limit is {d}", .{ size, max_alternate_shape }) };
    const gps = options.trace.gps_accuracy orelse 0;
    const radius = options.trace.search_radius orelse 0;
    const turn = options.trace.turn_penalty_factor orelse 0;
    if (!(gps >= 0 and gps <= limits.max_gps_accuracy and radius >= 0 and radius <= limits.max_search_radius and turn >= 0))
        return .{ .code = 158 };
    return null;
}

fn matchTrip(view: *const View, ctx: *http.Ctx, options: *const request.Options, attrs: Attributes, settings: service.TraceSettings, kernel: anytype, travel: tripleg.Travel, control: search.Control) !model.Trip {
    const a = ctx.arena.allocator();
    const trace = options.trace;
    const len = options.shape.len;
    const measurements = try a.alloc(match.candidates.Measurement, len);
    const accuracy = settings.value("gps_accuracy", trace.gps_accuracy);
    const radius = settings.value("search_radius", trace.search_radius);
    for (options.shape, measurements, 0..) |location, *measurement, i| {
        if (i % 256 == 0) try control.check();
        measurement.* = .{
            .point = .init(location.lng, location.lat),
            .gps_accuracy = if (location.accuracy) |m| @floatFromInt(m) else accuracy,
            .search_radius = if (location.radius) |m| @floatFromInt(m) else radius,
            .epoch_time = location.time,
            .stop_type = location.type,
        };
    }
    const origin = try snap.search(view, a, match.route.endpoint(options.shape[0]), .{}, kernel, control.deadline);
    const target = try snap.search(view, a, match.route.endpoint(options.shape[len - 1]), .{}, kernel, control.deadline);
    if (origin.edges.len == 0 or target.edges.len == 0) return error.MissingTraceCorrelation;

    // Transit costing starts at pedestrian correlations for an exact walk.
    // Street transition searches cannot traverse scheduled transit rides.
    const transit_walk = options.costing == .transit;
    if (transit_walk and trace.shape_match == .map_snap) return error.NoMatch;

    // Router searches rewind the result arena between candidate columns.
    // Their retained pages and the shape cache have a separate lifetime.
    var local_scratch = Arena.init(ctx.arena.backing, ctx.arena.options);
    defer local_scratch.deinit();
    const workspace = (ctx.scratch orelse &local_scratch).allocator();
    var finder = match.candidates.Finder.init(view, workspace, .{ .max_search_radius = settings.default.max_search_radius });
    defer finder.deinit();
    const Router = match.routing.Router(@TypeOf(kernel));
    var router = try Router.init(workspace, view, Router.default_scratch_bytes);
    defer router.deinit();
    const emission = try match.emission.Model.init(settings.default.sigma_z);
    const transition = try match.transition.Model.init(.{
        .beta = settings.default.beta,
        .breakage_distance_m = settings.value("breakage_distance", trace.breakage_distance),
        .max_route_distance_factor = settings.default.max_route_distance_factor,
        .max_route_time_factor = settings.default.max_route_time_factor,
        .turn_penalty_factor = settings.value("turn_penalty_factor", trace.turn_penalty_factor),
    });
    const results = match.route.resolve(ctx.arena, &finder, &router, kernel, measurements, emission, transition, .{
        .shape_match = if (transit_walk) .edge_walk else trace.shape_match,
        .use_timestamps = trace.use_timestamps,
        .require_timestamps = false,
        .best_paths = trace.alternates + 1,
        .interpolation_distance = settings.value("interpolation_distance", trace.interpolation_distance),
        .correlated = .{ .origin = origin.edges, .target = target.edges },
        .timing = .{ .invariant = options.date_time_type == .invariant },
        .start_clock = .{
            .date = options.shape[0].date_time orelse if (options.date_time_type != .arrive_by) options.date_time else null,
            .timestamp = options.shape[0].time,
            .now = io.wallSeconds(),
        },
    }, control) catch |err| {
        if (err == error.NoEdgeWalk and transit_walk and trace.shape_match == .walk_or_snap) return error.NoMatch;
        return err;
    };
    if (results.len == 0 or results[0].segments.len == 0) return error.NoMatch;
    const routes = try a.alloc(model.TripRoute, results.len);
    const best: f32 = @floatCast(results[0].score);
    for (results, routes, 0..) |result, *out, index| {
        try control.check();
        if (result.segments.len == 0) return error.NoMatch;
        out.* = try project(a, view, result, attrs, travel, if (index == 0) 1 else best / @as(f32, @floatCast(result.score)), options, control);
    }
    return .{ .routes = routes };
}

fn project(a: Allocator, view: *const View, result: match.route.Result, attrs: Attributes, travel: tripleg.Travel, confidence: f32, options: *const request.Options, control: search.Control) !model.TripRoute {
    if (result.legs.len == 0) return error.InvalidTraceRoute;
    const n = result.segments.len;
    const walked = result.segments[0].shape_end != null;
    const path = try a.alloc(endpoints.Segment, n);
    const steps = try a.alloc(legs.Recost.Step, n);
    const cuts = try a.alloc(legs.ShapeCut, n);
    const points = try a.alloc(model.MatchedPoint, if (walked) 0 else result.matches.len);
    const indices = if (!walked and attrs.has(.@"matched.edge_index")) try match.route.segmentIndices(a, result, control) else &.{};
    for (points, result.matches[0..points.len], 0..) |*point, m, i| {
        if (i % 256 == 0) try control.check();
        point.* = .{
            .type = if (attrs.has(.@"matched.type")) switch (m.kind) {
                .matched => .kMatched,
                .interpolated => .kInterpolated,
                .unmatched => .kUnmatched,
            } else .kUnmatched,
            .edge_index = if (indices.len != 0 and m.edge != null) indices[i] else null,
            .begins_discontinuity = attrs.has(.@"matched.begin_route_discontinuity") and m.begins_discontinuity,
            .ends_discontinuity = attrs.has(.@"matched.end_route_discontinuity") and m.ends_discontinuity,
            .distance_along_edge = if (attrs.has(.@"matched.distance_along_edge") and m.kind != .unmatched) m.fraction else null,
            .distance_from_trace_point = if (attrs.has(.@"matched.distance_from_trace_point") and m.kind != .unmatched) m.distance else null,
            .latlng = if (attrs.has(.@"matched.point")) .{ .lat = m.point.lat, .lng = m.point.lng } else null,
        };
    }
    for (result.segments, path, cuts, 0..) |segment, *edge, *cut, i| {
        try control.check();
        edge.* = segment.path;
        cut.* = .{ .disconnected = i != 0 and result.segments[i - 1].discontinuity };
        if (i == 0 or cut.disconnected)
            if (segment.first_match) |first| {
                cut.start = result.matches[first].point;
            };
        if (i + 1 == n or segment.discontinuity)
            if (segment.last_match) |last| {
                cut.end = result.matches[last].point;
            };
    }

    var offset: usize = 0;
    for (result.legs) |leg| {
        try control.check();
        if (leg.steps.len > n - offset) return error.InvalidTraceRoute;
        @memcpy(steps[offset..][0..leg.steps.len], leg.steps);
        offset += leg.steps.len;
    }
    if (offset != n) return error.InvalidTraceRoute;
    const first = result.legs[0].first_match;
    const last = result.legs[result.legs.len - 1].last_match;
    const geometry = try legs.buildTrace(a, view, path, steps, cuts, first, last, control);
    const built = try a.alloc(model.TripLeg, 1);
    built[0] = try tripleg.build(a, view, .{
        .segments = path,
        .geometry = &geometry,
        .attributes = attrs,
        .travel = travel,
        .trace = true,
        .algorithms = if (walked) &.{"edge_walk"} else &.{"map_snap"},
    }, control);
    built[0].location = try tripleg.traceEndpoints(a, &geometry, options.shape, path, result.matches[first].distance, result.matches[last].distance);
    return .{
        .legs = built,
        .matched_points = points,
        .confidence_score = if (attrs.has(.confidence_score)) confidence else 0,
        .raw_score = if (attrs.has(.raw_score)) @floatCast(result.score) else 0,
    };
}
