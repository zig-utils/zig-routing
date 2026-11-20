// Ported from src/sif/pedestriancost.cc and src/thor/multimodal_transit.cc (Valhalla 3.9.3).
const std = @import("std");
const json = @import("../api/json.zig");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const base = @import("base.zig");
const compiled = @import("compiled.zig");
const pedestrian = @import("pedestrian.zig");
const transit = @import("transit.zig");
const Allocator = std.mem.Allocator;
const Cost = compiled.Cost;
const Timetable = graph.transit.View;
const Bits = std.DynamicBitSetUnmanaged;

pub const Mode = enum { pedestrian, transit };
pub const WalkingPhase = enum { start_or_end, transfer };
pub const Transfer = enum { within_station, between_stations };

pub const Options = struct {
    pedestrian: pedestrian.Options,
    transit: transit.Options,
};

/// The subobjects come from the same costing_options object used by the
/// street costing parser.
pub fn parse(arena: Allocator, input: json.Value, warnings: *std.ArrayList(base.Warning), deadline: io.Deadline) !Options {
    return .{
        .pedestrian = try pedestrian.parse(arena, json.pointer(input, "/pedestrian") orelse .null, warnings, deadline),
        .transit = try transit.parse(arena, json.pointer(input, "/transit") orelse .null, warnings, deadline),
    };
}

const IdFilter = struct {
    action: transit.FilterAction,
    names: std.StringHashMapUnmanaged(void) = .empty,

    fn init(a: Allocator, filter: transit.Filter, deadline: io.Deadline) !IdFilter {
        var result: IdFilter = .{ .action = filter.action };
        errdefer result.names.deinit(a);
        if (filter.action != .include and filter.action != .exclude) return result;
        for (filter.ids, 0..) |id, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            try result.names.put(a, id, {});
        }
        return result;
    }

    fn allows(self: *const IdFilter, name: []const u8) bool {
        if (self.names.count() == 0) return true;
        const matched = self.names.contains(name);
        return if (self.action == .include) matched else !matched;
    }
};

/// Dense request-local bitsets keyed by the bundle's platform, station and
/// route IDs. An empty slice represents unrestricted access.
pub const Filters = struct {
    stops: Bits = .{},
    stations: Bits = .{},
    routes: Bits = .{},

    fn init(arena: Allocator, options: transit.Options, table: Timetable, deadline: io.Deadline) !Filters {
        var stop_ids = try IdFilter.init(arena, options.stops, deadline);
        defer stop_ids.names.deinit(arena);
        var route_ids = try IdFilter.init(arena, options.routes, deadline);
        defer route_ids.names.deinit(arena);
        var operator_ids = try IdFilter.init(arena, options.operators, deadline);
        defer operator_ids.names.deinit(arena);
        var result: Filters = .{};
        errdefer {
            result.stops.deinit(arena);
            result.stations.deinit(arena);
        }
        if (stop_ids.names.count() != 0) {
            result.stops = try placeBits(arena, table, table.stops, &stop_ids, deadline);
            result.stations = try placeBits(arena, table, table.stations, &stop_ids, deadline);
        }
        if (route_ids.names.count() != 0 or operator_ids.names.count() != 0) {
            var routes = try Bits.initEmpty(arena, table.routes.len);
            errdefer routes.deinit(arena);
            for (table.routes, 0..) |route, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                const route_name = (try table.text(route.one_stop_id)) orelse "";
                const operator_name = (try table.text(route.operator_one_stop_id)) orelse "";
                if (!route_ids.allows(route_name) or !operator_ids.allows(operator_name)) routes.set(i);
            }
            result.routes = routes;
        }
        return result;
    }

    pub fn allowsStop(self: Filters, id: u32) bool {
        return id >= self.stops.bit_length or !self.stops.isSet(id);
    }

    pub fn allowsStation(self: Filters, id: u32) bool {
        return id >= self.stations.bit_length or !self.stations.isSet(id);
    }

    pub fn allowsRoute(self: Filters, id: u32) bool {
        return id >= self.routes.bit_length or !self.routes.isSet(id);
    }
};

fn placeBits(arena: Allocator, table: Timetable, rows: anytype, filter: *const IdFilter, deadline: io.Deadline) !Bits {
    var result = try Bits.initEmpty(arena, rows.len);
    errdefer result.deinit(arena);
    for (rows, 0..) |row, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!filter.allows((try table.text(row.place.one_stop_id)) orelse "")) result.set(i);
    }
    return result;
}

pub const Kernel = struct {
    walking: pedestrian.Profile,
    walking_table: compiled.Compiled,
    walking_mode_factor: f32,
    walking_limit: u32,
    transfer_limit: u32,
    transit: transit.Profile,
    filters: Filters,

    /// The compiled model and bitsets borrow the per-request arena.
    pub fn init(arena: Allocator, view: *const graph.reader.View, options: Options, deadline: io.Deadline) !Kernel {
        const factor = base.Range.factor(1.5);
        if (!std.math.isFinite(options.pedestrian.mode_factor) or
            options.pedestrian.mode_factor < factor.min or options.pedestrian.mode_factor > factor.max)
            return error.InvalidMultimodalOptions;
        var walk = try pedestrian.Model.canonicalize(options.pedestrian);
        walk.allow_transit_connections = true;
        const classes = view.classes orelse return error.MissingClassSection;
        const factors = try arena.alloc(f32, classes.len);
        errdefer arena.free(factors);
        return .{
            .walking = walk,
            .walking_table = try compiled.compileInto(pedestrian.Model, walk, classes, factors, deadline),
            .walking_mode_factor = options.pedestrian.mode_factor,
            .walking_limit = options.pedestrian.transit_start_end_max_distance,
            .transfer_limit = options.pedestrian.transit_transfer_max_distance,
            .transit = try transit.Profile.init(options.transit),
            .filters = if (view.transit_index) |table| try Filters.init(arena, options.transit, table, deadline) else .{},
        };
    }

    pub fn allowsWalk(self: *const Kernel, phase: WalkingPhase, previous: *const graph.class_table.EdgeClass, next: *const graph.class_table.EdgeClass, edge: graph.format.EdgeHot, check: pedestrian.PathCheck) bool {
        const distance = @as(u64, check.previous_distance) + edge.geom.len_m;
        const limit = if (phase == .transfer) @min(self.walking_limit, self.transfer_limit) else self.walking_limit;
        if (distance > limit) return false;
        return pedestrian.Kernel.allowed(&self.walking, previous, next, edge, check);
    }

    pub fn walkCost(self: *const Kernel, class: *const graph.class_table.EdgeClass, edge: graph.format.EdgeHot, ferry_speed: u8, effects: compiled.Effects) Cost {
        var edge_cost = pedestrian.Kernel.edgeCost(&self.walking, &self.walking_table, class, edge, ferry_speed, effects);
        edge_cost.cost *= self.walking_mode_factor;
        return edge_cost;
    }

    pub fn allowsStation(self: *const Kernel, view: *const graph.reader.View, id: u32) !bool {
        const table = view.transit_index orelse return error.MissingTransitSection;
        if (id >= table.stations.len) return error.InvalidTransitStation;
        return self.filters.allowsStation(id) and try self.placeAccessible(view, &table.stations[id].place);
    }

    pub fn allowsStop(self: *const Kernel, view: *const graph.reader.View, id: u32) !bool {
        const table = view.transit_index orelse return error.MissingTransitSection;
        if (id >= table.stops.len) return error.InvalidTransitStop;
        return self.filters.allowsStop(id) and try self.placeAccessible(view, &table.stops[id].place);
    }

    pub fn allowsDeparture(self: *const Kernel, view: *const graph.reader.View, departure: *const graph.transit.Departure) !bool {
        const table = view.transit_index orelse return error.MissingTransitSection;
        if (departure.route >= table.routes.len or departure.line >= table.lines.len)
            return error.InvalidTransitDeparture;
        const line = table.lines[departure.line];
        if (line.route != departure.route) return error.InvalidTransitDeparture;
        const route = table.routes[departure.route];
        return self.filters.allowsRoute(departure.route) and self.transit.allowsUse(transit.vehicleUse(route.flags.vehicle)) and
            self.transit.allowsDeparture(departure) and
            try self.allowsStop(view, line.origin) and try self.allowsStop(view, line.destination);
    }

    fn placeAccessible(self: *const Kernel, view: *const graph.reader.View, place: *const graph.transit.Place) !bool {
        const mask: ?graph.constants.AccessMask = if (place.graph_node == graph.transit.no_id)
            null
        else
            @bitCast((try view.node(@fromBackingInt(place.graph_node))).attr.access);
        return self.transit.allowsPlace(place, mask);
    }

    pub fn transferCost(self: *const Kernel, transfer: Transfer) Cost {
        return switch (transfer) {
            .within_station => self.transit.defaultTransferCost(),
            .between_stations => self.transit.transferCost(),
        };
    }

    /// MultimodalTransit's mode changes carry no separate cost. Waiting
    /// time is part of the scheduled ride and the transfer policy is separate.
    pub fn modeChangeCost(_: *const Kernel, _: Mode, _: Mode) Cost {
        return .{};
    }
};
