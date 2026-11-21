//! Checked, immutable views over the geocoder's mmap sections.
const std = @import("std");
const io = @import("../infra/io.zig");
const model = @import("model.zig");
const house = @import("house_number.zig");
const interpolation = @import("interpolation.zig");
const postal = @import("postcode.zig");

const sections = std.enums.values(model.Section);
const address_section_count = @backingInt(model.Section.postcodes) - @backingInt(model.Section.street_ways);
const geometry_section_count = @backingInt(model.Section.admin_coordinates) - @backingInt(model.Section.postcodes);

pub const AdminGeometry = struct {
    admin_polygons: []const model.AdminPolygon = &.{},
    admin_rings: []const model.Span = &.{},
    admin_coordinates: []const model.Coordinate = &.{},

    fn validate(self: AdminGeometry, core: Data, deadline: io.Deadline) !void {
        for (self.admin_coordinates, 0..) |coordinate, i| {
            try checkAt(deadline, i);
            if (!coordinate.inRange()) return error.InvalidGeocodeAdminGeometry;
        }
        var next_ring: usize = 0;
        var next_point: usize = 0;
        for (self.admin_polygons, 0..) |entry, i| {
            try checkAt(deadline, i);
            if (entry.reserved != 0 or (try core.admin(entry.admin)) == null or
                entry.holes.first != next_ring or entry.outer.first != next_point or entry.outer.len < 3)
                return error.InvalidGeocodeAdminGeometry;
            const outer = try entry.outer.get(self.admin_coordinates);
            const holes = try entry.holes.get(self.admin_rings);
            next_point += outer.len;
            for (holes, 0..) |ring, j| {
                try checkAt(deadline, j);
                if (ring.first != next_point or ring.len < 3) return error.InvalidGeocodeAdminGeometry;
                next_point += (try ring.get(self.admin_coordinates)).len;
            }
            next_ring += holes.len;
        }
        if (next_ring != self.admin_rings.len or next_point != self.admin_coordinates.len)
            return error.InvalidGeocodeAdminGeometry;
    }
};

pub const AddressData = struct {
    country_codes: []const model.Span = &.{},
    street_shapes: []const model.Span = &.{},
    address_coordinates: []const model.Coordinate = &.{},
    street_houses: []const model.Span = &.{},
    house_links: []const model.HouseLink = &.{},
    interpolations: []const model.Interpolation = &.{},
    postcodes: []const model.Postcode = &.{},

    fn validate(self: AddressData, core: Data, deadline: io.Deadline) !void {
        if (self.country_codes.len != core.admins.len or self.street_shapes.len != core.street_ways.len or
            self.street_houses.len != core.streets.len)
            return error.InvalidGeocodeAddressIndex;
        for (self.country_codes, core.admins, 0..) |span, region, i| {
            try checkAt(deadline, i);
            const code = try span.get(core.text);
            if (code.len != 0 and (region.attr.division != .country or code.len != 2 or
                !std.ascii.isUpper(code[0]) or !std.ascii.isUpper(code[1])))
                return error.InvalidGeocodeAddressIndex;
        }
        for (self.address_coordinates, 0..) |coordinate, i| {
            try checkAt(deadline, i);
            if (!coordinate.inRange()) return error.InvalidGeocodeRecord;
        }
        for (self.street_shapes, 0..) |span, i| {
            try checkAt(deadline, i);
            try nonEmpty(span, self.address_coordinates);
        }
        for (self.interpolations, 0..) |range, i| {
            try checkAt(deadline, i);
            const shape = try range.shape.get(self.address_coordinates);
            if (shape.len < 2 or range.attr.reserved != 0 or range.reserved != 0 or range.first == range.last)
                return error.InvalidGeocodeAddressIndex;
            if (range.attr.mode == .alphabetic) {
                if (@max(range.first, range.last) > 26) return error.InvalidGeocodeAddressIndex;
            } else {
                if (range.alphabetic_base != 0) return error.InvalidGeocodeAddressIndex;
                if ((range.attr.mode == .even or range.attr.mode == .odd) and @max(range.first, range.last) > std.math.maxInt(u32) / 2)
                    return error.InvalidGeocodeAddressIndex;
            }
            try core.checkHierarchy(range.hierarchy);
        }
        var next_link: usize = 0;
        for (self.street_houses, core.streets, 0..) |span, street, i| {
            try checkAt(deadline, i);
            if (span.first != next_link) return error.InvalidGeocodeAddressIndex;
            const links = try span.get(self.house_links);
            var previous: ?house.Key = null;
            for (links, 0..) |link, j| {
                try checkAt(deadline, j);
                if (link.attr.reserved != 0 or link.street_way < street.ways.first or link.street_way - street.ways.first >= street.ways.len)
                    return error.InvalidGeocodeAddressIndex;
                const count = if (link.attr.kind == .exact) core.addresses.len else self.interpolations.len;
                if (link.object_id >= count) return error.InvalidGeocodeAddressIndex;
                const first = try link.first.key(core.text);
                if (previous) |key| if (key.order(first) == .gt) return error.InvalidGeocodeAddressIndex;
                if (link.attr.has_last and first.order(try link.last.key(core.text)) == .gt)
                    return error.InvalidGeocodeAddressIndex;
                _ = try link.unit.get(core.text);
                previous = first;
            }
            next_link += links.len;
        }
        if (next_link != self.house_links.len) return error.InvalidGeocodeAddressIndex;
        try self.validatePostcodes(core, deadline);
    }

    fn validatePostcodes(self: AddressData, core: Data, deadline: io.Deadline) !void {
        var previous: ?model.Postcode = null;
        for (self.postcodes, 0..) |postcode, i| {
            try checkAt(deadline, i);
            const code = try postcode.code.get(core.text);
            const canonical = postal.Code.normalize(code, "") orelse return error.InvalidGeocodePostcode;
            if (!std.mem.eql(u8, code, canonical.bytes()) or postcode.attr.reserved != 0 or
                (!postcode.attr.from_boundary and postcode.address_count == 0) or
                !postcode.center.inRange() or !postcode.min.inRange() or !postcode.max.inRange() or
                postcode.min.lat > postcode.center.lat or postcode.center.lat > postcode.max.lat)
                return error.InvalidGeocodePostcode;
            if (try core.admin(postcode.country)) |region| {
                if (region.attr.division != .country) return error.InvalidGeocodePostcode;
            }
            if (previous) |prior| {
                if (try comparePostcode(prior, postcode.country, code, core.text) != .lt)
                    return error.InvalidGeocodePostcode;
            }
            previous = postcode;
        }
    }
};

pub const Coverage = struct {
    country: usize = 0,
    city: usize = 0,
    country_and_city: usize = 0,

    noinline fn count(self: *Coverage, records: anytype, deadline: io.Deadline) !void {
        for (records, 0..) |*entry, i| {
            try checkAt(deadline, i);
            const hierarchy = &entry.record.hierarchy;
            const has_country = @backingInt(hierarchy.country) != 0;
            const has_city = @backingInt(hierarchy.city) != 0;
            self.country += @intFromBool(has_country);
            self.city += @intFromBool(has_city);
            self.country_and_city += @intFromBool(has_country and has_city);
        }
    }
};

pub const Data = struct {
    places: []const model.Place = &.{},
    streets: []const model.Street = &.{},
    addresses: []const model.Address = &.{},
    pois: []const model.Poi = &.{},
    admins: []const model.Admin = &.{},
    names: []const model.Name = &.{},
    text: []const u8 = &.{},
    street_ways: []const i64 = &.{},
    address_data: ?AddressData = null,
    admin_geometry: ?AdminGeometry = null,

    pub fn coverage(self: Data, deadline: io.Deadline) !Coverage {
        var result: Coverage = .{};
        try result.count(self.places, deadline);
        try result.count(self.streets, deadline);
        try result.count(self.addresses, deadline);
        try result.count(self.pois, deadline);
        return result;
    }

    pub fn validate(self: Data, deadline: io.Deadline) !void {
        if (deadline.expired()) return error.DeadlineExceeded;
        for (self.names, 0..) |name, i| {
            try checkAt(deadline, i);
            _ = try name.language.get(self.text);
            try nonEmpty(name.text, self.text);
        }
        for (self.admins, 0..) |region, i| {
            try checkAt(deadline, i);
            _ = try region.names.get(self.names);
            const role = @backingInt(region.attr.division);
            if (role > @backingInt(model.Division.district) or region.attr.reserved != 0 or
                region.attr.level < 2 or region.attr.level > 12)
                return error.InvalidGeocodeAdmin;
            if (try self.admin(region.parent)) |parent| {
                if (@backingInt(parent.attr.division) >= role) return error.InvalidGeocodeAdmin;
            }
        }
        for (self.places, 0..) |place, i| {
            try checkAt(deadline, i);
            try self.checkRecord(place.record);
            try nonEmpty(place.kind, self.text);
            if (place.reserved != 0) return error.InvalidGeocodeRecord;
        }
        for (self.streets, 0..) |street, i| {
            try checkAt(deadline, i);
            try self.checkRecord(street.record);
            try nonEmpty(street.kind, self.text);
            try nonEmpty(street.ways, self.street_ways);
            if (street.record.attr.source != .way or street.record.names.len == 0)
                return error.InvalidGeocodeRecord;
        }
        for (self.addresses, 0..) |address, i| {
            try checkAt(deadline, i);
            try self.checkRecord(address.record);
            _ = try address.number.get(self.text);
            _ = try address.house_name.get(self.text);
            if (address.number.len == 0 and address.house_name.len == 0) return error.InvalidGeocodeRecord;
            _ = try address.street.get(self.text);
            _ = try address.place.get(self.text);
            _ = try address.unit.get(self.text);
        }
        for (self.pois, 0..) |poi, i| {
            try checkAt(deadline, i);
            try self.checkRecord(poi.record);
            try nonEmpty(poi.category, self.text);
            try nonEmpty(poi.kind, self.text);
        }
        if (self.address_data) |addresses| try addresses.validate(self, deadline);
        if (self.admin_geometry) |geometry| try geometry.validate(self, deadline);
    }

    pub fn admin(self: Data, id: model.AdminId) !?model.Admin {
        const raw = @backingInt(id);
        if (raw == 0) return null;
        if (raw > self.admins.len) return error.InvalidGeocodeAdmin;
        return self.admins[raw - 1];
    }

    pub fn countryIso(self: Data, id: model.AdminId) ![]const u8 {
        const addresses = self.address_data orelse return "";
        if (try self.admin(id)) |region| {
            if (region.attr.division != .country) return error.InvalidGeocodeAdmin;
            const row = @backingInt(id) - 1;
            if (row >= addresses.country_codes.len) return error.InvalidGeocodeAddressIndex;
            return addresses.country_codes[row].get(self.text);
        }
        return "";
    }

    pub fn lookupPostcode(self: Data, country: model.AdminId, raw: []const u8) !?model.Postcode {
        const addresses = self.address_data orelse return null;
        const code = postal.Code.normalize(raw, try self.countryIso(country)) orelse return null;
        var low: usize = 0;
        var high = addresses.postcodes.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = addresses.postcodes[middle];
            switch (try comparePostcode(candidate, country, code.bytes(), self.text)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return candidate,
            }
        }
        return null;
    }

    pub fn estimateInterpolation(self: Data, index: u32, label: house.Label, deadline: io.Deadline) !?interpolation.Estimate {
        const addresses = self.address_data orelse return null;
        if (index >= addresses.interpolations.len) return null;
        const row = addresses.interpolations[index];
        return row.range().locate(label, try row.shape.get(addresses.address_coordinates), deadline);
    }

    fn checkRecord(self: Data, record: model.Record) !void {
        if (!record.coordinate.inRange() or record.attr.reserved != 0 or
            @backingInt(record.attr.source) > @backingInt(model.Source.relation))
            return error.InvalidGeocodeRecord;
        _ = try record.names.get(self.names);
        try self.checkHierarchy(record.hierarchy);
    }

    fn checkHierarchy(self: Data, hierarchy: model.Hierarchy) !void {
        _ = try hierarchy.postcode.get(self.text);
        inline for (std.enums.values(model.Division)) |division| {
            const id = @field(hierarchy, @tagName(division));
            if (try self.admin(id)) |region| {
                if (region.attr.division != division) return error.InvalidGeocodeAdmin;
            }
        }
    }
};

fn comparePostcode(row: model.Postcode, country: model.AdminId, code: []const u8, text: []const u8) !std.math.Order {
    const countries = std.math.order(@backingInt(row.country), @backingInt(country));
    return if (countries == .eq) std.mem.order(u8, try row.code.get(text), code) else countries;
}

pub const Bundle = struct {
    uuid: model.DatasetUuid,
    data: Data,
    mappings: [sections.len]?io.Mapping,

    pub fn open(path: []const u8, deadline: io.Deadline) !Bundle {
        const dir = try io.Directory.open(path);
        defer dir.close();
        return openInDir(dir, deadline);
    }

    pub fn openInDir(dir: io.Directory, deadline: io.Deadline) !Bundle {
        var result: Bundle = .{ .uuid = undefined, .data = .{}, .mappings = @splat(null) };
        errdefer result.close();
        var addresses: AddressData = .{};
        var geometry: AdminGeometry = .{};
        var address_files: usize = 0;
        var geometry_files: usize = 0;
        inline for (sections, 0..) |section, i| {
            const mapping: ?io.Mapping = map(dir, section) catch |err| blk: {
                if ((section.addressSection() or section.geometrySection()) and err == error.FileNotFound) break :blk null;
                return err;
            };
            if (mapping) |present| {
                result.mappings[i] = present;
                const decoded = try model.readSection(section, present.bytes, if (i == 0) null else result.uuid, deadline);
                result.uuid = decoded.uuid;
                if (comptime section.addressSection()) {
                    @field(addresses, @tagName(section)) = decoded.records;
                    address_files += 1;
                } else if (comptime section.geometrySection()) {
                    @field(geometry, @tagName(section)) = decoded.records;
                    geometry_files += 1;
                } else {
                    @field(result.data, @tagName(section)) = decoded.records;
                }
            }
        }
        if (address_files == address_section_count) {
            result.data.address_data = addresses;
        } else if (address_files != 0) return error.IncompleteGeocodeAddressIndex;
        if (geometry_files == geometry_section_count) {
            result.data.admin_geometry = geometry;
        } else if (geometry_files != 0) return error.IncompleteGeocodeAdminGeometry;
        try result.data.validate(deadline);
        return result;
    }

    pub fn close(self: *Bundle) void {
        for (self.mappings) |mapping| if (mapping) |present| present.unmap();
        self.* = undefined;
    }
};

fn map(dir: io.Directory, section: model.Section) !io.Mapping {
    const file = try dir.readFile(section.filename());
    defer file.close();
    return io.Mapping.mapFd(file, .read_only);
}

pub fn write(path: []const u8, uuid: model.DatasetUuid, data: Data, deadline: io.Deadline) !void {
    try data.validate(deadline);
    const name = std.fs.path.basename(path);
    if (name.len == 0 or name.len > std.fs.max_name_bytes or std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.InvalidArgument;
    var target: [std.fs.max_name_bytes:0]u8 = @splat(0);
    @memcpy(target[0..name.len], name);
    const parent = try io.Directory.open(std.fs.path.dirname(path) orelse ".");
    defer parent.close();
    const staged = try parent.temporaryChild();
    defer staged.dir.close();
    var published = false;
    errdefer if (!published) {
        for (sections) |section| staged.dir.deleteFile(section.filename()) catch {};
        parent.deleteDir(&staged.name) catch {};
    };
    inline for (sections) |section| {
        if (comptime section.addressSection()) {
            if (data.address_data) |addresses| {
                try writeRecords(staged.dir, section, uuid, @field(addresses, @tagName(section)), deadline);
            }
        } else if (comptime section.geometrySection()) {
            if (data.admin_geometry) |geometry| {
                try writeRecords(staged.dir, section, uuid, @field(geometry, @tagName(section)), deadline);
            }
        } else {
            try writeRecords(staged.dir, section, uuid, @field(data, @tagName(section)), deadline);
        }
    }
    try staged.dir.sync();
    if (deadline.expired()) return error.DeadlineExceeded;
    try parent.renameExclusive(&staged.name, target[0..name.len :0]);
    published = true;
    try parent.sync();
}

fn writeRecords(dir: io.Directory, comptime section: model.Section, uuid: model.DatasetUuid, records: []const section.Item(), deadline: io.Deadline) !void {
    try writeSection(dir, section, uuid, @sizeOf(section.Item()), records.len, std.mem.sliceAsBytes(records), deadline);
}

noinline fn writeSection(dir: io.Directory, section: model.Section, uuid: model.DatasetUuid, size: u32, count: usize, bytes: []const u8, deadline: io.Deadline) !void {
    const file = try dir.createFile(section.filename());
    defer file.close();
    var hash = std.hash.XxHash3.init(0);
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const chunk = bytes[offset..@min(offset +| (1 << 20), bytes.len)];
        io.updateFileHash(&hash, chunk);
        try file.pwriteAll(chunk, model.payload_offset + @as(u64, offset));
        offset += chunk.len;
    }
    const header: model.Header = .{
        .magic_tag = model.magic,
        .format_version = model.version,
        .kind = @backingInt(section),
        .dataset_uuid = uuid,
        .record_size = size,
        .count = count,
        .payload_hash = hash.final(),
    };
    try file.pwriteAll(std.mem.asBytes(&header), 0);
    try file.truncate(model.payload_offset + @as(u64, offset));
    try file.sync();
}

fn nonEmpty(span: model.Span, source: anytype) !void {
    if ((try span.get(source)).len == 0) return error.InvalidGeocodeSpan;
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

test "mmap geocode sections validate references, identity and checksum" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/geocode", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const uuid: model.DatasetUuid = @splat(42);
    const name: model.Span = .{ .len = 4 };
    const input: Data = .{
        .text = "Towncity",
        .names = &.{.{ .text = name }},
        .admins = &.{.{ .osm_id = 12, .names = .{ .len = 1 }, .attr = .{ .division = .city, .level = 8 } }},
        .places = &.{.{
            .record = .{
                .osm_id = 1,
                .coordinate = .{ .lng = 20, .lat = 10 },
                .names = .{ .len = 1 },
                .hierarchy = .{ .city = @fromBackingInt(@intCast(1)) },
                .attr = .{ .source = .node, .importance = 300 },
            },
            .kind = .{ .first = 4, .len = 4 },
        }},
    };
    try write(path, uuid, input, .none);
    try testing.expectError(error.PathAlreadyExists, write(path, @splat(3), .{}, .none));
    {
        var opened = try Bundle.open(path, .none);
        defer opened.close();
        try testing.expectEqual(uuid, opened.uuid);
        try testing.expectEqual(12, (try opened.data.admin(opened.data.places[0].record.hierarchy.city)).?.osm_id);
        try testing.expectEqualStrings("Town", try (try opened.data.places[0].record.names.get(opened.data.names))[0].text.get(opened.data.text));
    }
    const dir = try io.Directory.open(path);
    defer dir.close();
    const file = try dir.readWriteFile(model.Section.text.filename());
    defer file.close();
    try file.pwriteAll("D", model.payload_offset);
    try testing.expectError(error.GeocodeHashMismatch, Bundle.open(path, .none));
}
