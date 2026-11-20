//! Portable mmap record layouts for OSM geocoding extracts.
const std = @import("std");
const graph = @import("../graph/format.zig");
const io = @import("../infra/io.zig");
const house = @import("house_number.zig");
const interpolation = @import("interpolation.zig");

pub const attribution = "© OpenStreetMap contributors";
pub const attribution_url = "https://www.openstreetmap.org/copyright";
pub const license = "ODbL-1.0";
pub const magic = "ZRGEOCOD".*;
pub const version = 1;
pub const Header = graph.SectionHeader;
pub const DatasetUuid = graph.DatasetUuid;
pub const payload_offset = graph.payload_offset;
pub const Coordinate = graph.Coordinate;

pub const Source = enum(u2) { node, way, relation, _ };
pub const Division = enum(u3) { country, state, county, city, district, _ };
pub const AdminId = enum(u32) { unknown = 0, _ };

pub const Span = extern struct {
    first: u32 = 0,
    len: u32 = 0,

    pub fn init(first: usize, len: usize) error{GeocodeSectionTooLarge}!Span {
        return .{
            .first = std.math.cast(u32, first) orelse return error.GeocodeSectionTooLarge,
            .len = std.math.cast(u32, len) orelse return error.GeocodeSectionTooLarge,
        };
    }

    pub fn get(self: Span, data: anytype) error{InvalidGeocodeSpan}!@TypeOf(data) {
        if (self.first > data.len or self.len > data.len - self.first) return error.InvalidGeocodeSpan;
        return data[self.first..][0..self.len];
    }
};

/// An empty language span denotes the unqualified OSM name.
pub const Name = extern struct {
    language: Span = .{},
    text: Span,
};

pub const Hierarchy = extern struct {
    country: AdminId = .unknown,
    state: AdminId = .unknown,
    county: AdminId = .unknown,
    city: AdminId = .unknown,
    district: AdminId = .unknown,
    postcode: Span = .{},
};

pub const Record = extern struct {
    osm_id: i64,
    coordinate: Coordinate,
    names: Span = .{},
    hierarchy: Hierarchy = .{},
    attr: packed struct(u32) {
        source: Source,
        importance: u16,
        reserved: u14 = 0,
    },
};

pub const Place = extern struct {
    record: Record,
    kind: Span,
    population: u32 = 0,
    reserved: u32 = 0,
};

pub const Street = extern struct {
    record: Record,
    kind: Span,
    ways: Span,
};

pub const Address = extern struct {
    record: Record,
    number: Span = .{},
    house_name: Span = .{},
    street: Span = .{},
    place: Span = .{},
    unit: Span = .{},
};

pub const Poi = extern struct {
    record: Record,
    category: Span,
    kind: Span,
};

pub const Admin = extern struct {
    osm_id: i64,
    names: Span,
    parent: AdminId = .unknown,
    attr: packed struct(u32) {
        division: Division,
        level: u8,
        reserved: u21 = 0,
    },
};

pub const HouseKey = extern struct {
    number: u32,
    fraction: packed struct(u32) {
        numerator: u16 = 0,
        denominator: u16 = 1,
    } = .{},
    letters: Span = .{},

    pub fn key(self: HouseKey, text: []const u8) !house.Key {
        if (self.fraction.numerator >= self.fraction.denominator) return error.InvalidGeocodeHouseKey;
        return .{
            .number = self.number,
            .fraction = .{ .numerator = self.fraction.numerator, .denominator = self.fraction.denominator },
            .letters = try self.letters.get(text),
        };
    }
};

pub const HouseLink = extern struct {
    /// Zero-based address or interpolation row, selected by kind.
    object_id: u32,
    /// Zero-based row in the member-way sections.
    street_way: u32,
    /// Fraction along this member way on the full u32 range.
    position: u32,
    attr: packed struct(u32) {
        kind: enum(u1) { exact, interpolation },
        has_last: bool = false,
        reserved: u30 = 0,
    },
    first: HouseKey,
    last: HouseKey = .{ .number = 0 },
    unit: Span = .{},
};

pub const Interpolation = extern struct {
    osm_id: i64,
    first: u32,
    last: u32,
    alphabetic_base: u32,
    attr: packed struct(u32) {
        mode: interpolation.Mode,
        reserved: u30 = 0,
    },
    shape: Span,
    hierarchy: Hierarchy,
    reserved: u32 = 0,

    pub fn range(self: Interpolation) interpolation.Range {
        return .{ .mode = self.attr.mode, .first = self.first, .last = self.last, .alphabetic_base = self.alphabetic_base };
    }
};

pub const Postcode = extern struct {
    code: Span,
    country: AdminId,
    address_count: u32,
    center: Coordinate,
    /// Longitude min greater than max denotes an extent across the antimeridian.
    min: Coordinate,
    max: Coordinate,
    attr: packed struct(u32) {
        from_boundary: bool,
        reserved: u31 = 0,
    },
};

pub const Section = enum(u32) {
    places = 1,
    streets = 2,
    addresses = 3,
    pois = 4,
    admins = 5,
    names = 6,
    text = 7,
    street_ways = 8,
    country_codes = 9,
    street_shapes = 10,
    address_coordinates = 11,
    street_houses = 12,
    house_links = 13,
    interpolations = 14,
    postcodes = 15,

    pub fn addressSection(self: Section) bool {
        return @backingInt(self) >= @backingInt(Section.country_codes);
    }

    pub fn filename(self: Section) [:0]const u8 {
        return switch (self) {
            .places => "places.bin",
            .streets => "streets.bin",
            .addresses => "addresses.bin",
            .pois => "pois.bin",
            .admins => "admins.bin",
            .names => "names.bin",
            .text => "text.bin",
            .street_ways => "street-ways.bin",
            .country_codes => "country-codes.bin",
            .street_shapes => "street-shapes.bin",
            .address_coordinates => "address-coordinates.bin",
            .street_houses => "street-houses.bin",
            .house_links => "house-links.bin",
            .interpolations => "interpolations.bin",
            .postcodes => "postcodes.bin",
        };
    }

    pub fn Item(comptime self: Section) type {
        return switch (self) {
            .places => Place,
            .streets => Street,
            .addresses => Address,
            .pois => Poi,
            .admins => Admin,
            .names => Name,
            .text => u8,
            .street_ways => i64,
            .country_codes, .street_shapes, .street_houses => Span,
            .address_coordinates => Coordinate,
            .house_links => HouseLink,
            .interpolations => Interpolation,
            .postcodes => Postcode,
        };
    }
};

pub fn readSection(comptime section: Section, bytes: []const u8, uuid: ?DatasetUuid, deadline: io.Deadline) !struct { uuid: DatasetUuid, records: []const section.Item() } {
    if (deadline.expired()) return error.DeadlineExceeded;
    if (bytes.len < payload_offset) return error.InvalidGeocodeHeader;
    const header = (try io.typedSlice(Header, bytes, 0, 1))[0];
    if (!std.mem.eql(u8, &header.magic_tag, &magic) or header.format_version != version or
        header.kind != @backingInt(section) or header.record_size != @sizeOf(section.Item()) or
        header.reserved != 0 or !std.mem.allEqual(u8, &header.reserved_tail, 0))
        return error.InvalidGeocodeHeader;
    if (uuid) |expected| {
        if (!std.mem.eql(u8, &header.dataset_uuid, &expected)) return error.GeocodeDatasetUuidMismatch;
    }
    const payload = bytes[payload_offset..];
    const count = std.math.cast(usize, header.count) orelse return error.InvalidGeocodeCount;
    if (payload.len % @sizeOf(section.Item()) != 0 or payload.len / @sizeOf(section.Item()) != count)
        return error.InvalidGeocodeCount;
    if (try checksum(payload, deadline) != header.payload_hash) return error.GeocodeHashMismatch;
    return .{ .uuid = header.dataset_uuid, .records = try io.typedSlice(section.Item(), bytes, payload_offset, count) };
}

pub fn checksum(bytes: []const u8, deadline: io.Deadline) !u64 {
    var hash = std.hash.XxHash3.init(0);
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const chunk = bytes[offset..@min(offset +| (1 << 20), bytes.len)];
        io.updateFileHash(&hash, chunk);
        offset += chunk.len;
    }
    return hash.final();
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Span) == 8 and @offsetOf(Span, "first") == 0 and @offsetOf(Span, "len") == 4);
    std.debug.assert(@sizeOf(Name) == 16 and @offsetOf(Name, "language") == 0 and @offsetOf(Name, "text") == 8);
    std.debug.assert(@sizeOf(Hierarchy) == 28 and @offsetOf(Hierarchy, "country") == 0 and @offsetOf(Hierarchy, "state") == 4 and
        @offsetOf(Hierarchy, "county") == 8 and @offsetOf(Hierarchy, "city") == 12 and
        @offsetOf(Hierarchy, "district") == 16 and @offsetOf(Hierarchy, "postcode") == 20);
    std.debug.assert(@sizeOf(Record) == 56 and @offsetOf(Record, "osm_id") == 0 and @offsetOf(Record, "coordinate") == 8 and
        @offsetOf(Record, "names") == 16 and @offsetOf(Record, "hierarchy") == 24 and @offsetOf(Record, "attr") == 52);
    std.debug.assert(@sizeOf(Place) == 72 and @offsetOf(Place, "record") == 0 and @offsetOf(Place, "kind") == 56 and
        @offsetOf(Place, "population") == 64 and @offsetOf(Place, "reserved") == 68);
    std.debug.assert(@sizeOf(Street) == 72 and @offsetOf(Street, "record") == 0 and @offsetOf(Street, "kind") == 56 and @offsetOf(Street, "ways") == 64);
    std.debug.assert(@sizeOf(Address) == 96 and @offsetOf(Address, "record") == 0 and @offsetOf(Address, "number") == 56 and
        @offsetOf(Address, "house_name") == 64 and @offsetOf(Address, "street") == 72 and @offsetOf(Address, "place") == 80 and
        @offsetOf(Address, "unit") == 88);
    std.debug.assert(@sizeOf(Poi) == 72 and @offsetOf(Poi, "record") == 0 and @offsetOf(Poi, "category") == 56 and @offsetOf(Poi, "kind") == 64);
    std.debug.assert(@sizeOf(Admin) == 24 and @offsetOf(Admin, "osm_id") == 0 and @offsetOf(Admin, "names") == 8 and
        @offsetOf(Admin, "parent") == 16 and @offsetOf(Admin, "attr") == 20);
    std.debug.assert(@sizeOf(HouseKey) == 16 and @offsetOf(HouseKey, "number") == 0 and @offsetOf(HouseKey, "fraction") == 4 and
        @offsetOf(HouseKey, "letters") == 8);
    std.debug.assert(@sizeOf(HouseLink) == 56 and @offsetOf(HouseLink, "object_id") == 0 and @offsetOf(HouseLink, "street_way") == 4 and
        @offsetOf(HouseLink, "position") == 8 and @offsetOf(HouseLink, "attr") == 12 and @offsetOf(HouseLink, "first") == 16 and
        @offsetOf(HouseLink, "last") == 32 and @offsetOf(HouseLink, "unit") == 48);
    std.debug.assert(@sizeOf(Interpolation) == 64 and @offsetOf(Interpolation, "osm_id") == 0 and @offsetOf(Interpolation, "first") == 8 and
        @offsetOf(Interpolation, "last") == 12 and @offsetOf(Interpolation, "alphabetic_base") == 16 and @offsetOf(Interpolation, "attr") == 20 and
        @offsetOf(Interpolation, "shape") == 24 and @offsetOf(Interpolation, "hierarchy") == 32 and @offsetOf(Interpolation, "reserved") == 60);
    std.debug.assert(@sizeOf(Postcode) == 44 and @offsetOf(Postcode, "code") == 0 and @offsetOf(Postcode, "country") == 8 and
        @offsetOf(Postcode, "address_count") == 12 and @offsetOf(Postcode, "center") == 16 and @offsetOf(Postcode, "min") == 24 and
        @offsetOf(Postcode, "max") == 32 and @offsetOf(Postcode, "attr") == 40);
    std.debug.assert(payload_offset % @alignOf(Record) == 0);
}

test "geocode text spans borrow only their checked range" {
    const testing = std.testing;
    const name = try Span.init(2, 4);
    try testing.expectEqualStrings("town", try name.get(@as([]const u8, "A town")));
    try testing.expectError(error.InvalidGeocodeSpan, name.get(@as([]const u8, "short")));
}
