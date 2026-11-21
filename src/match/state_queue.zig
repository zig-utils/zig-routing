//! Indexed Fibonacci queue for the Meili search order. Root and child order
//! are observable when accumulated costs tie.
const std = @import("std");
const Control = @import("../search/search.zig").Control;

pub const Index = u32;
pub const none = std.math.maxInt(Index);

const List = struct {
    first: Index = none,
    last: Index = none,
};

pub const Node = struct {
    cost: f64 = -1,
    parent: Index = none,
    previous: Index = none,
    next: Index = none,
    children: List = .{},
    rank: u8 = 0,
    marked: bool = false,
};

pub const Queue = struct {
    nodes: std.ArrayList(Node) = .empty,
    roots: List = .{},
    best: Index = none,

    pub fn offer(self: *Queue, index: Index, cost: f64, control: Control) !bool {
        const node = &self.nodes.items[index];
        if (node.cost < 0) {
            node.* = .{ .cost = cost };
            self.prependRoot(index);
        } else {
            if (node.cost <= cost) return false;
            node.cost = cost;
            const parent = node.parent;
            if (parent != none and cost < self.nodes.items[parent].cost) {
                self.cut(index);
                try self.markAfterCut(parent, control);
            }
        }
        if (self.best == none or cost < self.nodes.items[self.best].cost) self.best = index;
        return true;
    }

    pub fn pop(self: *Queue, control: Control) !?Index {
        if (self.best == none) return null;
        const result = self.best;
        const node = &self.nodes.items[result];
        self.detach(&self.roots, result);
        var child = node.children.first;
        while (child != none) {
            self.nodes.items[child].parent = none;
            child = self.nodes.items[child].next;
        }
        if (node.children.first != none) {
            self.join(&self.roots, node.children);
            node.children = .{};
        }
        self.best = self.roots.first;
        if (self.best != none) try self.mergeRoots(control);
        return result;
    }

    fn cut(self: *Queue, index: Index) void {
        const node = &self.nodes.items[index];
        const parent = &self.nodes.items[node.parent];
        self.detach(&parent.children, index);
        parent.rank -= 1;
        node.parent = none;
        node.marked = false;
        self.prependRoot(index);
    }

    fn markAfterCut(self: *Queue, first: Index, control: Control) !void {
        var node = first;
        var cuts: usize = 0;
        while (self.nodes.items[node].parent != none) : (cuts += 1) {
            if (cuts % 256 == 0) try control.check();
            const parent = self.nodes.items[node].parent;
            if (!self.nodes.items[parent].marked) {
                self.nodes.items[parent].marked = true;
                return;
            }
            self.cut(node);
            node = parent;
        }
    }

    fn mergeRoots(self: *Queue, control: Control) !void {
        var ranks: [64]Index = @splat(none);
        var index = self.roots.first;
        var visited: usize = 0;
        while (index != none) : (visited += 1) {
            if (visited % 256 == 0) try control.check();
            const next = self.nodes.items[index].next;
            var root = index;
            var rank = self.nodes.items[root].rank;
            while (ranks[rank] != none) {
                var other = ranks[rank];
                ranks[rank] = none;
                // Keep the later root as parent when both costs tie.
                if (self.nodes.items[other].cost < self.nodes.items[root].cost) std.mem.swap(Index, &root, &other);
                self.detach(&self.roots, other);
                const parent = &self.nodes.items[root];
                self.join(&parent.children, .{ .first = other, .last = other });
                self.nodes.items[other].parent = root;
                parent.rank += 1;
                rank = parent.rank;
            }
            ranks[rank] = root;
            if (self.nodes.items[root].cost <= self.nodes.items[self.best].cost) self.best = root;
            index = next;
        }
    }

    fn prependRoot(self: *Queue, index: Index) void {
        const node = &self.nodes.items[index];
        node.next = self.roots.first;
        if (self.roots.first == none) {
            self.roots.last = index;
        } else {
            self.nodes.items[self.roots.first].previous = index;
        }
        self.roots.first = index;
    }

    fn detach(self: *Queue, list: *List, index: Index) void {
        const node = &self.nodes.items[index];
        if (node.previous == none) {
            list.first = node.next;
        } else {
            self.nodes.items[node.previous].next = node.next;
        }
        if (node.next == none) {
            list.last = node.previous;
        } else {
            self.nodes.items[node.next].previous = node.previous;
        }
        node.previous = none;
        node.next = none;
    }

    fn join(self: *Queue, list: *List, suffix: List) void {
        if (list.last == none) {
            list.first = suffix.first;
        } else {
            self.nodes.items[list.last].next = suffix.first;
            self.nodes.items[suffix.first].previous = list.last;
        }
        list.last = suffix.last;
    }
};
