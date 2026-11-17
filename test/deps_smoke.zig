//! Proves every reused zig-utils library compiles on the pinned toolchain and
//! that one function from each can be called. If this file stops compiling
//! after a toolchain bump, fix the library in its own repository and bump the
//! hash in build.zig.zon; never vendor a patched copy.

const std = @import("std");
const zig_cli = @import("zig_cli");
const zig_config = @import("zig_config");
const tls = @import("tls");
const xml = @import("xml");

test "zig-cli: parser and option construct" {
    var parser = zig_cli.Parser.init(std.testing.allocator);
    _ = &parser;
    const option = zig_cli.Option.init("port", "port", "Port to listen on", .int);
    try std.testing.expectEqualStrings("port", option.name);
}

test "zig-config: json value equality" {
    try std.testing.expect(zig_config.utils.jsonValuesEqual(.{ .integer = 8002 }, .{ .integer = 8002 }));
    try std.testing.expect(!zig_config.utils.jsonValuesEqual(.{ .integer = 1 }, .{ .bool = true }));
}

test "zig-tls: ALPN protocol list parses" {
    // ALPN extension body: u16 list length, then (u8 length, bytes) entries.
    const payload = "\x00\x0c\x02h2\x08http/1.1";
    const protocols = try tls.alpn.parseProtocolList(std.testing.allocator, payload);
    defer std.testing.allocator.free(protocols);
    try std.testing.expectEqual(@as(usize, 2), protocols.len);
    try std.testing.expect(tls.record_header_len > 0);
}

test "zig-xml: pull reader yields an element" {
    var reader = xml.Reader.init(std.testing.allocator, "<osm version=\"0.6\"><node id=\"1\"/></osm>");
    defer reader.deinit();
    const first = (try reader.next()) orelse return error.NoEvent;
    try std.testing.expect(first != .text);
}
