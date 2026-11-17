//! zr: the zig-routing command line.
//!
//!   zr serve [--host 0.0.0.0] [--port 8002] [--threads N] [--elevation DIR]
//!   zr version
//!
//! Argument handling moves to zig-cli with the CLI skeleton issue; this
//! keeps `zr serve` usable until then.

const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const http = routing.server.http;
const service = routing.api.service;

pub fn main(init: std.process.Init) !void {
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |a| try args.append(init.arena.allocator(), a);

    const cmd = if (args.items.len > 0) args.items[0] else "help";
    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("zr {s}\n", .{routing.version});
        return;
    }
    if (!std.mem.eql(u8, cmd, "serve")) {
        std.debug.print("usage: zr serve [--host IP] [--port N] [--threads N] [--elevation DIR]\n       zr version\n", .{});
        return;
    }

    var config: http.Config = .{ .address = io.Address.any(8002) };
    var elevation_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < args.items.len) : (i += 2) {
        const flag = args.items[i];
        const value = args.items[i + 1];
        if (std.mem.eql(u8, flag, "--port")) {
            config.address.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--threads")) {
            config.threads = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--host")) {
            config.address.ip = try parseIp4(value);
        } else if (std.mem.eql(u8, flag, "--elevation")) {
            elevation_dir = value;
        } else {
            std.debug.print("unknown option {s}\n", .{flag});
            return error.InvalidArgument;
        }
    }

    io.installTerminationHandler();
    var svc: service.Service = .{};
    var tiles: ?routing.elevation.hgt.Tiles = null;
    defer if (tiles) |*t| t.deinit();
    if (elevation_dir) |dir| {
        tiles = try routing.elevation.hgt.Tiles.init(std.heap.c_allocator, dir);
        svc.state = &tiles.?;
        svc.register(.height, routing.api.height_action.handle);
        std.debug.print("elevation: {d} tiles under {s}\n", .{ tiles.?.count, dir });
    }
    var server = http.Server.init(std.heap.c_allocator, config, svc.handler());
    try server.start();
    std.debug.print("zr {s} listening on {d}.{d}.{d}.{d}:{d} with {d} workers\n", .{ routing.version, config.address.ip[0], config.address.ip[1], config.address.ip[2], config.address.ip[3], server.port, server.threads.items.len });
    while (!io.termination_requested.load(.acquire)) io.sleepMs(200);
    std.debug.print("shutting down: draining in-flight requests\n", .{});
    server.stop();
}

fn parseIp4(s: []const u8) ![4]u8 {
    var out: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, s, '.');
    for (&out) |*b| b.* = try std.fmt.parseInt(u8, parts.next() orelse return error.InvalidArgument, 10);
    if (parts.next() != null) return error.InvalidArgument;
    return out;
}
