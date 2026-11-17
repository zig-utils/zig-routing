//! `zig build bench-lz4 [-- out.lz4]`: measures decompression and
//! compression throughput on elevation-like and text-like data, and
//! optionally writes our compressed frame to a file so the reference `lz4`
//! tool can check it decodes.

const std = @import("std");
const lz4 = @import("lz4");

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(if (@import("builtin").os.tag.isDarwin()) .UPTIME_RAW else .MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    var args_list: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |a| try args_list.append(init.arena.allocator(), a);
    const args = args_list.items;

    // 64 MiB of smooth int16 samples (like a DEM) mixed with repeated words.
    const n = 64 * 1024 * 1024;
    const src = try gpa.alloc(u8, n);
    defer gpa.free(src);
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var h: i16 = 500;
    var i: usize = 0;
    while (i + 2 <= n) : (i += 2) {
        h +%= @as(i16, r.intRangeAtMost(i8, -3, 3));
        std.mem.writeInt(i16, src[i..][0..2], h, .big);
    }

    const z = try lz4.compressAlloc(gpa, src, .{});
    defer gpa.free(z);
    const out = try gpa.alloc(u8, n);
    defer gpa.free(out);

    var best_c: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const t0 = nowNs();
        const zz = try lz4.compressAlloc(gpa, src, .{});
        best_c = @min(best_c, nowNs() - t0);
        gpa.free(zz);
    }
    var best_d: u64 = std.math.maxInt(u64);
    for (0..10) |_| {
        const t0 = nowNs();
        const res = try lz4.decompressFrames(z, out);
        best_d = @min(best_d, nowNs() - t0);
        if (res.written != n) return error.Mismatch;
    }
    if (!std.mem.eql(u8, src, out)) return error.Mismatch;

    const zn = try lz4.compressAlloc(gpa, src, .{ .content_checksum = false });
    defer gpa.free(zn);
    var best_n: u64 = std.math.maxInt(u64);
    for (0..10) |_| {
        const t0 = nowNs();
        _ = try lz4.decompressFrames(zn, out);
        best_n = @min(best_n, nowNs() - t0);
    }

    const mb = @as(f64, @floatFromInt(n)) / (1024 * 1024);
    std.debug.print("input {d:.0} MiB, ratio {d:.3}\ncompress   {d:.0} MiB/s\ndecompress {d:.0} MiB/s (incl. xxh32 content checksum)\ndecompress {d:.0} MiB/s (no checksum)\n", .{
        mb,
        @as(f64, @floatFromInt(z.len)) / @as(f64, @floatFromInt(n)),
        mb / (@as(f64, @floatFromInt(best_c)) / 1e9),
        mb / (@as(f64, @floatFromInt(best_d)) / 1e9),
        mb / (@as(f64, @floatFromInt(best_n)) / 1e9),
    });

    if (args.len > 1) {
        const f = std.c.fopen(try init.arena.allocator().dupeSentinel(u8, args[1], 0), "wb") orelse return error.Open;
        _ = std.c.fwrite(z.ptr, 1, z.len, f);
        _ = std.c.fclose(f);
        const raw = std.c.fopen(try std.fmt.allocPrintSentinel(init.arena.allocator(), "{s}.raw", .{args[1]}, 0), "wb") orelse return error.Open;
        _ = std.c.fwrite(src.ptr, 1, src.len, raw);
        _ = std.c.fclose(raw);
    }
}
