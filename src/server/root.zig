//! HTTP service: threads, routing of actions, limits, deadlines, metrics.

const std = @import("std");

pub const http = @import("http.zig");

test {
    std.testing.refAllDecls(@This());
}
