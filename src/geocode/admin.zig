//! Assign geocoding localities using OSM administrative multipolygons.
const std = @import("std");
const io = @import("../infra/io.zig");
const boundaries = @import("../build/admin_boundaries.zig");
const pbf = @import("../build/pbf/block.zig");
const polygon = @import("../geo/polygon.zig");
const polygon_index = @import("../geo/polygon_index.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const model = @import("model.zig");
const tags = @import("tags.zig");
const admin_geometry = @import("admin_geometry.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const Label = struct { language: []const u8, value: []const u8 };

const Policy = struct {
    pub const Attributes = struct {
        level: u8,
        division: model.Division,
        names: []const Label,
        iso: [2]u8,
    };

    pub fn read(owned: Allocator, relation: pbf.Relation, _: io.Deadline) !?Attributes {
        var boundary: []const u8 = "";
        var place: []const u8 = "";
        var level: u8 = 0;
        var iso: [2]u8 = @splat(0);
        var alpha2: [2]u8 = @splat(0);
        var tags_iter = relation.tags;
        while (try tags_iter.next()) |tag| {
            if (eql(u8, tag.key, "boundary")) {
                boundary = tag.value;
            } else if (eql(u8, tag.key, "admin_level")) {
                level = std.fmt.parseInt(u8, tag.value, 10) catch 0;
            } else if (eql(u8, tag.key, "place")) {
                place = tag.value;
            } else if (eql(u8, tag.key, "ISO3166-1:alpha2")) {
                alpha2 = countryCode(tag.value) orelse alpha2;
            } else if (eql(u8, tag.key, "ISO3166-1")) {
                iso = countryCode(tag.value) orelse iso;
            }
        }
        if (!eql(u8, boundary, "administrative")) return null;
        const division = role(level, place) orelse return null;
        var names: std.ArrayList(Label) = .empty;
        tags_iter = relation.tags;
        while (try tags_iter.next()) |tag| {
            const lang = tags.language(tag.key) orelse continue;
            if (tag.value.len == 0) continue;
            try names.append(owned, .{ .language = try owned.dupe(u8, lang), .value = try owned.dupe(u8, tag.value) });
        }
        return .{ .level = level, .division = division, .names = names.items, .iso = if (alpha2[0] == 0) iso else alpha2 };
    }

    pub const wayRole = boundaries.polygonRole;
};

fn countryCode(raw: []const u8) ?[2]u8 {
    if (raw.len != 2 or !std.ascii.isAlphabetic(raw[0]) or !std.ascii.isAlphabetic(raw[1])) return null;
    return .{ std.ascii.toUpper(raw[0]), std.ascii.toUpper(raw[1]) };
}

fn role(level: u8, place: []const u8) ?model.Division {
    if (level == 2) return .country;
    if (level < 3 or level > 12) return null;
    // OSM levels vary across jurisdictions, so prefer a settlement role
    // explicitly tagged on the boundary.
    if (eql(u8, place, "city") or eql(u8, place, "town") or eql(u8, place, "village") or eql(u8, place, "hamlet"))
        return .city;
    if (eql(u8, place, "suburb") or eql(u8, place, "quarter") or eql(u8, place, "neighbourhood"))
        return .district;
    return switch (level) {
        3, 4 => .state,
        5, 6 => .county,
        7, 8 => .city,
        9...12 => .district,
        else => unreachable,
    };
}

pub const Index = struct {
    catalog: boundaries.CatalogFor(Policy),
    tree: polygon_index.Index,
    records: []model.Admin,
    country_codes: []model.Span,
    owners: []const usize,
    areas: []const f64,
    hits: std.ArrayList(u32) = .empty,
    a: Allocator,
    deadline: io.Deadline,

    /// The scratch arena outlives the view. It owns the flat polygon arrays
    /// and the emitted records. The collector owns their geometry.
    pub fn build(a: Allocator, scratch: Allocator, pool: *tags.Pool, source: anytype, deadline: io.Deadline) !Index {
        var catalog = try boundaries.collectBoundaries(Policy, a, source, deadline);
        errdefer catalog.deinit();
        const records = try scratch.alloc(model.Admin, catalog.regions.len);
        const country_codes = try scratch.alloc(model.Span, catalog.regions.len);
        const areas = try scratch.alloc(f64, catalog.regions.len);
        const samples = try scratch.alloc(PointLL, catalog.regions.len);
        var polys: std.ArrayList(polygon.Polygon) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        for (catalog.regions, records, areas, samples, 0..) |region, *record, *area, *sample, i| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const first = pool.names.items.len;
            for (region.attrs.names) |label| {
                if (deadline.expired()) return error.DeadlineExceeded;
                try pool.addName(label.language, label.value);
            }
            record.* = .{
                .osm_id = region.osm_id,
                .names = try model.Span.init(first, region.attrs.names.len),
                .attr = .{ .division = region.attrs.division, .level = region.attrs.level },
            };
            country_codes[i] = if (region.attrs.division == .country and region.attrs.iso[0] != 0)
                try pool.text(&region.attrs.iso)
            else
                .{};
            var largest: f64 = -1;
            area.* = 0;
            for (region.geometry.polygons) |poly| {
                if (deadline.expired()) return error.DeadlineExceeded;
                try polys.append(scratch, poly);
                try owners.append(scratch, i);
                const size = @abs(try polygon.signedArea(poly.outer, deadline));
                area.* += size;
                if (size <= largest) continue;
                largest = size;
                sample.* = (try poly.representative(deadline)) orelse poly.outer[0];
            }
        }
        var index: Index = .{
            .catalog = catalog,
            .tree = try polygon_index.Index.init(a, polys.items, deadline),
            .records = records,
            .country_codes = country_codes,
            .owners = owners.items,
            .areas = areas,
            .a = a,
            .deadline = deadline,
        };
        errdefer index.tree.deinit();
        errdefer index.hits.deinit(a);
        for (records, samples, areas) |*record, sample, area| {
            const division = record.attr.division;
            if (division == .country) continue;
            const selected = try index.find(sample, area);
            var parent_role = @backingInt(division);
            while (parent_role != 0) {
                parent_role -= 1;
                const parent = selected.ids[parent_role];
                if (parent == .unknown) continue;
                record.parent = parent;
                break;
            }
        }
        return index;
    }

    pub fn deinit(self: *Index) void {
        self.hits.deinit(self.a);
        self.tree.deinit();
        self.catalog.deinit();
    }

    pub fn lookup(self: *Index, coordinate: model.Coordinate) !model.Hierarchy {
        return (try self.find(coordinate.toPoint(), 0)).hierarchy();
    }

    fn find(self: *Index, point: PointLL, min_area: f64) !admin_geometry.Choice {
        self.hits.clearRetainingCapacity();
        try self.tree.lookup(self.a, point, &self.hits, self.deadline);
        var selected: admin_geometry.Choice = .{};
        for (self.hits.items) |hit| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const i = self.owners[hit];
            const area = self.areas[i];
            if (area < min_area) continue;
            const id = std.math.cast(u32, i + 1) orelse return error.GeocodeSectionTooLarge;
            selected.add(self.records[i].attr.division, @fromBackingInt(id), area);
        }
        return selected;
    }
};
