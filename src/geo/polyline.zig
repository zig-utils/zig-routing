//! Encoded polylines.
//!
//! Ported from valhalla/midgard/encoded.h (Valhalla 3.9.3). Two wire formats:
//!
//! - **polyline** (upstream `encode` / `Shape5Decoder`): Google's printable
//!   format, 5-bit groups offset by 63. API responses use precision 6;
//!   requests may send 5 or 6.
//! - **varint** (upstream `encode7` / `Shape7Decoder`): 7-bit groups, binary.
//!   Used inside graph data. ("7" names the group width, not the digits.)
//!
//! Both store latitude then longitude, as zigzag deltas of values rounded to
//! the chosen precision. Encoders write into a caller buffer with no
//! allocation; decoders are iterators that report malformed input as errors
//! instead of reading past the end.

const std = @import("std");
const point = @import("point.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const PointLL = point.PointLL;
const FixedLL = point.FixedLL;

pub const Error = error{
    /// Input ended in the middle of a value.
    Truncated,
    /// A value had more groups than fit in 32 bits.
    Overflow,
    /// A byte outside the polyline alphabet.
    InvalidCharacter,
    /// A coordinate too large to encode at this precision.
    OutOfRange,
    /// The output buffer is too small (use `maxEncodedLen`).
    NoSpaceLeft,
};

pub const Format = enum { polyline, varint };

/// Multiplier for a number of decimal digits (5, 6 or 7).
pub fn factor(comptime digits: u8) f64 {
    comptime std.debug.assert(digits >= 1 and digits <= 9);
    return comptime std.math.pow(f64, 10, digits);
}

pub fn zigzagEncode(comptime T: type, value: T) @Int(.unsigned, @bitSizeOf(T)) {
    const U = @Int(.unsigned, @bitSizeOf(T));
    return @as(U, @bitCast(value << 1)) ^ @as(U, @bitCast(value >> (@bitSizeOf(T) - 1)));
}

pub fn zigzagDecode(comptime U: type, value: U) @Int(.signed, @bitSizeOf(U)) {
    const S = @Int(.signed, @bitSizeOf(U));
    return @as(S, @bitCast(value >> 1)) ^ -@as(S, @bitCast(value & 1));
}

/// Upper bound on the encoded size of `n` points (a u32 needs at most 7
/// polyline characters or 5 varint bytes; two values per point).
pub fn maxEncodedLen(format: Format, n: usize) usize {
    return n * 2 * @as(usize, if (format == .polyline) 7 else 5);
}

fn writePolylineVarint(out: []u8, pos: *usize, value: u32) Error!void {
    var number = value;
    while (number >= 0x20) {
        if (pos.* >= out.len) return error.NoSpaceLeft;
        out[pos.*] = @intCast((0x20 | (number & 0x1f)) + 63);
        pos.* += 1;
        number >>= 5;
    }
    if (pos.* >= out.len) return error.NoSpaceLeft;
    out[pos.*] = @intCast(number + 63);
    pos.* += 1;
}

fn writeVarint(out: []u8, pos: *usize, value: u32) Error!void {
    var number = value;
    while (number > 0x7f) {
        if (pos.* >= out.len) return error.NoSpaceLeft;
        out[pos.*] = @intCast(0x80 | (number & 0x7f));
        pos.* += 1;
        number >>= 7;
    }
    if (pos.* >= out.len) return error.NoSpaceLeft;
    out[pos.*] = @intCast(number & 0x7f);
    pos.* += 1;
}

/// Encode one E7 shape vertex relative to the previous vertex. Pass zero
/// coordinates as the predecessor of the first vertex.
pub fn encodeFixedVarint(point_ll: FixedLL, previous: FixedLL, out: *[10]u8) []const u8 {
    var pos: usize = 0;
    writeVarint(out, &pos, zigzagEncode(i32, point_ll.lat -% previous.lat)) catch unreachable;
    writeVarint(out, &pos, zigzagEncode(i32, point_ll.lng -% previous.lng)) catch unreachable;
    return out[0..pos];
}

fn toFixed(v: f64, comptime digits: u8) Error!i32 {
    const scaled = @round(v * factor(digits));
    if (!(scaled >= -2147483648.0 and scaled <= 2147483647.0)) return error.OutOfRange;
    return @intFromFloat(scaled);
}

/// Encodes points into `out`; returns the bytes written. Scalar reference
/// implementation, byte-identical to upstream `encode` / `encode7`.
pub fn encodeScalar(comptime format: Format, comptime digits: u8, points: []const PointLL, out: []u8) Error!usize {
    var pos: usize = 0;
    var last_lon: i32 = 0;
    var last_lat: i32 = 0;
    for (points) |p| {
        const lon = try toFixed(p.lng, digits);
        const lat = try toFixed(p.lat, digits);
        const dlat = zigzagEncode(i32, lat -% last_lat);
        const dlon = zigzagEncode(i32, lon -% last_lon);
        if (format == .polyline) {
            try writePolylineVarint(out, &pos, dlat);
            try writePolylineVarint(out, &pos, dlon);
        } else {
            try writeVarint(out, &pos, dlat);
            try writeVarint(out, &pos, dlon);
        }
        last_lon = lon;
        last_lat = lat;
    }
    return pos;
}

/// Encodes points into `out`; returns the bytes written. Rounds and deltas
/// in SIMD batches, then emits groups; output equals `encodeScalar`.
pub fn encode(comptime format: Format, comptime digits: u8, points: []const PointLL, out: []u8) Error!usize {
    return encodeWithDeadline(format, digits, points, out, .none) catch |err| switch (err) {
        error.DeadlineExceeded => unreachable,
        else => |other| return other,
    };
}

pub fn encodeWithDeadline(comptime format: Format, comptime digits: u8, points: []const PointLL, out: []u8, deadline: Deadline) (Error || error{DeadlineExceeded})!usize {
    if (deadline.expired()) return error.DeadlineExceeded;
    const lanes = 8;
    const V = @Vector(lanes, f64);
    const f: V = @splat(factor(digits));
    const lo: V = @splat(-2147483648.0);
    const hi: V = @splat(2147483647.0);
    var pos: usize = 0;
    var last_lon: i32 = 0;
    var last_lat: i32 = 0;
    var i: usize = 0;
    while (i + lanes <= points.len) : (i += lanes) {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        var lngs: V = undefined;
        var lats: V = undefined;
        inline for (0..lanes) |j| {
            lngs[j] = points[i + j].lng;
            lats[j] = points[i + j].lat;
        }
        const slng = @round(lngs * f);
        const slat = @round(lats * f);
        const ok = @reduce(.And, slng >= lo) and @reduce(.And, slng <= hi) and @reduce(.And, slat >= lo) and @reduce(.And, slat <= hi);
        if (!ok) return error.OutOfRange; // also catches NaN
        const ilng: @Vector(lanes, i32) = @intFromFloat(slng);
        const ilat: @Vector(lanes, i32) = @intFromFloat(slat);
        var prev_lng: @Vector(lanes, i32) = std.simd.shiftElementsRight(ilng, 1, last_lon);
        var prev_lat: @Vector(lanes, i32) = std.simd.shiftElementsRight(ilat, 1, last_lat);
        _ = &prev_lng;
        _ = &prev_lat;
        const dlng = ilng -% prev_lng;
        const dlat = ilat -% prev_lat;
        const one: @Vector(lanes, u5) = @splat(1);
        const sign: @Vector(lanes, u5) = @splat(31);
        const zlng: @Vector(lanes, u32) = @as(@Vector(lanes, u32), @bitCast(dlng << one)) ^ @as(@Vector(lanes, u32), @bitCast(dlng >> sign));
        const zlat: @Vector(lanes, u32) = @as(@Vector(lanes, u32), @bitCast(dlat << one)) ^ @as(@Vector(lanes, u32), @bitCast(dlat >> sign));
        inline for (0..lanes) |j| {
            if (format == .polyline) {
                try writePolylineVarint(out, &pos, zlat[j]);
                try writePolylineVarint(out, &pos, zlng[j]);
            } else {
                try writeVarint(out, &pos, zlat[j]);
                try writeVarint(out, &pos, zlng[j]);
            }
        }
        last_lon = ilng[lanes - 1];
        last_lat = ilat[lanes - 1];
    }
    while (i < points.len) : (i += 1) {
        const lon = try toFixed(points[i].lng, digits);
        const lat = try toFixed(points[i].lat, digits);
        const dlat = zigzagEncode(i32, lat -% last_lat);
        const dlon = zigzagEncode(i32, lon -% last_lon);
        if (format == .polyline) {
            try writePolylineVarint(out, &pos, dlat);
            try writePolylineVarint(out, &pos, dlon);
        } else {
            try writeVarint(out, &pos, dlat);
            try writeVarint(out, &pos, dlon);
        }
        last_lon = lon;
        last_lat = lat;
    }
    return pos;
}

/// Encodes into newly allocated memory (sized exactly).
pub fn encodeAlloc(gpa: std.mem.Allocator, comptime format: Format, comptime digits: u8, points: []const PointLL) (Error || error{OutOfMemory})![]u8 {
    const buf = try gpa.alloc(u8, maxEncodedLen(format, points.len));
    errdefer gpa.free(buf);
    const n = try encode(format, digits, points, buf);
    return gpa.realloc(buf, n);
}

/// Iterates the points of an encoded line.
pub fn Decoder(comptime format: Format) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        pos: usize = 0,
        lat: i32 = 0,
        lon: i32 = 0,
        precision: f64,

        pub fn init(bytes: []const u8, comptime digits: u8) Self {
            return .{ .bytes = bytes, .precision = 1.0 / factor(digits) };
        }

        /// Runtime precision (the decode multiplier, for example 1e-6).
        pub fn initPrecision(bytes: []const u8, precision: f64) Self {
            return .{ .bytes = bytes, .precision = precision };
        }

        pub fn empty(self: *const Self) bool {
            return self.pos >= self.bytes.len;
        }

        fn readVarint(self: *Self) Error!u32 {
            var result: u32 = 0;
            var shift: u32 = 0;
            while (true) {
                if (self.pos >= self.bytes.len) return error.Truncated;
                const byte = self.bytes[self.pos];
                self.pos += 1;
                if (format == .polyline) {
                    if (byte < 63 or byte > 126) return error.InvalidCharacter;
                    const chunk: u32 = byte - 63;
                    const group = chunk & 0x1f;
                    if (shift >= 32 or group > @as(u32, std.math.maxInt(u32)) >> @as(u5, @intCast(shift))) return error.Overflow;
                    result |= group << @intCast(shift);
                    shift += 5;
                    if (chunk < 0x20) return result;
                } else {
                    const group = @as(u32, byte) & 0x7f;
                    if (shift >= 32 or group > @as(u32, std.math.maxInt(u32)) >> @as(u5, @intCast(shift))) return error.Overflow;
                    result |= group << @intCast(shift);
                    shift += 7;
                    if (byte & 0x80 == 0) return result;
                }
            }
        }

        /// Decode a vertex at the encoded integer precision.
        pub fn nextFixed(self: *Self) Error!?FixedLL {
            if (self.empty()) return null;
            const dlat = try self.readVarint();
            const dlon = try self.readVarint();
            self.lat +%= zigzagDecode(u32, dlat);
            self.lon +%= zigzagDecode(u32, dlon);
            return .{ .lng = self.lon, .lat = self.lat };
        }

        pub fn next(self: *Self) Error!?PointLL {
            const fixed = (try self.nextFixed()) orelse return null;
            return .{ .lng = @as(f64, @floatFromInt(fixed.lng)) * self.precision, .lat = @as(f64, @floatFromInt(fixed.lat)) * self.precision };
        }
    };
}

/// Decodes a whole line into newly allocated memory.
pub fn decodeAlloc(gpa: std.mem.Allocator, comptime format: Format, comptime digits: u8, bytes: []const u8) (Error || error{OutOfMemory})![]PointLL {
    var list: std.ArrayList(PointLL) = .empty;
    errdefer list.deinit(gpa);
    try list.ensureTotalCapacity(gpa, bytes.len / 4);
    var d = Decoder(format).init(bytes, digits);
    while (try d.next()) |p| try list.append(gpa, p);
    return list.toOwnedSlice(gpa);
}

/// Delta + zigzag + varint for an integer sequence (upstream encode7int).
pub fn encodeInts(comptime T: type, values: []const T, out: []u8) Error!usize {
    const S = @Int(.signed, @bitSizeOf(T));
    const U = @Int(.unsigned, @bitSizeOf(T));
    var pos: usize = 0;
    var last: T = 0;
    for (values) |value| {
        const diff: S = @bitCast(value -% last);
        var number: U = zigzagEncode(S, diff);
        while (number > 0x7f) {
            if (pos >= out.len) return error.NoSpaceLeft;
            out[pos] = @intCast(0x80 | (number & 0x7f));
            pos += 1;
            number >>= 7;
        }
        if (pos >= out.len) return error.NoSpaceLeft;
        out[pos] = @intCast(number);
        pos += 1;
        last = value;
    }
    return pos;
}

/// Iterates an integer sequence written by `encodeInts` (upstream Int7Decoder).
pub fn IntDecoder(comptime T: type) type {
    return struct {
        const Self = @This();
        const U = @Int(.unsigned, @bitSizeOf(T));

        bytes: []const u8,
        pos: usize = 0,
        value: T = 0,

        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        pub fn next(self: *Self) Error!?T {
            const delta = (try self.nextDelta()) orelse return null;
            self.value +%= delta;
            return self.value;
        }

        pub fn nextDelta(self: *Self) Error!?T {
            if (self.pos >= self.bytes.len) return null;
            var result: U = 0;
            var shift: u32 = 0;
            while (true) {
                if (self.pos >= self.bytes.len) return error.Truncated;
                const byte = self.bytes[self.pos];
                self.pos += 1;
                const group = std.math.cast(U, byte & 0x7f) orelse return error.Overflow;
                if (shift >= @bitSizeOf(U) or group > @as(U, std.math.maxInt(U)) >> @intCast(shift)) return error.Overflow;
                result |= group << @intCast(shift);
                shift += 7;
                if (byte & 0x80 == 0) break;
            }
            return @bitCast(zigzagDecode(U, result));
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: ported from test/encode.cc
// ---------------------------------------------------------------------------

const testing = std.testing;

fn P(lng: f64, lat: f64) PointLL {
    return .{ .lng = lng, .lat = lat };
}

fn expectRoundTrip(comptime digits: u8, points: []const PointLL, encoded: []const u8, eps: f64) !void {
    var buf: [4096]u8 = undefined;
    const n = try encode(.polyline, digits, points, &buf);
    try testing.expectEqualStrings(encoded, buf[0..n]);
    const m = try encodeScalar(.polyline, digits, points, &buf);
    try testing.expectEqualStrings(encoded, buf[0..m]);
    const back = try decodeAlloc(testing.allocator, .polyline, digits, encoded);
    defer testing.allocator.free(back);
    try testing.expectEqual(points.len, back.len);
    for (points, back) |a, b| {
        try testing.expectApproxEqAbs(a.lng, b.lng, eps);
        try testing.expectApproxEqAbs(a.lat, b.lat, eps);
    }
}

test "polyline precision 5 (upstream Encode.Polyline5)" {
    var buf: [64]u8 = undefined;
    const n = try encode(.polyline, 5, &.{ P(-76.3002, 40.0433), P(-76.3036, 40.043) }, &buf);
    try testing.expectEqualStrings("s}ksFfkupMz@fT", buf[0..n]);
    try expectRoundTrip(5, &.{ P(41.37084, -5.03016), P(76.8342, 42.01251) }, "nmu]wfo{Fu_c~G_mmwE", 0.00005);
    try expectRoundTrip(5, &.{
        P(-9.42372, 152.03805),  P(-1.82375, 116.05687),  P(-71.41203, -66.66489),
        P(65.64729, 68.17239),   P(34.2284, -77.90916),   P(-72.90402, -47.25247),
        P(-78.55439, -25.28158), P(-31.92992, 103.20477), P(58.26482, -169.02219),
    }, "y|}~[fqox@jqrzEyjkm@~yfza@vmvgL_l~uXwkpcYtprzZ`ow~DisbzDrh{lSaebeCxqna@u~eoW}iq{Gnip|r@cdoeP", 0.00005);
}

test "polyline precision 6 (upstream Encode.Polyline)" {
    var buf: [64]u8 = undefined;
    const n = try encode(.polyline, 6, &.{ P(-76.3002, 40.0433), P(-76.3036, 40.043) }, &buf);
    try testing.expectEqualStrings("gq`kkAny~opCvQnsE", buf[0..n]);
    try expectRoundTrip(6, &.{ P(41.37084, -5.03016), P(76.8342, 42.01251) }, "~o_rHola|mA{egvxA_kosbA", 0.00001);
    try expectRoundTrip(6, &.{
        P(-15.14467, 95.09918),   P(-0.52122, -136.82914),  P(65.10222, 77.44049),
        P(-69.52769, -130.85075), P(46.36195, -33.8091),    P(4.62432, -55.24198),
        P(-85.23295, 56.73264),   P(-34.87542, -148.58007), P(-88.75693, 73.15576),
        P(14.66023, -174.40911),  P(-17.84068, 133.05384),  P(74.64337, -148.80224),
        P(-61.31799, -145.47643), P(45.99419, 133.9817),    P(34.77185, -75.40288),
        P(35.42642, -167.09832),  P(84.2264, -103.19799),
    }, "wqkktDzlj{[~~wjyLslp{Z{j~twK_xid|BnyahlKj`dx_Gcn}axDo}i`|E~ad{g@zxmrnAwlkqtEjnmkjDjkhrfKspq`_Bkxt|eLjitweBjcdewMosagdEkq`miQziu~|@~ccrxOc|wkoDcv~iE~olibGctw_tOgbytkEfgyjnKfs}kT~ss{mDsm}f@sid{xBwmoa|A", 0.00001);
}

test "varint format round-trips (upstream do_varint_pair)" {
    const pts = [_]PointLL{ P(-76.3002, 40.0433), P(-76.3036, 40.043), P(8.5417, 47.3769), P(-122.4194, 37.7749) };
    var buf: [128]u8 = undefined;
    const n = try encode(.varint, 7, &pts, &buf);
    try testing.expectEqual(n, try encodeScalar(.varint, 7, &pts, buf[64..]));
    var d = Decoder(.varint).init(buf[0..n], 7);
    for (pts) |p| {
        const q = (try d.next()).?;
        try testing.expectApproxEqAbs(p.lng, q.lng, 1e-7);
        try testing.expectApproxEqAbs(p.lat, q.lat, 1e-7);
    }
    try testing.expectEqual(@as(?PointLL, null), try d.next());
}

test "integer sequences (upstream encode7int / Int7Decoder)" {
    const values = [_]i64{ 0, 5, -3, 1 << 40, 7, -(1 << 50) };
    var buf: [128]u8 = undefined;
    const n = try encodeInts(i64, &values, &buf);
    var d = IntDecoder(i64).init(buf[0..n]);
    for (values) |v| try testing.expectEqual(v, (try d.next()).?);
    try testing.expectEqual(@as(?i64, null), try d.next());
}

test "zigzag" {
    try testing.expectEqual(@as(u32, 0), zigzagEncode(i32, 0));
    try testing.expectEqual(@as(u32, 1), zigzagEncode(i32, -1));
    try testing.expectEqual(@as(u32, 2), zigzagEncode(i32, 1));
    try testing.expectEqual(@as(u32, 0xffffffff), zigzagEncode(i32, std.math.minInt(i32)));
    for ([_]i32{ 0, 1, -1, 12345, -12345, std.math.maxInt(i32), std.math.minInt(i32) }) |v|
        try testing.expectEqual(v, zigzagDecode(u32, zigzagEncode(i32, v)));
}

test "malformed input returns errors" {
    var d = Decoder(.polyline).init("_", 6); // continuation bit set, then end
    try testing.expectError(error.Truncated, d.next());
    var bad = Decoder(.polyline).init("\x01\x02", 6);
    try testing.expectError(error.InvalidCharacter, bad.next());
    var long = Decoder(.varint).init("\xff\xff\xff\xff\xff\xff\xff\x01", 7);
    try testing.expectError(error.Overflow, long.next());
    var half = Decoder(.polyline).init("?", 6); // one value, missing the longitude
    try testing.expectError(error.Truncated, half.next());
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, encode(.polyline, 6, &.{P(-76.3, 40.0)}, &buf));
    try testing.expectError(error.OutOfRange, encode(.polyline, 7, &.{P(400, 0)}, buf[0..0]));
}

test "SIMD and scalar encoders agree on random lines" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var pts: [257]PointLL = undefined;
    var a: [maxEncodedLenStatic(257)]u8 = undefined;
    var b: [maxEncodedLenStatic(257)]u8 = undefined;
    for (0..400) |_| {
        const len = r.uintLessThan(usize, pts.len + 1);
        var lng = r.float(f64) * 360 - 180;
        var lat = r.float(f64) * 180 - 90;
        for (pts[0..len]) |*p| {
            lng = std.math.clamp(lng + (r.float(f64) - 0.5) * 0.01, -180, 180);
            lat = std.math.clamp(lat + (r.float(f64) - 0.5) * 0.01, -90, 90);
            p.* = P(lng, lat);
        }
        inline for (.{ Format.polyline, Format.varint }) |fmt| {
            const n = try encode(fmt, 6, pts[0..len], &a);
            const m = try encodeScalar(fmt, 6, pts[0..len], &b);
            try testing.expectEqualSlices(u8, b[0..m], a[0..n]);
        }
    }
}

fn maxEncodedLenStatic(comptime n: usize) usize {
    return n * 2 * 7;
}

test "decoder never reads out of bounds on random bytes" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var bytes: [64]u8 = undefined;
    for (0..5000) |_| {
        const len = r.uintLessThan(usize, bytes.len);
        r.bytes(bytes[0..len]);
        inline for (.{ Format.polyline, Format.varint }) |fmt| {
            var d = Decoder(fmt).init(bytes[0..len], 6);
            while (true) {
                const p = d.next() catch break;
                if (p == null) break;
            }
        }
    }
}
