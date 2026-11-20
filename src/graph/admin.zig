// Ported from src/mjolnir/admin.cc (Valhalla 3.9.3).
// The native section stores a sparse grid of clipped polygon pieces.
const std = @import("std");
const io = @import("../infra/io.zig");
const grid = @import("polygon_grid.zig");
const PointLL = @import("../geo/point.zig").PointLL;
const AABB = @import("../geo/aabb.zig").AABB;

pub const Id = grid.Id;
pub const unknown: Id = 0;
pub const columns = grid.columns;
pub const rows = grid.rows;
pub const Span = grid.Span;
pub const Cell = grid.Cell;
pub const Piece = grid.Piece;
pub const cellId = grid.cellId;
pub const cellBox = grid.cellBox;

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
        return span.get(self.strings) catch error.InvalidAdminIndex;
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

    /// Language policy combines every containing area, including language
    /// boundaries that are excluded from political admin lookup.
    pub fn languageAreas(self: View, point: PointLL, out: *std.ArrayList(Id), a: std.mem.Allocator, deadline: io.Deadline) !void {
        out.clearRetainingCapacity();
        if (!point.inRange()) return;
        const cell = cellId(point);
        const box = cellBox(cell);
        const west = cell % columns != 0 and point.lng == box.minx;
        const south = cell >= columns and point.lat == box.miny;
        const geometry = self.gridView();
        for ([_]?u32{
            cell,
            if (west) cell - 1 else null,
            if (south) cell - columns else null,
            if (west and south) cell - columns - 1 else null,
        }) |maybe_cell| {
            const candidate = maybe_cell orelse continue;
            const pieces = geometry.cellPieces(candidate) catch return error.InvalidAdminIndex;
            for (pieces, 0..) |piece, i| {
                try checkAt(deadline, i);
                const id = piece.attr.region;
                const area = (try self.region(id)) orelse return error.InvalidAdminIndex;
                if (area.default_language.count == 0 and !isPoliticalArea(area)) continue;
                if (std.mem.indexOfScalar(Id, out.items, id) != null) continue;
                if ((geometry.locate(piece, point, deadline) catch |err| return gridError(err)) == .outside) continue;
                try out.append(a, id);
            }
        }
        std.sort.heap(Id, out.items, self, languageAreaBefore);
    }

    fn languageAreaBefore(self: View, a: Id, b: Id) bool {
        const left = self.regions[a - 1];
        const right = self.regions[b - 1];
        if (left.attr.level != right.attr.level) return left.attr.level > right.attr.level;
        const left_name = self.text(left.name) catch "";
        const right_name = self.text(right.name) catch "";
        return switch (std.mem.order(u8, left_name, right_name)) {
            .lt => true,
            .gt => false,
            .eq => a < b,
        };
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
        const geometry = self.gridView();
        var found: Id = unknown;
        for (start_row..hi / columns + 1) |row| {
            for (start_col..hi % columns + 1) |col| {
                if (deadline.expired()) return error.DeadlineExceeded;
                const pieces = geometry.cellPieces(@intCast(row * columns + col)) catch return error.InvalidAdminIndex;
                for (pieces, 0..) |piece, i| {
                    try checkAt(deadline, i);
                    if (piece.attr.region == found) continue;
                    const area = (try self.region(piece.attr.region)) orelse return error.InvalidAdminIndex;
                    if (!isPoliticalArea(area)) continue;
                    const intersects = geometry.intersectsBox(piece, box, deadline) catch |err| return gridError(err);
                    if (!intersects) continue;
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
        const geometry = self.gridView();
        const pieces = geometry.cellPieces(id) catch return error.InvalidAdminIndex;
        var country: Id = unknown;
        for (pieces, 0..) |piece, i| {
            try checkAt(deadline, i);
            const area = (try self.region(piece.attr.region)) orelse return error.InvalidAdminIndex;
            if (!isPoliticalArea(area)) continue;
            const location = geometry.locate(piece, point, deadline) catch |err| return gridError(err);
            if (location == .outside) continue;
            // Match the state-first, name-ordered queries in Valhalla.
            if (area.attr.level == 4) return .{ .state = piece.attr.region };
            country = piece.attr.region;
        }
        return .{ .country = country };
    }

    fn gridView(self: View) grid.View {
        return .{ .cells = self.cells, .pieces = self.pieces, .rings = self.rings, .vertices = self.vertices };
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
        const max_id = std.math.cast(Id, self.regions.len) orelse return error.InvalidAdminIndex;
        self.gridView().verify(max_id, deadline) catch |err| return gridError(err);
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

fn gridError(err: anyerror) anyerror {
    return if (err == error.InvalidPolygonIndex) error.InvalidAdminIndex else err;
}

fn checkAt(deadline: io.Deadline, i: usize) !void {
    if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
}

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Header) == 32 and @offsetOf(Header, "vertices") == 20);
    std.debug.assert(@sizeOf(Region) == 48 and @offsetOf(Region, "osm_id") == 0 and @offsetOf(Region, "attr") == 8);
    std.debug.assert(@offsetOf(Region, "name") == 16 and @offsetOf(Region, "english_name") == 24);
    std.debug.assert(@offsetOf(Region, "iso_code") == 32 and @offsetOf(Region, "default_language") == 40);
}
