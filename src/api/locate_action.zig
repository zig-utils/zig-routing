// Ported from src/loki/locate_action.cc and src/tyr/locate_serializer.cc
// (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const costing = @import("../costing/root.zig");
const snap = @import("../snap/search.zig");
const http = @import("../server/http.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const json = @import("json.zig");
const request = @import("request.zig");
const service = @import("service.zig");
const details = @import("locate_details.zig");
const Failure = @import("errors.zig").Failure;
const Writer = @import("json_writer.zig").Writer;
const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const NodeId = graph.format.NodeId;

const Profile = union(enum) {
    none,
    auto: costing.auto.Profile,
    pedestrian: costing.pedestrian.Profile,
    bikeshare: costing.pedestrian.Profile,
    bicycle: costing.bicycle.Profile,
    truck: costing.truck.Profile,
    motorcycle: costing.motorcycle.Profile,

    fn init(a: Allocator, mode: request.Costing, values: json.Value, deadline: Deadline) !Profile {
        var warnings: std.ArrayList(costing.base.Warning) = .empty;
        const name = switch (mode) {
            .bikeshare, .multimodal, .transit => "pedestrian",
            else => @tagName(mode),
        };
        const object = if (values == .object) values.object.get(name) orelse .null else .null;
        return switch (mode) {
            .none => .none,
            .auto, .bus, .taxi, .auto_pedestrian => .{ .auto = try costing.auto.Model.canonicalize(
                try costing.auto.parse(a, switch (mode) {
                    .bus => .bus,
                    .taxi => .taxi,
                    else => .auto,
                }, object, &warnings, deadline),
            ) },
            .pedestrian, .multimodal, .transit, .bikeshare => blk: {
                const model = try costing.pedestrian.Model.canonicalize(try costing.pedestrian.parse(a, object, &warnings, deadline));
                break :blk if (mode == .bikeshare) .{ .bikeshare = model } else .{ .pedestrian = model };
            },
            .bicycle => .{ .bicycle = try costing.bicycle.Model.canonicalize(try costing.bicycle.parse(a, object, &warnings, deadline)) },
            .truck => .{ .truck = try costing.truck.Profile.init(try costing.truck.parse(a, object, &warnings, deadline)) },
            .motorcycle, .motor_scooter => .{ .motorcycle = try costing.motorcycle.Model.canonicalize(
                try costing.motorcycle.parse(a, if (mode == .motorcycle) .motorcycle else .motor_scooter, object, &warnings, deadline),
            ) },
        };
    }

    pub fn allowed(self: *const Profile, edge: snap.DirectedEdge) bool {
        return switch (self.*) {
            .none => (snap.NoCost{}).allowed(edge),
            inline .auto, .truck, .motorcycle => |*model| model.allowedCandidate(edge.class, .{}, .{}, false),
            .pedestrian => |*model| model.allowed(edge),
            .bikeshare => |*model| model.allowedCandidate(edge.class, .{}, .{}, true),
            .bicycle => |*model| model.allowed(edge),
        };
    }

    pub fn allowedNode(self: *const Profile, node: *const graph.format.NodeHot) bool {
        return switch (self.*) {
            .none => true,
            inline else => |*model| model.allowedNode(node),
        };
    }

    pub fn meetsAccessRestrictionsWithin(self: *const Profile, edge: snap.DirectedEdge, deadline: Deadline) !bool {
        const permission = switch (self.*) {
            .auto => |model| model.permission,
            .truck => |model| model.permission,
            else => return true,
        };
        const mask: u16 = @bitCast(permission.access_mask);
        if (permission.flags.contains(.ignore_restrictions) or edge.class.detail.access_restriction & mask == 0) return true;
        const record = try edge.graph_view.coldRecordWithDeadline(edge.id, deadline);
        var restrictions = record.restrictions();
        while (restrictions.next()) |entry| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (entry.attr.except_destination or entry.modes() & mask == 0) continue;
            const is_allowed = switch (self.*) {
                .auto => |model| model.dimensions.allowed(entry),
                .truck => |model| model.vehicle.allowed(entry),
                else => unreachable,
            };
            if (!is_allowed) return false;
        }
        return true;
    }
};

pub fn handle(svc: *service.Service, ctx: *http.Ctx, options: *request.Options, res: *http.Response) Allocator.Error!?Failure {
    if (options.locations.len == 0) return .{ .code = 110 };
    if (options.costing == .auto_pedestrian and options.locations.len > 2) {
        return .{ .code = 150, .extra = try std.fmt.allocPrint(res.gpa, "for auto_pedestrian: {d}", .{options.locations.len}) };
    }
    const view = svc.graph orelse return .{ .code = 171 };
    return locate(view, res.gpa, options, &res.body, ctx.deadline) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => blk: {
            res.body.clearRetainingCapacity();
            res.status = 504;
            break :blk null;
        },
        else => .{ .code = 171 },
    };
}

fn locate(view: *const View, a: Allocator, options: *const request.Options, out: *std.ArrayList(u8), deadline: Deadline) !?Failure {
    const values = options.costing_options orelse .null;
    const mode: request.Costing = if (options.costing == .auto_pedestrian) .auto else options.costing;
    const profile = try Profile.init(a, mode, values, deadline);
    const alternative = if (options.costing == .auto_pedestrian) try Profile.init(a, .pedestrian, values, deadline) else null;
    const osrm = options.format == .osrm;
    var w = Writer.init(a, out);
    if (osrm) {
        try w.beginObject();
        try w.field("code", "Ok");
        try w.beginArrayField("waypoints");
    } else {
        try w.beginArray();
    }
    for (options.locations, 0..) |input, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const chosen = if (i == 1 and alternative != null) &alternative.? else &profile;
        const result = snap.search(view, a, input, .{}, chosen, deadline) catch |err| switch (err) {
            error.OutOfMemory, error.DeadlineExceeded => return err,
            else => {
                if (osrm) return .{ .code = 171 };
                try writeMissing(&w, input, options.verbose);
                continue;
            },
        };
        if (osrm) {
            const edge = (try nearest(result.edges, deadline)) orelse return .{ .code = 171 };
            try writeNearest(&w, view, edge, deadline);
        } else {
            const checkpoint = w;
            const length = out.items.len;
            writeLocation(&w, view, input, result, options.verbose, deadline) catch |err| switch (err) {
                error.OutOfMemory, error.DeadlineExceeded => return err,
                else => {
                    out.shrinkRetainingCapacity(length);
                    w = checkpoint;
                    try writeMissing(&w, input, options.verbose);
                },
            };
        }
    }
    try w.endArray();
    if (osrm) try w.endObject();
    return null;
}

fn nearest(edges: []const snap.PathEdge, deadline: Deadline) !?snap.PathEdge {
    var best: ?snap.PathEdge = null;
    for (edges) |edge| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (best == null or edge.distance < best.?.distance) best = edge;
    }
    return best;
}

fn writeInput(w: *Writer, input: request.Location) !void {
    try w.beginObject();
    w.setPrecision(6);
    try w.field("input_lat", input.lat);
    try w.field("input_lon", input.lng);
    w.setPrecision(3);
}

fn writeMissing(w: *Writer, input: request.Location, verbose: bool) !void {
    try writeInput(w, input);
    try w.field("edges", null);
    try w.field("nodes", null);
    if (verbose) try w.field("reason", "No data found for location");
    try w.endObject();
}

fn writeLocation(w: *Writer, view: *const View, input: request.Location, path: snap.PathLocation, verbose: bool, deadline: Deadline) !void {
    try writeInput(w, input);
    try writeEdges(w, view, "edges", path.edges, verbose, deadline);
    if (path.filtered_edges.len != 0) try writeEdges(w, view, "filtered_edges", path.filtered_edges, verbose, deadline);
    try w.beginArrayField("nodes");
    var nodes: std.AutoHashMapUnmanaged(NodeId, void) = .empty;
    for (path.edges) |edge| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (edge.node != .end) continue;
        const id: NodeId = @fromBackingInt((try view.edge(edge.id)).head);
        if ((try nodes.getOrPut(w.gpa, id)).found_existing) continue;
        const p = (try view.coordinate(id)).toPoint();
        try w.beginObject();
        w.setPrecision(6);
        try w.field("lon", p.lng);
        try w.field("lat", p.lat);
        w.setPrecision(3);
        if (verbose) try details.writeNode(w, view, id);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

fn writeEdges(w: *Writer, view: *const View, comptime key: []const u8, edges: []const snap.PathEdge, verbose: bool, deadline: Deadline) !void {
    try w.beginArrayField(key);
    for (edges) |edge| {
        if (deadline.expired()) return error.DeadlineExceeded;
        try w.beginObject();
        const record = try view.coldRecordWithDeadline(edge.id, deadline);
        if (!verbose) try w.field("way_id", record.wayId());
        w.setPrecision(6);
        try w.field("correlated_lat", edge.projected.lat);
        try w.field("correlated_lon", edge.projected.lng);
        try w.field("side_of_street", if (edge.side == .none) "neither" else @tagName(edge.side));
        w.setPrecision(5);
        try w.field("percent_along", @as(f64, edge.percent_along));
        w.setPrecision(3);
        if (verbose) try details.writeEdge(w, view, edge, record, deadline);
        try w.endObject();
    }
    try w.endArray();
}

fn writeNearest(w: *Writer, view: *const View, candidate: snap.PathEdge, deadline: Deadline) !void {
    const edge = try view.edge(candidate.id);
    const opposing = try view.edge(try view.oppEdge(candidate.id));
    const names = try view.namesWithOptions(candidate.id, .{ .deadline = deadline });
    const name = if (names.count() != 0) (try names.valueAt(0)).text else "";
    try w.beginObject();
    w.setPrecision(6);
    try w.field("distance", candidate.distance);
    try w.field("name", name);
    try w.beginArrayField("location");
    try w.float(candidate.projected.lng);
    try w.float(candidate.projected.lat);
    try w.endArray();
    w.setPrecision(3);
    try w.beginArrayField("nodes");
    try w.uint(opposing.head);
    try w.uint(edge.head);
    try w.endArray();
    try w.endObject();
}
