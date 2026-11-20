//! Startup configuration compatible with Valhalla 3.9.3.

const std = @import("std");
const zig_config = @import("zig_config");
const io = @import("io.zig");
const http = @import("../server/http.zig");
const service = @import("../api/service.zig");

pub const Diagnostic = zig_config.Diagnostic;
pub const env_prefix = "ZR";

pub const Config = struct {
    service_limits: ServiceLimits = .{},
    httpd: struct { service: HttpService = .{} } = .{},
    additional_data: struct { elevation: ?[]const u8 = null } = .{},
    loki: struct { actions: []const service.Action = &service.action_order } = .{},
    mjolnir: Mjolnir = .{},
    zig_routing: ZigRouting = .{},

    pub const Mjolnir = struct {
        reclassify_links: ?bool = null,
        default_speeds_config: ?[]const u8 = null,
        data_processing: struct {
            infer_turn_channels: ?bool = null,
            infer_internal_intersections: ?bool = null,
            apply_country_overrides: ?bool = null,
        } = .{},
    };

    pub const ServiceLimits = struct {
        max_exclude_locations: usize = 50,
        max_exclude_polygons_length: f32 = 10_000,
        max_exclude_polygons_vertices: usize = 100,
        skadi: struct {
            max_shape: usize = (service.Limits{}).skadi_max_shape,
            min_resample: f32 = (service.Limits{}).skadi_min_resample,
        } = .{},
    };

    pub const HttpService = struct {
        listen: []const u8 = "tcp://*:8002",
        timeout_seconds: i64 = -1,
        drain_seconds: u32 = 28,
    };

    pub const Build = struct {
        inputs: []const []const u8 = &.{},
        dem_dir: ?[]const u8 = null,
        timezone_geojson: ?[]const u8 = null,
        timezone_rules: ?[]const u8 = null,
        work_dir: ?[]const u8 = null,
        bundle_path: ?[]const u8 = null,
        threads: ?usize = null,
        pbf_buffer_bytes: ?usize = null,
    };

    pub const ZigRouting = struct {
        build: Build = .{},
        bundle_path: ?[]const u8 = null,
        mlock_hot: bool = false,
        threads: usize = 0,
        request_memory_bytes: usize = (http.Config{}).arena_cap_bytes,
        max_header_bytes: usize = (http.Config{}).max_header_bytes,
        max_body_bytes: usize = (http.Config{}).max_body_bytes,
        metric_cache_bytes: ?usize = null,
    };

    pub fn httpConfig(self: Config) !http.Config {
        const httpd = self.httpd.service;
        if (httpd.timeout_seconds < -1) return error.InvalidRequestTimeout;
        const timeout_ms = if (httpd.timeout_seconds == -1) null else std.math.mul(u64, @intCast(httpd.timeout_seconds), std.time.ms_per_s) catch return error.InvalidRequestTimeout;
        return .{
            .address = try parseListen(httpd.listen),
            .threads = self.zig_routing.threads,
            .request_timeout_ms = timeout_ms,
            .drain_timeout_ms = @as(u64, httpd.drain_seconds) * std.time.ms_per_s,
            .arena_cap_bytes = self.zig_routing.request_memory_bytes,
            .max_header_bytes = self.zig_routing.max_header_bytes,
            .max_body_bytes = self.zig_routing.max_body_bytes,
        };
    }

    pub fn serviceConfig(self: Config) service.Service {
        return .{
            .limits = .{
                .skadi_max_shape = self.service_limits.skadi.max_shape,
                .skadi_min_resample = self.service_limits.skadi.min_resample,
                .exclusions = .{
                    .max_exclude_locations = self.service_limits.max_exclude_locations,
                    .max_exclude_polygons_length = self.service_limits.max_exclude_polygons_length,
                    .max_exclude_polygons_vertices = self.service_limits.max_exclude_polygons_vertices,
                },
            },
            .actions = self.loki.actions,
        };
    }
};

pub const Loaded = struct {
    config: Config,
    ignored_keys: []const []const u8,
};

/// Allocates config data and diagnostics' key list in the caller's startup arena.
pub fn load(arena: std.mem.Allocator, path: ?[]const u8, env: *const std.process.Environ.Map, diagnostic: *Diagnostic) !Loaded {
    const bytes = if (path) |file| try io.readFileAlloc(arena, file, 8 * 1024 * 1024) else "{}";
    return decode(arena, bytes, path orelse "", env, diagnostic);
}

pub fn decode(arena: std.mem.Allocator, bytes: []const u8, path: []const u8, env: ?*const std.process.Environ.Map, diagnostic: ?*Diagnostic) !Loaded {
    var ignored: std.ArrayList([]const u8) = .empty;
    const config = try zig_config.decodeJson(Config, arena, bytes, .{
        .path = path,
        .env_prefix = env_prefix,
        .environ = env,
        .diagnostic = diagnostic,
        .ignored_keys = &ignored,
    });
    _ = try config.httpConfig();
    if (config.loki.actions.len == 0 or std.mem.indexOfScalar(service.Action, config.loki.actions, .no_action) != null)
        return error.InvalidLokiActions;
    if (!std.math.isFinite(config.service_limits.skadi.min_resample) or config.service_limits.skadi.min_resample <= 0)
        return error.InvalidSkadiMinResample;
    if (!std.math.isFinite(config.service_limits.max_exclude_polygons_length) or config.service_limits.max_exclude_polygons_length < 0)
        return error.InvalidExcludePolygonsLength;
    // Equal keys have the same diagnostic text, so stability has no effect.
    std.sort.heap([]const u8, ignored.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return .{ .config = config, .ignored_keys = ignored.items };
}

fn parseListen(s: []const u8) !io.Address {
    const prefix = "tcp://";
    if (!std.mem.startsWith(u8, s, prefix)) return error.InvalidListenAddress;
    const split = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.InvalidListenAddress;
    if (split < prefix.len) return error.InvalidListenAddress;
    const port = std.fmt.parseInt(u16, s[split + 1 ..], 10) catch return error.InvalidListenAddress;
    const host = s[prefix.len..split];
    if (std.mem.eql(u8, host, "*")) return io.Address.any(port);
    if (std.mem.eql(u8, host, "localhost")) return io.Address.loopback(port);
    return .{ .ip = try parseIp4(host), .port = port };
}

pub fn parseIp4(s: []const u8) ![4]u8 {
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, s, '.');
    for (&ip) |*octet| octet.* = std.fmt.parseInt(u8, parts.next() orelse return error.InvalidListenAddress, 10) catch
        return error.InvalidListenAddress;
    if (parts.next() != null) return error.InvalidListenAddress;
    return ip;
}

const testing = std.testing;

test "configuration defaults match Valhalla's generated service limits" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const defaults = try decode(arena, "{}", "", null, null);
    // Generated by scripts/valhalla_build_config in Valhalla 3.9.3 with no arguments.
    const generated = try decode(arena, @embedFile("fixtures/valhalla-3.9.3-default.json"), "valhalla.json", null, null);
    try testing.expectEqualDeep(defaults.config.service_limits, generated.config.service_limits);
    try testing.expectEqualDeep(defaults.config.httpd.service, generated.config.httpd.service);
    try testing.expectEqualSlices(service.Action, &service.action_order, generated.config.loki.actions);
    try testing.expect(generated.config.additional_data.elevation != null);
    try testing.expectEqual(null, generated.config.mjolnir.default_speeds_config);
    try testing.expectEqual(true, generated.config.mjolnir.data_processing.infer_turn_channels.?);
    try testing.expectEqual(true, generated.config.mjolnir.data_processing.infer_internal_intersections.?);
}

test "environment overrides file, which overrides typed defaults" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZR_SERVICE_LIMITS_SKADI_MAX_SHAPE", "200");
    try env.put("ZR_ZIG_ROUTING_THREADS", "4");
    try env.put("ZR_LOKI_ACTIONS", "status,height");
    const loaded = try decode(state.allocator(),
        \\{"service_limits":{"skadi":{"max_shape":100,"min_resample":15},"auto":{}},"httpd":{"service":{
        \\"listen":"tcp://127.0.0.1:0","timeout_seconds":3,"drain_seconds":5,"loopback":"ipc://x"}}}
    , "valhalla.json", &env, null);
    const svc = loaded.config.serviceConfig();
    const server = try loaded.config.httpConfig();
    try testing.expectEqual(200, svc.limits.skadi_max_shape);
    try testing.expectEqual(15.0, svc.limits.skadi_min_resample);
    try testing.expectEqualSlices(service.Action, &.{ .status, .height }, svc.actions);
    try testing.expectEqual(io.Address.loopback_any_port, server.address);
    try testing.expectEqual(4, server.threads);
    try testing.expectEqual(@as(?u64, 3000), server.request_timeout_ms);
    try testing.expectEqual(5000, server.drain_timeout_ms);
    try testing.expectEqual(512 * 1024 * 1024, server.arena_cap_bytes);
    try testing.expectEqual(2, loaded.ignored_keys.len);
    try testing.expectEqualStrings("httpd.service.loopback", loaded.ignored_keys[0]);
    try testing.expectEqualStrings("service_limits.auto", loaded.ignored_keys[1]);
    var diagnostic: Diagnostic = .{};
    try env.put("ZR_SERVICE_LIMITS_SKADI_MAX_SHAPE", "invalid");
    try testing.expectError(error.ConfigSchemaViolation, decode(state.allocator(), "{}", "valhalla.json", &env, &diagnostic));
    try testing.expectEqualStrings("service_limits.skadi.max_shape", diagnostic.key());
    try testing.expectEqualStrings("ZR_SERVICE_LIMITS_SKADI_MAX_SHAPE", diagnostic.origin());
    try testing.expectError(error.InvalidSkadiMinResample, decode(state.allocator(),
        \\{"service_limits":{"skadi":{"min_resample":0}}}
    , "", null, null));
}
