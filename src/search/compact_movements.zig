//! Immutable movement operands derived from a validated graph view.
const std = @import("std");
const graph = @import("../graph/root.zig");
const memory = @import("../infra/arena.zig");
const motor = @import("../costing/motor.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const View = graph.reader.View;
const EdgeId = graph.format.EdgeId;

pub fn hasLayout(comptime Observer: type) bool {
    if (Observer == void) return false;
    const T = if (@typeInfo(Observer) == .pointer) @typeInfo(Observer).pointer.child else Observer;
    return @hasDecl(T, "movementLayout") and @TypeOf(T.movementLayout) != void;
}

pub const Movement = packed struct(u32) {
    row: graph.format.TurnEntry,
    sides: graph.turn_sides.Sides,
    prohibited_modes: u12,
    degrees: u9,
    more_than_two_roads: bool,

    pub fn motorTurn(self: Movement) motor.Turn {
        return .{
            .movement = .{ .base_turn = .{ .row = self.row }, .sides = self.sides },
            .degrees = self.degrees,
            .more_than_two_roads = self.more_than_two_roads,
        };
    }
};

pub const Layout = struct {
    view: *const View,
    opposite: []const EdgeId,
    node_offsets: []const u32,
    movements: []const Movement,

    pub fn init(a: std.mem.Allocator, view: *const View, deadline: Deadline) !Layout {
        if (deadline.expired()) return error.Cancelled;
        const opposite = try a.alloc(EdgeId, view.edges.len);
        errdefer a.free(opposite);
        const headings = try a.alloc(u16, view.edges.len);
        defer a.free(headings);
        var scratch = memory.Arena.init(a, .{});
        defer scratch.deinit();
        for (view.edges, opposite, headings, 0..) |*edge, *other, *heading, i| {
            if (i % 256 == 0 and deadline.expired()) return error.Cancelled;
            other.* = try view.opposingId(edge);
            heading.* = graph.headings.decode(try motor.Turn.encodedHeading(view, @fromBackingInt(@as(u32, @intCast(i))), scratch.allocator(), deadline));
            scratch.reset();
        }
        // The bundle deduplicates turn rows by their byte values. Heading,
        // side and restriction operands belong to the physical junction.
        const node_offsets = try a.alloc(u32, view.nodes.len);
        errdefer a.free(node_offsets);
        var movement_count: u32 = 0;
        for (node_offsets, 0..) |*offset, i| {
            if (i % 256 == 0 and deadline.expired()) return error.Cancelled;
            const degree = (try view.outEdgeRange(@fromBackingInt(@as(u32, @intCast(i))))).count();
            offset.* = movement_count;
            movement_count = try std.math.add(u32, movement_count, degree * degree);
        }
        const movements = try a.alloc(Movement, movement_count);
        errdefer a.free(movements);
        for (view.nodes, 0..) |*node, i| {
            if (i % 256 == 0 and deadline.expired()) return error.Cancelled;
            const node_id: graph.format.NodeId = @fromBackingInt(@as(u32, @intCast(i)));
            const exits = try view.outEdgeRange(node_id);
            const degree = exits.count();
            if (degree == 0) continue;
            const many_roads = degree > 2 or (try view.class(view.edges[exits.end - 1].cls.class_id)).flags.node_connector;
            for (0..degree) |from| {
                const row = try view.turnRowAt(node, degree, @intCast(from));
                const approach = (headings[exits.first + from] + 180) % 360;
                for (row, 0..) |entry, to| {
                    const outgoing: EdgeId = @fromBackingInt(@as(u32, @intCast(exits.first + to)));
                    const modes = if (node.attr.has_turn_restrictions)
                        view.turnRestrictionModes(opposite[exits.first + from], outgoing)
                    else
                        0;
                    movements[@as(usize, node_offsets[i]) + from * degree + to] = .{
                        .row = entry,
                        .sides = try view.turnSidesAtDegree(node_id, degree, @intCast(from), @intCast(to)),
                        .prohibited_modes = @intCast(modes),
                        .degrees = @intCast((headings[exits.first + to] + 360 - approach) % 360),
                        .more_than_two_roads = many_roads,
                    };
                }
            }
        }
        return .{ .view = view, .opposite = opposite, .node_offsets = node_offsets, .movements = movements };
    }

    pub fn deinit(self: Layout, a: std.mem.Allocator) void {
        a.free(self.movements);
        a.free(self.node_offsets);
        a.free(self.opposite);
    }

    pub fn residentBytes(self: Layout) usize {
        return self.opposite.len * @sizeOf(EdgeId) + self.node_offsets.len * @sizeOf(u32) +
            self.movements.len * @sizeOf(Movement);
    }

    pub inline fn get(self: Layout, offset: u32, degree: u32, from: u5, to: u5) Movement {
        return self.movements[offset + @as(u32, from) * degree + to];
    }
};
