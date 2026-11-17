//! HTTP/1.1 server: one event loop per worker thread, run-to-completion
//! handlers, no hand-offs.
//!
//! Replaces prime_server + ZeroMQ. Every worker owns a SO_REUSEPORT
//! listener, a readiness poller and a request arena; the kernel spreads
//! connections across workers. Requests are parsed in place from the
//! connection's read buffer, keep-alive and pipelining are supported, and
//! responses are written with writev straight from the arena. Limits on
//! header size, body size and idle time produce clean 4xx responses.

const std = @import("std");
const io = @import("../infra/io.zig");
const arena_mod = @import("../infra/arena.zig");
const Allocator = std.mem.Allocator;

pub const Method = enum { GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, other };

pub const Header = struct { name: []const u8, value: []const u8 };
pub const QueryParam = struct { key: []const u8, value: []const u8 };

pub const Request = struct {
    method: Method,
    /// The raw request target ("/route?json=...").
    target: []const u8,
    /// Path without the query string.
    path: []const u8,
    /// Query parameters, percent-decoded ('+' is a space), in order.
    query: []const QueryParam,
    headers: []const Header,
    body: []const u8,
    keep_alive: bool,

    /// Case-insensitive header lookup.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json;charset=utf-8",
    /// Extra header lines, each "Name: value" without CRLF.
    extra_headers: std.ArrayList([]const u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    pub fn writeBody(self: *Response, bytes: []const u8) Allocator.Error!void {
        try self.body.appendSlice(self.gpa, bytes);
    }

    pub fn addHeader(self: *Response, line: []const u8) Allocator.Error!void {
        try self.extra_headers.append(self.gpa, line);
    }
};

/// What a handler can see of the worker running it.
pub const Ctx = struct {
    worker_id: usize,
    arena: *arena_mod.Arena,
    stream: io.Stream,
    deadline: io.Deadline,

    /// True when the client disconnected or the deadline passed. Long loops
    /// call this every few thousand iterations.
    pub fn cancelled(self: *const Ctx) bool {
        return self.deadline.expired() or self.stream.peerClosed();
    }
};

pub const Handler = struct {
    context: *anyopaque,
    handle: *const fn (context: *anyopaque, ctx: *Ctx, req: *const Request, res: *Response) void,
};

pub const Config = struct {
    address: io.Address = io.Address.loopback(8002),
    /// Worker threads; 0 means one per CPU.
    threads: usize = 0,
    max_header_bytes: usize = 16 * 1024,
    max_body_bytes: usize = 64 * 1024 * 1024,
    idle_timeout_ms: u32 = 60_000,
    /// Per-request processing budget handed to handlers as a deadline.
    request_timeout_ms: u32 = 120_000,
    arena_cap_bytes: usize = 512 * 1024 * 1024,
    max_connections_per_worker: usize = 8192,
};

// ---------------------------------------------------------------------------
// Request head parsing
// ---------------------------------------------------------------------------

pub const ParseError = error{ BadRequest, HeaderTooLarge, BodyTooLarge, LengthRequired, Unsupported };

pub const Head = struct {
    method: Method,
    target: []const u8,
    headers_start: usize,
    head_len: usize,
    content_length: usize,
    keep_alive: bool,
    expect_continue: bool,
};

/// Parses a request head from the start of `buf`. Returns null when the
/// head is not complete yet.
pub fn parseHead(buf: []const u8, max_header: usize, max_body: usize) ParseError!?Head {
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        if (buf.len > max_header) return error.HeaderTooLarge;
        return null;
    };
    if (end + 4 > max_header) return error.HeaderTooLarge;
    const line_end = std.mem.indexOf(u8, buf[0..end], "\r\n") orelse end;
    const line = buf[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const sp2 = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    if (sp2 <= sp1) return error.BadRequest;
    const version = line[sp2 + 1 ..];
    const http10 = std.mem.eql(u8, version, "HTTP/1.0");
    if (!http10 and !std.mem.eql(u8, version, "HTTP/1.1")) return error.BadRequest;
    const method = std.meta.stringToEnum(Method, line[0..sp1]) orelse .other;
    const target = line[sp1 + 1 .. sp2];
    if (target.len == 0) return error.BadRequest;

    var head: Head = .{ .method = method, .target = target, .headers_start = @min(line_end + 2, end), .head_len = end + 4, .content_length = 0, .keep_alive = !http10, .expect_continue = false };
    var it = std.mem.splitSequence(u8, buf[head.headers_start..end], "\r\n");
    while (it.next()) |h| {
        if (h.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            head.content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
            if (head.content_length > max_body) return error.BodyTooLarge;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "identity")) return error.Unsupported;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) head.keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) head.keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) head.expect_continue = true;
        }
    }
    return head;
}

fn collectHeaders(arena: Allocator, buf: []const u8, head: Head) Allocator.Error![]Header {
    var list: std.ArrayList(Header) = .empty;
    var it = std.mem.splitSequence(u8, buf[head.headers_start .. head.head_len - 4], "\r\n");
    while (it.next()) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        try list.append(arena, .{ .name = std.mem.trim(u8, h[0..colon], " \t"), .value = std.mem.trim(u8, h[colon + 1 ..], " \t") });
    }
    return list.items;
}

/// Percent-decodes `s` ('+' is a space) into memory from `arena`.
pub fn urlDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "%+") == null) return s;
    const out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '+') {
            out[n] = ' ';
        } else if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                out[n] = '%';
                n += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                out[n] = '%';
                n += 1;
                continue;
            };
            out[n] = hi * 16 + lo;
            i += 2;
        } else {
            out[n] = s[i];
        }
        n += 1;
    }
    return out[0..n];
}

pub fn parseQuery(arena: Allocator, qs: []const u8) Allocator.Error![]QueryParam {
    var list: std.ArrayList(QueryParam) = .empty;
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = if (eq) |e| pair[0..e] else pair;
        const v = if (eq) |e| pair[e + 1 ..] else "";
        try list.append(arena, .{ .key = try urlDecode(arena, k), .value = try urlDecode(arena, v) });
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Response serialization
// ---------------------------------------------------------------------------

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

fn writeHead(arena: Allocator, res: *const Response, keep_alive: bool) Allocator.Error![]const u8 {
    var head: std.ArrayList(u8) = .empty;
    try head.print(arena, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\nConnection: {s}\r\n", .{
        res.status, reason(res.status), res.content_type, res.body.items.len, if (keep_alive) "keep-alive" else "close",
    });
    for (res.extra_headers.items) |h| {
        try head.appendSlice(arena, h);
        try head.appendSlice(arena, "\r\n");
    }
    try head.appendSlice(arena, "\r\n");
    return head.items;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const Conn = struct {
    stream: io.Stream,
    in: std.ArrayList(u8) = .empty,
    /// Response bytes that did not fit in the socket yet.
    pending: std.ArrayList(u8) = .empty,
    pending_off: usize = 0,
    last_active_ns: u64,
    close_after_flush: bool = false,
    sent_continue: bool = false,
};

const listener_token: u64 = std.math.maxInt(u64);

pub const Server = struct {
    gpa: Allocator,
    config: Config,
    handler: Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    threads: std.ArrayList(std.Thread) = .empty,
    /// The bound port (useful when listening on port 0).
    port: u16 = 0,
    ready: std.atomic.Value(usize) = .init(0),

    pub fn init(gpa: Allocator, config: Config, handler: Handler) Server {
        return .{ .gpa = gpa, .config = config, .handler = handler };
    }

    /// Starts the workers. Each binds its own SO_REUSEPORT listener.
    pub fn start(self: *Server) !void {
        const n = if (self.config.threads == 0) std.Thread.getCpuCount() catch 1 else self.config.threads;
        // Bind the first listener here so port 0 resolves to one port for all workers.
        const first = try io.Listener.listen(self.config.address, .{ .reuse_port = true, .nonblocking = true });
        self.port = try first.port();
        var addr = self.config.address;
        addr.port = self.port;
        for (0..n) |i| {
            const listener = if (i == 0) first else try io.Listener.listen(addr, .{ .reuse_port = true, .nonblocking = true });
            try self.threads.append(self.gpa, try std.Thread.spawn(.{}, workerMain, .{ self, i, listener }));
        }
        while (self.ready.load(.acquire) < n) std.atomic.spinLoopHint();
    }

    /// Stops accepting, finishes in-flight requests, closes connections.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        for (self.threads.items) |t| t.join();
        self.threads.deinit(self.gpa);
    }
};

fn workerMain(server: *Server, id: usize, listener: io.Listener) void {
    var w = Worker.init(server, id, listener) catch |e| {
        std.debug.print("worker {d} failed to start: {s}\n", .{ id, @errorName(e) });
        _ = server.ready.fetchAdd(1, .release);
        return;
    };
    defer w.deinit();
    _ = server.ready.fetchAdd(1, .release);
    w.run();
}

const Worker = struct {
    server: *Server,
    id: usize,
    listener: ?io.Listener,
    poller: io.Poller,
    arena: arena_mod.Arena,
    conns: std.ArrayList(?*Conn) = .empty,
    free_slots: std.ArrayList(usize) = .empty,
    live: usize = 0,

    fn init(server: *Server, id: usize, listener: io.Listener) !Worker {
        const poller = try io.Poller.init();
        errdefer poller.deinit();
        try poller.arm(listener.fd, listener_token, .read);
        return .{ .server = server, .id = id, .listener = listener, .poller = poller, .arena = arena_mod.Arena.init(server.gpa, .{ .cap_bytes = server.config.arena_cap_bytes }) };
    }

    fn deinit(self: *Worker) void {
        for (self.conns.items) |slot| if (slot) |c| self.closeConn(c);
        self.conns.deinit(self.server.gpa);
        self.free_slots.deinit(self.server.gpa);
        if (self.listener) |l| l.close();
        self.poller.deinit();
        self.arena.deinit();
    }

    fn run(self: *Worker) void {
        var events: [64]io.Event = undefined;
        var last_sweep = io.monotonicNs();
        while (true) {
            if (self.server.stopping.load(.acquire)) {
                if (self.listener) |l| {
                    l.close();
                    self.listener = null;
                }
                self.closeIdle();
                if (self.live == 0) return;
            }
            const ready = self.poller.wait(&events, 200) catch continue;
            for (ready) |ev| {
                if (ev.token == listener_token) {
                    self.acceptAll();
                    continue;
                }
                const slot: usize = @intCast(ev.token);
                const conn = (if (slot < self.conns.items.len) self.conns.items[slot] else null) orelse continue;
                self.service(slot, conn, ev);
            }
            const now = io.monotonicNs();
            if (now - last_sweep > std.time.ns_per_s) {
                last_sweep = now;
                self.sweepIdle(now);
            }
        }
    }

    fn acceptAll(self: *Worker) void {
        const l = self.listener orelse return;
        while (true) {
            const stream = l.accept() catch |e| switch (e) {
                error.WouldBlock => break,
                else => break,
            };
            if (self.live >= self.server.config.max_connections_per_worker) {
                stream.close();
                continue;
            }
            stream.setNonblocking() catch {
                stream.close();
                continue;
            };
            const conn = self.server.gpa.create(Conn) catch {
                stream.close();
                continue;
            };
            conn.* = .{ .stream = stream, .last_active_ns = io.monotonicNs() };
            const slot = self.free_slots.pop() orelse blk: {
                self.conns.append(self.server.gpa, null) catch {
                    self.server.gpa.destroy(conn);
                    stream.close();
                    continue;
                };
                break :blk self.conns.items.len - 1;
            };
            self.conns.items[slot] = conn;
            self.live += 1;
            self.poller.arm(stream.fd, slot, .read) catch self.drop(slot, conn);
        }
        self.poller.arm(l.fd, listener_token, .read) catch {};
    }

    fn drop(self: *Worker, slot: usize, conn: *Conn) void {
        self.closeConn(conn);
        self.conns.items[slot] = null;
        self.free_slots.append(self.server.gpa, slot) catch {};
        self.live -= 1;
    }

    fn closeConn(self: *Worker, conn: *Conn) void {
        conn.stream.close();
        conn.in.deinit(self.server.gpa);
        conn.pending.deinit(self.server.gpa);
        self.server.gpa.destroy(conn);
    }

    fn closeIdle(self: *Worker) void {
        for (self.conns.items, 0..) |slot_conn, slot| if (slot_conn) |c| {
            if (c.pending.items.len == c.pending_off and c.in.items.len == 0) self.drop(slot, c);
        };
    }

    fn sweepIdle(self: *Worker, now: u64) void {
        const limit = @as(u64, self.server.config.idle_timeout_ms) * std.time.ns_per_ms;
        for (self.conns.items, 0..) |slot_conn, slot| if (slot_conn) |c| {
            if (now - c.last_active_ns > limit) self.drop(slot, c);
        };
    }

    fn service(self: *Worker, slot: usize, conn: *Conn, ev: io.Event) void {
        conn.last_active_ns = io.monotonicNs();
        if (conn.pending.items.len > conn.pending_off) {
            if (!self.flush(conn)) return self.drop(slot, conn);
            if (conn.pending.items.len > conn.pending_off) {
                self.poller.arm(conn.stream.fd, slot, .write) catch self.drop(slot, conn);
                return;
            }
            if (conn.close_after_flush) return self.drop(slot, conn);
        }
        if (ev.readable or ev.hangup or !ev.writable) {
            if (!self.readAvailable(conn)) {
                // Peer closed: still answer what is already buffered, then close.
                conn.close_after_flush = true;
            }
        }
        self.processRequests(conn) catch {
            conn.close_after_flush = true;
        };
        if (conn.pending.items.len > conn.pending_off) {
            self.poller.arm(conn.stream.fd, slot, .write) catch self.drop(slot, conn);
            return;
        }
        if (conn.close_after_flush) return self.drop(slot, conn);
        self.poller.arm(conn.stream.fd, slot, .read) catch self.drop(slot, conn);
    }

    /// Reads everything available. Returns false once the peer has closed.
    fn readAvailable(self: *Worker, conn: *Conn) bool {
        const cap = self.server.config.max_header_bytes + self.server.config.max_body_bytes;
        while (true) {
            conn.in.ensureUnusedCapacity(self.server.gpa, 16 * 1024) catch return false;
            const room = conn.in.allocatedSlice()[conn.in.items.len..];
            const n = conn.stream.read(room) catch |e| switch (e) {
                error.WouldBlock => return true,
                else => return false,
            };
            if (n == 0) return false;
            conn.in.items.len += n;
            if (conn.in.items.len > cap) return true;
        }
    }

    /// Answers every complete request in the read buffer (pipelining).
    fn processRequests(self: *Worker, conn: *Conn) !void {
        const cfg = self.server.config;
        while (conn.in.items.len > 0 and conn.pending.items.len == conn.pending_off) {
            const head = parseHead(conn.in.items, cfg.max_header_bytes, cfg.max_body_bytes) catch |e| {
                const status: u16 = switch (e) {
                    error.HeaderTooLarge => 431,
                    error.BodyTooLarge => 413,
                    error.LengthRequired => 411,
                    error.Unsupported => 501,
                    error.BadRequest => 400,
                };
                try self.respondStatic(conn, status);
                conn.close_after_flush = true;
                conn.in.clearRetainingCapacity();
                return;
            } orelse return;
            const total = head.head_len + head.content_length;
            if (conn.in.items.len < total) {
                if (head.expect_continue and !conn.sent_continue) {
                    conn.sent_continue = true;
                    try self.queue(conn, &.{"HTTP/1.1 100 Continue\r\n\r\n"});
                }
                return;
            }
            conn.sent_continue = false;
            try self.handleOne(conn, head);
            std.mem.copyForwards(u8, conn.in.items[0 .. conn.in.items.len - total], conn.in.items[total..]);
            conn.in.items.len -= total;
            if (!head.keep_alive) {
                conn.close_after_flush = true;
                conn.in.clearRetainingCapacity();
                return;
            }
        }
    }

    fn handleOne(self: *Worker, conn: *Conn, head: Head) !void {
        defer self.arena.reset();
        const a = self.arena.allocator();
        const buf = conn.in.items;
        const q = std.mem.indexOfScalar(u8, head.target, '?');
        const req: Request = .{
            .method = head.method,
            .target = head.target,
            .path = if (q) |i| head.target[0..i] else head.target,
            .query = try parseQuery(a, if (q) |i| head.target[i + 1 ..] else ""),
            .headers = try collectHeaders(a, buf, head),
            .body = buf[head.head_len .. head.head_len + head.content_length],
            .keep_alive = head.keep_alive,
        };
        var res: Response = .{ .gpa = a };
        var ctx: Ctx = .{ .worker_id = self.id, .arena = &self.arena, .stream = conn.stream, .deadline = io.Deadline.fromNowMs(self.server.config.request_timeout_ms) };
        self.server.handler.handle(self.server.handler.context, &ctx, &req, &res);
        if (self.arena.cap_exceeded) {
            res = .{ .gpa = a, .status = 413 };
            self.arena.cap_exceeded = false;
        }
        const keep = head.keep_alive and !self.server.stopping.load(.acquire);
        const head_bytes = try writeHead(a, &res, keep);
        try self.queue(conn, &.{ head_bytes, if (req.method == .HEAD) "" else res.body.items });
        if (!keep) conn.close_after_flush = true;
    }

    fn respondStatic(self: *Worker, conn: *Conn, status: u16) !void {
        defer self.arena.reset();
        const a = self.arena.allocator();
        var res: Response = .{ .gpa = a, .status = status, .content_type = "text/plain" };
        try res.writeBody(reason(status));
        try self.queue(conn, &.{ try writeHead(a, &res, false), res.body.items });
    }

    /// Writes buffers now; whatever the socket does not take is copied into
    /// the connection's pending buffer and flushed when writable.
    fn queue(self: *Worker, conn: *Conn, buffers: []const []const u8) !void {
        var total: usize = 0;
        for (buffers) |b| total += b.len;
        var written: usize = 0;
        if (conn.pending.items.len == conn.pending_off) {
            while (written < total) {
                var parts: [8][]const u8 = undefined;
                var n: usize = 0;
                var skip = written;
                for (buffers) |b| {
                    if (skip >= b.len) {
                        skip -= b.len;
                        continue;
                    }
                    parts[n] = b[skip..];
                    skip = 0;
                    n += 1;
                }
                const w = conn.stream.writev(parts[0..n]) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => return e,
                };
                if (w == 0) break;
                written += w;
            }
        }
        if (written == total) return;
        if (conn.pending.items.len == conn.pending_off) {
            conn.pending.clearRetainingCapacity();
            conn.pending_off = 0;
        }
        var skip = written;
        for (buffers) |b| {
            if (skip >= b.len) {
                skip -= b.len;
                continue;
            }
            try conn.pending.appendSlice(self.server.gpa, b[skip..]);
            skip = 0;
        }
    }

    /// Writes pending bytes. Returns false on a broken connection.
    fn flush(_: *Worker, conn: *Conn) bool {
        while (conn.pending_off < conn.pending.items.len) {
            const n = conn.stream.write(conn.pending.items[conn.pending_off..]) catch |e| switch (e) {
                error.WouldBlock => return true,
                else => return false,
            };
            conn.pending_off += n;
        }
        conn.pending.clearRetainingCapacity();
        conn.pending_off = 0;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Echo = struct {
    fn handle(_: *anyopaque, ctx: *Ctx, req: *const Request, res: *Response) void {
        _ = ctx;
        if (std.mem.eql(u8, req.path, "/big")) {
            res.body.appendNTimes(res.gpa, 'x', 4 * 1024 * 1024) catch {};
            return;
        }
        res.body.print(res.gpa, "{s} {s} q={d}", .{ @tagName(req.method), req.path, req.query.len }) catch {};
        for (req.query) |p| res.body.print(res.gpa, " {s}={s}", .{ p.key, p.value }) catch {};
        if (req.body.len > 0) res.body.print(res.gpa, " body={s}", .{req.body}) catch {};
    }
};

fn startEcho(server: *Server) !void {
    var dummy: u8 = 0;
    server.* = Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 2, .max_header_bytes = 1024, .max_body_bytes = 1 << 20 }, .{ .context = &dummy, .handle = Echo.handle });
    try server.start();
}

fn readResponse(stream: io.Stream, buf: []u8) ![]const u8 {
    var got: usize = 0;
    while (true) {
        const n = try stream.read(buf[got..]);
        if (n == 0) return buf[0..got];
        got += n;
        if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n")) |he| {
            const cl_at = std.mem.indexOf(u8, buf[0..he], "Content-Length: ").?;
            const cl_end = std.mem.indexOfScalarPos(u8, buf, cl_at, '\r').?;
            const cl = try std.fmt.parseInt(usize, buf[cl_at + 16 .. cl_end], 10);
            if (got >= he + 4 + cl) return buf[0 .. he + 4 + cl];
        }
    }
}

test "head parsing" {
    const h = (try parseHead("POST /route?a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", 1024, 1024)).?;
    try testing.expectEqual(Method.POST, h.method);
    try testing.expectEqualStrings("/route?a=1", h.target);
    try testing.expectEqual(@as(usize, 5), h.content_length);
    try testing.expect(!h.keep_alive);
    try testing.expectEqual(@as(?Head, null), try parseHead("GET / HTTP/1.1\r\nHost: x\r\n", 1024, 1024));
    try testing.expectError(error.HeaderTooLarge, parseHead("GET / HTTP/1.1\r\n" ++ "X: " ++ rep('y', 2000), 1024, 1024));
    try testing.expectError(error.BodyTooLarge, parseHead("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n", 1024, 1024));
    try testing.expectError(error.BadRequest, parseHead("GARBAGE\r\n\r\n", 1024, 1024));
    try testing.expectError(error.Unsupported, parseHead("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 1024, 1024));
    const h10 = (try parseHead("GET / HTTP/1.0\r\n\r\n", 1024, 1024)).?;
    try testing.expect(!h10.keep_alive);
}

test "query decoding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const q = try parseQuery(arena_state.allocator(), "json=%7B%22a%22%3A1%7D&units=mi&flag&x=a+b&bad=%zz");
    try testing.expectEqual(@as(usize, 5), q.len);
    try testing.expectEqualStrings("{\"a\":1}", q[0].value);
    try testing.expectEqualStrings("a b", q[3].value);
    try testing.expectEqualStrings("%zz", q[4].value);
}

test "server: keep-alive, pipelining, partial writes, limits" {
    var server: Server = undefined;
    try startEcho(&server);
    defer server.stop();
    const addr = io.Address.loopback(server.port);
    var buf: [1 << 16]u8 = undefined;

    // Keep-alive: two requests on one connection.
    {
        const s = try io.Stream.connect(addr);
        defer s.close();
        try s.writeAll("GET /status?verbose=true HTTP/1.1\r\nHost: x\r\n\r\n");
        const r1 = try readResponse(s, &buf);
        try testing.expect(std.mem.startsWith(u8, r1, "HTTP/1.1 200 OK"));
        try testing.expect(std.mem.endsWith(u8, r1, "GET /status q=1 verbose=true"));
        try s.writeAll("POST /height HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
        const r2 = try readResponse(s, &buf);
        try testing.expect(std.mem.endsWith(u8, r2, "POST /height q=0 body={}"));
    }
    // Pipelining and a request split across writes.
    {
        const s = try io.Stream.connect(addr);
        defer s.close();
        try s.writeAll("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\nPOST /c HTTP/1.1\r\nContent-Le");
        try s.writeAll("ngth: 3\r\n\r\nab");
        try s.writeAll("c");
        var all: [1024]u8 = undefined;
        var got: usize = 0;
        while (std.mem.count(u8, all[0..got], "HTTP/1.1 200") < 3 or !std.mem.endsWith(u8, all[0..got], "body=abc")) got += try s.read(all[got..]);
        try testing.expect(std.mem.indexOf(u8, all[0..got], "GET /a").? < std.mem.indexOf(u8, all[0..got], "GET /b").?);
    }
    // A response much larger than the socket buffer.
    {
        const s = try io.Stream.connect(addr);
        defer s.close();
        try s.writeAll("GET /big HTTP/1.1\r\n\r\n");
        const big = try testing.allocator.alloc(u8, 5 << 20);
        defer testing.allocator.free(big);
        const r = try readResponse(s, big);
        try testing.expect(r.len > 4 * 1024 * 1024);
    }
    // Oversized header and body.
    inline for (.{ .{ "GET / HTTP/1.1\r\nX: " ++ rep('y', 1500) ++ "\r\n\r\n", "431" }, .{ "POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n", "413" }, .{ "BROKEN\r\n\r\n", "400" } }) |case| {
        const s = try io.Stream.connect(addr);
        defer s.close();
        try s.writeAll(case[0]);
        const r = try readResponse(s, &buf);
        try testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 " ++ case[1]));
        try testing.expect(std.mem.indexOf(u8, r, "Connection: close") != null);
    }
    // Connection: close is honoured.
    {
        const s = try io.Stream.connect(addr);
        defer s.close();
        try s.writeAll("GET /x HTTP/1.1\r\nConnection: close\r\n\r\n");
        _ = try readResponse(s, &buf);
        var tail: [16]u8 = undefined;
        try testing.expectEqual(@as(usize, 0), try s.read(&tail));
    }
}

fn rep(comptime ch: u8, comptime n: usize) *const [n]u8 {
    const a: [n]u8 = @splat(ch);
    return &a;
}
