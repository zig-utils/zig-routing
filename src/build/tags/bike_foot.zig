// Ported from lua/graph.lua's cycle lanes, shoulders and networks and
// src/mjolnir/pbfgraphparser.cc's bicycle and pedestrian handlers (Valhalla 3.9.3).

const std = @import("std");
const constants = @import("../../graph/constants.zig");
const io = @import("../../infra/io.zig");
const attrs = @import("attrs.zig");
const defaults = @import("defaults.zig");
const input = @import("input.zig");
const Selection = @import("selection.zig").Selection;
const Value = @import("table.zig").Value;

pub fn readMountainBike(tags: *const input.Scratch, deadline: io.Deadline) !attrs.BicycleAttrs {
    return .{
        .mtb_scale = try defaults.nonnegativeIntPrefix(tags.text(.@"mtb:scale") orelse "", deadline),
        .mtb_uphill_scale = try defaults.nonnegativeIntPrefix(tags.text(.@"mtb:scale:uphill") orelse "", deadline),
    };
}

fn directionalCycleLane(value: ?Value, buffer: ?Value) constants.CycleLane {
    const lane = defaults.cycleLane(value);
    return if (lane == .none and buffer == .yes) .dedicated else lane;
}

fn applyCycleLanes(way: *attrs.WayAttrs, tags: *const input.Scratch, selected: Selection) void {
    const bike = &way.bicycle;
    // Use the permissions present at graph.lua's lane stage. HOV and
    // MTB adjustments take effect after these lanes have been assigned.
    if ((way.use == .cycleway or way.use == .footway or way.use == .path) and
        (selected.forward.bicycle or selected.backward.bicycle))
    {
        const lane: constants.CycleLane = if (selected.forward_pedestrian_denied) .separated else switch (tags.id(.segregated) orelse .unknown) {
            .yes => .dedicated,
            .no => .shared,
            else => if (way.use == .cycleway) .dedicated else .shared,
        };
        bike.lane_left = lane;
        bike.lane_right = lane;
        return;
    }

    const common = tags.id(.cycleway);
    const left = tags.id(.@"cycleway:left");
    const right = tags.id(.@"cycleway:right");
    const opposite = defaults.oppositeCycleway(common);
    bike.left_opposite = opposite or defaults.oppositeCycleway(left);
    bike.right_opposite = opposite or defaults.oppositeCycleway(right);
    const common_lane = directionalCycleLane(common, tags.id(.@"cycleway:both:buffer"));
    bike.lane_left = if (common_lane != .none) common_lane else directionalCycleLane(left, tags.id(.@"cycleway:left:buffer"));
    bike.lane_right = if (common_lane != .none) common_lane else directionalCycleLane(right, tags.id(.@"cycleway:right:buffer"));

    if (tags.id(.@"oneway:bicycle") == .no and !bike.left_opposite and !bike.right_opposite) {
        if (bike.lane_right == .dedicated or bike.lane_right == .separated) {
            if (selected.oneway or bike.lane_left == .none) {
                bike.lane_left = bike.lane_right;
                bike.left_opposite = selected.oneway;
            }
        } else if (bike.lane_left == .dedicated or bike.lane_left == .separated) {
            if (selected.oneway or bike.lane_right == .none) {
                bike.lane_right = bike.lane_left;
                bike.right_opposite = selected.oneway;
            }
        }
    }
}

fn shoulder(value: ?Value) ?bool {
    return switch (value orelse return null) {
        .yes, .both => true,
        .no => false,
        else => null,
    };
}

fn applyShoulders(way: *attrs.WayAttrs, tags: *const input.Scratch) void {
    const common = tags.id(.shoulder);
    if (shoulder(common) orelse shoulder(tags.id(.@"shoulder:both"))) |present| {
        way.flags.shoulder_left = present;
        way.flags.shoulder_right = present;
        return;
    }
    const left = shoulder(tags.id(.@"shoulder:left")) orelse (common == .left);
    const right = shoulder(tags.id(.@"shoulder:right")) orelse (common == .right);
    way.flags.shoulder_left = left or (way.flags.oneway and right);
    way.flags.shoulder_right = right or (way.flags.oneway and left);
}

pub fn sacScale(text: []const u8, deadline: io.Deadline) !constants.SacScale {
    const values = [_]constants.SacScale{
        .difficult_alpine_hiking,
        .demanding_alpine_hiking,
        .alpine_hiking,
        .demanding_mountain_hiking,
        .mountain_hiking,
        .hiking,
    };
    for (values) |value| {
        if (try input.contains(text, @tagName(value), true, deadline)) return value;
    }
    return .none;
}

fn trailVisibility(value: ?Value) ?attrs.TrailVisibility {
    return switch (value orelse return null) {
        .excellent => .excellent,
        .good => .good,
        .intermediate => .intermediate,
        .bad => .bad,
        .horrible => .horrible,
        .no => .no,
        else => null,
    };
}

fn tactilePaving(value: ?Value) ?attrs.TactilePaving {
    return switch (value orelse return null) {
        .yes => .yes,
        .no => .no,
        .partial => .partial,
        .incorrect => .incorrect,
        else => null,
    };
}

fn steps(tags: *const input.Scratch, deadline: io.Deadline) !?u32 {
    const text = tags.text(.step_count) orelse return null;
    if (text.len == 0) return null;
    for (text, 0..) |c, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u32, text, 10) catch null;
}

pub fn applyWay(way: *attrs.WayAttrs, tags: *const input.Scratch, selected: Selection, deadline: io.Deadline) !void {
    applyCycleLanes(way, tags, selected);
    applyShoulders(way, tags);
    const bicycle = tags.id(.bicycle);
    way.bicycle.dismount = bicycle == .dismount;
    way.bicycle.use_sidepath = bicycle == .use_sidepath;
    way.bicycle.network = .{
        .ncn = tags.get(.ncn_ref) != null or tags.id(.ncn) == .yes,
        .rcn = tags.get(.rcn_ref) != null or tags.id(.rcn) == .yes,
        .lcn = tags.get(.lcn_ref) != null or tags.id(.lcn) == .yes,
        .mtb = tags.id(.mtb) == .yes,
        .icn = tags.get(.icn_ref) != null or tags.id(.icn) == .yes,
    };

    switch (tags.id(.sidewalk) orelse .unknown) {
        .both, .yes, .shared, .raised => {
            way.flags.sidewalk_left = true;
            way.flags.sidewalk_right = true;
        },
        .left => way.flags.sidewalk_left = true,
        .right => way.flags.sidewalk_right = true,
        else => {},
    }
    way.flags.indoor = tags.id(.indoor) == .yes;
    way.pedestrian = .{
        .sac_scale = if (tags.text(.sac_scale)) |value| try sacScale(value, deadline) else if (tags.id(.highway) == .via_ferrata) .difficult_alpine_hiking else .none,
        .trail_visibility = trailVisibility(tags.id(.trail_visibility)),
        .step_count = try steps(tags, deadline),
        .tactile_paving = tactilePaving(tags.id(.tactile_paving)),
        .foot = tags.text(.foot),
    };
}

pub fn applyNode(node: *attrs.NodeAttrs, tags: *const input.Scratch, deadline: io.Deadline) !void {
    node.step_count = try steps(tags, deadline);
    node.tactile_paving = tactilePaving(tags.id(.tactile_paving));
}
