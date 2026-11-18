//! Inputs the fuzzers found, one test per finding, kept with the fix so the
//! bug cannot come back. Each test feeds the crashing input to the target it
//! was found by, through the same entry point the fuzzer uses.
//!
//! To add one: copy the saved input (`fuzz-crashers/<target>-<time>.bin` from
//! scripts/fuzz.sh or the nightly job's artifact) to `test/fuzz/crashers/`,
//! add a test below that calls `replayStream(target, @embedFile(...))`, fix
//! the parser, commit all three. For an input written by hand, `replay` takes
//! the bytes the target should draw.

const std = @import("std");
const fuzz = @import("../fuzz.zig");

/// Replays a saved fuzzer input (the raw stream the target's Smith read).
pub fn replayStream(comptime target: fn (void, *std.testing.Smith) anyerror!void, stream: []const u8) !void {
    var smith: std.testing.Smith = .{ .in = stream };
    try target({}, &smith);
}

pub fn replay(comptime target: fn (void, *std.testing.Smith) anyerror!void, input: []const u8) !void {
    var buf: [4 + 65536]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @intCast(input.len), .little);
    @memcpy(buf[4..][0..input.len], input);
    var smith: std.testing.Smith = .{ .in = buf[0 .. 4 + input.len] };
    try target({}, &smith);
}

test "replay helper drives a target" {
    try replay(fuzz.fuzzHttp, "GET / HTTP/1.1\r\n\r\n");
}
