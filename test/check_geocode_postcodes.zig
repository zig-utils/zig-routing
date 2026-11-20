//! Check postcode lookup against integer shoelace moments from source polygons.
const std = @import("std");
const routing = @import("routing");
const pbf = routing.build.pbf;
const boundaries = routing.build.admin_boundaries;
const polygon = routing.geo.polygon;
const geocode = routing.geocode;
const io = routing.infra.io;
const Coordinate = geocode.model.Coordinate;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const Policy = struct {
    pub const Attributes = union(enum) { postal_code: []const u8, country: []const u8 };
    pub const wayRole = boundaries.polygonRole;

    pub fn read(a: Allocator, relation: pbf.block.Relation, _: io.Deadline) !?Attributes {
        var boundary: []const u8 = "";
        var code: []const u8 = "";
        var iso: []const u8 = "";
        var level: []const u8 = "";
        var tags = relation.tags;
        while (try tags.next()) |tag| {
            if (eql(u8, tag.key, "boundary")) boundary = tag.value;
            if (eql(u8, tag.key, "postal_code")) code = tag.value;
            if (eql(u8, tag.key, "admin_level")) level = tag.value;
            if (eql(u8, tag.key, "ISO3166-1:alpha2") or eql(u8, tag.key, "ISO3166-1")) {
                if (tag.value.len == 2) iso = tag.value;
            }
        }
        if (eql(u8, boundary, "postal_code") and code.len != 0)
            return .{ .postal_code = try a.dupe(u8, code) };
        if (eql(u8, boundary, "administrative") and eql(u8, level, "2") and iso.len != 0)
            return .{ .country = try a.dupe(u8, iso) };
        return null;
    }
};

const Moments = struct {
    area: i128 = 0,
    x: i128 = 0,
    y: i128 = 0,

    fn ring(points: polygon.Ring) Moments {
        if (points.len < 3) return .{};
        var result: Moments = .{};
        var previous = points[points.len - 1].toFixed();
        for (points) |point| {
            const next = point.toFixed();
            const cross = @as(i128, previous.lng) * next.lat - @as(i128, next.lng) * previous.lat;
            result.area += cross;
            result.x += (@as(i128, previous.lng) + next.lng) * cross;
            result.y += (@as(i128, previous.lat) + next.lat) * cross;
            previous = next;
        }
        if (result.area < 0) return .{ .area = -result.area, .x = -result.x, .y = -result.y };
        return result;
    }

    fn center(self: Moments) Coordinate {
        const divisor = self.area * 3;
        return .{ .lng = roundDiv(self.x, divisor), .lat = roundDiv(self.y, divisor) };
    }
};

fn roundDiv(value: i128, divisor: i128) i32 {
    const adjustment = @divTrunc(divisor, 2);
    return @intCast(@divTrunc(value + if (value < 0) -adjustment else adjustment, divisor));
}

const Reference = struct {
    moments: Moments = .{},
    min: Coordinate = .{ .lng = std.math.maxInt(i32), .lat = std.math.maxInt(i32) },
    max: Coordinate = .{ .lng = std.math.minInt(i32), .lat = std.math.minInt(i32) },

    fn add(self: *Reference, shape: polygon.Polygon) void {
        var total = Moments.ring(shape.outer);
        for (shape.holes) |hole| {
            const mass = Moments.ring(hole);
            total.area -= mass.area;
            total.x -= mass.x;
            total.y -= mass.y;
        }
        if (total.area <= 0) return;
        self.moments.area += total.area;
        self.moments.x += total.x;
        self.moments.y += total.y;
        for (shape.outer) |vertex| {
            const point = vertex.toFixed();
            self.min = .{ .lng = @min(self.min.lng, point.lng), .lat = @min(self.min.lat, point.lat) };
            self.max = .{ .lng = @max(self.max.lng, point.lng), .lat = @max(self.max.lat, point.lat) };
        }
    }
};

const ClosedWays = struct {
    allocator: Allocator,
    iso: []const u8,
    scratch: pbf.block.Scratch = .{},
    codes: std.StringHashMapUnmanaged(void) = .empty,

    fn scan(self: *ClosedWays, _: usize, bytes: []const u8) !void {
        const block = try self.scratch.decode(self.allocator, bytes, .none);
        var ways = block.ways();
        while (try ways.next()) |way| {
            var tags = way.tags;
            var postal = false;
            var raw: []const u8 = "";
            while (try tags.next()) |tag| {
                if (eql(u8, tag.key, "boundary")) postal = eql(u8, tag.value, "postal_code");
                if (eql(u8, tag.key, "postal_code")) raw = tag.value;
            }
            if (!postal or raw.len == 0) continue;
            var nodes = way.refs;
            const first = try nodes.next() orelse continue;
            var last = first;
            var count: usize = 1;
            while (try nodes.next()) |ref| {
                last = ref;
                count += 1;
            }
            if (count < 4 or last != first) continue;
            var split = std.mem.splitScalar(u8, raw, ';');
            while (split.next()) |value| {
                const code = geocode.postcode.Code.normalize(value, self.iso) orelse continue;
                if (!self.codes.contains(code.bytes()))
                    try self.codes.put(self.allocator, try self.allocator.dupe(u8, code.bytes()), {});
            }
        }
    }
};

fn contains(country: []const polygon.Polygon, point: routing.geo.PointLL) !bool {
    for (country) |shape| {
        if (try shape.locate(point, .none) != .outside) return true;
    }
    return false;
}

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input = args.next() orelse return error.MissingExtractPath;
    const bundle_path = args.next() orelse return error.MissingGeocodeBundle;
    const iso = args.next() orelse return error.MissingCountry;
    const samples = try std.fmt.parseInt(usize, args.next() orelse "1000", 10);
    if (samples == 0 or args.next() != null) return error.InvalidArgument;
    const a = init.arena.allocator();
    var source = try pbf.file.File.open(init.gpa, input, .none);
    defer source.close();
    const streams: pbf.file.IndexedStreams = .{
        .files = (&source)[0..1],
        .decode = .{ .workers = 7, .buffer_bytes = 512 * 1024 * 1024 },
    };
    var ways: ClosedWays = .{ .allocator = a, .iso = iso };
    defer ways.scratch.deinit(a);
    try streams.forEach(init.gpa, .none, &ways, ClosedWays.scan);
    var catalog = try boundaries.collectBoundaries(Policy, init.gpa, streams, .none);
    defer catalog.deinit();
    var country: std.ArrayList(polygon.Polygon) = .empty;
    for (catalog.regions) |region| {
        if (region.attrs == .country and std.ascii.eqlIgnoreCase(iso, region.attrs.country))
            try country.appendSlice(a, region.geometry.polygons);
    }
    if (country.items.len == 0) return error.MissingCountryGeometry;
    var reference: std.StringHashMapUnmanaged(Reference) = .empty;
    for (catalog.regions) |region| {
        if (region.attrs != .postal_code) continue;
        for (region.geometry.polygons) |shape| {
            const anchor = try shape.representative(.none) orelse continue;
            if (!try contains(country.items, anchor)) continue;
            var split = std.mem.splitScalar(u8, region.attrs.postal_code, ';');
            while (split.next()) |value| {
                const code = geocode.postcode.Code.normalize(value, iso) orelse continue;
                if (ways.codes.contains(code.bytes())) continue;
                const slot = try reference.getOrPut(a, code.bytes());
                if (!slot.found_existing) {
                    slot.key_ptr.* = try a.dupe(u8, code.bytes());
                    slot.value_ptr.* = .{};
                }
                slot.value_ptr.add(shape);
            }
        }
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var iterator = reference.iterator();
    while (iterator.next()) |slot| {
        if (slot.value_ptr.moments.area > 0) try keys.append(a, slot.key_ptr.*);
    }
    if (keys.items.len < samples) {
        std.debug.print("{s}: {d} reference polygons for {d} required lookups\n", .{ iso, keys.items.len, samples });
        return error.TooFewPostcodes;
    }
    std.mem.sortUnstable([]const u8, keys.items, {}, less);
    var bundle = try geocode.bundle.Bundle.open(bundle_path, .none);
    defer bundle.close();
    const address_data = bundle.data.address_data orelse return error.MissingGeocodeAddressIndex;
    var country_id: geocode.model.AdminId = .unknown;
    for (address_data.country_codes, 1..) |code, row| {
        if (std.ascii.eqlIgnoreCase(iso, try code.get(bundle.data.text))) {
            country_id = @fromBackingInt(@intCast(std.math.cast(u32, row) orelse return error.GeocodeSectionTooLarge));
            break;
        }
    }
    if (country_id == .unknown) return error.MissingCountry;
    var max_error: u64 = 0;
    for (0..samples) |i| {
        const key = keys.items[(i * keys.items.len) / samples];
        const expected = reference.get(key).?;
        const actual = (try bundle.data.lookupPostcode(country_id, key)) orelse {
            std.debug.print("{s}: missing {s}\n", .{ iso, key });
            return error.MissingPostcode;
        };
        const center = expected.moments.center();
        const error_lng = @abs(@as(i64, center.lng) - actual.center.lng);
        const error_lat = @abs(@as(i64, center.lat) - actual.center.lat);
        max_error = @max(max_error, error_lng, error_lat);
        if (!actual.attr.from_boundary or error_lng > 1 or error_lat > 1 or
            !std.meta.eql(expected.min, actual.min) or !std.meta.eql(expected.max, actual.max))
        {
            std.debug.print("{s} {s}: expected center {any}, min {any}, max {any}; got {any}, {any}, {any}\n", .{
                iso, key, center, expected.min, expected.max, actual.center, actual.min, actual.max,
            });
            return error.PostcodeGeometryMismatch;
        }
    }
    const json = try std.json.Stringify.valueAlloc(a, .{
        .country = iso,
        .polygon_references = keys.items.len,
        .lookups_checked = samples,
        .max_center_error_e7 = max_error,
    }, .{ .whitespace = .indent_2 });
    try io.writeStdout(json);
    try io.writeStdout("\n");
}
