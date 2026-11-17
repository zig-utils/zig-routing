//! Transcendental functions from the system libm.
//!
//! Upstream Valhalla gets sin, cos, acos, atan2 and friends from the
//! platform libm (glibc on the production Linux build). Zig's builtins and
//! even `extern "c" fn sin` resolve to Zig's own compiler-rt copies, which
//! differ from glibc in the last bit and flip decimal truncation in
//! responses (a height of 391.99 versus 392). So the functions are looked up
//! in the system libm with dlsym once, and called through pointers. On Linux
//! that is exactly the glibc code upstream runs; on macOS it is Apple's libm.
//! sqrt and floor are exact in IEEE arithmetic and stay as builtins.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const F1 = *const fn (f64) callconv(.c) f64;
const F2 = *const fn (f64, f64) callconv(.c) f64;
const F1f = *const fn (f32) callconv(.c) f32;

const Table = struct {
    sin: F1,
    cos: F1,
    tan: F1,
    asin: F1,
    acos: F1,
    atan: F1,
    atan2: F2,
    sinh: F1,
    log: F1,
    cosf: F1f,
};

var table: Table = undefined;
var ready: std.atomic.Value(bool) = .init(false);

fn lookup(comptime T: type, handle: *anyopaque, name: [*:0]const u8) T {
    const p = c.dlsym(handle, name) orelse @panic("libm function missing");
    return @ptrCast(@alignCast(p));
}

/// Resolves the table. Idempotent; concurrent first calls store identical values.
fn load() *const Table {
    if (ready.load(.acquire)) return &table;
    const path: [*:0]const u8 = if (builtin.os.tag.isDarwin()) "/usr/lib/libSystem.B.dylib" else "libm.so.6";
    const handle = c.dlopen(path, .{ .NOW = true }) orelse @panic("cannot open the system libm");
    table = .{
        .sin = lookup(F1, handle, "sin"),
        .cos = lookup(F1, handle, "cos"),
        .tan = lookup(F1, handle, "tan"),
        .asin = lookup(F1, handle, "asin"),
        .acos = lookup(F1, handle, "acos"),
        .atan = lookup(F1, handle, "atan"),
        .atan2 = lookup(F2, handle, "atan2"),
        .sinh = lookup(F1, handle, "sinh"),
        .log = lookup(F1, handle, "log"),
        .cosf = lookup(F1f, handle, "cosf"),
    };
    ready.store(true, .release);
    return &table;
}

pub inline fn sinF(x: f64) f64 {
    return load().sin(x);
}
pub inline fn cosF(x: f64) f64 {
    return load().cos(x);
}
pub inline fn tanF(x: f64) f64 {
    return load().tan(x);
}
pub inline fn asinF(x: f64) f64 {
    return load().asin(x);
}
pub inline fn acosF(x: f64) f64 {
    return load().acos(x);
}
pub inline fn atanF(x: f64) f64 {
    return load().atan(x);
}
pub inline fn atan2F(y: f64, x: f64) f64 {
    return load().atan2(y, x);
}
pub inline fn sinhF(x: f64) f64 {
    return load().sinh(x);
}
pub inline fn logF(x: f64) f64 {
    return load().log(x);
}
/// Single-precision cosine, as upstream's `cosf` in the longitude scale.
pub inline fn cosf32(x: f32) f32 {
    return load().cosf(x);
}

test "libm functions resolve and agree with known values" {
    try std.testing.expectEqual(@as(f64, 0), sinF(0));
    try std.testing.expectEqual(@as(f64, 1), cosF(0));
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, acosF(0), 1e-15);
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, atan2F(1, 1), 1e-15);
    try std.testing.expectEqual(@as(f32, 1), cosf32(0));
}
