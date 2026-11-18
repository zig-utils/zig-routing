//! `zr diff`: replay one corpus against two servers and score how closely the
//! responses agree (P0.07). Every parity gate in docs/PLAN.md (Verification)
//! is evaluated through it.
//!
//!   zr diff A_URL B_URL --corpus FILE [--out report.json] [--worst DIR]
//!
//! Each request goes to A, then to B, over one keep-alive connection per
//! server per thread. The pair of responses is handed to every scorer that
//! applies; a scorer returns pass, fail (with a severity and the first
//! difference it found), skip, or a classification (a difference that is
//! explained rather than failed, such as a strictly cheaper route, which the
//! cost gates of P3 add). A gate passes when its pass rate over the requests it
//! applies to reaches its threshold; the exit status is non-zero otherwise.
//!
//! Scorers are plain entries in `default_scorers`; later phases append matrix
//! cells (gate E), isochrone IoU (F), trace edges (G) and cost parity (A to C).
//! The worst failures of each scorer are written as one-line corpora with both
//! responses beside them, so `zr diff A B --corpus worst/x.tsv` reproduces one.

const std = @import("std");
const io = @import("../infra/io.zig");
const json = @import("../api/json.zig");
const JsonWriter = @import("../api/json_writer.zig").Writer;
const bench = @import("bench.zig");
const geo = @import("../geo/root.zig");
const PointLL = geo.PointLL;
const Allocator = std.mem.Allocator;
const Value = json.Value;

// ---------------------------------------------------------------------------
// Corpus lines
// ---------------------------------------------------------------------------

pub const Line = struct {
    path: []const u8,
    /// Empty for a GET.
    body: []const u8,
    /// 1-based line number in the corpus file.
    number: usize,
};

/// Splits a corpus (`PATH<TAB>BODY` per line, or a bare body for
/// `default_endpoint`, as `zr bench` reads it). Slices point into `text`.
pub fn parseCorpus(gpa: Allocator, text: []const u8, default_endpoint: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (it.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var l: Line = .{ .path = default_endpoint, .body = line, .number = number };
        if (line[0] == '/') {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            l.path = line[0..tab];
            l.body = if (tab < line.len) line[tab + 1 ..] else "";
        }
        try lines.append(gpa, l);
    }
    if (lines.items.len == 0) return error.EmptyCorpus;
    return lines.toOwnedSlice(gpa);
}

fn renderRequest(gpa: Allocator, out: *std.ArrayList(u8), host: []const u8, line: Line) !void {
    out.clearRetainingCapacity();
    if (line.body.len == 0) {
        try out.print(gpa, "GET {s} HTTP/1.1\r\nHost: {s}\r\n\r\n", .{ line.path, host });
    } else {
        try out.print(gpa, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ line.path, host, line.body.len });
        try out.appendSlice(gpa, line.body);
    }
}

// ---------------------------------------------------------------------------
// Blocking keep-alive client
// ---------------------------------------------------------------------------

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const Client = struct {
    target: bench.Target,
    timeout_ms: u32,
    stream: ?io.Stream = null,
    poller: io.Poller,
    buf: std.ArrayList(u8) = .empty,
    req: std.ArrayList(u8) = .empty,

    pub fn init(target: bench.Target, timeout_ms: u32) !Client {
        return .{ .target = target, .timeout_ms = timeout_ms, .poller = try io.Poller.init() };
    }

    pub fn deinit(self: *Client, gpa: Allocator) void {
        self.disconnect();
        self.poller.deinit();
        self.buf.deinit(gpa);
        self.req.deinit(gpa);
    }

    fn disconnect(self: *Client) void {
        if (self.stream) |s| s.close();
        self.stream = null;
    }

    /// Sends one request and reads the whole response. The body stays valid
    /// until the next call. A reused connection the server has closed in the
    /// meantime is retried once on a fresh one.
    pub fn exchange(self: *Client, gpa: Allocator, line: Line) !Response {
        try renderRequest(gpa, &self.req, self.target.host, line);
        const reused = self.stream != null;
        return self.attempt(gpa) catch |e| {
            self.disconnect();
            if (!reused or e == error.Timeout) return e;
            return self.attempt(gpa) catch |e2| {
                self.disconnect();
                return e2;
            };
        };
    }

    fn attempt(self: *Client, gpa: Allocator) !Response {
        if (self.stream == null) self.stream = try io.Stream.connect(self.target.address);
        const s = self.stream.?;
        try s.writeAll(self.req.items);

        self.buf.clearRetainingCapacity();
        var head_end: ?usize = null;
        var total: ?usize = null;
        var status: u16 = 0;
        var close_after = false;
        while (total == null or self.buf.items.len < total.?) {
            try self.buf.ensureUnusedCapacity(gpa, 64 * 1024);
            try self.poller.arm(s.fd, 0, .read);
            var events: [1]io.Event = undefined;
            if ((try self.poller.wait(&events, self.timeout_ms)).len == 0) return error.Timeout;
            const n = try s.read(self.buf.unusedCapacitySlice());
            if (n == 0) return error.ConnectionClosed;
            self.buf.items.len += n;
            if (head_end == null) {
                head_end = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse continue;
                const head = self.buf.items[0..head_end.?];
                if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.BadResponse;
                status = std.fmt.parseInt(u16, head[9..12], 10) catch return error.BadResponse;
                var length: usize = 0;
                var hl = std.mem.splitSequence(u8, head, "\r\n");
                _ = hl.next();
                while (hl.next()) |h| {
                    const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                    const name = h[0..colon];
                    const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                    if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                        length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
                    } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                        close_after = std.ascii.eqlIgnoreCase(value, "close");
                    } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                        return error.ChunkedUnsupported;
                    }
                }
                total = head_end.? + 4 + length;
            }
        }
        if (close_after) self.disconnect();
        return .{ .status = status, .body = self.buf.items[head_end.? + 4 .. total.?] };
    }
};

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

pub const Side = struct {
    status: u16,
    body: []const u8,
    /// Parsed body, or null when it is not JSON.
    json: ?Value,
};

pub const Exchange = struct {
    path: []const u8,
    request: ?Value,
    a: Side,
    b: Side,

    fn bothOk(self: *const Exchange) bool {
        return self.a.status == 200 and self.b.status == 200 and self.a.json != null and self.b.json != null;
    }
};

pub const Verdict = union(enum) {
    skip,
    pass,
    fail: struct {
        /// Larger is worse; used to pick the worst offenders.
        severity: f64,
        /// The first difference, for the report.
        detail: []const u8,
    },
    /// A difference explained rather than failed (e.g. "cheaper"); counted
    /// apart and not against the gate.
    classified: []const u8,
};

pub const Scorer = struct {
    name: []const u8,
    /// The parity gate in docs/PLAN.md this scorer serves.
    gate: []const u8,
    /// Minimum pass rate over the requests the scorer applies to.
    min_rate: f64,
    score: *const fn (arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict,
};

pub const default_scorers = [_]Scorer{
    .{ .name = "status", .gate = "H", .min_rate = 1.0, .score = scoreStatus },
    .{ .name = "json-schema", .gate = "H", .min_rate = 1.0, .score = scoreSchema },
    .{ .name = "errors", .gate = "H", .min_rate = 1.0, .score = scoreErrors },
    .{ .name = "height-values", .gate = "H", .min_rate = 1.0, .score = scoreHeight },
    .{ .name = "route-legs", .gate = "D", .min_rate = 1.0, .score = scoreRouteLegs },
    .{ .name = "route-length", .gate = "D", .min_rate = 0.95, .score = scoreRouteLength },
    .{ .name = "route-time", .gate = "D", .min_rate = 0.95, .score = scoreRouteTime },
    .{ .name = "route-shape", .gate = "D", .min_rate = 0.95, .score = scoreRouteShape },
};

/// Gate D tolerances (docs/PLAN.md): distance within 0.5%, time within 1%,
/// shape overlap at least 0.98, overlap measured within 5 m.
pub const route_length_tolerance = 0.005;
pub const route_time_tolerance = 0.01;
pub const route_min_overlap = 0.98;
pub const overlap_tolerance_m = 5.0;

fn fail(arena: Allocator, severity: f64, comptime fmt: []const u8, args: anytype) Allocator.Error!Verdict {
    return .{ .fail = .{ .severity = severity, .detail = try std.fmt.allocPrint(arena, fmt, args) } };
}

fn scoreStatus(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    if (ex.a.status == ex.b.status) return .pass;
    return fail(arena, 1, "HTTP {d} vs {d}", .{ ex.a.status, ex.b.status });
}

/// String values that are enumerations in the API (compared by value), as
/// opposed to free text such as names and shapes (compared by type only).
const enum_keys = [_][]const u8{ "units", "language", "status", "travel_mode", "travel_type", "shape_format", "type", "side_of_street", "warnings" };

fn isEnumKey(key: []const u8) bool {
    for (enum_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn kindName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

/// Walks both trees in step. Returns the pointer and description of the first
/// structural difference: a key present on one side only, a value of another
/// type, or an enumeration value that differs. Arrays are compared element by
/// element up to the shorter length (lengths legitimately differ between two
/// routes; counts that matter have their own scorers).
fn firstSchemaDiff(arena: Allocator, a: Value, b: Value, path: *std.ArrayList(u8), key: []const u8) Allocator.Error!?[]const u8 {
    const ka = kindName(a);
    const kb = kindName(b);
    if (!std.mem.eql(u8, ka, kb)) return try std.fmt.allocPrint(arena, "{s}: {s} vs {s}", .{ path.items, ka, kb });
    switch (a) {
        .string => |sa| if (isEnumKey(key) and !std.mem.eql(u8, sa, b.string))
            return try std.fmt.allocPrint(arena, "{s}: \"{s}\" vs \"{s}\"", .{ path.items, sa, b.string }),
        .object => |oa| {
            const ob = b.object;
            for (oa.keys()) |k| if (ob.get(k) == null) return try std.fmt.allocPrint(arena, "{s}/{s}: only in A", .{ path.items, k });
            for (ob.keys()) |k| if (oa.get(k) == null) return try std.fmt.allocPrint(arena, "{s}/{s}: only in B", .{ path.items, k });
            for (oa.keys(), oa.values()) |k, va| {
                const len = path.items.len;
                try path.print(arena, "/{s}", .{k});
                if (try firstSchemaDiff(arena, va, ob.get(k).?, path, k)) |d| return d;
                path.items.len = len;
            }
        },
        .array => |aa| {
            const n = @min(aa.items.len, b.array.items.len);
            for (aa.items[0..n], b.array.items[0..n], 0..) |va, vb, i| {
                const len = path.items.len;
                try path.print(arena, "/{d}", .{i});
                if (try firstSchemaDiff(arena, va, vb, path, key)) |d| return d;
                path.items.len = len;
            }
        },
        else => {},
    }
    return null;
}

fn scoreSchema(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    const a = ex.a.json orelse return if (ex.b.json == null) .skip else fail(arena, 1, "A is not JSON", .{});
    const b = ex.b.json orelse return fail(arena, 1, "B is not JSON", .{});
    var path: std.ArrayList(u8) = .empty;
    if (try firstSchemaDiff(arena, a, b, &path, "")) |d| return .{ .fail = .{ .severity = 1, .detail = d } };
    return .pass;
}

fn scoreErrors(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    if (ex.a.status == 200 and ex.b.status == 200) return .skip;
    const a = ex.a.json orelse return fail(arena, 1, "A error body is not JSON", .{});
    const b = ex.b.json orelse return fail(arena, 1, "B error body is not JSON", .{});
    inline for (.{ "/error_code", "/status_code", "/status", "/error" }) |p| {
        const va = json.pointer(a, p);
        const vb = json.pointer(b, p);
        if ((va == null) != (vb == null) or (va != null and !valuesEqual(va.?, vb.?)))
            return fail(arena, 1, "{s}: {s} vs {s}", .{ p, try short(arena, va), try short(arena, vb) });
    }
    return .pass;
}

fn short(arena: Allocator, v: ?Value) Allocator.Error![]const u8 {
    const x = v orelse return "missing";
    return switch (x) {
        .string => |s| try std.fmt.allocPrint(arena, "\"{s}\"", .{s[0..@min(s.len, 80)]}),
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        else => kindName(x),
    };
}

fn numberOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Deep equality; numbers compare by value whatever their spelling.
pub fn valuesEqual(a: Value, b: Value) bool {
    if (numberOf(a)) |x| return if (numberOf(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!valuesEqual(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and for (x.keys(), x.values()) |k, v| {
            const w = b.object.get(k) orelse break false;
            if (!valuesEqual(v, w)) break false;
        } else true,
        else => false,
    };
}

/// Largest absolute numeric difference between two equally shaped trees, and
/// the pointer where it occurs; infinity when the shapes differ.
fn maxNumericDiff(a: Value, b: Value, path: *std.ArrayList(u8), arena: Allocator, worst: *f64, at: *[]const u8) Allocator.Error!void {
    if (numberOf(a)) |x| {
        const y = numberOf(b) orelse {
            worst.* = std.math.inf(f64);
            at.* = try arena.dupe(u8, path.items);
            return;
        };
        if (@abs(x - y) > worst.*) {
            worst.* = @abs(x - y);
            at.* = try arena.dupe(u8, path.items);
        }
        return;
    }
    switch (a) {
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) {
                worst.* = std.math.inf(f64);
                at.* = try arena.dupe(u8, path.items);
                return;
            }
            for (x.items, b.array.items, 0..) |p, q, i| {
                const len = path.items.len;
                try path.print(arena, "/{d}", .{i});
                try maxNumericDiff(p, q, path, arena, worst, at);
                path.items.len = len;
            }
        },
        .object => |x| for (x.keys(), x.values()) |k, v| {
            const len = path.items.len;
            try path.print(arena, "/{s}", .{k});
            if (b == .object) if (b.object.get(k)) |w| try maxNumericDiff(v, w, path, arena, worst, at);
            path.items.len = len;
        },
        else => {},
    }
}

fn scoreHeight(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    if (!std.mem.eql(u8, ex.path, "/height") or !ex.bothOk()) return .skip;
    if (valuesEqual(ex.a.json.?, ex.b.json.?)) return .pass;
    var path: std.ArrayList(u8) = .empty;
    var worst: f64 = 0;
    var at: []const u8 = "";
    try maxNumericDiff(ex.a.json.?, ex.b.json.?, &path, arena, &worst, &at);
    if (worst == 0) return fail(arena, std.math.inf(f64), "values differ outside numbers", .{});
    if (std.math.isInf(worst)) return fail(arena, worst, "{s}: a number on one side only", .{at});
    return fail(arena, worst, "{s}: differs by {d}", .{ at, worst });
}

fn isRoute(ex: *const Exchange) bool {
    return std.mem.eql(u8, ex.path, "/route") and ex.bothOk() and json.pointer(ex.a.json.?, "/trip") != null and json.pointer(ex.b.json.?, "/trip") != null;
}

fn scoreRouteLegs(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    if (!isRoute(ex)) return .skip;
    inline for (.{ "/trip/legs", "/trip/locations" }) |p| {
        const na = if (json.array(ex.a.json.?, p)) |x| x.len else 0;
        const nb = if (json.array(ex.b.json.?, p)) |x| x.len else 0;
        if (na != nb) return fail(arena, @floatFromInt(@max(na, nb) - @min(na, nb)), "{s}: {d} vs {d}", .{ p, na, nb });
    }
    return .pass;
}

fn relativeDiff(a: f64, b: f64) f64 {
    const m = @max(@abs(a), @abs(b));
    return if (m == 0) 0 else @abs(a - b) / m;
}

fn scoreSummary(arena: Allocator, ex: *const Exchange, comptime p: []const u8, tolerance: f64) Allocator.Error!Verdict {
    if (!isRoute(ex)) return .skip;
    const a = numberOf(json.pointer(ex.a.json.?, p) orelse return fail(arena, 1, "A has no {s}", .{p})) orelse return fail(arena, 1, "A {s} not a number", .{p});
    const b = numberOf(json.pointer(ex.b.json.?, p) orelse return fail(arena, 1, "B has no {s}", .{p})) orelse return fail(arena, 1, "B {s} not a number", .{p});
    const d = relativeDiff(a, b);
    if (d <= tolerance) return .pass;
    return fail(arena, d, "{s}: {d} vs {d} ({d:.2}%)", .{ p, a, b, d * 100 });
}

fn scoreRouteLength(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    return scoreSummary(arena, ex, "/trip/summary/length", route_length_tolerance);
}

fn scoreRouteTime(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    return scoreSummary(arena, ex, "/trip/summary/time", route_time_tolerance);
}

/// The whole route as points: every leg's shape decoded per the request's
/// `shape_format` (polyline6 by default, polyline5, or GeoJSON), joined.
fn routeShape(arena: Allocator, response: Value, request: ?Value) !?[]PointLL {
    const format = if (request) |r| json.get([]const u8, r, "/shape_format", "polyline6") else "polyline6";
    if (std.mem.eql(u8, format, "no_shape")) return null;
    const legs = json.array(response, "/trip/legs") orelse return null;
    var pts: std.ArrayList(PointLL) = .empty;
    for (legs) |leg| {
        const shape = json.pointer(leg, "/shape") orelse continue;
        switch (shape) {
            .string => |s| {
                const decoded = if (std.mem.eql(u8, format, "polyline5"))
                    try geo.polyline.decodeAlloc(arena, .polyline, 5, s)
                else
                    try geo.polyline.decodeAlloc(arena, .polyline, 6, s);
                try pts.appendSlice(arena, decoded);
            },
            .object => {
                const coords = json.array(shape, "/coordinates") orelse continue;
                for (coords) |c| {
                    if (c != .array or c.array.items.len < 2) continue;
                    try pts.append(arena, PointLL.init(numberOf(c.array.items[0]) orelse 0, numberOf(c.array.items[1]) orelse 0));
                }
            },
            else => {},
        }
    }
    return try pts.toOwnedSlice(arena);
}

/// Spatial hash of a polyline's segments, for "is this point within
/// `tolerance_m` of the line" in roughly constant time.
const SegmentGrid = struct {
    const cell_deg: f64 = 0.001; // ~111 m north-south
    pts: []const PointLL,
    cells: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,

    fn key(lng: f64, lat: f64) u64 {
        const x: i64 = @intFromFloat(@floor((lng + 180.0) / cell_deg));
        const y: i64 = @intFromFloat(@floor((lat + 90.0) / cell_deg));
        return (@as(u64, @bitCast(y)) << 32) | (@as(u64, @bitCast(x)) & 0xffff_ffff);
    }

    fn build(arena: Allocator, pts: []const PointLL) Allocator.Error!SegmentGrid {
        var g: SegmentGrid = .{ .pts = pts };
        if (pts.len < 2) return g;
        for (pts[0 .. pts.len - 1], pts[1..], 0..) |a, b, i| {
            // Walk the segment in sub-cell steps and register the 3x3 block
            // around each step, which covers the tolerance (5 m << a cell).
            const steps: usize = @intFromFloat(@ceil(@max(@abs(b.lng - a.lng), @abs(b.lat - a.lat)) / (cell_deg / 2.0)) + 1);
            var last: ?u64 = null;
            for (0..steps + 1) |s| {
                const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
                const lng = a.lng + (b.lng - a.lng) * t;
                const lat = a.lat + (b.lat - a.lat) * t;
                const center = key(lng, lat);
                if (center == last) continue;
                last = center;
                for ([_]f64{ -1, 0, 1 }) |dy| for ([_]f64{ -1, 0, 1 }) |dx| {
                    const gop = try g.cells.getOrPut(arena, key(lng + dx * cell_deg, lat + dy * cell_deg));
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    const list = gop.value_ptr;
                    if (list.items.len == 0 or list.items[list.items.len - 1] != i) try list.append(arena, @intCast(i));
                };
            }
        }
        return g;
    }

    fn near(self: *const SegmentGrid, p: PointLL, tolerance_m: f64) bool {
        if (self.pts.len == 1) return self.pts[0].distance(p) <= tolerance_m;
        const list = self.cells.get(key(p.lng, p.lat)) orelse return false;
        const t2 = tolerance_m * tolerance_m;
        for (list.items) |i| {
            if (geo.line.segmentDistanceSquared(self.pts[i], self.pts[i + 1], p).distance_sq <= t2) return true;
        }
        return false;
    }
};

/// Fraction of `a`'s length that lies within `tolerance_m` of `b`, measured
/// on pieces of at most 2 m.
fn sharedFraction(a: []const PointLL, b: *const SegmentGrid, tolerance_m: f64) f64 {
    var total: f64 = 0;
    var shared: f64 = 0;
    if (a.len < 2) return if (a.len == 1 and b.near(a[0], tolerance_m)) 1 else 0;
    for (a[0 .. a.len - 1], a[1..]) |p, q| {
        const len = p.distance(q);
        if (len == 0) continue;
        const pieces: usize = @intFromFloat(@ceil(len / 2.0));
        const piece = len / @as(f64, @floatFromInt(pieces));
        for (0..pieces) |k| {
            const mid = p.pointAlongSegment(q, (@as(f64, @floatFromInt(k)) + 0.5) / @as(f64, @floatFromInt(pieces)));
            total += piece;
            if (b.near(mid, tolerance_m)) shared += piece;
        }
    }
    return if (total == 0) 1 else shared / total;
}

/// Shape overlap of two routes: the smaller of the two shared-length
/// fractions, so a detour on either side lowers it.
pub fn shapeOverlap(arena: Allocator, a: []const PointLL, b: []const PointLL, tolerance_m: f64) Allocator.Error!f64 {
    const ga = try SegmentGrid.build(arena, a);
    const gb = try SegmentGrid.build(arena, b);
    return @min(sharedFraction(a, &gb, tolerance_m), sharedFraction(b, &ga, tolerance_m));
}

fn scoreRouteShape(arena: Allocator, ex: *const Exchange) Allocator.Error!Verdict {
    if (!isRoute(ex)) return .skip;
    const a = routeShape(arena, ex.a.json.?, ex.request) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, 1, "A shape does not decode", .{}),
    } orelse return .skip;
    const b = routeShape(arena, ex.b.json.?, ex.request) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, 1, "B shape does not decode", .{}),
    } orelse return .skip;
    const overlap = try shapeOverlap(arena, a, b, overlap_tolerance_m);
    if (overlap >= route_min_overlap) return .pass;
    return fail(arena, 1 - overlap, "shape overlap {d:.4}", .{overlap});
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

pub const Options = struct {
    a: bench.Target,
    b: bench.Target,
    threads: usize = 4,
    timeout_ms: u32 = 60_000,
    /// Worst failures kept per scorer.
    worst: usize = 10,
};

pub const Offender = struct {
    line: usize,
    severity: f64,
    detail: []const u8,
    a_status: u16,
    b_status: u16,
    a_body: []const u8,
    b_body: []const u8,
};

pub const Tally = struct {
    applied: u64 = 0,
    passed: u64 = 0,
    failed: u64 = 0,
    classified: std.StringArrayHashMapUnmanaged(u64) = .empty,
    /// Sorted worst first, at most Options.worst.
    worst: std.ArrayList(Offender) = .empty,

    pub fn rate(self: *const Tally) f64 {
        const counted = self.passed + self.failed;
        return if (counted == 0) 1 else @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(counted));
    }

    fn offer(self: *Tally, gpa: Allocator, keep: usize, o: Offender) !void {
        if (keep == 0) return;
        if (self.worst.items.len == keep and o.severity <= self.worst.items[keep - 1].severity) return;
        const owned: Offender = .{
            .line = o.line,
            .severity = o.severity,
            .detail = try gpa.dupe(u8, o.detail),
            .a_status = o.a_status,
            .b_status = o.b_status,
            .a_body = try gpa.dupe(u8, o.a_body),
            .b_body = try gpa.dupe(u8, o.b_body),
        };
        var at: usize = self.worst.items.len;
        while (at > 0 and (self.worst.items[at - 1].severity < owned.severity or
            (self.worst.items[at - 1].severity == owned.severity and self.worst.items[at - 1].line > owned.line))) at -= 1;
        try self.worst.insert(gpa, at, owned);
        if (self.worst.items.len > keep) freeOffender(gpa, self.worst.pop().?);
    }

    fn deinit(self: *Tally, gpa: Allocator) void {
        for (self.worst.items) |o| freeOffender(gpa, o);
        self.worst.deinit(gpa);
        for (self.classified.keys()) |k| gpa.free(k);
        self.classified.deinit(gpa);
    }

    fn merge(self: *Tally, gpa: Allocator, keep: usize, other: *const Tally) !void {
        self.applied += other.applied;
        self.passed += other.passed;
        self.failed += other.failed;
        for (other.classified.keys(), other.classified.values()) |k, v| {
            const gop = try self.classified.getOrPut(gpa, k);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, k);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += v;
        }
        for (other.worst.items) |o| try self.offer(gpa, keep, o);
    }
};

fn freeOffender(gpa: Allocator, o: Offender) void {
    gpa.free(o.detail);
    gpa.free(o.a_body);
    gpa.free(o.b_body);
}

pub const Report = struct {
    requests: u64 = 0,
    /// Requests where either server could not be reached or timed out; they
    /// are not scored and fail the run.
    transport_errors: u64 = 0,
    first_transport_error: ?usize = null,
    scorers: []const Scorer,
    tallies: []Tally,
    elapsed_ns: u64 = 0,

    pub fn deinit(self: *Report, gpa: Allocator) void {
        for (self.tallies) |*t| t.deinit(gpa);
        gpa.free(self.tallies);
    }

    /// True when every gate meets its threshold and no request was lost.
    pub fn ok(self: *const Report) bool {
        if (self.transport_errors != 0) return false;
        for (self.scorers, self.tallies) |s, t| if (t.rate() < s.min_rate) return false;
        return true;
    }

    fn init(gpa: Allocator, scorers: []const Scorer) !Report {
        const tallies = try gpa.alloc(Tally, scorers.len);
        for (tallies) |*t| t.* = .{};
        return .{ .scorers = scorers, .tallies = tallies };
    }
};

/// Scores one pair of responses into `report` (one thread's report).
pub fn scorePair(gpa: Allocator, arena: Allocator, report: *Report, keep: usize, line: Line, a: Response, b: Response) !void {
    const ex: Exchange = .{
        .path = line.path,
        .request = if (line.body.len > 0) json.parse(arena, line.body) catch null else null,
        .a = .{ .status = a.status, .body = a.body, .json = json.parse(arena, a.body) catch null },
        .b = .{ .status = b.status, .body = b.body, .json = json.parse(arena, b.body) catch null },
    };
    for (report.scorers, report.tallies) |s, *t| {
        switch (try s.score(arena, &ex)) {
            .skip => continue,
            .pass => t.passed += 1,
            .fail => |f| {
                t.failed += 1;
                try t.offer(gpa, keep, .{ .line = line.number, .severity = f.severity, .detail = f.detail, .a_status = a.status, .b_status = b.status, .a_body = a.body, .b_body = b.body });
            },
            .classified => |cause| {
                const gop = try t.classified.getOrPut(gpa, cause);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try gpa.dupe(u8, cause);
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            },
        }
        t.applied += 1;
    }
}

const Shared = struct {
    gpa: Allocator,
    opts: Options,
    lines: []const Line,
    next: std.atomic.Value(usize) = .init(0),
    scorers: []const Scorer,
};

const Worker = struct {
    shared: *Shared,
    report: Report,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        self.loop() catch |e| {
            self.err = e;
        };
    }

    fn loop(self: *Worker) !void {
        const gpa = self.shared.gpa;
        var a = try Client.init(self.shared.opts.a, self.shared.opts.timeout_ms);
        defer a.deinit(gpa);
        var b = try Client.init(self.shared.opts.b, self.shared.opts.timeout_ms);
        defer b.deinit(gpa);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        while (true) {
            const i = self.shared.next.fetchAdd(1, .monotonic);
            if (i >= self.shared.lines.len) return;
            const line = self.shared.lines[i];
            self.report.requests += 1;
            _ = arena_state.reset(.retain_capacity);
            const ra = a.exchange(gpa, line) catch {
                self.transport(line);
                continue;
            };
            const rb = b.exchange(gpa, line) catch {
                self.transport(line);
                continue;
            };
            try scorePair(gpa, arena_state.allocator(), &self.report, self.shared.opts.worst, line, ra, rb);
        }
    }

    fn transport(self: *Worker, line: Line) void {
        self.report.transport_errors += 1;
        if (self.report.first_transport_error == null or line.number < self.report.first_transport_error.?)
            self.report.first_transport_error = line.number;
    }
};

pub fn run(gpa: Allocator, opts: Options, lines: []const Line, scorers: []const Scorer) !Report {
    var shared: Shared = .{ .gpa = gpa, .opts = opts, .lines = lines, .scorers = scorers };
    const n = @max(1, @min(opts.threads, lines.len));
    const workers = try gpa.alloc(Worker, n);
    defer gpa.free(workers);
    var started: usize = 0;
    defer for (workers[0..started]) |*w| w.report.deinit(gpa);
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);

    const timer = io.Timer.start();
    for (workers, threads) |*w, *t| {
        w.* = .{ .shared = &shared, .report = try Report.init(gpa, scorers) };
        started += 1;
        t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (threads) |t| t.join();

    var total = try Report.init(gpa, scorers);
    errdefer total.deinit(gpa);
    for (workers) |*w| {
        if (w.err) |e| return e;
        total.requests += w.report.requests;
        total.transport_errors += w.report.transport_errors;
        if (w.report.first_transport_error) |l| {
            if (total.first_transport_error == null or l < total.first_transport_error.?) total.first_transport_error = l;
        }
        for (total.tallies, w.report.tallies) |*t, *o| try t.merge(gpa, opts.worst, o);
    }
    total.elapsed_ns = timer.read();
    return total;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

pub const Meta = struct {
    a: []const u8,
    b: []const u8,
    corpus_path: []const u8,
    corpus_hash: u64,
    label: []const u8 = "",
};

pub fn writeSummary(gpa: Allocator, out: *std.ArrayList(u8), r: *const Report) !void {
    try out.print(gpa, "{d} requests in {d:.1}s, {d} transport errors\n", .{ r.requests, @as(f64, @floatFromInt(r.elapsed_ns)) / std.time.ns_per_s, r.transport_errors });
    try out.print(gpa, "{s:<16} {s:>4} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}  {s}\n", .{ "scorer", "gate", "applied", "passed", "failed", "rate", "needs", "" });
    for (r.scorers, r.tallies) |s, t| {
        var rate_buf: [16]u8 = undefined;
        var need_buf: [16]u8 = undefined;
        const rate = std.fmt.bufPrint(&rate_buf, "{d:.3}%", .{t.rate() * 100}) catch unreachable;
        const need = std.fmt.bufPrint(&need_buf, "{d:.1}%", .{s.min_rate * 100}) catch unreachable;
        const verdict = if (t.applied == 0) "n/a" else if (t.rate() >= s.min_rate) "ok" else "FAIL";
        try out.print(gpa, "{s:<16} {s:>4} {d:>9} {d:>9} {d:>9} {s:>9} {s:>9}  {s}\n", .{ s.name, s.gate, t.applied, t.passed, t.failed, rate, need, verdict });
        if (t.worst.items.len > 0 and t.rate() < 1) {
            const w = t.worst.items[0];
            try out.print(gpa, "    worst: line {d}: {s}\n", .{ w.line, w.detail });
        }
    }
    try out.print(gpa, "{s}\n", .{if (r.ok()) "PASS" else "FAIL"});
}

pub fn writeReport(gpa: Allocator, out: *std.ArrayList(u8), meta: Meta, r: *const Report) !void {
    var w = JsonWriter.init(gpa, out);
    w.setPrecision(6);
    try w.beginObject();
    try w.field("tool", "zr diff");
    try w.field("a", meta.a);
    try w.field("b", meta.b);
    try w.field("label", meta.label);
    try w.beginObjectField("corpus");
    try w.field("path", meta.corpus_path);
    var hash_buf: [16]u8 = undefined;
    try w.field("hash", std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{meta.corpus_hash}) catch unreachable);
    try w.endObject();
    try w.field("requests", r.requests);
    try w.field("transport_errors", r.transport_errors);
    try w.field("elapsed_s", @as(f64, @floatFromInt(r.elapsed_ns)) / std.time.ns_per_s);
    try w.field("pass", r.ok());
    try w.beginArrayField("scorers");
    for (r.scorers, r.tallies) |s, t| {
        try w.beginObject();
        try w.field("name", s.name);
        try w.field("gate", s.gate);
        try w.field("min_rate", s.min_rate);
        try w.field("applied", t.applied);
        try w.field("passed", t.passed);
        try w.field("failed", t.failed);
        try w.field("rate", t.rate());
        try w.field("ok", t.rate() >= s.min_rate);
        try w.beginObjectField("classified");
        for (t.classified.keys(), t.classified.values()) |k, v| {
            try w.key(k);
            try w.uint(v);
        }
        try w.endObject();
        try w.beginArrayField("worst");
        for (t.worst.items) |o| {
            try w.beginObject();
            try w.field("line", @as(u64, o.line));
            try w.field("severity", if (std.math.isInf(o.severity)) 1e300 else o.severity);
            try w.field("detail", o.detail);
            try w.field("a_status", @as(u64, o.a_status));
            try w.field("b_status", @as(u64, o.b_status));
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

/// Writes each scorer's worst offenders to `dir`: `<scorer>-<line>.tsv` (a
/// one-line corpus that reproduces it) and the two responses beside it.
pub fn writeWorst(gpa: Allocator, dir: []const u8, r: *const Report, lines: []const Line) !usize {
    var written: usize = 0;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (r.scorers, r.tallies) |s, t| for (t.worst.items) |o| {
        const line = for (lines) |l| {
            if (l.number == o.line) break l;
        } else continue;
        body.clearRetainingCapacity();
        try body.print(gpa, "{s}\t{s}\n", .{ line.path, line.body });
        path.clearRetainingCapacity();
        try path.print(gpa, "{s}/{s}-{d}.tsv", .{ dir, s.name, o.line });
        try io.writeFile(path.items, body.items);
        path.clearRetainingCapacity();
        try path.print(gpa, "{s}/{s}-{d}.a.json", .{ dir, s.name, o.line });
        try io.writeFile(path.items, o.a_body);
        path.clearRetainingCapacity();
        try path.print(gpa, "{s}/{s}-{d}.b.json", .{ dir, s.name, o.line });
        try io.writeFile(path.items, o.b_body);
        written += 1;
    };
    return written;
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

pub const usage =
    \\usage: zr diff A_URL B_URL --corpus FILE [options]
    \\
    \\  --corpus FILE     one request per line: PATH<TAB>BODY, or a body for --endpoint
    \\  --endpoint PATH   path for lines without one (default /route)
    \\  --threads N       requests in flight (default 4)
    \\  --timeout T       per-response timeout, e.g. 30s (default 60s)
    \\  --out FILE        write the JSON report here
    \\  --worst DIR       write each scorer's worst failures here (existing directory)
    \\  --keep N          worst failures kept per scorer (default 10)
    \\  --label TEXT      recorded in the report
    \\
    \\Exits 1 when a gate is below its threshold or a request got no answer.
    \\
;

/// Entry point for `zr diff`; `args` excludes the program and "diff".
/// Returns whether every gate passed.
pub fn main(gpa: Allocator, args: []const []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (args.len < 2 or args[0].len == 0 or args[0][0] == '-' or args[1].len == 0 or args[1][0] == '-') return usageError();

    var opts: Options = .{ .a = try bench.parseTarget(args[0]), .b = try bench.parseTarget(args[1]) };
    var meta: Meta = .{ .a = args[0], .b = args[1], .corpus_path = "", .corpus_hash = 0 };
    var endpoint: []const u8 = "/route";
    var out_path: ?[]const u8 = null;
    var worst_dir: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return usageError();
        const flag = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, flag, "--corpus")) {
            meta.corpus_path = v;
        } else if (std.mem.eql(u8, flag, "--endpoint")) {
            endpoint = v;
        } else if (std.mem.eql(u8, flag, "--threads")) {
            opts.threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, flag, "--timeout")) {
            opts.timeout_ms = @intCast(try bench.parseDuration(v) / std.time.ns_per_ms);
        } else if (std.mem.eql(u8, flag, "--out")) {
            out_path = v;
        } else if (std.mem.eql(u8, flag, "--worst")) {
            worst_dir = v;
        } else if (std.mem.eql(u8, flag, "--keep")) {
            opts.worst = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, flag, "--label")) {
            meta.label = v;
        } else {
            std.debug.print("unknown option {s}\n", .{flag});
            return usageError();
        }
    }
    if (meta.corpus_path.len == 0) return usageError();

    const text = try io.readFileAlloc(arena, meta.corpus_path, 4 << 30);
    meta.corpus_hash = std.hash.Wyhash.hash(0, text);
    const lines = try parseCorpus(arena, text, endpoint);

    io.installTerminationHandler();
    var report = try run(gpa, opts, lines, &default_scorers);
    defer report.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    try writeSummary(arena, &out, &report);
    if (report.first_transport_error) |l| try out.print(arena, "first transport error at line {d}\n", .{l});
    if (worst_dir) |dir| {
        const n = try writeWorst(gpa, dir, &report, lines);
        try out.print(arena, "wrote {d} worst cases to {s}\n", .{ n, dir });
    }
    std.debug.print("{s}", .{out.items});
    if (out_path) |path| {
        var file_bytes: std.ArrayList(u8) = .empty;
        try writeReport(arena, &file_bytes, meta, &report);
        try file_bytes.append(arena, '\n');
        try io.writeFile(path, file_bytes.items);
    }
    return report.ok();
}

fn usageError() error{InvalidArgument} {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgument;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const http = @import("../server/http.zig");

fn scoreBodies(path: []const u8, request: []const u8, a_status: u16, a: []const u8, b_status: u16, b: []const u8) !Report {
    var report = try Report.init(testing.allocator, &default_scorers);
    errdefer report.deinit(testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try scorePair(testing.allocator, arena_state.allocator(), &report, 3, .{ .path = path, .body = request, .number = 7 }, .{ .status = a_status, .body = a }, .{ .status = b_status, .body = b });
    return report;
}

fn tally(r: *const Report, name: []const u8) Tally {
    for (r.scorers, r.tallies) |s, t| if (std.mem.eql(u8, s.name, name)) return t;
    unreachable;
}

test "corpus lines keep their numbers" {
    const lines = try parseCorpus(testing.allocator, "# c\n/height\t{\"range\":true}\n\n{\"costing\":\"auto\"}\n/status\n", "/route");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("/height", lines[0].path);
    try testing.expectEqual(@as(usize, 2), lines[0].number);
    try testing.expectEqualStrings("/route", lines[1].path);
    try testing.expectEqual(@as(usize, 4), lines[1].number);
    try testing.expectEqualStrings("", lines[2].body);
}

test "identical height responses pass every applicable gate" {
    const body = "{\"shape\":[{\"lat\":47.1,\"lon\":9.5}],\"height\":[512,null]}";
    var r = try scoreBodies("/height", "{}", 200, body, 200, body);
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok());
    try testing.expectEqual(@as(u64, 1), tally(&r, "height-values").passed);
    try testing.expectEqual(@as(u64, 0), tally(&r, "route-shape").applied);
    try testing.expectEqual(@as(u64, 0), tally(&r, "errors").applied);
}

test "a changed height is caught with its size and place" {
    var r = try scoreBodies("/height", "{}", 200, "{\"height\":[512,513,514]}", 200, "{\"height\":[512,519,514.0]}");
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok());
    const t = tally(&r, "height-values");
    try testing.expectEqual(@as(u64, 1), t.failed);
    try testing.expectEqual(@as(f64, 6), t.worst.items[0].severity);
    try testing.expectEqualStrings("/height/1: differs by 6", t.worst.items[0].detail);
    try testing.expectEqual(@as(usize, 7), t.worst.items[0].line);
    // The schema still agrees: only the value moved.
    try testing.expectEqual(@as(u64, 1), tally(&r, "json-schema").passed);
}

test "a dropped key and a changed enum fail the schema gate" {
    var r = try scoreBodies("/route", "{}", 200, "{\"trip\":{\"units\":\"kilometers\",\"status\":0}}", 200, "{\"trip\":{\"units\":\"kilometers\"}}");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("/trip/status: only in A", tally(&r, "json-schema").worst.items[0].detail);
    var r2 = try scoreBodies("/route", "{}", 200, "{\"trip\":{\"units\":\"kilometers\",\"name\":\"a\"}}", 200, "{\"trip\":{\"units\":\"miles\",\"name\":\"b\"}}");
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("/trip/units: \"kilometers\" vs \"miles\"", tally(&r2, "json-schema").worst.items[0].detail);
    var r3 = try scoreBodies("/route", "{}", 200, "{\"x\":[1,\"s\"]}", 200, "{\"x\":[2,3]}");
    defer r3.deinit(testing.allocator);
    try testing.expectEqualStrings("/x/1: string vs number", tally(&r3, "json-schema").worst.items[0].detail);
}

test "error responses compare codes and statuses" {
    const e442 = "{\"error_code\":442,\"error\":\"No path could be found for input\",\"status_code\":400,\"status\":\"Bad Request\"}";
    var same = try scoreBodies("/route", "{}", 400, e442, 400, e442);
    defer same.deinit(testing.allocator);
    try testing.expect(same.ok());
    try testing.expectEqual(@as(u64, 1), tally(&same, "errors").passed);
    var other = try scoreBodies("/route", "{}", 400, e442, 400, "{\"error_code\":171,\"error\":\"No suitable edges near location\",\"status_code\":400,\"status\":\"Bad Request\"}");
    defer other.deinit(testing.allocator);
    try testing.expectEqualStrings("/error_code: 442 vs 171", tally(&other, "errors").worst.items[0].detail);
    var status = try scoreBodies("/route", "{}", 200, "{}", 400, e442);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), tally(&status, "status").failed);
}

fn routeBody(gpa: Allocator, pts: []const PointLL, length: f64, time: f64) ![]u8 {
    const shape = try geo.polyline.encodeAlloc(gpa, .polyline, 6, pts);
    defer gpa.free(shape);
    return std.fmt.allocPrint(gpa, "{{\"trip\":{{\"locations\":[{{}},{{}}],\"legs\":[{{\"shape\":\"{s}\"}}],\"summary\":{{\"length\":{d},\"time\":{d}}},\"units\":\"kilometers\"}}}}", .{ shape, length, time });
}

test "route gates: tolerances, leg counts and shape overlap" {
    const gpa = testing.allocator;
    const straight = [_]PointLL{ .init(9.50, 47.10), .init(9.51, 47.10), .init(9.52, 47.10) };
    // Same start and end, but a detour north through the middle.
    const detour = [_]PointLL{ .init(9.50, 47.10), .init(9.505, 47.11), .init(9.515, 47.11), .init(9.52, 47.10) };
    // The straight line drawn with different vertices: same geometry.
    const resampled = [_]PointLL{ .init(9.50, 47.10), .init(9.5033, 47.10), .init(9.512, 47.10), .init(9.52, 47.10) };
    const a = try routeBody(gpa, &straight, 1.517, 1200);
    defer gpa.free(a);
    const b = try routeBody(gpa, &resampled, 1.519, 1205);
    defer gpa.free(b);
    const c = try routeBody(gpa, &detour, 2.4, 1900);
    defer gpa.free(c);

    var same = try scoreBodies("/route", "{}", 200, a, 200, b);
    defer same.deinit(gpa);
    try testing.expect(same.ok());
    try testing.expectEqual(@as(u64, 1), tally(&same, "route-shape").passed);
    try testing.expectEqual(@as(u64, 1), tally(&same, "route-length").passed);

    var other = try scoreBodies("/route", "{}", 200, a, 200, c);
    defer other.deinit(gpa);
    try testing.expectEqual(@as(u64, 1), tally(&other, "route-shape").failed);
    try testing.expectEqual(@as(u64, 1), tally(&other, "route-length").failed);
    try testing.expectEqual(@as(u64, 1), tally(&other, "route-time").failed);
    try testing.expectEqual(@as(u64, 1), tally(&other, "route-legs").passed);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // The detour leaves at the first point and rejoins at the last: only the
    // few metres around the shared ends count.
    const overlap = try shapeOverlap(arena_state.allocator(), &straight, &detour, overlap_tolerance_m);
    try testing.expect(overlap < 0.02);
    // Half the line shared: the straight line against its own first half.
    const half = try shapeOverlap(arena_state.allocator(), &straight, straight[0..2], overlap_tolerance_m);
    try testing.expect(half > 0.49 and half < 0.51);
    try testing.expectEqual(@as(f64, 1), try shapeOverlap(arena_state.allocator(), &straight, &resampled, overlap_tolerance_m));
}

test "worst offenders keep the largest severities in order" {
    var t: Tally = .{};
    defer t.deinit(testing.allocator);
    for ([_]f64{ 3, 9, 1, 9, 5 }, 0..) |sev, i| try t.offer(testing.allocator, 3, .{ .line = i + 1, .severity = sev, .detail = "d", .a_status = 200, .b_status = 200, .a_body = "a", .b_body = "b" });
    try testing.expectEqual(@as(usize, 3), t.worst.items.len);
    try testing.expectEqual(@as(usize, 2), t.worst.items[0].line);
    try testing.expectEqual(@as(usize, 4), t.worst.items[1].line);
    try testing.expectEqual(@as(usize, 5), t.worst.items[2].line);
}

/// Answers /height with a fixed body; with `perturb`, line 3's height differs.
const Fixture = struct {
    perturb: bool,
    fn handle(ctx: *anyopaque, _: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        const third = std.mem.eql(u8, req.body, "{\"id\":3}");
        const h: u32 = if (self.perturb and third) 101 else 100;
        res.body.print(res.gpa, "{{\"height\":[{d}]}}", .{h}) catch {};
    }
};

test "two live servers: identical answers pass, a perturbed one is caught" {
    var fa: Fixture = .{ .perturb = false };
    var fb: Fixture = .{ .perturb = true };
    var sa = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 2 }, .{ .context = &fa, .handle = Fixture.handle });
    try sa.start();
    defer sa.stop();
    var sb = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 2 }, .{ .context = &fb, .handle = Fixture.handle });
    try sb.start();
    defer sb.stop();

    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    const host_a = try std.fmt.bufPrint(&buf_a, "127.0.0.1:{d}", .{sa.port});
    const host_b = try std.fmt.bufPrint(&buf_b, "127.0.0.1:{d}", .{sb.port});
    var corpus: std.ArrayList(u8) = .empty;
    defer corpus.deinit(testing.allocator);
    for (1..201) |id| try corpus.print(testing.allocator, "/height\t{{\"id\":{d}}}\n", .{id});
    const lines = try parseCorpus(testing.allocator, corpus.items, "/route");
    defer testing.allocator.free(lines);

    var self_report = try run(testing.allocator, .{ .a = try bench.parseTarget(host_a), .b = try bench.parseTarget(host_a), .threads = 3 }, lines, &default_scorers);
    defer self_report.deinit(testing.allocator);
    try testing.expect(self_report.ok());
    try testing.expectEqual(@as(u64, 200), self_report.requests);
    try testing.expectEqual(@as(u64, 200), tally(&self_report, "height-values").passed);

    var diff_report = try run(testing.allocator, .{ .a = try bench.parseTarget(host_a), .b = try bench.parseTarget(host_b), .threads = 3 }, lines, &default_scorers);
    defer diff_report.deinit(testing.allocator);
    try testing.expect(!diff_report.ok());
    const t = tally(&diff_report, "height-values");
    try testing.expectEqual(@as(u64, 1), t.failed);
    try testing.expectEqual(@as(usize, 3), t.worst.items[0].line);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeReport(testing.allocator, &out, .{ .a = host_a, .b = host_b, .corpus_path = "x", .corpus_hash = 1 }, &diff_report);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try json.parse(arena_state.allocator(), out.items);
    try testing.expectEqual(false, json.get(bool, parsed, "/pass", true));
    try testing.expectEqual(@as(i64, 3), json.get(i64, parsed, "/scorers/3/worst/0/line", 0));
}
