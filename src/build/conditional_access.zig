// Ported from src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const pbf = @import("pbf/root.zig");
const time = @import("time_parsing.zig");
const access = @import("../graph/access_restriction.zig");
const Access = @import("../graph/constants.zig").AccessMask;
const io = @import("../infra/io.zig");

pub const Parser = struct {
    times: time.Parser,
    domains: std.ArrayList(u64) = .empty,

    pub fn init(a: std.mem.Allocator, deadline: io.Deadline) Parser {
        return .{ .times = .{ .a = a, .deadline = deadline } };
    }

    pub fn deinit(self: *Parser) void {
        self.domains.deinit(self.times.a);
        self.times.deinit();
    }

    pub noinline fn append(self: *Parser, tags: pbf.block.TagIterator, entries: *std.ArrayList(access.Entry)) !void {
        var cursor = tags;
        while (try cursor.next()) |tag| {
            if (self.times.deadline.expired()) return error.DeadlineExceeded;
            const mark = std.mem.indexOfScalar(u8, tag.key, ':') orelse continue;
            if (!std.mem.startsWith(u8, tag.key[mark..], ":conditional")) continue;
            const mode = tag.key[0..mark];
            if (!mode_masks.has(mode) and !eql(mode, "motorcar")) continue;
            var fields = std.mem.tokenizeScalar(u8, tag.value, '@');
            const state = std.mem.trim(u8, fields.next() orelse continue, " \t\r\n");
            const condition = fields.next() orelse continue;
            if (state.len == 0 or fields.next() != null) continue;
            const kind: access.Kind = if (eql(state, "yes") or eql(state, "delivery") or eql(state, "designated"))
                .timed_allowed
            else if (eql(state, "destination") or eql(state, "private"))
                .destination_allowed
            else
                .timed_denied;
            const modes = mode_masks.get(mode) orelse if (kind == .timed_allowed)
                bits(.{ .auto = true, .hov = true, .taxi = true })
            else
                bits(.{ .auto = true, .truck = true, .emergency = true, .taxi = true, .bus = true, .hov = true });
            self.domains.clearRetainingCapacity();
            try self.times.parse(condition, &self.domains);
            for (self.domains.items, 0..) |domain, i| {
                if (i % 256 == 0 and self.times.deadline.expired()) return error.DeadlineExceeded;
                try entries.append(self.times.a, .{ .value = domain, .attr = .{ .kind = kind, .direction = .both, .modes = modes } });
            }
        }
    }
};

const foot = bits(.{ .pedestrian = true, .wheelchair = true });
const moped = bits(.{ .moped = true });
const mode_masks = std.StaticStringMap(u12).initComptime(.{
    .{ "access", 0x0fff },
    .{ "motor_vehicle", bits(.{ .auto = true, .truck = true, .emergency = true, .taxi = true, .bus = true, .hov = true, .moped = true, .motorcycle = true }) },
    .{ "bicycle", bits(.{ .bicycle = true }) },
    .{ "foot", foot },
    .{ "pedestrian", foot },
    .{ "hgv", bits(.{ .truck = true }) },
    .{ "moped", moped },
    .{ "mofa", moped },
    .{ "motorcycle", bits(.{ .motorcycle = true }) },
    .{ "psv", bits(.{ .taxi = true, .bus = true }) },
    .{ "taxi", bits(.{ .taxi = true }) },
    .{ "bus", bits(.{ .bus = true }) },
    .{ "hov", bits(.{ .hov = true }) },
    .{ "emergency", bits(.{ .emergency = true }) },
});

fn bits(access_mask: Access) u12 {
    return @truncate(@as(u16, @bitCast(access_mask)));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
