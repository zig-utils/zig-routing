//! Emit the restriction fixture for the Valhalla oracle's tile builder.

const std = @import("std");
const examples = @import("examples.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: zig build gurka-pbf -- FILE.osm.pbf [motor-vehicle]\n", .{});
        return error.MissingOutputPath;
    };
    const arena = init.arena.allocator();
    const fixture = if (args.next()) |name| blk: {
        if (!std.mem.eql(u8, name, "motor-vehicle")) return error.UnknownFixture;
        break :blk try examples.motorVehicle(arena);
    } else try examples.intersection(arena);
    if (args.next() != null) return error.ExtraArguments;
    try fixture.osm.writePbf(init.gpa, path);
}
