// Ported from src/meili/transition_cost_model.cc and
// valhalla/meili/transition_cost_model.h (Valhalla 3.9.3).
const std = @import("std");

pub const Options = struct {
    beta: f32 = 3,
    breakage_distance_m: f32 = 2000,
    max_route_distance_factor: f32 = 5,
    max_route_time_factor: f32 = 5,
    turn_penalty_factor: f32 = 200,
};

pub const Limits = struct {
    metres: f32,
    seconds: ?f32,

    pub fn allows(self: Limits, metres: f32, seconds: f32) bool {
        return metres < self.metres and (self.seconds == null or seconds < self.seconds.?);
    }
};

pub const Model = struct {
    options: Options,
    inverse_beta: f32,
    turn_penalties: [181]f32,

    pub fn init(options: Options) !Model {
        if (!std.math.isFinite(options.beta) or options.beta <= 0) return error.InvalidBeta;
        for ([_]f32{ options.breakage_distance_m, options.max_route_distance_factor, options.max_route_time_factor, options.turn_penalty_factor }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidTransitionOption;
        }
        var penalties: [181]f32 = @splat(0);
        if (options.turn_penalty_factor > 0) {
            for (&penalties, 0..) |*penalty, degree| {
                penalty.* = options.turn_penalty_factor * @exp(-@as(f32, @floatFromInt(degree)) / 45);
            }
        }
        return .{
            .options = options,
            .inverse_beta = 1 / options.beta,
            .turn_penalties = penalties,
        };
    }

    pub fn limits(self: *const Model, measurement_distance_m: f32, leave_time: f64, arrival_time: f64) Limits {
        const max_distance = @min(measurement_distance_m * self.options.max_route_distance_factor, self.options.breakage_distance_m);
        const clock_distance: f32 = if (leave_time >= 0 and arrival_time >= 0) @floatCast(arrival_time - leave_time) else -1;
        const max_time = clock_distance * self.options.max_route_time_factor;
        return .{
            .metres = @ceil(@max(max_distance, 1)),
            .seconds = if (max_time < 0) null else @ceil(max_time),
        };
    }

    /// Both headings point away from the intersection. A U-turn has a
    /// small angle between the rays and receives the largest penalty.
    pub fn turnPenalty(self: *const Model, inbound: u16, outbound: u16) f32 {
        const a = inbound % 360;
        const b = outbound % 360;
        const difference = @max(a, b) - @min(a, b);
        return self.turn_penalties[@min(difference, 360 - difference)];
    }

    pub fn cost(self: *const Model, turn_cost: f32, route_distance_m: f32, measurement_distance_m: f32) f32 {
        return (turn_cost + @abs(route_distance_m - measurement_distance_m)) * self.inverse_beta;
    }
};

test "transition uses strict routed limits and the capped distance ratio" {
    const model = try Model.init(.{});
    const limit = model.limits(40.1, 100.25, 105.5);
    try std.testing.expectEqual(@as(f32, 201), limit.metres);
    try std.testing.expectEqual(@as(?f32, 27), limit.seconds);
    try std.testing.expect(limit.allows(200, 26));
    try std.testing.expect(!limit.allows(201, 26));
    try std.testing.expect(!limit.allows(200, 27));
    try std.testing.expectEqual(@as(f32, 2000), model.limits(500, -1, 0).metres);
    try std.testing.expectEqual(@as(f32, 1), model.limits(0, -1, 0).metres);
    try std.testing.expect(model.limits(1, -1, 0).seconds == null);
}

test "transition prices both route distance discrepancies symmetrically" {
    const model = try Model.init(.{ .beta = 2, .turn_penalty_factor = 40 });
    try std.testing.expectEqual(@as(f32, 40), model.turnPenalty(0, 0));
    try std.testing.expectEqual(model.turnPenalty(350, 10), model.turnPenalty(10, 30));
    try std.testing.expectApproxEqAbs(@as(f32, 0.7326256), model.turnPenalty(0, 180), 1e-6);
    try std.testing.expectEqual(@as(f32, 12), model.cost(4, 120, 100));
    try std.testing.expectEqual(@as(f32, 12), model.cost(4, 80, 100));
}
