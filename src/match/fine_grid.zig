// Ported from valhalla/meili/grid_traversal.h (Valhalla 3.9.3).
const std = @import("std");
const geo = @import("../geo/root.zig");
const Deadline = @import("../infra/io.zig").Deadline;
const Point = geo.PointLL;

pub const side = 500;
const cell_width: f32 = 0.25 / @as(f32, side);
const step: f64 = cell_width;

pub const Square = struct {
    column: i32,
    row: i32,

    pub fn id(self: Square) u32 {
        return @intCast(self.row * side + self.column);
    }

    pub fn valid(self: Square) bool {
        return self.column >= 0 and self.column < side and self.row >= 0 and self.row < side;
    }

    pub fn clamp(self: Square) Square {
        return .{ .column = std.math.clamp(self.column, 0, side - 1), .row = std.math.clamp(self.row, 0, side - 1) };
    }
};

pub const Grid = struct {
    origin: Point,

    pub fn square(self: Grid, point: Point) Square {
        return .{
            .column = @intFromFloat(@floor((point.lng - self.origin.lng) / step)),
            .row = @intFromFloat(@floor((point.lat - self.origin.lat) / step)),
        };
    }

    pub fn bounds(self: Grid, target: Square) geo.AABB {
        const x = self.origin.lng + @as(f64, @floatFromInt(target.column)) * step;
        const y = self.origin.lat + @as(f64, @floatFromInt(target.row)) * step;
        return .init(x, y, x + step, y + step);
    }

    pub fn visits(self: Grid, from: Point, to: Point, target: Square, deadline: Deadline) !bool {
        const delta_x = to.lng - from.lng;
        const delta_y = to.lat - from.lat;
        const ray: Ray = .{
            .grid = self,
            .start = from,
            .rise = if (delta_x == 0) null else delta_y / delta_x,
            .run = if (delta_y == 0) null else delta_x / delta_y,
        };
        const end = self.square(to);
        var at = ray.first(to) orelse return false;
        while (at.valid()) {
            if (at.row == target.row and at.column == target.column) return true;
            const dx = std.math.sign(end.column - at.column);
            const dy = std.math.sign(end.row - at.row);
            if (dx == 0 and dy == 0) break;
            if (deadline.expired()) return error.DeadlineExceeded;
            if (dx != 0 and ray.rowAt(at.column + @intFromBool(dx > 0)) == at.row) {
                at.column += dx;
            } else if (dy != 0 and ray.columnAt(at.row + @intFromBool(dy > 0)) == at.column) {
                at.row += dy;
            } else {
                at.column += dx;
                at.row += dy;
            }
        }
        return false;
    }
};

const Ray = struct {
    grid: Grid,
    start: Point,
    rise: ?f64,
    run: ?f64,

    fn columnAt(self: Ray, row: i32) i32 {
        const slope = self.run orelse return -1;
        const y = self.grid.origin.lat + @as(f64, @floatFromInt(row)) * step;
        return cell((y - self.start.lat) * slope + self.start.lng, self.grid.origin.lng);
    }

    fn rowAt(self: Ray, column: i32) i32 {
        const slope = self.rise orelse return -1;
        const x = self.grid.origin.lng + @as(f64, @floatFromInt(column)) * step;
        return cell((x - self.start.lng) * slope + self.start.lat, self.grid.origin.lat);
    }

    fn cell(point: f64, origin: f64) i32 {
        const at = @floor((point - origin) / step);
        if (at < 0 or at >= side) return -1;
        return @intFromFloat(at);
    }

    fn first(self: Ray, end: Point) ?Square {
        const start = self.grid.square(self.start);
        if (start.valid()) return start;
        const origin = self.grid.origin;
        const east = origin.lng + side * step;
        const north = origin.lat + side * step;
        if (start.column < 0 and end.lng >= origin.lng) {
            const at: Square = .{ .column = 0, .row = self.rowAt(0) };
            if (at.valid()) return at;
        } else if (start.column >= side and end.lng < east) {
            const at: Square = .{ .column = side - 1, .row = self.rowAt(side - 1) };
            if (at.valid()) return at;
        }
        if (start.row < 0 and end.lat >= origin.lat) {
            const at: Square = .{ .column = self.columnAt(0), .row = 0 };
            if (at.valid()) return at;
        } else if (start.row >= side and end.lat < north) {
            const at: Square = .{ .column = self.columnAt(side - 1), .row = side - 1 };
            if (at.valid()) return at;
        }
        return null;
    }
};
