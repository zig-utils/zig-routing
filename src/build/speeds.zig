// Ported from src/mjolnir/speed_assigner.h (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/constants.zig");
const EdgeClass = @import("../graph/class_table.zig").EdgeClass;
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;

const max_rural_density = 8;
const urban_speed = [8]u8{ 89, 73, 57, 49, 40, 35, 30, 20 };

pub const Region = struct {
    country: []const u8 = "",
    state: []const u8 = "",
};

const Table = struct {
    way: [8]?u32,
    link_exiting: [5]?u32,
    link_turning: [5]?u32,
    roundabout: [8]?u32,
    driveway: ?u32,
    alley: ?u32,
    parking_aisle: ?u32,
    @"drive-through": ?u32,

    fn speed(self: *const Table, class: EdgeClass, use: graph.Use, signed: bool) ?u32 {
        switch (use) {
            .driveway => return self.driveway,
            .alley => return self.alley,
            .parking_aisle => return self.parking_aisle,
            .drive_through => return self.@"drive-through",
            else => {},
        }
        const rc = class.category.road_class;
        if (class.flags.link) {
            if (rc >= self.link_exiting.len) return null;
            return if (signed) self.link_exiting[rc] else self.link_turning[rc];
        }
        return if (class.flags.roundabout) self.roundabout[rc] else self.way[rc];
    }
};

const Rule = struct {
    @"iso3166-1": ?[]const u8 = null,
    @"iso3166-2": ?[]const u8 = null,
    rural: Table,
    suburban: Table,
    urban: Table,

    fn region(self: *const Rule) !Region {
        const country = self.@"iso3166-1" orelse return .{};
        if (country.len == 0) return error.InvalidSpeedRegion;
        const state = if (self.@"iso3166-2") |state| value: {
            if (state.len == 0) return error.InvalidSpeedRegion;
            break :value state;
        } else "";
        return .{ .country = country, .state = state };
    }
};

const RegionContext = struct {
    pub fn hash(_: RegionContext, key: Region) u64 {
        return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, key.country), key.state);
    }

    pub fn eql(_: RegionContext, a: Region, b: Region) bool {
        return std.mem.eql(u8, a.country, b.country) and std.mem.eql(u8, a.state, b.state);
    }
};

pub const Config = struct {
    const Lookup = std.HashMapUnmanaged(Region, *const Rule, RegionContext, std.hash_map.default_max_load_percentage);
    const vehicle_access: u16 = @bitCast(graph.AccessMask{
        .auto = true,
        .truck = true,
        .moped = true,
        .motorcycle = true,
        .taxi = true,
        .bus = true,
        .hov = true,
    });

    parsed: std.json.Parsed([]const Rule),
    lookup: Lookup,

    pub fn parse(allocator: Allocator, bytes: []const u8, deadline: Deadline) !Config {
        if (deadline.expired()) return error.DeadlineExceeded;
        const parsed = try std.json.parseFromSlice([]const Rule, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        var lookup: Lookup = .empty;
        errdefer lookup.deinit(allocator);
        for (parsed.value, 0..) |*rule, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const entry = try lookup.getOrPut(allocator, try rule.region());
            if (entry.found_existing) return error.DuplicateSpeedRegion;
            entry.value_ptr.* = rule;
        }
        return .{ .parsed = parsed, .lookup = lookup };
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        self.lookup.deinit(allocator);
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn speed(self: *const Config, region: Region, class: EdgeClass, density: u4, signed: bool) ?u8 {
        const use: graph.Use = @fromBackingInt(@intCast(class.category.use));
        if (use == .ferry or use == .rail_ferry or (class.access.forward | class.access.reverse) & vehicle_access == 0)
            return null;
        const rule = self.lookup.get(region) orelse self.lookup.get(.{ .country = region.country }) orelse self.lookup.get(.{}) orelse return null;
        const table = if (density <= 5) &rule.rural else if (density <= 10) &rule.suburban else &rule.urban;
        const value = table.speed(class, use, signed) orelse return null;
        return if (value == 0) null else @intCast(@min(graph.max_assumed_speed, value));
    }
};

pub const DefaultOptions = struct {
    infer_turn_channels: bool = true,
    ferry_duration: bool = false,
};

/// Conventional speed assignment when the admin speed table supplies no value.
/// Density is taken at the source node, before the endpoint average is stored
/// in the directed edge's class.
pub fn defaultSpeed(class: EdgeClass, initial_speed: u8, length: u24, density: u4, options: DefaultOptions) u8 {
    const use: graph.Use = @fromBackingInt(@intCast(class.category.use));
    if (class.flags.link) {
        const factor: f32 = if (use == .turn_channel and options.infer_turn_channels)
            1.25
        else if (use == .ramp and !class.flags.tagged_speed)
            if (class.category.road_class <= @backingInt(graph.RoadClass.primary) and density > max_rural_density) 0.8 else 0.85
        else
            return initial_speed;
        return scaled(initial_speed, factor);
    }

    const rough = class.category.surface >= @backingInt(graph.Surface.paved_rough);
    if (class.flags.tagged_speed) {
        if (!rough) return initial_speed;
        if (initial_speed >= 50) return initial_speed - 10;
        if (initial_speed > 15) return initial_speed - 5;
        return initial_speed;
    }

    switch (use) {
        .rail_ferry => return 65,
        .ferry => return if (options.ferry_duration) initial_speed else if (length < 2000) 10 else if (length < 8000) 20 else 30,
        else => {},
    }

    var speed = if (density > max_rural_density) urban_speed[class.category.road_class] else initial_speed;
    if (class.flags.roundabout) speed = scaled(speed, 0.5);
    speed = switch (use) {
        .parking_aisle => 15,
        .driveway, .drive_through => 10,
        else => speed,
    };
    return if (rough) speed / 2 else speed;
}

fn scaled(speed: u8, factor: f32) u8 {
    return @intFromFloat(@min(graph.max_assumed_speed, @as(f32, @floatFromInt(speed)) * factor + 0.5));
}

test "Valhalla default speeds preserve speed assignment precedence" {
    const testing = std.testing;
    var class: EdgeClass = .{};
    class.category.road_class = @backingInt(graph.RoadClass.primary);
    try testing.expectEqual(70, defaultSpeed(class, 70, 100, 8, .{}));
    try testing.expectEqual(57, defaultSpeed(class, 70, 100, 9, .{}));
    class.flags.roundabout = true;
    try testing.expectEqual(29, defaultSpeed(class, 70, 100, 9, .{}));
    class.category.surface = @backingInt(graph.Surface.gravel);
    try testing.expectEqual(14, defaultSpeed(class, 70, 100, 9, .{}));
    class.flags.tagged_speed = true;
    try testing.expectEqual(40, defaultSpeed(class, 50, 100, 9, .{}));
    try testing.expectEqual(11, defaultSpeed(class, 16, 100, 9, .{}));
    try testing.expectEqual(15, defaultSpeed(class, 15, 100, 9, .{}));
    class.flags.tagged_speed = false;
    class.category.use = @backingInt(graph.Use.parking_aisle);
    try testing.expectEqual(7, defaultSpeed(class, 50, 100, 9, .{}));
    class.category.use = @backingInt(graph.Use.ferry);
    try testing.expectEqual(10, defaultSpeed(class, 50, 1999, 9, .{}));
    try testing.expectEqual(20, defaultSpeed(class, 50, 2000, 9, .{}));
    try testing.expectEqual(30, defaultSpeed(class, 50, 8000, 9, .{}));
    try testing.expectEqual(50, defaultSpeed(class, 50, 1999, 9, .{ .ferry_duration = true }));
    class.category.use = @backingInt(graph.Use.rail_ferry);
    try testing.expectEqual(65, defaultSpeed(class, 50, 100, 9, .{}));
}

test "Valhalla applies separate ramp and turn-channel speed rules" {
    const testing = std.testing;
    var class: EdgeClass = .{
        .category = .{ .use = @backingInt(graph.Use.ramp), .road_class = @backingInt(graph.RoadClass.motorway) },
        .flags = .{ .link = true },
    };
    try testing.expectEqual(85, defaultSpeed(class, 100, 100, 8, .{}));
    try testing.expectEqual(80, defaultSpeed(class, 100, 100, 9, .{}));
    class.flags.tagged_speed = true;
    try testing.expectEqual(100, defaultSpeed(class, 100, 100, 9, .{}));
    class.category.use = @backingInt(graph.Use.turn_channel);
    try testing.expectEqual(63, defaultSpeed(class, 50, 100, 9, .{}));
    try testing.expectEqual(50, defaultSpeed(class, 50, 100, 9, .{ .infer_turn_channels = false }));
    try testing.expectEqual(140, defaultSpeed(class, 140, 100, 9, .{}));
}

test "Valhalla configured speeds use the selected region and density band" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const common: Table = .{
        .way = @splat(15),
        .link_exiting = @splat(30),
        .link_turning = @splat(20),
        .roundabout = @splat(10),
        .driveway = 8,
        .alley = 7,
        .parking_aisle = 6,
        .@"drive-through" = 5,
    };
    var suburban = common;
    suburban.way = @splat(26);
    var urban = common;
    urban.way = @splat(200);
    urban.way[@backingInt(graph.RoadClass.tertiary)] = null;
    const rules = [_]Rule{
        .{ .rural = common, .suburban = common, .urban = common },
        .{ .@"iso3166-1" = "US", .rural = suburban, .suburban = suburban, .urban = suburban },
        .{ .@"iso3166-1" = "US", .@"iso3166-2" = "PA", .rural = common, .suburban = suburban, .urban = urban },
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, rules, .{ .emit_null_optional_fields = false });
    defer allocator.free(bytes);
    var config = try Config.parse(allocator, bytes, .none);
    defer config.deinit(allocator);
    const region: Region = .{ .country = "US", .state = "PA" };
    var class: EdgeClass = .{
        .category = .{ .road_class = @backingInt(graph.RoadClass.secondary) },
        .access = .{ .reverse = @bitCast(graph.AccessMask{ .truck = true }) },
        .flags = .{ .tagged_speed = true },
    };
    try testing.expectEqual(@as(?u8, 15), config.speed(region, class, 5, false));
    try testing.expectEqual(@as(?u8, 26), config.speed(region, class, 6, false));
    try testing.expectEqual(@as(?u8, 26), config.speed(region, class, 10, false));
    try testing.expectEqual(@as(?u8, 140), config.speed(region, class, 11, false));
    try testing.expectEqual(@as(?u8, 26), config.speed(.{ .country = "US", .state = "NY" }, class, 15, false));
    try testing.expectEqual(@as(?u8, 15), config.speed(.{ .country = "DE" }, class, 15, false));
    class.category.road_class = @backingInt(graph.RoadClass.tertiary);
    try testing.expectEqual(null, config.speed(region, class, 11, false));
    class.flags.link = true;
    class.category.use = @backingInt(graph.Use.ramp);
    try testing.expectEqual(@as(?u8, 20), config.speed(region, class, 11, false));
    try testing.expectEqual(@as(?u8, 30), config.speed(region, class, 11, true));
    class.category.use = @backingInt(graph.Use.ferry);
    try testing.expectEqual(null, config.speed(region, class, 11, true));

    const duplicate = try std.json.Stringify.valueAlloc(allocator, .{ rules[0], rules[0] }, .{ .emit_null_optional_fields = false });
    defer allocator.free(duplicate);
    try testing.expectError(error.DuplicateSpeedRegion, Config.parse(allocator, duplicate, .none));
}
