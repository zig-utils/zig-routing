//! Gate A for the motor costing models on imported Valhalla tiles.
const std = @import("std");
const routing = @import("routing");
const io = routing.infra.io;
const graph = routing.graph;
const auto = routing.costing.auto;
const compiled = routing.costing.compiled;
const parity = routing.cli.parity_costing;
const search = routing.search.search;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;
const Arena = std.mem.Allocator;

const Probe = struct {
    profile: *const auto.Profile,
    tables: *const compiled.Compiled,
    arena: Arena,
    previous_internal: ?*auto.InternalTurn = null,

    pub fn edgeCost(self: Probe, view: *const View, _: EdgeId, edge: *const graph.format.EdgeHot, _: search.Direction) !compiled.Cost {
        const class = try view.class(edge.cls.class_id);
        return auto.Kernel.edgeCost(self.profile, self.tables, class, edge.*, self.profile.untimedSpeed(edge.*), .{});
    }

    pub fn turnCost(self: Probe, view: *const View, movement: search.Transition, _: search.Label, _: search.Direction) !compiled.Cost {
        var turn = try auto.Turn.read(view, movement.node, movement.incoming, movement.outgoing, self.arena, .none);
        turn.measured_speed = @as(u8, @bitCast(self.profile.untimedSpeed(movement.incoming_edge.*).sources)) != 0;
        const from = try view.class(movement.incoming_edge.cls.class_id);
        const to = try view.class(movement.outgoing_edge.cls.class_id);
        const node = try view.node(movement.node);
        if (self.previous_internal) |previous| {
            turn.internal_turn = previous.*;
            previous.* = auto.Kernel.internalTurn(node, to, movement.outgoing_edge.*, turn.movement.base_turn);
        }
        return auto.Kernel.turnCost(self.profile, node, from, to, turn);
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse return error.MissingBundle;
    const samples = args.next() orelse return error.MissingCostingReference;
    const minimum = if (args.next()) |value| try std.fmt.parseInt(u64, value, 10) else parity.minimum_calls;
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

    var err_buffer: [4096]u8 = undefined;
    var stderr = io.stderrWriter(init.io, &err_buffer);
    var totals: std.EnumArray(auto.Mode, parity.Counts) = .initFill(.{});
    var profiles: std.ArrayList(parity.ProfileReport) = .empty;
    defer profiles.deinit(init.gpa);
    while (try reference.nextProfile()) |profile| {
        const mode: auto.Mode = switch (profile.mode) {
            .auto => .auto,
            .bus => .bus,
            .taxi => .taxi,
            else => return error.InvalidReferenceCosting,
        };
        const counts = try checkProfile(init.gpa, view, &reference, profile, mode, &stderr.interface);
        totals.getPtr(mode).merge(counts);
        try profiles.append(init.gpa, .{ .mode = profile.mode, .options = profile.options, .scores = counts });
    }
    try stderr.interface.flush();
    var passed = true;
    for (totals.values) |counts| {
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
        .profiles = profiles.items,
        .passed = passed,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    if (!passed) return error.CostingParityFailed;
}

fn checkProfile(gpa: Arena, view: *const View, reference: *parity.Reference, sample: parity.Reference.Profile, mode: auto.Mode, diagnostics: *io.Writer) !parity.Counts {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, arena, sample.options, .{});
    if (settings != .object) return error.InvalidReferenceOptions;
    var warnings: std.ArrayList(routing.costing.base.Warning) = .empty;
    const options = try auto.parse(arena, mode, settings, &warnings, .none);
    if (warnings.items.len != 0) return error.InvalidReferenceOptions;
    const profile = try auto.Model.canonicalize(options);
    const classes = view.classes orelse return error.MissingClassTable;
    const tables = try compiled.compileInto(auto.Model, profile, classes, try arena.alloc(f32, classes.len), .none);
    const probe: Probe = .{ .profile = &profile, .tables = &tables, .arena = arena };
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
        const turn = try auto.Turn.read(view, node_id, from, to, arena, .none);

        const traversal = try probe.edgeCost(view, to, outgoing, .forward);
        const forward = auto.Kernel.turnCost(&profile, node, from_class, to_class, turn);
        const reverse = auto.Kernel.turnCostReverse(&profile, node, from_class, to_class, turn);
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
        var path_probe = probe;
        path_probe.previous_internal = &internal;
        for (path.segments) |segment| {
            const id: EdgeId = @fromBackingInt(segment.edge);
            _ = recost.add(view, path_probe, .{ .edge = id, .begin = segment.begin, .end = segment.end }, try view.edge(id), false) catch |err| {
                if (err != error.InvalidRouteCost) return err;
                recost.elapsed = .forbidden;
                break;
            };
        }
        if (!try counts.recost.compare(path.expected, recost.elapsed, parity.path_limit) and counts.recost.failures <= 8)
            try diagnostics.print("recost {s}: expected {d}/{d}, got {d}/{d}, request {s}\n", .{
                @tagName(sample.mode), path.expected.cost, path.expected.secs, recost.elapsed.cost, recost.elapsed.secs, path.request,
            });
    }
    return counts;
}
