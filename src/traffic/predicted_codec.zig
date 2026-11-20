// Ported from src/baldr/predictedspeeds.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");

pub const bucket_seconds = 300;
pub const bucket_count = 2016;
pub const coefficient_count = 200;
pub const Profile = [coefficient_count]i16;
pub const encoded_size = std.base64.standard.Encoder.calcSize(@sizeOf(Profile));

const lanes = 8;
const Floats = @Vector(lanes, f32);
const Shorts = @Vector(lanes, i16);
const Ints = @Vector(lanes, i32);
const Longs = @Vector(lanes, i64);
const normalization: f32 = 0.031497039;
const dc_scale: f32 = 0.707106781;
const angle: f32 = @as(f32, std.math.pi) / bucket_count;
const q15_scale = 32767;
const lane_l1_limit = std.math.maxInt(i32) / q15_scale;
const Basis = [bucket_count][coefficient_count]f32;
const FixedBasis = [bucket_count]Profile;

var basis: Basis align(64) = undefined;
var fixed_basis: FixedBasis align(64) = undefined;
var initialized: std.atomic.Value(bool) = .init(false);
var initialize_lock: io.Mutex = .{};

pub const StoredProfile = extern struct {
    coefficients: Profile,
    flags: packed struct(u32) {
        fixed: bool,
        reserved: u31 = 0,
    },

    pub fn init(profile: Profile) StoredProfile {
        return .{ .coefficients = profile, .flags = .{ .fixed = safeFixed(&profile) } };
    }

    pub fn valid(self: *const StoredProfile) bool {
        return self.flags.reserved == 0 and self.flags.fixed == safeFixed(&self.coefficients);
    }
};

comptime {
    std.debug.assert(@sizeOf(StoredProfile) == 404 and @alignOf(StoredProfile) == 4);
    std.debug.assert(@offsetOf(StoredProfile, "coefficients") == 0 and @offsetOf(StoredProfile, "flags") == 400);
}

// Q15 rounding adds at most one half-unit per product. With this bound
// each SIMD lane fits in i32, and the total projection error is under
// 0.253 kph before the final float rounding. Wider inputs use f32.
fn safeFixed(profile: *const Profile) bool {
    var magnitudes: [lanes]u32 = @splat(0);
    for (profile, 0..) |value, i| magnitudes[i % lanes] += @abs(value);
    for (magnitudes) |magnitude| {
        if (magnitude > lane_l1_limit) return false;
    }
    return true;
}

pub const Codec = struct {
    weights: *const Basis,
    fixed_weights: *const FixedBasis,

    /// Build the shared basis on startup, before the codec enters a read loop.
    pub fn init(deadline: io.Deadline) !Codec {
        if (!initialized.load(.acquire)) {
            initialize_lock.lock();
            defer initialize_lock.unlock();
            if (!initialized.load(.monotonic)) {
                for (&basis, &fixed_basis, 0..) |*row, *fixed_row, bucket| {
                    if (deadline.expired()) return error.DeadlineExceeded;
                    const theta = angle * (@as(f32, @floatFromInt(bucket)) + 0.5);
                    row[0] = dc_scale;
                    for (row[1..], 1..) |*weight, c| weight.* = @cos(theta * @as(f32, @floatFromInt(c)));
                    for (row, fixed_row) |weight, *fixed| fixed.* = @intFromFloat(@round(weight * q15_scale));
                }
                initialized.store(true, .release);
            }
        }
        return .{ .weights = &basis, .fixed_weights = &fixed_basis };
    }

    pub fn compress(self: Codec, speeds: *const [bucket_count]f32, deadline: io.Deadline) !Profile {
        var sums: [coefficient_count / lanes]Floats = @splat(@splat(0));
        for (speeds, self.weights, 0..) |kph, *row, bucket| {
            if (bucket % 32 == 0 and deadline.expired()) return error.DeadlineExceeded;
            if (!std.math.isFinite(kph) or kph < 0 or kph > 252) return error.InvalidPredictedSpeed;
            const values: Floats = @splat(kph);
            for (&sums, 0..) |*sum, i| {
                const weights: Floats = row[i * lanes ..][0..lanes].*;
                sum.* = @mulAdd(Floats, weights, values, sum.*);
            }
        }
        var out: Profile = undefined;
        const scale: Floats = @splat(normalization);
        for (sums, 0..) |sum, i| {
            const packed_values: Shorts = @intFromFloat(@round(sum * scale));
            out[i * lanes ..][0..lanes].* = packed_values;
        }
        return out;
    }

    pub fn speed(self: Codec, profile: *const StoredProfile, seconds_of_week: u64) f32 {
        const bucket = (seconds_of_week / bucket_seconds) % bucket_count;
        return self.decodeBucket(profile, @intCast(bucket));
    }

    pub inline fn decodeBucket(self: Codec, profile: *const StoredProfile, bucket: u11) f32 {
        std.debug.assert(bucket < bucket_count);
        return if (profile.flags.fixed)
            self.decodeFixed(&profile.coefficients, bucket)
        else
            self.decodeFloat(&profile.coefficients, bucket);
    }

    inline fn decodeFixed(self: Codec, profile: *const Profile, bucket: u11) f32 {
        const row = &self.fixed_weights[bucket];
        const accumulators = 5;
        var sums: [accumulators]Ints = @splat(@splat(0));
        for (0..coefficient_count / (lanes * accumulators)) |i| {
            inline for (0..accumulators) |j| {
                const index = (i * accumulators + j) * lanes;
                const weights: Shorts = row[index..][0..lanes].*;
                const raw: Shorts = profile[index..][0..lanes].*;
                sums[j] += @as(Ints, weights) * @as(Ints, raw);
            }
        }
        var sum: Ints = @splat(0);
        inline for (sums) |accumulator| sum += accumulator;
        return @as(f32, @floatFromInt(@reduce(.Add, @as(Longs, sum)))) * (normalization / q15_scale);
    }

    fn decodeFloat(self: Codec, profile: *const Profile, bucket: u11) f32 {
        const row = &self.weights[bucket];
        const accumulators = 5;
        comptime std.debug.assert(coefficient_count % (lanes * accumulators) == 0);
        var sums: [accumulators]Floats = @splat(@splat(0));
        for (0..coefficient_count / (lanes * accumulators)) |i| {
            inline for (0..accumulators) |j| {
                const index = (i * accumulators + j) * lanes;
                const weights: Floats = row[index..][0..lanes].*;
                const raw: Shorts = profile[index..][0..lanes].*;
                sums[j] = @mulAdd(Floats, weights, @as(Floats, @floatFromInt(raw)), sums[j]);
            }
        }
        var sum: Floats = @splat(0);
        inline for (sums) |accumulator| sum += accumulator;
        return @reduce(.Add, sum) * normalization;
    }
};

pub fn encode(profile: *const Profile, buffer: *[encoded_size]u8) []const u8 {
    var bytes: [@sizeOf(Profile)]u8 = undefined;
    for (profile, 0..) |coefficient, i| std.mem.writeInt(i16, bytes[2 * i ..][0..2], coefficient, .big);
    return std.base64.standard.Encoder.encode(buffer, &bytes);
}

pub fn decode(input: []const u8, deadline: io.Deadline) !Profile {
    var encoded: [encoded_size]u8 = undefined;
    var n: usize = 0;
    for (input, 0..) |byte, i| {
        if (i % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (std.ascii.isWhitespace(byte)) continue;
        if (n == encoded.len) return error.InvalidPredictedProfile;
        encoded[n] = byte;
        n += 1;
    }
    // The reference accepts omitted padding on its standard base64 alphabet.
    const unpadded_size = comptime std.base64.standard_no_pad.Encoder.calcSize(@sizeOf(Profile));
    const decoder = switch (n) {
        encoded_size => std.base64.standard.Decoder,
        unpadded_size => std.base64.standard_no_pad.Decoder,
        else => return error.InvalidPredictedProfile,
    };
    const size = decoder.calcSizeForSlice(encoded[0..n]) catch return error.InvalidPredictedProfile;
    if (size != @sizeOf(Profile)) return error.InvalidPredictedProfile;
    var bytes: [@sizeOf(Profile)]u8 = undefined;
    decoder.decode(&bytes, encoded[0..n]) catch return error.InvalidPredictedProfile;
    var profile: Profile = undefined;
    for (&profile, 0..) |*coefficient, i| coefficient.* = std.mem.readInt(i16, bytes[2 * i ..][0..2], .big);
    return profile;
}

test "400 signed network-order bytes round trip as Valhalla base64" {
    var profile: Profile = @splat(0);
    profile[0] = -32768;
    profile[1] = 32767;
    profile[coefficient_count - 1] = -2026;
    var data: [encoded_size]u8 = undefined;
    const encoded = encode(&profile, &data);
    try std.testing.expectEqualStrings("gAB//w", encoded[0..6]);
    try std.testing.expectEqual(profile, try decode(encoded, .none));
    try std.testing.expectEqual(profile, try decode(encoded[0 .. encoded.len - 2], .none));
    try std.testing.expectError(error.InvalidPredictedProfile, decode(encoded[0 .. encoded.len - 3], .none));
}

test "SIMD decoder matches scalar Valhalla DCT-III for every weekly bucket" {
    const codec = try Codec.init(.none);
    var profile: Profile = undefined;
    profile[0] = 2245;
    for (profile[1..], 1..) |*value, i| value.* = @as(i16, @intCast((i * 29 + 31) % 227)) - 112;
    const stored = StoredProfile.init(profile);
    try std.testing.expect(stored.flags.fixed and stored.valid());
    for (0..bucket_count) |bucket| {
        const theta = angle * (@as(f32, @floatFromInt(bucket)) + 0.5);
        var sum = @as(f32, @floatFromInt(profile[0])) * dc_scale;
        for (profile[1..], 1..) |value, i| {
            sum += @as(f32, @floatFromInt(value)) * @cos(theta * @as(f32, @floatFromInt(i)));
        }
        const seconds = bucket * bucket_seconds + 299;
        try std.testing.expectApproxEqAbs(sum * normalization, codec.speed(&stored, seconds), 1);
        try std.testing.expectEqual(codec.speed(&stored, seconds), codec.speed(&stored, seconds + bucket_count * bucket_seconds));
    }
}

test "SIMD DCT-II keeps a constant weekly speed in the DC coefficient" {
    const codec = try Codec.init(.none);
    const profile = try codec.compress(&@as([bucket_count]f32, @splat(70)), .none);
    try std.testing.expectEqual(@as(i16, 3143), profile[0]);
    for (profile[1..]) |value| try std.testing.expectEqual(@as(i16, 0), value);
    const stored = StoredProfile.init(profile);
    for (0..bucket_count) |bucket| try std.testing.expectApproxEqAbs(@as(f32, 70), codec.decodeBucket(&stored, @intCast(bucket)), 0.02);
}

test "profiles above the fixed-point lane bound use the floating-point projection" {
    const codec = try Codec.init(.none);
    var profile: Profile = undefined;
    for (&profile, 0..) |*value, i| value.* = if (i % 3 == 0) std.math.minInt(i16) else std.math.maxInt(i16);
    const stored = StoredProfile.init(profile);
    try std.testing.expect(!stored.flags.fixed and stored.valid());
    for (0..bucket_count) |bucket| {
        const row = &codec.weights[bucket];
        var total: f64 = 0;
        for (profile, row) |value, weight| total += @as(f64, @floatFromInt(value)) * weight;
        const expected: f32 = @floatCast(total * normalization);
        try std.testing.expectApproxEqAbs(expected, codec.decodeBucket(&stored, @intCast(bucket)), 1);
    }
}
