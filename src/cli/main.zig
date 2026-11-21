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
const inspect = routing.cli.inspect;
const traffic = routing.cli.traffic;
const dem = routing.cli.dem;
const Command = cli.BaseCommand;
const Context = Command.ParseContext;
const Allocator = std.mem.Allocator;

const cpu_features = features: {
    const arch_features = builtin.cpu.arch.allFeaturesList();
    var names: [arch_features.len][]const u8 = undefined;
    var count: usize = 0;
    for (arch_features) |feature| {
        if (!builtin.cpu.features.isEnabled(feature.index)) continue;
        names[count] = feature.name;
        count += 1;
    }
    break :features names[0..count].*;
};
const version_details = details: {
    var features: []const u8 = "";
    for (cpu_features, 0..) |name, i| features = features ++ (if (i == 0) "" else ", ") ++ name;
    break :details std.fmt.comptimePrint("commit {s}\nzig {s}\ncpu {s}\nfeatures {s}\n", .{
        build_options.commit, builtin.zig_version_string, @tagName(builtin.cpu.arch), features,
    });
};

const App = struct {
    arena: Allocator,
    env: *const std.process.Environ.Map,
    stderr: *io.Writer,
    log_level: std.log.Level = .info,

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
    var app: App = .{
        .arena = a,
        .env = init.environ_map,
        .stderr = &stderr.interface,
    };
    const root = try createCommands(a);
    return cli.run(a, root, if (args.items.len == 0) &.{"--help"} else args.items, .{
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
        .version = routing.version,
        .version_details = version_details,
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
        option("gtfs", "GTFS schedule ZIP. Use zig_routing.build.gtfs_inputs for multiple feeds", .string),
        option("edge-key-hash", "Build a minimal perfect hash for edge-key lookup", .bool),
        option("work-dir", "Directory for stage checkpoints and build-stats.json", .string),
        option("dem", "Directory of HGT elevation tiles", .string),
        option("timezones", "Timezone boundary GeoJSON file", .string),
        option("timezone-rules", "Compiled IANA timezone rules file", .string),
        option("pbf-buffer-bytes", "Cap decoded PBF buffers (default 512 MiB)", .int),
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
    _ = try command(root, "diff", "Compare API servers or graph edge keys", compareServers, &.{
        option("edge-keys", "Compare the stable edge keys of two graph bundles", .bool),
        option("corpus", "Request corpus file for HTTP comparison", .string),
        option("endpoint", "Default path for requests (default /route)", .string),
        option("timeout", "Per-response timeout (default 60s)", .string),
        option("out", "Write the JSON report to a file", .string),
        option("worst", "Write worst cases to an existing directory", .string),
        option("keep", "Worst cases per scorer (default 10)", .int),
        option("label", "Label recorded in the report", .string),
    }, &.{ arg("A", "First server URL or graph bundle"), arg("B", "Second server URL or graph bundle") });
    _ = try command(root, "inspect", "Inspect a graph bundle or vector tile", inspectGraph, &.{
        option("verify", "Verify every section payload checksum", .bool),
        option("mvt", "Decode a raw or gzip-compressed vector tile", .bool),
        option("edge", "Print a directed edge by ID", .int),
        option("node", "Print a node by ID", .int),
        option("edge-key", "Find WAY,BEGIN,END,forward|reverse[,OCCURRENCE[,KIND]]", .string),
        option("key-for-edge", "Print the stable key for a directed edge ID", .int),
    }, &.{arg("INPUT", "Graph bundle directory or vector tile file")});
    const traffic_cmd = try command(root, "traffic", "Manage live and predicted speeds", null, &.{}, &.{});
    _ = try command(traffic_cmd, "set", "Apply a CSV or JSON lines file by stable edge key", setTraffic, &.{
        option("format", "Input format (csv or jsonl)", .string),
        option("max-age", "Maximum observation age in seconds (default 300)", .int),
    }, &.{ arg("BUNDLE", "Graph bundle directory"), arg("FILE", "Traffic update file") });
    _ = try command(traffic_cmd, "serve", "Run the loopback traffic update endpoint", serveTraffic, &.{
        option("port", "Loopback TCP port (default 8003)", .int),
        option("max-age", "Maximum observation age in seconds (default 300)", .int),
    }, &.{arg("BUNDLE", "Graph bundle directory")});
    _ = try command(traffic_cmd, "add-predicted", "Add weekly profiles and static traffic speeds from CSV", addPredicted, &.{}, &.{
        arg("BUNDLE", "Graph bundle directory"), arg("FILE", "CSV with edge keys and predicted speeds"),
    });
    const geocode_cmd = try command(root, "geocode", "Manage geocoding data", null, &.{}, &.{});
    _ = try command(geocode_cmd, "build", "Extract geocoding records from OpenStreetMap", buildGeocode, &.{
        option("threads", "Number of PBF decode workers", .int),
        option("timeout", "Time limit for extraction", .string),
        option("admin-pbf", "Additional boundary extract from the same OSM snapshot", .string).withRepeatable(true),
    }, &.{ arg("PBF", "Source OSM PBF file"), arg("OUTPUT", "New geocoding bundle directory") });
    _ = try command(geocode_cmd, "inspect", "Verify and count geocoding bundle records", inspectGeocode, &.{}, &.{
        arg("BUNDLE", "Geocoding bundle directory"),
    });
    _ = try command(geocode_cmd, "index", "Build a geocoder term index from a bundle", buildGeocodeIndex, &.{
        option("threads", "Number of parallel analysis workers", .int),
        option("timeout", "Time limit for building the index", .string),
    }, &.{arg("BUNDLE", "Geocoding bundle directory")});
    _ = try command(geocode_cmd, "search", "Search an indexed geocoding bundle", searchGeocode, &.{
        option("name", "Name to match", .string),
        option("street", "Street to match", .string),
        option("city", "City to match", .string),
        option("postcode", "Postcode to match", .string),
        option("house-number", "House number to match", .string),
        option("country", "Country name or ISO code", .string),
        option("language", "Preferred result language", .string),
        option("near", "Bias point as longitude,latitude", .string),
        option("bbox", "Filter by west,south,east,north", .string),
        option("layer", "Result layer: place, street, address or poi", .string).withRepeatable(true),
        option("limit", "Maximum results (default 10)", .int),
        option("exact", "Require exact tokens and their aliases", .bool),
        option("timeout", "Time limit for opening the bundle and searching", .string),
    }, &.{ arg("BUNDLE", "Geocoding bundle directory"), arg("TEXT", "Free text query").withRequired(false) });
    _ = try command(geocode_cmd, "postcode", "Look up postcode centroids and extents", lookupGeocodePostcodes, &.{
        option("timeout", "Time limit for bundle verification and lookup", .string),
    }, &.{
        arg("BUNDLE", "Geocoding bundle directory"),
        arg("COUNTRY", "ISO 3166-1 alpha-2 country code"),
        arg("CODE", "Postcode to look up").withVariadic(true),
    });
    _ = try command(root, "bundle-manifest", "Write range hashes for a graph bundle", bundleManifest, &.{
        option("output", "Range manifest output file", .string).withRequired(true),
    }, &.{arg("BUNDLE", "Graph bundle directory")});
    _ = try command(root, "fetch-bundle", "Fill a verified graph bundle from HTTP ranges", fetchBundle, &.{
        option("timeout", "Time limit for completing the bundle", .string),
    }, &.{ arg("URL", "Bundle origin directory"), arg("MANIFEST", "Trusted range manifest file"), arg("CACHE", "Existing local cache directory") });
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
    _ = try command(root, "import-valhalla", "Import local Valhalla tiles into a test graph bundle", importValhalla, &.{
        option("output", "Publish the graph bundle at this path", .string).withRequired(true),
    }, &.{arg("TILES", "Valhalla tile directory, .gph file or indexed tiles.tar").withVariadic(true)});
    const parity = try command(root, "parity", "Run same-graph oracle parity checks", null, &.{}, &.{});
    _ = try command(parity, "costing", "Compare native and Valhalla costing calls and path recosts", compareCosting, &.{
        option("out", "Write the gate A JSON report", .string),
        option("minimum-calls", "Required calls per mode (default 10000000)", .int),
    }, &.{ arg("BUNDLE", "Bundle imported from the oracle tiles"), arg("REFERENCE", "Valhalla costing reference binary") });
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

fn version(ctx: *Context) !u8 {
    if (ctx.wantsJson()) {
        try ctx.writeJson(.{
            .version = routing.version,
            .commit = build_options.commit,
            .zig = builtin.zig_version_string,
            .cpu = @tagName(builtin.cpu.arch),
            .features = &cpu_features,
        });
    } else {
        try ctx.out.?.print("zr {s}\n{s}", .{ routing.version, version_details });
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
    bundle: ?routing.graph.reader.Bundle = null,
    warmup: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
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
        self.stopping.store(true, .release);
        if (self.warmup) |worker| worker.join();
        if (self.svc.transit_coverage) |coverage| std.heap.c_allocator.destroy(@constCast(coverage));
        if (self.bundle) |*bundle| bundle.close();
        if (self.pack) |*pack| pack.close();
        if (self.tiles) |*tiles| tiles.deinit();
    }

    fn openGraph(self: *Runtime, ctx: *Context, path: ?[]const u8) !void {
        self.bundle = routing.graph.reader.Bundle.open(path orelse return) catch |err| {
            switch (err) {
                error.LiveTrafficDatasetUuidMismatch => ctx.setDiagnostic("traffic-live.bin dataset UUID does not match the configured graph bundle"),
                error.PredictedTrafficDatasetUuidMismatch => ctx.setDiagnostic("traffic-pred.bin dataset UUID does not match the configured graph bundle"),
                else => {},
            }
            return err;
        };
        self.svc.graph = &self.bundle.?.view;
        self.svc.transit_coverage = try routing.graph.transit_coverage.Index.init(std.heap.c_allocator, self.bundle.?.view.transit_index, .none);
        self.svc.register(.locate, routing.api.locate_action.handle);
        self.svc.register(.tile, routing.api.tile_action.handle);
        self.svc.register(.transit_available, routing.api.transit_available_action.handle);
    }

    fn startWarmup(self: *Runtime, lock_hot: bool) void {
        if (self.bundle == null) return;
        self.warmup = std.Thread.spawn(.{}, warmBundle, .{ self, lock_hot }) catch |err| {
            std.log.warn("could not start graph warm-up ({t})", .{err});
            return;
        };
    }

    fn warmBundle(self: *Runtime, lock_hot: bool) void {
        self.bundle.?.warm(lock_hot, &self.stopping);
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
    try runtime.openGraph(ctx, loaded.config.zig_routing.bundle_path);
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
    runtime.startWarmup(loaded.config.zig_routing.mlock_hot);
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
    if (action == .locate or action == .tile or action == .transit_available) try runtime.openGraph(ctx, loaded.config.zig_routing.bundle_path);

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
    if (action != .tile or response.status >= 400) try writer.writeByte('\n');
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
    if (std.mem.eql(u8, ctx.getOption("edge-keys") orelse "false", "true")) return compareEdgeKeys(ctx);
    const corpus = ctx.getOption("corpus") orelse return badOption(ctx, "provide --corpus for HTTP comparison");
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
        .corpus_path = corpus,
        .corpus_hash = 0,
        .label = ctx.getOption("label") orelse "",
    }, ctx.getOption("endpoint") orelse "/route", ctx.getOption("out"), ctx.getOption("worst"), ctx.wantsJson());
    return if (ok) 0 else 1;
}

fn compareEdgeKeys(ctx: *Context) !u8 {
    if (ctx.getOption("corpus") != null or ctx.getOption("endpoint") != null or ctx.getOption("worst") != null or
        ctx.getOption("keep") != null or ctx.getOption("label") != null)
        return badOption(ctx, "--edge-keys expects two bundle directories and accepts --timeout, --out and --json");
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |span| io.Deadline.fromNow(span) else .none;
    var diagnostic: routing.graph.reader.Diagnostic = .{};
    const Bundle = routing.graph.reader.Bundle;
    var old = Bundle.openVerified(ctx.getArgument(0).?, deadline, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "verify first", diagnostic, err);
    defer old.close();
    var new = Bundle.openVerified(ctx.getArgument(1).?, deadline, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "verify second", diagnostic, err);
    defer new.close();
    const before = old.view.edge_key_index orelse return missingEdgeKeys(ctx);
    const after = new.view.edge_key_index orelse return missingEdgeKeys(ctx);
    if (ctx.getOption("out")) |path| {
        var report: io.Writer.Allocating = .init(std.heap.c_allocator);
        defer report.deinit();
        try inspect.diffEdgeKeys(before, after, &report.writer, true, deadline);
        try io.writeFile(path, report.written());
        if (ctx.wantsJson()) try ctx.out.?.writeAll(report.written());
    }
    if (!ctx.wantsJson() or ctx.getOption("out") == null)
        try inspect.diffEdgeKeys(before, after, ctx.out.?, ctx.wantsJson(), deadline);
    return 0;
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
        .gtfs_inputs = if (ctx.getOption("gtfs")) |path| &.{path} else settings.gtfs_inputs,
        .edge_key_hash = if (ctx.getOption("edge-key-hash")) |enabled| std.mem.eql(u8, enabled, "true") else settings.edge_key_hash,
        .output = output,
        .work_dir = work_dir,
        .dem_dir = ctx.getOption("dem") orelse settings.dem_dir orelse loaded.config.additional_data.elevation,
        .timezone_geojson = ctx.getOption("timezones") orelse settings.timezone_geojson,
        .timezone_rules = ctx.getOption("timezone-rules") orelse settings.timezone_rules,
        .default_speeds_config = loaded.config.mjolnir.default_speeds_config,
        .reclassify_links = loaded.config.mjolnir.reclassify_links,
        .infer_turn_channels = loaded.config.mjolnir.data_processing.infer_turn_channels,
        .infer_internal_intersections = loaded.config.mjolnir.data_processing.infer_internal_intersections,
        .apply_country_overrides = loaded.config.mjolnir.data_processing.apply_country_overrides,
        .use_admin_db = loaded.config.mjolnir.data_processing.use_admin_db,
        .allow_alt_name = loaded.config.mjolnir.data_processing.allow_alt_name,
        .use_direction_on_ways = loaded.config.mjolnir.data_processing.use_direction_on_ways,
        .drive_side = side,
        .order = order,
        .workers = (try unsigned(ctx, usize, "threads")) orelse settings.threads orelse configured.threads,
        .pbf_buffer_bytes = (try unsigned(ctx, usize, "pbf-buffer-bytes")) orelse settings.pbf_buffer_bytes orelse driver.default_pbf_buffer_bytes,
        .from = from,
        .to = to,
    };
    var diagnostic: driver.Diagnostic = .{};
    const allocator = std.heap.c_allocator;
    const result = driver.run(allocator, options, if (ctx.wantsJson()) null else ctx.out, &diagnostic) catch |err| {
        const stage = if (diagnostic.stage) |stage| @tagName(stage) else "setup";
        const message = if (diagnostic.input) |path| blk: {
            const table = diagnostic.gtfs_table;
            if (table.file.len != 0)
                break :blk try std.fmt.allocPrint(ctx.allocator, "build {s} could not read {s} {s} row {d}, column {d} ({s})", .{
                    stage, path, table.file, table.row, table.column, @errorName(err),
                });
            break :blk try std.fmt.allocPrint(ctx.allocator, "build {s} could not read {s} ({s})", .{ stage, path, @errorName(err) });
        } else switch (err) {
            error.MissingOsmInput => "provide at least one OSM PBF input",
            error.MissingGtfsInput => "provide a GTFS schedule ZIP for the transit stage",
            error.MissingBundlePath => "provide --output to finalize the bundle",
            error.InvalidStageRange => "--from must precede or equal --to",
            error.PbfDecodeBudgetExceeded => "PBF decode buffer budget cannot fit the largest compressed block",
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
    if (ctx.wantsJson()) {
        try ctx.writeJson(result);
    } else if (result.transit) |report| {
        try ctx.out.?.print("transit connected {d}/{d} platforms\n", .{ report.connected, report.platforms });
        if (report.connected != report.platforms)
            try ctx.out.?.print("  {d} missing coordinates, {d} without a walkable street, {d} without a pathway to the street, {d} one-way only\n", .{
                report.missing_coordinates, report.no_pedestrian_street, report.no_pathway_to_street, report.one_way_only,
            });
    }
    return 0;
}

fn inspectGraph(ctx: *Context) !u8 {
    const edge_id = try unsigned(ctx, u32, "edge");
    const node_id = try unsigned(ctx, u32, "node");
    const key_edge = try unsigned(ctx, u32, "key-for-edge");
    const edge_key = if (ctx.getOption("edge-key")) |text|
        routing.graph.edge_keys.Key.parse(text) catch return badOption(ctx, "--edge-key expects WAY,BEGIN,END,forward|reverse[,OCCURRENCE[,KIND]]")
    else
        null;
    if ((edge_key != null and key_edge != null) or ((edge_key != null or key_edge != null) and (edge_id != null or node_id != null)))
        return badOption(ctx, "choose one edge-key lookup per inspection");
    const verify = std.mem.eql(u8, ctx.getOption("verify") orelse "false", "true");
    const path = ctx.getArgument(0).?;
    if (std.mem.eql(u8, ctx.getOption("mvt") orelse "false", "true")) {
        if (edge_id != null or node_id != null or key_edge != null or edge_key != null)
            return badOption(ctx, "edge and node lookups require a graph bundle");
        const mapping = try io.Mapping.mapFile(path, .read_only);
        defer mapping.unmap();
        try inspect.writeTile(ctx.allocator, mapping.bytes, ctx.out.?, ctx.wantsJson());
        return 0;
    }
    var diagnostic: routing.graph.reader.Diagnostic = .{};
    const Bundle = routing.graph.reader.Bundle;
    var bundle = if (verify)
        Bundle.openVerified(path, .none, &diagnostic) catch |err| return graphDiagnostic(ctx, "verify", diagnostic, err)
    else
        Bundle.openDescribed(path, &diagnostic) catch |err| return graphDiagnostic(ctx, "open", diagnostic, err);
    defer bundle.close();
    if (edge_key != null or key_edge != null) {
        const index = bundle.view.edge_key_index orelse return missingEdgeKeys(ctx);
        try inspect.writeEdgeKey(index, ctx.out.?, ctx.wantsJson(), if (edge_key) |key| .{ .key = key } else .{ .edge = key_edge.? });
    } else {
        try inspect.write(&bundle, ctx.out.?, ctx.wantsJson(), verify, edge_id, node_id);
    }
    return 0;
}

fn missingEdgeKeys(ctx: *Context) error{MissingEdgeKeys} {
    ctx.setDiagnostic("bundle needs stable edge-key sections");
    return error.MissingEdgeKeys;
}

fn setTraffic(ctx: *Context) !u8 {
    const input = ctx.getArgument(1).?;
    const FeedFormat = routing.traffic.feed.Format;
    const kind: FeedFormat = if (ctx.getOption("format")) |name|
        std.meta.stringToEnum(FeedFormat, name) orelse return badOption(ctx, "--format expects csv or jsonl")
    else if (std.mem.endsWith(u8, input, ".jsonl") or std.mem.endsWith(u8, input, ".ndjson"))
        .jsonl
    else
        .csv;
    const max_age = (try unsigned(ctx, u64, "max-age")) orelse routing.traffic.live.default_max_age_seconds;
    const map = try io.Mapping.mapFile(input, .read_only);
    defer map.unmap();
    const a = std.heap.c_allocator;
    var owned = traffic.OwnedFeeder.open(a, ctx.getArgument(0).?, max_age, .none) catch |err| {
        if (err == error.MissingEdgeKeys) return missingEdgeKeys(ctx);
        return err;
    };
    defer owned.close();
    const now = std.math.cast(u64, io.wallSeconds()) orelse return error.InvalidLiveTrafficTime;
    const report = try owned.feeder.apply(a, map.bytes, kind, now, .none);
    defer report.deinit(a);
    try ctx.writeJson(report);
    return 0;
}

fn buildGeocode(ctx: *Context) !u8 {
    const workers = (try unsigned(ctx, usize, "threads")) orelse 0;
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |ns| .fromNow(ns) else .none;
    const report = try routing.geocode.extract.build(std.heap.c_allocator, ctx.getArgument(0).?, ctx.getArgument(1).?, .{
        .workers = workers,
        .admin_sources = ctx.getOptionValues("admin-pbf"),
    }, deadline);
    try ctx.writeJson(report);
    return 0;
}

fn inspectGeocode(ctx: *Context) !u8 {
    const geocode = routing.geocode;
    const a = std.heap.c_allocator;
    const dir = try io.Directory.open(ctx.getArgument(0).?);
    defer dir.close();
    var opened = try geocode.bundle.Bundle.openInDir(dir, .none);
    defer opened.close();
    const data = opened.data;
    var index: ?geocode.index.Index = geocode.index.Index.open(dir, opened.uuid, .none) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (index) |*present| present.close();
    var stats: ?geocode.index.Summary = if (index) |present| blk: {
        if (!std.meta.eql(present.view.header.records, try geocode.index_build.counts(data)))
            return error.GeocodeIndexRecordCountMismatch;
        break :blk try present.view.summarize(a, 10, .none);
    } else null;
    defer if (stats) |*present| present.deinit(a);
    try ctx.writeJson(.{
        .places = data.places.len,
        .streets = data.streets.len,
        .street_ways = data.street_ways.len,
        .addresses = data.addresses.len,
        .pois = data.pois.len,
        .admins = data.admins.len,
        .house_links = if (data.address_data) |addresses| addresses.house_links.len else 0,
        .interpolations = if (data.address_data) |addresses| addresses.interpolations.len else 0,
        .postcodes = if (data.address_data) |addresses| addresses.postcodes.len else 0,
        .index = stats,
        .coverage = try data.coverage(.none),
        .attribution = geocode.model.attribution,
        .attribution_url = geocode.model.attribution_url,
        .license = geocode.model.license,
    });
    return 0;
}

fn buildGeocodeIndex(ctx: *Context) !u8 {
    const workers = (try unsigned(ctx, usize, "threads")) orelse 0;
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |ns| .fromNow(ns) else .none;
    const report = try routing.geocode.index_build.build(std.heap.c_allocator, ctx.getArgument(0).?, workers, deadline);
    try ctx.writeJson(report);
    return 0;
}

fn searchGeocode(ctx: *Context) !u8 {
    const geocode = routing.geocode.query;
    const a = App.from(ctx).arena;
    const structured: geocode.Structured = .{
        .name = ctx.getOption("name") orelse "",
        .street = ctx.getOption("street") orelse "",
        .city = ctx.getOption("city") orelse "",
        .postcode = ctx.getOption("postcode") orelse "",
        .house_number = ctx.getOption("house-number") orelse "",
        .country = ctx.getOption("country") orelse "",
    };
    const has_fields = structured.byteCount() != 0;
    const text: geocode.Text = if (ctx.getArgument(1)) |value| text: {
        if (has_fields) return badOption(ctx, "choose free text or structured query fields");
        break :text .{ .free = value };
    } else if (has_fields) .{ .structured = structured } else return badOption(ctx, "provide query text or structured fields");

    var filters: geocode.Filters = .{ .language = ctx.getOption("language") orelse "" };
    if (ctx.getOption("near")) |raw| {
        const point = geocodeNumbers(2, raw) catch return badOption(ctx, "--near expects longitude,latitude");
        filters.near = .init(point[0], point[1]);
    }
    if (ctx.getOption("bbox")) |raw| {
        const box = geocodeNumbers(4, raw) catch return badOption(ctx, "--bbox expects west,south,east,north");
        filters.bounds = .{ .west = box[0], .south = box[1], .east = box[2], .north = box[3] };
    }
    const layers = ctx.getOptionValues("layer");
    if (layers.len != 0) {
        filters.layers = .empty;
        for (layers) |name| filters.layers.insert(std.meta.stringToEnum(geocode.Layer, name) orelse
            return badOption(ctx, "--layer expects place, street, address or poi"));
    }
    const limit = (try unsigned(ctx, usize, "limit")) orelse 10;
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |ns| .fromNow(ns) else .none;
    var engine = try geocode.Engine.open(std.heap.page_allocator, ctx.getArgument(0).?, deadline);
    defer engine.close();
    const found = try engine.search(a, .{
        .text = text,
        .filters = filters,
        .limit = limit,
        .typos = !std.mem.eql(u8, ctx.getOption("exact") orelse "false", "true"),
    }, deadline);
    try ctx.writeJson(found);
    return 0;
}

fn geocodeNumbers(comptime count: usize, text: []const u8) ![count]f64 {
    var values: [count]f64 = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    for (&values) |*value| {
        const part = parts.next() orelse return error.InvalidGeocodeCoordinates;
        value.* = try std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t"));
    }
    if (parts.next() != null) return error.InvalidGeocodeCoordinates;
    return values;
}

fn lookupGeocodePostcodes(ctx: *Context) !u8 {
    const geocode = routing.geocode;
    const iso = ctx.getArgument(1).?;
    if (iso.len != 2 or !std.ascii.isAlphabetic(iso[0]) or !std.ascii.isAlphabetic(iso[1]))
        return badOption(ctx, "COUNTRY expects a two-letter country code");
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |ns| .fromNow(ns) else .none;
    var opened = try geocode.bundle.Bundle.open(ctx.getArgument(0).?, deadline);
    defer opened.close();
    const data = opened.data;
    const addresses = data.address_data orelse return error.MissingGeocodeAddressIndex;
    const a = std.heap.c_allocator;
    var country_ids: std.ArrayList(geocode.model.AdminId) = .empty;
    defer country_ids.deinit(a);
    for (addresses.country_codes, 0..) |span, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (std.ascii.eqlIgnoreCase(iso, try span.get(data.text))) {
            try country_ids.append(a, @fromBackingInt(@intCast(std.math.cast(u32, i + 1) orelse return error.GeocodeSectionTooLarge)));
        }
    }
    const Result = struct {
        query: []const u8,
        record: ?struct {
            postcode: []const u8,
            center: routing.geo.PointLL,
            min: routing.geo.PointLL,
            max: routing.geo.PointLL,
            address_count: u32,
            from_boundary: bool,
        } = null,
    };
    const results = try a.alloc(Result, ctx.getArgumentCount() - 2);
    defer a.free(results);
    for (results, 2..) |*result, i| {
        if (deadline.expired()) return error.DeadlineExceeded;
        result.* = .{ .query = ctx.getArgument(i).? };
        for (country_ids.items) |country| {
            const match = try data.lookupPostcode(country, result.query) orelse continue;
            result.record = .{
                .postcode = try match.code.get(data.text),
                .center = match.center.toPoint(),
                .min = match.min.toPoint(),
                .max = match.max.toPoint(),
                .address_count = match.address_count,
                .from_boundary = match.attr.from_boundary,
            };
            break;
        }
    }
    try ctx.writeJson(.{
        .country = iso,
        .results = results,
        .attribution = geocode.model.attribution,
        .attribution_url = geocode.model.attribution_url,
        .license = geocode.model.license,
    });
    return 0;
}

fn addPredicted(ctx: *Context) !u8 {
    const dir = try io.Directory.open(ctx.getArgument(0).?);
    defer dir.close();
    var bundle = try routing.graph.reader.Bundle.openInDir(dir, null);
    defer bundle.close();
    const view = &bundle.view;
    const index = view.edge_key_index orelse return missingEdgeKeys(ctx);
    try index.verify(view.edges.len, .none);
    const edge_count = std.math.cast(u32, view.edges.len) orelse return error.PredictedTrafficTooLarge;
    const map = try io.Mapping.mapFile(ctx.getArgument(1).?, .read_only);
    defer map.unmap();
    const report = try routing.traffic.predicted_ingest.apply(std.heap.c_allocator, dir, view.dataset_uuid, edge_count, index, map.bytes, .none);
    try ctx.writeJson(report);
    return 0;
}

fn serveTraffic(ctx: *Context) !u8 {
    const app = App.from(ctx);
    const token = app.env.get("ZR_TRAFFIC_TOKEN") orelse return badOption(ctx, "set ZR_TRAFFIC_TOKEN to serve traffic updates");
    if (token.len == 0) return badOption(ctx, "ZR_TRAFFIC_TOKEN must be nonempty");
    const max_age = (try unsigned(ctx, u64, "max-age")) orelse routing.traffic.live.default_max_age_seconds;
    const port = (try unsigned(ctx, u16, "port")) orelse 8003;
    const a = std.heap.c_allocator;
    var owned = traffic.OwnedFeeder.open(a, ctx.getArgument(0).?, max_age, .none) catch |err| {
        if (err == error.MissingEdgeKeys) return missingEdgeKeys(ctx);
        return err;
    };
    defer owned.close();
    var admin = traffic.Admin.init(&owned.feeder, token);
    io.installTerminationHandler();
    var server = http.Server.init(a, .{ .address = io.Address.loopback(port), .threads = 1 }, admin.handler());
    try server.start();
    defer server.stop();
    if (ctx.wantsJson()) {
        try ctx.writeJson(.{ .host = .{ 127, 0, 0, 1 }, .port = server.port });
        try ctx.out.?.flush();
    } else {
        try ctx.out.?.print("Traffic update endpoint on loopback port {d}\n", .{server.port});
        try ctx.out.?.flush();
    }
    while (!io.termination_requested.load(.acquire)) {
        io.sleepMs(250);
        const now = std.math.cast(u64, io.wallSeconds()) orelse return error.InvalidLiveTrafficTime;
        admin.expire(now, io.Deadline.fromNowMs(120_000)) catch |err| switch (err) {
            error.DeadlineExceeded => continue,
            else => return err,
        };
    }
    return 0;
}

fn bundleManifest(ctx: *Context) !u8 {
    var diagnostic: routing.graph.reader.Diagnostic = .{};
    var bundle = routing.graph.reader.Bundle.openVerified(ctx.getArgument(0).?, .none, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "verify", diagnostic, err);
    defer bundle.close();
    const manifest = try routing.graph.range_manifest.encode(ctx.allocator, &bundle, .none);
    defer ctx.allocator.free(manifest);
    const path = ctx.getOption("output").?;
    const dir = try io.Directory.open(std.fs.path.dirname(path) orelse ".");
    defer dir.close();
    const name = try ctx.allocator.dupeSentinel(u8, std.fs.path.basename(path), 0);
    defer ctx.allocator.free(name);
    try dir.writeAtomic(name, manifest);
    return 0;
}

fn fetchBundle(ctx: *Context) !u8 {
    const a = ctx.allocator;
    const deadline: io.Deadline = if (try duration(ctx, "timeout")) |span| io.Deadline.fromNow(span) else .none;
    const manifest = try io.Mapping.mapFile(ctx.getArgument(1).?, .read_only);
    defer manifest.unmap();
    const path = ctx.getArgument(2).?;
    const root = try io.Directory.open(path);
    defer root.close();
    var origin = try routing.graph.range_http.Origin.open(a, ctx.getArgument(0).?);
    defer origin.close(a);
    var cache = try routing.graph.range_cache.Cache.open(a, root, manifest.bytes, origin.source(), .{}, deadline);
    defer cache.close();
    try cache.fill(&.{}, deadline);
    var diagnostic: routing.graph.reader.Diagnostic = .{};
    var bundle = routing.graph.reader.Bundle.openInDir(cache.dir, &diagnostic) catch |err|
        return graphDiagnostic(ctx, "open", diagnostic, err);
    defer bundle.close();
    bundle.view.verify(deadline, &diagnostic) catch |err| return graphDiagnostic(ctx, "verify", diagnostic, err);
    if (!std.mem.eql(u8, &bundle.view.dataset_uuid, &cache.manifest.dataset_uuid)) return error.DatasetUuidMismatch;
    const result = try std.fs.path.join(a, &.{ path, &cache.key });
    defer a.free(result);
    if (ctx.wantsJson()) try ctx.writeJson(.{ .bundle = result }) else try ctx.out.?.print("{s}\n", .{result});
    return 0;
}

fn importValhalla(ctx: *Context) !u8 {
    const paths = try ctx.allocator.alloc([]const u8, ctx.getArgumentCount());
    for (paths, 0..) |*path, i| path.* = ctx.getArgument(i).?;
    const stats = routing.cli.import_valhalla.run(std.heap.c_allocator, paths, ctx.getOption("output").?, .none) catch |err| {
        ctx.setDiagnostic(try std.fmt.allocPrint(ctx.allocator, "could not import Valhalla tiles ({t})", .{err}));
        return err;
    };
    if (stats.version_mismatches != 0) {
        try App.from(ctx).stderr.print("warning: {d} Valhalla tiles have a major version other than 3\n", .{stats.version_mismatches});
    }
    if (ctx.wantsJson()) {
        try ctx.writeJson(stats);
    } else {
        try ctx.out.?.print("imported {d} nodes and {d} directed edges from {d} local Valhalla tiles\n", .{ stats.nodes, stats.edges, stats.tiles });
    }
    return 0;
}

fn compareCosting(ctx: *Context) !u8 {
    const parity = routing.cli.parity_costing;
    const minimum = (try unsigned(ctx, u64, "minimum-calls")) orelse parity.minimum_calls;
    var bundle = try routing.graph.reader.Bundle.open(ctx.getArgument(0).?);
    defer bundle.close();
    const reference = try io.Mapping.mapFile(ctx.getArgument(1).?, .read_only);
    defer reference.unmap();
    const app = App.from(ctx);
    const report = try parity.run(ctx.allocator, &bundle.view, reference.bytes, minimum, app.stderr, .none);
    if (ctx.getOption("out")) |destination| {
        const payload = try std.json.Stringify.valueAlloc(ctx.allocator, report, .{ .whitespace = .indent_2 });
        try io.writeFile(destination, payload);
    }
    if (ctx.wantsJson()) {
        try ctx.writeJson(report);
    } else {
        try ctx.out.?.print("costing parity {s}: pedestrian {d} calls and {d} paths, bicycle {d} calls and {d} paths, {d} failures\n", .{
            if (report.passed) "passed" else "failed", report.pedestrian.calls(),     report.pedestrian.recost.samples,
            report.bicycle.calls(),                    report.bicycle.recost.samples, report.pedestrian.failures() + report.bicycle.failures(),
        });
    }
    return if (report.passed) 0 else 1;
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
