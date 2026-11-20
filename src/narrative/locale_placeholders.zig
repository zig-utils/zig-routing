//! Placeholder validation for the pinned locale sources.
const std = @import("std");

const Tag = enum {
    BEGIN_STREET_NAMES,
    BRANCH_SIGN,
    CARDINAL_DIRECTION,
    CROSS_STREET_NAMES,
    CURRENT_VERBAL_CUE,
    DESTINATION,
    EXIT_NUMBERS,
    FEET,
    FERRY_LABEL,
    JUNCTION_NAME,
    KILOMETERS,
    LENGTH,
    LEVEL,
    METERS,
    MILES,
    NAME_SIGN,
    NEXT_VERBAL_CUE,
    NUMBER_SIGN,
    OBJECT_LABEL,
    ORDINAL_VALUE,
    PREVIOUS_STREET_NAMES,
    RELATIVE_DIRECTION,
    ROUNDABOUT_EXIT_BEGIN_STREET_NAMES,
    ROUNDABOUT_EXIT_STREET_NAMES,
    STATION_LABEL,
    STREET_NAMES,
    TIME,
    TOWARD_SIGN,
    TRANSIT_HEADSIGN,
    TRANSIT_NAME,
    TRANSIT_STOP,
    TRANSIT_STOP_COUNT,
    TRANSIT_STOP_COUNT_LABEL,
    @"<CARDINAL_DIRECTION",
    @"ORDINAL VALUE",

    fn bit(self: Tag) u64 {
        return @as(u64, 1) << @intCast(@backingInt(self));
    }
};

const Change = struct {
    locale: []const u8,
    subset: []const u8,
    id: u8,
    remove: ?Tag = null,
    add: ?Tag = null,
};

// The pinned translations contain these phrase placeholder differences.
const upstream_phrase_changes = [_]Change{
    .{ .locale = "ca-ES", .subset = "exit_roundabout_verbal", .id = 2, .add = .STREET_NAMES },
    .{ .locale = "de-DE", .subset = "bear_verbal", .id = 2, .add = .STREET_NAMES },
    .{ .locale = "de-DE", .subset = "enter_roundabout_verbal", .id = 9, .remove = .ORDINAL_VALUE },
    .{ .locale = "de-DE", .subset = "keep_to_stay_on", .id = 2, .remove = .TOWARD_SIGN, .add = .NUMBER_SIGN },
    .{ .locale = "de-DE", .subset = "keep_to_stay_on_verbal", .id = 2, .remove = .TOWARD_SIGN, .add = .NUMBER_SIGN },
    .{ .locale = "de-DE", .subset = "turn_verbal", .id = 2, .add = .STREET_NAMES },
    .{ .locale = "el-GR", .subset = "sharp", .id = 5, .remove = .TOWARD_SIGN, .add = .STREET_NAMES },
    .{ .locale = "el-GR", .subset = "sharp_verbal", .id = 5, .remove = .TOWARD_SIGN, .add = .STREET_NAMES },
    .{ .locale = "hi-IN", .subset = "bear", .id = 2, .remove = .BEGIN_STREET_NAMES },
    .{ .locale = "hi-IN", .subset = "exit", .id = 14, .remove = .BRANCH_SIGN },
    .{ .locale = "hi-IN", .subset = "exit", .id = 29, .remove = .BRANCH_SIGN },
    .{ .locale = "hi-IN", .subset = "exit_verbal", .id = 14, .remove = .BRANCH_SIGN },
    .{ .locale = "hi-IN", .subset = "exit_verbal", .id = 29, .remove = .BRANCH_SIGN },
    .{ .locale = "hi-IN", .subset = "start_verbal", .id = 1, .remove = .CARDINAL_DIRECTION, .add = .@"<CARDINAL_DIRECTION" },
    .{ .locale = "mn-MN", .subset = "enter_roundabout_verbal", .id = 10, .remove = .ORDINAL_VALUE, .add = .@"ORDINAL VALUE" },
    .{ .locale = "sk-SK", .subset = "bear_verbal", .id = 2, .add = .STREET_NAMES },
    .{ .locale = "sk-SK", .subset = "sharp_verbal", .id = 2, .add = .STREET_NAMES },
    .{ .locale = "sk-SK", .subset = "turn_verbal", .id = 2, .add = .STREET_NAMES },
};

pub fn validate(locale: []const u8, subset: []const u8, field: []const u8, id: u8, text: []const u8, reference: []const u8) !void {
    var expected = try mask(reference);
    if (std.mem.eql(u8, field, "phrases")) {
        for (upstream_phrase_changes) |change| {
            if (change.id != id or !std.mem.eql(u8, change.locale, locale) or !std.mem.eql(u8, change.subset, subset)) continue;
            if (change.remove) |tag| expected &= ~tag.bit();
            if (change.add) |tag| expected |= tag.bit();
            break;
        }
    } else if (std.mem.eql(u8, locale, "ar-SA") or
        (std.mem.eql(u8, locale, "bg-BG") and !std.mem.eql(u8, subset, "continue_verbal")))
    {
        // These metric and customary length entries have no numeric placeholder upstream.
        if (std.mem.eql(u8, field, "metric_lengths")) {
            if (id == 0) expected &= ~Tag.KILOMETERS.bit();
            if (id == 2) expected &= ~Tag.METERS.bit();
        } else if (std.mem.eql(u8, field, "us_customary_lengths") and id == 0) {
            expected &= ~Tag.MILES.bit();
        }
    }
    if (try mask(text) != expected) {
        std.debug.print("placeholder set differs at {s}.{s}.{d}\n", .{ subset, field, id });
        return error.LocalePlaceholderMismatch;
    }
}

fn mask(text: []const u8) !u64 {
    var remaining = text;
    var result: u64 = 0;
    while (std.mem.indexOfScalar(u8, remaining, '<')) |start| {
        const tag_start = remaining[start + 1 ..];
        const end = std.mem.indexOfScalar(u8, tag_start, '>') orelse return error.UnterminatedLocalePlaceholder;
        const token = tag_start[0..end];
        const tag = std.meta.stringToEnum(Tag, token) orelse {
            std.debug.print("unknown locale placeholder {s}\n", .{token});
            return error.UnknownLocalePlaceholder;
        };
        result |= tag.bit();
        remaining = tag_start[end + 1 ..];
    }
    return result;
}
