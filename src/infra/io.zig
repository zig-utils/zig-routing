//! The IO shim: the only file that talks to the operating system for clocks,
//! files, memory maps, sockets and readiness polling.
//!
//! The Zig 0.17-dev standard library moves these APIs often (std.time.Timer,
//! std.fs.cwd and blocking sockets are gone, and std.Io wants an `Io` handle
//! threaded everywhere). Operating-system calls use `std.c` and CLI writers
//! use the standard library, so toolchain changes are isolated here.
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
    PathAlreadyExists,
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
    return failErrno(c.errno(rc));
}

noinline fn failErrno(code: c.E) Error {
    return switch (code) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
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

// Keep kernel calls out of callers so checkpoint and bundle code share the
// same syscall, retry, and error translation paths.
pub const OpenMode = enum { read_only, read_write, create_truncate };

pub const File = struct {
    fd: c.fd_t,

    /// A disk-backed scratch file scoped to this handle. Closing it releases
    /// its storage even if the process exits during a build.
    pub noinline fn temporary(directory: []const u8) Error!File {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}/.zr-scratch-XXXXXX", .{directory}) catch
            return error.InvalidArgument;
        buf[path.len] = 0;
        const name = buf[0..path.len :0];
        const fd = try checkInt(mkostemp(name.ptr, @as(c_int, @bitCast(c.O{ .CLOEXEC = true }))));
        errdefer _ = c.close(fd);
        _ = try checkInt(c.unlink(name.ptr));
        return .{ .fd = fd };
    }

    extern "c" fn mkostemp(path: [*:0]u8, flags: c_int) c_int;

    pub noinline fn open(path: []const u8, mode: OpenMode) Error!File {
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

    pub noinline fn close(self: File) void {
        _ = c.close(self.fd);
    }

    pub fn sync(self: File) Error!void {
        try syncFd(self.fd);
    }

    /// Held until this file descriptor is closed.
    pub fn lockExclusive(self: File) Error!void {
        try lockExclusiveFd(self.fd);
    }

    /// File size via lseek (portable: glibc does not export fstat as a
    /// plain symbol). Leaves the file offset at the end; reads use pread.
    pub noinline fn size(self: File) Error!u64 {
        const end = c.lseek(self.fd, 0, c.SEEK.END);
        if (end < 0) return fail(@as(c_int, -1));
        return @intCast(end);
    }

    pub noinline fn truncate(self: File, len: u64) Error!void {
        const size_bytes = std.math.cast(c.off_t, len) orelse return error.OutOfBounds;
        _ = try checkInt(c.ftruncate(self.fd, size_bytes));
    }

    /// Hint that upcoming positional reads will need this file range.
    pub fn prefetch(self: File, offset: u64, len: u32) void {
        const start = std.math.cast(c.off_t, offset) orelse return;
        if (is_linux) {
            _ = std.os.linux.fadvise(self.fd, start, len, std.os.linux.POSIX_FADV.WILLNEED);
        } else {
            const AdviceRange = extern struct { offset: c.off_t, count: c_int };
            const range: AdviceRange = .{ .offset = start, .count = std.math.cast(c_int, len) orelse return };
            _ = c.fcntl(self.fd, c.F.RDADVISE, &range);
        }
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
    pub noinline fn preadAll(self: File, buf: []u8, offset: u64) Error!void {
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

    /// Writes all of `bytes` at `offset` without moving the file offset.
    pub noinline fn pwriteAll(self: File, bytes: []const u8, offset: u64) Error!void {
        var done: usize = 0;
        while (done < bytes.len) {
            const rc = c.pwrite(self.fd, bytes[done..].ptr, bytes.len - done, @intCast(offset + done));
            if (rc < 0 and c.errno(rc) == .INTR) continue;
            done += try checkSize(rc);
        }
    }
};

noinline fn syncFd(fd: c.fd_t) Error!void {
    while (true) {
        const rc = c.fsync(fd);
        if (rc < 0 and c.errno(rc) == .INTR) continue;
        _ = try checkInt(rc);
        return;
    }
}

/// Directory descriptor used for creating, verifying and publishing a bundle
/// under the same parent even if its path is renamed elsewhere.
pub const Directory = struct {
    fd: c.fd_t,

    pub const TempName = [36:0]u8;

    pub noinline fn open(path: []const u8) Error!Directory {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidArgument;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return .{ .fd = try checkInt(c.open(@ptrCast(&buf), directory_flags)) };
    }

    pub noinline fn close(self: Directory) void {
        _ = c.close(self.fd);
    }

    pub noinline fn child(self: Directory, name: [:0]const u8) Error!Directory {
        try checkChildName(name);
        var flags = directory_flags;
        flags.NOFOLLOW = true;
        return .{ .fd = try checkInt(c.openat(self.fd, name, flags)) };
    }

    pub noinline fn createChild(self: Directory, name: [:0]const u8) Error!Directory {
        try checkChildName(name);
        _ = try checkInt(c.mkdirat(self.fd, name, 0o755));
        errdefer self.deleteDir(name) catch {};
        return self.child(name);
    }

    /// Held until this directory descriptor is closed.
    pub fn lockExclusive(self: Directory) Error!void {
        try lockExclusiveFd(self.fd);
    }

    pub noinline fn temporaryChild(self: Directory) Error!struct { dir: Directory, name: TempName } {
        // A collision cannot replace an existing directory. Retry with
        // fresh randomness if a name is already present.
        for (0..16) |_| {
            const name = try randomTempName();
            const rc = c.mkdirat(self.fd, &name, 0o755);
            if (rc < 0 and c.errno(rc) == .EXIST) continue;
            _ = try checkInt(rc);
            errdefer self.deleteDir(&name) catch {};
            return .{ .dir = try self.child(&name), .name = name };
        }
        return error.PathAlreadyExists;
    }

    /// Create a temporary sibling that the caller can publish with renameExclusive.
    pub noinline fn temporaryFile(self: Directory) Error!struct { file: File, name: TempName } {
        for (0..16) |_| {
            const name = try randomTempName();
            const file = self.createFile(&name) catch |err| {
                if (err == error.PathAlreadyExists) continue;
                return err;
            };
            return .{ .file = file, .name = name };
        }
        return error.PathAlreadyExists;
    }

    fn randomTempName() Error!TempName {
        var nonce: [16]u8 = undefined;
        try fillRandom(&nonce);
        var name: TempName = undefined;
        name[0..4].* = ".zr-".*;
        @memcpy(name[4..name.len], &std.fmt.bytesToHex(nonce, .lower));
        name[name.len] = 0;
        return name;
    }

    pub noinline fn createFile(self: Directory, name: [:0]const u8) Error!File {
        try checkChildName(name);
        const flags: c.O = .{ .CLOEXEC = true, .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
        return .{ .fd = try checkInt(c.openat(self.fd, name, flags, @as(c.mode_t, 0o644))) };
    }

    pub noinline fn openOrCreateFile(self: Directory, name: [:0]const u8) Error!File {
        try checkChildName(name);
        const flags: c.O = .{ .CLOEXEC = true, .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .NONBLOCK = true };
        return .{ .fd = try checkInt(c.openat(self.fd, name, flags, @as(c.mode_t, 0o644))) };
    }

    pub noinline fn readFile(self: Directory, name: [:0]const u8) Error!File {
        try checkChildName(name);
        const flags: c.O = .{ .CLOEXEC = true, .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true };
        return .{ .fd = try checkInt(c.openat(self.fd, name, flags)) };
    }

    pub noinline fn readWriteFile(self: Directory, name: [:0]const u8) Error!File {
        try checkChildName(name);
        const flags: c.O = .{ .CLOEXEC = true, .ACCMODE = .RDWR, .NOFOLLOW = true, .NONBLOCK = true };
        return .{ .fd = try checkInt(c.openat(self.fd, name, flags)) };
    }

    pub noinline fn deleteFile(self: Directory, name: [:0]const u8) Error!void {
        try checkChildName(name);
        _ = try checkInt(c.unlinkat(self.fd, name, 0));
    }

    pub noinline fn deleteDir(self: Directory, name: [:0]const u8) Error!void {
        try checkChildName(name);
        _ = try checkInt(c.unlinkat(self.fd, name, c.AT.REMOVEDIR));
    }

    pub fn sync(self: Directory) Error!void {
        try syncFd(self.fd);
    }

    /// Atomically publish a sibling name. Existing paths stay intact.
    pub noinline fn renameExclusive(self: Directory, old: [:0]const u8, new: [:0]const u8) Error!void {
        try checkChildName(old);
        try checkChildName(new);
        if (is_linux) {
            const linux = std.os.linux;
            const rc = linux.renameat2(self.fd, old, self.fd, new, .{ .NOREPLACE = true });
            const code = linux.errno(rc);
            if (code != .SUCCESS) return failErrno(code);
        } else {
            _ = try checkInt(c.renameatx_np(self.fd, old, self.fd, new, .{ .EXCL = true }));
        }
    }

    /// Atomically swap two existing sibling paths.
    pub noinline fn exchange(self: Directory, first: [:0]const u8, second: [:0]const u8) Error!void {
        try checkChildName(first);
        try checkChildName(second);
        if (is_linux) {
            const linux = std.os.linux;
            const rc = linux.renameat2(self.fd, first, self.fd, second, .{ .EXCHANGE = true });
            const code = linux.errno(rc);
            if (code != .SUCCESS) return failErrno(code);
        } else {
            _ = try checkInt(c.renameatx_np(self.fd, first, self.fd, second, .{ .SWAP = true }));
        }
    }

    pub noinline fn writeAtomic(self: Directory, name: [:0]const u8, bytes: []const u8) !void {
        try checkChildName(name);
        var nonce: [16]u8 = undefined;
        try fillRandom(&nonce);
        var tmp: [44]u8 = undefined;
        const printed = try std.fmt.bufPrint(tmp[0 .. tmp.len - 1], ".zr-report-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        tmp[printed.len] = 0;
        const staged = tmp[0..printed.len :0];
        const file = try self.createFile(staged);
        defer file.close();
        errdefer self.deleteFile(staged) catch {};
        try file.pwriteAll(bytes, 0);
        try file.sync();
        try self.replaceFile(staged, name);
        try self.sync();
    }

    /// Atomically replace a sibling file.
    pub noinline fn replaceFile(self: Directory, old: [:0]const u8, new: [:0]const u8) Error!void {
        try checkChildName(old);
        try checkChildName(new);
        _ = try checkInt(c.renameat(self.fd, old, self.fd, new));
    }

    const directory_flags: c.O = .{ .DIRECTORY = true, .CLOEXEC = true, .ACCMODE = .RDONLY };
};

noinline fn checkChildName(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidArgument;
}

fn lockExclusiveFd(fd: c.fd_t) Error!void {
    while (true) {
        const result = c.flock(fd, c.LOCK.EX | c.LOCK.NB);
        if (result != 0 and c.errno(result) == .INTR) continue;
        _ = try checkInt(result);
        return;
    }
}

fn fillRandom(bytes: []u8) Error!void {
    if (is_linux) {
        const linux = std.os.linux;
        var filled: usize = 0;
        while (filled < bytes.len) {
            const rc = linux.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.Unexpected;
                    filled += rc;
                },
                .INTR => continue,
                else => |code| return failErrno(code),
            }
        }
    } else {
        c.arc4random_buf(bytes.ptr, bytes.len);
    }
}

/// Reads a whole file into memory owned by `allocator`.
pub noinline fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) (Error || error{FileTooBig})![]u8 {
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

    pub noinline fn mapFd(file: File, mode: MapMode) Error!Mapping {
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

    pub noinline fn unmap(self: Mapping) void {
        if (self.bytes.len == 0) return;
        _ = c.munmap(@ptrCast(self.bytes.ptr), self.bytes.len);
    }

    /// Advises the kernel about a page-aligned range (offset is rounded down,
    /// end rounded up). Unsupported advice is a no-op.
    pub noinline fn advise(self: Mapping, offset: usize, len: usize, advice: Advice) Error!void {
        if (offset >= self.bytes.len or len == 0) return;
        const start = std.mem.alignBackward(usize, offset, std.heap.pageSize());
        const end = @min(self.bytes.len, offset +| len);
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

    /// Snapshot of resident bytes without reading the mapped data. Count
    /// only bytes within the file when the final page is partial.
    pub fn residentBytes(self: Mapping, deadline: Deadline) (Error || error{DeadlineExceeded})!usize {
        if (self.bytes.len == 0) return 0;
        const granularity = std.heap.pageSize();
        const batch_pages = 512;
        // Linux's mincore can report every page of a file as resident when
        // the caller cannot write it. Read the process's present bits instead.
        const pagemap = if (is_linux) try File.open("/proc/self/pagemap", .read_only) else {};
        defer if (is_linux) pagemap.close();
        var offset: usize = 0;
        var resident: usize = 0;
        while (offset < self.bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const len = @min(self.bytes.len - offset, granularity * batch_pages);
            const pages = (len - 1) / granularity + 1;
            if (is_linux) {
                var entries: [batch_pages]u64 = undefined;
                const address = @intFromPtr(self.bytes.ptr) + offset;
                const first_entry = (address / granularity) * @sizeOf(u64);
                try pagemap.preadAll(std.mem.sliceAsBytes(entries[0..pages]), first_entry);
                for (entries[0..pages], 0..) |entry, i| {
                    if (entry >> 63 != 0) resident += @min(granularity, len - i * granularity);
                }
            } else {
                var entries: [batch_pages]u8 = undefined;
                const ptr: *align(page_size) anyopaque = @ptrCast(@alignCast(self.bytes.ptr + offset));
                _ = try checkInt(c.mincore(ptr, len, &entries));
                for (entries[0..pages], 0..) |entry, i| {
                    if (entry & 1 != 0) resident += @min(granularity, len - i * granularity);
                }
            }
            offset += len;
        }
        return resident;
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

/// Share the bulk XXH3 update kernel across file writes and verification.
pub noinline fn updateFileHash(hash: *std.hash.XxHash3, chunk: []const u8) void {
    hash.update(chunk);
}

/// Bounds- and alignment-checked typed view over raw bytes.
pub fn typedSlice(comptime T: type, bytes: []const u8, offset: usize, count: usize) Error![]const T {
    const addr = try checkedSliceAddress(bytes, offset, count, @sizeOf(T), @alignOf(T));
    if (count == 0) return &.{};
    const base: [*]const T = @ptrFromInt(addr);
    return base[0..count];
}

/// Bundle sections share the same width and alignment checks across types.
noinline fn checkedSliceAddress(bytes: []const u8, offset: usize, count: usize, record_size: usize, alignment: usize) Error!usize {
    const size = std.math.mul(usize, record_size, count) catch return error.OutOfBounds;
    const end = std.math.add(usize, offset, size) catch return error.OutOfBounds;
    if (end > bytes.len) return error.OutOfBounds;
    if (count == 0) return 0;
    const addr = @intFromPtr(bytes.ptr) + offset;
    if (addr & (alignment - 1) != 0) return error.Misaligned;
    return addr;
}

// ---------------------------------------------------------------------------
// Standard streams and sockets
// ---------------------------------------------------------------------------

fn writeAllFd(fd: c.fd_t, bytes: []const u8) Error!void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = c.write(fd, bytes.ptr + done, bytes.len - done);
        if (rc < 0 and c.errno(rc) == .INTR) continue;
        done += try checkSize(rc);
    }
}

pub fn writeStdout(bytes: []const u8) Error!void {
    return writeAllFd(c.STDOUT_FILENO, bytes);
}

pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;

pub fn stdoutWriter(system: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(system, buffer);
}

pub fn stderrWriter(system: std.Io, buffer: []u8) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(system, buffer);
}

/// A seekable ZIP reader borrowing a shim file and caller-owned buffer.
pub const Zip = struct {
    pub const Iterator = std.zip.Iterator;
    pub const Entry = Iterator.Entry;
    reader: std.Io.File.Reader,

    pub fn init(file: File, buffer: []u8) Zip {
        const borrowed: std.Io.File = .{ .handle = file.fd, .flags = .{ .nonblocking = false } };
        return .{ .reader = borrowed.reader(std.Io.Threaded.global_single_threaded.io(), buffer) };
    }

    pub fn entries(self: *Zip) !Iterator {
        return .init(&self.reader);
    }

    pub fn filename(self: *Zip, entry: Entry, storage: []u8) ![]const u8 {
        return entry.getFilename(&self.reader, storage, .{});
    }

    /// Streams a stored or deflated member directly into caller memory.
    pub fn read(self: *Zip, entry: Entry, storage: []u8, deadline: Deadline) !void {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (storage.len != entry.uncompressed_size) return error.ZipOutputSizeMismatch;
        var output: ZipOutput = .{ .storage = storage, .deadline = deadline };
        entry.extractTo(&self.reader, &output.writer) catch |err| {
            if (output.deadline.expired()) return error.DeadlineExceeded;
            return err;
        };
        if (output.position != storage.len) return error.ZipOutputSizeMismatch;
        if (output.crc.final() != entry.crc32) return error.ZipCrcMismatch;
    }
};

const ZipOutput = struct {
    storage: []u8,
    deadline: Deadline,
    position: usize = 0,
    crc: std.hash.Crc32 = .init(),
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ZipOutput = @fieldParentPtr("writer", writer);
        const previous = self.position;
        for (data[0 .. data.len - 1]) |part| try self.write(part);
        for (0..splat) |_| try self.write(data[data.len - 1]);
        return self.position - previous;
    }

    fn write(self: *ZipOutput, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.deadline.expired() or bytes.len > self.storage.len - self.position) return error.WriteFailed;
        @memcpy(self.storage[self.position..][0..bytes.len], bytes);
        self.crc.update(bytes);
        self.position += bytes.len;
    }
};

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(std.Io.Threaded.global_single_threaded.io(), &mutex.inner);
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(std.Io.Threaded.global_single_threaded.io());
    }
};

pub fn waitAtomic(word: *const std.atomic.Value(u32), expected: u32, deadline: Deadline) void {
    const time = deadline.remainingNs();
    if (time == 0) return;
    const timeout: std.Io.Timeout = if (deadline.at_ns == Deadline.none.at_ns)
        .none
    else
        .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = time } } };
    std.Io.Threaded.global_single_threaded.io().futexWaitTimeout(u32, &word.raw, expected, timeout) catch {};
}

pub fn wakeAtomic(word: *const std.atomic.Value(u32)) void {
    std.Io.Threaded.global_single_threaded.io().futexWake(u32, &word.raw, std.math.maxInt(u32));
}

pub const InflateError = error{ CorruptZlib, InflateSizeMismatch, DeadlineExceeded };

/// Inflate a single zlib stream into caller-owned memory and verify its length,
/// checksum and end of input. The output buffer also serves as match history.
pub fn inflateZlibExact(src: []const u8, dst: []u8, deadline: Deadline) InflateError!void {
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var stream: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var checksum: std.hash.Adler32 = .{};
    while (true) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const begin = output.end;
        _ = stream.reader.stream(&output, .limited(256 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.InflateSizeMismatch,
            error.ReadFailed => return error.CorruptZlib,
        };
        checksum.update(dst[begin..output.end]);
    }
    if (output.end != dst.len) return error.InflateSizeMismatch;
    if (input.seek != src.len or checksum.adler != stream.container_metadata.zlib.adler) return error.CorruptZlib;
}

pub fn deflateGzip(a: std.mem.Allocator, src: []const u8, deadline: Deadline) (std.mem.Allocator.Error || error{DeadlineExceeded})![]u8 {
    if (deadline.expired()) return error.DeadlineExceeded;
    var output: std.Io.Writer.Allocating = try .initCapacity(a, @max(64, src.len / 2));
    defer output.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    const Compress = std.compress.flate.Compress;
    var stream = Compress.init(&output.writer, &window, .gzip, Compress.Options.fastest) catch return error.OutOfMemory;
    var offset: usize = 0;
    while (offset < src.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const end = @min(offset +| window.len, src.len);
        stream.writer.writeAll(src[offset..end]) catch return error.OutOfMemory;
        offset = end;
    }
    stream.finish() catch return error.OutOfMemory;
    if (deadline.expired()) return error.DeadlineExceeded;
    return output.toOwnedSlice();
}

pub fn inflateGzip(a: std.mem.Allocator, src: []const u8, limit: usize, deadline: Deadline) ![]u8 {
    if (src.len < 18) return error.CorruptGzip;
    const len = std.mem.readInt(u32, src[src.len - 4 ..][0..4], .little);
    if (len > limit) return error.InflateSizeMismatch;
    const dst = try a.alloc(u8, len);
    errdefer a.free(dst);
    var input: std.Io.Reader = .fixed(src);
    var output: std.Io.Writer = .fixed(dst);
    var stream: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    var checksum: std.hash.Crc32 = .init();
    while (true) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const begin = output.end;
        _ = stream.reader.stream(&output, .limited(256 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.InflateSizeMismatch,
            error.ReadFailed => return error.CorruptGzip,
        };
        checksum.update(dst[begin..output.end]);
    }
    if (output.end != dst.len) return error.InflateSizeMismatch;
    if (input.seek != src.len or checksum.final() != stream.container_metadata.gzip.crc) return error.CorruptGzip;
    return dst;
}

pub fn peakRssBytes() Error!u64 {
    var usage: c.rusage = undefined;
    _ = try checkInt(c.getrusage(c.rusage.SELF, &usage));
    return @as(u64, @intCast(usage.maxrss)) * (if (is_linux) @as(u64, 1024) else 1);
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

pub const TcpPeer = union(enum) {
    ip4: c.sockaddr.in,
    ip6: c.sockaddr.in6,

    /// Resolve once at startup. A range miss never does a DNS lookup.
    pub fn resolve(a: std.mem.Allocator, hostname: []const u8, port: u16) ![]TcpPeer {
        var host_buf: [255]u8 = @splat(0);
        if (hostname.len == 0 or hostname.len >= host_buf.len - 1 or
            std.mem.indexOfScalar(u8, hostname, 0) != null) return error.InvalidHostname;
        @memcpy(host_buf[0..hostname.len], hostname);
        var port_buf: [6]u8 = undefined;
        const service = try std.fmt.bufPrintSentinel(&port_buf, "{d}", .{port}, 0);
        var hints = std.mem.zeroes(c.addrinfo);
        hints.socktype = c.SOCK.STREAM;
        hints.protocol = c.IPPROTO.TCP;
        var head: ?*c.addrinfo = null;
        if (@backingInt(c.getaddrinfo(host_buf[0..hostname.len :0], service, &hints, &head)) != 0) return error.HostLookupFailed;
        const first = head orelse return error.HostLookupFailed;
        defer c.freeaddrinfo(first);
        var peers: std.ArrayList(TcpPeer) = .empty;
        errdefer peers.deinit(a);
        while (head) |item| : (head = item.next) {
            const address = item.addr orelse continue;
            const peer: TcpPeer = switch (item.family) {
                c.AF.INET => .{ .ip4 = @as(*const c.sockaddr.in, @ptrCast(@alignCast(address))).* },
                c.AF.INET6 => .{ .ip6 = @as(*const c.sockaddr.in6, @ptrCast(@alignCast(address))).* },
                else => continue,
            };
            try peers.append(a, peer);
        }
        if (peers.items.len == 0) return error.HostLookupFailed;
        return peers.toOwnedSlice(a);
    }

    pub fn connect(self: *const TcpPeer, deadline: Deadline) !DeadlineStream {
        return switch (self.*) {
            .ip4 => |*address| DeadlineStream.connect(c.AF.INET, @ptrCast(address), @sizeOf(c.sockaddr.in), deadline),
            .ip6 => |*address| DeadlineStream.connect(c.AF.INET6, @ptrCast(address), @sizeOf(c.sockaddr.in6), deadline),
        };
    }
};

pub const DeadlineStream = struct {
    fd: c.fd_t,
    deadline: Deadline,

    fn connect(family: c_uint, address: *const c.sockaddr, len: c.socklen_t, deadline: Deadline) !DeadlineStream {
        if (deadline.expired()) return error.DeadlineExceeded;
        const fd = try checkInt(c.socket(family, c.SOCK.STREAM, c.IPPROTO.TCP));
        errdefer _ = c.close(fd);
        _ = try checkInt(c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)));
        try setFdNonblocking(fd);
        if (is_darwin) try setOpt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, 1);
        const self: DeadlineStream = .{ .fd = fd, .deadline = deadline };
        const rc = c.connect(fd, address, len);
        if (rc < 0) {
            switch (c.errno(rc)) {
                .INPROGRESS, .INTR => {},
                else => |err| return failErrno(err),
            }
            try self.wait(c.POLL.OUT);
            var status: c_int = 0;
            var status_len: c.socklen_t = @sizeOf(c_int);
            _ = try checkInt(c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &status, &status_len));
            if (status != 0) return failErrno(@fromBackingInt(@intCast(status)));
        }
        try setOpt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
        return self;
    }

    pub fn close(self: DeadlineStream) void {
        _ = c.close(self.fd);
    }

    pub fn read(self: DeadlineStream, bytes: []u8) !usize {
        while (true) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const rc = c.recv(self.fd, bytes.ptr, bytes.len, 0);
            if (rc >= 0) return @intCast(rc);
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => try self.wait(c.POLL.IN),
                else => |err| return failErrno(err),
            }
        }
    }

    pub fn write(self: DeadlineStream, bytes: []const u8) !usize {
        while (true) {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const rc = c.send(self.fd, bytes.ptr, bytes.len, if (is_linux) c.MSG.NOSIGNAL else 0);
            if (rc >= 0) return @intCast(rc);
            switch (c.errno(rc)) {
                .INTR => continue,
                .AGAIN => try self.wait(c.POLL.OUT),
                else => |err| return failErrno(err),
            }
        }
    }

    fn wait(self: DeadlineStream, events: i16) !void {
        var descriptor: [1]c.pollfd = .{.{ .fd = self.fd, .events = events, .revents = 0 }};
        while (true) {
            const left = self.deadline.remainingNs();
            if (left == 0) return error.DeadlineExceeded;
            const ms: c_int = @intCast(@min((left +| (std.time.ns_per_ms - 1)) / std.time.ns_per_ms, std.math.maxInt(c_int)));
            const rc = c.poll(&descriptor, 1, ms);
            if (rc > 0) return;
            if (rc == 0 or c.errno(rc) == .INTR) continue;
            return fail(rc);
        }
    }
};

/// Adapt a short-read source such as the deadline socket or a TLS connection
/// to the buffered reader used by Zig's HTTP framing and the TLS handshake.
pub fn BufferedReader(comptime Context: type) type {
    return struct {
        context: Context,
        failure: ?anyerror = null,
        interface: Reader,

        const Self = @This();

        pub fn init(context: Context, buffer: []u8) Self {
            return .{
                .context = context,
                .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream } },
            };
        }

        fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
            if (limit == .nothing) return 0;
            const self: *Self = @fieldParentPtr("interface", r);
            const output = limit.slice(try w.writableSliceGreedy(1));
            const n = self.context.read(output) catch |err| {
                self.failure = err;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    };
}

pub const SocketWriter = struct {
    socket: DeadlineStream,
    failure: ?anyerror = null,
    interface: Writer,

    pub fn init(socket: DeadlineStream, buffer: []u8) SocketWriter {
        return .{ .socket = socket, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *SocketWriter = @fieldParentPtr("interface", w);
        self.writeAll(w.buffered()) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        w.end = 0;
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |part| total += try self.writePart(part);
        for (0..splat) |_| total += try self.writePart(data[data.len - 1]);
        return total;
    }

    fn writePart(self: *SocketWriter, part: []const u8) Writer.Error!usize {
        self.writeAll(part) catch |err| {
            self.failure = err;
            return error.WriteFailed;
        };
        return part.len;
    }

    fn writeAll(self: *SocketWriter, data: []const u8) !void {
        var done: usize = 0;
        while (done < data.len) {
            const written = try self.socket.write(data[done..]);
            if (written == 0) return error.BrokenPipe;
            done += written;
        }
    }
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
                .events = @as(u32, if (interest == .read) linux.EPOLL.IN else linux.EPOLL.OUT) | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
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

test "mapping residency counts only file bytes in the last page" {
    var path_buf: [256]u8 = undefined;
    const path = tmpPath(&path_buf, "resident");
    defer unlink(path);
    const file = try File.open(path, .create_truncate);
    defer file.close();
    const size = std.heap.pageSize();
    const len = 2 * size + 73;
    try file.truncate(len);
    const map = try Mapping.mapFd(file, .read_only);
    defer map.unmap();

    try testing.expectError(error.DeadlineExceeded, map.residentBytes(.{ .at_ns = 0 }));
    try testing.expect(try map.residentBytes(.none) <= len);
    for (0..3) |page| {
        const byte: *const volatile u8 = &map.bytes[page * size];
        _ = byte.*;
    }
    try testing.expectEqual(len, try map.residentBytes(.none));
    try map.advise(size + 37, std.math.maxInt(usize), .random);
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

// ---------------------------------------------------------------------------
// Directory walking
// ---------------------------------------------------------------------------

/// Calls `visit(context, path)` for every regular file under `root`,
/// recursively. Paths are built in a stack buffer and valid only during the
/// call. Symlinks and special files are skipped; unreadable directories are
/// skipped silently (as upstream's recursive_directory_iterator use treats
/// them as absent data).
pub fn walkFiles(root: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), []const u8) void) void {
    const Visitor = struct {
        fn call(target: @TypeOf(context), path: []const u8) !void {
            visit(target, path);
        }
    };
    walkFilesUntil(root, .none, context, Visitor.call) catch unreachable;
}

pub fn walkFilesUntil(root: []const u8, deadline: Deadline, context: anytype, comptime visit: anytype) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (root.len >= buf.len) return;
    @memcpy(buf[0..root.len], root);
    try walkDir(&buf, root.len, deadline, context, visit, 0);
}

fn walkDir(buf: *[std.fs.max_path_bytes]u8, len: usize, deadline: Deadline, context: anytype, comptime visit: anytype, depth: u32) anyerror!void {
    if (depth > 32) return;
    buf[len] = 0;
    const dir = c.opendir(@ptrCast(buf)) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        if (deadline.expired()) return error.DeadlineExceeded;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (len + 1 + name.len >= buf.len) continue;
        buf[len] = '/';
        @memcpy(buf[len + 1 ..][0..name.len], name);
        const sub_len = len + 1 + name.len;
        switch (entry.type) {
            c.DT.DIR => try walkDir(buf, sub_len, deadline, context, visit, depth + 1),
            c.DT.REG => try visit(context, buf[0..sub_len]),
            else => {},
        }
    }
}
