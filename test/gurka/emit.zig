//! Emit the restriction fixture for the Valhalla oracle's tile builder.

const std = @import("std");
const examples = @import("examples.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: zig build gurka-pbf -- FILE.osm.pbf\n", .{});
        return error.MissingOutputPath;
    };
    if (args.next() != null) return error.ExtraArguments;
    const fixture = try examples.intersection(init.arena.allocator());
    try fixture.osm.writePbf(init.gpa, path);
}
