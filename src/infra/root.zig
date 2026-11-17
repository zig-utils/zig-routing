//! Shared runtime pieces: arenas, allocators, clocks.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
