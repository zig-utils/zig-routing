//! Gate A compares native costing calls and fixed-path recosts with Valhalla.
const std = @import("std");
const io = @import("../infra/io.zig");
const graph = @import("../graph/root.zig");
const costing = @import("../costing/root.zig");
const search = @import("../search/search.zig");
const legs = @import("../search/legs.zig");
const Allocator = std.mem.Allocator;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const EdgeHot = graph.format.EdgeHot;
const Cost = costing.compiled.Cost;

pub const call_limit = 1e-5;
pub const path_limit = 1e-4;
pub const minimum_calls = 10_000_000;
const magic = "ZRCOST01";
pub const Mode = enum(u32) { pedestrian, bicycle, auto, bus, taxi, truck, motorcycle, motor_scooter };

const Case = extern struct {
    incoming: u32,
    outgoing: u32,
    edge: Cost,
    turn: Cost,
    reverse_turn: Cost,
};

const Segment = extern struct {
    edge: u32,
    begin: f32,
    end: f32,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Case) == 32 and @offsetOf(Case, "edge") == 8 and @offsetOf(Case, "turn") == 16 and @offsetOf(Case, "reverse_turn") == 24);
    std.debug.assert(@sizeOf(Segment) == 12 and @offsetOf(Segment, "begin") == 4 and @offsetOf(Segment, "end") == 8);
}

const Cursor = struct {
    remaining: []const u8,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (n > self.remaining.len) return error.TruncatedCostingReference;
        const result = self.remaining[0..n];
        self.remaining = self.remaining[n..];
        return result;
    }

    fn value(self: *Cursor, comptime T: type) !T {
        return std.mem.bytesToValue(T, try self.take(@sizeOf(T)));
    }

    fn array(self: *Cursor, comptime T: type, n: usize) ![]align(1) const T {
        const len = std.math.mul(usize, n, @sizeOf(T)) catch return error.TruncatedCostingReference;
        return std.mem.bytesAsSlice(T, try self.take(len));
    }

    fn string(self: *Cursor) ![]const u8 {
        const n = try self.value(u32);
        return self.take(n);
    }
};

pub const Reference = struct {
    cursor: Cursor,
    uuid: []const u8,
    nodes: u32,
    edges: []align(1) const u64,

    pub fn init(bytes: []const u8) !Reference {
        var cursor: Cursor = .{ .remaining = bytes };
        if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) return error.InvalidCostingReference;
        const uuid = try cursor.take(32);
        const nodes = try cursor.value(u32);
        const count = try cursor.value(u32);
        const edges = try cursor.array(u64, count);
        return .{ .cursor = cursor, .uuid = uuid, .nodes = nodes, .edges = edges };
    }

    pub const Profile = struct {
        mode: Mode,
        options: []const u8,
        calls: []align(1) const Case,
        paths: u32,
    };

    pub fn nextProfile(self: *Reference) !?Profile {
        if (self.cursor.remaining.len == 0) return null;
        const mode = std.enums.fromInt(Mode, try self.cursor.value(u32)) orelse return error.InvalidReferenceCosting;
        const calls = try self.cursor.value(u32);
        const paths = try self.cursor.value(u32);
        const options = try self.cursor.string();
        return .{ .mode = mode, .options = options, .calls = try self.cursor.array(Case, calls), .paths = paths };
    }

    pub const Path = struct {
        expected: Cost,
        request: []const u8,
        segments: []align(1) const Segment,
    };

    pub fn nextPath(self: *Reference) !Path {
        const count = try self.cursor.value(u32);
        if (count == 0) return error.InvalidReferencePath;
        const cost = try self.cursor.value(Cost);
        const request = try self.cursor.string();
        return .{ .expected = cost, .request = request, .segments = try self.cursor.array(Segment, count) };
    }
};

pub const Score = struct {
    samples: u64 = 0,
    failures: u64 = 0,
    max_relative_error: f64 = 0,

    pub fn compare(self: *Score, expected: Cost, actual: Cost, tolerance: f64) !bool {
        if (!std.math.isFinite(expected.cost) or !std.math.isFinite(expected.secs)) return error.InvalidReferenceCost;
        const difference = @max(relative(expected.cost, actual.cost), relative(expected.secs, actual.secs));
        self.samples += 1;
        self.max_relative_error = @max(difference, self.max_relative_error);
        if (difference <= tolerance) return true;
        self.failures += 1;
        return false;
    }
};

fn relative(expected: f32, actual: f32) f64 {
    if (expected == actual) return 0;
    if (expected == 0 or !std.math.isFinite(actual)) return std.math.floatMax(f64);
    return @abs(@as(f64, actual) - @as(f64, expected)) / @abs(@as(f64, expected));
}

pub const Counts = struct {
    traversal: Score = .{},
    transition: Score = .{},
    reverse_transition: Score = .{},
    recost: Score = .{},

    pub fn calls(self: Counts) u64 {
        return self.traversal.samples + self.transition.samples + self.reverse_transition.samples;
    }

    pub fn failures(self: Counts) u64 {
        return self.traversal.failures + self.transition.failures + self.reverse_transition.failures + self.recost.failures;
    }

    pub fn merge(self: *Counts, other: Counts) void {
        inline for (.{ "traversal", "transition", "reverse_transition", "recost" }) |name| {
            const destination = &@field(self, name);
            const source = @field(other, name);
            destination.samples += source.samples;
            destination.failures += source.failures;
            destination.max_relative_error = @max(destination.max_relative_error, source.max_relative_error);
        }
    }
};

pub const ProfileReport = struct {
    mode: Mode,
    options: []const u8,
    scores: Counts,
};

pub const Report = struct {
    dataset_uuid: [32]u8,
    oracle_version: []const u8 = "3.9.3",
    call_tolerance: f64 = call_limit,
    path_tolerance: f64 = path_limit,
    minimum_calls_per_mode: u64,
    pedestrian: Counts,
    bicycle: Counts,
    profiles: []const ProfileReport,
    passed: bool,
};

fn Kernel(comptime model: type) type {
    return struct {
        profile: *const model.Profile,
        table: *const costing.compiled.Compiled,

        pub fn edgeCost(self: @This(), view: *const View, _: EdgeId, hot: *const EdgeHot, _: search.Direction) !Cost {
            const class = try view.class(hot.cls.class_id);
            if (model == costing.pedestrian) return model.Kernel.edgeCost(self.profile, self.table, class, hot.*, self.profile.untimedFerrySpeed(hot.*), .{});
            return model.Kernel.edgeCost(self.profile, self.table, class, hot.*, .{});
        }

        pub fn turnCost(self: @This(), view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !Cost {
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const node = try view.node(movement.node);
            const turn = try model.Turn.read(view, movement.node, movement.incoming, movement.outgoing);
            return model.Kernel.turnCost(self.profile, node, from, to, turn);
        }
    };
}

pub fn run(a: Allocator, bundle: *const View, bytes: []const u8, min_calls: u64, diagnostics: *io.Writer, deadline: io.Deadline) !Report {
    var reference = try Reference.init(bytes);
    const uuid = std.fmt.bytesToHex(bundle.dataset_uuid, .lower);
    if (!std.mem.eql(u8, reference.uuid, &uuid) or reference.nodes != bundle.nodes.len or reference.edges.len != bundle.edges.len) return error.CostingReferenceGraphMismatch;
    var reports: std.ArrayList(ProfileReport) = .empty;
    var pedestrian: Counts = .{};
    var bicycle: Counts = .{};
    while (try reference.nextProfile()) |profile| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const scores = switch (profile.mode) {
            .pedestrian => try checkProfile(costing.pedestrian, a, bundle, &reference, profile, diagnostics, deadline),
            .bicycle => try checkProfile(costing.bicycle, a, bundle, &reference, profile, diagnostics, deadline),
            else => return error.InvalidReferenceCosting,
        };
        try reports.append(a, .{ .mode = profile.mode, .options = profile.options, .scores = scores });
        switch (profile.mode) {
            .pedestrian => pedestrian.merge(scores),
            .bicycle => bicycle.merge(scores),
            else => unreachable,
        }
    }
    return .{
        .dataset_uuid = uuid,
        .minimum_calls_per_mode = min_calls,
        .pedestrian = pedestrian,
        .bicycle = bicycle,
        .profiles = reports.items,
        .passed = pedestrian.calls() >= min_calls and bicycle.calls() >= min_calls and
            pedestrian.recost.samples != 0 and bicycle.recost.samples != 0 and pedestrian.failures() == 0 and bicycle.failures() == 0,
    };
}

fn checkProfile(comptime model: type, gpa: Allocator, view: *const View, reference: *Reference, profile: Reference.Profile, diagnostics: *io.Writer, deadline: io.Deadline) !Counts {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, a, profile.options, .{});
    if (settings != .object) return error.InvalidReferenceOptions;
    var warnings: std.ArrayList(costing.base.Warning) = .empty;
    const config = try model.parse(a, settings, &warnings, deadline);
    if (warnings.items.len != 0) return error.InvalidReferenceOptions;
    var cache = try model.Cache.init(a, view.classes orelse return error.MissingClassTable, 1);
    defer cache.deinit();
    var lease = try cache.acquire(config, deadline);
    defer lease.release();
    const kernel: Kernel(model) = .{ .profile = lease.profile(), .table = lease.tables() };
    var counts: Counts = .{};
    for (profile.calls, 0..) |sample, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const from: EdgeId = @fromBackingInt(sample.incoming);
        const to: EdgeId = @fromBackingInt(sample.outgoing);
        const incoming = try view.edge(from);
        const outgoing = try view.edge(to);
        const node: graph.format.NodeId = @fromBackingInt(incoming.head);
        const range = try view.outEdgeRange(node);
        const row = try view.turnRow(node, incoming.cls.opp_local);
        if (outgoing.cls.local >= row.len or range.first + outgoing.cls.local != sample.outgoing) return error.InvalidReferenceTurn;
        const movement: search.Transition = .{
            .node = node,
            .incoming = from,
            .incoming_edge = incoming,
            .outgoing = to,
            .outgoing_edge = outgoing,
            .row = row[outgoing.cls.local],
        };
        const previous: search.Label = .{ .edge = sample.incoming };
        const traversal = try kernel.edgeCost(view, to, outgoing, .forward);
        const forward = try kernel.turnCost(view, movement, previous, .forward);
        const reverse = try kernel.turnCost(view, movement, previous, .reverse);
        if (!try counts.traversal.compare(sample.edge, traversal, call_limit)) try tupleDiagnostic(diagnostics, "edge", profile, reference.*, sample, sample.edge, traversal);
        if (!try counts.transition.compare(sample.turn, forward, call_limit)) try tupleDiagnostic(diagnostics, "turn", profile, reference.*, sample, sample.turn, forward);
        if (!try counts.reverse_transition.compare(sample.reverse_turn, reverse, call_limit)) try tupleDiagnostic(diagnostics, "reverse_turn", profile, reference.*, sample, sample.reverse_turn, reverse);
    }
    for (0..profile.paths) |_| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const path = try reference.nextPath();
        var recost: legs.Recost = .{};
        for (path.segments, 0..) |segment, j| {
            if (j % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const edge: EdgeId = @fromBackingInt(segment.edge);
            _ = recost.add(view, kernel, .{ .edge = edge, .begin = segment.begin, .end = segment.end }, try view.edge(edge), false) catch |err| {
                if (err != error.InvalidRouteCost) return err;
                recost.elapsed = .forbidden;
                break;
            };
        }
        if (!try counts.recost.compare(path.expected, recost.elapsed, path_limit)) {
            try diagnostics.print("recost {s}: expected {d}/{d}, got {d}/{d}, request {s}\n", .{
                @tagName(profile.mode), path.expected.cost, path.expected.secs, recost.elapsed.cost, recost.elapsed.secs, path.request,
            });
        }
    }
    return counts;
}

pub fn tupleDiagnostic(out: *io.Writer, name: []const u8, profile: Reference.Profile, ref: Reference, sample: Case, expected: Cost, actual: Cost) !void {
    try out.print("{s} {s}: expected {d}/{d}, got {d}/{d}, native {d}->{d}, Valhalla {d}->{d}, options {s}\n", .{
        @tagName(profile.mode),     name,                       expected.cost,   expected.secs, actual.cost, actual.secs, sample.incoming, sample.outgoing,
        ref.edges[sample.incoming], ref.edges[sample.outgoing], profile.options,
    });
}
