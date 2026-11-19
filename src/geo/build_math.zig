//! Transcendentals for coordinates written into bundles. Keep the same
//! arithmetic across targets, including on systems with a different libm.
const std = @import("std");

pub const acosF = std.math.acos;
pub const asinF = std.math.asin;
pub const atan2F = std.math.atan2;

/// These inputs are angles in radians bounded by one full revolution.
pub fn sinF(x: f64) f64 {
    return trig(x, false);
}

pub fn cosF(x: f64) f64 {
    return trig(x, true);
}

fn trig(x: f64, comptime cosine: bool) f64 {
    // The leading part has enough trailing zero bits that multiplication
    // by the quadrant is exact. The second part preserves the remainder
    // for angles close to a multiple of pi/2.
    const half_pi_high: f64 = 0x1.921fb54400000p+0;
    const half_pi_low: f64 = std.math.pi / 2.0 - 0x1.921fb54400000p+0;
    const quadrant: i32 = @intFromFloat(@round(x * (2.0 / std.math.pi)));
    const n: f64 = @floatFromInt(quadrant);
    const reduced = (x - n * half_pi_high) - n * half_pi_low;
    return switch (@mod(quadrant + @as(i32, @intFromBool(cosine)), 4)) {
        0 => reduced * series(reduced * reduced, 1),
        1 => series(reduced * reduced, 0),
        2 => -reduced * series(reduced * reduced, 1),
        3 => -series(reduced * reduced, 0),
        else => unreachable,
    };
}

fn series(square: f64, comptime parity: comptime_int) f64 {
    // Taylor series in Horner order on [-pi/4, pi/4]. The first omitted
    // term has magnitude below 3e-18.
    var polynomial: f64 = 0;
    inline for (0..9) |i| {
        const k = 8 - i;
        const coefficient: f64 = comptime blk: {
            var factorial: comptime_int = 1;
            for (1..2 * k + parity + 1) |j| factorial *= j;
            const denominator: f64 = @floatFromInt(factorial);
            break :blk (if (k % 2 == 0) @as(f64, 1) else -1) / denominator;
        };
        polynomial = coefficient + square * polynomial;
    }
    return polynomial;
}

test "portable coordinate trigonometry across quadrants" {
    for (0..4097) |i| {
        const x = (@as(f64, @floatFromInt(i)) / 1024 - 2) * std.math.pi;
        try std.testing.expectApproxEqAbs(@sin(x), sinF(x), 3e-16);
        try std.testing.expectApproxEqAbs(@cos(x), cosF(x), 3e-16);
    }
}
