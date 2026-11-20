//! Gates A and B for motor costing and timed routing on imported Valhalla tiles.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const graph = routing.graph;
const auto = routing.costing.auto;
const motorcycle = routing.costing.motorcycle;
const truck = routing.costing.truck;
const compiled = routing.costing.compiled;
const parity = routing.cli.parity_costing;
const search = routing.search.search;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const Arena = std.mem.Allocator;
const Movements = std.AutoHashMapUnmanaged(u64, void);
const RouteGate = enum { timed, access };

fn movementKey(incoming: EdgeId, outgoing: EdgeId) u64 {
    return (@as(u64, @backingInt(incoming)) << 32) | @backingInt(outgoing);
}

fn Probe(comptime model: type) type {
    return struct {
        const Self = @This();

        profile: *const model.Profile,
        tables: ?*const compiled.Compiled,
        arena: Arena,
        previous_internal: ?*auto.InternalTurn = null,
        previous_destination_only: ?*bool = null,
        routed: bool = false,
        fixed_movements: ?*const Movements = null,

        pub fn edgeCost(self: Self, view: *const View, _: EdgeId, edge: *const graph.format.EdgeHot, _: search.Direction) !compiled.Cost {
            return (try self.traversal(view, edge, self.profile.untimedSpeed(edge.*))).cost;
        }

        pub fn edgeTraversal(self: Self, view: *const View, _: EdgeId, edge: *const graph.format.EdgeHot, _: search.Direction) !search.Traversal {
            return self.traversal(view, edge, self.profile.untimedSpeed(edge.*));
        }

        pub fn edgeCostAt(self: Self, view: *const View, id: EdgeId, edge: *const graph.format.EdgeHot, _: search.Direction, time: graph.time_info.TimeInfo) !search.Traversal {
            const speed = self.profile.resolvedSpeed(edge.*, id, graph.speed.Time.fromTimeInfo(time), graph.speed.NoOverlays{});
            return self.traversal(view, edge, speed);
        }

        fn traversal(self: Self, view: *const View, edge: *const graph.format.EdgeHot, speed: model.Speed) !search.Traversal {
            const class = try view.class(edge.cls.class_id);
            const cost = if (model == truck and self.tables == null)
                truck.Kernel.rawEdgeCost(self.profile, class, edge.*, speed, .{})
            else
                model.Kernel.edgeCost(self.profile, self.tables.?, class, edge.*, speed, .{});
            return .{ .cost = cost, .measured_speed = @as(u8, @bitCast(speed.sources)) != 0 };
        }

        pub fn restrictionPermission(self: Self) routing.costing.base.Permission {
            return self.profile.permission;
        }

        pub fn timeDependentCosts(self: Self, available: graph.speed.Flow) bool {
            const selected = self.profile.permission.flow;
            return self.profile.fixed_speed == 0 and ((available.freeflow and selected.freeflow) or (available.constrained and selected.constrained));
        }

        pub fn allowedTurn(self: Self, view: *const View, movement: search.Transition, _: search.Label, direction: search.Direction) !bool {
            if (self.fixed_movements) |fixed| {
                if (!fixed.contains(movementKey(movement.incoming, movement.outgoing))) return false;
            }
            if (!self.profile.allowedNode(try view.node(movement.node))) return false;
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const prior = if (direction == .forward) from else to;
            const previous = if (direction == .forward) movement.incoming_access else movement.outgoing_access;
            const check: auto.PathCheck = .{
                .previous_dead_end = prior.flags.dead_end or (try view.outEdgeRange(movement.node)).count() == 1,
                .backtrack = movement.incoming_edge.cls.opp_local == movement.outgoing_edge.cls.local,
                .previous_access = previous,
            };
            const turn: routing.costing.base.Turn = .{ .row = movement.row };
            const access = if (direction == .forward)
                try auto.Kernel.allowed(self.profile, from, to, turn, check, .none)
            else
                try auto.Kernel.allowedReverse(self.profile, from, to, turn, check, .none);
            return access.allowed;
        }

        pub fn turnCost(self: Self, view: *const View, movement: search.Transition, _: search.Label, direction: search.Direction) !compiled.Cost {
            var turn = try model.Turn.read(view, movement.node, movement.incoming, movement.outgoing, self.arena, .none);
            turn.measured_speed = if (self.routed) movement.measured_speed else @as(u8, @bitCast(self.profile.untimedSpeed(movement.incoming_edge.*).sources)) != 0;
            turn.movement.base_turn.previous_destination_only = movement.incoming_access.destination_only;
            turn.movement.base_turn.next_destination_only = movement.outgoing_access.destination_only;
            const from = try view.class(movement.incoming_edge.cls.class_id);
            const to = try view.class(movement.outgoing_edge.cls.class_id);
            const node = try view.node(movement.node);
            if (self.previous_internal) |previous| {
                turn.internal_turn = previous.*;
                previous.* = model.Kernel.internalTurn(node, to, movement.outgoing_edge.*, turn.movement.base_turn);
            }
            if (model == truck) {
                const previous = self.previous_destination_only.?;
                turn.movement.base_turn.previous_destination_only = previous.*;
                previous.* = to.flags.destination_only_hgv;
            }
            return if (direction == .forward) model.Kernel.turnCost(self.profile, node, from, to, turn) else model.Kernel.turnCostReverse(self.profile, node, from, to, turn);
        }
    };
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const samples = args.next() orelse return error.MissingCostingReference;
    const family_or_minimum = args.next();
    const motor_modes: []const parity.Mode = &.{ .auto, .bus, .taxi };
    var min_arg = family_or_minimum;
    var route_gate: ?RouteGate = null;
    const tested: []const parity.Mode = if (family_or_minimum) |value| blk: {
        if (!std.mem.startsWith(u8, value, "--")) break :blk motor_modes;
        min_arg = args.next();
        if (std.mem.eql(u8, value, "--truck")) break :blk &.{.truck};
        if (std.mem.eql(u8, value, "--motorcycle")) break :blk &.{ .motorcycle, .motor_scooter };
        if (std.meta.stringToEnum(RouteGate, value[2..])) |gate| {
            route_gate = gate;
            break :blk &.{.auto};
        }
        if (std.mem.eql(u8, value, "--motor")) break :blk motor_modes;
        return error.InvalidCostingFamily;
    } else motor_modes;
    const minimum: u64 = if (min_arg) |value| try std.fmt.parseInt(u64, value, 10) else if (route_gate != null) 1 else parity.minimum_calls;
    if (args.next() != null) return error.TooManyArguments;
    const files = try io.File.open(samples, .read_only);
    defer files.close();
    const mapped = try io.Mapping.mapFd(files, .read_only);
    defer mapped.unmap();
    var bundle = try graph.reader.Bundle.open(path);
    defer bundle.close();
    const view = &bundle.view;
    var reference = try parity.Reference.init(mapped.bytes);
    const uuid = std.fmt.bytesToHex(view.dataset_uuid, .lower);
    if (!std.mem.eql(u8, reference.uuid, &uuid) or reference.nodes != view.nodes.len or reference.edges.len != view.edges.len)
        return error.CostingReferenceGraphMismatch;
    if (route_gate) |gate| return compareRoutes(init, view, &reference, &uuid, minimum, gate);

    var err_buffer: [4096]u8 = undefined;
    var stderr = io.stderrWriter(init.io, &err_buffer);
    var totals: std.EnumArray(parity.Mode, parity.Counts) = .initFill(.{});
    var raw_only_profiles: usize = 0;
    var profiles: std.ArrayList(parity.ProfileReport) = .empty;
    defer profiles.deinit(init.gpa);
    while (try reference.nextProfile()) |profile| {
        if (std.mem.indexOfScalar(parity.Mode, tested, profile.mode) == null) return error.InvalidReferenceCosting;
        const result = switch (profile.mode) {
            inline .auto, .bus, .taxi => |mode| try checkProfile(auto, init.gpa, view, &reference, profile, @field(auto.Mode, @tagName(mode)), &stderr.interface),
            .truck => try checkProfile(truck, init.gpa, view, &reference, profile, {}, &stderr.interface),
            inline .motorcycle, .motor_scooter => |mode| try checkProfile(motorcycle, init.gpa, view, &reference, profile, @field(motorcycle.Mode, @tagName(mode)), &stderr.interface),
            else => return error.InvalidReferenceCosting,
        };
        totals.getPtr(profile.mode).merge(result.counts);
        raw_only_profiles += @intFromBool(result.raw_only);
        try profiles.append(init.gpa, .{ .mode = profile.mode, .options = profile.options, .scores = result.counts });
    }
    try stderr.interface.flush();
    var passed = true;
    for (tested) |mode| {
        const counts = totals.get(mode);
        passed = passed and counts.calls() >= minimum and counts.recost.samples != 0 and counts.failures() == 0;
    }
    var buffer: [8192]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    try std.json.Stringify.value(.{
        .dataset_uuid = uuid,
        .oracle_version = "3.9.3",
        .call_tolerance = parity.call_limit,
        .path_tolerance = parity.path_limit,
        .minimum_calls_per_mode = minimum,
        .auto = totals.get(.auto),
        .bus = totals.get(.bus),
        .taxi = totals.get(.taxi),
        .truck = totals.get(.truck),
        .motorcycle = totals.get(.motorcycle),
        .motor_scooter = totals.get(.motor_scooter),
        .raw_only_profiles = raw_only_profiles,
        .profiles = profiles.items,
        .passed = passed,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (!passed) return error.CostingParityFailed;
}

const ProfileResult = struct {
    counts: parity.Counts,
    raw_only: bool,
};

fn compareRoutes(init: std.process.Init, view: *const View, reference: *parity.Reference, uuid: []const u8, minimum: u64, gate: RouteGate) !void {
    const api = routing.api.request;
    const multi = routing.search.multi;
    var arena = routing.infra.arena.Arena.init(init.gpa, .{});
    defer arena.deinit();
    var engine = try search.Search(Probe(auto), routing.search.queue.Heap).init(init.gpa, view);
    defer engine.deinit();
    var cases: u64 = 0;
    var passed: u64 = 0;
    var same_as_static: u64 = 0;
    var same_as_oracle: u64 = 0;
    var equal_cost_different_path: u64 = 0;
    var cheaper: u64 = 0;
    var max_excess: f32 = 0;
    var error_buffer: [4096]u8 = undefined;
    var stderr = io.stderrWriter(init.io, &error_buffer);

    while (try reference.nextProfile()) |sample| {
        if (sample.mode != .auto) return error.InvalidReferenceCosting;
        const a = arena.allocator();
        var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
        const settings = try std.json.parseFromSliceLeaky(std.json.Value, a, sample.options, .{});
        const profile = try auto.Model.canonicalize(try auto.parse(a, .auto, settings, &warnings, .none));
        if (warnings.items.len != 0) return error.InvalidReferenceOptions;
        const classes = view.classes orelse return error.MissingClassTable;
        const tables = try compiled.compileInto(auto.Model, profile, classes, try a.alloc(f32, classes.len), .none);
        const probe: Probe(auto) = .{ .profile = &profile, .tables = &tables, .arena = a, .routed = true };
        for (0..sample.paths) |_| {
            const path = try reference.nextPath();
            const mark = arena.mark();
            defer arena.rewind(mark);
            const parsed = try api.parseHttp(a, "/route", &.{}, path.request);
            if (parsed != .ok or parsed.ok.locations.len != 2 or parsed.ok.date_time_type == .current or
                (gate == .timed) != (parsed.ok.date_time_type != .no_time))
                return error.InvalidReferenceRequest;
            const input = parsed.ok;
            const first = path.segments[0];
            const last = path.segments[path.segments.len - 1];
            const origin = referenceCandidate(@fromBackingInt(first.edge), first.begin);
            const destination = referenceCandidate(@fromBackingInt(last.edge), last.end);
            const snapped = [_]routing.snap.candidates.PathLocation{
                .{ .edges = &.{origin}, .filtered_edges = &.{}, .rank_candidates = true },
                .{ .edges = &.{destination}, .filtered_edges = &.{}, .rank_candidates = true },
            };
            const options: multi.Options = .{ .search = .{ .costing = .auto }, .date_time_type = input.date_time_type, .now = 0 };
            const control: search.Control = .{ .deadline = io.Deadline.fromNowMs(20_000) };
            const actual = multi.route(&engine, &arena, probe, input.locations, &snapped, options, control) catch |err| {
                try stderr.interface.print("{s} native search: {s}\n", .{ path.request, @errorName(err) });
                try stderr.interface.flush();
                return err;
            };
            if (gate == .access and actual.retried) return error.UnexpectedAccessRetry;

            var allowed: Movements = .empty;
            for (path.segments[0 .. path.segments.len - 1], path.segments[1..], 0..) |from, to, i| {
                if (i % 256 == 0) try control.check();
                try allowed.put(a, movementKey(@fromBackingInt(from.edge), @fromBackingInt(to.edge)), {});
            }
            var replay = probe;
            replay.fixed_movements = &allowed;
            const oracle_path = multi.route(&engine, &arena, replay, input.locations, &snapped, options, control) catch |err| {
                try stderr.interface.print("{s} replay: {s}\n", .{ path.request, @errorName(err) });
                try stderr.interface.flush();
                return err;
            };
            const replayed = oracle_path.legs[0].segments;
            if (replayed.len != path.segments.len) return error.ReferencePathChanged;
            for (replayed, path.segments) |native, pinned| {
                if (@backingInt(native.edge) != pinned.edge or native.begin != pinned.begin or native.end != pinned.end)
                    return error.ReferencePathChanged;
            }
            cases += 1;
            if (actual.total.cost <= oracle_path.total.cost) {
                passed += 1;
            } else {
                max_excess = @max(max_excess, actual.total.cost - oracle_path.total.cost);
                try stderr.interface.print("{s}: weighted cost {d} exceeds oracle path {d}\n", .{
                    path.request, actual.total.cost, oracle_path.total.cost,
                });
            }
            const actual_segments = actual.legs[0].segments;
            if (gate == .timed) {
                const untimed = try multi.route(&engine, &arena, probe, input.locations, &snapped, .{
                    .search = .{ .costing = .auto, .direction = if (input.date_time_type == .arrive_by) .reverse else .forward },
                }, control);
                if (samePath(actual_segments, untimed.legs[0].segments)) same_as_static += 1;
            } else if (samePath(actual_segments, replayed)) {
                same_as_oracle += 1;
            } else {
                if (actual.total.cost < oracle_path.total.cost) cheaper += 1;
                if (actual.total.cost == oracle_path.total.cost) equal_cost_different_path += 1;
                try stderr.interface.print("{s}: native weighted cost {d}, oracle path {d}\n", .{ path.request, actual.total.cost, oracle_path.total.cost });
                for (actual_segments) |segment| {
                    const class = try view.class((try view.edge(segment.edge)).cls.class_id);
                    try stderr.interface.print(" native edge {d} ({d}..{d}, destination-only {}, not-thru {})\n", .{
                        reference.edges[@backingInt(segment.edge)], segment.begin, segment.end, class.flags.destination_only, class.flags.not_thru,
                    });
                }
                for (path.segments) |segment| {
                    try stderr.interface.print(" oracle edge {d} ({d}..{d})\n", .{ reference.edges[segment.edge], segment.begin, segment.end });
                }
            }
        }
        arena.reset();
    }
    try stderr.interface.flush();
    var buffer: [8192]u8 = undefined;
    var stdout = io.stdoutWriter(init.io, &buffer);
    const success = cases != 0 and cases >= minimum and passed == cases;
    try std.json.Stringify.value(.{
        .dataset_uuid = uuid,
        .oracle_version = "3.9.3",
        .cases = cases,
        .optimal = passed,
        .same_as_static = if (gate == .timed) @as(?u64, same_as_static) else null,
        .same_as_oracle = if (gate == .access) @as(?u64, same_as_oracle) else null,
        .cheaper = if (gate == .access) @as(?u64, cheaper) else null,
        .equal_cost_different_path = if (gate == .access) @as(?u64, equal_cost_different_path) else null,
        .max_excess = max_excess,
        .passed = success,
    }, .{ .emit_null_optional_fields = false }, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (!success) return error.RouteParityFailed;
}

fn samePath(a: []const routing.search.endpoints.Segment, b: []const routing.search.endpoints.Segment) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.meta.eql(left, right)) return false;
    }
    return true;
}

fn referenceCandidate(id: EdgeId, fraction: f32) routing.snap.candidates.PathEdge {
    return .{
        .id = id,
        .percent_along = fraction,
        .projected = .init(0, 0),
        .distance = 0,
        .heading = 0,
        .node = if (fraction == 0) .begin else if (fraction == 1) .end else .none,
    };
}

fn checkProfile(comptime model: type, gpa: Arena, view: *const View, reference: *parity.Reference, sample: parity.Reference.Profile, mode: if (model == truck) void else model.Mode, diagnostics: *io.Writer) !ProfileResult {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, arena, sample.options, .{});
    if (settings != .object) return error.InvalidReferenceOptions;
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const options = if (model == truck) try truck.parse(arena, settings, &warnings, .none) else try model.parse(arena, mode, settings, &warnings, .none);
    if (warnings.items.len != 0) return error.InvalidReferenceOptions;
    const profile = try model.Model.canonicalize(options);
    const classes = view.classes orelse return error.MissingClassTable;
    const factors = try arena.alloc(f32, classes.len);
    const tables: ?compiled.Compiled = compiled.compileInto(model.Model, profile, classes, factors, .none) catch |err| switch (err) {
        error.InvalidClassFactor => if (model == truck) null else return err,
        else => return err,
    };
    const probe: Probe(model) = .{ .profile = &profile, .tables = if (tables) |*table| table else null, .arena = arena };
    var counts: parity.Counts = .{};
    for (sample.calls) |call| {
        const from: EdgeId = @fromBackingInt(call.incoming);
        const to: EdgeId = @fromBackingInt(call.outgoing);
        const incoming = try view.edge(from);
        const outgoing = try view.edge(to);
        const node_id: graph.format.NodeId = @fromBackingInt(incoming.head);
        const node = try view.node(node_id);
        const from_class = try view.class(incoming.cls.class_id);
        const to_class = try view.class(outgoing.cls.class_id);
        var turn = try model.Turn.read(view, node_id, from, to, arena, .none);
        if (model == truck) turn.movement.base_turn.previous_destination_only = from_class.flags.destination_only_hgv;

        const traversal = try probe.edgeCost(view, to, outgoing, .forward);
        const forward = model.Kernel.turnCost(&profile, node, from_class, to_class, turn);
        if (model == truck or model == motorcycle) {
            const opposite = try view.edge(try view.oppEdge(to));
            turn.movement.base_turn.next_destination_only = (try view.class(opposite.cls.class_id)).flags.destination_only;
        }
        const reverse = model.Kernel.turnCostReverse(&profile, node, from_class, to_class, turn);
        if (!try counts.traversal.compare(call.edge, traversal, parity.call_limit) and counts.traversal.failures <= 8)
            try parity.tupleDiagnostic(diagnostics, "edge", sample, reference.*, call, call.edge, traversal);
        if (!try counts.transition.compare(call.turn, forward, parity.call_limit) and counts.transition.failures <= 8)
            try parity.tupleDiagnostic(diagnostics, "turn", sample, reference.*, call, call.turn, forward);
        if (!try counts.reverse_transition.compare(call.reverse_turn, reverse, parity.call_limit) and counts.reverse_transition.failures <= 8)
            try parity.tupleDiagnostic(diagnostics, "reverse_turn", sample, reference.*, call, call.reverse_turn, reverse);
    }
    for (0..sample.paths) |_| {
        const path = try reference.nextPath();
        var recost: routing.search.legs.Recost = .{};
        var internal: auto.InternalTurn = .none;
        var destination_only = false;
        var path_probe = probe;
        path_probe.previous_internal = &internal;
        path_probe.previous_destination_only = &destination_only;
        for (path.segments, 0..) |segment, index| {
            const id: EdgeId = @fromBackingInt(segment.edge);
            _ = recost.add(view, path_probe, .{ .edge = id, .begin = segment.begin, .end = segment.end }, try view.edge(id), false) catch |err| {
                if (err != error.InvalidRouteCost) return err;
                try diagnostics.print("recost {s}: unusable Valhalla directed edge {d} at segment {d} fraction {d}..{d}\n", .{
                    @tagName(sample.mode), reference.edges[@backingInt(id)], index, segment.begin, segment.end,
                });
                recost.elapsed = .forbidden;
                break;
            };
        }
        if (!try counts.recost.compare(path.expected, recost.elapsed, parity.path_limit) and counts.recost.failures <= 8)
            try diagnostics.print("recost {s}: expected {d}/{d}, got {d}/{d}, request {s}\n", .{
                @tagName(sample.mode), path.expected.cost, path.expected.secs, recost.elapsed.cost, recost.elapsed.secs, path.request,
            });
    }
    return .{ .counts = counts, .raw_only = tables == null };
}
