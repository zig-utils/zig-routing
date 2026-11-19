//! Valhalla 3.9.3 API wire schemas.

const std = @import("std");
const protobuf = @import("protobuf");

pub const api = @import("api.zig");
pub const common = @import("common.zig");
pub const directions = @import("directions.zig");
pub const expansion = @import("expansion.zig");
pub const incidents = @import("incidents.zig");
pub const info = @import("info.zig");
pub const isochrone = @import("isochrone.zig");
pub const matrix = @import("matrix.zig");
pub const options = @import("options.zig");
pub const sign = @import("sign.zig");
pub const status = @import("status.zig");
pub const transit = @import("transit.zig");
pub const transit_fetch = @import("transit_fetch.zig");
pub const trip = @import("trip.zig");

pub const Api = api.Api;
const no_deadline = protobuf.no_deadline;

test "all Valhalla schemas instantiate their typed values" {
    inline for (.{ api, common, directions, expansion, incidents, info, isochrone, matrix, options, sign, status, transit, transit_fetch, trip }) |module| {
        inline for (@typeInfo(module).@"struct".decl_names) |name| {
            const decl = @field(module, name);
            if (@TypeOf(decl) == type and @typeInfo(decl) == .@"struct" and @hasDecl(decl, "Values")) {
                _ = @sizeOf(decl.Values);
            }
        }
    }
}

test "Options encode and decode explicit presence, enum names and map entries" {
    const values: options.Options.Values = .{
        .language = "",
        .action = .route,
        .format = .pbf,
        .costings = &.{.{ .key = 0, .value = .{} }},
    };
    var buf: [1024]u8 = undefined;
    const bytes = try options.Options.encode(&buf, values, no_deadline);
    const view = try options.Options.decode(bytes, no_deadline);
    try std.testing.expectEqualStrings("", (try view.get("language", no_deadline)).?);
    try std.testing.expectEqualStrings("route", @tagName(try view.get("action", no_deadline)));
    try std.testing.expectEqual(.pbf, try view.get("format", no_deadline));
    var entries = try view.get("costings", no_deadline);
    const entry = (try entries.next(no_deadline)).?;
    try std.testing.expectEqual(0, try entry.get("key", no_deadline));
    try std.testing.expect((try entry.get("value", no_deadline)) != null);
    try std.testing.expectEqual(null, try entries.next(no_deadline));
    try std.testing.expectEqualSlices(u8, "\x08\x00\x12\x00", try options.Options_CostingsEntry.encode(&buf, values.costings[0], no_deadline));
}

test "Trip and Directions round trip inside an Api envelope" {
    const value: Api.Values = .{
        .trip = .{ .routes = &.{.{ .legs = &.{.{ .shape = "trip shape" }} }} },
        .directions = .{ .routes = &.{.{ .legs = &.{.{ .shape = "directions shape" }} }} },
    };
    var buf: [1024]u8 = undefined;
    const view = try Api.decode(try Api.encode(&buf, value, no_deadline), no_deadline);
    const trip_view = (try view.get("trip", no_deadline)).?;
    var trips = try trip_view.get("routes", no_deadline);
    var trip_legs = try (try trips.next(no_deadline)).?.get("legs", no_deadline);
    try std.testing.expectEqualStrings("trip shape", try (try trip_legs.next(no_deadline)).?.get("shape", no_deadline));
    const directions_view = (try view.get("directions", no_deadline)).?;
    var routes = try directions_view.get("routes", no_deadline);
    var legs = try (try routes.next(no_deadline)).?.get("legs", no_deadline);
    try std.testing.expectEqualStrings("directions shape", try (try legs.next(no_deadline)).?.get("shape", no_deadline));
}

/// Materialize typed values for the byte-exact oracle test. The API uses
/// the zero-copy view and arena storage is confined to this test.
fn materialize(comptime Message: type, view: Message.View, arena: std.mem.Allocator) anyerror!Message.Values {
    var values: Message.Values = undefined;
    inline for (Message.schema) |field| {
        switch (field.presence) {
            .implicit, .required => {
                const value = try view.get(field.name, no_deadline);
                @field(values, field.name) = if (field.kind == .message)
                    try materialize(field.message, value, arena)
                else
                    value;
            },
            .optional => {
                const value = try view.get(field.name, no_deadline);
                @field(values, field.name) = if (field.kind == .message)
                    if (value) |nested| try materialize(field.message, nested, arena) else null
                else
                    value;
            },
            .repeated => {
                const Element = @typeInfo(@TypeOf(@field(values, field.name))).pointer.child;
                var list: std.ArrayList(Element) = .empty;
                var entries = try view.get(field.name, no_deadline);
                while (try entries.next(no_deadline)) |item| {
                    try list.append(arena, if (field.kind == .message)
                        try materialize(field.message, item, arena)
                    else
                        item);
                }
                @field(values, field.name) = list.items;
            },
        }
    }
    return values;
}

test "a Valhalla oracle route decodes and re-encodes byte for byte" {
    const reference = @embedFile("fixtures/utrecht-route.pbf");
    const view = try Api.decode(reference, no_deadline);
    try std.testing.expect((try view.get("directions", no_deadline)) != null);
    var storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer storage.deinit();
    const arena = storage.allocator();
    const values = try materialize(Api, view, arena);
    const buffer = try arena.alloc(u8, try Api.encodedSize(values, no_deadline));
    try std.testing.expectEqualSlices(u8, reference, try Api.encode(buffer, values, no_deadline));
}
