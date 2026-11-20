//! Geocoding, reverse geocoding and search.

const std = @import("std");
pub const model = @import("model.zig");
pub const bundle = @import("bundle.zig");
pub const extract = @import("extract.zig");
pub const house_number = @import("house_number.zig");
pub const interpolation = @import("interpolation.zig");
pub const postcode = @import("postcode.zig");
pub const address_format = @import("address_format.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("tags.zig");
}
