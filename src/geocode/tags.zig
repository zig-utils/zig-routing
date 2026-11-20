//! Classify OSM features and retain source labels before the PBF block expires.
const std = @import("std");
const pbf = @import("../build/pbf/block.zig");
const io = @import("../infra/io.zig");
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const keys = std.StaticStringMap(enum {
    name,
    place,
    highway,
    number,
    house_name,
    street,
    locality,
    unit,
    postcode,
    population,
    capital,
    wikidata,
    wikipedia,
}).initComptime(.{
    .{ "name", .name },
    .{ "place", .place },
    .{ "highway", .highway },
    .{ "addr:housenumber", .number },
    .{ "addr:housename", .house_name },
    .{ "addr:street", .street },
    .{ "addr:place", .locality },
    .{ "addr:unit", .unit },
    .{ "addr:postcode", .postcode },
    .{ "population", .population },
    .{ "capital", .capital },
    .{ "wikidata", .wikidata },
    .{ "wikipedia", .wikipedia },
});

// Earlier keys take precedence when a feature has several POI tags.
const poi_categories = [_][]const u8{
    "amenity", "shop",      "tourism",          "leisure", "historic", "healthcare", "office",
    "craft",   "emergency", "public_transport", "railway", "aeroway",  "man_made",   "natural",
};

pub const Labels = struct {
    name: []const u8 = "",
    place: []const u8 = "",
    highway: []const u8 = "",
    number: []const u8 = "",
    house_name: []const u8 = "",
    street: []const u8 = "",
    locality: []const u8 = "",
    unit: []const u8 = "",
    postcode: []const u8 = "",
    population: u32 = 0,
    capital: bool = false,
    wikidata: bool = false,
    wikipedia: bool = false,
    poi: ?struct { category: []const u8, kind: []const u8 } = null,

    pub fn read(tags: pbf.TagIterator) !Labels {
        var result: Labels = .{};
        var poi_rank: usize = poi_categories.len;
        var iter = tags;
        while (try iter.next()) |tag| {
            if (tag.value.len == 0) continue;
            if (keys.get(tag.key)) |key| {
                switch (key) {
                    .population => result.population = std.fmt.parseInt(u32, tag.value, 10) catch 0,
                    .capital => result.capital = validKind(tag.value),
                    .wikidata => result.wikidata = true,
                    .wikipedia => result.wikipedia = true,
                    inline else => |field| @field(result, @tagName(field)) = tag.value,
                }
            } else if (validKind(tag.value)) {
                for (poi_categories[0..poi_rank], 0..) |category, i| {
                    if (!eql(u8, tag.key, category)) continue;
                    result.poi = .{ .category = category, .kind = tag.value };
                    poi_rank = i;
                    break;
                }
            }
        }
        // Natural and man-made objects include extensive non-point land
        // cover and infrastructure. Their named features are searchable.
        if (result.poi) |poi| {
            if (result.name.len == 0 and (eql(u8, poi.category, "natural") or eql(u8, poi.category, "man_made")))
                result.poi = null;
        }
        return result;
    }

    pub fn feature(self: Labels, source: model.Source) bool {
        return validKind(self.place) or self.isStreet(source) or self.isAddress() or self.poi != null;
    }

    pub fn isStreet(self: Labels, source: model.Source) bool {
        return source == .way and self.name.len != 0 and validKind(self.highway);
    }

    pub fn isAddress(self: Labels) bool {
        return self.number.len != 0 or self.house_name.len != 0;
    }

    pub fn importance(self: Labels) u16 {
        const place: u16 = place_weights.get(self.place) orelse 0;
        const population: u16 = if (self.population == 0) 0 else @as(u16, std.math.log2_int(u32, self.population)) * 384;
        const capital: u16 = if (self.capital) 4096 else 0;
        const linked: u16 = (if (self.wikidata) @as(u16, 1536) else 0) + (if (self.wikipedia) @as(u16, 1024) else 0);
        const named: u16 = if (self.name.len != 0) 256 else 0;
        return place + population + capital + linked + named;
    }
};

const place_weights = std.StaticStringMap(u16).initComptime(.{
    .{ "continent", 32000 }, .{ "country", 30000 },      .{ "state", 25500 },
    .{ "region", 22500 },    .{ "city", 20000 },         .{ "town", 14500 },
    .{ "village", 9500 },    .{ "suburb", 7800 },        .{ "hamlet", 5800 },
    .{ "quarter", 5100 },    .{ "neighbourhood", 4100 }, .{ "locality", 3500 },
});

pub fn validKind(value: []const u8) bool {
    return value.len != 0 and !eql(u8, value, "no");
}

pub fn language(key: []const u8) ?[]const u8 {
    if (eql(u8, key, "name")) return "";
    if (!std.mem.startsWith(u8, key, "name:")) return null;
    const suffix = key["name:".len..];
    const primary = suffix[0 .. std.mem.indexOfScalar(u8, suffix, '-') orelse suffix.len];
    if (primary.len < 2 or primary.len > 3) return null;
    for (primary) |byte| {
        if (!std.ascii.isLower(byte)) return null;
    }
    for (suffix[primary.len..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return null;
    }
    return suffix;
}

pub const Pool = struct {
    a: Allocator,
    owned: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    names: std.ArrayList(model.Name) = .empty,
    texts: std.StringHashMapUnmanaged(model.Span) = .empty,

    pub fn deinit(self: *Pool) void {
        self.bytes.deinit(self.a);
        self.names.deinit(self.a);
        self.texts.deinit(self.a);
    }

    pub fn text(self: *Pool, value: []const u8) !model.Span {
        if (value.len == 0) return .{};
        if (self.texts.get(value)) |existing| return existing;
        const span = try model.Span.init(self.bytes.items.len, value.len);
        if (value.len > std.math.maxInt(u32) - span.first) return error.GeocodeSectionTooLarge;
        const stable = try self.owned.dupe(u8, value);
        try self.bytes.appendSlice(self.a, stable);
        try self.texts.put(self.a, stable, span);
        return span;
    }

    pub fn labels(self: *Pool, tags: pbf.TagIterator) !model.Span {
        const first = self.names.items.len;
        var iter = tags;
        while (try iter.next()) |tag| {
            const lang = language(tag.key) orelse continue;
            if (tag.value.len == 0) continue;
            try self.addName(lang, tag.value);
        }
        return model.Span.init(first, self.names.items.len - first);
    }

    pub fn addName(self: *Pool, lang: []const u8, value: []const u8) !void {
        try self.names.append(self.a, .{ .language = try self.text(lang), .text = try self.text(value) });
    }
};

test "OSM labels preserve language qualifiers and rank populated places" {
    const t = std.testing;
    try t.expectEqualStrings("", language("name").?);
    try t.expectEqualStrings("zh-Hant", language("name:zh-Hant").?);
    try t.expectEqualStrings("gsw", language("name:gsw").?);
    try t.expectEqual(null, language("name:etymology:wikidata"));
    try t.expectEqual(null, language("name:pronunciation"));
    const city: Labels = .{ .name = "City", .place = "city", .population = 81_000, .wikidata = true };
    const town: Labels = .{ .name = "Town", .place = "town", .population = 8_000 };
    try t.expect(city.importance() > town.importance());
}
