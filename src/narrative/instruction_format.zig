// Ported from src/odin/narrativebuilder.cc and src/odin/signs.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");
const Maneuver = @import("maneuver.zig").Maneuver;

/// A substitution borrows its source data. Lists write directly into the final instruction.
pub const Value = union(enum) {
    empty,
    text: []const u8,
    names: []const trip.StreetName,
    signs: []const trip.SignElement,
    guide: struct { branch: []const trip.SignElement, toward: []const trip.SignElement },

    pub fn isEmpty(self: Value) bool {
        return switch (self) {
            .empty => true,
            .text => |bytes| bytes.len == 0,
            .names => |list| list.len == 0,
            .signs => |list| list.len == 0,
            .guide => false,
        };
    }

    // Ferry labels in the pinned dictionaries contain no delimiter. A suffix
    // match can inspect the final name without joining the list.
    pub fn endsWithLabel(self: Value, label: []const u8) bool {
        const last = switch (self) {
            .text => |bytes| bytes,
            .names => |list| if (list.len == 0) "" else list[list.len - 1].value,
            else => unreachable,
        };
        return last.len >= label.len and std.ascii.eqlIgnoreCase(last[last.len - label.len ..], label);
    }

    fn write(self: Value, out: *io.Writer, deadline: io.Deadline) !void {
        switch (self) {
            .empty => {},
            .text => |bytes| try out.writeAll(bytes),
            .names => |list| for (list, 0..) |name, index| {
                if (deadline.expired()) return error.DeadlineExceeded;
                if (index != 0) try out.writeByte('/');
                try out.writeAll(name.value);
            },
            .signs => |list| try writeSigns(list, out, deadline),
            .guide => |pair| {
                try writeSigns(pair.branch, out, deadline);
                try out.writeByte('/');
                try writeSigns(pair.toward, out, deadline);
            },
        }
    }
};

pub fn names(list: []const trip.StreetName, limit: usize, deadline: io.Deadline) !Value {
    const limited = if (limit == 0) list else list[0..@min(limit, list.len)];
    for (limited, 0..) |entry, index| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (entry.value.len != 0) return .{ .names = limited[index..] };
    }
    return .empty;
}

pub fn streetNames(maneuver: *const Maneuver, list: []const trip.StreetName, labels: []const []const u8, limit: usize, deadline: io.Deadline) !Value {
    const value = try names(list, limit, deadline);
    if (!value.isEmpty()) return value;
    const index: usize = if (maneuver.pedestrian_type == .kBlind) blk: {
        if (maneuver.steps) break :blk 4;
        if (maneuver.bridge) break :blk 5;
        if (maneuver.tunnel) break :blk 6;
        return .empty;
    } else switch (maneuver.travel_mode) {
        .kPedestrian => if (maneuver.isUnnamedWalkway()) (if (maneuver.pedestrian_crossing) @as(usize, 3) else 0) else return .empty,
        .kBicycle => if (maneuver.isUnnamedCycleway()) 1 else if (maneuver.isUnnamedMountainBikeTrail()) 2 else return .empty,
        else => return .empty,
    };
    // The building subsets have no blind-way labels.
    return if (index < labels.len) .{ .text = labels[index] } else .empty;
}

pub const SignLimits = struct {
    count: usize = 4,
    consecutive: bool = true,
    deadline: io.Deadline = .none,

    pub fn signs(self: SignLimits, list: []const trip.SignElement) !Value {
        const selected = try self.select(list);
        for (selected) |sign| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (sign.text.len != 0) return .{ .signs = selected };
        }
        return .empty;
    }

    pub fn guide(self: SignLimits, sign: trip.Sign) !Value {
        if (sign.guide_onto_streets.len != 0 and sign.guide_toward_locations.len != 0 and self.count != 1) {
            const branch: SignLimits = .{ .count = self.count / 2 + self.count % 2, .consecutive = self.consecutive, .deadline = self.deadline };
            const toward: SignLimits = .{ .count = self.count / 2, .consecutive = self.consecutive, .deadline = self.deadline };
            return .{ .guide = .{
                .branch = try branch.select(sign.guide_onto_streets),
                .toward = try toward.select(sign.guide_toward_locations),
            } };
        }
        return self.signs(if (sign.guide_onto_streets.len != 0) sign.guide_onto_streets else sign.guide_toward_locations);
    }

    fn select(self: SignLimits, list: []const trip.SignElement) ![]const trip.SignElement {
        const limited = if (self.count == 0) list else list[0..@min(self.count, list.len)];
        if (self.consecutive and limited.len != 0) {
            for (limited[1..], 1..) |sign, index| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                if (sign.consecutive_count != limited[0].consecutive_count) return limited[0..index];
            }
        }
        return limited;
    }
};

fn writeSigns(list: []const trip.SignElement, out: *io.Writer, deadline: io.Deadline) !void {
    var started = false;
    for (list) |sign| {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (started) try out.writeByte('/');
        try out.writeAll(sign.text);
        started = started or sign.text.len != 0;
    }
}

pub const Fields = struct {
    CARDINAL_DIRECTION: ?Value = null,
    RELATIVE_DIRECTION: ?Value = null,
    STREET_NAMES: ?Value = null,
    BEGIN_STREET_NAMES: ?Value = null,
    CROSS_STREET_NAMES: ?Value = null,
    PREVIOUS_STREET_NAMES: ?Value = null,
    DESTINATION: ?Value = null,
    JUNCTION_NAME: ?Value = null,
    NUMBER_SIGN: ?Value = null,
    BRANCH_SIGN: ?Value = null,
    TOWARD_SIGN: ?Value = null,
    NAME_SIGN: ?Value = null,
    ORDINAL_VALUE: ?Value = null,
    ROUNDABOUT_EXIT_STREET_NAMES: ?Value = null,
    ROUNDABOUT_EXIT_BEGIN_STREET_NAMES: ?Value = null,
    FERRY_LABEL: ?Value = null,
    LEVEL: ?Value = null,
    OBJECT_LABEL: ?Value = null,
};

pub fn writePhrase(out: *io.Writer, pattern: []const u8, fields: Fields, deadline: io.Deadline) !void {
    const Field = std.meta.FieldEnum(Fields);
    var rest = pattern;
    while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const close = std.mem.indexOfScalarPos(u8, rest, start + 1, '>') orelse break;
        const tag = std.meta.stringToEnum(Field, rest[start + 1 .. close]);
        const value = if (tag) |field| switch (field) {
            inline else => |key| @field(fields, @tagName(key)),
        } else null;
        if (value) |replacement| {
            try out.writeAll(rest[0..start]);
            try replacement.write(out, deadline);
        } else {
            // Preserve literal text and upstream locale typos.
            try out.writeAll(rest[0 .. close + 1]);
        }
        rest = rest[close + 1 ..];
    }
    try out.writeAll(rest);
}

pub fn articulateItalian(bytes: []u8, deadline: io.Deadline) !usize {
    var len = try replaceInPlace(bytes, " su il ", " sul ", deadline);
    len = try replaceInPlace(bytes[0..len], " su la ", " sulla ", deadline);
    return len;
}

fn replaceInPlace(bytes: []u8, comptime before: []const u8, comptime after: []const u8, deadline: io.Deadline) !usize {
    var read: usize = 0;
    var written: usize = 0;
    var next_deadline_check: usize = 0;
    while (read < bytes.len) {
        if (read >= next_deadline_check) {
            if (deadline.expired()) return error.DeadlineExceeded;
            next_deadline_check = read +| 256;
        }
        if (std.mem.startsWith(u8, bytes[read..], before)) {
            @memcpy(bytes[written..][0..after.len], after);
            written += after.len;
            read += before.len;
        } else {
            bytes[written] = bytes[read];
            written += 1;
            read += 1;
        }
    }
    return written;
}
