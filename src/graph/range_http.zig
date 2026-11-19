//! HTTP(S) byte-range source for the sparse bundle cache.
const std = @import("std");
const tls = @import("tls");
const io = @import("../infra/io.zig");
const Kind = @import("format.zig").SectionKind;
const Source = @import("range_cache.zig").Source;
const Allocator = std.mem.Allocator;
const ResponseHead = std.http.Client.Response.Head;

const max_header = 16 * 1024;

pub const Origin = struct {
    host: []const u8,
    hostname: []const u8,
    path: []const u8,
    port: u16,
    peers: []io.TcpPeer,
    roots: ?tls.config.cert.Bundle,

    /// Borrows URL components. Resolve the hostname and load trust roots
    /// during startup, before serving requests.
    pub fn open(a: Allocator, url: []const u8) !Origin {
        const uri = try std.Uri.parse(url);
        const encrypted = std.ascii.eqlIgnoreCase(uri.scheme, "https");
        if (!encrypted and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidBundleOrigin;
        if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBundleOrigin;
        const host = component(uri.host orelse return error.InvalidBundleOrigin);
        const path = std.mem.trimEnd(u8, component(uri.path), "/");
        if (host.len == 0 or path.len >= 4096 or (path.len != 0 and path[0] != '/')) return error.InvalidBundleOrigin;
        for (host) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".-:[]", byte) == null) return error.InvalidBundleOrigin;
        }
        for (path) |byte| {
            if (byte <= ' ' or byte >= 0x7f) return error.InvalidBundleOrigin;
        }
        const hostname = if (host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
        const port = uri.port orelse @as(u16, if (encrypted) 443 else 80);
        if (port == 0) return error.InvalidBundleOrigin;
        const peers = try io.TcpPeer.resolve(a, hostname, port);
        errdefer a.free(peers);
        const roots = if (encrypted) try tls.config.cert.fromSystem(a) else null;
        return .{ .host = host, .hostname = hostname, .path = path, .port = port, .peers = peers, .roots = roots };
    }

    pub fn close(self: *Origin, a: Allocator) void {
        if (self.roots) |*roots| roots.deinit(a);
        a.free(self.peers);
        self.* = undefined;
    }

    pub fn source(self: *const Origin) Source {
        return .{ .context = self, .fetch = fetch };
    }

    fn fetch(context: *const anyopaque, kind: Kind, start: usize, size: usize, out: []u8, deadline: io.Deadline) !void {
        const self: *const Origin = @ptrCast(@alignCast(context));
        if (out.len == 0 or start >= size or out.len > size - start) return error.InvalidExtentRange;
        const socket = try self.connect(deadline);
        defer socket.close();

        var request_buf: [4608]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf, "GET {s}/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nRange: bytes={d}-{d}\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n", .{ self.path, kind.filename(), self.host, self.port, start, start + out.len - 1 });
        if (self.roots) |roots| {
            var encrypted_input: [tls.input_buffer_len]u8 = undefined;
            var encrypted_output: [tls.output_buffer_len]u8 = undefined;
            var input = io.BufferedReader(io.DeadlineStream).init(socket, &encrypted_input);
            var output = io.SocketWriter.init(socket, &encrypted_output);
            var connection = tls.client(&input.interface, &output.interface, .{
                .host = self.hostname,
                .root_ca = roots,
            }) catch |err| return input.failure orelse (output.failure orelse err);
            connection.writeAll(request) catch |err| return output.failure orelse err;
            consume(&connection, start, size, out) catch |err| return input.failure orelse (output.failure orelse err);
        } else {
            var output = io.SocketWriter.init(socket, &.{});
            output.interface.writeAll(request) catch |err| return output.failure orelse err;
            try consume(socket, start, size, out);
        }
    }

    fn connect(self: *const Origin, deadline: io.Deadline) !io.DeadlineStream {
        var failure: anyerror = error.ConnectionRefused;
        for (self.peers, 0..) |*peer, i| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const budget = if (i + 1 == self.peers.len) deadline else deadline.min(.fromNowMs(250));
            var socket = peer.connect(budget) catch |err| {
                failure = err;
                continue;
            };
            socket.deadline = deadline;
            return socket;
        }
        return failure;
    }
};

fn component(value: std.Uri.Component) []const u8 {
    return switch (value) {
        .percent_encoded, .raw => |bytes| bytes,
    };
}

fn consume(context: anytype, start: usize, size: usize, out: []u8) !void {
    var buffer: [max_header]u8 = undefined;
    var input = io.BufferedReader(@TypeOf(context)).init(context, &buffer);
    var http: std.http.Reader = .{ .in = &input.interface, .interface = undefined, .state = .ready, .max_head_len = buffer.len };
    const raw = http.receiveHead() catch |err| return input.failure orelse err;
    const head = try parseHead(raw, start, size, out.len);
    var body_buffer: [1024]u8 = undefined;
    const body = http.bodyReader(&body_buffer, head.transfer_encoding, head.content_length);
    body.readSliceAll(out) catch |err| return input.failure orelse (http.body_err orelse err);
    if (head.content_length == null) {
        if (body.takeByte()) |_| {
            return error.RangeBodyTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return input.failure orelse (http.body_err orelse err),
        }
    }
}

/// Validate the exact single range before admitting any payload bytes.
pub fn parseHead(raw: []const u8, start: usize, size: usize, len: usize) !ResponseHead {
    if (len == 0 or start >= size or len > size - start or raw.len < 12 or raw.len > max_header or
        !std.mem.endsWith(u8, raw, "\r\n\r\n") or !std.mem.eql(u8, raw[9..12], "206"))
        return error.InvalidRangeResponse;
    const head = try ResponseHead.parse(raw);
    if (head.status != .partial_content or head.content_encoding != .identity) return error.InvalidRangeResponse;
    if (head.content_length) |length| {
        if (length != len or head.transfer_encoding != .none) return error.InvalidRangeResponse;
    }
    var matched = false;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-range")) continue;
        if (matched or !matchesRange(header.value, start, size, len)) return error.InvalidRangeResponse;
        matched = true;
    }
    if (!matched) return error.InvalidRangeResponse;
    return head;
}

fn matchesRange(value: []const u8, start: usize, size: usize, len: usize) bool {
    const prefix = "bytes ";
    if (value.len < prefix.len or !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return false;
    var fields = std.mem.splitAny(u8, value[prefix.len..], "-/");
    const first = fields.first();
    const last = fields.next() orelse return false;
    const total = fields.next() orelse return false;
    if (fields.next() != null or value[prefix.len + first.len] != '-' or
        value[prefix.len + first.len + 1 + last.len] != '/') return false;
    return decimal(first) == start and decimal(last) == start + len - 1 and decimal(total) == size;
}

fn decimal(text: []const u8) ?usize {
    for (text) |char| if (!std.ascii.isDigit(char)) return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
}
