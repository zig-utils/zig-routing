// Ported from src/loki/status_action.cc and src/tyr/serializers.cc (Valhalla 3.9.3).
const std = @import("std");
const http = @import("../server/http.zig");
const service = @import("service.zig");
const errors = @import("errors.zig");
const json_writer = @import("json_writer.zig");
const version = @import("build_options").version;

pub fn handle(svc: *service.Service, _: *http.Ctx, options: *service.Options, res: *http.Response) std.mem.Allocator.Error!?errors.Failure {
    if (options.format == .pbf) return .{ .code = 107, .extra = "protobuf status" };
    var writer = json_writer.Writer.init(res.gpa, &res.body);
    try writer.beginObject();
    try writer.field("version", version);
    try writer.field("tileset_last_modified", @as(u64, svc.tileset_last_modified));
    try writer.beginArrayField("available_actions");
    for (std.enums.values(service.Action)) |action| {
        if (svc.handlers[@backingInt(action)] == null or std.mem.indexOfScalar(service.Action, svc.actions, action) == null) continue;
        try writer.string(@tagName(action));
    }
    try writer.endArray();
    try writer.endObject();
    return null;
}
