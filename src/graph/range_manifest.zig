//! Range-fetch manifest for one immutable bundle. Sections appear in kind
//! order, with a SHA-256 for the file followed by one per 64 KiB extent.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../infra/io.zig");
const format = @import("format.zig");
const Bundle = @import("reader.zig").Bundle;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Kind = format.SectionKind;
const kinds = std.enums.values(Kind);

pub const extent_size = format.payload_offset;
pub const Digest = [Sha256.digest_length]u8;
pub const Sections = std.EnumArray(Kind, ?Section);

const magic = "ZRANGES\x00".*;
const version: u32 = 1;
const Header = extern struct {
    signature: [8]u8 = magic,
    version: u32,
    count: u32,
    dataset_uuid: format.DatasetUuid,
};
const FileRecord = extern struct {
    kind: u32,
    reserved: u32 = 0,
    size: u64,
    digest: Digest,
};

comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 32 and @offsetOf(Header, "dataset_uuid") == 16);
    std.debug.assert(@sizeOf(FileRecord) == 48 and @offsetOf(FileRecord, "size") == 8 and @offsetOf(FileRecord, "digest") == 16);
}

pub const Section = struct {
    size: usize,
    digest: Digest,
    extents: []const Digest,

    pub fn extent(self: Section, index: usize) ?struct { offset: usize, len: usize, digest: Digest } {
        if (index >= self.extents.len) return null;
        const offset = index * extent_size;
        return .{ .offset = offset, .len = @min(extent_size, self.size - offset), .digest = self.extents[index] };
    }
};

pub const Manifest = struct {
    dataset_uuid: format.DatasetUuid,
    sections: Sections,

    /// Borrows the extent digests from bytes. The caller supplies the trusted
    /// manifest for the origin and keeps it alive while the cache uses it.
    pub fn parse(bytes: []const u8, deadline: io.Deadline) !Manifest {
        if (bytes.len < @sizeOf(Header)) return error.InvalidRangeManifest;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &header.signature, &magic) or header.version != version or
            header.count > kinds.len) return error.InvalidRangeManifest;

        var result: Manifest = .{ .dataset_uuid = header.dataset_uuid, .sections = .initFill(null) };
        var remainder = bytes[@sizeOf(Header)..];
        var previous: u32 = 0;
        for (0..header.count) |_| {
            if (deadline.expired()) return error.DeadlineExceeded;
            if (remainder.len < @sizeOf(FileRecord)) return error.InvalidRangeManifest;
            const record = std.mem.bytesToValue(FileRecord, remainder[0..@sizeOf(FileRecord)]);
            const kind = std.enums.fromInt(Kind, record.kind) orelse return error.InvalidRangeManifest;
            if (record.kind <= previous or record.reserved != 0 or
                record.size < extent_size or record.size > std.math.maxInt(i64)) return error.InvalidRangeManifest;
            const size = std.math.cast(usize, record.size) orelse return error.InvalidRangeManifest;
            previous = record.kind;
            remainder = remainder[@sizeOf(FileRecord)..];
            const count = extentCount(size);
            if (count > remainder.len / @sizeOf(Digest)) return error.InvalidRangeManifest;
            const end = count * @sizeOf(Digest);
            const hashes: [*]const Digest = @ptrCast(remainder.ptr);
            result.sections.set(kind, .{ .size = size, .digest = record.digest, .extents = hashes[0..count] });
            remainder = remainder[end..];
        }
        if (remainder.len != 0) return error.InvalidRangeManifest;
        for (kinds) |kind| {
            if (format.required_sections.contains(kind) and result.sections.get(kind) == null) return error.InvalidRangeManifest;
        }
        return result;
    }
};

fn extentCount(size: usize) usize {
    return (size - 1) / extent_size + 1;
}

pub fn digest(bytes: []const u8) Digest {
    var hash: Digest = undefined;
    Sha256.hash(bytes, &hash, .{});
    return hash;
}

pub fn digestFile(bytes: []const u8, deadline: io.Deadline) !Digest {
    var hash = Sha256.init(.{});
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (deadline.expired()) return error.DeadlineExceeded;
        const len = @min(bytes.len - offset, 1024 * 1024);
        hash.update(bytes[offset..][0..len]);
        offset += len;
    }
    return hash.finalResult();
}

/// Export from the exact verified bytes that will be served at the origin.
pub fn encode(a: Allocator, bundle: *const Bundle, deadline: io.Deadline) ![]u8 {
    var total: usize = @sizeOf(Header);
    var count: u32 = 0;
    for (kinds) |kind| {
        const bytes = bundle.mappings.get(kind).bytes;
        if (bytes.len == 0) continue;
        total += @sizeOf(FileRecord) + extentCount(bytes.len) * @sizeOf(Digest);
        count += 1;
    }
    const buffer = try a.alloc(u8, total);
    errdefer a.free(buffer);

    const header: Header = .{ .version = version, .count = count, .dataset_uuid = bundle.view.dataset_uuid };
    @memcpy(buffer[0..@sizeOf(Header)], std.mem.asBytes(&header));
    var offset: usize = @sizeOf(Header);
    for (kinds) |kind| {
        const bytes = bundle.mappings.get(kind).bytes;
        if (bytes.len == 0) continue;
        const record_start = offset;
        offset += @sizeOf(FileRecord);
        var whole = Sha256.init(.{});
        var start: usize = 0;
        while (start < bytes.len) {
            if (deadline.expired()) return error.DeadlineExceeded;
            const extent = bytes[start..][0..@min(extent_size, bytes.len - start)];
            whole.update(extent);
            buffer[offset..][0..@sizeOf(Digest)].* = digest(extent);
            offset += @sizeOf(Digest);
            start += extent.len;
        }
        var record: FileRecord = .{ .kind = @backingInt(kind), .size = bytes.len, .digest = undefined };
        whole.final(&record.digest);
        @memcpy(buffer[record_start..][0..@sizeOf(FileRecord)], std.mem.asBytes(&record));
    }
    return buffer;
}
