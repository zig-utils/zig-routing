//! Immutable build-stage artifacts and atomic publication of checkpoints.
const std = @import("std");
const io = @import("../infra/io.zig");
const Allocator = std.mem.Allocator;
const format = @import("../graph/format.zig");

pub const Stage = enum {
    read,
    tags,
    node_store,
    edges,
    order,
    assemble,
    enhance,
    elevation,
    turns,
    cold,
    spatial,
    validate,
    finalize,

    pub fn folder(self: Stage) [:0]const u8 {
        return switch (self) {
            inline else => |stage| ".zr-build-" ++ @tagName(stage),
        };
    }
};

pub const Metric = struct {
    stage: Stage,
    elapsed_ns: u64,
    rows: u64,
    bytes: u64,
    peak_rss_bytes: u64,
    rows_per_second: f64,
};

pub const Fingerprint = struct {
    bytes: u64,
    xxh3: u64,

    pub fn read(file: io.File, deadline: io.Deadline) !Fingerprint {
        return transfer(file, null, deadline);
    }
};

pub fn transfer(file: io.File, output: ?io.File, deadline: io.Deadline) !Fingerprint {
    var buffer: [128 * 1024]u8 = undefined;
    var digest = std.hash.XxHash3.init(0);
    const size = try file.size();
    var offset: u64 = 0;
    while (offset < size) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const n: usize = @intCast(@min(size - offset, buffer.len));
        const chunk = buffer[0..n];
        try file.preadAll(chunk, offset);
        if (output) |target| try target.pwriteAll(chunk, offset);
        digest.update(chunk);
        offset += n;
    }
    if (output) |target| try target.truncate(size);
    return .{ .bytes = size, .xxh3 = digest.final() };
}

pub const Artifact = enum {
    inputs,
    usage_directory,
    usage_leaves,
    cuts_directory,
    cuts_leaves,
    loops,
    loop_refs,
    source_stats,
    node_index,
    node_attributes,
    controls,
    segments,
    shape_points,
    way_attributes,
    names,
    name_refs,
    levels,
    logical_nodes,
    layout_stats,
    placements,
    slot_refs,
    groups,
    coordinates,
    first_edge,
    nodes,
    directed_edges,
    classes,
    means,
    slopes,
    terrain_stats,
    turn_pool,
    turn_stats,
    spatial_stats,
    bundle_nodes,
    bundle_edges,
    bundle_first_edge,
    bundle_turns,
    bundle_classes,
    bundle_coordinates,
    bundle_cold_idx,
    bundle_cold,
    bundle_slopes,
    bundle_spatial,
    bundle_metadata,
    bundle_components,
    turn_sides,
    bundle_turn_sides,
    bundle_coverage,
    default_speeds,
    motor_limits,
    admin_index,
    bundle_admins,
    bundle_node_admins,
    bundle_node_timezones,
    bundle_timezone_rules,
    simple_turn_relations,
    simple_turn_stats,
    mode_turns,
    bundle_turn_restrictions,
    bundle_restriction_automaton,
    complex_turn_relations,
    restriction_via_ways,
    restriction_states,
    restriction_conditions,
    bundle_restriction_conditions,
    simple_turn_domains,

    fn filename(self: Artifact) [:0]const u8 {
        return switch (self) {
            inline else => |key| @tagName(key) ++ ".bin",
        };
    }

    pub fn section(kind: format.SectionKind) Artifact {
        return switch (kind) {
            inline else => |key| @field(Artifact, "bundle_" ++ @tagName(key)),
        };
    }
};

pub const Manifest = struct {
    version: u32 = 1,
    identity: format.DatasetUuid,
    parent: ?u64,
    metric: Metric,
    files: std.EnumArray(Artifact, ?Fingerprint),

    const Disk = struct {
        version: u32,
        identity: format.DatasetUuid,
        parent: ?u64,
        metric: Metric,
        files: struct { values: []const ?Fingerprint },
    };

    pub fn parse(allocator: Allocator, bytes: []const u8) !Manifest {
        if (bytes.len > manifest_limit) return error.InvalidCheckpoint;
        const decoded = try std.json.parseFromSlice(Disk, allocator, bytes, .{});
        defer decoded.deinit();
        const stored = decoded.value;
        if (stored.version != 1 or !std.math.isFinite(stored.metric.rows_per_second) or stored.metric.rows_per_second < 0)
            return error.InvalidCheckpoint;
        var manifest: Manifest = .{
            .identity = stored.identity,
            .parent = stored.parent,
            .metric = stored.metric,
            .files = .initFill(null),
        };
        if (stored.files.values.len > manifest.files.values.len) return error.InvalidCheckpoint;
        @memcpy(manifest.files.values[0..stored.files.values.len], stored.files.values);
        return manifest;
    }

    fn encode(self: *const Manifest, allocator: Allocator) ![]u8 {
        var end = self.files.values.len;
        while (end != 0 and self.files.values[end - 1] == null) end -= 1;
        const disk: Disk = .{
            .version = self.version,
            .identity = self.identity,
            .parent = self.parent,
            .metric = self.metric,
            .files = .{ .values = self.files.values[0..end] },
        };
        return std.json.Stringify.valueAlloc(allocator, disk, .{});
    }

    fn digest(self: *const Manifest) u64 {
        var hash = std.hash.XxHash3.init(0);
        hash.update(&self.identity);
        hash.update(@tagName(self.metric.stage));
        if (self.parent) |parent| hash.update(std.mem.asBytes(&parent));
        for (std.enums.values(Artifact)) |artifact| {
            if (self.files.get(artifact)) |fingerprint| {
                hash.update(artifact.filename());
                hash.update(std.mem.asBytes(&fingerprint.bytes));
                hash.update(std.mem.asBytes(&fingerprint.xxh3));
            }
        }
        return hash.final();
    }
};
const manifest_name = "manifest.json";
const manifest_limit = 32 * 1024;

pub const Existing = struct {
    dir: io.Directory,
    manifest: Manifest,

    pub fn open(gpa: Allocator, root: io.Directory, stage: Stage, identity: ?format.DatasetUuid) !Existing {
        const dir = try root.child(stage.folder());
        errdefer dir.close();
        const file = try dir.readFile(manifest_name);
        defer file.close();
        const size = try file.size();
        if (size > manifest_limit) return error.InvalidCheckpoint;
        const bytes = try gpa.alloc(u8, @intCast(size));
        defer gpa.free(bytes);
        try file.preadAll(bytes, 0);
        const manifest = try Manifest.parse(gpa, bytes);
        if (manifest.metric.stage != stage) return error.InvalidCheckpoint;
        if (identity) |expected| {
            if (!std.mem.eql(u8, &manifest.identity, &expected)) return error.CheckpointInputMismatch;
        }
        return .{ .dir = dir, .manifest = manifest };
    }

    pub fn close(self: Existing) void {
        self.dir.close();
    }

    pub fn read(self: Existing, key: Artifact, deadline: io.Deadline) !io.File {
        const expected = self.manifest.files.get(key) orelse return error.MissingCheckpointArtifact;
        const file = try self.dir.readFile(key.filename());
        errdefer file.close();
        if (!std.meta.eql(expected, try Fingerprint.read(file, deadline))) return error.CheckpointChecksumMismatch;
        return file;
    }

    /// A repeated finalize may keep an already published, identical bundle.
    pub fn matchesBundle(self: Existing, dir: io.Directory, deadline: io.Deadline) !bool {
        for (std.enums.values(format.SectionKind)) |kind| {
            const expected = self.manifest.files.get(Artifact.section(kind));
            const file = dir.readFile(kind.filename()) catch |err| switch (err) {
                error.FileNotFound => {
                    if (expected != null) return false;
                    continue;
                },
                else => return err,
            };
            defer file.close();
            if (!std.meta.eql(expected orelse return false, try Fingerprint.read(file, deadline))) return false;
        }
        return true;
    }

    pub fn copySections(self: Existing, writer: *format.BundleWriter) !void {
        for (std.enums.values(format.SectionKind)) |kind| {
            const key = Artifact.section(kind);
            if (self.manifest.files.get(key) != null) {
                const file = try self.read(key, writer.deadline);
                defer file.close();
                try writer.copySection(kind, file);
            }
        }
    }

    pub fn readJson(self: Existing, comptime T: type, allocator: Allocator, key: Artifact, deadline: io.Deadline) !std.json.Parsed(T) {
        const mapping = try self.map(key, deadline);
        defer mapping.unmap();
        return std.json.parseFromSlice(T, allocator, mapping.bytes, .{ .allocate = .alloc_always });
    }

    pub fn map(self: Existing, key: Artifact, deadline: io.Deadline) !io.Mapping {
        const file = try self.read(key, deadline);
        defer file.close();
        return io.Mapping.mapFd(file, .read_only);
    }
};

pub fn array(comptime T: type, mapping: io.Mapping) ![]const T {
    if (mapping.bytes.len % @sizeOf(T) != 0) return error.InvalidCheckpoint;
    return mapping.slice(T, 0, mapping.bytes.len / @sizeOf(T));
}

pub const Session = struct {
    gpa: Allocator,
    root: io.Directory,
    path: []const u8,
    from: Stage,
    to: Stage,
    identity: format.DatasetUuid,
    deadline: io.Deadline,
    metrics: std.ArrayList(Metric) = .empty,
    progress: ?*io.Writer = null,
    current: *?Stage,
    previous: ?u64 = null,

    pub fn runs(self: Session, stage: Stage) bool {
        return @backingInt(self.from) <= @backingInt(stage) and @backingInt(stage) <= @backingInt(self.to);
    }

    pub fn endsAt(self: Session, stage: Stage) bool {
        return self.to == stage;
    }

    pub fn begin(self: Session, stage: Stage) !Transaction {
        self.current.* = stage;
        if (self.progress) |writer| {
            try writer.print("building {s}\n", .{@tagName(stage)});
            try writer.flush();
        }
        var tx = try Transaction.begin(self.root, stage, self.identity, self.deadline);
        tx.parent = self.previous;
        return tx;
    }

    pub fn open(self: Session, stage: Stage) !Existing {
        return Existing.open(self.gpa, self.root, stage, self.identity);
    }

    pub fn readPrior(self: *Session, stage: Stage) !void {
        self.current.* = stage;
        const saved = self.open(stage) catch |err| switch (err) {
            error.FileNotFound => return error.MissingCheckpoint,
            else => return err,
        };
        defer saved.close();
        if (saved.manifest.parent != self.previous) return error.StaleCheckpoint;
        self.previous = saved.manifest.digest();
        try self.metrics.append(self.gpa, saved.manifest.metric);
    }

    pub fn commit(self: *Session, tx: *Transaction, rows: u64, started: io.Timer) !void {
        const manifest = try tx.commit(self.gpa, rows, started);
        self.previous = manifest.digest();
        const metric = manifest.metric;
        try self.metrics.append(self.gpa, metric);
        if (self.progress) |writer| {
            try writer.print("{s}  {d:.3}s  {d} rows  {d:.0} rows/s  {d} bytes  peak RSS {d} bytes\n", .{
                @tagName(metric.stage), @as(f64, @floatFromInt(metric.elapsed_ns)) / std.time.ns_per_s,
                metric.rows,            metric.rows_per_second,
                metric.bytes,           metric.peak_rss_bytes,
            });
            try writer.flush();
        }
    }
};

pub const Transaction = struct {
    root: io.Directory,
    dir: io.Directory,
    name: io.Directory.TempName,
    stage: Stage,
    identity: format.DatasetUuid,
    deadline: io.Deadline,
    parent: ?u64 = null,
    output_bytes: u64 = 0,
    present: std.EnumSet(Artifact) = .empty,
    published: bool = false,

    pub fn begin(root: io.Directory, stage: Stage, identity: format.DatasetUuid, deadline: io.Deadline) !Transaction {
        const staging = try root.temporaryChild();
        return .{ .root = root, .dir = staging.dir, .name = staging.name, .stage = stage, .identity = identity, .deadline = deadline };
    }

    pub fn deinit(self: Transaction) void {
        self.dir.close();
        if (!self.published) remove(self.root, &self.name);
    }

    pub fn create(self: *Transaction, key: Artifact) !io.File {
        const output = try self.dir.createFile(key.filename());
        self.present.insert(key);
        return output;
    }

    pub fn stash(self: *Transaction, key: Artifact, source: io.File) !void {
        const output = try self.create(key);
        defer output.close();
        _ = try transfer(source, output, self.deadline);
        try output.sync();
    }

    pub fn write(self: *Transaction, key: Artifact, bytes: []const u8) !void {
        const file = try self.create(key);
        defer file.close();
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const n = @min(bytes.len - offset, 128 * 1024);
            try file.pwriteAll(bytes[offset..][0..n], offset);
            offset += n;
        }
        try file.sync();
    }

    pub fn saveSections(self: *Transaction, writer: *const format.BundleWriter) !void {
        var kinds = writer.written.iterator();
        while (kinds.next()) |kind| {
            const file = try writer.staging.readFile(kind.filename());
            defer file.close();
            try self.stash(Artifact.section(kind), file);
        }
    }

    pub fn writeArray(self: *Transaction, records: anytype, key: Artifact) !void {
        try self.write(key, std.mem.sliceAsBytes(records));
    }

    pub fn writeJson(self: *Transaction, allocator: Allocator, value: anytype, key: Artifact) !void {
        const data = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(data);
        try self.write(key, data);
    }

    pub fn commit(self: *Transaction, gpa: Allocator, rows: u64, started: io.Timer) !Manifest {
        var manifest: Manifest = .{
            .identity = self.identity,
            .parent = self.parent,
            .metric = .{
                .stage = self.stage,
                .elapsed_ns = 0,
                .rows = rows,
                .bytes = self.output_bytes,
                .peak_rss_bytes = try io.peakRssBytes(),
                .rows_per_second = 0,
            },
            .files = .initFill(null),
        };
        var keys = self.present.iterator();
        while (keys.next()) |key| {
            const file = try self.dir.readFile(key.filename());
            defer file.close();
            const digest = try Fingerprint.read(file, self.deadline);
            manifest.files.set(key, digest);
            manifest.metric.bytes = std.math.add(u64, manifest.metric.bytes, digest.bytes) catch return error.CheckpointTooLarge;
        }
        manifest.metric.elapsed_ns = started.read();
        manifest.metric.rows_per_second = @as(f64, @floatFromInt(rows)) * std.time.ns_per_s /
            @as(f64, @floatFromInt(@max(manifest.metric.elapsed_ns, 1)));
        const bytes = try manifest.encode(gpa);
        defer gpa.free(bytes);
        const file = try self.dir.createFile(manifest_name);
        defer file.close();
        try file.pwriteAll(bytes, 0);
        try file.sync();
        try self.dir.sync();
        if (self.deadline.expired()) return error.DeadlineExceeded;
        const prior = Existing.open(gpa, self.root, self.stage, self.identity) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (prior) |old| {
            old.close();
            try self.root.exchange(&self.name, self.stage.folder());
            remove(self.root, &self.name);
        } else {
            try self.root.renameExclusive(&self.name, self.stage.folder());
        }
        self.published = true;
        try self.root.sync();
        return manifest;
    }
};

fn remove(root: io.Directory, name: [:0]const u8) void {
    const dir = root.child(name) catch return;
    defer dir.close();
    for (std.enums.values(Artifact)) |key| dir.deleteFile(key.filename()) catch {};
    dir.deleteFile(manifest_name) catch {};
    root.deleteDir(name) catch {};
}

test "a failed stage leaves its previous record intact and a successful retry replaces it" {
    const testing = std.testing;
    const root = try io.Directory.open(".");
    defer root.close();
    const temp = try root.temporaryChild();
    defer root.deleteDir(&temp.name) catch {};
    defer temp.dir.close();
    defer remove(temp.dir, Stage.read.folder());
    const id: format.DatasetUuid = @splat(1);
    {
        var committed = try Transaction.begin(temp.dir, .read, id, .none);
        defer committed.deinit();
        try committed.write(.inputs, "first");
        const manifest = try committed.commit(testing.allocator, 1, .start());
        try testing.expectEqual(5, manifest.metric.bytes);
    }
    {
        const abandoned = try Transaction.begin(temp.dir, .read, id, .none);
        defer abandoned.deinit();
    }
    {
        const prior = try Existing.open(testing.allocator, temp.dir, .read, id);
        defer prior.close();
        const file = try prior.map(.inputs, .none);
        defer file.unmap();
        try testing.expectEqualStrings("first", file.bytes);
    }
    {
        var replacement = try Transaction.begin(temp.dir, .read, id, .none);
        defer replacement.deinit();
        try replacement.write(.inputs, "second");
        _ = try replacement.commit(testing.allocator, 1, .start());
    }
    const updated = try Existing.open(testing.allocator, temp.dir, .read, id);
    defer updated.close();
    const file = try updated.map(.inputs, .none);
    defer file.unmap();
    try testing.expectEqualStrings("second", file.bytes);
    try testing.expectError(error.CheckpointInputMismatch, Existing.open(testing.allocator, temp.dir, .read, @splat(2)));
}
