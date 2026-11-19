//! Standalone server fixture for measuring the HTTP transport with zr bench.
const std = @import("std");
const routing = @import("routing");
const http = routing.server.http;
const io = routing.infra.io;

fn echo(_: *anyopaque, _: *http.Ctx, request: *const http.Request, response: *http.Response) void {
    response.writeBody(request.body) catch {
        response.status = 500;
    };
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const port = if (args.next()) |value| try std.fmt.parseInt(u16, value, 10) else return error.MissingPort;
    const threads = if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else 0;
    if (args.next() != null) return error.InvalidArgument;

    var context: u8 = 0;
    var server = http.Server.init(std.heap.c_allocator, .{
        .address = .loopback(port),
        .threads = threads,
    }, .{ .context = &context, .handle = echo });
    io.installTerminationHandler();
    try server.start();
    defer server.stop();
    std.debug.print("echo server listening on loopback port {d} with {d} workers\n", .{ server.port, server.threads.items.len });
    while (!io.termination_requested.load(.acquire)) io.sleepMs(200);
}
