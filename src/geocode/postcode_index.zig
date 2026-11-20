//! Build sorted postcode rows from the primary extract's features and areas.
const std = @import("std");
const io = @import("../infra/io.zig");
const boundaries = @import("../build/admin_boundaries.zig");
const pbf = @import("../build/pbf/root.zig");
const polygon = @import("../geo/polygon.zig");
const admin = @import("admin.zig");
const model = @import("model.zig");
const postal = @import("postcode.zig");
const tags = @import("tags.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const Policy = struct {
    pub const Attributes = []const u8;
    pub const wayRole = boundaries.polygonRole;

    pub fn read(owned: Allocator, relation: pbf.block.Relation, _: io.Deadline) !?Attributes {
        var boundary: bool = false;
        var code: []const u8 = "";
        var input = relation.tags;
        while (try input.next()) |tag| {
            if (eql(u8, tag.key, "boundary")) boundary = eql(u8, tag.value, "postal_code");
            if (eql(u8, tag.key, "postal_code")) code = tag.value;
        }
        if (!boundary or code.len == 0) return null;
        return try owned.dupe(u8, code);
    }
};

const Key = struct { country: model.AdminId, code: model.Span };

pub const Builder = struct {
    a: Allocator,
    pool: *tags.Pool,
    admins: *admin.Index,
    deadline: io.Deadline,
    entries: std.AutoArrayHashMapUnmanaged(Key, postal.Accumulator) = .empty,

    pub fn deinit(self: *Builder) void {
        self.entries.deinit(self.a);
    }

    pub fn point(self: *Builder, country: model.AdminId, raw: []const u8, coordinate: model.Coordinate) !void {
        const iso = try self.countryIso(country);
        var tokens = std.mem.splitScalar(u8, raw, ';');
        while (tokens.next()) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const code = postal.Code.normalize(token, iso) orelse continue;
            try (try self.entry(country, code.bytes())).addPoint(coordinate);
        }
    }

    pub fn area(self: *Builder, raw: []const u8, shape: polygon.Polygon) !void {
        const anchor = try shape.representative(self.deadline) orelse return;
        const country = (try self.admins.lookup(anchor.toFixed())).country;
        const iso = try self.countryIso(country);
        var tokens = std.mem.splitScalar(u8, raw, ';');
        while (tokens.next()) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const code = postal.Code.normalize(token, iso) orelse continue;
            try (try self.entry(country, code.bytes())).addPolygon(shape, self.deadline);
        }
    }

    pub fn relations(self: *Builder, source: pbf.file.IndexedStreams) !void {
        if (self.deadline.expired()) return error.DeadlineExceeded;
        var catalog = try boundaries.collectBoundaries(Policy, self.a, source, self.deadline);
        defer catalog.deinit();
        for (catalog.regions) |region| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            for (region.geometry.polygons) |shape| try self.area(region.attrs, shape);
        }
    }

    pub fn records(self: Builder, owned: Allocator) ![]const model.Postcode {
        const result = try owned.alloc(model.Postcode, self.entries.count());
        var count: usize = 0;
        for (self.entries.keys(), self.entries.values()) |key, accumulated| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const summary = accumulated.summary() orelse continue;
            result[count] = .{
                .code = key.code,
                .country = key.country,
                .address_count = summary.address_count,
                .center = summary.center,
                .min = summary.extent.min,
                .max = summary.extent.max,
                .attr = .{ .from_boundary = summary.from_boundary },
            };
            count += 1;
        }
        std.mem.sortUnstable(model.Postcode, result[0..count], @as([]const u8, self.pool.bytes.items), less);
        return result[0..count];
    }

    fn entry(self: *Builder, country: model.AdminId, code: []const u8) !*postal.Accumulator {
        const key: Key = .{ .country = country, .code = try self.pool.text(code) };
        const slot = try self.entries.getOrPut(self.a, key);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        return slot.value_ptr;
    }

    fn countryIso(self: Builder, country: model.AdminId) ![]const u8 {
        if (country == .unknown) return "";
        return self.pool.stableText(self.admins.country_codes[@backingInt(country) - 1]);
    }

    fn less(text: []const u8, a: model.Postcode, b: model.Postcode) bool {
        if (a.country != b.country) return @backingInt(a.country) < @backingInt(b.country);
        return std.mem.lessThan(u8, text[a.code.first..][0..a.code.len], text[b.code.first..][0..b.code.len]);
    }
};
