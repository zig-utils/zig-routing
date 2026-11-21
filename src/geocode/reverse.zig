//! Reverse geocoding with shared snap-grid and administrative polygon lookup.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const grid = @import("../geo/grid.zig");
const constants = @import("../geo/constants.zig");
const math = @import("../geo/libm.zig");
const admin = @import("admin_geometry.zig");
const bundle = @import("bundle.zig");
const model = @import("model.zig");
const format = @import("index_model.zig");
const rank = @import("query_rank.zig");
const retrieve = @import("query_retrieve.zig");
const spatial = @import("reverse_spatial.zig");
const geometry = @import("reverse_geometry.zig");
const sort = @import("sort_runs.zig").sort;
const Allocator = std.mem.Allocator;

pub const Layer = enum { nearest, address, street, poi, place, city, country };
pub const max_results = 100;

pub const Request = struct {
    point: geo.PointLL,
    radius_m: f64 = 200,
    limit: usize = 1,
    layer: Layer = .nearest,
    language: []const u8 = "",
};

pub const Region = struct { osm_id: i64, level: u8, name: []const u8 };

pub const Hierarchy = struct {
    country: ?Region = null,
    state: ?Region = null,
    county: ?Region = null,
    city: ?Region = null,
    district: ?Region = null,
    country_code: []const u8 = "",
    postcode: []const u8 = "",
};

pub const Result = struct {
    layer: Layer,
    kind: []const u8,
    osm_id: i64,
    source: model.Source,
    name: []const u8,
    address: []const u8,
    coordinate: geo.PointLL,
    distance_m: f64,
    approximate: bool = false,
    hierarchy: Hierarchy,
};

pub const Response = struct {
    hierarchy: Hierarchy,
    results: []const Result = &.{},
};

const Target = enum { address, interpolation, street, poi, place };

const Hit = struct {
    target: Target,
    row: u32,
    point: geo.PointLL,
    distance: f64,
    number: ?geometry.Number = null,

    fn before(self: Hit, other: Hit) bool {
        if (self.distance != other.distance) return self.distance < other.distance;
        if (self.target != other.target) return @backingInt(self.target) < @backingInt(other.target);
        return self.row < other.row;
    }
};

const Top = struct {
    hits: []Hit,
    len: usize = 0,
    radius: f64,

    fn cutoff(self: Top) f64 {
        return if (self.len == self.hits.len) self.hits[self.len - 1].distance else self.radius;
    }

    fn eligible(self: Top, target: Target) bool {
        if (self.len != self.hits.len) return true;
        const worst = self.hits[self.len - 1];
        return worst.distance != 0 or @backingInt(target) <= @backingInt(worst.target);
    }

    fn add(self: *Top, value: Hit) void {
        if (value.distance > self.cutoff()) return;
        for (self.hits[0..self.len], 0..) |old, i| {
            if (old.target != value.target or old.row != value.row) continue;
            if (!value.before(old)) return;
            std.mem.copyForwards(Hit, self.hits[i .. self.len - 1], self.hits[i + 1 .. self.len]);
            self.len -= 1;
            break;
        }
        var at = self.len;
        while (at != 0 and value.before(self.hits[at - 1])) at -= 1;
        if (at == self.hits.len) return;
        const end = @min(self.len, self.hits.len - 1);
        std.mem.copyBackwards(Hit, self.hits[at + 1 .. end + 1], self.hits[at..end]);
        self.hits[at] = value;
        self.len = @min(self.len + 1, self.hits.len);
    }
};

pub const Engine = struct {
    bundle: bundle.Bundle,
    spatial: spatial.Index,
    polygons: ?admin.View,

    pub fn open(a: Allocator, path: []const u8, deadline: io.Deadline) !Engine {
        var source = try bundle.Bundle.open(path, deadline);
        errdefer source.close();
        var points = try spatial.Index.init(a, source.data, deadline);
        errdefer points.close();
        return .{ .bundle = source, .spatial = points, .polygons = try admin.View.open(a, source.data, deadline) };
    }

    pub fn close(self: *Engine) void {
        if (self.polygons) |*polygons| polygons.close();
        self.spatial.close();
        self.bundle.close();
        self.* = undefined;
    }

    pub fn lookup(self: *const Engine, a: Allocator, request: Request, deadline: io.Deadline) !Response {
        try validate(request, deadline);
        const data = self.bundle.data;
        const at_point: model.Hierarchy = if (self.polygons) |polygons| try polygons.lookup(a, request.point, deadline) else .{};
        var response: Response = .{ .hierarchy = try describeHierarchy(data, at_point, request.language, deadline) };
        if (request.layer == .city or request.layer == .country) {
            const region = if (request.layer == .city) at_point.city else at_point.country;
            response.results = try adminResult(a, data, request, region, response.hierarchy, deadline);
            return response;
        }

        var top: Top = .{ .hits = try a.alloc(Hit, request.limit), .radius = request.radius_m };
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(a);
        const lon_scale = math.cosF(request.point.lat * constants.rad_per_deg_d);
        if (request.layer == .nearest or request.layer == .address) {
            for (self.spatial.wide_ranges) |id| {
                if (deadline.expired()) return error.DeadlineExceeded;
                try self.visit(a, id, request, lon_scale, &top, &visited, deadline);
            }
        }
        var cells = try self.spatial.cells.view.rings(a, request.point, top.cutoff(), deadline);
        defer cells.deinit();
        while (cells.next()) |cell| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (cell.distance > top.cutoff() + 1e-8) break;
            var ids = cell.cell.edges();
            var check: u8 = 0;
            while (try ids.next()) |id| {
                if (check % 64 == 0 and deadline.expired()) return error.DeadlineExceeded;
                check +%= 1;
                try self.visit(a, @backingInt(id), request, lon_scale, &top, &visited, deadline);
            }
        }
        if (top.len == 0 and request.layer == .nearest) {
            const choice = mostSpecific(at_point);
            response.results = try adminResult(a, data, request, choice, response.hierarchy, deadline);
            return response;
        }
        const results = try a.alloc(Result, top.len);
        for (top.hits[0..top.len], results) |hit, *item| {
            if (deadline.expired()) return error.DeadlineExceeded;
            item.* = try self.describe(a, hit, request.language, deadline);
        }
        response.results = results;
        return response;
    }

    pub fn batch(self: *const Engine, a: Allocator, requests: []const Request, deadline: io.Deadline) ![]Response {
        const Entry = struct {
            ordinal: usize,
            cell: u32,

            fn less(_: void, left: @This(), right: @This()) bool {
                if (left.cell != right.cell) return left.cell < right.cell;
                return left.ordinal < right.ordinal;
            }
        };
        const order = try a.alloc(Entry, requests.len);
        defer a.free(order);
        for (requests, order, 0..) |request, *entry, i| {
            try validate(request, deadline);
            entry.* = .{ .ordinal = i, .cell = grid.snapCell(request.point) };
        }
        var scratch: std.ArrayList(Entry) = .empty;
        defer scratch.deinit(a);
        try sort(Entry, a, order, &scratch, Entry.less, deadline);
        const out = try a.alloc(Response, requests.len);
        for (order) |entry| out[entry.ordinal] = try self.lookup(a, requests[entry.ordinal], deadline);
        return out;
    }

    fn visit(
        self: *const Engine,
        a: Allocator,
        id: u32,
        request: Request,
        scale: f64,
        top: *Top,
        visited: *std.AutoHashMapUnmanaged(u32, void),
        deadline: io.Deadline,
    ) !void {
        const item = self.spatial.items[id];
        const target: Target = switch (item) {
            .address => .address,
            .place => .place,
            .poi => .poi,
            .street_anchor, .street_piece => .street,
            .interpolation => .interpolation,
        };
        if ((request.layer != .nearest and request.layer != layer(target)) or !top.eligible(target)) return;
        const data = self.bundle.data;
        if (item == .interpolation) {
            if ((try visited.getOrPut(a, id)).found_existing) return;
            const address_data = data.address_data.?;
            const row = item.interpolation;
            const interpolation = address_data.interpolations[row];
            const shape = try interpolation.shape.get(address_data.address_coordinates);
            const hit = try geometry.nearestRange(interpolation.range(), shape, request.point, scale, deadline) orelse return;
            top.add(.{ .target = target, .row = row, .point = hit.coordinate, .distance = hit.distance, .number = hit.number });
            return;
        }
        const row = switch (item) {
            .address, .place, .poi, .street_anchor => |entry| entry,
            .street_piece => |piece| piece.street,
            .interpolation => unreachable,
        };
        const point = switch (item) {
            .street_piece => |piece| project: {
                if ((try visited.getOrPut(a, id)).found_existing) return;
                const shape = try piece.shape.get(data.address_data.?.address_coordinates);
                const start = shape[0].toPoint();
                const end = shape[shape.len - 1].toPoint();
                break :project geometry.project(request.point, start, end, scale).point;
            },
            else => retrieve.record(data, document(target, row)).coordinate.toPoint(),
        };
        if (top.cutoff() == 0 and !point.eql(request.point) and point.lat != request.point.lat) return;
        top.add(.{ .target = target, .row = row, .point = point, .distance = geometry.distance(request.point, point) });
    }

    fn describe(self: *const Engine, a: Allocator, hit: Hit, language: []const u8, deadline: io.Deadline) !Result {
        const data = self.bundle.data;
        if (hit.target == .interpolation) {
            const interpolation = data.address_data.?.interpolations[hit.row];
            const hierarchy = try describeHierarchy(data, interpolation.hierarchy, language, deadline);
            var rendered_number: [16]u8 = undefined;
            const number = try hit.number.?.text(&rendered_number);
            const street_name = if (self.spatial.range_streets[hit.row]) |street|
                (try rank.describe(a, data, .{ .kind = .street, .row = street }, language, deadline)).name
            else
                "";
            const address = try rank.formatAddress(a, hierarchy.country_code, "", regionName(hierarchy.country), .{
                .number = number,
                .street = street_name,
                .locality = regionName(hierarchy.city),
                .postcode = hierarchy.postcode,
            });
            return .{
                .layer = .address,
                .kind = "address",
                .osm_id = interpolation.osm_id,
                .source = .way,
                .name = "",
                .address = address,
                .coordinate = hit.point,
                .distance_m = hit.distance,
                .approximate = true,
                .hierarchy = hierarchy,
            };
        }
        const doc = document(hit.target, hit.row);
        const feature = retrieve.record(data, doc);
        const detail = try rank.describe(a, data, doc, language, deadline);
        return .{
            .layer = layer(hit.target),
            .kind = detail.kind,
            .osm_id = feature.osm_id,
            .source = feature.attr.source,
            .name = detail.name,
            .address = detail.formatted_address,
            .coordinate = hit.point,
            .distance_m = hit.distance,
            .hierarchy = try describeHierarchy(data, feature.hierarchy, language, deadline),
        };
    }
};

fn validate(request: Request, deadline: io.Deadline) !void {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (!request.point.inRange()) return error.InvalidCoordinate;
    if (request.radius_m < 0 or !std.math.isFinite(request.radius_m)) return error.InvalidRadius;
    if (request.limit == 0 or request.limit > max_results) return error.InvalidGeocodeResultLimit;
    if (request.language.len > 63) return error.InvalidGeocodeLanguage;
}

fn document(target: Target, row: u32) format.Document {
    return .{ .row = row, .kind = switch (target) {
        .address => .address,
        .street => .street,
        .place => .place,
        .poi => .poi,
        .interpolation => unreachable,
    } };
}

fn layer(target: Target) Layer {
    return switch (target) {
        .address, .interpolation => .address,
        .street => .street,
        .place => .place,
        .poi => .poi,
    };
}

fn describeHierarchy(data: bundle.Data, subject: model.Hierarchy, language: []const u8, deadline: io.Deadline) !Hierarchy {
    var result: Hierarchy = .{
        .country_code = try data.countryIso(subject.country),
        .postcode = try subject.postcode.get(data.text),
    };
    inline for (std.enums.values(model.Division)) |division| {
        const id = @field(subject, @tagName(division));
        if (try data.admin(id)) |row| {
            @field(result, @tagName(division)) = .{ .osm_id = row.osm_id, .level = row.attr.level, .name = try rank.adminName(data, id, language, deadline) };
        }
    }
    return result;
}

fn mostSpecific(subject: model.Hierarchy) model.AdminId {
    for ([_]model.AdminId{ subject.district, subject.city, subject.county, subject.state }) |id| {
        if (id != .unknown) return id;
    }
    return subject.country;
}

fn regionName(region: ?Region) []const u8 {
    return if (region) |value| value.name else "";
}

fn adminResult(a: Allocator, data: bundle.Data, request: Request, id: model.AdminId, hierarchy: Hierarchy, deadline: io.Deadline) ![]const Result {
    const row = try data.admin(id) orelse return &.{};
    const name = try rank.adminName(data, id, request.language, deadline);
    const answer = try a.create(Result);
    answer.* = .{
        .layer = if (row.attr.division == .country) .country else .city,
        .kind = @tagName(row.attr.division),
        .osm_id = row.osm_id,
        .source = .relation,
        .name = name,
        .address = name,
        .coordinate = request.point,
        .distance_m = 0,
        .hierarchy = hierarchy,
    };
    return answer[0..1];
}
