//! Read a published GTFS feed and report its row counts and parse rate.
const std = @import("std");
const routing = @import("routing");
const gtfs = routing.build.gtfs;
const io = routing.infra.io;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingFeed;
    const workers = if (args.next()) |count| try std.fmt.parseInt(usize, count, 10) else 0;
    if (args.next() != null) return error.InvalidArguments;
    var diagnostic: gtfs.Diagnostic = .{};
    var stats: gtfs.Stats = .{};
    var feed = gtfs.read(init.gpa, path, .{ .workers = workers }, &diagnostic, &stats) catch |err| {
        var buf: [1024]u8 = undefined;
        var output = io.stderrWriter(init.io, &buf);
        try output.interface.print("{s}:{d}:{d} {s}: {s}\n", .{ diagnostic.file, diagnostic.row, diagnostic.column, diagnostic.field, @errorName(err) });
        try output.interface.flush();
        return err;
    };
    defer feed.deinit();
    var buf: [4096]u8 = undefined;
    var output = io.stdoutWriter(init.io, &buf);
    for (std.enums.values(gtfs.model.Table)) |table|
        try output.interface.print("{s}\t{d}\n", .{ @tagName(table), feed.count(table) });
    const rate = if (stats.stop_times_ns == 0) 0 else @as(f64, @floatFromInt(feed.stop_times.len)) * std.time.ns_per_s / @as(f64, @floatFromInt(stats.stop_times_ns));
    try output.interface.print("stop_times_workers\t{d}\nstop_times_ns\t{d}\nstop_times_rows_per_second\t{d:.0}\n", .{
        stats.stop_times_workers, stats.stop_times_ns, rate,
    });
    try output.interface.flush();
}
