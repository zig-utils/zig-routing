// Ported from src/baldr/graphtile.cc and src/mjolnir/convert_transit.cc (Valhalla 3.9.3).
// Translate offline transit tiles into the native timetable sections.
const std = @import("std");
const graph = @import("../graph/root.zig");
const io = @import("../infra/io.zig");
const tile_format = @import("valhalla_tile.zig");
const raw = @import("valhalla_transit.zig");
const ColdBuilder = @import("../build/cold_builder.zig").Builder;
const StringTable = @import("../build/tags/names.zig").StringTable;
const Allocator = std.mem.Allocator;
const Transit = graph.transit;
const Format = graph.format;
const GraphId = tile_format.GraphId;
const NodeType = graph.constants.NodeType;
const Use = graph.constants.Use;

pub const Source = struct {
    tile: tile_format.Tile,
    node_base: u32,
};

const PlaceRef = struct {
    id: u32 = Transit.no_id,
    kind: NodeType = .street_intersection,
};

const TileIndex = struct {
    by_node: []PlaceRef,
    by_stop: []PlaceRef,
};

const Arc = struct { origin: u32, destination: u32 };

const Builder = struct {
    a: Allocator,
    deadline: io.Deadline,
    strings: *StringTable,
    cold: *ColdBuilder,
    zones: graph.timezone.Rules,
    start_day: i32,
    sources: []const Source,
    by_key: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    tiles: []TileIndex,
    stops: std.ArrayList(Transit.Stop) = .empty,
    stations: std.ArrayList(Transit.Station) = .empty,
    egresses: std.ArrayList(Transit.Egress) = .empty,
    routes: std.ArrayList(Transit.Route) = .empty,
    lines: std.ArrayList(Transit.Line) = .empty,
    departures: std.ArrayList(Transit.Departure) = .empty,
    schedules: std.ArrayList(Transit.Schedule) = .empty,
    days: std.ArrayList(Transit.DayWord) = .empty,
    exceptions: std.ArrayList(Transit.Exception) = .empty,
    transfers: std.ArrayList(Transit.Transfer) = .empty,

    fn text(self: *Builder, value: []const u8) !Transit.Text {
        if (value.len == 0) return .none;
        return @fromBackingInt(try self.cold.nameRef(try self.strings.intern(value), false));
    }

    fn tileText(self: *Builder, tile: tile_format.Tile, offset: u24) !Transit.Text {
        return self.text(try tile.transitText(offset));
    }

    fn color(self: *Builder, value: u32) !Transit.Text {
        if (value > 0xffffff) return error.InvalidValhallaTransitColor;
        var buf: [6]u8 = undefined;
        return self.text(try std.fmt.bufPrint(&buf, "{X:0>6}", .{value}));
    }

    fn addPlaces(self: *Builder, coordinates: []const Format.Coordinate) !void {
        for (self.sources, self.tiles, 0..) |source, *index, ti| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const tile = source.tile;
            try self.by_key.putNoClobber(self.a, tile.header.tile.id.tileKey(), ti);
            index.* = .{
                .by_node = try self.a.alloc(PlaceRef, tile.nodes.len),
                .by_stop = try self.a.alloc(PlaceRef, tile.transit.stops.len),
            };
            @memset(index.by_stop, .{});
            for (tile.nodes, index.by_node, 0..) |node, *ref, ni| {
                if (ni % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
                const sid = node.flags.transition_index;
                if (sid >= index.by_stop.len or index.by_stop[sid].id != Transit.no_id)
                    return error.InvalidValhallaTransitStop;
                const fields = tile.transit.stops[sid].attrs;
                const access: graph.constants.AccessMask = @bitCast(@as(u16, node.position.access));
                const dense = source.node_base + @as(u32, @intCast(ni));
                const zone = try self.zones.name(node.timezone()) orelse "";
                const place: Transit.Place = .{
                    .coordinate = coordinates[dense],
                    .name = try self.tileText(tile, fields.name),
                    .one_stop_id = try self.tileText(tile, fields.one_stop),
                    .timezone = try self.text(zone),
                    .graph_node = dense,
                    .flags = .{
                        .traversability = @fromBackingInt(fields.traversability),
                        .generated = fields.generated,
                        .wheelchair_boarding = access.wheelchair,
                    },
                };
                const kind = std.enums.fromInt(NodeType, node.edges.kind) orelse return error.InvalidValhallaTransitNode;
                const id = switch (kind) {
                    .transit_station => try append(Transit.Station, self.a, &self.stations, .{ .place = place }),
                    .multi_use_transit_platform => try append(Transit.Stop, self.a, &self.stops, .{ .place = place }),
                    .transit_egress => try append(Transit.Egress, self.a, &self.egresses, try egress(place, node.headings)),
                    else => return error.InvalidValhallaTransitNode,
                };
                ref.* = .{ .id = id, .kind = kind };
                index.by_stop[sid] = ref.*;
            }
        }
    }

    fn linkedPlace(self: Builder, id: GraphId, kind: NodeType) !u32 {
        const tile = self.tiles[self.by_key.get(id.tileKey()) orelse return error.MissingValhallaTransitTile];
        if (id.index >= tile.by_node.len or tile.by_node[id.index].kind != kind)
            return error.InvalidValhallaTransitNode;
        return tile.by_node[id.index].id;
    }

    fn addTile(self: *Builder, source: Source, index: TileIndex) !void {
        const tile = source.tile;
        var arcs: std.AutoHashMapUnmanaged(u32, Arc) = .empty;
        defer arcs.deinit(self.a);
        for (tile.nodes, index.by_node, 0..) |node, from, ni| {
            if (ni % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            var station: u32 = Transit.no_id;
            const edges = tile.edges[node.edges.first..][0..node.edges.count];
            for (edges) |edge| {
                const end = edge.endpoint.node;
                if (edge.isTransitRide()) {
                    if (from.kind != .multi_use_transit_platform) return error.InvalidValhallaTransitLine;
                    const to = try self.linkedPlace(end, .multi_use_transit_platform);
                    const entry = try arcs.getOrPut(self.a, edge.transitLine());
                    if (entry.found_existing) return error.DuplicateValhallaTransitLine;
                    entry.value_ptr.* = .{ .origin = from.id, .destination = to };
                } else if ((from.kind == .multi_use_transit_platform and edge.speed.use == @backingInt(Use.platform_connection)) or
                    (from.kind == .transit_egress and edge.speed.use == @backingInt(Use.egress_connection)))
                {
                    const next = try self.linkedPlace(end, .transit_station);
                    if (station != Transit.no_id and station != next) return error.InvalidValhallaTransitStation;
                    station = next;
                }
            }
            switch (from.kind) {
                .multi_use_transit_platform => self.stops.items[from.id].station = station,
                .transit_egress => {
                    if (station == Transit.no_id) return error.InvalidValhallaTransitStation;
                    self.egresses.items[from.id].station = station;
                },
                else => {},
            }
        }

        const route_base = try idFor(self.routes.items.len);
        for (tile.transit.routes) |route| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (route.id.vehicle > 7) return error.InvalidValhallaTransitRoute;
            try self.routes.append(self.a, .{
                .one_stop_id = try self.tileText(tile, route.id.one_stop),
                .operator_one_stop_id = try self.tileText(tile, route.operator.one_stop),
                .operator_name = try self.tileText(tile, route.operator.name),
                .operator_website = try self.tileText(tile, route.website.url),
                .short_name = try self.tileText(tile, route.website.short_name),
                .long_name = try self.tileText(tile, route.details.long_name),
                .description = try self.tileText(tile, route.details.description),
                .color = try self.color(route.color),
                .text_color = try self.color(route.text_color),
                .flags = .{ .vehicle = @fromBackingInt(route.id.vehicle) },
            });
        }

        const schedule_base = try idFor(self.schedules.items.len);
        const tile_day = try creationDay(tile);
        for (tile.transit.schedules) |schedule| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            try self.addSchedule(schedule, tile_day);
        }

        var first: usize = 0;
        while (first < tile.transit.departures.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const first_row = tile.transit.departures[first];
            const arc = (arcs.fetchRemove(first_row.ids.line) orelse return error.MissingValhallaTransitLine).value;
            const line = try idFor(self.lines.items.len);
            const route = try std.math.add(u32, route_base, first_row.ids.route);
            const start = try idFor(self.departures.items.len);
            var next = first;
            while (next < tile.transit.departures.len) : (next += 1) {
                if (next % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
                const row = tile.transit.departures[next];
                if (row.ids.line != first_row.ids.line) break;
                if (row.ids.route != first_row.ids.route or row.ids.trip == Transit.no_id)
                    return error.InvalidValhallaTransitDeparture;
                const frequency = row.frequency();
                try self.departures.append(self.a, .{
                    .line = line,
                    .route = route,
                    .trip = row.ids.trip,
                    .block = if (row.attrs.block == 0) Transit.no_id else row.attrs.block,
                    .schedule = try std.math.add(u32, schedule_base, row.attrs.schedule),
                    .headsign = try self.tileText(tile, row.attrs.headsign),
                    .start_time = row.start(),
                    .end_time = if (frequency) |time| time.end else 0,
                    .headway = if (frequency) |time| time.headway else 0,
                    .elapsed_time = row.elapsed(),
                    .flags = .{ .kind = @fromBackingInt(row.attrs.kind), .wheelchair = row.attrs.wheelchair, .bicycle = row.attrs.bicycle },
                });
            }
            try self.lines.append(self.a, .{
                .origin = arc.origin,
                .destination = arc.destination,
                .route = route,
                .departures = .{ .first = start, .count = try idFor(next - first) },
            });
            first = next;
        }
        if (arcs.count() != 0) return error.MissingValhallaTransitDepartures;

        for (tile.transit.transfers) |transfer| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (transfer.from >= index.by_stop.len or transfer.to >= index.by_stop.len or transfer.attrs.kind > 3)
                return error.InvalidValhallaTransitTransfer;
            const from = index.by_stop[transfer.from];
            const to = index.by_stop[transfer.to];
            if (from.kind != .multi_use_transit_platform or to.kind != .multi_use_transit_platform)
                return error.InvalidValhallaTransitTransfer;
            try self.transfers.append(self.a, .{
                .origin = from.id,
                .destination = to.id,
                .minimum_time = transfer.attrs.minimum_time,
                .flags = .{ .kind = @fromBackingInt(transfer.attrs.kind) },
            });
        }
    }

    fn addSchedule(self: *Builder, schedule: raw.Schedule, tile_day: i32) !void {
        const count = @as(u7, schedule.attrs.end_day) + 1;
        var row: Transit.Schedule = .{ .days = .{}, .day_count = 0, .flags = .{ .weekdays = schedule.attrs.weekdays } };
        if (tile_day == self.start_day) {
            const bits = if (count == 64) schedule.days else schedule.days & ((@as(u64, 1) << @as(u6, @intCast(count))) - 1);
            row.days = .{ .first = try idFor(self.days.items.len), .count = if (count > 32) 2 else 1 };
            row.day_count = count;
            try self.days.append(self.a, .{ .bits = @truncate(bits) });
            if (count > 32) try self.days.append(self.a, .{ .bits = @truncate(bits >> 32) });
        } else {
            // A different source tile can anchor its bitset on any civil day.
            // Sparse overrides preserve that window without padding the gap.
            row.exceptions = .{ .first = try idFor(self.exceptions.items.len), .count = count };
            const offset = tile_day - self.start_day;
            for (0..count) |day| {
                try self.exceptions.append(self.a, .{
                    .day = offset + @as(i32, @intCast(day)),
                    .flags = .{ .active = schedule.days & (@as(u64, 1) << @as(u6, @intCast(day))) != 0 },
                });
            }
        }
        try self.schedules.append(self.a, row);
    }
};

fn egress(place: Transit.Place, connecting: u64) !Transit.Egress {
    var result: Transit.Egress = .{ .place = place, .station = Transit.no_id };
    if (connecting >> 63 != 0) {
        const lng: i64 = @as(u32, @truncate(connecting >> 31));
        const lat: i64 = @as(u31, @truncate(connecting));
        result.connecting_point = .{
            .lng = std.math.cast(i32, lng - 1_800_000_000) orelse return error.InvalidValhallaTransitCoordinate,
            .lat = @intCast(lat - 900_000_000),
        };
        if (!result.connecting_point.inRange()) return error.InvalidValhallaTransitCoordinate;
        result.flags.has_connecting_point = true;
    } else if (connecting != 0) {
        result.connecting_way = connecting;
        result.flags.has_connecting_way = true;
    }
    return result;
}

fn creationDay(tile: tile_format.Tile) !i32 {
    const pivot: graph.datetime.Date = .{ .year = 2014, .month = 1, .day = 1 };
    const day = @as(i64, tile.header.date_created) + pivot.days();
    if (day > std.math.maxInt(i32) - 63) return error.InvalidValhallaTransitDate;
    return @intCast(day);
}

fn idFor(count: usize) !u32 {
    if (count >= Transit.no_id) return error.TooManyValhallaTransitRecords;
    return @intCast(count);
}

fn append(comptime T: type, a: Allocator, list: *std.ArrayList(T), value: T) !u32 {
    const id = try idFor(list.items.len);
    try list.append(a, value);
    return id;
}

pub fn write(gpa: Allocator, sources: []const Source, coordinates: []const Format.Coordinate, strings: *StringTable, cold: *ColdBuilder, writer: *Format.BundleWriter) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var start_day: i32 = std.math.maxInt(i32);
    for (sources) |source| {
        if (writer.deadline.expired()) return error.DeadlineExceeded;
        start_day = @min(start_day, try creationDay(source.tile));
    }
    var builder: Builder = .{
        .a = a,
        .deadline = writer.deadline,
        .strings = strings,
        .cold = cold,
        .sources = sources,
        .zones = try graph.timezone.Rules.parse(&graph.timezone.bundled_rules),
        .start_day = start_day,
        .tiles = try a.alloc(TileIndex, sources.len),
    };
    try builder.addPlaces(coordinates);
    for (sources, builder.tiles) |source, index| try builder.addTile(source, index);
    const indexed = try Transit.indexDepartures(a, builder.lines.items, builder.departures.items, writer.deadline);
    const metadata: Transit.Metadata = .{ .start_day = start_day };
    try writer.write(.transit_metadata, &.{metadata});
    try writer.write(.transit_stops, builder.stops.items);
    try writer.write(.transit_stations, builder.stations.items);
    try writer.write(.transit_egresses, builder.egresses.items);
    try writer.write(.transit_routes, builder.routes.items);
    try writer.write(.transit_lines, indexed.lines);
    try writer.write(.transit_departures, builder.departures.items);
    try writer.write(.transit_occurrences, indexed.occurrences);
    try writer.write(.transit_schedules, builder.schedules.items);
    try writer.write(.transit_days, builder.days.items);
    try writer.write(.transit_exceptions, builder.exceptions.items);
    try writer.write(.transit_transfers, builder.transfers.items);
}
