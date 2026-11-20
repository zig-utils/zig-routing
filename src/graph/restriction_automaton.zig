//! Complex restrictions over physical directed edge IDs.
const std = @import("std");
const io = @import("../infra/io.zig");
const datetime = @import("datetime.zig");
const TimeDomain = @import("time_domain.zig").TimeDomain;

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
        timed: bool = false,
        reserved: u8 = 0,
    } = .{},

    pub fn root(id: u32) State {
        return .{ .edge = std.math.maxInt(u32), .failure = id, .attr = .{ .reverse = id == reverse_root } };
    }
};

pub const Condition = extern struct {
    state: u32,
    attr: packed struct(u32) { modes: u16, reserved: u16 = 0 },
    domain: u64,

    pub fn before(_: void, left: Condition, right: Condition) bool {
        if (left.state != right.state) return left.state < right.state;
        return left.domain < right.domain;
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

pub noinline fn blocksTimed(states: []const State, conditions: []const Condition, context: u32, modes: u16, local: datetime.Local, deadline: io.Deadline) !bool {
    var state = context;
    while (states[state].attr.timed) : (state = states[state].failure) {
        var low: usize = 0;
        var high = conditions.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (conditions[mid].state < state) low = mid + 1 else high = mid;
        }
        while (low < conditions.len and conditions[low].state == state) : (low += 1) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const term = conditions[low];
            if (term.attr.modes & modes == 0) continue;
            const domain: TimeDomain = @bitCast(term.domain);
            if (domain.active(local)) return true;
        }
    }
    return false;
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

pub fn verifyConditions(states: []const State, conditions: []const Condition, deadline: io.Deadline) !void {
    var index: usize = 0;
    for (states, 0..) |state, id| {
        if (id % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const inherited = id >= first_context and states[state.failure].attr.timed;
        const start = index;
        var previous: u64 = 0;
        while (index < conditions.len and conditions[index].state == id) : (index += 1) {
            if (index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const condition = conditions[index];
            const domain: TimeDomain = @bitCast(condition.domain);
            if (state.attr.depth < 2 or condition.attr.modes == 0 or condition.attr.modes & 0xf800 != 0 or
                condition.attr.reserved != 0 or condition.domain <= previous or !domain.valid())
                return error.InvalidRestrictionConditions;
            previous = condition.domain;
        }
        if (state.attr.timed != (inherited or index != start)) return error.InvalidRestrictionConditions;
    }
    if (index != conditions.len) return error.InvalidRestrictionConditions;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(State) == 20 and @offsetOf(State, "edge") == 0 and
        @offsetOf(State, "first") == 4 and @offsetOf(State, "end") == 8 and
        @offsetOf(State, "failure") == 12 and @offsetOf(State, "attr") == 16);
    std.debug.assert(@sizeOf(Condition) == 16 and @offsetOf(Condition, "attr") == 4 and @offsetOf(Condition, "domain") == 8);
}
