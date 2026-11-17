//! Valhalla request options: parsing of the shared fields, locations and
//! the /height fields.
//!
//! Ported from src/worker.cc `from_json`, `parse_location`,
//! `parse_locations` and `ParseApi` (Valhalla 3.9.3), field by field in
//! upstream order so the same request fails with the same error code.
//! Costing options are kept as the raw JSON object; each costing model
//! parses its own (P3, P5).
//!
//! Everything is allocated in the request arena.

const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const polyline = @import("../geo/polyline.zig");
const Allocator = std.mem.Allocator;

pub const Action = enum(u8) {
    no_action = 0,
    route = 1,
    locate = 2,
    sources_to_targets = 3,
    optimized_route = 4,
    isochrone = 5,
    trace_route = 6,
    trace_attributes = 7,
    height = 8,
    transit_available = 9,
    expansion = 10,
    centroid = 11,
    status = 12,
    tile = 13,

    /// URL path ("/route") to action, as `Options_Action_Enum_Parse(path.substr(1))`.
    pub fn fromPath(path: []const u8) ?Action {
        if (path.len < 2 or path[0] != '/') return null;
        const a = std.meta.stringToEnum(Action, path[1..]) orelse return null;
        return if (a == .no_action) null else a;
    }
};

pub const Format = enum { json, gpx, osrm, pbf, geotiff, mvt };
pub const Units = enum { kilometers, miles };
pub const DirectionsType = enum { instructions, none, maneuvers };
pub const ShapeFormat = enum { polyline6, polyline5, geojson, no_shape };
pub const Costing = enum { auto, bicycle, bus, taxi, motor_scooter, multimodal, pedestrian, transit, truck, motorcycle, none, bikeshare, auto_pedestrian };
pub const DateTimeType = enum { no_time, current, depart_at, arrive_by, invariant };
pub const LocationType = enum { @"break", through, via, break_through };
pub const PreferredSide = enum { either, same, opposite };
pub const RoadClass = enum { motorway, trunk, primary, secondary, tertiary, unclassified, residential, service_other };

/// The locales odin ships (locales/*.json). Unknown languages fall back to en-US.
pub const locales = [_][]const u8{ "ar-SA", "bg-BG", "ca-ES", "cs-CZ", "da-DK", "de-DE", "el-GR", "en-AU", "en-GB", "en-US-x-pirate", "en-US", "es-ES", "et-EE", "fi-FI", "fr-FR", "he-IL", "hi-IN", "hu-HU", "it-IT", "ja-JP", "ko-KR", "mn-MN", "nb-NO", "nl-NL", "pl-PL", "pt-BR", "pt-PT", "ro-RO", "ru-RU", "sk-SK", "sl-SI", "sv-SE", "tr-TR", "uk-UA", "vi-VN", "zh-CN" };

/// baldr::kMaxLevel.
pub const max_level: f32 = std.math.floatMax(f32);
pub const max_height_precision = 2;

pub const SearchFilter = struct {
    min_road_class: RoadClass = .service_other,
    max_road_class: RoadClass = .motorway,
    exclude_tunnel: bool = false,
    exclude_bridge: bool = false,
    exclude_toll: bool = false,
    exclude_ramp: bool = false,
    exclude_ferry: bool = false,
    exclude_closures: bool = true,
    exclude_restricted: bool = false,
    exclude_steps: bool = false,
    level: f32 = max_level,
};

pub const Location = struct {
    lat: f64,
    lng: f64,
    type: LocationType = .@"break",
    name: ?[]const u8 = null,
    street: ?[]const u8 = null,
    date_time: ?[]const u8 = null,
    heading: ?i32 = null,
    heading_tolerance: ?i32 = null,
    preferred_layer: ?i32 = null,
    node_snap_tolerance: ?f32 = null,
    minimum_reachability: ?u32 = null,
    radius: ?u32 = null,
    accuracy: ?u32 = null,
    time: f64 = -1,
    skip_ranking_candidates: bool = false,
    preferred_side: PreferredSide = .either,
    display_lat: ?f64 = null,
    display_lng: ?f64 = null,
    search_cutoff: ?u32 = null,
    street_side_tolerance: ?u32 = null,
    street_side_max_distance: ?u32 = null,
    street_side_cutoff: ?RoadClass = null,
    search_filter: SearchFilter = .{},
    waiting_secs: f32 = 0,
    original_index: u32 = 0,
};

pub const Options = struct {
    action: Action = .no_action,
    format: Format = .json,
    id: ?[]const u8 = null,
    units: Units = .kilometers,
    language: []const u8 = "en-US",
    directions_type: DirectionsType = .instructions,
    costing: Costing = .none,
    /// The whole `costing_options` object, parsed later by the costing model.
    costing_options: ?json.Value = null,
    verbose: bool = false,
    reverse: bool = false,
    generalize: ?f32 = null,
    date_time_type: DateTimeType = .no_time,
    date_time: ?[]const u8 = null,
    shape_format: ShapeFormat = .polyline6,
    shape_format_set: bool = false,
    locations: []Location = &.{},
    shape: []Location = &.{},
    encoded_polyline: ?[]const u8 = null,
    // /height
    range: bool = false,
    height_precision: u32 = 0,
    resample_distance: ?f64 = null,
    warnings: std.ArrayList(u16) = .empty,
};

pub const Result = union(enum) {
    ok: Options,
    failure: errors.Failure,
};

/// Parses an HTTP request as `ParseApi(http_request_t)` does: the action
/// comes from the path, the document from `?json=` or the body, and every
/// other query parameter is added as a string member (body keys win, as
/// upstream appends query members after the body's).
pub fn parseHttp(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8) Allocator.Error!Result {
    const action = Action.fromPath(path) orelse .no_action;
    var text: []const u8 = body;
    for (query) |q| if (std.mem.eql(u8, q.key, "json") and q.value.len > 0) {
        text = q.value;
        break;
    };
    var doc: json.Value = if (text.len == 0) .{ .object = .empty } else json.parse(arena, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return .{ .failure = .{ .code = 100 } },
    };
    if (doc != .object) return .{ .failure = .{ .code = 100 } };
    for (query) |q| {
        if (std.mem.eql(u8, q.key, "json") or q.key.len == 0 or q.value.len == 0) continue;
        const gop = try doc.object.getOrPut(arena, q.key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .string = q.value };
    }
    return fromJson(arena, doc, action);
}

pub const QueryParam = struct { key: []const u8, value: []const u8 };

fn fail(code: u16) Result {
    return .{ .failure = .{ .code = code } };
}

fn failExtra(code: u16, extra: []const u8) Result {
    return .{ .failure = .{ .code = code, .extra = extra } };
}

fn parseEnum(comptime E: type, s: []const u8) ?E {
    return std.meta.stringToEnum(E, s);
}

fn formatSupported(action: Action, format: Format) bool {
    return switch (format) {
        .json => true,
        .gpx => action == .route or action == .optimized_route or action == .trace_route,
        .osrm => switch (action) {
            .route, .optimized_route, .trace_route, .trace_attributes, .locate, .status, .sources_to_targets, .expansion => true,
            else => false,
        },
        .pbf => switch (action) {
            .route, .optimized_route, .trace_route, .centroid, .trace_attributes, .status, .sources_to_targets, .isochrone, .expansion => true,
            else => false,
        },
        .geotiff => action == .isochrone,
        .mvt => action == .tile,
    };
}

/// midgard circular_range_clamp.
fn circularClamp(value: f64, lower: f64, upper: f64) f64 {
    if (lower <= value and value <= upper) return value;
    const i = upper - lower;
    if (value < lower) {
        var d = lower - value;
        d -= @as(f64, @floatFromInt(@as(i32, @intFromFloat(d / i)))) * i;
        return upper - d;
    }
    var d = value - upper;
    d -= @as(f64, @floatFromInt(@as(i32, @intFromFloat(d / i)))) * i;
    return lower + d;
}

/// `from_json` for the fields in scope.
pub fn fromJson(arena: Allocator, doc: json.Value, action: Action) Allocator.Error!Result {
    var o: Options = .{ .action = action };

    o.verbose = json.get(bool, doc, "/verbose", action == .sources_to_targets);
    if (json.getOptional(f32, doc, "/generalize")) |g| o.generalize = g;

    // Deprecated directions_options: hoist its units, narrative, format, language.
    var root = doc;
    if (json.object(doc, "/directions_options")) |deprecated| {
        var copy = try root.object.clone(arena);
        for ([_][]const u8{ "units", "narrative", "format", "language" }) |k| {
            if (deprecated.get(k)) |v| if (!copy.contains(k)) try copy.put(arena, k, v);
        }
        _ = copy.orderedRemove("directions_options");
        root = .{ .object = copy };
    }

    if (json.getOptional([]const u8, root, "/format")) |f| if (parseEnum(Format, f)) |fmt| {
        o.format = fmt;
    };
    if (json.getOptional([]const u8, root, "/id")) |id| o.id = id;
    if (json.getOptional([]const u8, root, "/jsonp") != null) try o.warnings.append(arena, 104);
    if (!formatSupported(o.action, o.format)) {
        o.format = .json;
        try o.warnings.append(arena, 211);
    }
    if (json.getOptional([]const u8, root, "/units")) |u| {
        if (std.mem.eql(u8, u, "miles") or std.mem.eql(u8, u, "mi")) o.units = .miles;
    }
    o.reverse = json.get(bool, root, "/reverse", false);
    if (json.getOptional([]const u8, root, "/language")) |lang| {
        for (locales) |l| if (std.mem.eql(u8, l, lang)) {
            o.language = l;
            break;
        };
    }
    if (json.getOptional(bool, root, "/narrative")) |n| if (!n) {
        o.directions_type = .none;
    };
    if (json.getOptional([]const u8, root, "/directions_type")) |d| if (parseEnum(DirectionsType, d)) |dt| {
        o.directions_type = dt;
    };

    // Costing, including the deprecated aliases.
    var costing_str = json.get([]const u8, root, "/costing", "none");
    if (std.mem.eql(u8, costing_str, "auto_shorter")) {
        try o.warnings.append(arena, 100);
        costing_str = "auto";
    } else if (std.mem.eql(u8, costing_str, "hov")) {
        try o.warnings.append(arena, 101);
        costing_str = "auto";
    } else if (std.mem.eql(u8, costing_str, "auto_data_fix")) {
        try o.warnings.append(arena, 102);
        costing_str = "auto";
    }
    o.costing = if (costing_str.len == 0) .none else parseEnum(Costing, costing_str) orelse
        return failExtra(125, try std.fmt.allocPrint(arena, "'{s}'", .{costing_str}));
    o.costing_options = json.pointer(root, "/costing_options");

    // date_time (type and value validation; full time handling arrives with P5).
    if (json.getOptional(u32, root, "/date_time/type")) |t| if (t + 1 <= 4) {
        o.date_time_type = @fromBackingInt(@intCast(t + 1));
        const value = json.getOptional([]const u8, root, "/date_time/value");
        if (o.date_time_type == .current) {
            o.date_time = "current";
        } else if (value) |v| {
            if (!isIsoDateTime(v)) return fail(162);
            o.date_time = v;
        } else {
            return fail(switch (o.date_time_type) {
                .depart_at => 160,
                .arrive_by => 161,
                else => 165,
            });
        }
    };

    // shape_format (also selects the precision of /height encoded_polyline).
    if (json.getOptional([]const u8, root, "/shape_format")) |sf| {
        o.shape_format_set = true;
        if (std.mem.eql(u8, sf, "polyline6")) {
            o.shape_format = .polyline6;
        } else if (std.mem.eql(u8, sf, "polyline5")) {
            o.shape_format = .polyline5;
        } else if (std.mem.eql(u8, sf, "geojson")) {
            o.shape_format = .geojson;
        } else if (std.mem.eql(u8, sf, "no_shape") and action != .height) {
            o.shape_format = .no_shape;
        } else return fail(164);
    } else if (action == .sources_to_targets) o.shape_format = .no_shape;

    // Shape: an encoded polyline or a list of locations.
    if (json.getOptional([]const u8, root, "/encoded_polyline")) |enc| {
        o.encoded_polyline = enc;
        const precision: f64 = if (action == .height and o.shape_format == .polyline5) 1e-5 else 1e-6;
        var pts: std.ArrayList(Location) = .empty;
        var d = polyline.Decoder(.polyline).initPrecision(enc, precision);
        while (true) {
            const p = (d.next() catch return fail(100)) orelse break;
            try pts.append(arena, .{ .lat = p.lat, .lng = p.lng, .type = .via, .time = -1 });
        }
        if (pts.items.len > 0) {
            pts.items[0].type = .@"break";
            pts.items[pts.items.len - 1].type = .@"break";
        }
        o.shape = pts.items;
    } else {
        switch (try parseLocations(arena, root, "/shape", &o)) {
            .ok => |locs| o.shape = locs,
            .failure => return fail(134),
        }
    }

    switch (try parseLocations(arena, root, "/locations", &o)) {
        .ok => |locs| o.locations = locs,
        .failure => |f| return .{ .failure = if (f.code == 0) .{ .code = 130 } else f },
    }

    o.range = json.get(bool, root, "/range", false);
    if (json.getOptional(u32, root, "/height_precision")) |hp| if (hp <= max_height_precision) {
        o.height_precision = hp;
    };
    if (json.getOptional(f64, root, "/resample_distance")) |rd| o.resample_distance = rd;

    return .{ .ok = o };
}

const LocationsResult = union(enum) { ok: []Location, failure: errors.Failure };

/// `parse_locations`: any failure parsing one location becomes the
/// caller's node-specific code (130 locations, 134 shape, ...); a
/// failure code of 0 means "use the node's code".
fn parseLocations(arena: Allocator, doc: json.Value, path: []const u8, o: *const Options) Allocator.Error!LocationsResult {
    const items = json.array(doc, path) orelse return .{ .ok = &.{} };
    const locs = try arena.alloc(Location, items.len);
    for (items, 0..) |item, i| {
        locs[i] = parseLocation(item, o) orelse return .{ .failure = .{ .code = 0 } };
        locs[i].original_index = @intCast(i);
    }
    if (locs.len > 0) {
        locs[0].type = .@"break";
        locs[locs.len - 1].type = .@"break";
    }
    return .{ .ok = locs };
}

/// Location defaults that depend on the request, as the full parser sets them.
fn defaultLocation(lat: f64, lng: f64, o: *const Options) Location {
    var loc: Location = .{ .lat = lat, .lng = circularClamp(lng, -180, 180) };
    if (o.action == .trace_attributes or o.action == .trace_route) loc.type = .via;
    loc.search_filter.exclude_steps = o.costing == .bicycle;
    return loc;
}

fn parseLocation(r: json.Value, o: *const Options) ?Location {
    // Fast path: an object with only lat and lon (every /height point, most
    // route stops). All other fields take their defaults, exactly as the
    // full parser below would leave them.
    if (r == .object and r.object.count() <= 2) fast: {
        var lat: ?f64 = null;
        var lon: ?f64 = null;
        var it = r.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "lat")) {
                lat = json.convert(f64, e.value_ptr.*);
            } else if (std.mem.eql(u8, e.key_ptr.*, "lon")) {
                lon = json.convert(f64, e.value_ptr.*);
            } else break :fast;
        }
        const la = lat orelse return null;
        if (la < -90.0 or la > 90.0) return null;
        return defaultLocation(la, lon orelse return null, o);
    }
    const lat = json.getOptional(f64, r, "/lat") orelse return null;
    if (lat < -90.0 or lat > 90.0) return null;
    const lon_raw = json.getOptional(f64, r, "/lon") orelse return null;
    var loc: Location = .{ .lat = lat, .lng = circularClamp(lon_raw, -180, 180) };

    if (o.action == .trace_attributes) {
        loc.type = .via;
    } else if (json.getOptional([]const u8, r, "/type")) |t| {
        loc.type = parseEnum(LocationType, t) orelse .@"break";
    } else if (o.action == .trace_route) {
        loc.type = .via;
    }
    loc.name = json.getOptional([]const u8, r, "/name");
    loc.street = json.getOptional([]const u8, r, "/street");
    loc.date_time = json.getOptional([]const u8, r, "/date_time");
    loc.heading = json.getOptional(i32, r, "/heading");
    loc.heading_tolerance = json.getOptional(i32, r, "/heading_tolerance");
    loc.preferred_layer = json.getOptional(i32, r, "/preferred_layer");
    loc.node_snap_tolerance = json.getOptional(f32, r, "/node_snap_tolerance");
    loc.minimum_reachability = json.getOptional(u32, r, "/minimum_reachability");
    loc.radius = json.getOptional(u32, r, "/radius");
    loc.accuracy = json.getOptional(u32, r, "/accuracy");
    loc.time = json.get(f64, r, "/time", -1);
    loc.skip_ranking_candidates = !json.get(bool, r, "/rank_candidates", true);
    if (json.getOptional([]const u8, r, "/preferred_side")) |s| if (parseEnum(PreferredSide, s)) |side| {
        loc.preferred_side = side;
    };
    const dlat = json.getOptional(f64, r, "/display_lat");
    const dlon = json.getOptional(f64, r, "/display_lon");
    if (dlat != null and dlon != null and dlat.? >= -90.0 and dlat.? <= 90.0) {
        loc.display_lat = dlat;
        loc.display_lng = circularClamp(dlon.?, -180, 180);
    }
    loc.search_cutoff = json.getOptional(u32, r, "/search_cutoff");
    loc.street_side_tolerance = json.getOptional(u32, r, "/street_side_tolerance");
    loc.street_side_max_distance = json.getOptional(u32, r, "/street_side_max_distance");
    if (json.getOptional([]const u8, r, "/street_side_cutoff")) |c| loc.street_side_cutoff = parseEnum(RoadClass, c);

    var exclude_steps: ?bool = null;
    if (json.pointer(r, "/search_filter")) |sf| {
        if (parseEnum(RoadClass, json.get([]const u8, sf, "/min_road_class", "service_other"))) |rc| loc.search_filter.min_road_class = rc;
        if (parseEnum(RoadClass, json.get([]const u8, sf, "/max_road_class", "motorway"))) |rc| loc.search_filter.max_road_class = rc;
        loc.search_filter.exclude_tunnel = json.get(bool, sf, "/exclude_tunnel", false);
        loc.search_filter.exclude_bridge = json.get(bool, sf, "/exclude_bridge", false);
        loc.search_filter.exclude_toll = json.get(bool, sf, "/exclude_toll", false);
        loc.search_filter.exclude_ramp = json.get(bool, sf, "/exclude_ramp", false);
        loc.search_filter.exclude_ferry = json.get(bool, sf, "/exclude_ferry", false);
        loc.search_filter.exclude_restricted = json.get(bool, sf, "/exclude_restricted", false);
        loc.search_filter.level = json.get(f32, sf, "/level", max_level);
        exclude_steps = json.getOptional(bool, sf, "/exclude_steps");
        if (json.getOptional(bool, sf, "/exclude_closures")) |ec| loc.search_filter.exclude_closures = ec;
    }
    loc.search_filter.exclude_steps = exclude_steps orelse (o.costing == .bicycle);
    loc.waiting_secs = json.get(f32, r, "/waiting", 0);
    return loc;
}

/// baldr::DateTime::is_iso_valid: "YYYY-MM-DDTHH:MM" with valid ranges.
pub fn isIsoDateTime(s: []const u8) bool {
    if (s.len != 16 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':') return false;
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return false;
    if (year < 1900 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59) return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= days[month - 1];
}

// ---------------------------------------------------------------------------
// Tests (cases from test/parse_request.cc for the fields in scope)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseText(arena: Allocator, action: Action, text: []const u8) !Result {
    const doc = try json.parse(arena, text);
    return fromJson(arena, doc, action);
}

test "route request: wildloop-style pedestrian with costing options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseText(a, .route,
        \\{"locations":[{"lat":47.37,"lon":8.54},{"lat":47.38,"lon":8.55,"type":"through"},{"lat":47.39,"lon":8.56,"type":"via"}],
        \\ "costing":"pedestrian","costing_options":{"pedestrian":{"walkway_factor":0.6,"max_hiking_difficulty":3}},
        \\ "directions_type":"none","units":"miles","language":"de-DE","id":"leg-1"}
    );
    const o = r.ok;
    try testing.expectEqual(Costing.pedestrian, o.costing);
    try testing.expectEqual(DirectionsType.none, o.directions_type);
    try testing.expectEqual(Units.miles, o.units);
    try testing.expectEqualStrings("de-DE", o.language);
    try testing.expectEqualStrings("leg-1", o.id.?);
    try testing.expectEqual(@as(usize, 3), o.locations.len);
    // First and last are always breaks; the middle keeps its type.
    try testing.expectEqual(LocationType.@"break", o.locations[0].type);
    try testing.expectEqual(LocationType.through, o.locations[1].type);
    try testing.expectEqual(LocationType.@"break", o.locations[2].type);
    try testing.expectEqual(@as(f64, 0.6), json.getOptional(f64, o.costing_options.?, "/pedestrian/walkway_factor").?);
}

test "defaults, unknown language and unsupported format" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = (try parseText(a, .height, "{\"language\":\"xx-YY\",\"format\":\"gpx\",\"jsonp\":\"cb\"}")).ok;
    try testing.expectEqualStrings("en-US", o.language);
    try testing.expectEqual(Format.json, o.format);
    try testing.expectEqualSlices(u16, &.{ 104, 211 }, o.warnings.items);
    try testing.expectEqual(Costing.none, o.costing);
    try testing.expectEqual(Units.kilometers, o.units);
}

test "error codes in upstream order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(@as(u16, 125), (try parseText(a, .route, "{\"costing\":\"rocket\"}")).failure.code);
    try testing.expectEqual(@as(u16, 164), (try parseText(a, .height, "{\"shape_format\":\"no_shape\"}")).failure.code);
    try testing.expectEqual(@as(u16, 164), (try parseText(a, .route, "{\"shape_format\":\"wkt\"}")).failure.code);
    try testing.expectEqual(@as(u16, 130), (try parseText(a, .route, "{\"locations\":[{\"lat\":91,\"lon\":0}]}")).failure.code);
    try testing.expectEqual(@as(u16, 130), (try parseText(a, .route, "{\"locations\":[{\"lon\":0}]}")).failure.code);
    try testing.expectEqual(@as(u16, 134), (try parseText(a, .height, "{\"shape\":[{\"lat\":\"x\",\"lon\":0}]}")).failure.code);
    try testing.expectEqual(@as(u16, 162), (try parseText(a, .route, "{\"date_time\":{\"type\":1,\"value\":\"2026-02-30T10:00\"}}")).failure.code);
    try testing.expectEqual(@as(u16, 160), (try parseText(a, .route, "{\"date_time\":{\"type\":1}}")).failure.code);
    const unknown = (try parseText(a, .route, "{\"costing\":\"rocket\"}")).failure;
    try testing.expectEqualStrings("'rocket'", unknown.extra);
}

test "height request: shape, range, precision, resample" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = (try parseText(a, .height, "{\"shape\":[{\"lat\":40.712433,\"lon\":-76.504913},{\"lat\":40.712276,\"lon\":-76.605263}],\"range\":true,\"height_precision\":2,\"resample_distance\":30}")).ok;
    try testing.expectEqual(@as(usize, 2), o.shape.len);
    try testing.expect(o.range);
    try testing.expectEqual(@as(u32, 2), o.height_precision);
    try testing.expectEqual(@as(f64, 30), o.resample_distance.?);
    const p3 = (try parseText(a, .height, "{\"height_precision\":3}")).ok;
    try testing.expectEqual(@as(u32, 0), p3.height_precision);
}

test "height encoded polyline uses polyline5 when shape_format says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o5 = (try parseText(a, .height, "{\"encoded_polyline\":\"s}ksFfkupMz@fT\",\"shape_format\":\"polyline5\"}")).ok;
    try testing.expectEqual(@as(usize, 2), o5.shape.len);
    try testing.expectApproxEqAbs(@as(f64, 40.0433), o5.shape[0].lat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -76.3002), o5.shape[0].lng, 1e-9);
    const o6 = (try parseText(a, .height, "{\"encoded_polyline\":\"gq`kkAny~opCvQnsE\"}")).ok;
    try testing.expectApproxEqAbs(@as(f64, -76.3036), o6.shape[1].lng, 1e-9);
}

test "http: query parameters merge, body keys win, json param" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try parseHttp(a, "/route", &.{ .{ .key = "units", .value = "mi" }, .{ .key = "costing", .value = "auto" } }, "{\"costing\":\"bicycle\",\"locations\":[{\"lat\":1,\"lon\":2},{\"lat\":1.1,\"lon\":2.1}]}");
    try testing.expectEqual(Costing.bicycle, r.ok.costing);
    try testing.expectEqual(Units.miles, r.ok.units);
    try testing.expect(r.ok.locations[0].search_filter.exclude_steps); // bicycle default
    const g = try parseHttp(a, "/height", &.{.{ .key = "json", .value = "{\"range\":true}" }}, "");
    try testing.expect(g.ok.range);
    try testing.expectEqual(Action.height, g.ok.action);
    try testing.expectEqual(@as(u16, 100), (try parseHttp(a, "/route", &.{}, "{nope")).failure.code);
    try testing.expectEqual(Action.no_action, (try parseHttp(a, "/nothing", &.{}, "")).ok.action);
}

test "longitude wraps like circular_range_clamp" {
    try testing.expectApproxEqAbs(@as(f64, -170), circularClamp(190, -180, 180), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 170), circularClamp(-190, -180, 180), 1e-9);
    try testing.expectEqual(@as(f64, 10), circularClamp(10, -180, 180));
}
