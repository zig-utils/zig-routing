//! Valhalla error and warning codes.
//!
//! Ported from src/exceptions.cc (Valhalla 3.9.3); the table itself is
//! generated into errors_table.zig. A request fails with a `Failure`
//! (code plus optional extra text appended as ": extra", as upstream's
//! valhalla_exception_t does).

const std = @import("std");
const table = @import("errors_table.zig");

pub const Entry = table.Entry;

pub const Failure = struct {
    code: u16,
    /// Appended to the message as ": extra" when not empty.
    extra: []const u8 = "",

    pub fn entry(self: Failure) Entry {
        return lookup(self.code);
    }
};

/// Upstream returns a default-constructed exception for unknown codes;
/// we map those to a generic 500 so nothing is ever silently blank.
pub fn lookup(code: u16) Entry {
    for (table.errors) |e| if (e.code == code) return e;
    return .{ .code = code, .message = "Unknown error", .http_code = 500, .osrm = "{\"code\":\"InvalidUrl\",\"message\":\"Failed to serialize route.\"}", .statsd_key = "unknown" };
}

pub fn warningText(code: u16) ?[]const u8 {
    for (table.warnings) |w| if (w.code == code) return w.description;
    return null;
}

pub fn httpReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Error",
    };
}

test "table is complete and lookups work" {
    try std.testing.expectEqual(@as(usize, 100), table.errors.len);
    try std.testing.expectEqual(@as(usize, 30), table.warnings.len);
    const e = lookup(100);
    try std.testing.expectEqualStrings("Failed to parse json request", e.message);
    try std.testing.expectEqual(@as(u16, 400), e.http_code);
    try std.testing.expectEqualStrings("jsonp has been deprecated, use CORS instead", warningText(104).?);
    try std.testing.expectEqual(@as(u16, 500), lookup(9999).http_code);
    // Codes are unique.
    for (table.errors, 0..) |a, i| for (table.errors[i + 1 ..]) |b| try std.testing.expect(a.code != b.code);
}
