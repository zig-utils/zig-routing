//! Table-driven costing contract for the search kernels.
//!
//! Ported from the cost arithmetic and UnitSize interface in
//! valhalla/sif/dynamiccost.h and src/sif/dynamiccost.cc (Valhalla 3.9.3).
const std = @import("std");
const graph = @import("../graph/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Allocator = std.mem.Allocator;
const infinity = std.math.inf(f32);

pub const Cost = extern struct {
    cost: f32 = 0,
    secs: f32 = 0,

    pub const forbidden: Cost = .{ .cost = infinity, .secs = infinity };

    pub fn add(self: Cost, other: Cost) Cost {
        if (self.cost == infinity or other.cost == infinity) return .forbidden;
        std.debug.assert(self.valid() and other.valid());
        return .{ .cost = finiteAdd(self.cost, other.cost), .secs = finiteAdd(self.secs, other.secs) };
    }

    fn valid(self: Cost) bool {
        return std.math.isFinite(self.cost) and self.cost >= 0 and std.math.isFinite(self.secs) and self.secs >= 0;
    }
};

pub const Tick = u64;
pub const ticks_per_cost = 1000;
pub const forbidden_tick = std.math.maxInt(Tick);
const round_guard: f64 = 1 - 0x1p-20;
pub const MetricKey = [16]u8;
pub const abi_version: u32 = 1;

/// I4. A feature that can reduce weighted cost supplies floors in [0, 1].
/// Exclusions and additive penalties leave the floors at one.
pub const Floors = struct {
    edge_factor: f32 = 1,
    speed_ratio: f32 = 1,
    turn_factor: f32 = 1,

    fn valid(self: Floors) bool {
        return 0 <= self.edge_factor and self.edge_factor <= 1 and
            0 <= self.speed_ratio and self.speed_ratio <= 1 and
            0 <= self.turn_factor and self.turn_factor <= 1;
    }
};

pub const Rules = struct {
    seconds_per_metre: [256]f32 = default_speed,
    turn: [8]Cost = @splat(.{}),
    floors: Floors = .{},
    unit_size: u32 = 1,
    node_access_mask: u16 = 0,
    /// Static metric inputs that the model evaluates outside the generic
    /// speed and class tables, such as walking pace and grade penalties.
    model_metric_key: MetricKey = @splat(0),
};

const default_speed = blk: {
    var table: [256]f32 = undefined;
    table[0] = infinity;
    for (1..table.len) |i| table[i] = 3.6 / @as(f32, @floatFromInt(i));
    break :blk table;
};

pub const Effects = struct {
    factor: f32 = 1,
    penalty: Cost = .{},
    forbidden: bool = false,

    fn valid(self: Effects, floor: f32) bool {
        return std.math.isFinite(self.factor) and self.factor >= floor and self.penalty.valid();
    }
};

pub const Speed = struct {
    actual: u8,
    /// Greatest static speed allowed by the metric. Zero yields a zero bound
    /// when the graph cannot supply an upper speed.
    upper: u8 = 0,
};

/// Immutable POD borrowed from the compile storage for the lifetime of a
/// query. The kernel contains no runtime function pointers.
pub const Compiled = struct {
    class_factor: []const f32,
    seconds_per_metre: [256]f32,
    turn: [8]Cost,
    floors: Floors,
    unit_size: u32,
    node_access_mask: u16,
    min_turn_cost: f32,
    metric_key: MetricKey,

    pub fn factor(self: *const Compiled, class: graph.class_table.ClassId) f32 {
        return if (class < self.class_factor.len) self.class_factor[class] else infinity;
    }

    pub fn allowed(self: *const Compiled, edge: anytype) bool {
        return self.factor(edge.hot.cls.class_id) != infinity;
    }

    pub fn allowedNode(self: *const Compiled, node: *const graph.format.NodeHot) bool {
        return self.node_access_mask == 0 or node.attr.access & self.node_access_mask != 0;
    }
};

/// Models normalize their raw options, supply the fixed tables in rules(),
/// and compute one factor per bundle class in classFactor().
pub fn compileInto(comptime Model: type, options: Model.Canonical, classes: []const graph.class_table.EdgeClass, factors: []f32, deadline: Deadline) !Compiled {
    if (classes.len != factors.len or classes.len > graph.class_table.max_classes) return error.InvalidClassCount;
    if (deadline.expired()) return error.DeadlineExceeded;
    var rules = try Model.rules(options);
    if (!rules.floors.valid() or rules.unit_size == 0) return error.InvalidCostRules;
    rules.floors.edge_factor = canonicalFloat(rules.floors.edge_factor);
    rules.floors.speed_ratio = canonicalFloat(rules.floors.speed_ratio);
    rules.floors.turn_factor = canonicalFloat(rules.floors.turn_factor);
    if (rules.seconds_per_metre[0] != infinity) return error.InvalidSpeedTable;
    var minimum_turn = infinity;
    for (&rules.turn) |*turn| {
        if (!turn.valid()) return error.InvalidTurnCost;
        turn.cost = canonicalFloat(turn.cost);
        turn.secs = canonicalFloat(turn.secs);
        minimum_turn = @min(minimum_turn, turn.cost);
    }
    for (1..rules.seconds_per_metre.len) |i| {
        const value = canonicalFloat(rules.seconds_per_metre[i]);
        if (!std.math.isFinite(value) or value <= 0 or value > rules.seconds_per_metre[i - 1])
            return error.InvalidSpeedTable;
        rules.seconds_per_metre[i] = value;
    }

    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(std.mem.asBytes(&abi_version));
    const class_count: u32 = @intCast(classes.len);
    hash.update(std.mem.asBytes(&class_count));
    for (classes, factors, 0..) |class, *out, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const value = canonicalFloat(try Model.classFactor(options, class));
        if (std.math.isNan(value) or value < 0) return error.InvalidClassFactor;
        out.* = value;
        if (i % 1024 == 1023) hash.update(std.mem.sliceAsBytes(factors[i - 1023 .. i + 1]));
    }
    hash.update(std.mem.sliceAsBytes(factors[factors.len - factors.len % 1024 ..]));
    hash.update(std.mem.asBytes(&rules.seconds_per_metre));
    hash.update(std.mem.asBytes(&rules.turn));
    hash.update(std.mem.asBytes(&rules.floors.edge_factor));
    hash.update(std.mem.asBytes(&rules.floors.speed_ratio));
    hash.update(std.mem.asBytes(&rules.floors.turn_factor));
    hash.update(&rules.model_metric_key);
    var key: MetricKey = undefined;
    hash.final(&key);
    return .{
        .class_factor = factors,
        .seconds_per_metre = rules.seconds_per_metre,
        .turn = rules.turn,
        .floors = rules.floors,
        .unit_size = rules.unit_size,
        .node_access_mask = rules.node_access_mask,
        .min_turn_cost = minimum_turn,
        .metric_key = key,
    };
}

fn canonicalFloat(value: f32) f32 {
    return if (value == 0) 0 else value;
}

/// I1 and I2 use the floors declared at compilation. I3 reserves infinity for
/// forbidden edges or turns. I5 floors the static weights to integer ticks and
/// leaves a relative margin for f32 arithmetic in the real path.
pub const Kernel = struct {
    pub fn edgeCost(table: *const Compiled, edge: graph.format.EdgeHot, speed: Speed, effects: Effects) Cost {
        const factor = table.factor(edge.cls.class_id);
        if (effects.forbidden or factor == infinity or speed.actual == 0) return .forbidden;
        std.debug.assert(effects.valid(table.floors.edge_factor));
        const spm = table.seconds_per_metre[speed.actual];
        if (speed.upper != 0) {
            const floor = @as(f64, table.seconds_per_metre[speed.upper]) * table.floors.speed_ratio;
            std.debug.assert(spm >= floor);
        }
        const distance: f32 = @floatFromInt(edge.geom.len_m);
        const secs = finiteMul(distance, spm);
        const weighted = finiteMul(finiteMul(secs, factor), effects.factor);
        return .{ .cost = finiteAdd(weighted, effects.penalty.cost), .secs = finiteAdd(secs, effects.penalty.secs) };
    }

    pub fn turnCost(table: *const Compiled, row: graph.format.TurnEntry, effects: Effects) Cost {
        if (effects.forbidden or row & 0x80 != 0) return .forbidden;
        std.debug.assert(effects.valid(table.floors.turn_factor));
        const base = table.turn[row & 7];
        return .{
            .cost = finiteAdd(finiteMul(base.cost, effects.factor), effects.penalty.cost),
            .secs = finiteAdd(base.secs, effects.penalty.secs),
        };
    }

    pub noinline fn slowAllowed(table: *const Compiled, view: *const graph.reader.View, id: graph.format.EdgeId, policy: anytype) bool {
        const edge = view.edge(id) catch return false;
        return table.factor(edge.cls.class_id) != infinity and policy.allowed(view, id, edge);
    }

    pub fn unitSize(table: *const Compiled) u32 {
        return table.unit_size;
    }

    pub fn edgeLowerBound(table: *const Compiled, edge: graph.format.EdgeHot, upper_speed: u8) Tick {
        const factor = table.factor(edge.cls.class_id);
        if (factor == infinity) return forbidden_tick;
        if (upper_speed == 0) return 0;
        const len: f64 = @floatFromInt(edge.geom.len_m);
        const spm: f64 = table.seconds_per_metre[upper_speed];
        const secs = @min(len * spm * table.floors.speed_ratio, std.math.floatMax(f32));
        const weighted = @min(secs * factor, std.math.floatMax(f32));
        return floorTicks(weighted * table.floors.edge_factor);
    }

    pub fn turnLowerBound(table: *const Compiled) Tick {
        return floorTicks(@as(f64, table.min_turn_cost) * table.floors.turn_factor);
    }

    pub fn assertBounds(table: *const Compiled, edge: graph.format.EdgeHot, speed: Speed, row: graph.format.TurnEntry, edge_effects: Effects, turn_effects: Effects) void {
        const edge_cost = edgeCost(table, edge, speed, edge_effects);
        const turn_cost = turnCost(table, row, turn_effects);
        std.debug.assert(edge_cost.valid() or std.meta.eql(edge_cost, Cost.forbidden));
        std.debug.assert(turn_cost.valid() or std.meta.eql(turn_cost, Cost.forbidden));
        std.debug.assert(costUnits(edgeLowerBound(table, edge, speed.upper)) <= edge_cost.cost);
        std.debug.assert(costUnits(turnLowerBound(table)) <= turn_cost.cost);
    }
};

fn finiteMul(a: f32, b: f32) f32 {
    return @min(a * b, std.math.floatMax(f32));
}

fn finiteAdd(a: f32, b: f32) f32 {
    return @min(a + b, std.math.floatMax(f32));
}

pub fn floorTicks(value: f64) Tick {
    const scaled = value * round_guard * ticks_per_cost;
    std.debug.assert(scaled >= 0);
    if (scaled >= 0x1p64) return forbidden_tick - 1;
    return @intFromFloat(@floor(scaled));
}

pub fn costUnits(ticks: Tick) f64 {
    if (ticks == forbidden_tick) return std.math.inf(f64);
    return @as(f64, @floatFromInt(ticks)) / ticks_per_cost;
}

/// Worker-local cache. All class-factor storage is reserved up front. A
/// leased slot cannot be evicted while a query is using its compiled POD.
/// Canonical options use value semantics, and model callbacks do not allocate.
pub fn Cache(comptime Model: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            options: ?Model.Canonical = null,
            compiled: Compiled = undefined,
            borrowed: usize = 0,
            last_use: u64 = 0,
        };

        pub const Lease = struct {
            slot: *Slot,

            pub fn tables(self: Lease) *const Compiled {
                return &self.slot.compiled;
            }

            pub fn profile(self: Lease) *const Model.Canonical {
                return &self.slot.options.?;
            }

            pub fn release(self: *Lease) void {
                self.slot.borrowed -= 1;
                self.* = undefined;
            }
        };

        allocator: Allocator,
        classes: []const graph.class_table.EdgeClass,
        slots: []Slot,
        factors: []f32,
        clock: u64 = 0,

        pub fn init(allocator: Allocator, classes: []const graph.class_table.EdgeClass, capacity: usize) !Self {
            if (capacity == 0 or classes.len > graph.class_table.max_classes) return error.InvalidCompileCacheSize;
            const slots = try allocator.alloc(Slot, capacity);
            errdefer allocator.free(slots);
            @memset(slots, .{});
            const length = std.math.mul(usize, capacity, classes.len) catch return error.InvalidCompileCacheSize;
            const factors = try allocator.alloc(f32, length);
            return .{ .allocator = allocator, .classes = classes, .slots = slots, .factors = factors };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots) |slot| std.debug.assert(slot.borrowed == 0);
            self.allocator.free(self.factors);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn acquire(self: *Self, raw: Model.Options, deadline: Deadline) !Lease {
            if (deadline.expired()) return error.DeadlineExceeded;
            const canonical = try Model.canonicalize(raw);
            var victim: ?usize = null;
            for (self.slots, 0..) |*slot, index| {
                if (index % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (slot.options) |prior| {
                    if (std.meta.eql(canonical, prior)) return self.borrow(slot);
                    if (slot.borrowed != 0) continue;
                }
                if (victim == null or slot.options == null or
                    (self.slots[victim.?].options != null and slot.last_use < self.slots[victim.?].last_use))
                    victim = index;
            }
            const index = victim orelse return error.CompileCacheBusy;
            const slot = &self.slots[index];
            slot.options = null;
            const buffer = self.factors[index * self.classes.len ..][0..self.classes.len];
            const value = try compileInto(Model, canonical, self.classes, buffer, deadline);
            slot.compiled = value;
            slot.options = canonical;
            return self.borrow(slot);
        }

        fn borrow(self: *Self, slot: *Slot) Lease {
            self.clock +%= 1;
            slot.last_use = self.clock;
            slot.borrowed += 1;
            return .{ .slot = slot };
        }
    };
}

const Toy = struct {
    pub const Canonical = struct {
        class_scale: f32 = 1,
        turn_base: f32 = 0,
        raw_group: u8 = 0,
        unusual_speed: bool = false,
    };
    pub const Options = struct { value: Canonical = .{}, alias: bool = false };

    pub fn canonicalize(raw: Options) !Canonical {
        var result = raw.value;
        if (raw.alias) result.raw_group = 0;
        return result;
    }

    pub fn rules(options: Canonical) !Rules {
        var result: Rules = .{ .floors = .{ .edge_factor = 0.2, .speed_ratio = 0.25, .turn_factor = 0.5 } };
        for (&result.turn, 0..) |*turn, ordinal| {
            const value: f32 = @floatFromInt(ordinal);
            turn.* = .{ .cost = options.turn_base + value, .secs = value * 0.25 };
        }
        if (options.unusual_speed) @memset(result.seconds_per_metre[1..], std.math.floatMax(f32));
        return result;
    }

    pub fn classFactor(options: Canonical, class: graph.class_table.EdgeClass) !f32 {
        if (class.category.road_class == 0) return infinity;
        return options.class_scale * @as(f32, @floatFromInt(class.category.road_class));
    }
};

fn testEdge(class: graph.class_table.ClassId, length: u24) graph.format.EdgeHot {
    return .{
        .head = 0,
        .cls = .{ .class_id = class, .local = 0, .opp_local = 0, .cold_checks = 0, .pred_speed = 0 },
        .geom = .{ .len_m = length, .grade = 0, .curvature = 0 },
        .speed = @splat(0),
    };
}

test "weighted edge and turn bounds stay below the real costs across random compiled options" {
    const testing = std.testing;
    var rng = std.Random.DefaultPrng.init(0x71_c057);
    const random = rng.random();
    var classes: [8]graph.class_table.EdgeClass = @splat(.{});
    for (&classes, 0..) |*class, i| class.category.road_class = @intCast(i);
    var factors: [classes.len]f32 = undefined;
    for (0..32) |_| {
        const table = try compileInto(Toy, .{
            .turn_base = 0.25 + 80 * random.float(f32),
            .class_scale = 0.05 + 8 * random.float(f32),
        }, &classes, &factors, .none);
        for (0..1024) |_| {
            const edge = testEdge(random.intRangeAtMost(u20, 0, 7), random.int(u24));
            const upper = random.intRangeAtMost(u8, 1, 255);
            const speed: Speed = .{ .actual = random.intRangeAtMost(u8, 1, @min(@as(u8, 255), upper *| 3)), .upper = upper };
            const row = random.int(u8);
            const edge_effects: Effects = .{
                .factor = 0.25 + 3 * random.float(f32),
                .penalty = .{ .cost = random.float(f32) * 40, .secs = random.float(f32) * 20 },
                .forbidden = random.int(u4) == 0,
            };
            const turn_effects: Effects = .{
                .factor = 0.5 + 4 * random.float(f32),
                .penalty = .{ .cost = random.float(f32) * 60, .secs = random.float(f32) * 30 },
            };
            const actual = Kernel.edgeCost(&table, edge, speed, edge_effects);
            const turn = Kernel.turnCost(&table, row, turn_effects);
            try testing.expect(actual.valid() or std.meta.eql(actual, Cost.forbidden));
            try testing.expect(turn.valid() or std.meta.eql(turn, Cost.forbidden));
            try testing.expect(costUnits(Kernel.edgeLowerBound(&table, edge, upper)) <= actual.cost);
            try testing.expect(costUnits(Kernel.turnLowerBound(&table)) <= turn.cost);
            try testing.expectEqual(edge.cls.class_id == 0 or edge_effects.forbidden, actual.cost == infinity);
            try testing.expectEqual(row & 0x80 != 0, turn.cost == infinity);
            Kernel.assertBounds(&table, edge, speed, row, edge_effects, turn_effects);
        }
    }
    const overflow = try compileInto(Toy, .{ .class_scale = 1e-38, .unusual_speed = true }, &classes, &factors, .none);
    const edge = testEdge(1, 20_000);
    const speed: Speed = .{ .actual = 1, .upper = 1 };
    const actual = Kernel.edgeCost(&overflow, edge, speed, .{});
    try testing.expect(actual.valid());
    try testing.expect(costUnits(Kernel.edgeLowerBound(&overflow, edge, 1)) <= actual.cost);
    try testing.expectEqual(@as(Tick, 0), Kernel.edgeLowerBound(&overflow, edge, 0));
}

test "compile cache canonicalizes options, keys equivalent tables and allocates only at setup" {
    const testing = std.testing;
    var backing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const classes = [_]graph.class_table.EdgeClass{ .{}, .{ .category = .{ .road_class = 0 } } };
    var cache = try Cache(Toy).init(backing.allocator(), &classes, 2);
    defer cache.deinit();

    var first = try cache.acquire(.{}, .none);
    const first_key = first.tables().metric_key;
    var alias = try cache.acquire(.{ .value = .{ .raw_group = 4 }, .alias = true }, .none);
    try testing.expect(first.tables() == alias.tables());
    alias.release();
    var equivalent = try cache.acquire(.{ .value = .{ .raw_group = 9 } }, .none);
    try testing.expect(first.tables() != equivalent.tables());
    try testing.expectEqual(first_key, equivalent.tables().metric_key);
    try testing.expectError(error.CompileCacheBusy, cache.acquire(.{ .value = .{ .class_scale = 2 } }, .none));
    first.release();
    equivalent.release();

    const allocations = backing.allocations;
    const resizes = backing.resize_index;
    backing.fail_index = backing.alloc_index;
    for (1..128) |n| {
        const scale: f32 = @floatFromInt(n);
        var lease = try cache.acquire(.{ .value = .{ .class_scale = scale } }, .none);
        if (n != 1) try testing.expect(!std.mem.eql(u8, &first_key, &lease.tables().metric_key));
        try testing.expectEqual(1, Kernel.unitSize(lease.tables()));
        lease.release();
    }
    try testing.expectEqual(allocations, backing.allocations);
    try testing.expectEqual(resizes, backing.resize_index);
    try testing.expectError(error.DeadlineExceeded, cache.acquire(.{}, .{ .at_ns = 0 }));
}
