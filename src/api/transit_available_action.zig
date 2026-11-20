// Ported from src/loki/transit_available_action.cc and
// src/tyr/transit_available_serializer.cc (Valhalla 3.9.3).
const std = @import("std");
const service = @import("service.zig");
const http = @import("../server/http.zig");
const Writer = @import("json_writer.zig").Writer;
const Failure = @import("errors.zig").Failure;

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *service.Options, res: *http.Response) std.mem.Allocator.Error!?Failure {
    if (options.locations.len == 0) return .{ .code = 120 };
    var writer: Writer = .init(res.gpa, &res.body);
    writer.setPrecision(6);
    try writer.beginArray();
    for (options.locations) |location| {
        if (ctx.deadline.expired()) return cancelled(res);
        const radius = location.radius orelse 0;
        const available = if (svc.transit_coverage) |index|
            index.available(.{ .lat = location.lat, .lng = location.lng }, radius, ctx.deadline) catch return cancelled(res)
        else
            false;
        try writer.beginObject();
        try writer.key("input_lat");
        try writer.float(location.lat);
        try writer.key("input_lon");
        try writer.float(location.lng);
        try writer.key("radius");
        try writer.uint(radius);
        try writer.key("istransit");
        try writer.boolean(available);
        try writer.endObject();
    }
    try writer.endArray();
    return null;
}

fn cancelled(res: *http.Response) ?Failure {
    res.body.clearRetainingCapacity();
    res.status = 504;
    return null;
}
