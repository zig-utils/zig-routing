//! Untimed complex restrictions over physical directed edge IDs.
const std = @import("std");
const io = @import("../infra/io.zig");

pub const forward_root: u32 = 0;
pub const reverse_root: u32 = 1;
pub const first_context: u32 = 2;
pub const max_edges = 33;

/// Children occupy a contiguous run in edge-ID order. A failure link drops
/// the oldest part of a matched prefix until a shorter suffix can continue.
pub const State = extern struct {
    edge: u32,
    first: u32 = 0,
    end: u32 = 0,
    failure: u32,
    attr: packed struct(u32) {
        forbidden: u16 = 0,
        depth: u6 = 0,
        reverse: bool = false,
        reserved: u9 = 0,
    } = .{},

    pub fn root(id: u32) State {
        return .{ .edge = std.math.maxInt(u32), .failure = id, .attr = .{ .reverse = id == reverse_root } };
    }
};

pub fn child(states: []const State, parent: u32, edge: u32) ?u32 {
    const range = states[parent];
    var low = range.first;
    var high = range.end;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const key = states[mid].edge;
        if (edge == key) return mid;
        if (edge < key) high = mid else low = mid + 1;
    }
    return null;
}

pub fn advance(states: []const State, context: u32, edge: u32) u32 {
    var state = context;
    while (true) {
        if (child(states, state, edge)) |next| return next;
        if (state < first_context) return state;
        state = states[state].failure;
    }
}

pub fn verify(states: []const State, edges: usize, deadline: io.Deadline) !void {
    if (states.len <= first_context or states.len > std.math.maxInt(u32) or
        edges + states.len - first_context > std.math.maxInt(u32)) return error.InvalidRestrictionAutomaton;
    var end: u32 = first_context;
    for (states, 0..) |state, index| {
        if (index % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (state.first != end or state.end < end or state.end > states.len or
            state.attr.reserved != 0 or state.attr.forbidden & 0xf800 != 0)
            return error.InvalidRestrictionAutomaton;
        if (index < first_context) {
            const expected = State.root(@intCast(index));
            if (state.edge != expected.edge or state.failure != index or
                @as(u32, @bitCast(state.attr)) != @as(u32, @bitCast(expected.attr)))
                return error.InvalidRestrictionAutomaton;
        } else {
            if (state.edge >= edges or state.failure >= index or state.attr.depth == 0 or
                state.attr.depth > max_edges or (state.attr.depth == 1 and state.attr.forbidden != 0))
                return error.InvalidRestrictionAutomaton;
            const fallback = states[state.failure];
            if (fallback.attr.depth >= state.attr.depth or fallback.attr.reverse != state.attr.reverse or
                (state.failure >= first_context and fallback.edge != state.edge)) return error.InvalidRestrictionAutomaton;
        }
        var previous: ?u32 = null;
        for (states[state.first..state.end], state.first..) |descendant, i| {
            if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (i <= index or descendant.attr.depth != @as(u7, state.attr.depth) + 1 or
                descendant.attr.reverse != state.attr.reverse or (previous != null and descendant.edge <= previous.?))
                return error.InvalidRestrictionAutomaton;
            previous = descendant.edge;
        }
        end = state.end;
    }
    if (end != states.len) return error.InvalidRestrictionAutomaton;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(State) == 20 and @offsetOf(State, "edge") == 0 and
        @offsetOf(State, "first") == 4 and @offsetOf(State, "end") == 8 and
        @offsetOf(State, "failure") == 12 and @offsetOf(State, "attr") == 16);
}
