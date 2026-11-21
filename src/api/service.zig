//! The Valhalla-compatible service: routes HTTP requests to actions and
//! answers errors exactly as upstream does.
//!
//! Ported from src/worker.cc (`ParseApi`, `serialize_error`, `to_response`)
//! and the action check in src/loki/worker.cc (Valhalla 3.9.3). Actions
//! register a handler; an action without one answers error 107 (Not
//! Implemented) until its issue lands.

const std = @import("std");
const http = @import("../server/http.zig");
const request = @import("request.zig");
const errors = @import("errors.zig");
const json_writer = @import("json_writer.zig");
const mvt = @import("../tiles/mvt.zig");
const Allocator = std.mem.Allocator;

pub const Action = request.Action;
pub const Options = request.Options;
const exclusions = @import("exclusions.zig");

/// Service limits from `service_limits` in valhalla.json (defaults as in
/// scripts/valhalla_build_config).
pub const Limits = struct {
    skadi_max_shape: usize = 750_000,
    skadi_min_resample: f32 = 10.0,
    exclusions: exclusions.Limits = .{},
    linear_costs: @import("../snap/linear.zig").Limits = .{},
    tile: TileLimits = .{},
    trace: TraceLimits = .{},
};

pub const TileLimits = struct {
    min_zoom: [8]u8 = .{ 7, 7, 8, 11, 11, 12, 13, 14 },
    max_age: []const u8 = "1800",
    allow_verbose: bool = false,
};

pub const TraceLimits = struct {
    max_distance: f32 = 200_000,
    max_gps_accuracy: f32 = 100,
    max_search_radius: f32 = 100,
    max_shape: usize = 16_000,
    max_alternates: u32 = 3,
    max_alternates_shape: usize = 100,
};

pub const TraceDefaults = struct {
    sigma_z: f32 = @import("../match/emission.zig").Model.default_sigma_z,
    gps_accuracy: f32 = 5,
    beta: f32 = 3,
    max_route_distance_factor: f32 = 5,
    max_route_time_factor: f32 = 5,
    max_search_radius: f32 = 100,
    breakage_distance: f32 = 2000,
    interpolation_distance: f32 = 10,
    search_radius: f32 = 50,
    turn_penalty_factor: f32 = 0,
};

pub const TraceSettings = struct {
    default: TraceDefaults = .{},
    customizable: []const []const u8 = &.{ "search_radius", "turn_penalty_factor", "gps_accuracy", "interpolation_distance" },

    pub fn value(self: TraceSettings, comptime name: []const u8, override: ?f32) f32 {
        if (override) |set| {
            for (self.customizable) |key| {
                if (std.mem.eql(u8, key, name)) return set;
            }
        }
        return @field(self.default, name);
    }
};

pub const Reply = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json;charset=utf-8",
};

/// An action handler writes its successful response body and returns, or
/// returns a failure that the service serializes.
pub const ActionFn = *const fn (svc: *Service, ctx: *http.Ctx, options: *Options, res: *http.Response) Allocator.Error!?errors.Failure;

/// Actions in the order upstream's default `loki.actions` lists them; this
/// order is visible in error 106's message.
pub const action_order = [_]Action{ .locate, .route, .height, .sources_to_targets, .optimized_route, .isochrone, .trace_route, .trace_attributes, .transit_available, .expansion, .centroid, .status, .tile };

pub const Service = struct {
    limits: Limits = .{},
    actions: []const Action = &action_order,
    handlers: [14]?ActionFn = @splat(null),
    /// Opaque per-service state handlers can reach (elevation tiles, graph, ...).
    state: ?*anyopaque = null,
    graph: ?*const @import("../graph/reader.zig").View = null,
    transit_coverage: ?*const @import("../graph/transit_coverage.zig").Index = null,
    tileset_last_modified: u32 = 0,
    allow_status_verbose: bool = false,
    trace: TraceSettings = .{},

    pub fn register(self: *Service, action: Action, f: ActionFn) void {
        self.handlers[@backingInt(action)] = f;
    }

    pub fn handler(self: *Service) http.Handler {
        return .{ .context = self, .handle = handleHttp };
    }

    fn handleHttp(context: *anyopaque, ctx: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        const self: *Service = @ptrCast(@alignCast(context));
        self.handle(ctx, req, res);
    }

    /// Dispatch the same request and error handling for HTTP and the one-shot CLI.
    pub fn handle(self: *Service, ctx: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        self.dispatch(ctx, req, res) catch {
            // Out of request memory: a plain 413 (the arena cap was hit).
            res.status = 413;
            res.body.clearRetainingCapacity();
        };
    }

    fn dispatch(self: *Service, ctx: *http.Ctx, req: *const http.Request, res: *http.Response) Allocator.Error!void {
        const a = res.gpa;
        if (req.method != .GET and req.method != .POST) return writeError(a, res, .{ .code = 101 }, .json);

        const pbf = if (req.header("Content-Type")) |ct| std.mem.eql(u8, ct, "application/x-protobuf") else false;
        if (pbf) return writeError(a, res, .{ .code = 107, .extra = "protobuf requests" }, .json);

        var query: std.ArrayList(request.QueryParam) = .empty;
        for (req.query) |q| try query.append(a, .{ .key = q.key, .value = q.value });
        const native_height = self.handlers[@backingInt(Action.height)] == &@import("height_action.zig").handle;
        const parsed = request.parseHttpWithin(a, req.path, query.items, req.body, native_height, ctx.deadline) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DeadlineExceeded => {
                res.status = 504;
                return;
            },
        };
        var options = switch (parsed) {
            .failure => |f| return switch (f.trace_format) {
                .json => writeError(a, res, f, .json),
                .osrm => writeError(a, res, f, .osrm),
                .pbf => writeTracePbfError(a, res, f),
            },
            .ok => |o| o,
        };
        if (std.mem.indexOfScalar(Action, self.actions, options.action) == null)
            return writeError(a, res, .{ .code = 106, .extra = try supportedList(a, self.actions) }, options.format);
        if ((options.exclude_polygons.len != 0 or options.exclude_locations.len != 0) and usesGraphCosting(options.action)) {
            const failure = exclusions.validate(a, self.limits.exclusions, options.exclude_polygons, options.exclude_locations.len, ctx.deadline) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DeadlineExceeded => {
                    res.status = 504;
                    return;
                },
            };
            if (failure) |f| return writeError(a, res, f, options.format);
        }
        const f = self.handlers[@backingInt(options.action)] orelse
            return writeError(a, res, .{ .code = 107, .extra = @tagName(options.action) }, options.format);
        if (try f(self, ctx, &options, res)) |failure| {
            res.body.clearRetainingCapacity();
            res.extra_headers.clearRetainingCapacity();
            if (options.action == .trace_attributes and options.format == .pbf) return writeTracePbfError(a, res, failure);
            return writeError(a, res, failure, options.format);
        }
        if (options.action == .tile and res.status == 200 and std.mem.eql(u8, res.content_type, mvt.mime_type)) {
            try res.addHeader("Vary: Accept-Encoding");
            if (res.body.items.len != 0 and acceptsGzip(req.header("Accept-Encoding") orelse "")) {
                const zipped = mvt.gzip(a, res.body.items, ctx.deadline) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.DeadlineExceeded => {
                        res.body.clearRetainingCapacity();
                        res.status = 504;
                        return;
                    },
                };
                res.body.deinit(a);
                res.body = .fromOwnedSlice(zipped);
                try res.addHeader("Content-Encoding: gzip");
            }
        }
    }
};

fn acceptsGzip(header: []const u8) bool {
    var encodings = std.mem.splitScalar(u8, header, ',');
    var wildcard = false;
    while (encodings.next()) |encoding| {
        var parts = std.mem.splitScalar(u8, encoding, ';');
        const token = std.mem.trim(u8, parts.first(), " \t");
        const explicit = std.ascii.eqlIgnoreCase(token, "gzip");
        if (!explicit and !std.mem.eql(u8, token, "*")) continue;
        var acceptable = true;
        if (parts.next()) |parameter| {
            var quality = std.mem.splitScalar(u8, parameter, '=');
            const key = std.mem.trim(u8, quality.first(), " \t");
            const value = std.mem.trim(u8, quality.next() orelse "", " \t");
            const q = std.fmt.parseFloat(f32, value) catch 0;
            acceptable = std.ascii.eqlIgnoreCase(key, "q") and quality.next() == null and q > 0 and q <= 1;
        }
        if (explicit) return acceptable;
        wildcard = acceptable;
    }
    return wildcard;
}

fn usesGraphCosting(action: Action) bool {
    return switch (action) {
        .route, .locate, .sources_to_targets, .optimized_route, .isochrone, .trace_route, .trace_attributes, .expansion, .centroid => true,
        else => false,
    };
}

fn supportedList(a: Allocator, actions: []const Action) Allocator.Error![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    for (actions) |act| try s.print(a, "'/{s}' ", .{@tagName(act)});
    return s.items;
}

/// `serialize_error`: JSON {error_code, error, status_code, status} (the
/// key order upstream's output has), the OSRM error body for format=osrm.
pub fn writeError(a: Allocator, res: *http.Response, failure: errors.Failure, format: request.Format) Allocator.Error!void {
    const e = errors.lookup(failure.code);
    res.status = e.http_code;
    res.content_type = "application/json;charset=utf-8";
    res.body.clearRetainingCapacity();
    if (format == .osrm) return res.body.appendSlice(a, e.osrm);
    const message = if (failure.extra.len > 0) try std.fmt.allocPrint(a, "{s}: {s}", .{ e.message, failure.extra }) else e.message;
    var w = json_writer.Writer.init(a, &res.body);
    try w.beginObject();
    try w.field("error_code", @as(u64, e.code));
    try w.field("error", message);
    try w.field("status_code", @as(u64, e.http_code));
    try w.field("status", errors.httpReason(e.http_code));
    try w.endObject();
}

fn writeTracePbfError(a: Allocator, res: *http.Response, failure: errors.Failure) Allocator.Error!void {
    const api = @import("proto/api.zig").Api;
    const e = failure.entry();
    const message = if (failure.extra.len > 0) try std.fmt.allocPrint(a, "{s}: {s}", .{ e.message, failure.extra }) else e.message;
    const level = if (e.http_code >= 500) "error" else "warn";
    const worker = switch (e.code) {
        0...199, 300...399 => "loki",
        400...500 => "thor",
        else => "odin",
    };
    const key = try std.fmt.allocPrint(a, "trace_attributes.{s}.{s}.{s}", .{ level, worker, e.statsd_key });
    const wire: api.Values = .{ .info = .{
        .errors = &.{.{ .code = e.code, .description = message }},
        .statistics = &.{.{ .key = key, .value = 1 }},
    } };
    const need = api.encodedSize(wire, io.Deadline.none) catch unreachable;
    const buffer = try a.alloc(u8, need);
    res.body = .fromOwnedSlice(api.encode(buffer, wire, io.Deadline.none) catch unreachable);
    res.status = e.http_code;
    res.content_type = "application/x-protobuf";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const io = @import("../infra/io.zig");

fn get(port: u16, raw: []const u8, buf: []u8) ![]const u8 {
    const s = try io.Stream.connect(io.Address.loopback(port));
    defer s.close();
    try s.writeAll(raw);
    var got: usize = 0;
    while (true) {
        const n = try s.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

fn body(resp: []const u8) []const u8 {
    return resp[std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4 ..];
}

test "every action path is reachable by GET and POST; errors match upstream" {
    var svc: Service = .{};
    var server = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 1 }, svc.handler());
    try server.start();
    defer server.stop();
    var buf: [8192]u8 = undefined;

    for (action_order) |act| {
        const query_json = if (act == .tile) "%7B%22tile%22%3A%7B%22x%22%3A0%2C%22y%22%3A0%2C%22z%22%3A0%7D%7D" else "%7B%7D";
        const g = try std.fmt.bufPrint(buf[4096..], "GET /{s}?json={s} HTTP/1.1\r\nConnection: close\r\n\r\n", .{ @tagName(act), query_json });
        const r = try get(server.port, g, buf[0..4096]);
        try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 501"));
        try testing.expect(std.mem.indexOf(u8, body(r), "\"error_code\":107") != null);
        const body_json = if (act == .tile) "{\"tile\":{\"x\":0,\"y\":0,\"z\":0}}" else "{}";
        const p = try std.fmt.bufPrint(buf[4096..], "POST /{s} HTTP/1.1\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ @tagName(act), body_json.len, body_json });
        try testing.expect(std.mem.startsWith(u8, try get(server.port, p, buf[0..4096]), "HTTP/1.1 501"));
    }

    const unknown = try get(server.port, "GET /nope HTTP/1.1\r\nConnection: close\r\n\r\n", &buf);
    try testing.expect(std.mem.startsWith(u8, unknown, "HTTP/1.1 404"));
    try testing.expectEqualStrings(
        "{\"error_code\":106,\"error\":\"Try any of: '/locate' '/route' '/height' '/sources_to_targets' '/optimized_route' '/isochrone' '/trace_route' '/trace_attributes' '/transit_available' '/expansion' '/centroid' '/status' '/tile' \",\"status_code\":404,\"status\":\"Not Found\"}",
        body(unknown),
    );

    const bad_json = try get(server.port, "POST /route HTTP/1.1\r\nContent-Length: 5\r\nConnection: close\r\n\r\n{nope", &buf);
    try testing.expect(std.mem.startsWith(u8, bad_json, "HTTP/1.1 400"));
    try testing.expectEqualStrings("{\"error_code\":100,\"error\":\"Failed to parse json request\",\"status_code\":400,\"status\":\"Bad Request\"}", body(bad_json));

    const method = try get(server.port, "DELETE /route HTTP/1.1\r\nConnection: close\r\n\r\n", &buf);
    try testing.expect(std.mem.startsWith(u8, method, "HTTP/1.1 405"));

    const costing = try get(server.port, "GET /route?json=%7B%22costing%22%3A%22rocket%22%7D HTTP/1.1\r\nConnection: close\r\n\r\n", &buf);
    try testing.expectEqualStrings("{\"error_code\":125,\"error\":\"No costing method found: 'rocket'\",\"status_code\":400,\"status\":\"Bad Request\"}", body(costing));
}

test "osrm format errors use the OSRM body" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var res: http.Response = .{ .gpa = testing.allocator, .body = out };
    defer res.body.deinit(testing.allocator);
    try writeError(testing.allocator, &res, .{ .code = 171 }, .osrm);
    try testing.expectEqual(@as(u16, 400), res.status);
    try testing.expect(std.mem.indexOf(u8, res.body.items, "\"code\":\"NoSegment\"") != null);
}

test "transit availability returns false without a timetable and validates locations" {
    var svc: Service = .{};
    svc.register(.transit_available, @import("transit_available_action.zig").handle);
    var server = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 1 }, svc.handler());
    try server.start();
    defer server.stop();
    var buf: [2048]u8 = undefined;
    var raw: [1024]u8 = undefined;
    const payload =
        \\{"locations":[{"lat":42.0803851,"lon":-71.0390241},{"lat":42.1,"lon":-71.1,"radius":-1},{"lat":42.1,"lon":-71.1,"radius":2.6}]}
    ;
    const post = try std.fmt.bufPrint(&raw, "POST /transit_available HTTP/1.1\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
    const response = try get(server.port, post, &buf);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try testing.expectEqualStrings(
        \\[{"input_lat":42.080385,"input_lon":-71.039024,"radius":0,"istransit":false},{"input_lat":42.1,"input_lon":-71.1,"radius":4294967295,"istransit":false},{"input_lat":42.1,"input_lon":-71.1,"radius":2,"istransit":false}]
    , body(response));
    const missing = try get(server.port, "GET /transit_available?json=%7B%7D HTTP/1.1\r\nConnection: close\r\n\r\n", &buf);
    try testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, body(missing), "\"error_code\":120") != null);
}
