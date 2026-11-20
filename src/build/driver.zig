// Ported from src/mjolnir/util.cc and valhalla/mjolnir/util.h (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const graph = @import("../graph/root.zig");
const hgt = @import("../elevation/hgt.zig");
const checkpoint = @import("checkpoint.zig");
const assemble = @import("assemble.zig");
const admin_index = @import("admin_index.zig");
const speeds = @import("speeds.zig");
const edges = @import("edges.zig");
const node_store = @import("node_store.zig");
const usage = @import("node_store/usage.zig");
const pbf = @import("pbf/root.zig");
const Allocator = std.mem.Allocator;

pub const Stage = checkpoint.Stage;
pub const default_pbf_buffer_bytes = 512 * 1024 * 1024;

pub const Options = struct {
    inputs: []const []const u8 = &.{},
    output: ?[]const u8 = null,
    work_dir: []const u8,
    dem_dir: ?[]const u8 = null,
    default_speeds_config: ?[]const u8 = null,
    timezone_geojson: ?[]const u8 = null,
    timezone_rules: ?[]const u8 = null,
    infer_turn_channels: ?bool = null,
    infer_internal_intersections: ?bool = null,
    apply_country_overrides: ?bool = null,
    drive_side: ?@import("edge_class.zig").DriveSide = null,
    order: ?graph.format.OrderingKind = null,
    workers: usize = 0,
    pbf_buffer_bytes: usize = default_pbf_buffer_bytes,
    from: Stage = .read,
    to: Stage = .finalize,
    deadline: io.Deadline = .none,
};

pub const Diagnostic = struct {
    stage: ?Stage = null,
    input: ?[]const u8 = null,
};

pub const Result = struct {
    dataset_uuid: graph.format.DatasetUuid,
    finalized: bool,
    stages: []const checkpoint.Metric,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.stages);
    }
};

const Source = struct {
    path: []const u8,
    digest: checkpoint.Fingerprint,
};

const TimezoneInputs = struct {
    boundaries: Source,
    rules: Source,
};

const Inputs = struct {
    sources: []const Source,
    dem_dir: ?[]const u8,
    dem_digest: ?[32]u8 = null,
    speed_digest: ?[32]u8 = null,
    timezones: ?TimezoneInputs = null,
    infer_turn_channels: bool = true,
    infer_internal_intersections: bool = true,
    apply_country_overrides: bool = true,
    drive_side: @import("edge_class.zig").DriveSide,
    order: graph.format.OrderingKind,

    fn identity(self: Inputs) graph.format.DatasetUuid {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zr-build-v1");
        hash.update(&.{ @intFromBool(self.dem_dir != null), @backingInt(self.drive_side) });
        hash.update(@tagName(self.order));
        if (self.dem_digest) |digest| {
            hash.update("dem-bytes-v1");
            hash.update(&digest);
        } else if (self.dem_dir) |path| {
            // Resumes of checkpoints from before DEM fingerprints keep
            // their original dataset identity.
            hash.update(path);
            hash.update(&.{0});
        }
        if (self.speed_digest) |digest| {
            hash.update("default-speed-config");
            hash.update(&digest);
        }
        if (self.timezones) |input| {
            hash.update("timezone-inputs");
            hash.update(std.mem.asBytes(&input.boundaries.digest));
            hash.update(std.mem.asBytes(&input.rules.digest));
        }
        if (!self.infer_turn_channels) hash.update("turn-channels-off");
        if (!self.infer_internal_intersections) hash.update("internal-intersections-off");
        if (!self.apply_country_overrides) hash.update("country-overrides-off");
        for (self.sources) |source| {
            hash.update(std.mem.asBytes(&source.digest.bytes));
            hash.update(std.mem.asBytes(&source.digest.xxh3));
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var id = digest[0..16].*;
        id[6] = (id[6] & 15) | 0x80;
        id[8] = (id[8] & 63) | 0x80;
        return id;
    }
};

/// Run an inclusive stage interval. Completed checkpoints contain immutable
/// inputs for the next stage. A work directory belongs to one build identity.
pub fn run(gpa: Allocator, options: Options, progress: ?*io.Writer, diagnostic: *Diagnostic) !Result {
    if (@backingInt(options.from) > @backingInt(options.to)) return error.InvalidStageRange;
    if (options.to == .finalize and options.output == null) return error.MissingBundlePath;
    const root = try openWork(options.work_dir);
    defer root.close();
    root.lockExclusive() catch |err| return if (err == error.WouldBlock) error.BuildWorkDirectoryBusy else err;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const read_timer = io.Timer.start();
    diagnostic.stage = if (options.from == .read) .read else options.from;
    const previous = if (options.from != .read) try checkpoint.Existing.open(gpa, root, .read, null) else null;
    defer if (previous) |saved| saved.close();
    var inputs: Inputs = if (previous) |saved| blk: {
        const decoded = try saved.readJson(Inputs, a, .inputs, options.deadline);
        break :blk decoded.value;
    } else .{
        .sources = try fingerprintInputs(a, options, diagnostic),
        .dem_dir = options.dem_dir,
        .timezones = try timezoneInputs(options, diagnostic),
        .infer_turn_channels = options.infer_turn_channels orelse true,
        .infer_internal_intersections = options.infer_internal_intersections orelse true,
        .apply_country_overrides = options.apply_country_overrides orelse true,
        .drive_side = options.drive_side orelse .right,
        .order = options.order orelse .hilbert,
    };
    if (previous != null) try checkOptions(a, &inputs, options, diagnostic);
    var speed_mapping: ?io.Mapping = null;
    defer if (speed_mapping) |mapping| mapping.unmap();
    var speed_input = if (options.default_speeds_config) |path| try openDefaultSpeeds(a, path, options.deadline) else null;
    defer if (speed_input) |*input| input.rules.deinit(a);
    if (previous) |saved| {
        if (options.default_speeds_config != null and !std.meta.eql(inputs.speed_digest, speedDigest(speed_input)))
            return error.CheckpointInputMismatch;
        if (speed_input == null and inputs.speed_digest != null) {
            speed_mapping = try saved.map(.default_speeds, options.deadline);
            const bytes = speed_mapping.?.bytes;
            speed_input = .{ .bytes = bytes, .rules = try speeds.Config.parse(a, bytes, options.deadline) };
            if (!std.meta.eql(inputs.speed_digest, speedDigest(speed_input))) return error.CheckpointChecksumMismatch;
        }
    } else {
        inputs.speed_digest = speedDigest(speed_input);
    }
    var tiles: ?hgt.Tiles = null;
    defer if (tiles) |*catalog| catalog.deinit();
    const stamps_elevation = @backingInt(options.from) <= @backingInt(Stage.elevation) and
        @backingInt(options.to) >= @backingInt(Stage.elevation);
    if (inputs.dem_dir) |path| {
        if (previous == null or stamps_elevation or (options.dem_dir != null and inputs.dem_digest != null)) {
            diagnostic.input = path;
            tiles = try hgt.Tiles.initBuild(gpa, path, options.deadline);
            if (previous == null or inputs.dem_digest != null) {
                const digest = try tiles.?.fingerprint(options.deadline);
                if (inputs.dem_digest) |expected| {
                    if (!std.mem.eql(u8, &digest, &expected)) return error.CheckpointInputMismatch;
                }
                inputs.dem_digest = digest;
            }
            diagnostic.input = null;
        }
    }
    const id = inputs.identity();
    var session: checkpoint.Session = .{
        .gpa = gpa,
        .root = root,
        .path = options.work_dir,
        .from = options.from,
        .to = options.to,
        .identity = id,
        .deadline = options.deadline,
        .progress = progress,
        .current = &diagnostic.stage,
    };
    defer session.metrics.deinit(gpa);
    for (std.enums.values(Stage)) |stage| {
        if (@backingInt(stage) >= @backingInt(options.from)) break;
        try session.readPrior(stage);
    }
    var timezone_mappings: ?TimezoneMappings = null;
    defer if (timezone_mappings) |mapped| mapped.close();
    if (session.runs(.cold)) {
        if (inputs.timezones) |input| timezone_mappings = try TimezoneMappings.open(input, options.deadline, diagnostic);
    }
    const graph_options: assemble.Options = .{
        .scratch_dir = options.work_dir,
        .workers = options.workers,
        .deadline = options.deadline,
        .drive_side = inputs.drive_side,
        .ordering = .{ .kind = inputs.order },
        .dem_source = if (tiles) |*catalog| .{ .catalog = catalog } else null,
        .speed_rules = if (speed_input) |*input| &input.rules else null,
        .infer_turn_channels = inputs.infer_turn_channels,
        .infer_internal_intersections = inputs.infer_internal_intersections,
        .apply_country_overrides = inputs.apply_country_overrides,
        .timezone_source = if (timezone_mappings) |mapped| .{ .boundaries = mapped.boundaries.bytes, .rules = mapped.rules.bytes } else null,
    };
    if (session.runs(.read)) {
        var tx = try session.begin(.read);
        defer tx.deinit();
        try tx.writeJson(gpa, inputs, .inputs);
        if (speed_input) |input| try tx.write(.default_speeds, input.bytes);
        try session.commit(&tx, inputs.sources.len, read_timer);
    }
    if (@backingInt(options.to) >= @backingInt(Stage.tags) and @backingInt(options.from) <= @backingInt(Stage.spatial)) {
        var metadata = assemble.Metadata.init(gpa, graph_options);
        defer metadata.deinit();
        if (@backingInt(options.from) <= @backingInt(Stage.edges)) {
            try buildSegments(&session, &metadata, inputs, graph_options, options.pbf_buffer_bytes, diagnostic);
        }
        if (@backingInt(options.to) >= @backingInt(Stage.order)) {
            const prior = try session.open(.edges);
            defer prior.close();
            const source_stats = try prior.readJson(edges.Stats, gpa, .source_stats, options.deadline);
            defer source_stats.deinit();
            if (@backingInt(options.from) > @backingInt(Stage.edges)) {
                try metadata.loadWays(prior);
                if (session.runs(.order)) {
                    const nodes = try session.open(.node_store);
                    defer nodes.close();
                    try metadata.loadNodes(nodes);
                }
            }
            const edge_file = try prior.read(.segments, options.deadline);
            defer edge_file.close();
            const shape_file = try prior.read(.shape_points, options.deadline);
            defer shape_file.close();
            const tagged = try session.open(.tags);
            defer tagged.close();
            var admin_mapping: ?io.Mapping = null;
            defer if (admin_mapping) |mapped| mapped.unmap();
            var assembly_options = graph_options;
            if (tagged.manifest.files.get(.admin_index) != null) {
                admin_mapping = try tagged.map(.admin_index, options.deadline);
                assembly_options.admin_index = try graph.admin.View.parse(admin_mapping.?.bytes);
            }
            try assemble.buildStaged(&session, &metadata, source_stats.value, edge_file, shape_file, assembly_options);
        }
    }
    if (session.runs(.validate)) try validate(&session);
    if (session.runs(.finalize)) try finalize(&session, options.output.?);
    diagnostic.* = .{};
    const stages = try session.metrics.toOwnedSlice(gpa);
    errdefer gpa.free(stages);
    const result: Result = .{ .dataset_uuid = id, .finalized = session.runs(.finalize), .stages = stages };
    const report = try std.json.Stringify.valueAlloc(a, result, .{ .whitespace = .indent_2 });
    try root.writeAtomic("build-stats.json", report);
    return result;
}

const SpeedInput = struct {
    bytes: []const u8,
    rules: speeds.Config,
};

fn speedDigest(input: ?SpeedInput) ?[32]u8 {
    const present = input orelse return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(present.bytes, &digest, .{});
    return digest;
}

fn openDefaultSpeeds(a: Allocator, path: []const u8, deadline: io.Deadline) !?SpeedInput {
    if (deadline.expired()) return error.DeadlineExceeded;
    const bytes = io.readFileAlloc(a, path, 16 * 1024 * 1024) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.log.warn("default speed configuration disabled ({s})", .{@errorName(err)});
        return null;
    };
    const rules = speeds.Config.parse(a, bytes, deadline) catch |err| {
        if (err == error.OutOfMemory or err == error.DeadlineExceeded) return err;
        std.log.warn("default speed configuration disabled ({s})", .{@errorName(err)});
        return null;
    };
    return .{ .bytes = bytes, .rules = rules };
}

fn fingerprintInputs(a: Allocator, options: Options, diagnostic: *Diagnostic) ![]const Source {
    if (options.inputs.len == 0) return error.MissingOsmInput;
    const rows = try a.alloc(Source, options.inputs.len);
    for (options.inputs, rows) |path, *row| {
        diagnostic.input = path;
        const file = try io.File.open(path, .read_only);
        defer file.close();
        const stream = try pbf.file.Stream.init(file);
        try stream.validateHeader(a, options.deadline);
        row.* = .{ .path = path, .digest = try checkpoint.Fingerprint.read(file, options.deadline) };
    }
    diagnostic.input = null;
    return rows;
}

fn timezoneInputs(options: Options, diagnostic: *Diagnostic) !?TimezoneInputs {
    const paths = options.timezone_geojson orelse {
        if (options.timezone_rules != null) return error.MissingTimezoneBoundaries;
        return null;
    };
    const rules = options.timezone_rules orelse return error.MissingTimezoneRules;
    return .{
        .boundaries = try fingerprintFile(paths, options.deadline, diagnostic),
        .rules = try fingerprintFile(rules, options.deadline, diagnostic),
    };
}

fn fingerprintFile(path: []const u8, deadline: io.Deadline, diagnostic: *Diagnostic) !Source {
    diagnostic.input = path;
    const file = try io.File.open(path, .read_only);
    defer file.close();
    const digest = try checkpoint.Fingerprint.read(file, deadline);
    diagnostic.input = null;
    return .{ .path = path, .digest = digest };
}

const TimezoneMappings = struct {
    boundaries: io.Mapping,
    rules: io.Mapping,

    fn open(input: TimezoneInputs, deadline: io.Deadline, diagnostic: *Diagnostic) !TimezoneMappings {
        const boundaries = try mapSource(input.boundaries, deadline, diagnostic);
        errdefer boundaries.unmap();
        return .{ .boundaries = boundaries, .rules = try mapSource(input.rules, deadline, diagnostic) };
    }

    fn close(self: TimezoneMappings) void {
        self.rules.unmap();
        self.boundaries.unmap();
    }

    fn mapSource(input: Source, deadline: io.Deadline, diagnostic: *Diagnostic) !io.Mapping {
        diagnostic.input = input.path;
        const file = try io.File.open(input.path, .read_only);
        defer file.close();
        if (!std.meta.eql(input.digest, try checkpoint.Fingerprint.read(file, deadline)))
            return error.CheckpointInputMismatch;
        const mapping = try io.Mapping.mapFd(file, .read_only);
        diagnostic.input = null;
        return mapping;
    }
};

fn checkOptions(a: Allocator, inputs: *Inputs, options: Options, diagnostic: *Diagnostic) !void {
    if (options.drive_side) |side| if (side != inputs.drive_side) return error.CheckpointInputMismatch;
    if (options.order) |order| if (order != inputs.order) return error.CheckpointInputMismatch;
    if (options.infer_turn_channels) |infer| if (infer != inputs.infer_turn_channels) return error.CheckpointInputMismatch;
    if (options.infer_internal_intersections) |infer| if (infer != inputs.infer_internal_intersections) return error.CheckpointInputMismatch;
    if (options.apply_country_overrides) |apply| if (apply != inputs.apply_country_overrides) return error.CheckpointInputMismatch;
    if (options.timezone_geojson) |path| {
        const expected = if (inputs.timezones) |input| input.boundaries else return error.CheckpointInputMismatch;
        const actual = try fingerprintFile(path, options.deadline, diagnostic);
        if (!std.meta.eql(expected.digest, actual.digest)) return error.CheckpointInputMismatch;
        inputs.timezones.?.boundaries = actual;
    }
    if (options.timezone_rules) |path| {
        const expected = if (inputs.timezones) |input| input.rules else return error.CheckpointInputMismatch;
        const actual = try fingerprintFile(path, options.deadline, diagnostic);
        if (!std.meta.eql(expected.digest, actual.digest)) return error.CheckpointInputMismatch;
        inputs.timezones.?.rules = actual;
    }
    if (options.dem_dir) |dir| {
        const saved = inputs.dem_dir orelse return error.CheckpointInputMismatch;
        if (inputs.dem_digest == null and !std.mem.eql(u8, dir, saved)) return error.CheckpointInputMismatch;
        inputs.dem_dir = dir;
    }
    if (options.inputs.len != 0) {
        const current = try fingerprintInputs(a, options, diagnostic);
        if (current.len != inputs.sources.len) return error.CheckpointInputMismatch;
        for (current, inputs.sources) |present, expected| {
            if (!std.meta.eql(present.digest, expected.digest)) return error.CheckpointInputMismatch;
        }
        inputs.sources = current;
    }
}

fn buildSegments(session: *checkpoint.Session, metadata: *assemble.Metadata, inputs: Inputs, graph_options: assemble.Options, pbf_buffer_bytes: usize, diagnostic: *Diagnostic) !void {
    const gpa = session.gpa;
    const deadline = session.deadline;
    const indexed_at = io.Timer.start();
    const streams = try gpa.alloc(pbf.file.File, inputs.sources.len);
    defer gpa.free(streams);
    var opened: usize = 0;
    defer for (streams[0..opened]) |*stream| stream.close();
    for (inputs.sources, streams) |input, *stream| {
        diagnostic.input = input.path;
        const file = try io.File.open(input.path, .read_only);
        defer file.close();
        if (!std.meta.eql(input.digest, try checkpoint.Fingerprint.read(file, deadline))) return error.CheckpointInputMismatch;
        stream.* = try pbf.file.File.openFd(gpa, file, deadline);
        opened += 1;
    }
    diagnostic.input = null;
    const source: pbf.file.IndexedStreams = .{
        .files = streams,
        .decode = .{ .workers = graph_options.workers, .buffer_bytes = pbf_buffer_bytes },
    };
    const options: edges.Options = .{ .scratch_dir = session.path, .workers = graph_options.workers, .deadline = deadline };
    var prep = try edges.Preparation.init(gpa, options, true);
    defer prep.deinit();

    var referenced: ?usage.Usage = null;
    defer if (referenced) |*store| store.deinit();
    if (session.runs(.tags)) {
        const start = indexed_at;
        var tx = try session.begin(.tags);
        defer tx.deinit();
        referenced = try usage.Usage.init(session.path);
        try prep.selectWays(source, &referenced.?);
        try prep.saveTags(&tx);
        try edges.saveUsage(&tx, &referenced.?, .usage_directory, .usage_leaves);
        if (try admin_index.build(gpa, source, deadline)) |compiled| {
            var index = compiled;
            defer index.deinit();
            try admin_index.save(index.view, &tx);
        }
        try session.commit(&tx, prep.selected_ways, start);
    } else {
        const tags = try session.open(.tags);
        defer tags.close();
        try prep.loadTags(tags);
        if (session.runs(.node_store)) {
            try prep.loadCuts(tags);
            referenced = try edges.loadUsage(tags, session.path, .usage_directory, .usage_leaves, deadline);
        }
    }
    if (session.endsAt(.tags)) return;

    if (session.runs(.node_store)) {
        const start = if (session.from == .node_store) indexed_at else io.Timer.start();
        var tx = try session.begin(.node_store);
        defer tx.deinit();
        const node_file = try tx.create(.node_index);
        defer node_file.close();
        const store = try prep.collectNodes(source, &referenced.?, node_file, metadata, assemble.Metadata.node);
        try node_file.sync();
        try prep.saveNodes(&tx);
        try metadata.saveNodes(&tx);
        try session.commit(&tx, store.nodeCount(), start);
    } else {
        const nodes = try session.open(.node_store);
        defer nodes.close();
        try prep.loadCuts(nodes);
        try prep.loadNodes(nodes);
        try metadata.loadNodes(nodes);
    }
    if (session.endsAt(.node_store)) return;

    if (session.runs(.edges)) {
        const start = if (session.from == .edges) indexed_at else io.Timer.start();
        var tx = try session.begin(.edges);
        defer tx.deinit();
        const saved = try session.open(.node_store);
        defer saved.close();
        const node_file = try saved.read(.node_index, deadline);
        defer node_file.close();
        const store = try node_store.Store.open(node_file);
        const edge_file = try tx.create(.segments);
        defer edge_file.close();
        const shape_file = try tx.create(.shape_points);
        defer shape_file.close();
        // Edge batches already use the worker pool. Decode inline between
        // batches so the two phases do not start competing worker pools.
        var edge_source = source;
        edge_source.decode.workers = 1;
        const stats = try edges.generate(gpa, edge_source, .{ .edges = edge_file, .shapes = shape_file }, options, &prep, store, metadata, assemble.Metadata.way, assemble.Metadata.culdesac);
        try edge_file.sync();
        try shape_file.sync();
        try metadata.saveWays(&tx);
        try tx.writeJson(gpa, stats, .source_stats);
        try session.commit(&tx, stats.edges, start);
    }
}

fn validate(session: *checkpoint.Session) !void {
    const start = io.Timer.start();
    var tx = try session.begin(.validate);
    defer tx.deinit();
    var writer = try assemble.stageWriter(session.*, tx);
    defer writer.deinit();
    for ([_]Stage{ .cold, .spatial }) |stage| {
        const saved = try session.open(stage);
        defer saved.close();
        try saved.copySections(&writer);
    }
    const path = try std.fs.path.join(session.gpa, &.{ session.path, &tx.name, &writer.temp_name });
    defer session.gpa.free(path);
    var bundle = try graph.reader.Bundle.open(path);
    defer bundle.close();
    try bundle.view.verify(session.deadline, null);
    try assemble.validate(bundle.view.first_edge, bundle.view.edges, bundle.view.coordinates.?, bundle.view.classes.?, session.deadline);
    try tx.saveSections(&writer);
    try session.commit(&tx, bundle.view.edges.len, start);
}

fn finalize(session: *checkpoint.Session, output: []const u8) !void {
    const start = io.Timer.start();
    var tx = try session.begin(.finalize);
    defer tx.deinit();
    const saved = try session.open(.validate);
    defer saved.close();
    const existing = io.Directory.open(output) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |dir| {
        defer dir.close();
        if (!try saved.matchesBundle(dir, session.deadline)) return error.PathAlreadyExists;
    } else {
        var writer = try graph.format.BundleWriter.init(output, session.identity, session.deadline);
        defer writer.deinit();
        try saved.copySections(&writer);
        try writer.commit();
    }
    tx.output_bytes = saved.manifest.metric.bytes;
    try session.commit(&tx, saved.manifest.metric.rows, start);
}

fn openWork(path: []const u8) !io.Directory {
    return io.Directory.open(path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const parent = try io.Directory.open(std.fs.path.dirname(path) orelse ".");
            defer parent.close();
            const name = std.fs.path.basename(path);
            var buf: [std.fs.max_name_bytes + 1]u8 = undefined;
            if (name.len >= buf.len) return error.InvalidArgument;
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const terminated = buf[0..name.len :0];
            break :blk parent.createChild(terminated) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => try parent.child(terminated),
                else => return create_err,
            };
        },
        else => return err,
    };
}
