// Ported from valhalla/baldr/accessrestriction.h (Valhalla 3.9.3).
const std = @import("std");
const Access = @import("constants.zig").AccessMask;

pub const Kind = enum(u4) {
    hazmat = 0,
    maxheight = 1,
    maxwidth = 2,
    maxlength = 3,
    maxweight = 4,
    maxaxleload = 5,
    maxaxles = 9,
    _,

    pub fn modes(self: Kind) u16 {
        const access: Access = switch (self) {
            .hazmat, .maxaxleload, .maxaxles => .{ .truck = true },
            .maxheight, .maxwidth, .maxlength, .maxweight => .{
                .truck = true,
                .auto = true,
                .hov = true,
                .bus = true,
                .taxi = true,
            },
            else => .{},
        };
        return @bitCast(access);
    }
};

pub const Direction = enum(u2) { both, forward, backward, reserved };

/// Dimensions are in centimetres and weights in hundredths of the
/// locally used ton. Hazmat is an allow flag and maxaxles is a count.
pub const Entry = extern struct {
    value: u64,
    attr: packed struct(u64) {
        kind: Kind,
        direction: Direction,
        except_destination: bool = false,
        reserved: u57 = 0,
    },

    pub fn applies(self: Entry, forward: bool) bool {
        return self.attr.direction == .both or self.attr.direction == (if (forward) Direction.forward else .backward);
    }

    pub fn valid(self: Entry) bool {
        return self.attr.kind.modes() != 0 and self.attr.direction != .reserved and
            self.attr.reserved == 0 and (self.attr.kind != .hazmat or self.value <= 1);
    }
};

// Five limits can be tagged both generally and by direction. The other
// two (axle weight and axle count) are only read on the whole way.
pub const max_per_way = 17;

pub const Set = struct {
    items: [max_per_way]Entry = @splat(.{ .value = 0, .attr = .{ .kind = .hazmat, .direction = .both } }),
    len: u8 = 0,

    pub fn entries(self: *const Set) []const Entry {
        return self.items[0..self.len];
    }

    pub fn modes(self: *const Set, forward: bool) u16 {
        var mask: u16 = 0;
        for (self.entries()) |entry| {
            if (entry.applies(forward)) mask |= entry.attr.kind.modes();
        }
        return mask;
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Entry) == 16 and @offsetOf(Entry, "value") == 0 and @offsetOf(Entry, "attr") == 8);
}
