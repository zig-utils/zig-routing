// Ported from src/mjolnir/admin.cc (Valhalla 3.9.3).
// The native section stores a sparse grid of clipped polygon pieces.
const std = @import("std");
const io = @import("../infra/io.zig");
const polygon = @import("../geo/polygon.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const AABB = @import("../geo/aabb.zig").AABB;

pub const Id = u16;
pub const unknown: Id = 0;
pub const columns = 180;
pub const rows = 90;
const cell_width = 2;

pub const Header = extern struct {
    version: u32 = 1,
    regions: u32,
    cells: u32,
    pieces: u32,
    rings: u32,
    vertices: u32,
    string_bytes: u32,
    reserved: u32 = 0,
};

pub const Span = extern struct {
    first: u32,
    count: u32,

    pub fn get(self: Span, slice: anytype) error{InvalidAdminIndex}!@TypeOf(slice) {
        if (self.first > slice.len or self.count > slice.len - self.first) return error.InvalidAdminIndex;
        return slice[self.first..][0..self.count];
    }
};

pub const Region = extern struct {
    osm_id: i64,
    attr: packed struct(u64) {
        parent: Id = unknown,
        level: u8,
        drive_on_right: bool,
        allow_intersection_names: bool,
        reserved: u38 = 0,
    },
    name: Span,
    english_name: Span,
    iso_code: Span,
    default_language: Span,
};

pub const Cell = extern struct {
    id: u32,
    pieces: Span,
};

pub const Piece = extern struct {
    attr: packed struct(u32) { region: Id, reserved: u16 = 0 },
    rings: Span,
};

pub const Names = struct {
    country: []const u8 = "",
    country_iso: []const u8 = "",
    state: []const u8 = "",
    state_iso: []const u8 = "",
};

pub const View = struct {
    regions: []const Region,
    cells: []const Cell,
    pieces: []const Piece,
    rings: []const Span,
    vertices: []const PointLL,
    strings: []const u8,

    pub fn write(self: View, writer: anytype) !void {
        const header: Header = .{
            .regions = try count(self.regions.len),
            .cells = try count(self.cells.len),
            .pieces = try count(self.pieces.len),
            .rings = try count(self.rings.len),
            .vertices = try count(self.vertices.len),
            .string_bytes = try count(self.strings.len),
        };
        try writer.append(std.mem.asBytes(&header));
        inline for (.{ self.vertices, self.regions, self.cells, self.pieces, self.rings, self.strings }) |slice| {
            try writer.append(std.mem.sliceAsBytes(slice));
        }
    }

    pub fn parse(bytes: []const u8) error{InvalidAdminIndex}!View {
        if (bytes.len < @sizeOf(Header) or !std.mem.isAligned(@intFromPtr(bytes.ptr), @alignOf(PointLL)))
            return error.InvalidAdminIndex;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (header.version != 1 or header.reserved != 0 or header.regions > std.math.maxInt(Id) or header.cells > rows * columns)
            return error.InvalidAdminIndex;
        var remaining: []align(8) const u8 = @alignCast(bytes[@sizeOf(Header)..]);
        const vertices = try take(PointLL, header.vertices, &remaining);
        const regions = try take(Region, header.regions, &remaining);
        // The first two record types keep the cursor aligned to eight.
        var rest: []align(4) const u8 = remaining;
        const cells = try take(Cell, header.cells, &rest);
        const pieces = try take(Piece, header.pieces, &rest);
        const rings = try take(Span, header.rings, &rest);
        if (rest.len != header.string_bytes) return error.InvalidAdminIndex;
        return .{ .regions = regions, .cells = cells, .pieces = pieces, .rings = rings, .vertices = vertices, .strings = rest };
    }

    pub fn region(self: View, id: Id) error{InvalidAdminIndex}!?Region {
        if (id == unknown) return null;
        if (id > self.regions.len) return error.InvalidAdminIndex;
        return self.regions[id - 1];
    }

    pub fn text(self: View, span: Span) error{InvalidAdminIndex}![]const u8 {
        return span.get(self.strings);
    }

    /// A state stores the ID of its covering country.
    pub fn names(self: View, id: Id) error{InvalidAdminIndex}!Names {
        const area = (try self.region(id)) orelse return .{};
        if (area.attr.level == 2) {
            return .{ .country = try self.text(area.name), .country_iso = try self.text(area.iso_code) };
        }
        if (area.attr.level != 4 or area.attr.parent == unknown) return error.InvalidAdminIndex;
        const country = (try self.region(area.attr.parent)) orelse unreachable;
        if (country.attr.level >= area.attr.level) return error.InvalidAdminIndex;
        return .{
            .country = try self.text(country.name),
            .country_iso = try self.text(country.iso_code),
            .state = try self.text(area.name),
            .state_iso = try self.text(area.iso_code),
        };
    }

    pub fn lookup(self: View, point: PointLL, deadline: io.Deadline) !Id {
        if (deadline.expired()) return error.DeadlineExceeded;
        if (!point.inRange()) return unknown;
        const id = cellId(point);
        const box = cellBox(id);
        const west = id % columns != 0 and point.lng == box.minx;
        const south = id >= columns and point.lat == box.miny;
        var result = try self.lookupCell(id, point, deadline);
        if (west) result = prefer(result, try self.lookupCell(id - 1, point, deadline));
        if (south) result = prefer(result, try self.lookupCell(id - columns, point, deadline));
        if (west and south) result = prefer(result, try self.lookupCell(id - columns - 1, point, deadline));
        return if (result.state != unknown) result.state else result.country;
    }

    /// Valhalla assigns a tile's sole admin to every node in that tile.
    pub fn singleArea(self: View, box: AABB, deadline: io.Deadline) !Id {
        if (!box.minpt().inRange() or !box.maxpt().inRange() or box.minx > box.maxx or box.miny > box.maxy)
            return error.InvalidAdminBounds;
        const lo = cellId(box.minpt());
        const hi = cellId(box.maxpt());
        const lo_box = cellBox(lo);
        const start_col = lo % columns - @as(u32, @intFromBool(lo % columns != 0 and box.minx == lo_box.minx));
        const start_row = lo / columns - @as(u32, @intFromBool(lo >= columns and box.miny == lo_box.miny));
        var found: Id = unknown;
        for (start_row..hi / columns + 1) |row| {
            for (start_col..hi % columns + 1) |col| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const pieces = try self.cellPieces(@intCast(row * columns + col));
                for (pieces, 0..) |piece, i| {
                    try checkAt(deadline, i);
                    if (piece.attr.region == found) continue;
                    const area = (try self.region(piece.attr.region)) orelse return error.InvalidAdminIndex;
                    if (!isPoliticalArea(area) or !try self.intersectsBox(piece, box, deadline)) continue;
                    if (found != unknown) return unknown;
                    found = piece.attr.region;
                }
            }
        }
        return found;
    }

    const Match = struct { state: Id = unknown, country: Id = unknown };

    fn prefer(a: Match, b: Match) Match {
        return .{
            .state = if (a.state == unknown) b.state else if (b.state == unknown) a.state else @min(a.state, b.state),
            .country = @max(a.country, b.country),
        };
    }

    noinline fn lookupCell(self: View, id: u32, point: PointLL, deadline: io.Deadline) !Match {
        const pieces = try self.cellPieces(id);
        var country: Id = unknown;
        for (pieces, 0..) |piece, i| {
            try checkAt(deadline, i);
            const area = (try self.region(piece.attr.region)) orelse return error.InvalidAdminIndex;
            if (!isPoliticalArea(area)) continue;
            if (try self.locate(piece, point, deadline) == .outside) continue;
            // Match the state-first, name-ordered queries in Valhalla.
            if (area.attr.level == 4) return .{ .state = piece.attr.region };
            country = piece.attr.region;
        }
        return .{ .country = country };
    }

    fn cellPieces(self: View, id: u32) error{InvalidAdminIndex}![]const Piece {
        var low: usize = 0;
        var high = self.cells.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const cell = self.cells[mid];
            if (cell.id == id) return cell.pieces.get(self.pieces);
            if (cell.id < id) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return &.{};
    }

    fn locate(self: View, piece: Piece, point: PointLL, deadline: io.Deadline) !polygon.Location {
        const rings = try piece.rings.get(self.rings);
        if (rings.len == 0) return error.InvalidAdminIndex;
        const shell = try polygon.locateInRing(try rings[0].get(self.vertices), point, deadline);
        if (shell != .inside) return shell;
        for (rings[1..], 0..) |ring, i| {
            try checkAt(deadline, i);
            switch (try polygon.locateInRing(try ring.get(self.vertices), point, deadline)) {
                .inside => return .outside,
                .boundary => return .boundary,
                .outside => {},
            }
        }
        return .inside;
    }

    fn intersectsBox(self: View, piece: Piece, box: AABB, deadline: io.Deadline) !bool {
        if (try self.locate(piece, box.minpt(), deadline) != .outside) return true;
        const rings = try piece.rings.get(self.rings);
        for (rings, 0..) |ring, i| {
            try checkAt(deadline, i);
            if (try polygon.ringIntersectsBox(try ring.get(self.vertices), box, deadline)) return true;
        }
        return false;
    }

    pub fn verify(self: View, deadline: io.Deadline) !void {
        for (self.regions, 0..) |area, i| {
            try checkAt(deadline, i);
            if (area.attr.reserved != 0 or area.attr.level == 0) return error.InvalidAdminIndex;
            if (try self.region(area.attr.parent)) |parent| {
                if (parent.attr.level >= area.attr.level) return error.InvalidAdminIndex;
            }
            _ = try self.text(area.name);
            _ = try self.text(area.english_name);
            _ = try self.text(area.iso_code);
            _ = try self.text(area.default_language);
        }
        var previous: ?u32 = null;
        var piece_offset: usize = 0;
        for (self.cells, 0..) |cell, i| {
            try checkAt(deadline, i);
            if (cell.id >= rows * columns or (previous != null and cell.id <= previous.?) or
                cell.pieces.first != piece_offset or cell.pieces.count == 0)
                return error.InvalidAdminIndex;
            const pieces = try cell.pieces.get(self.pieces);
            for (pieces, 0..) |piece, j| {
                try checkAt(deadline, j);
                if (piece.attr.region == unknown or piece.attr.region > self.regions.len or
                    piece.attr.reserved != 0 or piece.rings.count == 0)
                    return error.InvalidAdminIndex;
                _ = try piece.rings.get(self.rings);
            }
            piece_offset += pieces.len;
            previous = cell.id;
        }
        if (piece_offset != self.pieces.len) return error.InvalidAdminIndex;
        for (self.rings, 0..) |ring, i| {
            try checkAt(deadline, i);
            if (ring.count < 3) return error.InvalidAdminIndex;
            _ = try ring.get(self.vertices);
        }
        for (self.vertices, 0..) |vertex, i| {
            try checkAt(deadline, i);
            if (!vertex.inRange()) return error.InvalidAdminIndex;
        }
    }
};

fn isPoliticalArea(area: Region) bool {
    return area.attr.level == 2 or (area.attr.level == 4 and area.attr.parent != unknown);
}

fn count(len: usize) !u32 {
    return std.math.cast(u32, len) orelse error.AdminIndexTooLarge;
}

fn take(comptime T: type, item_count: u32, bytes: anytype) error{InvalidAdminIndex}![]const T {
    const size = @as(u64, item_count) * @sizeOf(T);
    if (size > bytes.len) return error.InvalidAdminIndex;
    const end: usize = @intCast(size);
    const items = std.mem.bytesAsSlice(T, bytes.*[0..end]);
    bytes.* = @alignCast(bytes.*[end..]);
    return items;
}

/// Both positive ends of the world belong to the final column or row.
pub fn cellId(point: PointLL) u32 {
    const x: u32 = @intFromFloat(@min(columns - 1, (point.lng + 180) / cell_width));
    const y: u32 = @intFromFloat(@min(rows - 1, (point.lat + 90) / cell_width));
    return y * columns + x;
}

pub fn cellBox(id: u32) AABB {
    const x: f64 = @floatFromInt(id % columns);
    const y: f64 = @floatFromInt(id / columns);
    const lo = PointLL.init(x * cell_width - 180, y * cell_width - 90);
    return AABB.fromPoints(lo, .init(lo.lng + cell_width, lo.lat + cell_width));
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 32 and @offsetOf(Header, "vertices") == 20);
    std.debug.assert(@sizeOf(PointLL) == 16 and @offsetOf(PointLL, "lng") == 0 and @offsetOf(PointLL, "lat") == 8);
    std.debug.assert(@sizeOf(Span) == 8 and @offsetOf(Span, "first") == 0 and @offsetOf(Span, "count") == 4);
    std.debug.assert(@sizeOf(Region) == 48 and @offsetOf(Region, "osm_id") == 0 and @offsetOf(Region, "attr") == 8);
    std.debug.assert(@offsetOf(Region, "name") == 16 and @offsetOf(Region, "english_name") == 24);
    std.debug.assert(@offsetOf(Region, "iso_code") == 32 and @offsetOf(Region, "default_language") == 40);
    std.debug.assert(@sizeOf(Cell) == 12 and @offsetOf(Cell, "id") == 0 and @offsetOf(Cell, "pieces") == 4);
    std.debug.assert(@sizeOf(Piece) == 12 and @offsetOf(Piece, "attr") == 0 and @offsetOf(Piece, "rings") == 4);
}
