//! zr command registration and dispatch.

const std = @import("std");
const builtin = @import("builtin");
const routing = @import("routing");
const cli = @import("zig_cli");
const build_options = @import("build_options");
const io = routing.infra.io;
const config = routing.infra.config;
const http = routing.server.http;
const service = routing.api.service;
const bench = routing.cli.bench;
const diff = routing.cli.diff;
const dem = routing.cli.dem;
const Command = cli.BaseCommand;
const Context = Command.ParseContext;
const Allocator = std.mem.Allocator;

const App = struct {
    arena: Allocator,
    env: *const std.process.Environ.Map,
    stderr: *io.Writer,
    log_level: std.log.Level = .info,
    features: []const []const u8,
    version_details: []const u8,

    fn from(ctx: *Context) *App {
        return @ptrCast(@alignCast(ctx.user_data.?));
    }

    fn load(self: *App, ctx: *Context, file: ?[]const u8) !config.Loaded {
        var diagnostic: config.Diagnostic = .{};
        return config.load(self.arena, file, self.env, &diagnostic) catch |err| {
            if (diagnostic.message().len != 0) ctx.setDiagnostic(diagnostic.message());
            return err;
        };
    }

    fn warnIgnored(self: *App, keys: []const []const u8) void {
        if (@backingInt(self.log_level) < @backingInt(std.log.Level.warn) or keys.len == 0) return;
        const list = std.mem.join(self.arena, ", ", keys) catch return;
        std.debug.print("ignoring configuration keys: {s}\n", .{list});
    }
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |token| try args.append(a, token);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &out_buf);
    var stderr = io.stderrWriter(init.io, &err_buf);
    var features: std.ArrayList([]const u8) = .empty;
    for (builtin.cpu.arch.allFeaturesList()) |feature| {
        if (builtin.cpu.features.isEnabled(feature.index)) try features.append(a, feature.name);
    }
    var app: App = .{
        .arena = a,
        .env = init.environ_map,
        .stderr = &stderr.interface,
        .features = features.items,
        .version_details = try std.fmt.allocPrint(a, "commit {s}\nzig {s}\ncpu {s}\nfeatures {s}\n", .{
            build_options.commit,
            builtin.zig_version_string,
            @tagName(builtin.cpu.arch),
            try std.mem.join(a, ", ", features.items),
        }),
    };
    const root = try createCommands(a);
    return cli.run(a, root, if (args.items.len == 0) &.{"--help"} else args.items, .{
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .version = routing.version,
        .version_details = app.version_details,
        .user_data = &app,
    });
}

fn createCommands(a: Allocator) !*Command {
    const root = try Command.init(a, "zr", "Valhalla-compatible routing engine");
    _ = root.enableJson();
    _ = try root.addOption(option("config", "Read settings from a Valhalla JSON file", .string));
    _ = try root.addOption(option("threads", "Worker count", .int));
    _ = try root.addOption(option("log-level", "Logging threshold (error, warn, info, debug)", .string));

    _ = try command(root, "serve", "Start the HTTP service", serve, &.{
        option("host", "Bind to an IPv4 address", .string),
        option("port", "Bind to a TCP port", .int),
        option("elevation", "Read HGT tiles or a packed DEM", .string),
    }, &.{});
    _ = try command(root, "build", "Build a graph bundle from OSM data", buildGraph, &.{
        option("output", "Publish the graph bundle at this path", .string),
        option("work-dir", "Directory for stage checkpoints and build-stats.json", .string),
        option("dem", "Directory of HGT elevation tiles", .string),
        option("from", "First stage to run (default read)", .string),
        option("to", "Last stage to run (default finalize)", .string),
        option("order", "Dense node ordering (hilbert or encounter)", .string),
        option("drive-side", "Default driving side (right or left)", .string),
    }, &.{arg("OSM_PBF", "Source OSM PBF files").withRequired(false).withVariadic(true)});
    _ = try command(root, "route", "Run one request in process", route, &.{
        option("action", "Valhalla action (default route)", .string),
        option("file", "Read the request JSON from a file", .string),
    }, &.{arg("JSON", "Inline request JSON").withRequired(false)});
    _ = try command(root, "bench", "Benchmark an HTTP server or compare results", benchmark, &.{
        option("compare", "Compare two benchmark result files", .bool),
        option("corpus", "Request corpus file", .string),
        option("endpoint", "Default path for requests (default /route)", .string),
        option("connections", "Keep-alive connections (default 16)", .int),
        option("rate", "Open-loop requests per second", .float),
        option("duration", "Measured time, e.g. 30s or 2m (default 10s)", .string),
        option("requests", "Stop after this many measured requests", .int),
        option("warmup", "Excluded warm-up (default 2s)", .string),
        option("timeout", "Per-request timeout (default 30s)", .string),
        option("counters", "Record Linux hardware counters when available", .bool),
        option("out", "Write the JSON result to a file", .string),
        option("dataset", "Dataset name recorded in the result", .string),
        option("commit", "Server commit recorded in the result", .string),
        option("label", "Label recorded in the result", .string),
    }, &.{ arg("URL|A.json", "HTTP server or first result file"), arg("B.json", "Second result file").withRequired(false) });
    _ = try command(root, "diff", "Check API parity between two servers", compareServers, &.{
        option("corpus", "Request corpus file", .string).withRequired(true),
        option("endpoint", "Default path for requests (default /route)", .string),
        option("timeout", "Per-response timeout (default 60s)", .string),
        option("out", "Write the JSON parity report to a file", .string),
        option("worst", "Write worst cases to an existing directory", .string),
        option("keep", "Worst cases per scorer (default 10)", .int),
        option("label", "Label recorded in the report", .string),
    }, &.{ arg("A_URL", "First server"), arg("B_URL", "Second server") });
    _ = try command(root, "inspect", "Inspect a graph bundle", inspectGraph, &.{
        option("verify", "Verify every section payload checksum", .bool),
        option("edge", "Print a directed edge by ID", .int),
        option("node", "Print a node by ID", .int),
    }, &.{arg("BUNDLE", "Graph bundle directory")});
    const tagging = try command(root, "tags", "Inspect OSM tag transformations", null, &.{}, &.{});
    _ = try command(tagging, "dump", "Dump OSM node and way tag fields as JSON lines", dumpTags, &.{
        option("raw", "Dump input tags for the Valhalla oracle", .bool),
    }, &.{arg("PBF", "Source OSM PBF file")});
    const conf = try command(root, "config", "Inspect service configuration", null, &.{}, &.{});
    _ = try command(conf, "check", "Print effective settings and ignored keys", checkConfig, &.{}, &.{arg("FILE", "Valhalla JSON config")});
    const elevation = try command(root, "dem", "Pack, verify, and inspect elevation tiles", null, &.{}, &.{});
    _ = try command(elevation, "pack", "Pack an HGT directory", packDem, &.{}, &.{
        arg("HGT_DIR", "Source tile directory"), arg("PACK", "Output DEM file"),
    });
    _ = try command(elevation, "verify", "Compare a packed DEM with its HGT tiles", verifyDem, &.{
        option("samples", "Random samples per tile (default 1000)", .int),
    }, &.{ arg("PACK", "Packed DEM"), arg("HGT_DIR", "Source tile directory") });
    _ = try command(elevation, "info", "Describe a packed DEM", infoDem, &.{}, &.{arg("PACK", "Packed DEM")});
    _ = try command(root, "import-valhalla", "Import existing Valhalla graph tiles", stub, &.{}, &.{});
    _ = try command(root, "version", "Show version, commit, toolchain and CPU features", version, &.{}, &.{});
    return root;
}

fn option(name: []const u8, description: []const u8, kind: cli.Option.OptionType) cli.Option {
    return cli.Option.init(name, name, description, kind);
}

fn arg(name: []const u8, description: []const u8) cli.Argument {
    return cli.Argument.init(name, description, .string);
}

fn command(parent: *Command, name: []const u8, description: []const u8, comptime action: ?Command.CommandActionWithCode, options: []const cli.Option, args: []const cli.Argument) !*Command {
    const child = try Command.init(parent.allocator, name, description);
    _ = try parent.addCommand(child);
    for (options) |opt| _ = try child.addOption(opt);
    for (args) |param| _ = try child.addArgument(param);
    if (action) |execute| _ = child.setActionWithCode(struct {
        fn run(ctx: *Context) !u8 {
            if (ctx.getOption("log-level")) |level| {
                App.from(ctx).log_level = if (std.mem.eql(u8, level, "error")) .err else std.meta.stringToEnum(std.log.Level, level) orelse
                    return badOption(ctx, "--log-level expects error, warn, info or debug");
            }
            return execute(ctx);
        }
    }.run);
    return child;
}

fn badOption(ctx: *Context, message: []const u8) error{InvalidOptionValue} {
    ctx.setDiagnostic(message);
    return error.InvalidOptionValue;
}

fn unsigned(ctx: *Context, comptime T: type, comptime name: []const u8) !?T {
    const value = ctx.getOption(name) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch return badOption(ctx, "--" ++ name ++ " expects a non-negative integer in range");
}

fn duration(ctx: *Context, comptime name: []const u8) !?u64 {
    const value = ctx.getOption(name) orelse return null;
    return bench.parseDuration(value) catch return badOption(ctx, "--" ++ name ++ " expects a duration such as 30s");
}

fn stub(ctx: *Context) !u8 {
    const message = try std.fmt.allocPrint(ctx.allocator, "command '{s}' is not implemented", .{ctx.command_name});
    ctx.setDiagnostic(message);
    return error.NotImplemented;
}

fn version(ctx: *Context) !u8 {
    const app = App.from(ctx);
    if (ctx.wantsJson()) {
        try ctx.writeJson(.{
            .version = routing.version,
            .commit = build_options.commit,
            .zig = builtin.zig_version_string,
            .cpu = @tagName(builtin.cpu.arch),
            .features = app.features,
        });
    } else {
        try ctx.out.?.print("zr {s}\n{s}", .{ routing.version, app.version_details });
    }
    return 0;
}

fn checkConfig(ctx: *Context) !u8 {
    const loaded = try App.from(ctx).load(ctx, ctx.getArgument(0).?);
    const text = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .effective = loaded.config,
        .ignored_keys = loaded.ignored_keys,
    }, .{ .whitespace = .indent_2 });
    try ctx.out.?.print("{s}\n", .{text});
    return 0;
}

const Runtime = struct {
    svc: service.Service,
    tiles: ?routing.elevation.hgt.Tiles = null,
    pack: ?routing.elevation.@"packed".Pack = null,
    source: routing.elevation.Source = undefined,

    fn open(self: *Runtime, path: ?[]const u8) !void {
        const elevation = path orelse return;
        if (std.mem.endsWith(u8, elevation, ".zdem")) {
            self.pack = try routing.elevation.@"packed".Pack.open(elevation);
            self.source = .{ .pack = &self.pack.? };
        } else {
            self.tiles = try routing.elevation.hgt.Tiles.init(std.heap.c_allocator, elevation);
            self.source = .{ .tiles = &self.tiles.? };
        }
        self.svc.state = &self.source;
        self.svc.register(.height, routing.api.height_action.handle);
    }

    fn close(self: *Runtime) void {
        if (self.pack) |*pack| pack.close();
        if (self.tiles) |*tiles| tiles.deinit();
    }
};

fn serve(ctx: *Context) !u8 {
    const app = App.from(ctx);
    const loaded = try app.load(ctx, ctx.getOption("config"));
    app.warnIgnored(loaded.ignored_keys);
    var settings = try loaded.config.httpConfig();
    if (ctx.getOption("host")) |ip| {
        settings.address.ip = config.parseIp4(ip) catch return badOption(ctx, "--host expects an IPv4 address");
    }
    settings.address.port = (try unsigned(ctx, u16, "port")) orelse settings.address.port;
    settings.threads = (try unsigned(ctx, usize, "threads")) orelse settings.threads;

    var runtime: Runtime = .{ .svc = loaded.config.serviceConfig() };
    defer runtime.close();
    const elevation = ctx.getOption("elevation") orelse loaded.config.additional_data.elevation;
    try runtime.open(elevation);
    io.installTerminationHandler();
    var server = http.Server.init(std.heap.c_allocator, settings, runtime.svc.handler());
    try server.start();
    defer server.stop();
    const ip = settings.address.ip;
    if (ctx.wantsJson()) {
        try ctx.writeJson(.{ .host = ip, .port = server.port, .workers = server.threads.items.len });
        try ctx.out.?.flush();
    } else if (@backingInt(app.log_level) >= @backingInt(std.log.Level.info)) {
        if (runtime.pack) |pack| std.debug.print("elevation: {d} tiles in {s}\n", .{ pack.header.tile_count, elevation.? });
        if (runtime.tiles) |tiles| std.debug.print("elevation: {d} tiles under {s}\n", .{ tiles.count, elevation.? });
        std.debug.print("zr {s} listening on {d}.{d}.{d}.{d}:{d} with {d} workers\n", .{
            routing.version, ip[0], ip[1], ip[2], ip[3], server.port, server.threads.items.len,
        });
    }
    while (!io.termination_requested.load(.acquire)) io.sleepMs(200);
    if (@backingInt(app.log_level) >= @backingInt(std.log.Level.info)) {
        std.debug.print("shutting down: draining in-flight requests\n", .{});
    }
    return 0;
}

fn route(ctx: *Context) !u8 {
    const app = App.from(ctx);
    const action = std.meta.stringToEnum(service.Action, ctx.getOption("action") orelse "route") orelse
        return badOption(ctx, "--action expects a Valhalla action name");
    if (action == .no_action) return badOption(ctx, "--action expects a Valhalla action name");
    const file = ctx.getOption("file");
    const inline_json = ctx.getArgument(0);
    if ((file == null) == (inline_json == null)) return badOption(ctx, "provide inline request JSON or --file FILE");

    const loaded = try app.load(ctx, ctx.getOption("config"));
    app.warnIgnored(loaded.ignored_keys);
    const settings = try loaded.config.httpConfig();
    const body = if (file) |path| try io.readFileAlloc(app.arena, path, settings.max_body_bytes) else inline_json.?;
    if (body.len > settings.max_body_bytes) return error.FileTooBig;
    var runtime: Runtime = .{ .svc = loaded.config.serviceConfig() };
    defer runtime.close();
    try runtime.open(loaded.config.additional_data.elevation);

    var arena = routing.infra.arena.Arena.init(std.heap.c_allocator, .{ .cap_bytes = settings.arena_cap_bytes });
    defer arena.deinit();
    var worker: http.Ctx = .{
        .worker_id = 0,
        .arena = &arena,
        .deadline = if (settings.request_timeout_ms) |ms| io.Deadline.fromNowMs(ms) else .none,
    };
    const path = try std.fmt.allocPrint(app.arena, "/{s}", .{@tagName(action)});
    const req: http.Request = .{
        .method = .POST,
        .target = path,
        .path = path,
        .query = &.{},
        .headers = &.{},
        .body = body,
        .keep_alive = false,
    };
    var response: http.Response = .{ .gpa = arena.allocator() };
    runtime.svc.handle(&worker, &req, &response);
    if (response.body.items.len == 0 and response.status >= 400) return error.RequestFailed;
    const writer = if (response.status >= 400) app.stderr else ctx.out.?;
    try writer.writeAll(response.body.items);
    try writer.writeByte('\n');
    return if (response.status >= 400) 1 else 0;
}

fn workerCount(ctx: *Context) !?usize {
    if (try unsigned(ctx, usize, "threads")) |count| return count;
    const app = App.from(ctx);
    const path = ctx.getOption("config");
    if (path == null and app.env.get("ZR_ZIG_ROUTING_THREADS") == null) return null;
    const count = (try app.load(ctx, path)).config.zig_routing.threads;
    return if (count == 0) null else count;
}

fn benchmark(ctx: *Context) !u8 {
    const target = ctx.getArgument(0).?;
    if (std.mem.eql(u8, ctx.getOption("compare") orelse "false", "true")) {
        const other = ctx.getArgument(1) orelse return badOption(ctx, "--compare requires two JSON files");
        try bench.compareFiles(std.heap.c_allocator, target, other, ctx.wantsJson());
        return 0;
    }
    if (ctx.getArgument(1) != null) return badOption(ctx, "a second argument requires --compare");
    const corpus = ctx.getOption("corpus") orelse return badOption(ctx, "provide --corpus FILE");
    var opts: bench.Options = .{ .target = bench.parseTarget(target) catch return badOption(ctx, "expected an HTTP server URL") };
    opts.connections = (try unsigned(ctx, usize, "connections")) orelse opts.connections;
    opts.threads = (try workerCount(ctx)) orelse opts.threads;
    opts.duration_ns = (try duration(ctx, "duration")) orelse opts.duration_ns;
    opts.requests = try unsigned(ctx, u64, "requests");
    opts.timeout_ns = (try duration(ctx, "timeout")) orelse opts.timeout_ns;
    opts.warmup_ns = (try duration(ctx, "warmup")) orelse opts.warmup_ns;
    opts.measure_counters = std.mem.eql(u8, ctx.getOption("counters") orelse "false", "true");
    if (ctx.getOption("rate")) |value| {
        const rate = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(rate) or rate <= 0) return badOption(ctx, "--rate expects a positive finite number");
        opts.rate = rate;
    }
    try bench.runCommand(std.heap.c_allocator, opts, .{
        .target = target,
        .corpus_path = corpus,
        .dataset = ctx.getOption("dataset") orelse "",
        .commit = ctx.getOption("commit") orelse "",
        .label = ctx.getOption("label") orelse "",
    }, ctx.getOption("endpoint") orelse "/route", ctx.getOption("out"), ctx.wantsJson());
    return 0;
}

fn compareServers(ctx: *Context) !u8 {
    const a = ctx.getArgument(0).?;
    const b = ctx.getArgument(1).?;
    var opts: diff.Options = .{
        .a = bench.parseTarget(a) catch return badOption(ctx, "expected an HTTP URL for A_URL"),
        .b = bench.parseTarget(b) catch return badOption(ctx, "expected an HTTP URL for B_URL"),
    };
    opts.threads = (try workerCount(ctx)) orelse opts.threads;
    opts.worst = (try unsigned(ctx, usize, "keep")) orelse opts.worst;
    if (try duration(ctx, "timeout")) |ns| {
        opts.timeout_ms = std.math.cast(u32, ns / std.time.ns_per_ms) orelse return badOption(ctx, "--timeout is out of range");
    }
    const ok = try diff.runCommand(std.heap.c_allocator, opts, .{
        .a = a,
        .b = b,
        .corpus_path = ctx.getOption("corpus").?,
        .corpus_hash = 0,
        .label = ctx.getOption("label") orelse "",
    }, ctx.getOption("endpoint") orelse "/route", ctx.getOption("out"), ctx.getOption("worst"), ctx.wantsJson());
    return if (ok) 0 else 1;
}

fn buildGraph(ctx: *Context) !u8 {
    const driver = routing.build.driver;
    const loaded = try App.from(ctx).load(ctx, ctx.getOption("config"));
    const configured = loaded.config.zig_routing;
    const settings = configured.build;
    const output = ctx.getOption("output") orelse settings.bundle_path orelse configured.bundle_path;
    const work_dir = ctx.getOption("work-dir") orelse settings.work_dir orelse
        if (output) |path| try std.fmt.allocPrint(ctx.allocator, "{s}.work", .{path}) else return badOption(ctx, "provide --work-dir or --output");
    const from = std.meta.stringToEnum(driver.Stage, ctx.getOption("from") orelse "read") orelse
        return badOption(ctx, "unknown --from stage");
    const to = std.meta.stringToEnum(driver.Stage, ctx.getOption("to") orelse "finalize") orelse
        return badOption(ctx, "unknown --to stage");
    const order = if (ctx.getOption("order")) |text|
        std.meta.stringToEnum(routing.graph.format.OrderingKind, text) orelse return badOption(ctx, "--order expects hilbert or encounter")
    else
        null;
    const side = if (ctx.getOption("drive-side")) |text|
        std.meta.stringToEnum(routing.build.edge_class.DriveSide, text) orelse return badOption(ctx, "--drive-side expects right or left")
    else
        null;
    const arguments = try ctx.allocator.alloc([]const u8, ctx.getArgumentCount());
    for (arguments, 0..) |*value, i| value.* = ctx.getArgument(i).?;
    const options: driver.Options = .{
        .inputs = if (arguments.len == 0) settings.inputs else arguments,
        .output = output,
        .work_dir = work_dir,
        .dem_dir = ctx.getOption("dem") orelse settings.dem_dir orelse loaded.config.additional_data.elevation,
        .drive_side = side,
        .order = order,
        .workers = (try unsigned(ctx, usize, "threads")) orelse settings.threads orelse configured.threads,
        .from = from,
        .to = to,
    };
    var diagnostic: driver.Diagnostic = .{};
    const allocator = std.heap.c_allocator;
    const result = driver.run(allocator, options, if (ctx.wantsJson()) null else ctx.out, &diagnostic) catch |err| {
        const stage = if (diagnostic.stage) |stage| @tagName(stage) else "setup";
        const message = if (diagnostic.input) |path|
            try std.fmt.allocPrint(ctx.allocator, "build {s} could not read {s} ({s})", .{ stage, path, @errorName(err) })
        else switch (err) {
            error.MissingOsmInput => "provide at least one OSM PBF input",
            error.MissingBundlePath => "provide --output to finalize the bundle",
            error.InvalidStageRange => "--from must precede or equal --to",
            error.BuildWorkDirectoryBusy => "another build is using this work directory",
            error.MissingCheckpoint => try std.fmt.allocPrint(ctx.allocator, "build checkpoint for {s} is missing", .{stage}),
            error.StaleCheckpoint => try std.fmt.allocPrint(ctx.allocator, "build checkpoint for {s} is stale, restart from {s}", .{ stage, stage }),
            error.PathAlreadyExists => "the bundle destination already contains different data",
            error.CheckpointInputMismatch => "the work directory belongs to different build inputs",
            else => try std.fmt.allocPrint(ctx.allocator, "build {s} failed ({s})", .{ stage, @errorName(err) }),
        };
        ctx.setDiagnostic(message);
        return err;
    };
    defer result.deinit(allocator);
    if (ctx.wantsJson()) try ctx.writeJson(result);
    return 0;
}

fn inspectGraph(ctx: *Context) !u8 {
    const edge_id = try unsigned(ctx, u32, "edge");
    const node_id = try unsigned(ctx, u32, "node");
    const verify = std.mem.eql(u8, ctx.getOption("verify") orelse "false", "true");
    const path = ctx.getArgument(0).?;
    var diagnostic: routing.graph.reader.Diagnostic = .{};
    var bundle = routing.graph.reader.Bundle.openDescribed(path, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "open", diagnostic, err);
    defer bundle.close();
    if (verify) bundle.view.verify(.none, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "verify", diagnostic, err);
    try routing.cli.inspect.write(&bundle.view, ctx.out.?, ctx.wantsJson(), verify, edge_id, node_id);
    return 0;
}

fn graphDiagnostic(ctx: *Context, action: []const u8, diagnostic: routing.graph.reader.Diagnostic, err: anyerror) anyerror {
    const subject = if (diagnostic.section) |section| section.filename() else "graph bundle";
    const message = std.fmt.allocPrint(ctx.allocator, "could not {s} {s} ({t})", .{ action, subject, err }) catch return err;
    ctx.setDiagnostic(message);
    return err;
}

fn dumpTags(ctx: *Context) !u8 {
    const raw = std.mem.eql(u8, ctx.getOption("raw") orelse "false", "true");
    try routing.cli.tags.dump(std.heap.c_allocator, ctx.getArgument(0).?, raw, ctx.out.?, .none);
    return 0;
}

fn packDem(ctx: *Context) !u8 {
    const pack = ctx.getArgument(1).?;
    const threads = dem.threadCount(try workerCount(ctx));
    try dem.pack(std.heap.c_allocator, ctx.getArgument(0).?, pack, threads);
    if (ctx.wantsJson()) try ctx.writeJson(.{ .ok = true, .pack = pack });
    return 0;
}

fn verifyDem(ctx: *Context) !u8 {
    const pack = ctx.getArgument(0).?;
    const threads = dem.threadCount(try workerCount(ctx));
    try dem.verify(std.heap.c_allocator, pack, ctx.getArgument(1).?, (try unsigned(ctx, usize, "samples")) orelse 1000, threads);
    if (ctx.wantsJson()) try ctx.writeJson(.{ .ok = true, .pack = pack });
    return 0;
}

fn infoDem(ctx: *Context) !u8 {
    const info = try dem.loadInfo(ctx.getArgument(0).?);
    if (ctx.wantsJson()) try ctx.writeJson(info) else dem.printInfo(info);
    return 0;
}
