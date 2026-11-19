//! Directed-edge attributes grouped into canonical, deduplicated tuples.
//! Field meaning follows valhalla/baldr/directededge.h (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const constants = @import("constants.zig");

pub const ClassId = u20;
pub const max_classes = 1 << @bitSizeOf(ClassId);

/// An interning handle is distinct from the final, byte-order class ID.
pub const Handle = enum(u32) { _ };

pub const EdgeClass = extern struct {
    category: packed struct(u32) {
        use: u6 = @backingInt(constants.Use.road),
        road_class: u3 = @backingInt(constants.RoadClass.service_other),
        surface: u3 = @backingInt(constants.Surface.paved),
        sac_scale: u3 = 0,
        cycle_lane: u2 = 0,
        /// National, regional, local and MTB bits follow graph constants.
        /// The fifth bit retains the international-network tag.
        bike_network: u5 = 0,
        lanes: u4 = 1,
        density: u4 = 0,
        reserved: u2 = 0,
    } = .{},
    access: packed struct(u32) {
        forward: u16 = 0,
        reverse: u16 = 0,
    } = .{},
    flags: packed struct(u32) {
        toll: bool = false,
        tunnel: bool = false,
        bridge: bool = false,
        roundabout: bool = false,
        link: bool = false,
        internal: bool = false,
        destination_only: bool = false,
        lit: bool = false,
        sidewalk_left: bool = false,
        sidewalk_right: bool = false,
        dismount: bool = false,
        use_sidepath: bool = false,
        hov3: bool = false,
        truck_route: bool = false,
        shoulder: bool = false,
        destination_only_hgv: bool = false,
        not_thru: bool = false,
        dead_end: bool = false,
        named: bool = false,
        indoor: bool = false,
        complex_restriction: bool = false,
        bike_share_connection: bool = false,
        traffic_signal: bool = false,
        stop_sign: bool = false,
        yield_sign: bool = false,
        country_crossing: bool = false,
        tagged_speed: bool = false,
        reserved: u5 = 0,
    } = .{},
    restrictions: packed struct(u32) {
        start: u16 = 0,
        end: u16 = 0,
    } = .{},
    detail: packed struct(u32) {
        access_restriction: u16 = 0,
        max_up_slope: u5 = 0,
        max_down_slope: u5 = 0,
        reserved: u6 = 0,
    } = .{},

    pub fn valid(self: EdgeClass) bool {
        return self.category.reserved == 0 and self.flags.reserved == 0 and self.detail.reserved == 0 and
            std.enums.fromInt(constants.Use, self.category.use) != null and
            std.enums.fromInt(constants.SacScale, self.category.sac_scale) != null;
    }

    pub fn forwardAccess(self: EdgeClass) constants.AccessMask {
        return @bitCast(self.access.forward);
    }

    pub fn reverseAccess(self: EdgeClass) constants.AccessMask {
        return @bitCast(self.access.reverse);
    }

    pub fn isHovOnly(self: EdgeClass) bool {
        const access = self.forwardAccess();
        return access.hov and !access.auto;
    }

    pub fn onBikeNetwork(self: EdgeClass) bool {
        const bits: u4 = @truncate(self.category.bike_network);
        return bits != 0;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(EdgeClass) == 20 and @alignOf(EdgeClass) == 4);
    std.debug.assert(@offsetOf(EdgeClass, "category") == 0 and @offsetOf(EdgeClass, "access") == 4);
    std.debug.assert(@offsetOf(EdgeClass, "flags") == 8 and @offsetOf(EdgeClass, "restrictions") == 12);
    std.debug.assert(@offsetOf(EdgeClass, "detail") == 16);
}

const Key = [@sizeOf(EdgeClass)]u8;

pub const Interner = struct {
    const Allocator = std.mem.Allocator;

    gpa: Allocator,
    rows: std.ArrayList(EdgeClass) = .empty,
    index: std.AutoHashMapUnmanaged(Key, Handle) = .empty,

    pub fn init(gpa: Allocator) Interner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Interner) void {
        self.index.deinit(self.gpa);
        self.rows.deinit(self.gpa);
    }

    pub fn intern(self: *Interner, class: EdgeClass) !Handle {
        if (!class.valid()) return error.InvalidEdgeClass;
        const key = std.mem.asBytes(&class).*;
        if (self.index.get(key)) |handle| return handle;
        if (self.rows.items.len == max_classes) return error.EdgeClassLimitExceeded;

        const handle: Handle = @fromBackingInt(@intCast(self.rows.items.len));
        try self.rows.ensureUnusedCapacity(self.gpa, 1);
        try self.index.ensureUnusedCapacity(self.gpa, 1);
        self.index.putAssumeCapacityNoClobber(key, handle);
        self.rows.appendAssumeCapacity(class);
        return handle;
    }

    pub fn count(self: *const Interner) usize {
        return self.rows.items.len;
    }

    /// Handles remain valid while the interner lives. Each finished table
    /// can remap every handle allocated before it was created.
    pub fn finish(self: *const Interner, deadline: io.Deadline) !Table {
        if (deadline.expired()) return error.DeadlineExceeded;
        const gpa = self.gpa;
        const rows = self.rows.items;
        const classes = try gpa.alloc(EdgeClass, rows.len);
        errdefer gpa.free(classes);
        const remap = try gpa.alloc(ClassId, rows.len);
        errdefer gpa.free(remap);

        const order = try gpa.alloc(u32, rows.len);
        defer gpa.free(order);
        const scratch = try gpa.alloc(u32, rows.len);
        defer gpa.free(scratch);
        for (order, 0..) |*index, i| {
            try checkDeadline(deadline, i);
            index.* = @intCast(i);
        }
        const sorted = try sortBytes(rows, order, scratch, deadline);
        for (sorted, classes, 0..) |old, *record, id| {
            try checkDeadline(deadline, id);
            record.* = rows[old];
            remap[old] = @intCast(id);
        }
        return .{ .gpa = gpa, .classes = classes, .remap = remap };
    }
};

pub const Table = struct {
    gpa: std.mem.Allocator,
    classes: []const EdgeClass,
    remap: []const ClassId,

    pub fn id(self: *const Table, handle: Handle) error{InvalidClassHandle}!ClassId {
        const index = @backingInt(handle);
        if (index >= self.remap.len) return error.InvalidClassHandle;
        return self.remap[index];
    }

    pub fn deinit(self: *Table) void {
        self.gpa.free(self.remap);
        self.gpa.free(self.classes);
    }
};

fn checkDeadline(deadline: io.Deadline, index: usize) error{DeadlineExceeded}!void {
    if (index % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

/// Stable LSD radix sort yields lexicographic order of the on-disk bytes.
/// Sort indices so each pass moves 4 bytes per row.
fn sortBytes(rows: []const EdgeClass, indices: []u32, scratch: []u32, deadline: io.Deadline) ![]const u32 {
    var src = indices;
    var dst = scratch;
    for (0..@sizeOf(EdgeClass)) |pass| {
        const byte = @sizeOf(EdgeClass) - 1 - pass;
        var starts: [256]u32 = @splat(0);
        for (src, 0..) |index, i| {
            try checkDeadline(deadline, i);
            starts[std.mem.asBytes(&rows[index])[byte]] += 1;
        }
        var total: u32 = 0;
        for (&starts) |*start| {
            const count = start.*;
            start.* = total;
            total += count;
        }
        for (src, 0..) |index, i| {
            try checkDeadline(deadline, i);
            const next = &starts[std.mem.asBytes(&rows[index])[byte]];
            dst[next.*] = index;
            next.* += 1;
        }
        std.mem.swap([]u32, &src, &dst);
    }
    return src;
}

test "class IDs are assigned by canonical bytes regardless of arrival order" {
    const testing = std.testing;
    const a: EdgeClass = .{ .access = .{ .forward = 1 } };
    const b: EdgeClass = .{ .access = .{ .forward = 256 }, .flags = .{ .truck_route = true } };
    const c: EdgeClass = .{ .category = .{ .use = @backingInt(constants.Use.steps) } };
    var first = Interner.init(testing.allocator);
    defer first.deinit();
    const ha = try first.intern(a);
    const hb = try first.intern(b);
    const hc = try first.intern(c);
    try testing.expectEqual(ha, try first.intern(a));
    try testing.expectEqual(3, first.count());
    try testing.expectError(error.InvalidEdgeClass, first.intern(.{ .category = .{ .use = 63 } }));
    try testing.expectError(error.DeadlineExceeded, first.finish(.{ .at_ns = 0 }));
    var left = try first.finish(.none);
    defer left.deinit();

    var second = Interner.init(testing.allocator);
    defer second.deinit();
    const rc = try second.intern(c);
    const ra = try second.intern(a);
    const rb = try second.intern(b);
    var right = try second.finish(.none);
    defer right.deinit();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.classes), std.mem.sliceAsBytes(right.classes));
    try testing.expectEqual(try left.id(ha), try right.id(ra));
    try testing.expectEqual(try left.id(hb), try right.id(rb));
    try testing.expectEqual(try left.id(hc), try right.id(rc));
    try testing.expectEqual(0, try left.id(hb));
    try testing.expectEqual(1, try left.id(ha));
    try testing.expectEqual(2, try left.id(hc));
    try testing.expectError(error.InvalidClassHandle, left.id(@fromBackingInt(@intCast(3))));
}

test "the 20-bit class ID space admits its last class and rejects a new one" {
    const testing = std.testing;
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    for (0..max_classes) |i| {
        _ = try interner.intern(.{ .access = .{ .forward = @truncate(i), .reverse = @intCast(i >> 16) } });
    }
    try testing.expectEqual(max_classes, interner.count());
    try testing.expectEqual(@as(Handle, @fromBackingInt(@as(u32, 0))), try interner.intern(.{}));
    try testing.expectError(error.EdgeClassLimitExceeded, interner.intern(.{ .access = .{ .reverse = 16 } }));
}
