// Ported from src/loki/tile_action.cc (Valhalla 3.9.3).
const std = @import("std");
const service = @import("service.zig");
const http = @import("../server/http.zig");
const renderer = @import("../tiles/graph_tile.zig");
const Attributes = @import("attributes.zig").Controller;
const Failure = @import("errors.zig").Failure;

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *service.Options, res: *http.Response) std.mem.Allocator.Error!?Failure {
    const tile = options.tile orelse return .{ .code = 174 };
    const limits = svc.limits.tile;
    if (tile.z > limits.min_zoom[7]) {
        return .{ .code = 175, .extra = try std.fmt.allocPrint(res.gpa, "{d}", .{limits.min_zoom[7]}) };
    }
    const view = svc.graph orelse return .{ .code = 107, .extra = "tile" };
    const filters: Attributes = if (options.verbose and limits.allow_verbose)
        .{ .enabled = .full }
    else if (options.filters.action == .no_action)
        .{ .enabled = .empty }
    else
        options.tripAttributes(true, ctx.deadline) catch {
            res.status = 504;
            return null;
        };
    renderer.render(res.gpa, view, tile, limits.min_zoom, filters, options.generalize orelse 4, &res.body, ctx.deadline) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlineExceeded => {
            res.body.clearRetainingCapacity();
            res.status = 504;
            return null;
        },
        else => return .{ .code = 199 },
    };
    res.content_type = "application/vnd.mapbox-vector-tile";
    try res.addHeader(try std.fmt.allocPrint(res.gpa, "Cache-Control: public, max-age={s}", .{limits.max_age}));
    return null;
}
