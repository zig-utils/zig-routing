const std = @import("std");
const routing = @import("routing");

pub fn main() void {
    std.debug.print("zr {s}\n", .{routing.version});
}
