// Ported from src/sif/transitcost.cc (Valhalla 3.9.3).
const std = @import("std");
const json = @import("../api/json.zig");
const constants = @import("../graph/constants.zig");
const timetable = @import("../graph/transit.zig");
const io = @import("../infra/io.zig");
const base = @import("base.zig");
const Cost = @import("compiled.zig").Cost;
const Allocator = std.mem.Allocator;

pub const unit_size: u32 = 1;
pub const FilterAction = @import("../api/proto/options.zig").FilterAction;
pub const Filter = struct {
    action: FilterAction = .no_action,
    ids: []const []const u8 = &.{},
};

pub const Options = struct {
    mode_factor: f32 = 1,
    use_bus: f32 = 0.3,
    use_rail: f32 = 0.6,
    use_transfers: f32 = 0.3,
    transfer_cost: f32 = 15,
    transfer_penalty: f32 = 300,
    wheelchair: bool = false,
    bicycle: bool = false,
    stops: Filter = .{},
    routes: Filter = .{},
    operators: Filter = .{},
};

const NumericOption = struct { name: []const u8, range: base.Range };
const ranges = [_]NumericOption{
    .{ .name = "mode_factor", .range = .factor(1) },
    .{ .name = "use_bus", .range = .preference(0.3) },
    .{ .name = "use_rail", .range = .preference(0.6) },
    .{ .name = "use_transfers", .range = .preference(0.3) },
    .{ .name = "transfer_cost", .range = .penalty(15) },
    .{ .name = "transfer_penalty", .range = .penalty(300) },
};

/// Parses the transit subobject of costing_options.
pub fn parse(arena: Allocator, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: io.Deadline) !Options {
    if (deadline.expired()) return error.DeadlineExceeded;
    var options: Options = .{
        .wheelchair = json.get(bool, input, "/wheelchair", false),
        .bicycle = json.get(bool, input, "/bicycle", false),
    };
    inline for (ranges) |spec| {
        @field(options, spec.name) = try base.rangedFloat(arena, input, spec.name, spec.range, warnings);
    }
    options.stops = try parseFilter(arena, input, "stops", deadline);
    options.operators = try parseFilter(arena, input, "operators", deadline);
    options.routes = try parseFilter(arena, input, "routes", deadline);
    return options;
}

fn parseFilter(arena: Allocator, input: json.Value, comptime name: []const u8, deadline: io.Deadline) !Filter {
    const action_name = json.getOptional([]const u8, input, "/filters/" ++ name ++ "/action") orelse return .{};
    const action = std.meta.stringToEnum(FilterAction, action_name) orelse return .{};
    const items = json.array(input, "/filters/" ++ name ++ "/ids") orelse return .{ .action = action };
    const ids = try arena.alloc([]const u8, items.len);
    errdefer arena.free(ids);
    var count: usize = 0;
    for (items, 0..) |value, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (value != .string) continue;
        ids[count] = value.string;
        count += 1;
    }
    return .{ .action = action, .ids = ids[0..count] };
}

pub const Profile = extern struct {
    mode_factor: f32,
    bus_factor: f32,
    rail_factor: f32,
    transfer_factor: f32,
    default_transfer: Cost,
    flags: packed struct(u32) {
        allow_bus: bool,
        allow_rail: bool,
        wheelchair: bool,
        bicycle: bool,
        reserved: u28 = 0,
    },

    pub fn init(options: Options) !Profile {
        inline for (ranges) |spec| {
            const value = @field(options, spec.name);
            if (!std.math.isFinite(value) or value < spec.range.min or value > spec.range.max)
                return error.InvalidTransitOptions;
        }
        var bus = preferenceWeight(options.use_bus);
        var rail = preferenceWeight(options.use_rail);
        if (rail < bus) {
            const ratio = bus / rail;
            rail = 1;
            bus *= ratio;
        } else {
            const ratio = rail / bus;
            bus = 1;
            rail *= ratio;
        }
        return .{
            .mode_factor = options.mode_factor,
            .bus_factor = bus,
            .rail_factor = rail,
            .transfer_factor = preferenceWeight(options.use_transfers),
            .default_transfer = .{ .cost = options.transfer_cost + options.transfer_penalty, .secs = options.transfer_cost },
            .flags = .{
                .allow_bus = options.use_bus > 0,
                .allow_rail = options.use_rail > 0,
                .wheelchair = options.wheelchair,
                .bicycle = options.bicycle,
            },
        };
    }

    pub fn allowsUse(self: Profile, use: constants.Use) bool {
        return switch (use) {
            .bus => self.flags.allow_bus,
            .rail => self.flags.allow_rail,
            else => true,
        };
    }

    pub fn allowsDeparture(self: Profile, departure: *const timetable.Departure) bool {
        return (!self.flags.wheelchair or departure.flags.wheelchair) and
            (!self.flags.bicycle or departure.flags.bicycle);
    }

    pub fn allowsPlace(self: Profile, place: *const timetable.Place, node_access: ?constants.AccessMask) bool {
        if (self.flags.wheelchair and (!place.flags.wheelchair_boarding or
            (node_access != null and !node_access.?.wheelchair))) return false;
        return !self.flags.bicycle or node_access == null or node_access.?.bicycle;
    }

    pub fn edgeCost(self: Profile, use: constants.Use, departure: timetable.NextDeparture, current_time: u32) Cost {
        return self.rideCost(use, departure.departure.elapsed_time, departure.time -% current_time);
    }

    pub fn rideCost(self: Profile, use: constants.Use, elapsed_secs: u32, wait_secs: u32) Cost {
        const wait: f32 = @floatFromInt(wait_secs);
        const elapsed: f32 = @floatFromInt(elapsed_secs);
        return .{ .cost = wait + elapsed * self.modeWeight(use), .secs = wait + elapsed };
    }

    pub fn transitionCost(self: Profile, use: constants.Use, from_pedestrian: bool) Cost {
        if (!from_pedestrian) return .{};
        return switch (use) {
            .bus, .rail => .{ .cost = 0.5 + self.modeWeight(use) },
            else => .{},
        };
    }

    pub fn transferCost(self: Profile) Cost {
        return .{ .cost = self.default_transfer.cost * self.transfer_factor, .secs = self.default_transfer.secs * 4 };
    }

    pub fn defaultTransferCost(self: Profile) Cost {
        return self.default_transfer;
    }

    fn modeWeight(self: Profile, use: constants.Use) f32 {
        return switch (use) {
            .bus => self.bus_factor,
            .rail => self.rail_factor,
            else => 1,
        };
    }
};

pub fn vehicleUse(vehicle: timetable.Vehicle) constants.Use {
    return switch (vehicle) {
        .bus, .trolleybus => .bus,
        else => .rail,
    };
}

fn preferenceWeight(preference: f32) f32 {
    return if (preference >= 0.5) 1.5 - preference else 5 - preference * 8;
}

test "Valhalla TransitCost parameter ranges fall back to their defaults" {
    // Ported from the inline tests in src/sif/transitcost.cc.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var random_state = std.Random.DefaultPrng.init(0);
    const random = random_state.random();
    inline for (ranges) |spec| {
        const width = spec.range.max - spec.range.min;
        for (0..250) |_| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var object: std.json.ObjectMap = .empty;
            const value = spec.range.min - width + random.float(f32) * (3 * width);
            try object.put(a, spec.name, .{ .float = value });
            var warnings: std.ArrayList(base.Warning) = .empty;
            const options = try parse(a, .{ .object = object }, &warnings, .none);
            const in_range = spec.range.min <= value and value <= spec.range.max;
            try t.expectEqual(if (in_range) value else spec.range.default, @field(options, spec.name));
            try t.expectEqual(@intFromBool(!in_range), warnings.items.len);
            _ = try Profile.init(options);
        }
    }
}

test "transit weighting applies to elapsed ride time and preserves transfer seconds" {
    const t = std.testing;
    const profile = try Profile.init(.{ .use_bus = 0.5, .use_rail = 0, .use_transfers = 0.5, .wheelchair = true });
    const departure: timetable.Departure = .{
        .line = 0,
        .route = 0,
        .trip = 0,
        .block = 0,
        .schedule = 0,
        .start_time = 100,
        .elapsed_time = 20,
        .flags = .{ .wheelchair = true },
    };
    const next: timetable.NextDeparture = .{ .departure = &departure, .time = 100 };
    try t.expect(profile.allowsUse(.bus) and !profile.allowsUse(.rail));
    try t.expect(profile.allowsDeparture(&departure));
    try t.expectEqualDeep(Cost{ .cost = 30, .secs = 30 }, profile.edgeCost(.bus, next, 90));
    try t.expectEqualDeep(Cost{ .cost = 510, .secs = 30 }, profile.edgeCost(.rail, next, 90));
    try t.expectEqualDeep(Cost{ .cost = 1.5 }, profile.transitionCost(.bus, true));
    try t.expectEqualDeep(Cost{ .cost = 315, .secs = 60 }, profile.transferCost());
    try t.expectEqualDeep(Cost{ .cost = 315, .secs = 15 }, profile.defaultTransferCost());
}
