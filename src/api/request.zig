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
const exclusions = @import("exclusions.zig");
const datetime = @import("../graph/datetime.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const polyline = @import("../geo/polyline.zig");
const PointLL = @import("../geo/point.zig").PointLL;
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
const AutoAlias = enum(u8) { auto_shorter = 100, hov = 101, auto_data_fix = 102 };
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
    minimum_inbound_reachability: ?u32 = null,
    minimum_outbound_reachability: ?u32 = null,
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

pub const Recosting = struct {
    costing: Costing,
    name: []const u8,
    options: json.Value,
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
    recostings: []const Recosting = &.{},
    ignore_closures: ?bool = null,
    filter_closures: bool = true,
    verbose: bool = false,
    reverse: bool = false,
    generalize: ?f32 = null,
    date_time_type: DateTimeType = .no_time,
    date_time: ?[]const u8 = null,
    shape_format: ShapeFormat = .polyline6,
    shape_format_set: bool = false,
    locations: []Location = &.{},
    sources: []Location = &.{},
    targets: []Location = &.{},
    exclude_locations: []Location = &.{},
    exclude_polygons: []const exclusions.Ring = &.{},
    shape: []Location = &.{},
    encoded_polyline: ?[]const u8 = null,
    // /height
    /// The native handler needs only coordinates from a plain numeric shape.
    height_points: ?[]const PointLL = null,
    range: bool = false,
    height_precision: u32 = 0,
    resample_distance: ?f64 = null,
    warnings: std.ArrayList(u16) = .empty,

    pub fn heightPoints(self: *const Options, arena: Allocator) Allocator.Error![]const PointLL {
        if (self.height_points) |points| return points;
        const points = try arena.alloc(PointLL, self.shape.len);
        for (self.shape, points) |location, *p| p.* = .{ .lng = location.lng, .lat = location.lat };
        return points;
    }

    fn shapeCount(self: *const Options) usize {
        return if (self.height_points) |points| points.len else self.shape.len;
    }

    fn shapePoint(self: *const Options, i: usize) PointLL {
        if (self.height_points) |points| return points[i];
        const location = self.shape[i];
        return .{ .lng = location.lng, .lat = location.lat };
    }
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
    return parseWithoutDeadline(arena, path, query, body, .locations);
}

/// Parse plain /height shapes directly into the coordinates its handler reads.
pub fn parseHttpForHeight(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8) Allocator.Error!Result {
    return parseWithoutDeadline(arena, path, query, body, .height_points);
}

/// `parseHttp` without the /height shape fast path: the reference the fast
/// path is tested against.
pub fn parseHttpReference(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8) Allocator.Error!Result {
    return parseWithoutDeadline(arena, path, query, body, .reference);
}

const ParseError = Allocator.Error || error{DeadlineExceeded};
const ShapeMode = enum { reference, locations, height_points };

fn parseWithoutDeadline(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8, mode: ShapeMode) Allocator.Error!Result {
    return parseHttpWith(arena, path, query, body, mode, .none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => unreachable,
    };
}

pub fn parseHttpWithin(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8, height_points: bool, deadline: Deadline) ParseError!Result {
    return parseHttpWith(arena, path, query, body, if (height_points) .height_points else .locations, deadline);
}

fn parseHttpWith(arena: Allocator, path: []const u8, query: []const QueryParam, body: []const u8, mode: ShapeMode, deadline: Deadline) ParseError!Result {
    const action = Action.fromPath(path) orelse .no_action;
    var text: []const u8 = body;
    for (query) |q| if (std.mem.eql(u8, q.key, "json") and q.value.len > 0) {
        text = q.value;
        break;
    };
    // A /height shape is nearly all of a bulk request. When it is a plain
    // array of {"lat":n,"lon":n}, read it straight from the text and hand the
    // rest of the document (shape replaced by []) to the general parser.
    const fast: ?FastShape = if (mode != .reference and action == .height and text.len >= 128) try fastShape(arena, text) else null;
    if (fast) |f| text = f.rest;
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
    var result = try fromJsonWithin(arena, doc, action, deadline);
    if (fast) |f| switch (result) {
        .ok => |*o| if (o.encoded_polyline == null) {
            if (o.locations.len == 0 and o.sources.len == 0 and o.targets.len == 0 and o.exclude_locations.len == 0) {
                o.filter_closures = !(o.ignore_closures orelse false);
            }
            if (mode == .height_points) {
                for (f.points) |*p| p.lng = circularClamp(p.lng, -180, 180);
                o.height_points = f.points;
            } else {
                // What parseLocations would have built from the same points.
                const locs = try arena.alloc(Location, f.points.len);
                for (locs, f.points, 0..) |*l, p, i| {
                    l.* = defaultLocation(p.lat, p.lng, o);
                    l.original_index = @intCast(i);
                }
                locs[0].type = .@"break";
                locs[locs.len - 1].type = .@"break";
                o.shape = locs;
            }
        },
        .failure => {},
    };
    return result;
}

const FastShape = struct {
    /// The document with the shape array replaced by `[]`.
    rest: []const u8,
    /// Latitudes are range-checked. Longitudes still need circular clamping.
    points: []PointLL,
};

inline fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipWs(t: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < t.len and isWs(t[i])) i += 1;
    return i;
}

/// Index after the string starting at `i` (t[i] == '"'), or null.
fn skipString(t: []const u8, i_in: usize) ?usize {
    var i = i_in + 1;
    while (i < t.len) : (i += 1) switch (t[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        else => {},
    };
    return null;
}

/// Index after the value starting at `i`, without validating it (the
/// general parser validates the whole document afterwards).
fn skipValue(t: []const u8, i_in: usize) ?usize {
    if (i_in >= t.len) return null;
    var i = i_in;
    switch (t[i]) {
        '"' => return skipString(t, i),
        '{', '[' => {
            var depth: usize = 0;
            while (i < t.len) {
                switch (t[i]) {
                    '"' => {
                        i = skipString(t, i) orelse return null;
                        continue;
                    },
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                    else => {},
                }
                i += 1;
            }
            return null;
        },
        else => {
            while (i < t.len and t[i] != ',' and t[i] != '}' and t[i] != ']' and !isWs(t[i])) i += 1;
            return i;
        },
    }
}

const pow10_u64 = blk: {
    var t: [20]u64 = undefined;
    t[0] = 1;
    for (1..20) |k| t[k] = t[k - 1] * 10;
    break :blk t;
};

/// Reads the run of decimal digits at t[i..] into `out` and returns its
/// length; 16 or more means "too long" (the caller falls back). Eight digits
/// at a time with SWAR when eight bytes are readable.
fn digitRun(t: []const u8, i_in: usize, out: *u64) u32 {
    var i = i_in;
    var v: u64 = 0;
    var n: u32 = 0;
    while (i + 8 <= t.len) {
        const word = std.mem.readInt(u64, t[i..][0..8], .little);
        // High bit of each byte set where the byte is not '0'..'9'.
        const non_digit = ((word +% 0x4646464646464646) | (word -% 0x3030303030303030)) & 0x8080808080808080;
        const k: u32 = if (non_digit == 0) 8 else @intCast(@ctz(non_digit) / 8);
        if (k > 0) {
            // The first k digits, most significant first in byte 0, moved to
            // the top of the word with zeros below, then combined in pairs.
            var x = (word -% 0x3030303030303030) << @intCast((8 - k) * 8);
            if (k == 8) x = word -% 0x3030303030303030;
            x = ((x & 0x0F0F0F0F0F0F0F0F) *% 2561) >> 8;
            x = ((x & 0x00FF00FF00FF00FF) *% 6553601) >> 16;
            x = ((x & 0x0000FFFF0000FFFF) *% 42949672960001) >> 32;
            v = v *% pow10_u64[k] +% x;
            n += k;
            i += k;
        }
        if (k < 8 or n >= 16) {
            out.* = v;
            return n;
        }
    }
    while (i < t.len and t[i] >= '0' and t[i] <= '9' and n < 16) : (i += 1) {
        v = v * 10 + (t[i] - '0');
        n += 1;
    }
    out.* = v;
    return n;
}

const exact_pow10 = [23]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

/// A strict JSON number at `t[i..]` with at most 15 digits, converted
/// exactly as the general parser converts it: an integer literal through
/// i64 (so "-0" is +0), anything else correctly rounded (Clinger's fast
/// path: mantissa < 2^53 and |exponent| <= 22 make one IEEE operation
/// exact). Returns the end index, or null to fall back.
fn parseNumber(t: []const u8, i_in: usize, out: *f64) ?usize {
    var i = i_in;
    const neg = i < t.len and t[i] == '-';
    if (neg) i += 1;
    if (i >= t.len) return null;
    var m: u64 = 0;
    var digits: u32 = 0;
    if (t[i] == '0') {
        i += 1;
        digits = 1;
    } else if (t[i] >= '1' and t[i] <= '9') {
        const n = digitRun(t, i, &m);
        i += n;
        digits = n;
    } else return null;
    var frac_digits: i32 = 0;
    var is_float = false;
    if (i < t.len and t[i] == '.') {
        is_float = true;
        i += 1;
        var f: u64 = 0;
        const n = digitRun(t, i, &f);
        if (n == 0) return null;
        if (digits + n > 15) return null;
        m = m * pow10_u64[n] + f;
        i += n;
        digits += n;
        frac_digits = @intCast(n);
    }
    var exp: i32 = 0;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        is_float = true;
        i += 1;
        var exp_neg = false;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) {
            exp_neg = t[i] == '-';
            i += 1;
        }
        const start = i;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {
            if (i - start >= 4) return null;
            exp = exp * 10 + (t[i] - '0');
        }
        if (i == start) return null;
        if (exp_neg) exp = -exp;
    }
    if (digits > 15) return null;
    if (!is_float) {
        const v: i64 = @intCast(m);
        out.* = @floatFromInt(if (neg) -v else v);
        return i;
    }
    const e10 = exp - frac_digits;
    if (e10 < -22 or e10 > 22) return null;
    const mf: f64 = @floatFromInt(m);
    const v = if (e10 >= 0) mf * exact_pow10[@intCast(e10)] else mf / exact_pow10[@intCast(-e10)];
    out.* = if (neg) -v else v;
    return i;
}

/// One `{"lat":n,"lon":n}` (either order, whitespace allowed) at t[i..].
fn parsePoint(t: []const u8, i_in: usize, out: *[2]f64) ?usize {
    var i = skipWs(t, i_in);
    if (i >= t.len or t[i] != '{') return null;
    var seen: [2]bool = .{ false, false };
    for (0..2) |k| {
        i = skipWs(t, i + 1);
        if (i + 5 > t.len or t[i] != '"') return null;
        const which: usize = if (std.mem.eql(u8, t[i..][0..5], "\"lat\"")) 0 else if (std.mem.eql(u8, t[i..][0..5], "\"lon\"")) 1 else return null;
        if (seen[which]) return null;
        seen[which] = true;
        i = skipWs(t, i + 5);
        if (i >= t.len or t[i] != ':') return null;
        i = parseNumber(t, skipWs(t, i + 1), &out[which]) orelse return null;
        i = skipWs(t, i);
        if (i >= t.len or t[i] != (if (k == 0) @as(u8, ',') else '}')) return null;
    }
    return i + 1;
}

/// Finds the document's one top-level "shape" member and parses it when it
/// is a non-empty array of plain points with valid latitudes; null for
/// anything else (the general parser then handles the whole document).
fn fastShape(arena: Allocator, t: []const u8) Allocator.Error!?FastShape {
    var i = skipWs(t, 0);
    if (i >= t.len or t[i] != '{') return null;
    i = skipWs(t, i + 1);
    var span: ?[2]usize = null;
    var points: std.ArrayList(PointLL) = .empty;
    while (i < t.len and t[i] == '"') {
        const key_end = skipString(t, i) orelse return null;
        const key = t[i + 1 .. key_end - 1];
        if (std.mem.indexOfScalar(u8, key, '\\') != null) return null;
        i = skipWs(t, key_end);
        if (i >= t.len or t[i] != ':') return null;
        i = skipWs(t, i + 1);
        const end: usize = if (std.mem.eql(u8, key, "shape")) shape: {
            if (span != null) return null; // duplicate keys: the general parser's rule decides
            const end = (try parsePlainShape(arena, t, i, &points)) orelse return null;
            span = .{ i, end };
            break :shape end;
        } else skipValue(t, i) orelse return null;
        i = skipWs(t, end);
        if (i < t.len and t[i] == ',') {
            i = skipWs(t, i + 1);
            continue;
        }
        break;
    }
    const s = span orelse return null;

    const rest = try arena.alloc(u8, t.len - (s[1] - s[0]) + 2);
    @memcpy(rest[0..s[0]], t[0..s[0]]);
    rest[s[0]] = '[';
    rest[s[0] + 1] = ']';
    @memcpy(rest[s[0] + 2 ..], t[s[1]..]);
    return .{ .rest = rest, .points = points.items };
}

fn parsePlainShape(arena: Allocator, t: []const u8, start: usize, points: *std.ArrayList(PointLL)) Allocator.Error!?usize {
    if (start >= t.len or t[start] != '[') return null;
    try points.ensureTotalCapacity(arena, @min((t.len - start) / 24 + 1, 4096));
    var j = skipWs(t, start + 1);
    if (j < t.len and t[j] == ']') return null; // empty: nothing to gain
    while (true) {
        var p: [2]f64 = undefined;
        j = parsePoint(t, j, &p) orelse return null;
        if (p[0] < -90.0 or p[0] > 90.0) return null;
        try points.append(arena, .{ .lat = p[0], .lng = p[1] });
        j = skipWs(t, j);
        if (j >= t.len) return null;
        if (t[j] == ']') return j + 1;
        if (t[j] != ',') return null;
        j += 1;
    }
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
        d -= @as(f64, @floatFromInt(truncI32(d / i))) * i;
        return upper - d;
    }
    var d = value - upper;
    d -= @as(f64, @floatFromInt(truncI32(d / i))) * i;
    return lower + d;
}

/// `static_cast<int>(x)` as compiled for x86-64 (cvttsd2si): truncation, and
/// INT_MIN for NaN or anything out of range. In C++ the out-of-range cast is
/// undefined; this is what production's x86-64 build does with it, so a
/// request with `"lon": 1e400` gets upstream's answer instead of a crash.
fn truncI32(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

/// `from_json` for the fields in scope.
pub fn fromJson(arena: Allocator, doc: json.Value, action: Action) Allocator.Error!Result {
    return fromJsonWithin(arena, doc, action, .none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => unreachable,
    };
}

fn fromJsonWithin(arena: Allocator, doc: json.Value, action: Action, deadline: Deadline) ParseError!Result {
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
    const requested_costing = json.get([]const u8, root, "/costing", "none");
    const alias = parseEnum(AutoAlias, requested_costing);
    if (alias) |legacy| try o.warnings.append(arena, @backingInt(legacy));
    const costing_str = if (alias != null) "auto" else requested_costing;
    o.costing = if (costing_str.len == 0) .none else parseEnum(Costing, costing_str) orelse
        return failExtra(125, try std.fmt.allocPrint(arena, "'{s}'", .{costing_str}));
    o.costing_options = json.pointer(root, "/costing_options");
    if (alias) |legacy| o.costing_options = try normalizeAutoOptions(arena, o.costing_options, legacy);
    if (o.ignore_closures == null and o.costing != .multimodal and o.costing_options != null and o.costing_options.? == .object) {
        const costings = o.costing_options.?.object;
        const key = if (alias != null) costing_str else requested_costing;
        if (costings.get(key) orelse costings.get(@tagName(o.costing))) |costing| {
            o.ignore_closures = json.getOptional(bool, costing, "/ignore_closures");
        }
    }

    if (parseDateTime(root, &o)) |code| return fail(code);

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
        if (try parseLocationField(arena, root, &o, "/shape", .shape, 134, deadline)) |failure| return failure;
    }

    if (json.array(root, "/recostings")) |items| {
        if (try parseRecostings(arena, items, &o, deadline)) |failure| return failure;
    }
    if (try parseLocationField(arena, root, &o, "/locations", .locations, 130, deadline)) |failure| return failure;
    if (try parseLocationField(arena, root, &o, "/sources", .sources, 131, deadline)) |failure| return failure;
    if (try parseLocationField(arena, root, &o, "/targets", .targets, 132, deadline)) |failure| return failure;
    const avoids = if (root == .object and root.object.contains("avoid_locations")) "/avoid_locations" else "/exclude_locations";
    if (try parseLocationField(arena, root, &o, avoids, .exclude_locations, 133, deadline)) |failure| return failure;
    switch (try exclusions.parse(arena, root, circularClamp, deadline)) {
        .rings => |rings| o.exclude_polygons = rings,
        .warning => try o.warnings.append(arena, 204),
        .failure => |failure| return .{ .failure = failure },
    }

    o.range = json.get(bool, root, "/range", false);
    if (json.getOptional(u32, root, "/height_precision")) |hp| if (hp <= max_height_precision) {
        o.height_precision = hp;
    };
    if (json.getOptional(f64, root, "/resample_distance")) |rd| o.resample_distance = rd;

    return .{ .ok = o };
}

const LocationsResult = union(enum) { ok: []Location, failure: errors.Failure };

const LocationField = enum { shape, locations, sources, targets, exclude_locations };

// Ported from parse_recostings in src/worker.cc (Valhalla 3.9.3).
noinline fn parseRecostings(arena: Allocator, items: []const json.Value, out: *Options, deadline: Deadline) ParseError!?Result {
    const recostings = try arena.alloc(Recosting, items.len);
    var names: std.json.ObjectMap = .empty;
    for (items, recostings, 0..) |item, *recosting, i| {
        if (i % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const requested = json.getOptional([]const u8, item, "/costing") orelse return fail(127);
        const costing = parseEnum(Costing, requested) orelse return failExtra(125, try std.fmt.allocPrint(arena, "'{s}'", .{requested}));
        const name = switch (costing) {
            .multimodal, .bikeshare, .auto_pedestrian => return fail(127),
            .bus, .taxi, .none, .transit => requested,
            else => json.getOptional([]const u8, item, "/name") orelse requested,
        };
        const entry = try names.getOrPut(arena, name);
        if (entry.found_existing) return fail(128);
        entry.value_ptr.* = .null;
        recosting.* = .{ .costing = costing, .name = name, .options = item };
    }
    out.recostings = recostings;
    return null;
}

fn parseLocationField(arena: Allocator, doc: json.Value, o: *Options, path: []const u8, comptime field: LocationField, code: u16, deadline: Deadline) ParseError!?Result {
    switch (try parseLocations(arena, doc, path, o, deadline)) {
        .ok => |locs| @field(o, @tagName(field)) = locs,
        .failure => |failure| return .{ .failure = if (failure.code == 0) .{ .code = code } else failure },
    }
    return null;
}

noinline fn normalizeAutoOptions(arena: Allocator, options: ?json.Value, alias: AutoAlias) Allocator.Error!json.Value {
    const input = options orelse .null;
    var costings: std.json.ObjectMap = if (input == .object) try input.object.clone(arena) else .empty;
    const previous = costings.get(@tagName(alias)) orelse costings.get("auto") orelse .null;
    var motor: std.json.ObjectMap = if (previous == .object) try previous.object.clone(arena) else .empty;
    const flags: []const []const u8 = switch (alias) {
        .auto_shorter => &.{"shortest"},
        .hov => &.{"include_hov2"},
        .auto_data_fix => &.{ "ignore_restrictions", "ignore_oneways", "ignore_access", "ignore_closures" },
    };
    for (flags) |flag| try motor.put(arena, flag, .{ .bool = true });
    try costings.put(arena, "auto", .{ .object = motor });
    return .{ .object = costings };
}

fn parseDateTime(root: json.Value, o: *Options) ?u16 {
    if (json.getOptional(u32, root, "/date_time/type")) |value| {
        if (value <= 3) o.date_time_type = @fromBackingInt(@intCast(value + 1));
    }
    const transit = o.costing == .multimodal or o.costing == .transit;
    if (o.date_time_type == .no_time and transit) o.date_time_type = .current;
    switch (o.date_time_type) {
        .no_time => return null,
        .current => o.date_time = "current",
        .depart_at, .arrive_by, .invariant => |mode| {
            const value = json.get([]const u8, root, "/date_time/value", "");
            if (value.len == 0) return switch (mode) {
                .depart_at => 160,
                .arrive_by => 161,
                .invariant => 165,
                else => unreachable,
            };
            if (!std.mem.eql(u8, value, "current") and !isIsoDateTime(value)) return 162;
            o.date_time = value;
        },
    }
    if (o.date_time_type == .arrive_by or o.date_time_type == .invariant) {
        if (transit) return 141;
        if (o.action == .isochrone) return 142;
    }
    return null;
}

/// `parse_locations`: any failure parsing one location becomes the
/// caller's node-specific code (130 locations, 134 shape, ...); a
/// failure code of 0 means "use the node's code".
noinline fn parseLocations(arena: Allocator, doc: json.Value, path: []const u8, o: *Options, deadline: Deadline) ParseError!LocationsResult {
    const items = json.array(doc, path) orelse return .{ .ok = &.{} };
    const locs = try arena.alloc(Location, items.len);
    var filter_closures = true;
    for (items, 0..) |item, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        locs[i] = parseLocation(item, o) catch |err| return .{ .failure = .{ .code = switch (err) {
            error.InvalidCoordinate => 0,
            error.ConflictingClosures => 143,
        } } };
        filter_closures = filter_closures and locs[i].search_filter.exclude_closures;
        locs[i].original_index = @intCast(i);
        if (o.action == .sources_to_targets) continue;
        switch (o.date_time_type) {
            .no_time => {},
            .current, .depart_at => if (i == 0) {
                locs[i].date_time = o.date_time;
            },
            .arrive_by => if (i + 1 == items.len) {
                locs[i].date_time = o.date_time;
            },
            .invariant => locs[i].date_time = o.date_time,
        }
    }
    if (locs.len > 0) {
        o.filter_closures = filter_closures;
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
    if (o.ignore_closures) |ignore| loc.search_filter.exclude_closures = !ignore;
    return loc;
}

fn parseLocation(r: json.Value, o: *const Options) error{ InvalidCoordinate, ConflictingClosures }!Location {
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
        const la = lat orelse return error.InvalidCoordinate;
        if (la < -90.0 or la > 90.0) return error.InvalidCoordinate;
        return defaultLocation(la, lon orelse return error.InvalidCoordinate, o);
    }
    const lat = json.getOptional(f64, r, "/lat") orelse return error.InvalidCoordinate;
    if (lat < -90.0 or lat > 90.0) return error.InvalidCoordinate;
    const lon_raw = json.getOptional(f64, r, "/lon") orelse return error.InvalidCoordinate;
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
    loc.minimum_inbound_reachability = json.getOptional(u32, r, "/minimum_inbound_reachability");
    loc.minimum_outbound_reachability = json.getOptional(u32, r, "/minimum_outbound_reachability");
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
    var exclude_closures: ?bool = null;
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
        exclude_closures = json.getOptional(bool, sf, "/exclude_closures");
    }
    loc.search_filter.exclude_steps = exclude_steps orelse (o.costing == .bicycle);
    if (o.ignore_closures) |ignore| {
        if (exclude_closures != null) return error.ConflictingClosures;
        loc.search_filter.exclude_closures = !ignore;
    } else loc.search_filter.exclude_closures = exclude_closures orelse true;
    loc.waiting_secs = json.get(f32, r, "/waiting", 0);
    return loc;
}

/// Valhalla's date and time syntax check for request options.
pub fn isIsoDateTime(s: []const u8) bool {
    return datetime.validRequest(s);
}

// ---------------------------------------------------------------------------
// Tests (cases from test/parse_request.cc for the fields in scope)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseText(arena: Allocator, action: Action, text: []const u8) !Result {
    const doc = try json.parse(arena, text);
    return fromJson(arena, doc, action);
}

// Ported from the error_request and api cases in test/gurka/test_recost.cc.
test "recostings keep ordered named profiles and reject invalid or duplicate costings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = (try parseText(a, .route,
        \\{"costing":"auto","recostings":[{"costing":"auto"},
        \\{"costing":"auto","name":"avoid_highways","use_highways":0.1},
        \\{"costing":"bicycle","name":"slower"},
        \\{"costing":"pedestrian","name":"slowest","walking_speed":2}]}
    )).ok.recostings;
    try testing.expectEqual(4, valid.len);
    try testing.expectEqualStrings("auto", valid[0].name);
    try testing.expectEqualStrings("avoid_highways", valid[1].name);
    try testing.expectEqual(.bicycle, valid[2].costing);
    try testing.expectEqual(@as(f32, 2), json.get(f32, valid[3].options, "/walking_speed", 0));
    for ([_]struct { items: []const u8, code: u16 }{
        .{ .items = "[{\"frosting\":\"chocolate\"}]", .code = 127 },
        .{ .items = "[{\"costing\":\"foo\"}]", .code = 125 },
        .{ .items = "[{\"name\":\"foo\"}]", .code = 127 },
        .{ .items = "[{\"costing\":\"auto\"},{\"costing\":\"auto\"}]", .code = 128 },
        .{ .items = "[{\"costing\":\"auto\",\"name\":\"same\"},{\"costing\":\"auto\",\"name\":\"same\"}]", .code = 128 },
    }) |case| {
        const body = try std.fmt.allocPrint(a, "{{\"costing\":\"auto\",\"locations\":[],\"recostings\":{s}}}", .{case.items});
        try testing.expectEqual(case.code, (try parseText(a, .route, body)).failure.code);
    }
}

test "request time modes attach dates to the selected locations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arrive = (try parseText(a, .route,
        \\{"costing":"auto","date_time":{"type":2,"value":"2026-01-03T06:17"},
        \\"locations":[{"lat":1,"lon":1,"date_time":"2026-01-02T18:00"},{"lat":2,"lon":2}]}
    )).ok;
    try testing.expectEqual(.arrive_by, arrive.date_time_type);
    try testing.expectEqualStrings("2026-01-02T18:00", arrive.locations[0].date_time.?);
    try testing.expectEqualStrings("2026-01-03T06:17", arrive.locations[1].date_time.?);
    const invariant = (try parseText(a, .route,
        \\{"date_time":{"type":3,"value":"current"},"locations":[{"lat":1,"lon":1},{"lat":2,"lon":2}]}
    )).ok;
    try testing.expectEqual(.invariant, invariant.date_time_type);
    for (invariant.locations) |location| try testing.expectEqualStrings("current", location.date_time.?);
    const transit = (try parseText(a, .route,
        \\{"costing":"multimodal","locations":[{"lat":1,"lon":1},{"lat":2,"lon":2}]}
    )).ok;
    try testing.expectEqual(.current, transit.date_time_type);
    try testing.expectEqualStrings("current", transit.locations[0].date_time.?);
    try testing.expectEqual(@as(?[]const u8, null), transit.locations[1].date_time);
    const ignored = (try parseText(a, .route,
        \\{"date_time":{"type":4294967295}}
    )).ok;
    try testing.expectEqual(.no_time, ignored.date_time_type);
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
    try testing.expectEqual(@as(u16, 162), (try parseText(a, .route, "{\"date_time\":{\"type\":1,\"value\":\"1900-02-01T10:00\"}}")).failure.code);
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

test "exclusion options follow deprecated alias precedence and closure presence" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const parsed = (try parseHttp(a, "/route", &.{},
        \\{"costing":"auto", "costing_options":{"auto":{"ignore_closures":true}},
        \\ "exclude_locations":[{}], "avoid_locations":[{"lat":2,"lon":190}],
        \\ "exclude_polygons":null, "avoid_polygons":[[],[[1,2],[1,3],[2,3]]]}
    )).ok;
    try testing.expectEqual(1, parsed.exclude_locations.len);
    try testing.expectEqual(@as(f64, -170), parsed.exclude_locations[0].lng);
    try testing.expect(!parsed.exclude_locations[0].search_filter.exclude_closures);
    try testing.expect(!parsed.filter_closures);
    try testing.expectEqual(1, parsed.exclude_polygons.len);
    try testing.expectEqual(3, parsed.exclude_polygons[0].segmentCount());
    const conflict = try parseHttp(a, "/route", &.{},
        \\{"costing":"auto", "costing_options":{"auto":{"ignore_closures":false}},
        \\ "locations":[{"lat":2,"lon":1,"search_filter":{"exclude_closures":false}}]}
    );
    try testing.expectEqual(143, conflict.failure.code);
    const invalid = try parseHttp(a, "/route", &.{},
        \\{"exclude_polygons":[[[1,2],[3]]]}
    );
    try testing.expectEqual(137, invalid.failure.code);
}

test "deprecated motor types normalize their flags and copy the alias options" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const shorter = (try parseHttp(arena, "/route", &.{},
        \\{"costing":"auto_shorter","costing_options":{"auto_shorter":{"fixed_speed":50,"shortest":false}}}
    )).ok;
    try testing.expectEqual(.auto, shorter.costing);
    try testing.expectEqualSlices(u16, &.{100}, shorter.warnings.items);
    try testing.expect(json.get(bool, shorter.costing_options.?, "/auto/shortest", false));
    try testing.expectEqual(50, json.get(u32, shorter.costing_options.?, "/auto/fixed_speed", 0));
    const fix = (try parseHttp(arena, "/route", &.{},
        \\{"costing":"auto_data_fix","costing_options":{"auto":{"fixed_speed":20}},
        \\ "locations":[{"lat":52.1,"lon":5.1},{"lat":52.2,"lon":5.2}]}
    )).ok;
    try testing.expectEqualSlices(u16, &.{102}, fix.warnings.items);
    try testing.expectEqual(20, json.get(u32, fix.costing_options.?, "/auto/fixed_speed", 0));
    for ([_][]const u8{ "/auto/ignore_restrictions", "/auto/ignore_oneways", "/auto/ignore_access", "/auto/ignore_closures" }) |path|
        try testing.expect(json.get(bool, fix.costing_options.?, path, false));
    try testing.expect(!fix.filter_closures);
}

/// Whether two parse results are the same in every field a handler reads.
pub fn resultsEqual(x: Result, y: Result) bool {
    switch (x) {
        .failure => |f| return y == .failure and y.failure.code == f.code,
        .ok => |a| {
            if (y != .ok) return false;
            const b = y.ok;
            if (a.action != b.action or a.format != b.format or a.units != b.units or a.directions_type != b.directions_type or
                a.costing != b.costing or a.shape_format != b.shape_format or a.range != b.range or
                a.height_precision != b.height_precision or a.verbose != b.verbose or a.filter_closures != b.filter_closures) return false;
            if (!std.meta.eql(a.resample_distance, b.resample_distance)) return false;
            if ((a.id == null) != (b.id == null) or (a.id != null and !std.mem.eql(u8, a.id.?, b.id.?))) return false;
            if ((a.encoded_polyline == null) != (b.encoded_polyline == null)) return false;
            if (!std.mem.eql(u16, a.warnings.items, b.warnings.items)) return false;
            if (a.shapeCount() != b.shapeCount() or a.locations.len != b.locations.len) return false;
            if (a.height_points != null or b.height_points != null) {
                for (0..a.shapeCount()) |i| if (!std.meta.eql(a.shapePoint(i), b.shapePoint(i))) return false;
            } else {
                for (a.shape, b.shape) |p, q| if (!std.meta.eql(p, q)) return false;
            }
            return true;
        },
    }
}

test "huge and infinite longitudes clamp like upstream's x86-64 build instead of crashing" {
    try testing.expectEqual(@as(f64, -170), circularClamp(190, -180, 180));
    try testing.expectEqual(@as(f64, 170), circularClamp(-190, -180, 180));
    // inf / 360 casts to INT_MIN, and inf - (INT_MIN * 360) stays inf.
    try testing.expect(std.math.isPositiveInf(circularClamp(std.math.inf(f64), -180, 180)));
    try testing.expect(std.math.isNegativeInf(circularClamp(-std.math.inf(f64), -180, 180)));
    try testing.expect(std.math.isNan(circularClamp(std.math.nan(f64), -180, 180)));
    _ = circularClamp(1e300, -180, 180);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try parseHttp(arena_state.allocator(), "/height", &.{}, "{\"shape\":[{\"lat\":1,\"lon\":1e400}]}");
}

test "the /height shape fast path parses exactly like the general parser" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(17);
    const random = prng.random();
    var fast_taken: usize = 0;
    var doc: std.ArrayList(u8) = .empty;
    for (0..4000) |round| {
        _ = arena_state.reset(.retain_capacity);
        doc = .empty;
        const ws = [_][]const u8{ "", " ", "\n\t", "  \r\n" };
        const sp = ws[random.uintLessThan(usize, ws.len)];
        try doc.print(a, "{{{s}", .{sp});
        // Optional members before the shape.
        if (random.boolean()) try doc.print(a, "\"range\":{s},{s}", .{ if (random.boolean()) "true" else "false", sp });
        if (random.uintLessThan(u8, 8) == 0) try doc.print(a, "\"encoded_polyline\":\"_p~iF~ps|U\",", .{});
        if (random.uintLessThan(u8, 10) == 0) try doc.print(a, "\"shape\":[{{\"lat\":1,\"lon\":2}}],", .{}); // duplicate key
        if (random.uintLessThan(u8, 12) == 0) try doc.print(a, "\"sh\\u0061pe\":[],", .{}); // escaped key
        try doc.print(a, "\"shape\"{s}:{s}[", .{ sp, sp });
        const n = 1 + random.uintLessThan(usize, 40);
        for (0..n) |k| {
            if (k > 0) try doc.print(a, ",{s}", .{sp});
            const lat = random.float(f64) * 180 - 90;
            const lon = random.float(f64) * 400 - 200; // some wrap
            var lat_s: []const u8 = try std.fmt.allocPrint(a, "{d:.6}", .{lat});
            var lon_s: []const u8 = try std.fmt.allocPrint(a, "{d:.5}", .{lon});
            switch (random.uintLessThan(u16, 600)) {
                0 => lat_s = "-0",
                1 => lat_s = "-0.0",
                2 => lon_s = "1.5e2",
                3 => lon_s = "-12E-1",
                4 => lat_s = "91",
                5 => lat_s = "\"45.5\"", // numeric string: general parser only
                6 => lon_s = "0.12345678901234567", // too many digits
                7 => lat_s = "01", // not JSON
                8 => lon_s = "1e400",
                9 => lat_s = "45",
                10 => lon_s = "-180.000000",
                else => {},
            }
            if (random.uintLessThan(u8, 30) == 0) {
                try doc.print(a, "{{\"lat\":{s},\"lon\":{s},\"type\":\"via\"}}", .{ lat_s, lon_s });
            } else if (random.boolean()) {
                try doc.print(a, "{{{s}\"lat\"{s}:{s}{s}{s},\"lon\":{s}{s}}}", .{ sp, sp, sp, lat_s, sp, lon_s, sp });
            } else {
                try doc.print(a, "{{\"lon\":{s},{s}\"lat\":{s}}}", .{ lon_s, sp, lat_s });
            }
        }
        try doc.print(a, "]{s}", .{sp});
        if (random.boolean()) try doc.print(a, ",\"height_precision\":{d},\"id\":\"r{d}\"", .{ random.uintLessThan(u8, 4), round });
        if (random.uintLessThan(u8, 6) == 0) try doc.print(a, ",\"resample_distance\":{d}", .{random.uintLessThan(u16, 100)});
        try doc.print(a, "}}{s}", .{sp});
        if (random.uintLessThan(u8, 20) == 0) doc.items.len -= 3; // truncated document
        const padded = try std.fmt.allocPrint(a, "{s}{s}", .{ doc.items, &@as([128]u8, @splat(' ')) }); // over the fast path's size floor
        const via_query = random.uintLessThan(u8, 5) == 0;
        const q: []const QueryParam = if (via_query) &.{.{ .key = "json", .value = padded }} else &.{};
        const body = if (via_query) "" else padded;
        const fast = try parseHttp(a, "/height", q, body);
        const ref = try parseHttpReference(a, "/height", q, body);
        if (!resultsEqual(fast, ref)) {
            std.debug.print("differs on: {s}\n", .{padded});
            return error.TestUnexpectedResult;
        }
        try testing.expect(resultsEqual(try parseHttpForHeight(a, "/height", q, body), ref));
        if (fastShape(a, padded) catch null) |_| fast_taken += 1;
    }
    // The generator mostly produces plain shapes, so the fast path is exercised.
    try testing.expect(fast_taken > 1000);
}

test "digit runs: SWAR and byte-at-a-time agree" {
    var prng = std.Random.DefaultPrng.init(8);
    const random = prng.random();
    var buf: [40]u8 = undefined;
    for (0..200_000) |_| {
        const len = random.uintLessThan(usize, 24);
        for (buf[0..len]) |*c| c.* = '0' + random.uintLessThan(u8, 10);
        const tail = [_]u8{ '.', 'e', ',', '}', ' ', '/', ':', 0, 0xff };
        const extra = random.uintLessThan(usize, 12);
        for (buf[len..][0..extra]) |*c| c.* = tail[random.uintLessThan(usize, tail.len)];
        const text = buf[0 .. len + extra];
        var got: u64 = 0;
        const n = digitRun(text, 0, &got);
        // Reference: count digits up to 16 and value of the first min(len,16)... runs past 15 are rejected by callers.
        var want: u64 = 0;
        var k: u32 = 0;
        while (k < len and k < 16) : (k += 1) want = want *% 10 +% (text[k] - '0');
        if (len < 16) {
            try testing.expectEqual(@as(u32, @intCast(len)), n);
            try testing.expectEqual(want, got);
        } else try testing.expect(n >= 16);
    }
}
