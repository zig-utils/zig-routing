// Ported from valhalla/meili/emission_cost_model.h (Valhalla 3.9.3).
const std = @import("std");

pub const Model = struct {
    inverse_variance: f64,

    pub const default_sigma_z: f32 = 4.07;

    pub fn init(sigma_z: f32) !Model {
        if (!std.math.isFinite(sigma_z) or sigma_z <= 0) return error.InvalidSigmaZ;
        const inverse: f32 = 1 / (sigma_z * sigma_z * 2);
        return .{ .inverse_variance = inverse };
    }

    /// GPS accuracy controls the candidate radius. The squared distance in
    /// the resulting candidate is rounded to the upstream float field.
    pub fn cost(self: Model, squared_distance: f64) f32 {
        const distance: f32 = @floatCast(squared_distance);
        return @floatCast(@as(f64, distance) * self.inverse_variance);
    }
};

test "emission penalizes the squared candidate distance" {
    const model = try Model.init(4);
    try std.testing.expectEqual(@as(f32, 0), model.cost(0));
    try std.testing.expectEqual(@as(f32, 2), model.cost(64));
    try std.testing.expectEqual(@as(f32, 8), model.cost(256));
    try std.testing.expectError(error.InvalidSigmaZ, Model.init(0));
}
