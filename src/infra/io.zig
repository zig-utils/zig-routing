//! The IO shim: the only file that talks to the operating system for clocks,
//! files, memory maps, sockets and readiness polling.
//!
//! The Zig 0.17-dev standard library moves these APIs often (std.time.Timer,
//! std.fs.cwd and blocking sockets are gone, and std.Io wants an `Io` handle
//! threaded everywhere). Everything here goes straight to libc through
//! `std.c`, so a toolchain bump should touch this file and little else.
//! Other source files must not use `std.Io.{Dir,File,net,Clock,Threaded}`;
//! CI greps for it.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

comptime {
    if (!is_linux and !is_darwin) @compileError("zig-routing supports Linux and macOS");
}

pub const Error = error{
    AccessDenied,
    FileNotFound,
    AddressInUse,
    ConnectionRefused,
    ConnectionReset,
    BrokenPipe,
    WouldBlock,
    Interrupted,
    OutOfMemory,
    InvalidArgument,
    Misaligned,
    OutOfBounds,
    Unexpected,
};

fn fail(rc: anytype) Error {
    return switch (c.errno(rc)) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .NOMEM => error.OutOfMemory,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

fn checkInt(rc: c_int) Error!c_int {
    if (rc < 0) return fail(rc);
    return rc;
}

fn checkSize(rc: isize) Error!usize {
    if (rc < 0) return fail(rc);
    return @intCast(rc);
}

// ---------------------------------------------------------------------------
// Clocks and deadlines
// ---------------------------------------------------------------------------

const monotonic_clock: c.clockid_t = if (is_darwin) .UPTIME_RAW else .MONOTONIC;

/// Nanoseconds on a clock that never goes backwards and does not count suspend
/// on macOS. Only differences are meaningful.
pub fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(monotonic_clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Nanoseconds since the Unix epoch on the wall clock.
pub fn wallNs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Seconds since the Unix epoch on the wall clock.
pub fn wallSeconds() i64 {
    return @divFloor(wallNs(), std.time.ns_per_s);
}

/// Measures elapsed time on the monotonic clock.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() Timer {
        return .{ .start_ns = monotonicNs() };
    }

    pub fn read(self: Timer) u64 {
        return monotonicNs() - self.start_ns;
    }

    /// Returns the elapsed time and restarts the timer.
    pub fn lap(self: *Timer) u64 {
        const now = monotonicNs();
        defer self.start_ns = now;
        return now - self.start_ns;
    }
};

/// A point on the monotonic clock after which work must stop. `none` never
/// expires. Checked inside every long loop (search, build, serialization).
pub const Deadline = struct {
    at_ns: u64,

    pub const none: Deadline = .{ .at_ns = std.math.maxInt(u64) };

    pub fn fromNow(duration_ns: u64) Deadline {
        return .{ .at_ns = monotonicNs() +| duration_ns };
    }

    pub fn fromNowMs(ms: u64) Deadline {
        return fromNow(ms *| std.time.ns_per_ms);
    }

    pub fn expired(self: Deadline) bool {
        return self.at_ns != std.math.maxInt(u64) and monotonicNs() >= self.at_ns;
    }

    pub fn remainingNs(self: Deadline) u64 {
        if (self.at_ns == std.math.maxInt(u64)) return std.math.maxInt(u64);
        const now = monotonicNs();
        return if (now >= self.at_ns) 0 else self.at_ns - now;
    }

    /// The earlier of two deadlines.
    pub fn min(a: Deadline, b: Deadline) Deadline {
        return if (a.at_ns <= b.at_ns) a else b;
    }
};

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

pub const OpenMode = enum { read_only, read_write, create_truncate };

pub const File = struct {
    fd: c.fd_t,

    pub fn open(path: []const u8, mode: OpenMode) Error!File {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len) return error.InvalidArgument;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        var flags: c.O = .{ .CLOEXEC = true };
        switch (mode) {
            .read_only => flags.ACCMODE = .RDONLY,
            .read_write => flags.ACCMODE = .RDWR,
            .create_truncate => {
                flags.ACCMODE = .RDWR;
                flags.CREAT = true;
                flags.TRUNC = true;
            },
        }
        const fd = try checkInt(c.open(z, flags, @as(c.mode_t, 0o644)));
        return .{ .fd = fd };
    }

    pub fn close(self: File) void {
        _ = c.close(self.fd);
    }

    pub fn size(self: File) Error!u64 {
        var st: c.Stat = undefined;
        _ = try checkInt(c.fstat(self.fd, &st));
        return @intCast(st.size);
    }

    /// Reads up to `buf.len` bytes at `offset`. Returns the count read (0 at end).
    pub fn pread(self: File, buf: []u8, offset: u64) Error!usize {
        while (true) {
            const rc = c.pread(self.fd, buf.ptr, buf.len, @intCast(offset));
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            return checkSize(rc);
        }
    }

    /// Reads exactly `buf.len` bytes at `offset` or fails with OutOfBounds.
    pub fn preadAll(self: File, buf: []u8, offset: u64) Error!void {
        var done: usize = 0;
        while (done < buf.len) {
            const n = try self.pread(buf[done..], offset + done);
            if (n == 0) return error.OutOfBounds;
            done += n;
        }
    }

    pub fn writeAll(self: File, bytes: []const u8) Error!void {
        try writeAllFd(self.fd, bytes);
    }
};

/// Reads a whole file into memory owned by `allocator`.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) (Error || error{FileTooBig})![]u8 {
    const file = try File.open(path, .read_only);
    defer file.close();
    const len = try file.size();
    if (len > max_bytes) return error.FileTooBig;
    const buf = allocator.alloc(u8, @intCast(len)) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    try file.preadAll(buf, 0);
    return buf;
}

/// Writes a whole file, replacing any existing one.
pub fn writeFile(path: []const u8, bytes: []const u8) Error!void {
    const file = try File.open(path, .create_truncate);
    defer file.close();
    try file.writeAll(bytes);
}

// ---------------------------------------------------------------------------
// Memory maps
// ---------------------------------------------------------------------------

pub const page_size = std.heap.page_size_min;

pub const MapMode = enum {
    /// Immutable graph sections: shared, read-only.
    read_only,
    /// Overlays written in place by another process (live traffic).
    shared_writable,
};

pub const Advice = enum {
    normal,
    /// Prefetch now (startup warm-up of hot sections).
    will_need,
    /// Point lookups (cold attributes): no read-ahead.
    random,
    /// Scans (build stages): aggressive read-ahead.
    sequential,
    /// Back with transparent huge pages where the OS supports it (Linux).
    huge_page,
    /// Pages may be dropped.
    dont_need,
};

pub const Mapping = struct {
    bytes: []align(page_size) u8,

    /// Maps a whole file. An empty file maps to an empty slice.
    pub fn mapFile(path: []const u8, mode: MapMode) Error!Mapping {
        const file = try File.open(path, if (mode == .read_only) .read_only else .read_write);
        defer file.close();
        return mapFd(file, mode);
    }

    pub fn mapFd(file: File, mode: MapMode) Error!Mapping {
        const len: usize = @intCast(try file.size());
        if (len == 0) return .{ .bytes = &.{} };
        const prot: c.PROT = if (mode == .read_only) .{ .READ = true } else .{ .READ = true, .WRITE = true };
        var flags: c.MAP = .{ .TYPE = .SHARED };
        _ = &flags;
        const ptr = c.mmap(null, len, prot, flags, file.fd, 0);
        if (ptr == c.MAP_FAILED) return fail(@as(c_int, -1));
        const base: [*]align(page_size) u8 = @ptrCast(@alignCast(ptr));
        return .{ .bytes = base[0..len] };
    }

    pub fn unmap(self: Mapping) void {
        if (self.bytes.len == 0) return;
        _ = c.munmap(@ptrCast(self.bytes.ptr), self.bytes.len);
    }

    /// Advises the kernel about a page-aligned range (offset is rounded down,
    /// end rounded up). Unsupported advice is a no-op.
    pub fn advise(self: Mapping, offset: usize, len: usize, advice: Advice) Error!void {
        if (self.bytes.len == 0 or len == 0) return;
        const start = std.mem.alignBackward(usize, offset, page_size);
        const end = @min(self.bytes.len, std.mem.alignForward(usize, offset + len, page_size));
        if (start >= end) return;
        const code: u32 = switch (advice) {
            .normal => c.MADV.NORMAL,
            .will_need => c.MADV.WILLNEED,
            .random => c.MADV.RANDOM,
            .sequential => c.MADV.SEQUENTIAL,
            .dont_need => c.MADV.DONTNEED,
            .huge_page => if (is_linux) c.MADV.HUGEPAGE else return,
        };
        const ptr: *align(page_size) anyopaque = @ptrCast(@alignCast(self.bytes.ptr + start));
        _ = try checkInt(c.madvise(ptr, end - start, code));
    }

    pub fn adviseAll(self: Mapping, advice: Advice) Error!void {
        return self.advise(0, self.bytes.len, advice);
    }

    /// Pins the whole mapping in memory. Fails with AccessDenied or
    /// OutOfMemory when the process limit (RLIMIT_MEMLOCK) is too low.
    pub fn lock(self: Mapping) Error!void {
        if (self.bytes.len == 0) return;
        _ = try checkInt(c.mlock(@ptrCast(self.bytes.ptr), self.bytes.len));
    }

    /// A typed view of `count` records of `T` starting at byte `offset`. The
    /// single place on-disk bytes become typed slices: checks bounds and
    /// alignment, then casts once.
    pub fn slice(self: Mapping, comptime T: type, offset: usize, count: usize) Error![]const T {
        return typedSlice(T, self.bytes, offset, count);
    }

    pub fn sliceMut(self: Mapping, comptime T: type, offset: usize, count: usize) Error![]T {
        const view = try typedSlice(T, self.bytes, offset, count);
        return @constCast(view);
    }
};

/// Bounds- and alignment-checked typed view over raw bytes.
pub fn typedSlice(comptime T: type, bytes: []const u8, offset: usize, count: usize) Error![]const T {
    const size = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfBounds;
    const end = std.math.add(usize, offset, size) catch return error.OutOfBounds;
    if (end > bytes.len) return error.OutOfBounds;
    if (count == 0) return &.{};
    const addr = @intFromPtr(bytes.ptr) + offset;
    if (addr % @alignOf(T) != 0) return error.Misaligned;
    const base: [*]const T = @ptrFromInt(addr);
    return base[0..count];
}

// ---------------------------------------------------------------------------
// Sockets
// ---------------------------------------------------------------------------

fn writeAllFd(fd: c.fd_t, bytes: []const u8) Error!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = c.write(fd, bytes.ptr + done, bytes.len - done);
        if (rc < 0 and c.errno(rc) == .INTR) continue;
        done += try checkSize(rc);
    }
}

pub const Address = struct {
    /// IPv4 address in network byte order as four octets.
    ip: [4]u8,
    port: u16,

    pub const loopback_any_port: Address = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 };

    pub fn loopback(port: u16) Address {
        return .{ .ip = .{ 127, 0, 0, 1 }, .port = port };
    }

    pub fn any(port: u16) Address {
        return .{ .ip = .{ 0, 0, 0, 0 }, .port = port };
    }

    fn toSockaddr(self: Address) c.sockaddr.in {
        var sa: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
        if (is_darwin) sa.len = @sizeOf(c.sockaddr.in);
        sa.family = c.AF.INET;
        sa.port = std.mem.nativeToBig(u16, self.port);
        sa.addr = @bitCast(self.ip);
        return sa;
    }
};

pub const ListenOptions = struct {
    backlog: u31 = 1024,
    /// One listener per thread on the same port (the kernel load-balances).
    reuse_port: bool = false,
    nonblocking: bool = false,
};

fn setOpt(fd: c.fd_t, level: i32, name: u32, value: c_int) Error!void {
    _ = try checkInt(c.setsockopt(fd, level, name, &value, @sizeOf(c_int)));
}

fn setFdNonblocking(fd: c.fd_t) Error!void {
    const flags = try checkInt(c.fcntl(fd, c.F.GETFL));
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    _ = try checkInt(c.fcntl(fd, c.F.SETFL, flags | nonblock));
}

pub const Listener = struct {
    fd: c.fd_t,

    pub fn listen(address: Address, options: ListenOptions) Error!Listener {
        const fd = try checkInt(c.socket(c.AF.INET, c.SOCK.STREAM, 0));
        errdefer _ = c.close(fd);
        try setOpt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, 1);
        if (options.reuse_port) try setOpt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, 1);
        const sa = address.toSockaddr();
        _ = try checkInt(c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)));
        _ = try checkInt(c.listen(fd, options.backlog));
        if (options.nonblocking) try setFdNonblocking(fd);
        return .{ .fd = fd };
    }

    /// The bound port (useful after listening on port 0).
    pub fn port(self: Listener) Error!u16 {
        var sa: c.sockaddr.in = undefined;
        var len: c.socklen_t = @sizeOf(c.sockaddr.in);
        _ = try checkInt(c.getsockname(self.fd, @ptrCast(&sa), &len));
        return std.mem.bigToNative(u16, sa.port);
    }

    /// Accepts one connection. Returns WouldBlock on a nonblocking listener
    /// with nothing pending.
    pub fn accept(self: Listener) Error!Stream {
        while (true) {
            const rc = c.accept(self.fd, null, null);
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            const fd = try checkInt(rc);
            errdefer _ = c.close(fd);
            try setOpt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
            if (is_darwin) try setOpt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, 1);
            return .{ .fd = fd };
        }
    }

    pub fn close(self: Listener) void {
        _ = c.close(self.fd);
    }
};

pub const Stream = struct {
    fd: c.fd_t,

    /// Opens a blocking TCP connection (tests and the bench client).
    pub fn connect(address: Address) Error!Stream {
        const fd = try checkInt(c.socket(c.AF.INET, c.SOCK.STREAM, 0));
        errdefer _ = c.close(fd);
        const sa = address.toSockaddr();
        while (true) {
            const rc = c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in));
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            _ = try checkInt(rc);
            break;
        }
        try setOpt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
        if (is_darwin) try setOpt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, 1);
        return .{ .fd = fd };
    }

    pub fn setNonblocking(self: Stream) Error!void {
        return setFdNonblocking(self.fd);
    }

    /// Reads up to `buf.len` bytes; 0 means the peer closed.
    pub fn read(self: Stream, buf: []u8) Error!usize {
        while (true) {
            const rc = c.read(self.fd, buf.ptr, buf.len);
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            return checkSize(rc);
        }
    }

    pub fn write(self: Stream, bytes: []const u8) Error!usize {
        while (true) {
            const rc = c.write(self.fd, bytes.ptr, bytes.len);
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            return checkSize(rc);
        }
    }

    pub fn writeAll(self: Stream, bytes: []const u8) Error!void {
        return writeAllFd(self.fd, bytes);
    }

    /// Writes all buffers with as few syscalls as possible (responses are
    /// assembled as a list of arena slices and never copied together).
    pub fn writevAll(self: Stream, buffers: []const []const u8) Error!void {
        var iov: [16]c.iovec_const = undefined;
        var index: usize = 0;
        var skip: usize = 0; // bytes of buffers[index] already written
        while (index < buffers.len) {
            var n: usize = 0;
            var i = index;
            while (i < buffers.len and n < iov.len) : (i += 1) {
                const part = if (i == index) buffers[i][skip..] else buffers[i];
                if (part.len == 0) continue;
                iov[n] = .{ .base = part.ptr, .len = part.len };
                n += 1;
            }
            if (n == 0) return;
            const rc = c.writev(self.fd, &iov, @intCast(n));
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            var written = try checkSize(rc);
            while (index < buffers.len) {
                const left = buffers[index].len - skip;
                if (written < left) {
                    skip += written;
                    break;
                }
                written -= left;
                index += 1;
                skip = 0;
            }
        }
    }

    /// One writev call: returns the bytes written (possibly fewer than the
    /// total) or WouldBlock on a nonblocking socket that cannot take more.
    pub fn writev(self: Stream, buffers: []const []const u8) Error!usize {
        var iov: [16]c.iovec_const = undefined;
        var n: usize = 0;
        for (buffers) |b| {
            if (b.len == 0) continue;
            if (n == iov.len) break;
            iov[n] = .{ .base = b.ptr, .len = b.len };
            n += 1;
        }
        if (n == 0) return 0;
        while (true) {
            const rc = c.writev(self.fd, &iov, @intCast(n));
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            return checkSize(rc);
        }
    }

    /// Whether the peer has closed its side, checked without blocking or
    /// consuming data (a zero-byte peek). Used to cancel work for a client
    /// that went away.
    pub fn peerClosed(self: Stream) bool {
        var b: [1]u8 = undefined;
        const rc = c.recv(self.fd, &b, 1, c.MSG.PEEK | c.MSG.DONTWAIT);
        if (rc == 0) return true;
        if (rc < 0) {
            const e = c.errno(rc);
            return e != .AGAIN and e != .INTR;
        }
        return false;
    }

    pub fn shutdownWrite(self: Stream) void {
        _ = c.shutdown(self.fd, 1);
    }

    pub fn close(self: Stream) void {
        _ = c.close(self.fd);
    }
};

// ---------------------------------------------------------------------------
// Readiness polling (kqueue on macOS, epoll on Linux)
// ---------------------------------------------------------------------------

pub const Interest = enum { read, write };

pub const Event = struct {
    token: u64,
    readable: bool,
    writable: bool,
    hangup: bool,
};

pub const Poller = struct {
    fd: c.fd_t,

    pub fn init() Error!Poller {
        const fd = if (is_linux)
            try checkInt(c.epoll_create1(std.os.linux.EPOLL.CLOEXEC))
        else
            try checkInt(c.kqueue());
        return .{ .fd = fd };
    }

    pub fn deinit(self: Poller) void {
        _ = c.close(self.fd);
    }

    /// Registers `fd` for one-shot readiness. Re-arm after handling an event.
    pub fn arm(self: Poller, fd: c.fd_t, token: u64, interest: Interest) Error!void {
        if (is_linux) {
            const linux = std.os.linux;
            var ev: c.epoll_event = .{
                .events = (if (interest == .read) linux.EPOLL.IN else linux.EPOLL.OUT) | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
                .data = .{ .u64 = token },
            };
            if (c.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, fd, &ev) < 0) {
                _ = try checkInt(c.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev));
            }
        } else {
            const change: c.Kevent = .{
                .ident = @intCast(fd),
                .filter = if (interest == .read) c.EVFILT.READ else c.EVFILT.WRITE,
                .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intCast(token),
            };
            const changes = [1]c.Kevent{change};
            var none: [0]c.Kevent = undefined;
            _ = try checkInt(c.kevent(self.fd, &changes, 1, &none, 0, null));
        }
    }

    /// Waits for events. `timeout_ms` null blocks. Returns the events filled.
    pub fn wait(self: Poller, out: []Event, timeout_ms: ?u32) Error![]Event {
        if (out.len == 0) return out[0..0];
        if (is_linux) {
            const linux = std.os.linux;
            var raw: [64]c.epoll_event = undefined;
            const max = @min(raw.len, out.len);
            const t: c_int = if (timeout_ms) |ms| @intCast(ms) else -1;
            const rc = c.epoll_wait(self.fd, &raw, @intCast(max), t);
            if (rc < 0 and c.errno(rc) == .INTR) return out[0..0];
            const n: usize = @intCast(try checkInt(rc));
            for (raw[0..n], 0..) |ev, i| out[i] = .{
                .token = ev.data.u64,
                .readable = ev.events & linux.EPOLL.IN != 0,
                .writable = ev.events & linux.EPOLL.OUT != 0,
                .hangup = ev.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP | linux.EPOLL.ERR) != 0,
            };
            return out[0..n];
        } else {
            var raw: [64]c.Kevent = undefined;
            const max = @min(raw.len, out.len);
            var ts: c.timespec = undefined;
            const tsp: ?*const c.timespec = if (timeout_ms) |ms| blk: {
                ts = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
                break :blk &ts;
            } else null;
            const no_changes: [0]c.Kevent = undefined;
            const rc = c.kevent(self.fd, &no_changes, 0, &raw, @intCast(max), tsp);
            if (rc < 0 and c.errno(rc) == .INTR) return out[0..0];
            const n: usize = @intCast(try checkInt(rc));
            for (raw[0..n], 0..) |ev, i| out[i] = .{
                .token = @intCast(ev.udata),
                .readable = ev.filter == c.EVFILT.READ,
                .writable = ev.filter == c.EVFILT.WRITE,
                .hangup = ev.flags & c.EV.EOF != 0,
            };
            return out[0..n];
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpPath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/zig-routing-test-{d}-{s}", .{ c.getpid(), name }) catch unreachable;
}

fn unlink(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(@ptrCast(&buf));
}

test "clocks move forward and deadlines expire" {
    const a = monotonicNs();
    const timer = Timer.start();
    while (timer.read() == 0) {}
    try testing.expect(monotonicNs() > a);
    try testing.expect(wallSeconds() > 1_700_000_000);

    try testing.expect(!Deadline.none.expired());
    try testing.expectEqual(std.math.maxInt(u64), Deadline.none.remainingNs());
    const past: Deadline = .{ .at_ns = monotonicNs() - 1 };
    try testing.expect(past.expired());
    try testing.expectEqual(@as(u64, 0), past.remainingNs());
    const later = Deadline.fromNowMs(60_000);
    try testing.expect(!later.expired());
    try testing.expectEqual(past, Deadline.min(past, later));
}

const Record = extern struct { id: u32, value: u32 };

test "mmap a file and read typed records" {
    var path_buf: [256]u8 = undefined;
    const path = tmpPath(&path_buf, "records");
    defer unlink(path);

    var records: [1000]Record = undefined;
    for (&records, 0..) |*r, i| r.* = .{ .id = @intCast(i), .value = @intCast(i * 3) };
    try writeFile(path, std.mem.sliceAsBytes(&records));

    const map = try Mapping.mapFile(path, .read_only);
    defer map.unmap();
    try map.adviseAll(.will_need);
    try map.advise(8, 4096, .random);
    try map.adviseAll(.huge_page);

    const view = try map.slice(Record, 0, records.len);
    try testing.expectEqual(@as(u32, 999), view[999].id);
    try testing.expectEqual(@as(u32, 2997), view[999].value);
    try testing.expectError(error.OutOfBounds, map.slice(Record, 8, records.len));
    try testing.expectError(error.Misaligned, map.slice(Record, 2, 1));

    const file = try File.open(path, .read_only);
    defer file.close();
    try testing.expectEqual(@as(u64, @sizeOf(@TypeOf(records))), try file.size());
    var four: [4]u8 = undefined;
    try file.preadAll(&four, 8);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &four, .little));

    const whole = try readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(whole);
    try testing.expectEqual(@as(usize, 8000), whole.len);
}

test "shared writable mapping is visible to a second mapping" {
    var path_buf: [256]u8 = undefined;
    const path = tmpPath(&path_buf, "shared");
    defer unlink(path);
    var zeros: [4096]u8 = @splat(0);
    try writeFile(path, &zeros);

    const writer = try Mapping.mapFile(path, .shared_writable);
    defer writer.unmap();
    const reader = try Mapping.mapFile(path, .read_only);
    defer reader.unmap();
    const words = try writer.sliceMut(u64, 0, 4);
    @atomicStore(u64, &words[2], 0xfeed, .release);
    const seen = try reader.slice(u64, 0, 4);
    try testing.expectEqual(@as(u64, 0xfeed), @atomicLoad(u64, &seen[2], .acquire));
}

test "empty files map to empty slices and missing files fail cleanly" {
    var path_buf: [256]u8 = undefined;
    const path = tmpPath(&path_buf, "empty");
    defer unlink(path);
    try writeFile(path, "");
    const map = try Mapping.mapFile(path, .read_only);
    defer map.unmap();
    try testing.expectEqual(@as(usize, 0), map.bytes.len);
    try testing.expectError(error.FileNotFound, Mapping.mapFile("/nonexistent/zig-routing", .read_only));
}

test "loopback accept, read, write and writev" {
    const listener = try Listener.listen(.loopback_any_port, .{});
    defer listener.close();
    const port = try listener.port();
    try testing.expect(port != 0);

    const client = try Stream.connect(Address.loopback(port));
    defer client.close();
    const server = try listener.accept();
    defer server.close();

    try client.writeAll("GET /status HTTP/1.1\r\n\r\n");
    var buf: [128]u8 = undefined;
    var got: usize = 0;
    while (got < 24) got += try server.read(buf[got..]);
    try testing.expectEqualStrings("GET /status HTTP/1.1\r\n\r\n", buf[0..got]);

    try server.writevAll(&.{ "HTTP/1.1 200 OK\r\n", "", "Content-Length: 2\r\n\r\n", "{}" });
    got = 0;
    const want = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
    while (got < want.len) got += try client.read(buf[got..]);
    try testing.expectEqualStrings(want, buf[0..got]);

    server.shutdownWrite();
    try testing.expectEqual(@as(usize, 0), try client.read(&buf));
}

test "writev handles more buffers than one iovec batch and partial progress" {
    const listener = try Listener.listen(.loopback_any_port, .{});
    defer listener.close();
    const client = try Stream.connect(Address.loopback(try listener.port()));
    defer client.close();
    const server = try listener.accept();
    defer server.close();

    var parts: [40][]const u8 = undefined;
    for (&parts, 0..) |*p, i| p.* = if (i % 2 == 0) "ab" else "cde";
    try server.writevAll(&parts);
    server.shutdownWrite();
    var buf: [256]u8 = undefined;
    var got: usize = 0;
    while (true) {
        const n = try client.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqual(@as(usize, 100), got);
    try testing.expectEqualStrings("abcdeabcde", buf[0..10]);
}

test "poller reports a readable connection" {
    const listener = try Listener.listen(.loopback_any_port, .{ .reuse_port = true, .nonblocking = true });
    defer listener.close();
    try testing.expectError(error.WouldBlock, listener.accept());

    const poller = try Poller.init();
    defer poller.deinit();
    try poller.arm(listener.fd, 7, .read);

    const client = try Stream.connect(Address.loopback(try listener.port()));
    defer client.close();

    var events: [8]Event = undefined;
    const ready = try poller.wait(&events, 2000);
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqual(@as(u64, 7), ready[0].token);
    try testing.expect(ready[0].readable);

    const server = try listener.accept();
    defer server.close();
    try server.setNonblocking();
    var empty: [4]u8 = undefined;
    try testing.expectError(error.WouldBlock, server.read(&empty));

    try poller.arm(server.fd, 9, .read);
    try client.writeAll("x");
    const more = try poller.wait(&events, 2000);
    try testing.expectEqual(@as(u64, 9), more[0].token);
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try server.read(&one));
}

// ---------------------------------------------------------------------------
// Process signals and sleeping
// ---------------------------------------------------------------------------

/// Set once SIGINT or SIGTERM arrives after `installTerminationHandler`.
pub var termination_requested: std.atomic.Value(bool) = .init(false);

fn onTerminate(_: c.SIG) callconv(.c) void {
    termination_requested.store(true, .release);
}

/// Routes SIGINT and SIGTERM to `termination_requested` (for graceful
/// shutdown) and ignores SIGPIPE (writes to closed sockets return errors).
pub fn installTerminationHandler() void {
    var act: c.Sigaction = std.mem.zeroes(c.Sigaction);
    act.handler = .{ .handler = onTerminate };
    _ = c.sigemptyset(&act.mask);
    _ = c.sigaction(.INT, &act, null);
    _ = c.sigaction(.TERM, &act, null);
    var ignore: c.Sigaction = std.mem.zeroes(c.Sigaction);
    ignore.handler = .{ .handler = c.SIG.IGN };
    _ = c.sigemptyset(&ignore.mask);
    _ = c.sigaction(.PIPE, &ignore, null);
}

pub fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (c.nanosleep(&ts, &ts) != 0) {}
}
