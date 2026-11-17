//! Per-request memory.
//!
//! Every worker thread owns one `Arena`. A request allocates from it freely
//! and never frees; `reset()` rewinds it after the response is written and
//! keeps the chunks, so once a worker has seen its largest request it never
//! calls the backing allocator again. A hard byte cap turns a runaway request
//! into `error.RequestTooLarge` instead of an out-of-memory kill.
//!
//! Upstream Valhalla's per-worker heap ratchets up over time (issues 5172,
//! 4322, 4667); wholesale arena resets are the fix.
//!
//! Also here: `PagePool` (fixed-size pages for paged status arrays),
//! `CountingAllocator` (what the backing allocator saw), the
//! `expectNoSteadyStateAlloc` test helper, and `Scratch` (a growable byte
//! buffer that lives inside an arena, for serializers).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Error = error{RequestTooLarge};

pub const ArenaOptions = struct {
    /// Total bytes the arena may hold across all chunks. Allocations past it
    /// fail; `last_error` then reads `error.RequestTooLarge`.
    cap_bytes: usize = 256 * 1024 * 1024,
    /// Size of the first chunk; later chunks double.
    first_chunk_bytes: usize = 64 * 1024,
};

pub const Arena = struct {
    backing: Allocator,
    options: ArenaOptions,
    chunks: std.ArrayList([]align(16) u8) = .empty,
    /// Chunk currently being bumped.
    current: usize = 0,
    /// Bump offset inside `chunks[current]`.
    offset: usize = 0,
    /// Sum of all chunk sizes (what the cap is checked against).
    reserved: usize = 0,
    /// Bytes handed out since the last reset (for metrics and budgets).
    used: usize = 0,
    /// Largest `used` seen across resets.
    high_water: usize = 0,
    /// Set when an allocation failed because of the cap.
    cap_exceeded: bool = false,

    pub fn init(backing: Allocator, options: ArenaOptions) Arena {
        return .{ .backing = backing, .options = options };
    }

    pub fn deinit(self: *Arena) void {
        for (self.chunks.items) |chunk| self.backing.free(chunk);
        self.chunks.deinit(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *Arena) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Rewinds to empty, keeping every chunk for the next request.
    pub fn reset(self: *Arena) void {
        self.high_water = @max(self.high_water, self.used);
        self.current = 0;
        self.offset = 0;
        self.used = 0;
        self.cap_exceeded = false;
    }

    /// Returns `error.RequestTooLarge` if any allocation since the last reset
    /// hit the cap. Request handlers call this to turn an allocator failure
    /// into the right error response.
    pub fn check(self: *const Arena) Error!void {
        if (self.cap_exceeded) return error.RequestTooLarge;
    }

    /// Releases chunks beyond what `keep_bytes` needs (for a worker that saw
    /// one pathological request). Must be called right after `reset`.
    pub fn trim(self: *Arena, keep_bytes: usize) void {
        std.debug.assert(self.used == 0);
        var kept: usize = 0;
        var n: usize = 0;
        while (n < self.chunks.items.len and kept < keep_bytes) : (n += 1) kept += self.chunks.items[n].len;
        for (self.chunks.items[n..]) |chunk| {
            self.reserved -= chunk.len;
            self.backing.free(chunk);
        }
        self.chunks.shrinkRetainingCapacity(n);
    }

    fn bump(self: *Arena, len: usize, alignment: Alignment) ?[*]u8 {
        const align_bytes = alignment.toByteUnits();
        while (self.current < self.chunks.items.len) {
            const chunk = self.chunks.items[self.current];
            const base = @intFromPtr(chunk.ptr);
            const start = alignment.forward(base + self.offset) - base;
            if (start + len <= chunk.len) {
                self.offset = start + len;
                self.used += len;
                return chunk.ptr + start;
            }
            self.current += 1;
            self.offset = 0;
        }
        // Need a new chunk: double the last one, at least big enough for this request.
        const last = if (self.chunks.items.len == 0) self.options.first_chunk_bytes / 2 else self.chunks.items[self.chunks.items.len - 1].len;
        var size = @max(self.options.first_chunk_bytes, last *| 2);
        size = @max(size, len + align_bytes);
        if (self.reserved + size > self.options.cap_bytes) {
            // Try the largest chunk that still fits under the cap.
            const room = self.options.cap_bytes -| self.reserved;
            if (room < len + align_bytes) {
                self.cap_exceeded = true;
                return null;
            }
            size = room;
        }
        self.chunks.ensureUnusedCapacity(self.backing, 1) catch return null;
        const chunk = self.backing.alignedAlloc(u8, .@"16", size) catch return null;
        self.chunks.appendAssumeCapacity(chunk);
        self.reserved += size;
        self.current = self.chunks.items.len - 1;
        self.offset = 0;
        return self.bump(len, alignment);
    }

    fn isLast(self: *Arena, memory: []u8) bool {
        if (self.current >= self.chunks.items.len) return false;
        const chunk = self.chunks.items[self.current];
        return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(chunk.ptr) + self.offset;
    }

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        return self.bump(len, alignment);
    }

    /// Grows or shrinks in place only for the most recent allocation.
    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            if (self.isLast(memory)) {
                self.offset -= memory.len - new_len;
                self.used -= memory.len - new_len;
            }
            return true;
        }
        if (!self.isLast(memory)) return false;
        const chunk = self.chunks.items[self.current];
        const grow = new_len - memory.len;
        if (self.offset + grow > chunk.len) return false;
        self.offset += grow;
        self.used += grow;
        return true;
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (vResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    /// Frees only the most recent allocation (the common push-then-pop case).
    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        if (self.isLast(memory)) {
            self.offset -= memory.len;
            self.used -= memory.len;
        }
    }

    const vtable: Allocator.VTable = .{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree };
};

/// Fixed-size pages handed out from an arena and recycled through a free
/// list. Paged edge-status and potential-memo arrays take their pages from
/// here so touching a new region of the graph costs one bump, not a malloc.
pub fn PagePool(comptime page_bytes: usize) type {
    return struct {
        const Self = @This();
        pub const Page = [page_bytes]u8;

        arena: *Arena,
        free_list: std.ArrayList(*align(64) Page) = .empty,

        pub fn init(arena: *Arena) Self {
            return .{ .arena = arena };
        }

        /// Returns a zeroed page.
        pub fn get(self: *Self) error{OutOfMemory}!*align(64) Page {
            if (self.free_list.pop()) |page| {
                @memset(page, 0);
                return page;
            }
            const bytes = try self.arena.allocator().alignedAlloc(u8, .@"64", page_bytes);
            @memset(bytes, 0);
            return @ptrCast(bytes.ptr);
        }

        pub fn put(self: *Self, page: *align(64) Page) void {
            self.free_list.append(self.arena.allocator(), page) catch {};
        }

        /// Forget every page (call alongside `Arena.reset`).
        pub fn reset(self: *Self) void {
            self.free_list = .empty;
        }
    };
}

/// Wraps an allocator and records what passes through it.
pub const CountingAllocator = struct {
    inner: Allocator,
    allocs: usize = 0,
    frees: usize = 0,
    resizes: usize = 0,
    bytes_live: usize = 0,
    bytes_peak: usize = 0,
    bytes_total: usize = 0,

    pub fn init(inner: Allocator) CountingAllocator {
        return .{ .inner = inner };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Calls of any kind since construction or the last `resetCounts`.
    pub fn calls(self: *const CountingAllocator) usize {
        return self.allocs + self.frees + self.resizes;
    }

    pub fn resetCounts(self: *CountingAllocator) void {
        self.allocs = 0;
        self.frees = 0;
        self.resizes = 0;
        self.bytes_total = 0;
        self.bytes_peak = self.bytes_live;
    }

    fn note(self: *CountingAllocator, added: usize, removed: usize) void {
        self.bytes_live = self.bytes_live + added - removed;
        self.bytes_total += added;
        self.bytes_peak = @max(self.bytes_peak, self.bytes_live);
    }

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        const ptr = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.note(len, 0);
        return ptr;
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.note(new_len, memory.len);
        return true;
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        const ptr = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.note(new_len, memory.len);
        return ptr;
    }

    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
        self.note(0, memory.len);
    }

    const vtable: Allocator.VTable = .{ .alloc = vAlloc, .resize = vResize, .remap = vRemap, .free = vFree };
};

/// Runs `work(arena, context)` twice on an arena backed by a counting
/// allocator, resetting in between, and fails if the second run reached the
/// backing allocator at all. Every endpoint gets one of these tests.
pub fn expectNoSteadyStateAlloc(
    comptime Context: type,
    context: Context,
    comptime work: fn (*Arena, Context) anyerror!void,
) !void {
    var counting = CountingAllocator.init(std.testing.allocator);
    var arena = Arena.init(counting.allocator(), .{});
    defer arena.deinit();

    try work(&arena, context); // warm up
    arena.reset();
    counting.resetCounts();
    try work(&arena, context);
    arena.reset();
    if (counting.calls() != 0) {
        std.debug.print("steady-state run reached the backing allocator {d} times ({d} allocs, {d} bytes)\n", .{ counting.calls(), counting.allocs, counting.bytes_total });
        return error.SteadyStateAllocation;
    }
}

/// A growable byte buffer inside an arena. Serializers write responses into
/// it; growth is a bump (or an in-place extend when it is the newest
/// allocation), never a backing-allocator call once the arena is warm.
pub const Scratch = struct {
    arena: *Arena,
    list: std.ArrayList(u8) = .empty,

    pub fn init(arena: *Arena) Scratch {
        return .{ .arena = arena };
    }

    pub fn items(self: *const Scratch) []const u8 {
        return self.list.items;
    }

    pub fn append(self: *Scratch, bytes: []const u8) error{OutOfMemory}!void {
        try self.list.appendSlice(self.arena.allocator(), bytes);
    }

    pub fn appendByte(self: *Scratch, byte: u8) error{OutOfMemory}!void {
        try self.list.append(self.arena.allocator(), byte);
    }

    pub fn print(self: *Scratch, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.list.print(self.arena.allocator(), fmt, args);
    }

    pub fn clear(self: *Scratch) void {
        self.list.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "arena reuses its chunks after reset with zero backing calls" {
    var counting = CountingAllocator.init(testing.allocator);
    var arena = Arena.init(counting.allocator(), .{ .first_chunk_bytes = 1024 });
    defer arena.deinit();
    const a = arena.allocator();

    for (0..2) |round| {
        if (round == 1) counting.resetCounts();
        var total: usize = 0;
        for (0..100) |i| {
            const block = try a.alloc(u64, i + 1);
            @memset(block, i);
            total += block.len;
        }
        try testing.expect(total == 5050);
        const big = try a.alloc(u8, 100_000);
        big[99_999] = 1;
        try arena.check();
        arena.reset();
    }
    try testing.expectEqual(@as(usize, 0), counting.calls());
    try testing.expect(arena.high_water >= 5050 * 8 + 100_000);
}

test "allocations respect alignment" {
    var arena = Arena.init(testing.allocator, .{ .first_chunk_bytes = 256 });
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 3);
    const wide = try a.alignedAlloc(u8, .@"64", 10);
    try testing.expect(@intFromPtr(wide.ptr) % 64 == 0);
    const words = try a.alloc(u64, 7);
    try testing.expect(@intFromPtr(words.ptr) % 8 == 0);
}

test "exceeding the cap reports RequestTooLarge without leaking" {
    var arena = Arena.init(testing.allocator, .{ .cap_bytes = 64 * 1024, .first_chunk_bytes = 16 * 1024 });
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 40 * 1024);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 40 * 1024));
    try testing.expectError(error.RequestTooLarge, arena.check());
    arena.reset();
    try arena.check();
    _ = try a.alloc(u8, 30 * 1024);
}

test "newest allocation can grow, shrink and be freed in place" {
    var arena = Arena.init(testing.allocator, .{ .first_chunk_bytes = 4096 });
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(u32) = .empty;
    for (0..500) |i| try list.append(a, @intCast(i));
    try testing.expectEqual(@as(u32, 499), list.items[499]);
    const before = arena.used;
    const tmp = try a.alloc(u8, 100);
    a.free(tmp);
    try testing.expectEqual(before, arena.used);
}

test "trim releases chunks beyond what is kept" {
    var counting = CountingAllocator.init(testing.allocator);
    var arena = Arena.init(counting.allocator(), .{ .first_chunk_bytes = 1024 });
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 1_000_000);
    arena.reset();
    const reserved = arena.reserved;
    arena.trim(0);
    try testing.expect(arena.reserved < reserved);
    try testing.expectEqual(@as(usize, 0), arena.chunks.items.len);
}

test "page pool hands out zeroed, recycled pages" {
    var arena = Arena.init(testing.allocator, .{});
    defer arena.deinit();
    var pool = PagePool(16 * 1024).init(&arena);
    const p1 = try pool.get();
    p1[5] = 9;
    try testing.expect(@intFromPtr(p1) % 64 == 0);
    pool.put(p1);
    const p2 = try pool.get();
    try testing.expectEqual(p1, p2);
    try testing.expectEqual(@as(u8, 0), p2[5]);
}

const Workload = struct { n: usize };

fn sampleRequest(arena: *Arena, w: Workload) anyerror!void {
    var out = Scratch.init(arena);
    try out.append("{\"trip\":{\"legs\":[");
    for (0..w.n) |i| try out.print("{{\"i\":{d}}},", .{i});
    try out.append("]}}");
    var labels: std.ArrayList(u64) = .empty;
    for (0..w.n * 4) |i| try labels.append(arena.allocator(), i);
    try testing.expect(out.items().len > w.n);
}

test "expectNoSteadyStateAlloc passes for an arena-only workload" {
    try expectNoSteadyStateAlloc(Workload, .{ .n = 2000 }, sampleRequest);
}

fn leakyRequest(arena: *Arena, w: Workload) anyerror!void {
    _ = arena;
    const tmp = try testing.allocator.alloc(u8, w.n);
    testing.allocator.free(tmp);
}

test "expectNoSteadyStateAlloc ignores allocators other than the arena's backing" {
    // The helper only sees the arena's backing allocator; code that bypasses
    // the arena is caught by review and by the per-endpoint helper tests.
    try expectNoSteadyStateAlloc(Workload, .{ .n = 16 }, leakyRequest);
}
