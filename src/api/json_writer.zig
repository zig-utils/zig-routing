//! Streaming JSON writer.
//!
//! Byte-compatible with the writer Valhalla uses (`baldr::rapidjson::
//! writer_wrapper_t` over rapidjson's `Writer`): compact output, commas
//! handled automatically, strings escaped the same way (`\"`, `\\`, the
//! short control escapes, other control bytes as `\u00XX` with uppercase hex,
//! UTF-8 passed through), and doubles printed with rapidjson's Grisu2 +
//! Prettify, including `SetMaxDecimalPlaces`, which *truncates* extra
//! decimals and trims trailing zeros (so 1.2345 at 3 places is "1.234").
//!
//! The Grisu2 digit generation and cached powers are ported from rapidjson
//! (MIT, THL A29 Limited / Milo Yip), `include/rapidjson/internal/dtoa.h`
//! and `diyfp.h`.
//!
//! Output goes into a `std.ArrayList(u8)` grown with the request arena, so
//! steady-state serialization performs no heap allocation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_depth = 64;

pub const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    /// Decimal places kept by `float` (rapidjson default is 324, i.e. all).
    max_decimals: u16 = 324,
    depth: u8 = 0,
    /// Per level: has a value been written (so the next one needs a comma)?
    has_value: std.bit_set.IntegerBitSet(max_depth) = .empty,
    /// The next value completes a key/value pair (no comma before it).
    after_key: bool = false,

    pub fn init(gpa: Allocator, out: *std.ArrayList(u8)) Writer {
        return .{ .out = out, .gpa = gpa };
    }

    pub fn setPrecision(self: *Writer, decimals: u16) void {
        std.debug.assert(decimals >= 1);
        self.max_decimals = decimals;
    }

    fn prefix(self: *Writer) Allocator.Error!void {
        if (self.after_key) {
            self.after_key = false;
            return;
        }
        if (self.depth > 0) {
            if (self.has_value.isSet(self.depth)) try self.out.append(self.gpa, ',');
            self.has_value.set(self.depth);
        }
    }

    pub fn beginObject(self: *Writer) Allocator.Error!void {
        try self.prefix();
        try self.out.append(self.gpa, '{');
        self.push();
    }

    pub fn endObject(self: *Writer) Allocator.Error!void {
        self.pop();
        try self.out.append(self.gpa, '}');
    }

    pub fn beginArray(self: *Writer) Allocator.Error!void {
        try self.prefix();
        try self.out.append(self.gpa, '[');
        self.push();
    }

    pub fn endArray(self: *Writer) Allocator.Error!void {
        self.pop();
        try self.out.append(self.gpa, ']');
    }

    fn push(self: *Writer) void {
        std.debug.assert(self.depth + 1 < max_depth);
        self.depth += 1;
        self.has_value.unset(self.depth);
    }

    fn pop(self: *Writer) void {
        std.debug.assert(self.depth > 0 and !self.after_key);
        self.depth -= 1;
    }

    /// Writes an object key; the next call writes its value.
    pub fn key(self: *Writer, name: []const u8) Allocator.Error!void {
        std.debug.assert(!self.after_key);
        try self.prefix();
        try writeString(self.out, self.gpa, name);
        try self.out.append(self.gpa, ':');
        self.after_key = true;
    }

    pub fn beginObjectField(self: *Writer, name: []const u8) Allocator.Error!void {
        try self.key(name);
        try self.beginObject();
    }

    pub fn beginArrayField(self: *Writer, name: []const u8) Allocator.Error!void {
        try self.key(name);
        try self.beginArray();
    }

    pub fn string(self: *Writer, s: []const u8) Allocator.Error!void {
        try self.prefix();
        try writeString(self.out, self.gpa, s);
    }

    pub fn int(self: *Writer, v: i64) Allocator.Error!void {
        try self.prefix();
        var buf: [24]u8 = undefined;
        try self.out.appendSlice(self.gpa, formatInt(v, &buf));
    }

    pub fn uint(self: *Writer, v: u64) Allocator.Error!void {
        try self.prefix();
        var buf: [24]u8 = undefined;
        try self.out.appendSlice(self.gpa, formatUint(v, &buf));
    }

    /// Opens a value the caller writes straight into `out` (for arrays of
    /// many small items written in one loop): emits the separator and
    /// returns the buffer. The caller writes exactly one JSON value.
    pub fn rawValue(self: *Writer) Allocator.Error!*std.ArrayList(u8) {
        try self.prefix();
        return self.out;
    }

    pub fn boolean(self: *Writer, v: bool) Allocator.Error!void {
        try self.prefix();
        try self.out.appendSlice(self.gpa, if (v) "true" else "false");
    }

    pub fn null_(self: *Writer) Allocator.Error!void {
        try self.prefix();
        try self.out.appendSlice(self.gpa, "null");
    }

    /// A double as rapidjson writes it at the current precision. NaN is
    /// written as null (as the keyed form of upstream's wrapper does);
    /// infinities as null too, since rapidjson refuses to write them.
    pub fn float(self: *Writer, v: f64) Allocator.Error!void {
        try self.prefix();
        if (!std.math.isFinite(v)) return self.out.appendSlice(self.gpa, "null");
        var buf: [40]u8 = undefined;
        try self.out.appendSlice(self.gpa, dtoa(v, &buf, self.max_decimals));
    }

    /// Splices pre-encoded JSON (for example a quoted polyline) as a value.
    pub fn raw(self: *Writer, fragment: []const u8) Allocator.Error!void {
        try self.prefix();
        try self.out.appendSlice(self.gpa, fragment);
    }

    /// A key known at compile time (all of upstream's are) and its value.
    /// The quoted, escaped key is built at compile time.
    pub fn field(self: *Writer, comptime name: []const u8, v: anytype) Allocator.Error!void {
        std.debug.assert(!self.after_key);
        try self.prefix();
        try self.out.appendSlice(self.gpa, comptime quotedKey(name));
        self.after_key = true;
        try self.value(v);
    }

    /// Writes a value chosen by type, like the wrapper's operator().
    pub fn value(self: *Writer, v: anytype) Allocator.Error!void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .int, .comptime_int => if (@typeInfo(@TypeOf(v)) == .comptime_int or @typeInfo(T).int.signedness == .signed) try self.int(@intCast(v)) else try self.uint(@intCast(v)),
            .float, .comptime_float => try self.float(@floatCast(v)),
            .bool => try self.boolean(v),
            .null => try self.null_(),
            .optional => if (v) |inner| try self.value(inner) else try self.null_(),
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return self.string(v);
                if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return self.string(v);
                @compileError("unsupported JSON value type " ++ @typeName(T));
            },
            else => @compileError("unsupported JSON value type " ++ @typeName(T)),
        }
    }
};

const escape_table = blk: {
    var t: [256]u8 = @splat(0);
    for (0..0x20) |c| t[c] = 'u';
    t['\x08'] = 'b';
    t['\t'] = 't';
    t['\n'] = 'n';
    t['\x0c'] = 'f';
    t['\r'] = 'r';
    t['"'] = '"';
    t['\\'] = '\\';
    break :blk t;
};

/// Quotes and escapes `s` as rapidjson's Writer::String does.
pub fn writeString(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.ensureUnusedCapacity(gpa, s.len + 2);
    out.appendAssumeCapacity('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const e = escape_table[c];
        if (e == 0) continue;
        try out.appendSlice(gpa, s[start..i]);
        if (e == 'u') {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(gpa, &.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] });
        } else {
            try out.appendSlice(gpa, &.{ '\\', e });
        }
        start = i + 1;
    }
    try out.appendSlice(gpa, s[start..]);
    try out.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// rapidjson dtoa: Grisu2 + Prettify
// ---------------------------------------------------------------------------

const DiyFp = struct {
    f: u64,
    e: i32,

    const significand_size = 52;
    const exponent_bias = 0x3FF + significand_size;
    const min_exponent = -exponent_bias;
    const hidden_bit: u64 = 0x0010000000000000;
    const significand_mask: u64 = 0x000FFFFFFFFFFFFF;
    const exponent_mask: u64 = 0x7FF0000000000000;

    fn fromDouble(d: f64) DiyFp {
        const u: u64 = @bitCast(d);
        const biased_e: i32 = @intCast((u & exponent_mask) >> significand_size);
        const significand = u & significand_mask;
        if (biased_e != 0) return .{ .f = significand + hidden_bit, .e = biased_e - exponent_bias };
        return .{ .f = significand, .e = min_exponent + 1 };
    }

    fn sub(a: DiyFp, b: DiyFp) DiyFp {
        return .{ .f = a.f - b.f, .e = a.e };
    }

    fn mul(a: DiyFp, b: DiyFp) DiyFp {
        const p = @as(u128, a.f) * @as(u128, b.f);
        var h: u64 = @truncate(p >> 64);
        const l: u64 = @truncate(p);
        if (l & (@as(u64, 1) << 63) != 0) h += 1;
        return .{ .f = h, .e = a.e + b.e + 64 };
    }

    fn normalize(self: DiyFp) DiyFp {
        const s: u6 = @intCast(@clz(self.f));
        return .{ .f = self.f << s, .e = self.e - s };
    }

    fn normalizeBoundary(self: DiyFp) DiyFp {
        var res = self;
        while (res.f & (hidden_bit << 1) == 0) {
            res.f <<= 1;
            res.e -= 1;
        }
        res.f <<= 64 - significand_size - 2;
        res.e -= 64 - significand_size - 2;
        return res;
    }

    fn normalizedBoundaries(self: DiyFp, minus: *DiyFp, plus: *DiyFp) void {
        const pl = (DiyFp{ .f = (self.f << 1) + 1, .e = self.e - 1 }).normalizeBoundary();
        var mi: DiyFp = if (self.f == hidden_bit) .{ .f = (self.f << 2) - 1, .e = self.e - 2 } else .{ .f = (self.f << 1) - 1, .e = self.e - 1 };
        mi.f <<= @intCast(mi.e - pl.e);
        mi.e = pl.e;
        plus.* = pl;
        minus.* = mi;
    }
};

const cached_powers_f = [87]u64{
    0xfa8fd5a0081c0288, 0xbaaee17fa23ebf76, 0x8b16fb203055ac76, 0xcf42894a5dce35ea, 0x9a6bb0aa55653b2d, 0xe61acf033d1a45df,
    0xab70fe17c79ac6ca, 0xff77b1fcbebcdc4f, 0xbe5691ef416bd60c, 0x8dd01fad907ffc3c, 0xd3515c2831559a83, 0x9d71ac8fada6c9b5,
    0xea9c227723ee8bcb, 0xaecc49914078536d, 0x823c12795db6ce57, 0xc21094364dfb5637, 0x9096ea6f3848984f, 0xd77485cb25823ac7,
    0xa086cfcd97bf97f4, 0xef340a98172aace5, 0xb23867fb2a35b28e, 0x84c8d4dfd2c63f3b, 0xc5dd44271ad3cdba, 0x936b9fcebb25c996,
    0xdbac6c247d62a584, 0xa3ab66580d5fdaf6, 0xf3e2f893dec3f126, 0xb5b5ada8aaff80b8, 0x87625f056c7c4a8b, 0xc9bcff6034c13053,
    0x964e858c91ba2655, 0xdff9772470297ebd, 0xa6dfbd9fb8e5b88f, 0xf8a95fcf88747d94, 0xb94470938fa89bcf, 0x8a08f0f8bf0f156b,
    0xcdb02555653131b6, 0x993fe2c6d07b7fac, 0xe45c10c42a2b3b06, 0xaa242499697392d3, 0xfd87b5f28300ca0e, 0xbce5086492111aeb,
    0x8cbccc096f5088cc, 0xd1b71758e219652c, 0x9c40000000000000, 0xe8d4a51000000000, 0xad78ebc5ac620000, 0x813f3978f8940984,
    0xc097ce7bc90715b3, 0x8f7e32ce7bea5c70, 0xd5d238a4abe98068, 0x9f4f2726179a2245, 0xed63a231d4c4fb27, 0xb0de65388cc8ada8,
    0x83c7088e1aab65db, 0xc45d1df942711d9a, 0x924d692ca61be758, 0xda01ee641a708dea, 0xa26da3999aef774a, 0xf209787bb47d6b85,
    0xb454e4a179dd1877, 0x865b86925b9bc5c2, 0xc83553c5c8965d3d, 0x952ab45cfa97a0b3, 0xde469fbd99a05fe3, 0xa59bc234db398c25,
    0xf6c69a72a3989f5c, 0xb7dcbf5354e9bece, 0x88fcf317f22241e2, 0xcc20ce9bd35c78a5, 0x98165af37b2153df, 0xe2a0b5dc971f303a,
    0xa8d9d1535ce3b396, 0xfb9b7cd9a4a7443c, 0xbb764c4ca7a44410, 0x8bab8eefb6409c1a, 0xd01fef10a657842c, 0x9b10a4e5e9913129,
    0xe7109bfba19c0c9d, 0xac2820d9623bf429, 0x80444b5e7aa7cf85, 0xbf21e44003acdd2d, 0x8e679c2f5e44ff8f, 0xd433179d9c8cb841,
    0x9e19db92b4e31ba9, 0xeb96bf6ebadf77d9, 0xaf87023b9bf0ee6b,
};

const cached_powers_e = [87]i16{
    -1220, -1193, -1166, -1140, -1113, -1087, -1060, -1034, -1007, -980,
    -954,  -927,  -901,  -874,  -847,  -821,  -794,  -768,  -741,  -715,
    -688,  -661,  -635,  -608,  -582,  -555,  -529,  -502,  -475,  -449,
    -422,  -396,  -369,  -343,  -316,  -289,  -263,  -236,  -210,  -183,
    -157,  -130,  -103,  -77,   -50,   -24,   3,     30,    56,    83,
    109,   136,   162,   189,   216,   242,   269,   295,   322,   348,
    375,   402,   428,   455,   481,   508,   534,   561,   588,   614,
    641,   667,   694,   720,   747,   774,   800,   827,   853,   880,
    907,   933,   960,   986,   1013,  1039,  1066,
};

fn cachedPower(e: i32, k_out: *i32) DiyFp {
    const dk = @as(f64, @floatFromInt(-61 - e)) * 0.30102999566398114 + 347;
    var k: i32 = @intFromFloat(dk);
    if (dk - @as(f64, @floatFromInt(k)) > 0.0) k += 1;
    const index: u32 = @intCast((k >> 3) + 1);
    k_out.* = -(-348 + @as(i32, @intCast(index << 3)));
    return .{ .f = cached_powers_f[index], .e = cached_powers_e[index] };
}

fn grisuRound(buffer: []u8, len: usize, delta: u64, rest_in: u64, ten_kappa: u64, wp_w: u64) void {
    var rest = rest_in;
    while (rest < wp_w and delta - rest >= ten_kappa and (rest + ten_kappa < wp_w or wp_w - rest > rest + ten_kappa - wp_w)) {
        buffer[len - 1] -= 1;
        rest += ten_kappa;
    }
}

fn countDecimalDigit32(n: u32) i32 {
    if (n < 10) return 1;
    if (n < 100) return 2;
    if (n < 1000) return 3;
    if (n < 10000) return 4;
    if (n < 100000) return 5;
    if (n < 1000000) return 6;
    if (n < 10000000) return 7;
    if (n < 100000000) return 8;
    return 9;
}

const pow10 = [20]u64{ 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000, 1000000000000000, 10000000000000000, 100000000000000000, 1000000000000000000, 10000000000000000000 };

fn digitGen(w: DiyFp, mp: DiyFp, delta_in: u64, buffer: []u8, len: *usize, k: *i32) void {
    var delta = delta_in;
    const shift: u6 = @intCast(-mp.e);
    const one: DiyFp = .{ .f = @as(u64, 1) << shift, .e = mp.e };
    const wp_w = mp.sub(w);
    var p1: u32 = @intCast(mp.f >> shift);
    var p2: u64 = mp.f & (one.f - 1);
    var kappa = countDecimalDigit32(p1);
    len.* = 0;
    while (kappa > 0) {
        var d: u32 = 0;
        switch (kappa) {
            inline 1...9 => |kc| {
                const div: u32 = comptime @intCast(pow10[kc - 1]);
                d = p1 / div;
                p1 %= div;
            },
            else => unreachable,
        }
        if (d != 0 or len.* != 0) {
            buffer[len.*] = '0' + @as(u8, @intCast(d));
            len.* += 1;
        }
        kappa -= 1;
        const tmp = (@as(u64, p1) << shift) + p2;
        if (tmp <= delta) {
            k.* += kappa;
            grisuRound(buffer, len.*, delta, tmp, pow10[@intCast(kappa)] << shift, wp_w.f);
            return;
        }
    }
    while (true) {
        p2 *%= 10;
        delta *%= 10;
        const d: u8 = @intCast(p2 >> shift);
        if (d != 0 or len.* != 0) {
            buffer[len.*] = '0' + d;
            len.* += 1;
        }
        p2 &= one.f - 1;
        kappa -= 1;
        if (p2 < delta) {
            k.* += kappa;
            const index: i32 = -kappa;
            grisuRound(buffer, len.*, delta, p2, one.f, wp_w.f *% (if (index < 20) pow10[@intCast(index)] else 0));
            return;
        }
    }
}

fn grisu2(value_in: f64, buffer: []u8, length: *usize, k: *i32) void {
    const v = DiyFp.fromDouble(value_in);
    var w_m: DiyFp = undefined;
    var w_p: DiyFp = undefined;
    v.normalizedBoundaries(&w_m, &w_p);
    const c_mk = cachedPower(w_p.e, k);
    const w = v.normalize().mul(c_mk);
    var wp = w_p.mul(c_mk);
    var wm = w_m.mul(c_mk);
    wm.f += 1;
    wp.f -= 1;
    digitGen(w, wp, wp.f - wm.f, buffer, length, k);
}

fn writeExponent(k_in: i32, buffer: []u8) usize {
    var k = k_in;
    var i: usize = 0;
    if (k < 0) {
        buffer[i] = '-';
        i += 1;
        k = -k;
    }
    const uk: u32 = @intCast(k);
    if (uk >= 100) {
        buffer[i] = '0' + @as(u8, @intCast(uk / 100));
        buffer[i + 1] = '0' + @as(u8, @intCast((uk % 100) / 10));
        buffer[i + 2] = '0' + @as(u8, @intCast(uk % 10));
        i += 3;
    } else if (uk >= 10) {
        buffer[i] = '0' + @as(u8, @intCast(uk / 10));
        buffer[i + 1] = '0' + @as(u8, @intCast(uk % 10));
        i += 2;
    } else {
        buffer[i] = '0' + @as(u8, @intCast(uk));
        i += 1;
    }
    return i;
}

/// Returns the end index of the prettified number in `buffer`.
fn prettify(buffer: []u8, length_in: usize, k: i32, max_decimals: i32) usize {
    const length: i32 = @intCast(length_in);
    const kk = length + k;
    if (0 <= k and kk <= 21) {
        var i = length;
        while (i < kk) : (i += 1) buffer[@intCast(i)] = '0';
        buffer[@intCast(kk)] = '.';
        buffer[@intCast(kk + 1)] = '0';
        return @intCast(kk + 2);
    } else if (0 < kk and kk <= 21) {
        const ukk: usize = @intCast(kk);
        std.mem.copyBackwards(u8, buffer[ukk + 1 .. @as(usize, @intCast(length)) + 1], buffer[ukk..@intCast(length)]);
        buffer[ukk] = '.';
        if (0 > k + max_decimals) {
            var i = kk + max_decimals;
            while (i > kk + 1) : (i -= 1) if (buffer[@intCast(i)] != '0') return @intCast(i + 1);
            return @intCast(kk + 2);
        }
        return @intCast(length + 1);
    } else if (-6 < kk and kk <= 0) {
        const offset: usize = @intCast(2 - kk);
        std.mem.copyBackwards(u8, buffer[offset .. offset + @as(usize, @intCast(length))], buffer[0..@intCast(length)]);
        buffer[0] = '0';
        buffer[1] = '.';
        for (2..offset) |i| buffer[i] = '0';
        if (length - kk > max_decimals) {
            var i = max_decimals + 1;
            while (i > 2) : (i -= 1) if (buffer[@intCast(i)] != '0') return @intCast(i + 1);
            return 3;
        }
        return @as(usize, @intCast(length)) + offset;
    } else if (kk < -max_decimals) {
        buffer[0] = '0';
        buffer[1] = '.';
        buffer[2] = '0';
        return 3;
    } else if (length == 1) {
        buffer[1] = 'e';
        return 2 + writeExponent(kk - 1, buffer[2..]);
    } else {
        const ul: usize = @intCast(length);
        std.mem.copyBackwards(u8, buffer[2 .. ul + 1], buffer[1..ul]);
        buffer[1] = '.';
        buffer[ul + 1] = 'e';
        return ul + 2 + writeExponent(kk - 1, buffer[ul + 2 ..]);
    }
}

/// rapidjson `internal::dtoa`. `buffer` needs 40 bytes. Returns the text.
///
/// Fast path: if `value` is the double nearest to a decimal S with at most
/// `max_decimals` places, and S sits well inside value's rounding interval
/// (under 0.45 ulp away, so inside Grisu2's slightly conservative interval
/// too), then S is the unique shortest representation, Grisu2 emits exactly
/// S's digits, and Prettify keeps them untruncated. So S printed directly is
/// byte-identical to rapidjson. This covers coordinates, distances and
/// heights, which are all on such grids. Anything else takes full Grisu2.
pub fn dtoa(value_in: f64, buffer: []u8, max_decimals: u16) []const u8 {
    if (max_decimals <= 15) if (dtoaFixed(value_in, buffer, max_decimals)) |s| return s;
    return dtoaGrisu(value_in, buffer, max_decimals);
}

const pow10_f64 = [16]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15 };

fn dtoaFixed(value: f64, buffer: []u8, max_decimals: u16) ?[]const u8 {
    const mag = @abs(value);
    if (!(mag >= 1e-5 and mag < 1e15)) return null;
    const p10 = pow10_f64[max_decimals];
    const qf = @round(mag * p10);
    if (qf <= 0 or qf >= 9007199254740992.0) return null;
    const bits: u64 = @bitCast(mag);
    const up: f64 = @as(f64, @bitCast(bits + 1)) - mag;
    const down: f64 = mag - @as(f64, @bitCast(bits - 1));
    // The rounding interval must be narrower than the grid, so at most one
    // grid decimal can lie in it and Grisu2's digits g satisfy
    // S - spacing < g < S + spacing.
    if (up + down >= 0.9 / p10) return null;
    // r = value - S, nearly exact via fused multiply-add, kept scaled by
    // p10 (rs = r * p10) and compared with the scaled half-spacings: one
    // rounding either way, far inside the 0.45..0.55 band that sends
    // anything near the boundary to Grisu2.
    const rs = -@mulAdd(f64, -mag, p10, qf);
    const down_s = down * p10;
    const up_s = up * p10;
    var q: u64 = @intFromFloat(qf);
    if (rs >= 0) {
        // S at or below value. Inside the interval: g = S. Outside: g > S,
        // so truncation gives S. Near the boundary: let Grisu2 decide.
        if (rs >= 0.45 * down_s and rs <= 0.55 * down_s) return null;
    } else {
        // S above value. Inside: g = S. Outside: g < S, truncation gives S - spacing.
        const d = -rs;
        if (d >= 0.45 * up_s and d <= 0.55 * up_s) return null;
        if (d > 0.55 * up_s) q -= 1;
    }

    const scale: u64 = @intFromFloat(p10);
    var i: usize = 0;
    if (value < 0) {
        buffer[0] = '-';
        i = 1;
    }
    const int_part = q / scale;
    var frac = q % scale;
    var int_buf: [24]u8 = undefined;
    const int_digits = formatUint(int_part, &int_buf);
    @memcpy(buffer[i..][0..int_digits.len], int_digits);
    i += int_digits.len;
    buffer[i] = '.';
    i += 1;
    if (frac == 0) {
        buffer[i] = '0';
        return buffer[0 .. i + 1];
    }
    var digits: usize = max_decimals;
    while (frac % 10 == 0) {
        frac /= 10;
        digits -= 1;
    }
    var j = digits;
    while (j >= 2) : (j -= 2) {
        const pair: usize = @intCast(frac % 100);
        frac /= 100;
        buffer[i + j - 2 ..][0..2].* = digit_pairs[2 * pair ..][0..2].*;
    }
    if (j == 1) buffer[i] = '0' + @as(u8, @intCast(frac % 10));
    return buffer[0 .. i + digits];
}

const digit_pairs = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + @as(u8, @intCast(i / 10));
        t[2 * i + 1] = '0' + @as(u8, @intCast(i % 10));
    }
    break :blk t;
};

/// Decimal digits of `v`, right-aligned at the end of `buf`; returns them.
pub fn formatUint(v_in: u64, buf: *[24]u8) []const u8 {
    var v = v_in;
    var i: usize = buf.len;
    while (v >= 100) {
        const r: usize = @intCast(v % 100);
        v /= 100;
        i -= 2;
        buf[i..][0..2].* = digit_pairs[2 * r ..][0..2].*;
    }
    if (v >= 10) {
        i -= 2;
        buf[i..][0..2].* = digit_pairs[2 * @as(usize, @intCast(v)) ..][0..2].*;
    } else {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v));
    }
    return buf[i..];
}

pub fn formatInt(v: i64, buf: *[24]u8) []const u8 {
    if (v >= 0) return formatUint(@intCast(v), buf);
    const digits = formatUint(@abs(v), buf);
    const start = buf.len - digits.len - 1;
    buf[start] = '-';
    return buf[start..];
}

/// Full rapidjson Grisu2 + Prettify.
pub fn dtoaGrisu(value_in: f64, buffer: []u8, max_decimals: u16) []const u8 {
    std.debug.assert(max_decimals >= 1 and buffer.len >= 40);
    var value = value_in;
    var start: usize = 0;
    if (value == 0) {
        if (std.math.signbit(value)) {
            buffer[0] = '-';
            start = 1;
        }
        @memcpy(buffer[start..][0..3], "0.0");
        return buffer[0 .. start + 3];
    }
    if (value < 0) {
        buffer[0] = '-';
        start = 1;
        value = -value;
    }
    var length: usize = 0;
    var k: i32 = 0;
    grisu2(value, buffer[start..], &length, &k);
    const end = prettify(buffer[start..], length, k, max_decimals);
    return buffer[0 .. start + end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDouble(v: f64, decimals: u16, expected: []const u8) !void {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings(expected, dtoa(v, &buf, decimals));
}

test "doubles as rapidjson writes them (writertest Double)" {
    try expectDouble(0.0, 324, "0.0");
    try expectDouble(-0.0, 324, "-0.0");
    try expectDouble(1.0, 324, "1.0");
    try expectDouble(-1.0, 324, "-1.0");
    try expectDouble(1.2345, 324, "1.2345");
    try expectDouble(1.2345678, 324, "1.2345678");
    try expectDouble(0.123456789012, 324, "0.123456789012");
    try expectDouble(1234567.8, 324, "1234567.8");
    try expectDouble(-79.39773355813419, 324, "-79.39773355813419");
    try expectDouble(0.000001, 324, "0.000001");
    try expectDouble(0.0000001, 324, "1e-7");
    try expectDouble(1e30, 324, "1e30");
    try expectDouble(1.234567890123456e30, 324, "1.234567890123456e30");
    try expectDouble(5e-324, 324, "5e-324");
    try expectDouble(2.225073858507201e-308, 324, "2.225073858507201e-308");
    try expectDouble(1.7976931348623157e308, 324, "1.7976931348623157e308");
    try expectDouble(123456789012345678901.0, 324, "123456789012345680000.0");
    try expectDouble(1e21, 324, "1e21");
}

test "max decimal places truncate and trim (writertest MaxDecimalPlaces)" {
    try expectDouble(0.0, 3, "0.0");
    try expectDouble(0.1, 3, "0.1");
    try expectDouble(0.12, 3, "0.12");
    try expectDouble(0.123, 3, "0.123");
    try expectDouble(0.1234, 3, "0.123");
    try expectDouble(1.2345, 3, "1.234");
    try expectDouble(1.2345678, 3, "1.234");
    try expectDouble(0.0001, 3, "0.0");
    try expectDouble(0.00001, 3, "0.0");
    try expectDouble(1.1, 3, "1.1");
    try expectDouble(1.102, 2, "1.1");
    try expectDouble(1e30, 3, "1e30");
    try expectDouble(-0.1234, 3, "-0.123");
    // Coordinates at the API precision of 6.
    try expectDouble(47.3768866, 6, "47.376886");
    try expectDouble(-122.41941550000001, 6, "-122.419415");
    try expectDouble(8.5, 6, "8.5");
    // Heights at precision 1.
    try expectDouble(303.25, 1, "303.2");
}

test "writer output: commas, keys, nesting, escaping" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &out);
    try w.beginObject();
    try w.beginArrayField("shape");
    w.setPrecision(6);
    for ([_][2]f64{ .{ 40.712433, -76.504913 }, .{ 40.712276, -76.605263 } }) |p| {
        try w.beginObject();
        try w.field("lat", p[0]);
        try w.field("lon", p[1]);
        try w.endObject();
    }
    try w.endArray();
    try w.beginArrayField("height");
    try w.int(303);
    try w.null_();
    try w.float(275.5);
    try w.endArray();
    try w.field("id", "a\"b\\c\n\x01/é");
    try w.field("ok", true);
    try w.field("n", @as(u32, 7));
    try w.key("raw");
    try w.raw("\"_ixfE\"");
    try w.beginObjectField("empty");
    try w.endObject();
    try w.endObject();
    try testing.expectEqualStrings(
        "{\"shape\":[{\"lat\":40.712433,\"lon\":-76.504913},{\"lat\":40.712276,\"lon\":-76.605263}]," ++
            "\"height\":[303,null,275.5],\"id\":\"a\\\"b\\\\c\\n\\u0001/é\",\"ok\":true,\"n\":7,\"raw\":\"_ixfE\",\"empty\":{}}",
        out.items,
    );
}

test "non-finite doubles become null" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var w = Writer.init(testing.allocator, &out);
    try w.beginArray();
    try w.float(std.math.nan(f64));
    try w.float(std.math.inf(f64));
    try w.endArray();
    try testing.expectEqualStrings("[null,null]", out.items);
}

test "dtoa output parses back to the same double at full precision" {
    var prng = std.Random.DefaultPrng.init(17);
    const r = prng.random();
    var buf: [40]u8 = undefined;
    for (0..100_000) |_| {
        const bits = r.int(u64);
        const v: f64 = @bitCast(bits);
        if (!std.math.isFinite(v)) continue;
        const s = dtoa(v, &buf, 324);
        const back = try std.fmt.parseFloat(f64, s);
        try testing.expectEqual(v, back);
    }
}

test "serialization reaches the backing allocator only while warming up" {
    const arena_mod = @import("../infra/arena.zig");
    const Work = struct {
        fn run(arena: *arena_mod.Arena, n: usize) anyerror!void {
            var out: std.ArrayList(u8) = .empty;
            var w = Writer.init(arena.allocator(), &out);
            w.setPrecision(6);
            try w.beginArray();
            for (0..n) |i| try w.float(@as(f64, @floatFromInt(i)) * 0.000123 + 8.5);
            try w.endArray();
        }
    };
    try arena_mod.expectNoSteadyStateAlloc(usize, 5000, Work.run);
}

test "perf: coordinate-heavy payload throughput (ReleaseFast only)" {
    if (@import("builtin").mode != .fast) return error.SkipZigTest;
    const io = @import("../infra/io.zig");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.ensureTotalCapacity(testing.allocator, 64 << 20);
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        out.clearRetainingCapacity();
        var w = Writer.init(testing.allocator, &out);
        w.setPrecision(6);
        const t = io.Timer.start();
        try w.beginArray();
        var lat: f64 = 47.376887;
        var lon: f64 = 8.541694;
        for (0..1_000_000) |i| {
            lat += @as(f64, @floatFromInt(i % 7)) * 0.000001;
            lon -= @as(f64, @floatFromInt(i % 5)) * 0.000001;
            try w.beginObject();
            try w.field("lat", lat);
            try w.field("lon", lon);
            try w.endObject();
        }
        try w.endArray();
        best = @min(best, t.read());
    }
    std.debug.print("\njson writer: {d} bytes in {d:.1} ms = {d:.0} MB/s\n", .{ out.items.len, @as(f64, @floatFromInt(best)) / 1e6, @as(f64, @floatFromInt(out.items.len)) / (@as(f64, @floatFromInt(best)) / 1e9) / 1e6 });
}

fn quotedKey(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (name) |c| {
            const e = escape_table[c];
            if (e == 0) {
                out = out ++ &[_]u8{c};
            } else if (e == 'u') {
                const hex = "0123456789ABCDEF";
                out = out ++ &[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] };
            } else {
                out = out ++ &[_]u8{ '\\', e };
            }
        }
        return out ++ "\":";
    }
}

test "perf: dtoa alone (ReleaseFast only)" {
    if (@import("builtin").mode != .fast) return error.SkipZigTest;
    const io = @import("../infra/io.zig");
    var buf: [40]u8 = undefined;
    var total: usize = 0;
    const t = io.Timer.start();
    var lat: f64 = 47.376887;
    for (0..2_000_000) |i| {
        lat += @as(f64, @floatFromInt(i % 7)) * 0.000001;
        total += dtoa(lat, &buf, 6).len;
    }
    const ns = t.read();
    std.debug.print("\ndtoa: {d:.1} ns/number, {d:.0} MB/s\n", .{ @as(f64, @floatFromInt(ns)) / 2e6, @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6 });
}

test "fast fixed-point path is byte-identical to full Grisu2" {
    var prng = std.Random.DefaultPrng.init(2024);
    const r = prng.random();
    var a: [40]u8 = undefined;
    var b: [40]u8 = undefined;
    var fast_hits: usize = 0;
    var p: u16 = 1;
    while (p <= 15) : (p += 1) {
        for (0..60_000) |n| {
            // Mix values on decimal grids (the common case) with arbitrary ones.
            const v: f64 = switch (n % 5) {
                0 => @as(f64, @floatFromInt(r.intRangeAtMost(i64, -180_000_000, 180_000_000))) / 1e6,
                4 => @as(f64, @floatFromInt(r.intRangeAtMost(i64, -1_800_000_000, 1_800_000_000))) * 1e-7, // decoded shape7 values
                1 => @as(f64, @floatFromInt(r.intRangeAtMost(i64, -9_000_000, 9_000_000))) / std.math.pow(f64, 10, @floatFromInt(r.uintAtMost(u4, 9))),
                2 => (r.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(r.intRangeAtMost(i32, -6, 15))),
                else => @bitCast(r.int(u64)),
            };
            if (!std.math.isFinite(v)) continue;
            const slow = dtoaGrisu(v, &b, p);
            if (p <= 15) if (dtoaFixed(v, &a, p)) |fast| {
                fast_hits += 1;
                try testing.expectEqualStrings(slow, fast);
            };
        }
    }
    try testing.expect(fast_hits > 100_000);
}

test "integer formatting matches std.fmt" {
    var prng = std.Random.DefaultPrng.init(9);
    const random = prng.random();
    var buf: [24]u8 = undefined;
    var ref: [24]u8 = undefined;
    const edges = [_]i64{ 0, 1, -1, 9, 10, 99, 100, -100, 999, 1000, std.math.maxInt(i64), std.math.minInt(i64) };
    for (edges) |v| try std.testing.expectEqualStrings(try std.fmt.bufPrint(&ref, "{d}", .{v}), formatInt(v, &buf));
    for (0..100_000) |_| {
        const v = random.int(i64) >> random.int(u6);
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&ref, "{d}", .{v}), formatInt(v, &buf));
    }
    try std.testing.expectEqualStrings("18446744073709551615", formatUint(std.math.maxInt(u64), &buf));
}
