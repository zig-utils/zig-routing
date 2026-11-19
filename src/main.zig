//! zr: the zig-routing command line.
//!
//!   zr serve [--config FILE] [--host IP] [--port N] [--threads N] [--elevation DIR|FILE.zdem]
//!   zr config check FILE
//!   zr dem pack HGT_DIR OUT.zdem | verify PACK HGT_DIR | info PACK
//!   zr bench URL --corpus FILE [options]   (zr bench with no arguments lists them)
//!   zr diff A_URL B_URL --corpus FILE      (zr diff with no arguments lists them)
//!   zr version
//!
//! Argument handling moves to zig-cli with the CLI skeleton issue; this
//! keeps `zr serve` usable until then.

const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const http = routing.server.http;
const config = routing.infra.config;

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
    if (std.mem.eql(u8, cmd, "bench")) {
        routing.cli.bench.main(std.heap.c_allocator, args.items[1..]) catch |e| switch (e) {
            error.InvalidArgument => std.process.exit(2),
            else => return e,
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "dem")) {
        routing.cli.dem.main(std.heap.c_allocator, args.items[1..]) catch |e| switch (e) {
            error.InvalidArgument => std.process.exit(2),
            error.VerifyFailed => std.process.exit(1),
            else => return e,
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "diff")) {
        const ok = routing.cli.diff.main(std.heap.c_allocator, args.items[1..]) catch |e| switch (e) {
            error.InvalidArgument => std.process.exit(2),
            else => return e,
        };
        if (!ok) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, cmd, "config")) {
        if (args.items.len != 3 or !std.mem.eql(u8, args.items[1], "check")) {
            std.debug.print("usage: zr config check FILE\n", .{});
            std.process.exit(2);
        }
        const a = init.arena.allocator();
        const loaded = loadConfig(a, args.items[2], init.environ_map) catch std.process.exit(2);
        const json = try std.json.Stringify.valueAlloc(a, .{
            .effective = loaded.config,
            .ignored_keys = loaded.ignored_keys,
        }, .{ .whitespace = .indent_2 });
        try io.writeStdout(json);
        try io.writeStdout("\n");
        return;
    }
    if (!std.mem.eql(u8, cmd, "serve")) {
        std.debug.print("usage: zr serve [--config FILE] [--host IP] [--port N] [--threads N] [--elevation DIR|FILE.zdem]\n       zr config check FILE\n       zr bench URL --corpus FILE [options]\n       zr diff A_URL B_URL --corpus FILE [options]\n       zr dem pack|verify|info ...\n       zr version\n", .{});
        return;
    }

    var config_path: ?[]const u8 = null;
    var ip: ?[4]u8 = null;
    var port: ?u16 = null;
    var threads: ?usize = null;
    var elevation_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.items.len) : (i += 2) {
        const flag = args.items[i];
        if (i + 1 == args.items.len) {
            std.debug.print("missing value for {s}\n", .{flag});
            std.process.exit(2);
        }
        const value = args.items[i + 1];
        if (std.mem.eql(u8, flag, "--config")) {
            config_path = value;
        } else if (std.mem.eql(u8, flag, "--port")) {
            port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--threads")) {
            threads = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, flag, "--host")) {
            ip = try config.parseIp4(value);
        } else if (std.mem.eql(u8, flag, "--elevation")) {
            elevation_dir = value;
        } else {
            std.debug.print("unknown option {s}\n", .{flag});
            return error.InvalidArgument;
        }
    }

    const loaded = loadConfig(init.arena.allocator(), config_path, init.environ_map) catch std.process.exit(2);
    if (loaded.ignored_keys.len != 0) {
        std.debug.print("ignoring configuration keys: {s}\n", .{
            try std.mem.join(init.arena.allocator(), ", ", loaded.ignored_keys),
        });
    }
    var server_config = try loaded.config.httpConfig();
    server_config.address.ip = ip orelse server_config.address.ip;
    server_config.address.port = port orelse server_config.address.port;
    server_config.threads = threads orelse server_config.threads;
    elevation_dir = elevation_dir orelse loaded.config.additional_data.elevation;

    io.installTerminationHandler();
    var svc = loaded.config.serviceConfig();
    var tiles: ?routing.elevation.hgt.Tiles = null;
    defer if (tiles) |*t| t.deinit();
    var pack: ?routing.elevation.@"packed".Pack = null;
    defer if (pack) |*p| p.close();
    var source: routing.elevation.Source = undefined;
    if (elevation_dir) |path| {
        // A pack from `zr dem pack`, or a directory of .hgt tiles.
        if (std.mem.endsWith(u8, path, ".zdem")) {
            pack = try routing.elevation.@"packed".Pack.open(path);
            source = .{ .pack = &pack.? };
            std.debug.print("elevation: {d} tiles in {s}\n", .{ pack.?.header.tile_count, path });
        } else {
            tiles = try routing.elevation.hgt.Tiles.init(std.heap.c_allocator, path);
            source = .{ .tiles = &tiles.? };
            std.debug.print("elevation: {d} tiles under {s}\n", .{ tiles.?.count, path });
        }
        svc.state = &source;
        svc.register(.height, routing.api.height_action.handle);
    }
    var server = http.Server.init(std.heap.c_allocator, server_config, svc.handler());
    try server.start();
    const host = server_config.address.ip;
    std.debug.print("zr {s} listening on {d}.{d}.{d}.{d}:{d} with {d} workers\n", .{ routing.version, host[0], host[1], host[2], host[3], server.port, server.threads.items.len });
    while (!io.termination_requested.load(.acquire)) io.sleepMs(200);
    std.debug.print("shutting down: draining in-flight requests\n", .{});
    server.stop();
}

fn loadConfig(arena: std.mem.Allocator, path: ?[]const u8, env: *const std.process.Environ.Map) !config.Loaded {
    var diagnostic: config.Diagnostic = .{};
    return config.load(arena, path, env, &diagnostic) catch |err| {
        const detail = diagnostic.message();
        std.debug.print("configuration {s}: {s}\n", .{ path orelse "from the environment", if (detail.len != 0) detail else @errorName(err) });
        return err;
    };
}
