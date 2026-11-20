// Ported from src/odin/narrativebuilder.cc and src/odin/signs.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");
const Maneuver = @import("maneuver.zig").Maneuver;
const verbal_text = @import("verbal_text.zig");
const locale_format = @import("locale_format.zig");
const Length = @import("verbal_distances.zig").Length;

pub const Speech = struct {
    text_formatter: *verbal_text.Formatter,
    style: verbal_text.Style,
    numbers: locale_format.Numbers,
    delimiter: []const u8 = ", ",
};

pub const Context = struct {
    deadline: io.Deadline,
    speech: ?Speech = null,

    fn writeName(self: Context, out: *io.Writer, text: []const u8, pronunciation: ?trip.Pronunciation) !void {
        if (self.speech) |speech| {
            try speech.text_formatter.write(out, speech.style, text, pronunciation);
        } else {
            try out.writeAll(text);
        }
    }

    fn delimiter(self: Context) []const u8 {
        return if (self.speech) |speech| speech.delimiter else "/";
    }
};

/// A substitution borrows its source data. Lists write directly into the final instruction.
pub const Value = union(enum) {
    empty,
    text: []const u8,
    spoken: []const u8,
    length: Length,
    names: []const trip.StreetName,
    signs: []const trip.SignElement,
    guide: struct { branch: []const trip.SignElement, toward: []const trip.SignElement },

    pub fn isEmpty(self: Value) bool {
        return switch (self) {
            .empty => true,
            .text, .spoken => |bytes| bytes.len == 0,
            .length => |value| value.text.len == 0,
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

    pub fn write(self: Value, out: *io.Writer, context: Context) !void {
        switch (self) {
            .empty => {},
            .text => |bytes| try out.writeAll(bytes),
            .spoken => |bytes| try context.writeName(out, bytes, null),
            .length => |value| try value.write(out, if (context.speech) |voice| voice.numbers else .{}, context.deadline),
            .names => |list| for (list, 0..) |name, index| {
                if (context.deadline.expired()) return error.DeadlineExceeded;
                if (index != 0) try out.writeAll(context.delimiter());
                try context.writeName(out, name.value, name.pronunciation);
            },
            .signs => |list| try writeSigns(list, out, context),
            .guide => |pair| {
                try writeSigns(pair.branch, out, context);
                try out.writeAll(context.delimiter());
                try writeSigns(pair.toward, out, context);
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

pub const StreetPair = struct { street: Value = .empty, begin: Value = .empty };

pub fn startNames(step: *const Maneuver, labels: []const []const u8, limit: usize, deadline: io.Deadline) !StreetPair {
    const begin = try names(step.begin_street_names, limit, deadline);
    if (step.contains_obvious_maneuver and !begin.isEmpty()) return .{ .street = begin };
    return .{ .street = try streetNames(step, step.street_names, labels, limit, deadline), .begin = begin };
}

pub const JunctionOrGuide = struct { id: ?u8 = null, junction: Value = .empty, guide: Value = .empty };

pub fn junctionOrGuide(step: *const Maneuver, limits: SignLimits, junction_id: u8, guide_id: u8) !JunctionOrGuide {
    if (step.hasGuideSign()) return .{ .id = guide_id, .guide = try limits.guide(step.signs) };
    if (step.signs.junction_names.len != 0) return .{ .id = junction_id, .junction = try limits.signs(step.signs.junction_names) };
    return .{};
}

pub const KeepNames = struct { street: Value, toward: Value };

pub fn keepNames(step: *const Maneuver, labels: []const []const u8, limits: SignLimits) !KeepNames {
    const sign = step.signs;
    if (step.hasGuideSign()) return .{
        .street = try limits.signs(sign.guide_onto_streets),
        .toward = try limits.signs(sign.guide_toward_locations),
    };
    var street: Value = if (step.ramp and sign.exit_onto_streets.len != 0)
        try limits.signs(sign.exit_onto_streets)
    else
        try streetNames(step, step.street_names, labels, limits.count, limits.deadline);
    if (street.isEmpty() and !step.ramp) street = try limits.signs(sign.exit_onto_streets);
    return .{ .street = street, .toward = try limits.signs(sign.exit_toward_locations) };
}

pub fn exitNumbers(sign: trip.Sign, deadline: io.Deadline) !Value {
    const unlimited: SignLimits = .{ .count = 0, .consecutive = false, .deadline = deadline };
    return unlimited.signs(sign.exit_numbers);
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

fn writeSigns(list: []const trip.SignElement, out: *io.Writer, context: Context) !void {
    var started = false;
    for (list) |sign| {
        if (context.deadline.expired()) return error.DeadlineExceeded;
        if (started) try out.writeAll(context.delimiter());
        try context.writeName(out, sign.text, sign.pronunciation);
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
    LENGTH: ?Value = null,
    CURRENT_VERBAL_CUE: ?Value = null,
    NEXT_VERBAL_CUE: ?Value = null,
    TRANSIT_STOP: ?Value = null,
    TIME: ?Value = null,
};

pub fn writePhrase(out: *io.Writer, pattern: []const u8, fields: Fields, context: Context) !void {
    const Field = std.meta.FieldEnum(Fields);
    var rest = pattern;
    while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
        if (context.deadline.expired()) return error.DeadlineExceeded;
        const close = std.mem.indexOfScalarPos(u8, rest, start + 1, '>') orelse break;
        const tag = std.meta.stringToEnum(Field, rest[start + 1 .. close]);
        const value = if (tag) |field| switch (field) {
            inline else => |key| @field(fields, @tagName(key)),
        } else null;
        if (value) |replacement| {
            try out.writeAll(rest[0..start]);
            try replacement.write(out, context);
        } else {
            // A literal opening bracket may precede a valid locale tag.
            try out.writeAll(rest[0 .. start + 1]);
            rest = rest[start + 1 ..];
            continue;
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

pub fn present(value: bool) u8 {
    return @intFromBool(value);
}

pub fn direction(step: *const Maneuver, labels: [2][]const u8) Value {
    return .{ .text = labels[@intFromBool(step.isRightType())] };
}

pub fn forkDirection(step: *const Maneuver, labels: [3][]const u8) Value {
    const index: usize = switch (step.type) {
        .kStayLeft => 0,
        .kStayStraight => 1,
        .kStayRight => 2,
        else => unreachable,
    };
    return .{ .text = labels[index] };
}

pub fn rampDirectionOffset(step: *const Maneuver) u8 {
    return switch (step.begin_relative_direction) {
        .left, .right => 5,
        .keep_left => if (step.drive_on_right) 0 else 10,
        .keep_right => if (step.drive_on_right) 10 else 0,
        else => 0,
    };
}

test "Valhalla sign list and sign text snapshots" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    const testing = std.testing;
    try testing.expectEqual(19, fixtures.sign_cases.len);
    var output = io.Writer.Allocating.init(testing.allocator);
    defer output.deinit();

    for (fixtures.sign_cases) |fixture| {
        errdefer std.debug.print("failed upstream fixture {s}\n", .{fixture.name});
        for (fixture.trials) |trial| {
            const limits: SignLimits = .{ .count = trial.limit, .consecutive = trial.consecutive };
            const result: Value = switch (fixture.part) {
                .guide => try limits.guide(fixture.sign),
                .trim => .{ .signs = try limits.select(fixture.sign.exit_onto_streets) },
                inline else => |part| try limits.signs(@field(fixture.sign, @tagName(part))),
            };
            switch (trial.expected) {
                .text => |text| {
                    output.clearRetainingCapacity();
                    try result.write(&output.writer, .{ .deadline = .none });
                    try snapshot.match(fixture.name, text, output.written());
                },
                .elements => |expected| switch (result) {
                    .signs => |actual| try testing.expectEqualDeep(expected, actual),
                    .guide => |guide| {
                        try testing.expectEqual(expected.len, guide.branch.len + guide.toward.len);
                        try testing.expectEqualDeep(expected[0..guide.branch.len], guide.branch);
                        try testing.expectEqualDeep(expected[guide.branch.len..], guide.toward);
                    },
                    .empty => try testing.expectEqual(0, expected.len),
                    else => return error.InvalidSignFixture,
                },
            }
        }
    }
}
