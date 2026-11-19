//! Sparse, content-addressed local storage for an immutable remote bundle.
//! The bitmap is a restart hint. A previously downloaded extent is checked
//! before any reader can observe it in a new process.
const std = @import("std");
const io = @import("../infra/io.zig");
const format = @import("format.zig");
const manifests = @import("range_manifest.zig");
const Allocator = std.mem.Allocator;
const Kind = format.SectionKind;
const kinds = std.enums.values(Kind);
const Word = std.atomic.Value(u32);

const Stat = enum(u32) { missing, fetching, present };

pub const Source = struct {
    context: *const anyopaque,
    fetch: *const fn (*const anyopaque, Kind, usize, usize, []u8, io.Deadline) anyerror!void,
};

pub const Options = struct {
    attempts: u8 = 3,
    /// Upper bound for one transfer, even outside a request.
    transfer_timeout_ms: u32 = 2_000,
};

pub const Range = struct {
    kind: Kind,
    offset: usize,
    len: usize,
};

const Local = struct {
    file: io.File,
    mapping: io.Mapping,
    bitmap: io.Mapping,
    extents: []Word,

    fn open(a: Allocator, dir: io.Directory, kind: Kind, section: manifests.Section) !Local {
        const file = try dir.openOrCreateFile(kind.filename());
        errdefer file.close();
        try sizeFile(file, section.size);
        const mapping = try io.Mapping.mapFd(file, .read_only);
        errdefer mapping.unmap();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&name_buf, "{s}.fill", .{kind.filename()}, 0);
        const bits = try dir.openOrCreateFile(name);
        defer bits.close();
        try sizeFile(bits, (section.extents.len - 1) / 8 + 1);
        const bitmap = try io.Mapping.mapFd(bits, .shared_writable);
        errdefer bitmap.unmap();
        const extents = try a.alloc(Word, section.extents.len);
        @memset(extents, .init(@backingInt(Stat.missing)));
        return .{ .file = file, .mapping = mapping, .bitmap = bitmap, .extents = extents };
    }

    fn close(self: Local, a: Allocator) void {
        a.free(self.extents);
        self.bitmap.unmap();
        self.mapping.unmap();
        self.file.close();
    }

    fn sizeFile(file: io.File, size: usize) !void {
        const current = try file.size();
        if (current == 0) {
            try file.truncate(size);
        } else if (current != size) {
            return error.RangeCacheSizeMismatch;
        }
    }

    fn bit(index: usize) u8 {
        return @as(u8, 1) << @as(u3, @truncate(index));
    }

    fn remembered(self: Local, index: usize) bool {
        return @atomicLoad(u8, &self.bitmap.bytes[index / 8], .monotonic) & bit(index) != 0;
    }

    fn forget(self: Local, index: usize) void {
        _ = @atomicRmw(u8, &self.bitmap.bytes[index / 8], .And, ~bit(index), .monotonic);
    }

    fn remember(self: Local, index: usize) void {
        _ = @atomicRmw(u8, &self.bitmap.bytes[index / 8], .Or, bit(index), .monotonic);
    }
};

pub const Cache = struct {
    a: Allocator,
    dir: io.Directory,
    key: [64]u8,
    manifest: manifests.Manifest,
    files: std.EnumArray(Kind, ?Local) = .initFill(null),
    source: Source,
    options: Options,

    /// `manifest_bytes` and `source.context` must outlive the cache. Each
    /// manifest owns a separate directory, locked until its workers finish.
    pub fn open(a: Allocator, parent: io.Directory, manifest_bytes: []const u8, source: Source, options: Options, deadline: io.Deadline) !Cache {
        if (options.attempts == 0 or options.transfer_timeout_ms == 0) return error.InvalidRangeCacheOptions;
        const manifest = try manifests.Manifest.parse(manifest_bytes, deadline);
        var name: [65]u8 = @splat(0);
        name[0..64].* = std.fmt.bytesToHex(try manifests.digestFile(manifest_bytes, deadline), .lower);
        const cache_name: [:0]const u8 = name[0..64 :0];
        const dir = parent.createChild(cache_name) catch |err| switch (err) {
            error.PathAlreadyExists => try parent.child(cache_name),
            else => return err,
        };
        var self: Cache = .{ .a = a, .dir = dir, .key = name[0..64].*, .manifest = manifest, .source = source, .options = options };
        errdefer self.close();
        try dir.lockExclusive();
        for (kinds) |kind| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const section = manifest.sections.get(kind) orelse continue;
            self.files.set(kind, try Local.open(a, dir, kind, section));
        }
        return self;
    }

    /// Workers and borrowed slices must be quiescent before close.
    pub fn close(self: *Cache) void {
        for (self.files.values) |entry| if (entry) |local| local.close(self.a);
        self.dir.close();
        self.* = undefined;
    }

    /// Return a borrowed byte range only after every covering extent has
    /// passed verification. An already present extent only needs an atomic load.
    pub fn read(self: *const Cache, range: Range, deadline: io.Deadline) ![]const u8 {
        if (deadline.expired()) return error.DeadlineExceeded;
        const section = self.manifest.sections.get(range.kind) orelse return error.MissingSection;
        const local = self.files.get(range.kind).?;
        if (range.offset > section.size or range.len > section.size - range.offset) return error.OutOfBounds;
        if (range.len == 0) return &.{};
        const end = range.offset + range.len;
        for (range.offset / manifests.extent_size..(end - 1) / manifests.extent_size + 1) |index| {
            try self.ensure(range.kind, section, local, index, deadline);
        }
        return local.mapping.bytes[range.offset..end];
    }

    /// Run on a background worker. Recent ranges use the same single-flight
    /// read path as queries. Hot sections lead, then recent ranges, then the rest.
    pub fn fill(self: *const Cache, recent: []const Range, deadline: io.Deadline) !void {
        for (kinds) |kind| {
            if (kind.placement() != .hot) continue;
            if (self.manifest.sections.get(kind)) |section| _ = try self.read(.{ .kind = kind, .offset = 0, .len = section.size }, deadline);
        }
        for (recent) |range| _ = try self.read(range, deadline);
        for (kinds) |kind| {
            const section = self.manifest.sections.get(kind) orelse continue;
            const bytes = try self.read(.{ .kind = kind, .offset = 0, .len = section.size }, deadline);
            const hash = try manifests.digestFile(bytes, deadline);
            if (!std.mem.eql(u8, &hash, &section.digest)) return error.RangeSectionHashMismatch;
        }
    }

    fn ensure(self: *const Cache, kind: Kind, section: manifests.Section, local: Local, index: usize, deadline: io.Deadline) !void {
        const state = &local.extents[index];
        while (true) {
            if (deadline.expired()) return error.DeadlineExceeded;
            switch (@as(Stat, @fromBackingInt(state.load(.acquire)))) {
                .present => return,
                .fetching => io.waitAtomic(state, @backingInt(Stat.fetching), deadline),
                .missing => {
                    if (state.cmpxchgStrong(@backingInt(Stat.missing), @backingInt(Stat.fetching), .acq_rel, .acquire) != null) continue;
                    defer io.wakeAtomic(state);
                    errdefer state.store(@backingInt(Stat.missing), .release);
                    try self.fetch(kind, section, local, index, deadline);
                    state.store(@backingInt(Stat.present), .release);
                    return;
                },
            }
        }
    }

    noinline fn fetch(self: *const Cache, kind: Kind, section: manifests.Section, local: Local, index: usize, deadline: io.Deadline) !void {
        const target = section.extent(index).?;
        if (local.remembered(index)) {
            const bytes = local.mapping.bytes[target.offset..][0..target.len];
            if (std.mem.eql(u8, &manifests.digest(bytes), &target.digest)) return;
            local.forget(index);
        }
        var buffer: [manifests.extent_size]u8 = undefined;
        var failure: anyerror = error.RangeExtentUnavailable;
        for (0..self.options.attempts) |attempt| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (attempt > 0) {
                const delay = @as(u64, 10) << @as(u3, @intCast(@min(attempt - 1, 5)));
                io.sleepMs(@min(delay, deadline.remainingNs() / std.time.ns_per_ms));
                if (deadline.expired()) return error.DeadlineExceeded;
            }
            const budget = deadline.min(.fromNowMs(self.options.transfer_timeout_ms));
            const bytes = buffer[0..target.len];
            self.source.fetch(self.source.context, kind, target.offset, section.size, bytes, budget) catch |err| {
                failure = err;
                continue;
            };
            if (!std.mem.eql(u8, &manifests.digest(bytes), &target.digest)) {
                failure = error.RangeExtentHashMismatch;
                continue;
            }
            try local.file.pwriteAll(bytes, target.offset);
            local.remember(index);
            return;
        }
        if (deadline.expired()) return error.DeadlineExceeded;
        return failure;
    }
};
