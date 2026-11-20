// Ported from NarrativeBuilder::FormLength, FormMetricLength and
// FormUsCustomaryLength in src/odin/narrativebuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const Units = @import("../api/request.zig").Units;
const Maneuver = @import("maneuver.zig").Maneuver;
const locale_format = @import("locale_format.zig");

pub const Labels = struct {
    metric: [4][]const u8,
    customary: [6][]const u8,

    pub fn from(subset: anytype) Labels {
        return .{
            .metric = subset.metric_lengths,
            .customary = subset.us_customary_lengths,
        };
    }
};

pub const Length = struct {
    text: []const u8,
    number: ?f32 = null,

    pub fn forManeuver(step: *const Maneuver, units: Units, labels: Labels) Length {
        const distance = if (step.has_combined_enter_exit_roundabout)
            step.roundaboutExitLength(units)
        else
            step.length(units);
        return fromDistance(distance, units, labels);
    }

    pub fn fromDistance(distance: f32, units: Units, labels: Labels) Length {
        return if (units == .miles) customary(distance, labels.customary) else metric(distance, labels.metric);
    }

    pub fn write(self: Length, out: *io.Writer, numbers: locale_format.Numbers, deadline: io.Deadline) !void {
        const Tag = enum { KILOMETERS, METERS, MILES, TENTHS_OF_MILE, FEET };
        var rest = self.text;
        while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const close = std.mem.indexOfScalarPos(u8, rest, start + 1, '>') orelse break;
            if (std.meta.stringToEnum(Tag, rest[start + 1 .. close]) != null) {
                try out.writeAll(rest[0..start]);
                if (self.number) |number| try numbers.write(out, number);
            } else {
                try out.writeAll(rest[0 .. close + 1]);
            }
            rest = rest[close + 1 ..];
        }
        try out.writeAll(rest);
    }
};

fn metric(kilometers: f32, labels: [4][]const u8) Length {
    const meters = @round(kilometers * 1000);
    if (meters > 949) {
        const rounded = if (kilometers > 3) @round(kilometers) else @round(kilometers * 2) / 2;
        return if (rounded == 1) .{ .text = labels[1] } else .{ .text = labels[0], .number = rounded };
    }
    if (!(meters > 9)) return .{ .text = labels[3] };
    const increment: f32 = if (meters > 94) 100 else 10;
    return .{ .text = labels[2], .number = @round(meters / increment) * increment };
}

fn customary(miles: f32, labels: [6][]const u8) Length {
    const feet = @round(miles * 5280);
    if (feet > 1000) {
        const rounded = if (miles > 2)
            @round(miles)
        else if (miles >= 0.625)
            @round(miles * 2) / 2
        else
            @round(miles * 4) / 4;
        if (rounded == 0.25) return .{ .text = labels[3] };
        if (rounded == 0.5) return .{ .text = labels[2] };
        if (rounded == 1) return .{ .text = labels[1] };
        return .{ .text = labels[0], .number = rounded };
    }
    if (!(feet > 9)) return .{ .text = labels[5] };
    const increment: f32 = if (feet > 94) 100 else 10;
    return .{ .text = labels[4], .number = @round(feet / increment) * increment };
}
