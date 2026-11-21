//! Score and format forward geocoder results from immutable bundle rows.
const std = @import("std");
const io = @import("../infra/io.zig");
const geo = @import("../geo/point.zig");
const address_format = @import("address_format.zig");
const bundle = @import("bundle.zig");
const format = @import("index_model.zig");
const model = @import("model.zig");
const retrieve = @import("query_retrieve.zig");
const Allocator = std.mem.Allocator;
const weights = retrieve.weights;

pub const Bounds = struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,

    pub fn valid(self: Bounds) bool {
        return geo.PointLL.init(self.west, self.south).inRange() and
            geo.PointLL.init(self.east, self.north).inRange() and self.south <= self.north;
    }

    pub fn contains(self: Bounds, point: geo.PointLL) bool {
        if (point.lat < self.south or point.lat > self.north) return false;
        return if (self.west <= self.east)
            self.west <= point.lng and point.lng <= self.east
        else
            self.west <= point.lng or point.lng <= self.east;
    }
};

pub const Filters = struct {
    language: []const u8 = "",
    near: ?geo.PointLL = null,
    bounds: ?Bounds = null,
    layers: std.EnumSet(format.Kind) = .full,
};

pub const Result = struct {
    document: format.Document,
    osm_id: i64,
    source: model.Source,
    kind: []const u8,
    name: []const u8,
    formatted_address: []const u8,
    city: []const u8,
    country: []const u8,
    country_code: []const u8,
    postcode: []const u8,
    coordinate: geo.PointLL,
    bounds: Bounds,
    score: u32,
};

pub const Ranked = struct {
    hit: retrieve.Hit,
    document: format.Document,
    score: u32,

    fn before(self: Ranked, other: Ranked) bool {
        if (self.score != other.score) return self.score > other.score;
        if (self.hit.importance != other.hit.importance) return self.hit.importance > other.hit.importance;
        return self.hit.id < other.hit.id;
    }
};

pub const Top = struct {
    entries: []Ranked,
    len: usize = 0,

    pub fn add(self: *Top, ranked: Ranked) void {
        for (self.entries[0..self.len], 0..) |prior, i| {
            if (prior.hit.id != ranked.hit.id) continue;
            if (!ranked.before(prior)) return;
            std.mem.copyForwards(Ranked, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
            self.len -= 1;
            break;
        }
        var at = self.len;
        while (at > 0 and ranked.before(self.entries[at - 1])) : (at -= 1) {}
        if (at == self.entries.len) return;
        const end = @min(self.len, self.entries.len - 1);
        std.mem.copyBackwards(Ranked, self.entries[at + 1 .. end + 1], self.entries[at..end]);
        self.entries[at] = ranked;
        self.len = @min(self.entries.len, self.len + 1);
    }

    pub fn canImprove(self: Top, upper: u32) bool {
        return self.len < self.entries.len or upper >= self.entries[self.len - 1].score;
    }
};

pub fn importance(raw: u16) u32 {
    return @min(raw, weights.importance_cap) / weights.importance_divisor;
}

pub fn maxBonus(filters: Filters) u32 {
    return weights.max_layer + @as(u32, if (filters.near != null) weights.near else 0) +
        @as(u32, if (filters.language.len != 0) weights.language else 0);
}

pub fn evaluate(
    data: bundle.Data,
    counts: format.RecordCounts,
    hit: retrieve.Hit,
    text_score: u32,
    country: model.AdminId,
    filters: Filters,
    deadline: io.Deadline,
) !?Ranked {
    const document = counts.document(hit.id).?;
    if (!filters.layers.contains(document.kind)) return null;
    const feature = retrieve.record(data, document);
    if (country != .unknown and feature.hierarchy.country != country) return null;
    const point = feature.coordinate.toPoint();
    if (filters.bounds) |bounds| if (!bounds.contains(point)) return null;
    var score = text_score + importance(hit.importance) + weights.layers[@backingInt(document.kind)];
    if (filters.near) |near| score += @intFromFloat(weights.near / (1.0 + near.distance(point) / weights.near_scale_m));
    if (filters.language.len != 0 and (try selectName(data, feature.names, filters.language, deadline)).preferred)
        score += weights.language;
    return .{ .hit = hit, .document = document, .score = score };
}

const Name = struct {
    text: []const u8 = "",
    preferred: bool = false,
};

fn selectName(data: bundle.Data, span: model.Span, language: []const u8, deadline: io.Deadline) !Name {
    const base = baseLanguage(language);
    var fallback: []const u8 = "";
    var localized: []const u8 = "";
    for (try span.get(data.names)) |label| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const text = try label.text.get(data.text);
        const tag = try label.language.get(data.text);
        if (fallback.len == 0 or tag.len == 0) fallback = text;
        if (tag.len == 0 or language.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(language, tag)) return .{ .text = text, .preferred = true };
        if (localized.len == 0 and std.ascii.eqlIgnoreCase(base, baseLanguage(tag))) localized = text;
    }
    return if (localized.len != 0) .{ .text = localized, .preferred = true } else .{ .text = fallback };
}

fn baseLanguage(tag: []const u8) []const u8 {
    return tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len];
}

fn adminName(data: bundle.Data, id: model.AdminId, language: []const u8, deadline: io.Deadline) ![]const u8 {
    const admin = try data.admin(id) orelse return "";
    return (try selectName(data, admin.names, language, deadline)).text;
}

pub fn assemble(a: Allocator, data: bundle.Data, candidate: Ranked, language: []const u8, deadline: io.Deadline) !Result {
    const doc = candidate.document;
    const feature = retrieve.record(data, doc);
    const subject = feature.hierarchy;
    const country = try adminName(data, subject.country, language, deadline);
    const iso = try data.countryIso(subject.country);
    const postcode_text = try subject.postcode.get(data.text);
    var city = try adminName(data, subject.city, language, deadline);
    var name = (try selectName(data, feature.names, language, deadline)).text;
    var components: address_format.Components = .{ .locality = city, .postcode = postcode_text };
    const kind: []const u8 = switch (doc.kind) {
        .place => try data.places[doc.row].kind.get(data.text),
        .street => street: {
            components.street = name;
            break :street try data.streets[doc.row].kind.get(data.text);
        },
        .poi => try data.pois[doc.row].kind.get(data.text),
        .address => address: {
            const row = data.addresses[doc.row];
            if (name.len == 0) name = try row.house_name.get(data.text);
            components.street = try row.street.get(data.text);
            components.number = try row.number.get(data.text);
            components.unit = try row.unit.get(data.text);
            if (city.len == 0) {
                city = try row.place.get(data.text);
                components.locality = city;
            }
            break :address "address";
        },
    };
    const street_buffer = try a.alloc(u8, components.street.len + components.number.len + components.unit.len + 8);
    const locality_buffer = try a.alloc(u8, components.postcode.len + components.locality.len + 8);
    const lines = try address_format.render(iso, components, street_buffer, locality_buffer);
    var display: [4][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ name, lines.street, lines.locality, country }) |part| {
        if (part.len == 0) continue;
        for (display[0..count]) |prior| {
            if (std.mem.eql(u8, part, prior)) break;
        } else {
            display[count] = part;
            count += 1;
        }
    }
    return .{
        .document = doc,
        .osm_id = feature.osm_id,
        .source = feature.attr.source,
        .kind = kind,
        .name = name,
        .formatted_address = try std.mem.join(a, ", ", display[0..count]),
        .city = city,
        .country = country,
        .country_code = iso,
        .postcode = postcode_text,
        .coordinate = feature.coordinate.toPoint(),
        .bounds = try extent(data, doc, feature.coordinate.toPoint(), deadline),
        .score = candidate.score,
    };
}

fn extent(data: bundle.Data, doc: format.Document, center: geo.PointLL, deadline: io.Deadline) !Bounds {
    var result: Bounds = .{ .west = center.lng, .east = center.lng, .south = center.lat, .north = center.lat };
    const addresses = data.address_data orelse return result;
    if (doc.kind != .street) return result;
    const members = try data.streets[doc.row].ways.get(addresses.street_shapes);
    for (members) |member| {
        for (try member.get(addresses.address_coordinates), 0..) |coordinate, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const point = coordinate.toPoint();
            const longitude = center.lng + geo.wrappedLongitudeDelta(point.lng, center.lng);
            result.west = @min(result.west, longitude);
            result.east = @max(result.east, longitude);
            result.south = @min(result.south, point.lat);
            result.north = @max(result.north, point.lat);
        }
    }
    if (result.west < -180) result.west += 360;
    if (result.east > 180) result.east -= 360;
    return result;
}
