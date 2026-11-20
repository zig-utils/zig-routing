//! Emit the restriction fixture for the Valhalla oracle's tile builder.

const std = @import("std");
const examples = @import("examples.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: zig build gurka-pbf -- FILE.osm.pbf [motor-vehicle|admin-boundaries|country-access]\n", .{});
        return error.MissingOutputPath;
    };
    const arena = init.arena.allocator();
    const fixture = if (args.next()) |name| blk: {
        if (std.mem.eql(u8, name, "motor-vehicle")) break :blk try examples.motorVehicle(arena);
        if (std.mem.eql(u8, name, "admin-boundaries")) break :blk try examples.adminBoundaries(arena);
        if (std.mem.eql(u8, name, "country-access")) break :blk try examples.countryAccess(arena);
        return error.UnknownFixture;
    } else try examples.intersection(arena);
    if (args.next() != null) return error.ExtraArguments;
    try fixture.osm.writePbf(init.gpa, path);
}
