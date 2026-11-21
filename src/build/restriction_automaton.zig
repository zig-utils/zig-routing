//! Compile both directions of the forbidden edge sequences into a sparse trie.
const std = @import("std");
const io = @import("../infra/io.zig");
const machine = @import("../graph/restriction_automaton.zig");
const State = machine.State;
const Condition = machine.Condition;
const Allocator = std.mem.Allocator;

pub const Program = struct {
    states: []State = &.{},
    conditions: []Condition = &.{},

    pub fn deinit(self: Program, a: Allocator) void {
        a.free(self.states);
        a.free(self.conditions);
    }
};

pub const Builder = struct {
    a: Allocator,
    deadline: io.Deadline,
    nodes: std.ArrayList(State) = .empty,
    transitions: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    conditions: std.ArrayList(Condition) = .empty,

    pub fn deinit(self: *Builder) void {
        self.nodes.deinit(self.a);
        self.transitions.deinit(self.a);
        self.conditions.deinit(self.a);
    }

    pub fn forbid(self: *Builder, edges: []const u32, modes: u16) !void {
        return self.forbidWhen(edges, modes, 0);
    }

    pub fn forbidWhen(self: *Builder, edges: []const u32, modes: u16, domain: u64) !void {
        return self.forbidIf(edges, modes, .{ .domain = domain });
    }

    pub fn forbidIf(self: *Builder, edges: []const u32, modes: u16, predicate: machine.Predicate) !void {
        if (edges.len < 2 or edges.len > machine.max_edges or modes & 0xf800 != 0 or predicate.probability > 100)
            return error.InvalidRestrictionSequence;
        if (modes == 0) return;
        if (self.nodes.items.len == 0) try self.nodes.appendSlice(self.a, &.{
            State.root(machine.forward_root), State.root(machine.reverse_root),
        });
        try self.insert(false, edges, modes, predicate);
        try self.insert(true, edges, modes, predicate);
    }

    noinline fn insert(self: *Builder, reverse: bool, edges: []const u32, modes: u16, predicate: machine.Predicate) !void {
        const root = if (reverse) machine.reverse_root else machine.forward_root;
        var parent = root;
        for (0..edges.len) |i| {
            const edge = edges[if (reverse) edges.len - 1 - i else i];
            const key = (@as(u64, parent) << 32) | edge;
            const entry = try self.transitions.getOrPut(self.a, key);
            if (!entry.found_existing) {
                errdefer _ = self.transitions.remove(key);
                const index = std.math.cast(u32, self.nodes.items.len) orelse return error.TooManyRestrictionStates;
                if (index == std.math.maxInt(u32)) return error.TooManyRestrictionStates;
                try self.nodes.append(self.a, .{
                    .edge = edge,
                    .failure = root,
                    .attr = .{ .depth = @intCast(i + 1), .reverse = reverse },
                });
                entry.value_ptr.* = index;
            }
            parent = entry.value_ptr.*;
        }
        if (predicate.domain == 0 and predicate.probability == 0) {
            self.nodes.items[parent].attr.forbidden |= modes;
        } else {
            try self.conditions.append(self.a, .{
                .state = parent,
                .attr = .{ .modes = modes, .probability = predicate.probability },
                .domain = predicate.domain,
            });
            if (predicate.domain == 0) {
                self.nodes.items[parent].attr.probable = true;
            } else {
                self.nodes.items[parent].attr.timed = true;
            }
        }
    }

    const Link = struct {
        key: u64,
        child: u32,

        fn before(_: void, lhs: Link, rhs: Link) bool {
            return lhs.key < rhs.key;
        }
    };

    pub noinline fn finish(self: *Builder, edge_count: usize) !Program {
        const nodes = self.nodes.items;
        if (nodes.len == 0) return .{};
        const a = self.a;
        const links = try a.alloc(Link, self.transitions.count());
        defer a.free(links);
        var it = self.transitions.iterator();
        for (links, 0..) |*link, i| {
            try self.check(i);
            const entry = it.next().?;
            link.* = .{ .key = entry.key_ptr.*, .child = entry.value_ptr.* };
        }
        std.sort.heap(Link, links, {}, Link.before);
        for (links, 0..) |link, i| {
            try self.check(i);
            const parent = &nodes[link.key >> 32];
            if (parent.end == 0) parent.first = @intCast(i);
            parent.end = @intCast(i + 1);
        }

        const order = try a.alloc(u32, nodes.len);
        defer a.free(order);
        const result = try a.alloc(State, nodes.len);
        errdefer a.free(result);
        order[0..machine.first_context].* = .{ machine.forward_root, machine.reverse_root };
        var end: u32 = machine.first_context;
        for (result, 0..) |*state, i| {
            try self.check(i);
            const node = nodes[order[i]];
            state.* = node;
            state.first = end;
            for (links[node.first..node.end], node.first..) |link, j| {
                try self.check(j);
                order[end] = link.child;
                end += 1;
            }
            state.end = end;
        }
        for (result, 0..) |state, i| {
            try self.check(i);
            if (i < machine.first_context) continue;
            for (result[state.first..state.end], state.first..) |*child, j| {
                try self.check(j);
                const fallback = machine.advance(result, state.failure, child.edge);
                child.failure = fallback;
                child.attr.forbidden |= result[fallback].attr.forbidden;
                child.attr.timed = child.attr.timed or result[fallback].attr.timed;
                child.attr.probable = child.attr.probable or result[fallback].attr.probable;
            }
        }
        try machine.verify(result, edge_count, self.deadline);
        const conditions = try self.finishConditions(order);
        errdefer a.free(conditions);
        try machine.verifyConditions(result, conditions, self.deadline);
        return .{ .states = result, .conditions = conditions };
    }

    noinline fn finishConditions(self: *const Builder, order: []const u32) ![]Condition {
        if (self.conditions.items.len == 0) return &.{};
        const a = self.a;
        const ids = try a.alloc(u32, order.len);
        defer a.free(ids);
        for (order, 0..) |original, state| {
            try self.check(state);
            ids[original] = @intCast(state);
        }
        const sorted = try a.dupe(Condition, self.conditions.items);
        errdefer a.free(sorted);
        for (sorted, 0..) |*row, i| {
            try self.check(i);
            row.state = ids[row.state];
        }
        std.sort.heap(Condition, sorted, {}, Condition.before);
        var count: usize = 0;
        for (sorted, 0..) |row, i| {
            try self.check(i);
            if (count != 0 and !Condition.before({}, sorted[count - 1], row)) {
                sorted[count - 1].attr.modes |= row.attr.modes;
            } else {
                sorted[count] = row;
                count += 1;
            }
        }
        return a.realloc(sorted, count);
    }

    fn check(self: Builder, index: usize) !void {
        if (index % 1024 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
    }
};

test "complex restriction automata inherit overlapping suffixes in both directions" {
    const t = std.testing;
    var builder: Builder = .{ .a = t.allocator, .deadline = .none };
    defer builder.deinit();
    try builder.forbid(&.{ 0, 1, 2, 3 }, 1);
    try builder.forbid(&.{ 1, 2, 3 }, 2);
    try builder.forbid(&.{ 0, 1, 2 }, 4);
    try builder.forbidWhen(&.{ 1, 2, 3 }, 8, 23622321788);
    try builder.forbidWhen(&.{ 1, 2, 3 }, 16, 23622321788);
    const program = try builder.finish(4);
    defer program.deinit(t.allocator);
    const states = program.states;
    var forward = machine.forward_root;
    for ([_]u32{ 0, 1, 2 }) |edge| forward = machine.advance(states, forward, edge);
    try t.expectEqual(4, states[forward].attr.forbidden);
    forward = machine.advance(states, forward, 3);
    try t.expectEqual(3, states[forward].attr.forbidden);
    const local = @import("../graph/datetime.zig").Local.parse("2026-11-16T09:00").?;
    try t.expect(try machine.blocksTimed(states, program.conditions, forward, 8, 0, local, .none));
    try t.expectEqual(2, program.conditions.len);
    try t.expectEqual(24, program.conditions[0].attr.modes);
    var reverse = machine.reverse_root;
    for ([_]u32{ 3, 2, 1 }) |edge| reverse = machine.advance(states, reverse, edge);
    try t.expectEqual(2, states[reverse].attr.forbidden);
    try t.expect(try machine.blocksTimed(states, program.conditions, reverse, 16, 0, local, .none));
    reverse = machine.advance(states, reverse, 0);
    try t.expectEqual(5, states[reverse].attr.forbidden);
}
