//! Checked, immutable views over the geocoder's mmap sections.
const std = @import("std");
const io = @import("../infra/io.zig");
const model = @import("model.zig");

const sections = std.enums.values(model.Section);

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
    }

    pub fn admin(self: Data, id: model.AdminId) !?model.Admin {
        const raw = @backingInt(id);
        if (raw == 0) return null;
        if (raw > self.admins.len) return error.InvalidGeocodeAdmin;
        return self.admins[raw - 1];
    }

    fn checkRecord(self: Data, record: model.Record) !void {
        if (!record.coordinate.inRange() or record.attr.reserved != 0 or
            @backingInt(record.attr.source) > @backingInt(model.Source.relation))
            return error.InvalidGeocodeRecord;
        _ = try record.names.get(self.names);
        _ = try record.hierarchy.postcode.get(self.text);
        inline for (std.enums.values(model.Division)) |division| {
            const id = @field(record.hierarchy, @tagName(division));
            if (try self.admin(id)) |region| {
                if (region.attr.division != division) return error.InvalidGeocodeAdmin;
            }
        }
    }
};

pub const Bundle = struct {
    uuid: model.DatasetUuid,
    data: Data,
    mappings: [sections.len]io.Mapping,

    pub fn open(path: []const u8, deadline: io.Deadline) !Bundle {
        const dir = try io.Directory.open(path);
        defer dir.close();
        var result: Bundle = .{ .uuid = undefined, .data = .{}, .mappings = undefined };
        var mapped: usize = 0;
        errdefer for (result.mappings[0..mapped]) |mapping| mapping.unmap();
        inline for (sections, 0..) |section, i| {
            const mapping = try map(dir, section);
            result.mappings[i] = mapping;
            mapped += 1;
            const decoded = try model.readSection(section, mapping.bytes, if (i == 0) null else result.uuid, deadline);
            result.uuid = decoded.uuid;
            @field(result.data, @tagName(section)) = decoded.records;
        }
        try result.data.validate(deadline);
        return result;
    }

    pub fn close(self: *Bundle) void {
        for (self.mappings) |mapping| mapping.unmap();
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
        const records = @field(data, @tagName(section));
        try writeSection(staged.dir, section, uuid, @sizeOf(section.Item()), records.len, std.mem.sliceAsBytes(records), deadline);
    }
    try staged.dir.sync();
    if (deadline.expired()) return error.DeadlineExceeded;
    try parent.renameExclusive(&staged.name, target[0..name.len :0]);
    published = true;
    try parent.sync();
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
