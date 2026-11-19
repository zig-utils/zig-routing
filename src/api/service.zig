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
const Allocator = std.mem.Allocator;

pub const Action = request.Action;
pub const Options = request.Options;

/// Service limits from `service_limits` in valhalla.json (defaults as in
/// scripts/valhalla_build_config).
pub const Limits = struct {
    skadi_max_shape: usize = 750_000,
    skadi_min_resample: f32 = 10.0,
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
        const parsed = try request.parseHttp(a, req.path, query.items, req.body);
        var options = switch (parsed) {
            .failure => |f| return writeError(a, res, f, .json),
            .ok => |o| o,
        };
        if (std.mem.indexOfScalar(Action, self.actions, options.action) == null)
            return writeError(a, res, .{ .code = 106, .extra = try supportedList(a, self.actions) }, options.format);
        const f = self.handlers[@backingInt(options.action)] orelse
            return writeError(a, res, .{ .code = 107, .extra = @tagName(options.action) }, options.format);
        if (try f(self, ctx, &options, res)) |failure| {
            res.body.clearRetainingCapacity();
            res.extra_headers.clearRetainingCapacity();
            return writeError(a, res, failure, options.format);
        }
    }
};

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
        const g = try std.fmt.bufPrint(buf[4096..], "GET /{s}?json=%7B%7D HTTP/1.1\r\nConnection: close\r\n\r\n", .{@tagName(act)});
        const r = try get(server.port, g, buf[0..4096]);
        try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 501"));
        try testing.expect(std.mem.indexOf(u8, body(r), "\"error_code\":107") != null);
        const p = try std.fmt.bufPrint(buf[4096..], "POST /{s} HTTP/1.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}", .{@tagName(act)});
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
