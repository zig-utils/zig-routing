//! `zr bench`: replays a request corpus against any Valhalla-compatible
//! server and reports latency distributions (P0.06). It is the instrument
//! behind every scoreboard number, so it must not be the bottleneck: requests
//! are rendered once up front, connections are keep-alive and nonblocking,
//! one event loop per thread, and nothing is allocated per request once a
//! connection's response buffer has grown to the largest response seen.
//!
//! Closed loop (default): N connections, each sends its next request as soon
//! as the previous response arrives.
//!
//! Open loop (`--rate R`): request k is due at `start + k / R`. Latency is
//! measured from the moment a request was due, not from when a connection was
//! free to send it, so a stalled server shows up in the tail instead of
//! silently slowing the client down (coordinated omission).
//!
//! Corpus format: one request per line, `PATH<TAB>BODY`, for example
//! `/height<TAB>{"shape":[...]}`. A line that does not start with `/` is a
//! body for `--endpoint` (default `/route`). Blank lines and `#` comments are
//! skipped.
//!
//! Upstream has no equivalent; `run_route_scripts/perf_test/` only times
//! sequential curl calls.

const std = @import("std");
const builtin = @import("builtin");
const perf = @import("perf_counters");
const io = @import("../infra/io.zig");
const json = @import("../api/json.zig");
const JsonWriter = @import("../api/json_writer.zig").Writer;
const Allocator = std.mem.Allocator;

const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Histogram
// ---------------------------------------------------------------------------

/// Log-linear latency histogram (HDR style) over u64 nanoseconds. Values below
/// 256 are exact; above that each power of two is split into 128 buckets, so a
/// reported value is within 0.4% of the true one. Fixed size, mergeable.
pub const Histogram = struct {
    pub const sub_bits = 7;
    const sub: u64 = 1 << sub_bits;
    pub const bucket_count = (64 - sub_bits + 1) * sub;

    counts: [bucket_count]u64 = @splat(0),
    total: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    sum: u128 = 0,

    pub fn index(v: u64) usize {
        if (v < 2 * sub) return @intCast(v);
        const b: u6 = @intCast(63 - @clz(v) - sub_bits);
        return @intCast((@as(u64, b) + 1) * sub + ((v >> b) - sub));
    }

    /// The smallest and largest value that land in bucket `i`.
    pub fn bounds(i: usize) [2]u64 {
        if (i < 2 * sub) return .{ i, i };
        const b: u6 = @intCast(i / sub - 1);
        const lo = (@as(u64, i % sub) + sub) << b;
        return .{ lo, lo + ((@as(u64, 1) << b) - 1) };
    }

    pub fn record(self: *Histogram, v: u64) void {
        self.counts[index(v)] += 1;
        self.total += 1;
        self.sum += v;
        self.min = @min(self.min, v);
        self.max = @max(self.max, v);
    }

    pub fn merge(self: *Histogram, other: *const Histogram) void {
        for (&self.counts, other.counts) |*a, b| a.* += b;
        self.total += other.total;
        self.sum += other.sum;
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
    }

    /// Nearest-rank percentile (`p` in 0..100), reported as the middle of the
    /// bucket that holds that rank, clamped to the observed range.
    pub fn percentile(self: *const Histogram, p: f64) u64 {
        if (self.total == 0) return 0;
        const rank_f = @ceil(p / 100.0 * @as(f64, @floatFromInt(self.total)));
        const rank: u64 = std.math.clamp(@as(u64, @intFromFloat(@max(rank_f, 1))), 1, self.total);
        var seen: u64 = 0;
        for (self.counts, 0..) |n, i| {
            seen += n;
            if (seen >= rank) {
                const b = bounds(i);
                return std.math.clamp(b[0] + (b[1] - b[0]) / 2, self.min, self.max);
            }
        }
        return self.max;
    }

    pub fn mean(self: *const Histogram) u64 {
        if (self.total == 0) return 0;
        return @intCast(self.sum / self.total);
    }
};

// ---------------------------------------------------------------------------
// Target and corpus
// ---------------------------------------------------------------------------

pub const Target = struct {
    address: io.Address,
    /// Value of the Host header ("127.0.0.1:8002").
    host: []const u8,
};

/// Parses `http://HOST:PORT` (or `HOST:PORT`). HOST is an IPv4 address or
/// `localhost`; the bench box addresses servers by IP, so there is no DNS.
pub fn parseTarget(url: []const u8) !Target {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "http://")) rest = rest["http://".len..];
    if (std.mem.startsWith(u8, rest, "https://")) return error.HttpsUnsupported;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':');
    const host = if (colon) |i| rest[0..i] else rest;
    const port: u16 = if (colon) |i| try std.fmt.parseInt(u16, rest[i + 1 ..], 10) else 80;
    var ip: [4]u8 = undefined;
    if (std.mem.eql(u8, host, "localhost")) {
        ip = .{ 127, 0, 0, 1 };
    } else {
        var parts = std.mem.splitScalar(u8, host, '.');
        for (&ip) |*b| b.* = std.fmt.parseInt(u8, parts.next() orelse return error.InvalidHost, 10) catch return error.InvalidHost;
        if (parts.next() != null) return error.InvalidHost;
    }
    return .{ .address = .{ .ip = ip, .port = port }, .host = rest };
}

pub const Corpus = struct {
    /// Complete HTTP requests, ready to write.
    requests: []const []const u8,
    backing: []u8,
    /// Wyhash of the corpus text, so results name exactly what was replayed.
    hash: u64,

    pub fn deinit(self: Corpus, gpa: Allocator) void {
        gpa.free(self.requests);
        gpa.free(self.backing);
    }
};

pub fn loadCorpus(gpa: Allocator, text: []const u8, host: []const u8, default_endpoint: []const u8) !Corpus {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var path = default_endpoint;
        var body = line;
        if (line[0] == '/') {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            path = line[0..tab];
            body = if (tab < line.len) line[tab + 1 ..] else "";
        }
        if (body.len == 0) {
            try bytes.print(gpa, "GET {s} HTTP/1.1\r\nHost: {s}\r\n\r\n", .{ path, host });
        } else {
            try bytes.print(gpa, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ path, host, body.len });
            try bytes.appendSlice(gpa, body);
        }
        try ends.append(gpa, bytes.items.len);
    }
    if (ends.items.len == 0) return error.EmptyCorpus;

    const backing = try bytes.toOwnedSlice(gpa);
    errdefer gpa.free(backing);
    const requests = try gpa.alloc([]const u8, ends.items.len);
    var start: usize = 0;
    for (requests, ends.items) |*r, end| {
        r.* = backing[start..end];
        start = end;
    }
    return .{ .requests = requests, .backing = backing, .hash = std.hash.Wyhash.hash(0, text) };
}

// ---------------------------------------------------------------------------
// Load generator
// ---------------------------------------------------------------------------

pub const Options = struct {
    target: Target,
    connections: usize = 16,
    /// Client threads; 0 means min(CPUs, connections).
    threads: usize = 0,
    /// Open loop at this many requests per second; null is closed loop.
    rate: ?f64 = null,
    warmup_ns: u64 = 2 * ns_per_s,
    duration_ns: u64 = 10 * ns_per_s,
    /// Stop after this many measured requests instead of after `duration_ns`.
    requests: ?u64 = null,
    timeout_ns: u64 = 30 * ns_per_s,
    measure_counters: bool = false,
};

pub const Result = struct {
    hist: Histogram = .{},
    status: [600]u64 = @splat(0),
    transport_errors: u64 = 0,
    timeouts: u64 = 0,
    /// Open loop only: requests that came due but were never sent because the
    /// run ended with every connection still busy.
    unsent: u64 = 0,
    bytes_in: u64 = 0,
    /// Measurement window: end of warm-up to the last measured completion.
    window_ns: u64 = 0,
    threads: usize = 0,
    client_counters: ?perf.Counts = null,

    pub fn errorCount(self: *const Result) u64 {
        var n = self.transport_errors + self.timeouts;
        for (self.status, 0..) |count, code| {
            if (code < 200 or code >= 300) n += count;
        }
        return n;
    }

    pub fn throughput(self: *const Result) f64 {
        if (self.window_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.hist.total)) * ns_per_s / @as(f64, @floatFromInt(self.window_ns));
    }
};

const Clock = struct {
    start_ns: u64,
    warm_end_ns: u64,
    /// Duration mode: nothing new is issued (or, open loop, comes due) after this.
    stop_ns: u64,
    open_interval_ns: f64,
};

const Conn = struct {
    stream: ?io.Stream = null,
    state: enum { idle, writing, reading } = .idle,
    req: []const u8 = "",
    written: usize = 0,
    buf: []u8 = &.{},
    got: usize = 0,
    /// Where the response body ends, once the head has been parsed.
    resp_len: ?usize = null,
    close_after: bool = false,
    status: u16 = 0,
    /// When the latency clock started (the due time in open loop).
    start_ns: u64 = 0,
    deadline_ns: u64 = 0,
    measured: bool = false,
    retry_at_ns: u64 = 0,
};

const Worker = struct {
    gpa: Allocator,
    opts: *const Options,
    corpus: *const Corpus,
    clock: *const Clock,
    id: usize,
    threads: usize,
    conns: []Conn,
    poller: io.Poller,
    result: Result = .{},
    /// Measured requests this thread may issue in request-count mode.
    quota: u64 = std.math.maxInt(u64),
    issued_measured: u64 = 0,
    next_req: usize,
    /// Open loop: sequence number of the next request to come due (per thread).
    due_seq: u64 = 0,
    last_done_ns: u64 = 0,
    err: ?anyerror = null,
    counters_pending: bool = false,
    counters: ?perf.Counters = null,

    fn dueAt(self: *const Worker, seq: u64) u64 {
        // Threads interleave: thread t owns global slots t, t+T, t+2T, ...
        const slot = @as(f64, @floatFromInt(seq * self.threads + self.id));
        return self.clock.start_ns + @as(u64, @intFromFloat(slot * self.clock.open_interval_ns));
    }

    fn openLoop(self: *const Worker) bool {
        return self.opts.rate != null;
    }

    /// Whether a request starting its latency clock at `start` may be issued.
    fn mayIssue(self: *const Worker, start: u64) bool {
        if (io.termination_requested.load(.acquire)) return false;
        if (self.opts.requests != null) return self.issued_measured < self.quota;
        return start < self.clock.stop_ns;
    }

    fn inFlight(self: *const Worker) usize {
        var n: usize = 0;
        for (self.conns) |c| n += @intFromBool(c.state != .idle);
        return n;
    }

    fn run(self: *Worker) void {
        self.loop() catch |e| {
            self.err = e;
        };
        if (self.counters) |*active| self.result.client_counters = active.finish();
        for (self.conns) |*c| {
            if (c.stream) |s| s.close();
            self.gpa.free(c.buf);
        }
        self.poller.deinit();
    }

    noinline fn startCounters(self: *Worker) void {
        self.counters_pending = false;
        self.counters = perf.Counters.start();
    }

    fn loop(self: *Worker) !void {
        var events: [64]io.Event = undefined;
        while (true) {
            const now = io.monotonicNs();
            if (self.counters_pending and now >= self.clock.warm_end_ns) self.startCounters();
            if (self.openLoop()) {
                while (self.dueAt(self.due_seq) <= now and self.mayIssue(self.dueAt(self.due_seq))) {
                    const c = self.idleConn(now) orelse break;
                    try self.send(c, self.dueAt(self.due_seq), now);
                    self.due_seq += 1;
                }
            } else if (self.mayIssue(now)) {
                for (self.conns) |*c| {
                    if (c.state == .idle and self.mayIssue(now)) {
                        if (self.ensureOpen(c, now)) try self.send(c, now, now);
                    }
                }
            }

            const issuing = if (self.openLoop()) self.mayIssue(self.dueAt(self.due_seq)) else self.mayIssue(now);
            if (!issuing and self.inFlight() == 0) break;
            // A duration run whose stragglers outlive the per-request timeout
            // (or, open loop, still has requests due with every connection
            // stuck) ends there instead of waiting forever.
            if (now > self.clock.stop_ns +| self.opts.timeout_ns) {
                if (self.openLoop()) self.countUnsent();
                for (self.conns) |*c| if (c.state != .idle) self.fail(c, .timeout);
                break;
            }

            for (self.conns) |*c| {
                if (c.state != .idle and now > c.deadline_ns) self.fail(c, .timeout);
            }

            var timeout_ms: u32 = 10;
            if (self.openLoop() and issuing) {
                const due = self.dueAt(self.due_seq);
                // Spin for the last millisecond so sends are not late by a
                // whole poll tick. When the request is already due, every
                // connection is busy and the next response wakes the loop.
                if (due > now) timeout_ms = if (due - now < ns_per_ms) 0 else @intCast(@min(10, (due - now) / ns_per_ms));
            }
            const ready = try self.poller.wait(&events, timeout_ms);
            for (ready) |ev| try self.onEvent(&self.conns[@intCast(ev.token)]);
        }
    }

    fn countUnsent(self: *Worker) void {
        while (self.dueAt(self.due_seq) < self.clock.stop_ns) : (self.due_seq += 1) {
            if (self.dueAt(self.due_seq) >= self.clock.warm_end_ns) self.result.unsent += 1;
        }
    }

    fn idleConn(self: *Worker, now: u64) ?*Conn {
        for (self.conns) |*c| {
            if (c.state == .idle and self.ensureOpen(c, now)) return c;
        }
        return null;
    }

    fn ensureOpen(self: *Worker, c: *Conn, now: u64) bool {
        if (c.stream != null) return true;
        if (now < c.retry_at_ns) return false;
        const s = io.Stream.connect(self.opts.target.address) catch {
            self.result.transport_errors += 1;
            c.retry_at_ns = now + 100 * ns_per_ms;
            return false;
        };
        s.setNonblocking() catch {
            s.close();
            self.result.transport_errors += 1;
            return false;
        };
        c.stream = s;
        return true;
    }

    fn send(self: *Worker, c: *Conn, start: u64, now: u64) !void {
        c.req = self.corpus.requests[self.next_req % self.corpus.requests.len];
        self.next_req += self.threads;
        c.written = 0;
        c.got = 0;
        c.resp_len = null;
        c.close_after = false;
        c.start_ns = start;
        c.deadline_ns = now + self.opts.timeout_ns;
        c.measured = start >= self.clock.warm_end_ns;
        if (c.measured) self.issued_measured += 1;
        c.state = .writing;
        try self.pump(c);
    }

    fn onEvent(self: *Worker, c: *Conn) !void {
        if (c.state == .idle or c.stream == null) return;
        try self.pump(c);
    }

    /// Advances a connection as far as the socket allows, then re-arms it.
    fn pump(self: *Worker, c: *Conn) !void {
        const s = c.stream.?;
        while (c.state == .writing) {
            const n = s.write(c.req[c.written..]) catch |e| switch (e) {
                error.WouldBlock => return self.arm(c, .write),
                else => return self.fail(c, .transport),
            };
            c.written += n;
            if (c.written == c.req.len) c.state = .reading;
        }
        while (c.state == .reading) {
            if (c.got == c.buf.len) {
                const grown = @max(16 * 1024, c.buf.len * 2);
                c.buf = try self.gpa.realloc(c.buf, grown);
            }
            const n = s.read(c.buf[c.got..]) catch |e| switch (e) {
                error.WouldBlock => return self.arm(c, .read),
                else => return self.fail(c, .transport),
            };
            if (n == 0) return self.fail(c, .transport);
            c.got += n;
            if (c.resp_len == null) {
                parseHead(c) catch return self.fail(c, .transport);
            }
            if (c.resp_len) |len| {
                if (c.got >= len) self.complete(c);
            }
        }
    }

    fn arm(self: *Worker, c: *Conn, interest: io.Interest) !void {
        const index = (@intFromPtr(c) - @intFromPtr(self.conns.ptr)) / @sizeOf(Conn);
        self.poller.arm(c.stream.?.fd, index, interest) catch return self.fail(c, .transport);
    }

    fn complete(self: *Worker, c: *Conn) void {
        const now = io.monotonicNs();
        if (c.measured) {
            self.result.hist.record(now -| c.start_ns);
            self.result.status[@min(c.status, 599)] += 1;
            self.result.bytes_in += c.got;
            self.last_done_ns = @max(self.last_done_ns, now);
        }
        c.state = .idle;
        if (c.close_after) self.reset(c);
        // Closed loop: the connection goes straight back to work.
        if (!self.openLoop() and self.mayIssue(now) and self.ensureOpen(c, now)) {
            if (self.counters_pending and now >= self.clock.warm_end_ns) self.startCounters();
            self.send(c, now, now) catch {
                self.result.transport_errors += 1;
            };
        }
    }

    const Failure = enum { transport, timeout };

    fn fail(self: *Worker, c: *Conn, why: Failure) void {
        if (c.measured or why == .transport) switch (why) {
            .transport => self.result.transport_errors += 1,
            .timeout => self.result.timeouts += 1,
        };
        c.state = .idle;
        self.reset(c);
    }

    fn reset(self: *Worker, c: *Conn) void {
        _ = self;
        if (c.stream) |s| s.close();
        c.stream = null;
    }
};

/// Parses the response head once it is complete: status, Content-Length and
/// whether the server will close the connection.
fn parseHead(c: *Conn) !void {
    const data = c.buf[0..c.got];
    const head_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return;
    if (head_end < 12 or !std.mem.startsWith(u8, data, "HTTP/1.")) return error.BadResponse;
    c.status = std.fmt.parseInt(u16, data[9..12], 10) catch return error.BadResponse;
    var length: ?usize = null;
    var lines = std.mem.splitSequence(u8, data[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            c.close_after = std.ascii.eqlIgnoreCase(value, "close");
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.ChunkedUnsupported; // neither Valhalla nor zr chunk responses
        }
    }
    c.resp_len = head_end + 4 + (length orelse 0);
}

pub fn run(gpa: Allocator, opts: Options, corpus: *const Corpus) !Result {
    if (opts.connections == 0) return error.InvalidArgument;
    const cpus = std.Thread.getCpuCount() catch 1;
    const threads = if (opts.threads > 0) @min(opts.threads, opts.connections) else @min(cpus, opts.connections);

    const start = io.monotonicNs() + 20 * ns_per_ms;
    const clock: Clock = .{
        .start_ns = start,
        .warm_end_ns = start + opts.warmup_ns,
        .stop_ns = if (opts.requests != null) std.math.maxInt(u64) else start + opts.warmup_ns + opts.duration_ns,
        .open_interval_ns = if (opts.rate) |r| ns_per_s / r else 0,
    };

    const workers = try gpa.alloc(Worker, threads);
    defer gpa.free(workers);
    const conns = try gpa.alloc(Conn, opts.connections);
    defer gpa.free(conns);
    for (conns) |*c| c.* = .{};

    var made: usize = 0;
    defer for (workers[0..made]) |*w| w.poller.deinit();
    var first_conn: usize = 0;
    for (workers, 0..) |*w, t| {
        const n = opts.connections / threads + @intFromBool(t < opts.connections % threads);
        w.* = .{
            .gpa = gpa,
            .opts = &opts,
            .corpus = corpus,
            .clock = &clock,
            .id = t,
            .threads = threads,
            .conns = conns[first_conn .. first_conn + n],
            .poller = try io.Poller.init(),
            .next_req = t,
        };
        made += 1;
        first_conn += n;
        if (opts.requests) |total| w.quota = total / threads + @intFromBool(t < total % threads);
        w.counters_pending = opts.measure_counters and w.quota != 0;
    }
    // Connect before the clock starts so connection setup is not measured.
    for (conns) |*c| {
        c.stream = io.Stream.connect(opts.target.address) catch |e| {
            for (conns) |*o| if (o.stream) |s| s.close();
            return e;
        };
        try c.stream.?.setNonblocking();
    }

    const handles = try gpa.alloc(std.Thread, threads);
    defer gpa.free(handles);
    made = 0; // pollers are now owned (and closed) by Worker.run
    var spawned: usize = 0;
    errdefer for (handles[0..spawned]) |h| h.join();
    for (workers, handles) |*w, *h| {
        h.* = try std.Thread.spawn(.{}, Worker.run, .{w});
        spawned += 1;
    }
    for (handles) |h| h.join();

    var result: Result = .{ .threads = threads };
    var client_counters: ?perf.Counts = if (opts.measure_counters and (opts.requests orelse 1) != 0) .{} else null;
    var last_done: u64 = 0;
    for (workers) |*w| {
        if (w.err) |e| return e;
        result.hist.merge(&w.result.hist);
        for (&result.status, w.result.status) |*a, b| a.* += b;
        result.transport_errors += w.result.transport_errors;
        result.timeouts += w.result.timeouts;
        result.unsent += w.result.unsent;
        result.bytes_in += w.result.bytes_in;
        last_done = @max(last_done, w.last_done_ns);
        if (w.quota != 0) {
            if (client_counters) |*total| {
                if (w.result.client_counters) |counts| {
                    total.add(counts);
                } else {
                    // Partial worker totals would understate work per request.
                    client_counters = null;
                }
            }
        }
    }
    result.client_counters = client_counters;
    result.window_ns = last_done -| clock.warm_end_ns;
    return result;
}

// ---------------------------------------------------------------------------
// Result file
// ---------------------------------------------------------------------------

pub const Meta = struct {
    target: []const u8,
    corpus_path: []const u8,
    dataset: []const u8 = "",
    commit: []const u8 = "",
    label: []const u8 = "",
};

pub const percentiles = [_]struct { name: []const u8, p: f64 }{
    .{ .name = "p50", .p = 50 },
    .{ .name = "p90", .p = 90 },
    .{ .name = "p99", .p = 99 },
    .{ .name = "p999", .p = 99.9 },
};

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

pub fn writeResult(gpa: Allocator, out: *std.ArrayList(u8), meta: Meta, opts: Options, corpus: *const Corpus, r: *const Result) !void {
    var w = JsonWriter.init(gpa, out);
    w.setPrecision(3);
    try w.beginObject();
    try w.field("tool", "zr bench");
    try w.field("target", meta.target);
    try w.field("dataset", meta.dataset);
    try w.field("commit", meta.commit);
    try w.field("label", meta.label);
    try w.beginObjectField("corpus");
    try w.field("path", meta.corpus_path);
    try w.field("requests", @as(u64, corpus.requests.len));
    var hash_buf: [16]u8 = undefined;
    try w.field("hash", std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{corpus.hash}) catch unreachable);
    try w.endObject();
    try w.beginObjectField("hardware");
    try w.field("os", @tagName(builtin.os.tag));
    try w.field("arch", @tagName(builtin.cpu.arch));
    try w.field("cpus", @as(u64, std.Thread.getCpuCount() catch 0));
    var model_buf: [256]u8 = undefined;
    try w.field("cpu", cpuModel(&model_buf));
    try w.endObject();
    try w.field("mode", if (opts.rate != null) "open" else "closed");
    try w.field("connections", @as(u64, opts.connections));
    try w.field("threads", @as(u64, r.threads));
    if (opts.rate) |rate| try w.field("rate", rate) else {
        try w.key("rate");
        try w.null_();
    }
    try w.field("warmup_s", @as(f64, @floatFromInt(opts.warmup_ns)) / ns_per_s);
    try w.field("window_s", @as(f64, @floatFromInt(r.window_ns)) / ns_per_s);
    try w.field("requests", r.hist.total);
    try w.field("throughput_rps", r.throughput());
    try w.field("bytes_in", r.bytes_in);
    if (opts.measure_counters) {
        try w.key("client_hardware_counters");
        if (r.client_counters) |counts| {
            try w.beginObject();
            const fields = .{ "cycles", "instructions", "cache_misses", "branch_misses" };
            inline for (fields) |field| try w.field(field, @field(counts, field));
            if (counts.perUnit(r.hist.total)) |per_request| {
                try w.beginObjectField("per_request");
                inline for (fields) |field| try w.field(field, @field(per_request, field));
                try w.endObject();
            }
            try w.endObject();
        } else {
            try w.null_();
        }
    }
    try w.beginObjectField("errors");
    try w.field("total", r.errorCount());
    try w.field("transport", r.transport_errors);
    try w.field("timeouts", r.timeouts);
    try w.field("unsent", r.unsent);
    try w.beginObjectField("status");
    for (r.status, 0..) |count, code| {
        if (count == 0) continue;
        var code_buf: [3]u8 = undefined;
        try w.key(std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch unreachable);
        try w.uint(count);
    }
    try w.endObject();
    try w.endObject();
    try w.beginObjectField("latency_us");
    try w.field("min", us(if (r.hist.total == 0) 0 else r.hist.min));
    try w.field("mean", us(r.hist.mean()));
    inline for (percentiles) |p| try w.field(p.name, us(r.hist.percentile(p.p)));
    try w.field("max", us(r.hist.max));
    try w.endObject();
    try w.endObject();
}

fn cpuModel(buf: []u8) []const u8 {
    if (builtin.os.tag.isDarwin()) {
        var len: usize = buf.len;
        if (std.c.sysctlbyname("machdep.cpu.brand_string", buf.ptr, &len, null, 0) == 0 and len > 0) {
            return std.mem.sliceTo(buf[0..len], 0);
        }
        return "";
    }
    const file = io.File.open("/proc/cpuinfo", .read_only) catch return "";
    defer file.close();
    var tmp: [8192]u8 = undefined;
    const n = file.pread(&tmp, 0) catch return "";
    var lines = std.mem.splitScalar(u8, tmp[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const m = @min(v.len, buf.len);
            @memcpy(buf[0..m], v[0..m]);
            return buf[0..m];
        }
    }
    return "";
}

pub fn writeSummary(out: *std.ArrayList(u8), gpa: Allocator, r: *const Result) !void {
    try out.print(gpa, "{d} requests in {d:.2} s: {d:.0} req/s, {d} errors ({d} transport, {d} timeouts, {d} unsent)\n", .{
        r.hist.total,
        @as(f64, @floatFromInt(r.window_ns)) / ns_per_s,
        r.throughput(),
        r.errorCount(),
        r.transport_errors,
        r.timeouts,
        r.unsent,
    });
    try out.print(gpa, "latency ms: min {d:.3}  mean {d:.3}  p50 {d:.3}  p90 {d:.3}  p99 {d:.3}  p99.9 {d:.3}  max {d:.3}\n", .{
        us(if (r.hist.total == 0) 0 else r.hist.min) / 1000,
        us(r.hist.mean()) / 1000,
        us(r.hist.percentile(50)) / 1000,
        us(r.hist.percentile(90)) / 1000,
        us(r.hist.percentile(99)) / 1000,
        us(r.hist.percentile(99.9)) / 1000,
        us(r.hist.max) / 1000,
    });
}

/// `--compare a.json b.json`: one row per tracked number, with b relative to a.
pub fn compare(arena: Allocator, a_text: []const u8, b_text: []const u8, out: *std.ArrayList(u8)) !void {
    const a = try json.parse(arena, a_text);
    const b = try json.parse(arena, b_text);
    const rows = [_]struct { label: []const u8, path: []const u8 }{
        .{ .label = "throughput req/s", .path = "/throughput_rps" },
        .{ .label = "errors", .path = "/errors/total" },
        .{ .label = "latency mean us", .path = "/latency_us/mean" },
        .{ .label = "latency p50 us", .path = "/latency_us/p50" },
        .{ .label = "latency p90 us", .path = "/latency_us/p90" },
        .{ .label = "latency p99 us", .path = "/latency_us/p99" },
        .{ .label = "latency p99.9 us", .path = "/latency_us/p999" },
        .{ .label = "latency max us", .path = "/latency_us/max" },
    };
    try out.print(arena, "{s:<18} {s:>14} {s:>14} {s:>9}\n", .{ "", nonEmpty(json.get([]const u8, a, "/label", ""), "a"), nonEmpty(json.get([]const u8, b, "/label", ""), "b"), "change" });
    for (rows) |row| {
        const va = json.get(f64, a, row.path, 0);
        const vb = json.get(f64, b, row.path, 0);
        try out.print(arena, "{s:<18} {d:>14.1} {d:>14.1} ", .{ row.label, va, vb });
        if (va == 0) {
            try out.print(arena, "{s:>9}\n", .{"-"});
        } else {
            const delta = (vb - va) / va * 100;
            var cell: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&cell, "{s}{d:.1}%", .{ if (delta < 0) "-" else "+", @abs(delta) }) catch "?";
            try out.print(arena, "{s:>9}\n", .{text});
        }
    }
}

fn nonEmpty(s: []const u8, fallback: []const u8) []const u8 {
    return if (s.len == 0) fallback else s;
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

pub const usage =
    \\usage: zr bench URL --corpus FILE [options]
    \\       zr bench --compare A.json B.json
    \\
    \\  --corpus FILE       one request per line: PATH<TAB>BODY, or a body for --endpoint
    \\  --endpoint PATH     path for lines without one (default /route)
    \\  --connections N     keep-alive connections (default 16)
    \\  --threads N         client threads (default min(CPUs, connections))
    \\  --rate R            open loop at R requests/s (default: closed loop)
    \\  --duration T        measured time, e.g. 30s, 2m (default 10s)
    \\  --requests N        stop after N measured requests instead
    \\  --warmup T          excluded warm-up (default 2s)
    \\  --timeout T         per-request timeout (default 30s)
    \\  --counters          report Linux client hardware counters when available
    \\  --out FILE          write the JSON result here
    \\  --dataset NAME      --commit SHA  --label TEXT   recorded in the result
    \\
;

pub fn parseDuration(s: []const u8) !u64 {
    const units = [_]struct { suffix: []const u8, ns: u64 }{
        .{ .suffix = "ms", .ns = ns_per_ms },
        .{ .suffix = "s", .ns = ns_per_s },
        .{ .suffix = "m", .ns = 60 * ns_per_s },
    };
    for (units) |u| {
        if (std.mem.endsWith(u8, s, u.suffix)) {
            const v = try std.fmt.parseFloat(f64, s[0 .. s.len - u.suffix.len]);
            if (v < 0) return error.InvalidArgument;
            return @intFromFloat(v * @as(f64, @floatFromInt(u.ns)));
        }
    }
    const v = try std.fmt.parseFloat(f64, s);
    if (v < 0) return error.InvalidArgument;
    return @intFromFloat(v * ns_per_s);
}

/// Entry point for `zr bench`; `args` excludes the program and "bench".
pub fn main(gpa: Allocator, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;

    if (args.len >= 1 and std.mem.eql(u8, args[0], "--compare")) {
        if (args.len != 3) return usageError();
        const a = try io.readFileAlloc(arena, args[1], 64 << 20);
        const b = try io.readFileAlloc(arena, args[2], 64 << 20);
        try compare(arena, a, b, &out);
        std.debug.print("{s}", .{out.items});
        return;
    }
    if (args.len < 1 or args[0].len == 0 or args[0][0] == '-') return usageError();

    var opts: Options = .{ .target = try parseTarget(args[0]) };
    var meta: Meta = .{ .target = args[0], .corpus_path = "" };
    var endpoint: []const u8 = "/route";
    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) {
        const flag = args[i];
        i += 1;
        if (std.mem.eql(u8, flag, "--counters")) {
            opts.measure_counters = true;
            continue;
        }
        if (i >= args.len) return usageError();
        const v = args[i];
        i += 1;
        if (std.mem.eql(u8, flag, "--corpus")) {
            meta.corpus_path = v;
        } else if (std.mem.eql(u8, flag, "--endpoint")) {
            endpoint = v;
        } else if (std.mem.eql(u8, flag, "--connections")) {
            opts.connections = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, flag, "--threads")) {
            opts.threads = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, flag, "--rate")) {
            opts.rate = try std.fmt.parseFloat(f64, v);
            if (opts.rate.? <= 0) return error.InvalidArgument;
        } else if (std.mem.eql(u8, flag, "--duration")) {
            opts.duration_ns = try parseDuration(v);
        } else if (std.mem.eql(u8, flag, "--requests")) {
            opts.requests = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, flag, "--warmup")) {
            opts.warmup_ns = try parseDuration(v);
        } else if (std.mem.eql(u8, flag, "--timeout")) {
            opts.timeout_ns = try parseDuration(v);
        } else if (std.mem.eql(u8, flag, "--out")) {
            out_path = v;
        } else if (std.mem.eql(u8, flag, "--dataset")) {
            meta.dataset = v;
        } else if (std.mem.eql(u8, flag, "--commit")) {
            meta.commit = v;
        } else if (std.mem.eql(u8, flag, "--label")) {
            meta.label = v;
        } else {
            std.debug.print("unknown option {s}\n", .{flag});
            return usageError();
        }
    }
    if (meta.corpus_path.len == 0) return usageError();

    const text = try io.readFileAlloc(arena, meta.corpus_path, 4 << 30);
    const corpus = try loadCorpus(gpa, text, opts.target.host, endpoint);
    defer corpus.deinit(gpa);

    io.installTerminationHandler();
    const result = try gpa.create(Result);
    defer gpa.destroy(result);
    result.* = try run(gpa, opts, &corpus);

    try writeSummary(&out, arena, result);
    if (opts.measure_counters) {
        if (result.client_counters) |counts| {
            if (counts.perUnit(result.hist.total)) |per| {
                try out.print(arena, "client per completed request: {d:.1} cycles, {d:.1} instructions, {d:.1} cache misses, {d:.1} branch misses\n", .{
                    per.cycles, per.instructions, per.cache_misses, per.branch_misses,
                });
            }
        } else {
            try out.appendSlice(arena, "client hardware counters unavailable\n");
        }
    }
    std.debug.print("{s}", .{out.items});
    if (out_path) |path| {
        var file_bytes: std.ArrayList(u8) = .empty;
        try writeResult(arena, &file_bytes, meta, opts, &corpus, result);
        try file_bytes.append(arena, '\n');
        try io.writeFile(path, file_bytes.items);
    }
}

fn usageError() error{InvalidArgument} {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgument;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const http = @import("../server/http.zig");

test "histogram buckets cover every value and stay within 0.4%" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        const v = random.int(u64) >> random.int(u6);
        const idx = Histogram.index(v);
        try testing.expect(idx < Histogram.bucket_count);
        const b = Histogram.bounds(idx);
        try testing.expect(b[0] <= v and v <= b[1]);
        if (v > 0) try testing.expect(@as(f64, @floatFromInt(b[1] - b[0])) / @as(f64, @floatFromInt(v)) <= 1.0 / 128.0);
    }
    try testing.expectEqual(Histogram.bucket_count - 1, Histogram.index(std.math.maxInt(u64)));
}

test "histogram percentiles match exact nearest rank within 1%" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const n = 100_000;
    const values = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(values);
    const hist = try testing.allocator.create(Histogram);
    defer testing.allocator.destroy(hist);
    hist.* = .{};
    for (values) |*v| {
        // Long-tailed latencies: mostly ~1 ms, a heavy tail into seconds.
        const base = 200_000 + random.uintLessThan(u64, 1_600_000);
        v.* = if (random.uintLessThan(u32, 100) == 0) base * (1 + random.uintLessThan(u64, 2000)) else base;
        hist.record(v.*);
    }
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    for ([_]f64{ 1, 10, 50, 90, 99, 99.9, 99.99, 100 }) |p| {
        const rank: usize = @intFromFloat(@ceil(p / 100.0 * n));
        const exact: f64 = @floatFromInt(values[rank - 1]);
        const got: f64 = @floatFromInt(hist.percentile(p));
        try testing.expect(@abs(got - exact) / exact < 0.01);
    }
    try testing.expectEqual(values[0], hist.min);
    try testing.expectEqual(values[n - 1], hist.max);

    var merged: Histogram = .{};
    merged.merge(hist);
    merged.merge(hist);
    try testing.expectEqual(2 * hist.total, merged.total);
    try testing.expectEqual(hist.percentile(99), merged.percentile(99));
}

test "target and duration parsing" {
    const t = try parseTarget("http://127.0.0.1:8002/");
    try testing.expectEqual(@as(u16, 8002), t.address.port);
    try testing.expectEqualStrings("127.0.0.1:8002", t.host);
    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, (try parseTarget("localhost:9")).address.ip);
    try testing.expectError(error.InvalidHost, parseTarget("http://example.com:80"));
    try testing.expectError(error.HttpsUnsupported, parseTarget("https://1.2.3.4"));
    try testing.expectEqual(@as(u64, 1500 * ns_per_ms), try parseDuration("1.5s"));
    try testing.expectEqual(@as(u64, 250 * ns_per_ms), try parseDuration("250ms"));
    try testing.expectEqual(@as(u64, 120 * ns_per_s), try parseDuration("2m"));
    try testing.expectEqual(@as(u64, 3 * ns_per_s), try parseDuration("3"));
}

test "corpus lines become complete requests" {
    const corpus = try loadCorpus(testing.allocator, "# comment\n/height\t{\"range\":true}\n\n{\"costing\":\"auto\"}\r\n/status\n", "h:1", "/route");
    defer corpus.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), corpus.requests.len);
    try testing.expectEqualStrings("POST /height HTTP/1.1\r\nHost: h:1\r\nContent-Type: application/json\r\nContent-Length: 14\r\n\r\n{\"range\":true}", corpus.requests[0]);
    try testing.expect(std.mem.startsWith(u8, corpus.requests[1], "POST /route HTTP/1.1\r\n"));
    try testing.expect(std.mem.endsWith(u8, corpus.requests[1], "\r\n\r\n{\"costing\":\"auto\"}"));
    try testing.expectEqualStrings("GET /status HTTP/1.1\r\nHost: h:1\r\n\r\n", corpus.requests[2]);
    try testing.expectError(error.EmptyCorpus, loadCorpus(testing.allocator, "# nothing\n", "h", "/route"));
}

const Responder = struct {
    fn handle(_: *anyopaque, _: *http.Ctx, req: *const http.Request, res: *http.Response) void {
        if (std.mem.eql(u8, req.path, "/missing")) res.status = 404;
        // A body larger than the client's first read buffer.
        const n: usize = if (std.mem.eql(u8, req.path, "/big")) 100_000 else 2;
        res.body.appendNTimes(res.gpa, 'x', n) catch {};
    }
};

fn startResponder(server: *http.Server) !void {
    var dummy: u8 = 0;
    server.* = http.Server.init(testing.allocator, .{ .address = .loopback_any_port, .threads = 2 }, .{ .context = &dummy, .handle = Responder.handle });
    try server.start();
}

test "closed loop drives a server and counts statuses" {
    var server: http.Server = undefined;
    try startResponder(&server);
    defer server.stop();
    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{server.port});
    const corpus = try loadCorpus(testing.allocator, "/ok\t{}\n/big\n/missing\n", host, "/route");
    defer corpus.deinit(testing.allocator);

    const result = try testing.allocator.create(Result);
    defer testing.allocator.destroy(result);
    result.* = try run(testing.allocator, .{
        .target = try parseTarget(host),
        .connections = 3,
        .threads = 2,
        .warmup_ns = 20 * ns_per_ms,
        .requests = 300,
    }, &corpus);
    try testing.expectEqual(@as(u64, 300), result.hist.total);
    try testing.expectEqual(@as(u64, 0), result.transport_errors + result.timeouts);
    try testing.expectEqual(@as(u64, 300), result.status[200] + result.status[404]);
    try testing.expect(result.status[404] >= 50);
    try testing.expectEqual(result.status[404], result.errorCount());
    try testing.expect(result.throughput() > 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(u8) = .empty;
    try writeResult(arena_state.allocator(), &out, .{ .target = host, .corpus_path = "x", .label = "a" }, .{ .target = undefined, .connections = 3 }, &corpus, result);
    const parsed = try json.parse(arena_state.allocator(), out.items);
    try testing.expectEqual(@as(i64, 300), json.get(i64, parsed, "/requests", 0));
    try testing.expectEqualStrings("closed", json.get([]const u8, parsed, "/mode", ""));
    try testing.expect(json.get(f64, parsed, "/latency_us/p50", 0) > 0);

    var table: std.ArrayList(u8) = .empty;
    try compare(arena_state.allocator(), out.items, out.items, &table);
    try testing.expect(std.mem.indexOf(u8, table.items, "latency p99 us") != null);
    try testing.expect(std.mem.indexOf(u8, table.items, "+0.0%") != null);

    const meta: Meta = .{ .target = host, .corpus_path = "x" };
    const opts: Options = .{ .target = undefined, .measure_counters = true };
    out.clearRetainingCapacity();
    try writeResult(arena_state.allocator(), &out, meta, opts, &corpus, result);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"client_hardware_counters\":null") != null);

    result.client_counters = .{ .instructions = 12_000, .cache_misses = 1_500 };
    out.clearRetainingCapacity();
    try writeResult(arena_state.allocator(), &out, meta, opts, &corpus, result);
    const measured = try json.parse(arena_state.allocator(), out.items);
    try testing.expectEqual(12_000, json.get(i64, measured, "/client_hardware_counters/instructions", -1));
    try testing.expectEqual(5, json.get(f64, measured, "/client_hardware_counters/per_request/cache_misses", -1));
}

test "open loop holds the requested rate" {
    var server: http.Server = undefined;
    try startResponder(&server);
    defer server.stop();
    var host_buf: [32]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{server.port});
    const corpus = try loadCorpus(testing.allocator, "/ok\t{}\n", host, "/route");
    defer corpus.deinit(testing.allocator);

    const result = try testing.allocator.create(Result);
    defer testing.allocator.destroy(result);
    result.* = try run(testing.allocator, .{
        .target = try parseTarget(host),
        .connections = 4,
        .threads = 2,
        .rate = 2000,
        .warmup_ns = 50 * ns_per_ms,
        .duration_ns = 300 * ns_per_ms,
    }, &corpus);
    // 2000 req/s for 0.3 s is 600 requests, give or take the boundary slot.
    try testing.expect(result.hist.total + result.unsent >= 598 and result.hist.total + result.unsent <= 602);
    try testing.expectEqual(@as(u64, 0), result.transport_errors + result.timeouts);
}
