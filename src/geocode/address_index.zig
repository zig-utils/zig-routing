//! Associate house numbers with named street geometry and pack the per-street index.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const line = @import("../geo/line.zig");
const bundle = @import("bundle.zig");
const house = @import("house_number.zig");
const model = @import("model.zig");
const tags = @import("tags.zig");
const Allocator = std.mem.Allocator;

const NamedStreet = struct { name: model.Span, city: model.AdminId, street: u32 };
const Pending = struct { street: u32, link: model.HouseLink };
const Projection = struct { distance_squared: f64, position: u32 };
const Match = struct { street: u32, way: u32, position: u32 };

pub const Builder = struct {
    a: Allocator,
    pool: *tags.Pool,
    streets: []const model.Street,
    deadline: io.Deadline,
    names: std.ArrayList(NamedStreet) = .empty,
    street_shapes: std.ArrayList(model.Span) = .empty,
    coordinates: std.ArrayList(model.Coordinate) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    interpolations: std.ArrayList(model.Interpolation) = .empty,

    pub fn deinit(self: *Builder) void {
        self.names.deinit(self.a);
        self.street_shapes.deinit(self.a);
        self.coordinates.deinit(self.a);
        self.pending.deinit(self.a);
        self.interpolations.deinit(self.a);
    }

    pub fn appendStreetShape(self: *Builder, shape: []const model.Coordinate) !void {
        try self.street_shapes.append(self.a, try self.addShape(shape));
    }

    pub fn indexNames(self: *Builder) !void {
        for (self.streets, 0..) |street, i| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const id = std.math.cast(u32, i) orelse return error.GeocodeSectionTooLarge;
            const aliases = try street.record.names.get(@as([]const model.Name, self.pool.names.items));
            for (aliases) |alias| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                try self.names.append(self.a, .{ .name = alias.text, .city = street.record.hierarchy.city, .street = id });
            }
        }
        std.mem.sortUnstable(NamedStreet, self.names.items, self.pool.bytes.items, nameLess);
    }

    pub fn addAddress(self: *Builder, index: usize, record: model.Address) !void {
        if (record.number.len == 0 or record.street.len == 0) return;
        const name = try self.pool.stableText(record.street);
        const match = try self.matchStreet(name, record.record.hierarchy, record.record.coordinate) orelse return;
        const raw = try self.pool.stableText(record.number);
        const unit = try self.pool.stableText(record.unit);
        const row = std.math.cast(u32, index) orelse return error.GeocodeSectionTooLarge;
        var labels = std.mem.tokenizeAny(u8, raw, ",;");
        while (labels.next()) |part| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const parsed = house.parse(part, unit) catch continue;
            try self.addLink(match, row, .exact, parsed);
        }
    }

    pub fn addInterpolation(
        self: *Builder,
        record: model.Interpolation,
        shape: []const model.Coordinate,
        street: []const u8,
        anchor: model.Coordinate,
        first: house.Key,
        last: house.Key,
    ) !void {
        const match = try self.matchStreet(street, record.hierarchy, anchor);
        const index = std.math.cast(u32, self.interpolations.items.len) orelse return error.GeocodeSectionTooLarge;
        var linked = record;
        linked.shape = try self.addShape(shape);
        try self.interpolations.append(self.a, linked);
        if (match) |present| {
            const ordered: house.Label = if (first.order(last) == .gt)
                .{ .first = last, .last = first }
            else
                .{ .first = first, .last = last };
            try self.addLink(present, index, .interpolation, ordered);
        }
    }

    pub fn finish(self: *Builder, owned: Allocator) !bundle.AddressData {
        const context: []const u8 = self.pool.bytes.items;
        std.mem.sortUnstable(Pending, self.pending.items, context, linkLess);
        const spans = try owned.alloc(model.Span, self.streets.len);
        const links = try owned.alloc(model.HouseLink, self.pending.items.len);
        var first: usize = 0;
        for (spans, 0..) |*span, street| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            var end = first;
            while (end < links.len and self.pending.items[end].street == street) : (end += 1) {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                links[end] = self.pending.items[end].link;
            }
            span.* = try model.Span.init(first, end - first);
            first = end;
        }
        return .{
            .street_shapes = self.street_shapes.items,
            .address_coordinates = self.coordinates.items,
            .street_houses = spans,
            .house_links = links,
            .interpolations = self.interpolations.items,
        };
    }

    fn addShape(self: *Builder, shape: []const model.Coordinate) !model.Span {
        const span = try model.Span.init(self.coordinates.items.len, shape.len);
        try self.coordinates.appendSlice(self.a, shape);
        return span;
    }

    const LinkKind = @FieldType(@FieldType(model.HouseLink, "attr"), "kind");

    fn addLink(self: *Builder, match: Match, row: u32, kind: LinkKind, parsed: house.Label) !void {
        try self.pending.append(self.a, .{
            .street = match.street,
            .link = .{
                .object_id = row,
                .street_way = match.way,
                .position = match.position,
                .attr = .{ .kind = kind, .has_last = parsed.last != null },
                .first = try self.storeKey(parsed.first),
                .last = if (parsed.last) |last| try self.storeKey(last) else .{ .number = 0 },
                .unit = try self.pool.text(parsed.unit),
            },
        });
    }

    fn storeKey(self: *Builder, key: house.Key) !model.HouseKey {
        return .{
            .number = key.number,
            .fraction = .{ .numerator = key.fraction.numerator, .denominator = key.fraction.denominator },
            .letters = try self.pool.text(key.letters),
        };
    }

    fn matchStreet(self: *const Builder, name: []const u8, hierarchy: model.Hierarchy, coordinate: model.Coordinate) !?Match {
        if (name.len == 0) return null;
        if (hierarchy.city != .unknown) {
            if (try self.closestNamedStreet(name, hierarchy, coordinate, hierarchy.city)) |local| return local;
        }
        return self.closestNamedStreet(name, hierarchy, coordinate, .unknown);
    }

    fn closestNamedStreet(
        self: *const Builder,
        name: []const u8,
        hierarchy: model.Hierarchy,
        coordinate: model.Coordinate,
        city: model.AdminId,
    ) !?Match {
        const text: []const u8 = self.pool.bytes.items;
        const Search = struct {
            name: []const u8,
            text: []const u8,
            city: model.AdminId,

            fn compare(ctx: @This(), item: NamedStreet) std.math.Order {
                const names = std.ascii.orderIgnoreCase(ctx.name, knownText(item.name, ctx.text));
                return if (names == .eq) std.math.order(@backingInt(ctx.city), @backingInt(item.city)) else names;
            }
        };
        const first = std.sort.lowerBound(NamedStreet, self.names.items, Search{ .name = name, .text = text, .city = city }, Search.compare);
        var best: ?Match = null;
        var best_distance = std.math.inf(f64);
        var previous: ?u32 = null;
        for (self.names.items[first..]) |candidate| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (city != .unknown and city != candidate.city) break;
            if (!std.ascii.eqlIgnoreCase(name, knownText(candidate.name, text))) break;
            if (previous == candidate.street) continue;
            previous = candidate.street;
            const street = self.streets[candidate.street];
            const locality = street.record.hierarchy;
            if (hierarchy.country != .unknown and locality.country != .unknown and hierarchy.country != locality.country) continue;
            const shapes = try street.ways.get(@as([]const model.Span, self.street_shapes.items));
            for (shapes, 0..) |span, i| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                const shape = try span.get(@as([]const model.Coordinate, self.coordinates.items));
                const measured = try project(coordinate, shape, self.deadline) orelse continue;
                if (measured.distance_squared > best_distance) continue;
                if (best) |prior| {
                    if (measured.distance_squared == best_distance and candidate.street >= prior.street) continue;
                }
                const way = std.math.cast(u32, @as(usize, street.ways.first) + i) orelse return error.GeocodeSectionTooLarge;
                best = .{ .street = candidate.street, .way = way, .position = measured.position };
                best_distance = measured.distance_squared;
            }
        }
        return best;
    }
};

fn knownText(span: model.Span, strings: []const u8) []const u8 {
    return strings[span.first..][0..span.len];
}

fn nameLess(text: []const u8, a: NamedStreet, b: NamedStreet) bool {
    const order = std.ascii.orderIgnoreCase(knownText(a.name, text), knownText(b.name, text));
    if (order != .eq) return order == .lt;
    const cities = std.math.order(@backingInt(a.city), @backingInt(b.city));
    return if (cities == .eq) a.street < b.street else cities == .lt;
}

fn linkLess(text: []const u8, a: Pending, b: Pending) bool {
    if (a.street != b.street) return a.street < b.street;
    const order = (a.link.first.key(text) catch unreachable).order(b.link.first.key(text) catch unreachable);
    if (order != .eq) return order == .lt;
    if (a.link.attr.kind != b.link.attr.kind) return a.link.attr.kind == .exact;
    return a.link.object_id < b.link.object_id;
}

fn project(query: model.Coordinate, shape: []const model.Coordinate, deadline: io.Deadline) !?Projection {
    if (shape.len == 0) return null;
    const point = query.toPoint();
    var a = shape[0].toPoint();
    var closest = std.math.inf(f64);
    var distance: f64 = 0;
    var length: f64 = 0;
    for (shape[1..], 0..) |end, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const b = end.toPoint();
        const ax = point.lng + geo.wrappedLongitudeDelta(a.lng, point.lng);
        const bx = ax + geo.wrappedLongitudeDelta(b.lng, a.lng);
        const local_a = geo.PointLL.init(ax, a.lat);
        const local_b = geo.PointLL.init(bx, b.lat);
        const nearest = line.segmentDistanceSquared(local_a, local_b, point);
        if (nearest.distance_sq < closest) {
            closest = nearest.distance_sq;
            distance = length + local_a.distance(nearest.point);
        }
        length += a.distance(b);
        a = b;
    }
    if (length == 0) return .{ .distance_squared = a.distanceSquared(point), .position = 0 };
    const scale: f64 = @floatFromInt(std.math.maxInt(u32));
    const position: u32 = @intFromFloat(@round(std.math.clamp(distance / length, 0, 1) * scale));
    return .{ .distance_squared = closest, .position = position };
}
