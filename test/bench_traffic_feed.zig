//! Apply a large CSV batch of distinct traffic keys to a mapped overlay.
const std = @import("std");
const routing = @import("routing");
const graph = routing.graph;
const io = routing.infra.io;
const feed = routing.traffic.feed;
const live = routing.traffic.live;
const expiry = routing.traffic.expiry;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const count = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 10_000_000;
    if (count == 0 or args.next() != null) return error.InvalidArguments;
    const a = init.arena.allocator();
    const fixture_uuid: graph.format.DatasetUuid = @splat(198);
    const edges = try a.alloc(graph.format.EdgeHot, count);
    const records = try a.alloc(graph.edge_keys.Record, count);
    const inverse = try a.alloc(u32, count);
    const deadline = io.Deadline.fromNowMs(120_000);
    const edge: graph.format.EdgeHot = .{
        .head = 0,
        .geom = .{ .len_m = 100, .grade = 6, .curvature = 0 },
        .cls = .{ .class_id = 0, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .speed = .{ 50, 60, 40, 50 },
    };
    var csv: io.Writer.Allocating = try .initCapacity(a, @as(usize, count) * 38);
    defer csv.deinit();
    try csv.writer.writeAll("edge_key,speed\n");
    for (edges, records, inverse, 0..) |*item, *record, *back, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        item.* = edge;
        const begin: i64 = @intCast(i + 1);
        record.* = .{
            .key = .{ .way_id = 12, .begin_node = begin, .end_node = begin + 1 },
            .edge = @intCast(i),
        };
        back.* = @intCast(i);
        try csv.writer.print("\"12,{d},{d},forward\",{d}\n", .{ begin, begin + 1, sampleSpeed(i) });
    }
    const parent = try io.Directory.open(".");
    defer parent.close();
    const temp = try parent.temporaryChild();
    defer {
        temp.dir.deleteFile(live.filename) catch {};
        temp.dir.deleteFile(expiry.filename) catch {};
        temp.dir.close();
        parent.deleteDir(&temp.name) catch {};
    }
    const source: live.Graph = .{
        .uuid = fixture_uuid,
        .edges = edges,
        .classes = &.{.{ .access = .{ .forward = 1, .reverse = 1 } }},
        .bounds = null,
    };
    const key_index: graph.edge_keys.View = .{ .records = records, .inverse = inverse };
    var feeder = try feed.Feeder.open(init.gpa, temp.dir, source, key_index, live.default_max_age_seconds, deadline);
    defer feeder.close();
    const reader = (try live.Reader.open(temp.dir, fixture_uuid, count, deadline)).?;
    defer reader.close();
    const timer = io.Timer.start();
    const report = try feeder.apply(init.gpa, csv.written(), .csv, 1000, deadline);
    const elapsed = timer.read();
    defer report.deinit(init.gpa);
    if (report.rows != count or report.applied != count or report.unknown != 0 or report.invalid_rows != 0 or report.out_of_range != 0 or
        report.metadata == null or report.metadata.?.epoch != 1)
        return error.TrafficBatchMismatch;
    for (0..count) |i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const item = reader.view.record(@fromBackingInt(@as(u32, @intCast(i)))) orelse return error.MissingTrafficRecord;
        if (item.overallKph() != sampleSpeed(i)) return error.TrafficBatchMismatch;
    }
    var buf: [1024]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buf);
    try output.interface.print("distinct_updates {d}\ninput_bytes {d}\napply_seconds {d:.3}\nepoch {d}\n", .{
        count, csv.written().len, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s, report.metadata.?.epoch,
    });
    try output.interface.flush();
    if (count == 10_000_000 and elapsed >= 5 * std.time.ns_per_s) return error.TrafficFeedBudgetExceeded;
}

fn sampleSpeed(index: usize) u8 {
    return @intCast(90 + index % 17 * 2);
}
