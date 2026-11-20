// Ported from src/mjolnir/add_predicted_speeds.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const radix = @import("../infra/radix.zig");
const csv = @import("../build/gtfs/csv.zig");
const format = @import("../graph/format.zig");
const keys = @import("../graph/edge_keys.zig");
const max_assumed_speed = @import("../graph/constants.zig").max_assumed_speed;
const live = @import("live.zig");
const predicted = @import("predicted.zig");
const codec = @import("predicted_codec.zig");
const Allocator = std.mem.Allocator;
const EdgeId = format.EdgeId;

pub const Report = struct {
    rows: usize = 0,
    applied_rows: usize = 0,
    invalid_rows: usize = 0,
    duplicate_rows: usize = 0,
    unknown_keys: usize = 0,
    clamped_speeds: usize = 0,
    updated_edges: usize = 0,
    edges_with_profiles: usize = 0,
    unique_profiles: usize = 0,
    profile_dedup_ratio: ?f64 = null,
    profile_storage_bytes: usize = 0,
};

const Input = struct {
    key: keys.Key,
    free_flow: u8,
    constrained: u8,
    profile: ?codec.Profile,
    clamped: u2,
};

pub fn parseRow(fields: []const csv.Field, deadline: io.Deadline) !Input {
    if (fields.len == 0 or fields.len > 4) return error.InvalidPredictedTrafficRow;
    const key = try keys.Key.parse(std.mem.trim(u8, fields[0].raw, " \t"));
    const free_flow = try parseSpeed(fields, 1);
    const constrained = try parseSpeed(fields, 2);
    const encoded = if (fields.len == 4) std.mem.trim(u8, fields[3].raw, " \t") else "";
    return .{
        .key = key,
        .free_flow = @intCast(@min(free_flow, max_assumed_speed)),
        .constrained = @intCast(@min(constrained, max_assumed_speed)),
        .clamped = @as(u2, @intFromBool(free_flow > max_assumed_speed)) + @intFromBool(constrained > max_assumed_speed),
        .profile = if (encoded.len != 0) try codec.decode(encoded, deadline) else null,
    };
}

fn parseSpeed(fields: []const csv.Field, i: usize) !u32 {
    if (fields.len <= i) return 0;
    const text = std.mem.trim(u8, fields[i].raw, " \t");
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidPredictedTrafficRow;
}

fn isHeader(fields: []const csv.Field) bool {
    const names = [_][]const u8{ "edge_key", "free_flow", "constrained", "coefficients" };
    if (fields.len == 0 or fields.len > names.len) return false;
    for (fields, names[0..fields.len]) |field, name| {
        if (!std.mem.eql(u8, field.raw, name)) return false;
    }
    return true;
}

const Intern = struct {
    items: std.ArrayList(codec.StoredProfile) = .empty,
    ids: std.HashMapUnmanaged(u32, void, IndexContext, std.hash_map.default_max_load_percentage) = .empty,

    const IndexContext = struct {
        profiles: []const codec.StoredProfile,

        pub fn hash(self: IndexContext, index: u32) u64 {
            return hashProfile(&self.profiles[index].coefficients);
        }

        pub fn eql(_: IndexContext, a: u32, b: u32) bool {
            return a == b;
        }
    };

    const ProfileContext = struct {
        profiles: []const codec.StoredProfile,

        pub fn hash(_: ProfileContext, profile: *const codec.Profile) u64 {
            return hashProfile(profile);
        }

        pub fn eql(self: ProfileContext, profile: *const codec.Profile, index: u32) bool {
            return std.mem.eql(i16, profile, &self.profiles[index].coefficients);
        }
    };

    fn hashProfile(profile: *const codec.Profile) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(profile));
    }

    fn add(self: *Intern, a: Allocator, profile: *const codec.Profile) !u32 {
        if (self.items.items.len >= predicted.no_profile) return error.PredictedTrafficTooLarge;
        try self.items.ensureUnusedCapacity(a, 1);
        const saved = self.items.items;
        const gop = try self.ids.getOrPutContextAdapted(a, profile, ProfileContext{ .profiles = saved }, IndexContext{ .profiles = saved });
        if (!gop.found_existing) {
            gop.key_ptr.* = @intCast(saved.len);
            self.items.appendAssumeCapacity(codec.StoredProfile.init(profile.*));
        }
        return gop.key_ptr.*;
    }

    fn deinit(self: *Intern, a: Allocator) void {
        self.ids.deinit(a);
        self.items.deinit(a);
    }
};

const Update = struct { edge: EdgeId, data: predicted.EdgeData };

fn byEdge(_: void, update: Update) u64 {
    return @backingInt(update.edge);
}

/// The directory lock serializes writers until the caller closes the handle.
pub fn apply(a: Allocator, dir: io.Directory, uuid: format.DatasetUuid, edge_count: u32, index: keys.View, bytes: []const u8, deadline: io.Deadline) !Report {
    try dir.lockExclusive();
    const saved = try predicted.Reader.open(dir, uuid, edge_count, deadline);
    defer if (saved) |reader| reader.close();
    const previous = if (saved) |reader| reader.view else null;

    var fields: std.ArrayList(csv.Field) = .empty;
    defer fields.deinit(a);
    var seen: std.AutoHashMapUnmanaged(EdgeId, void) = .empty;
    defer seen.deinit(a);
    var changes: std.ArrayList(Update) = .empty;
    defer changes.deinit(a);
    var incoming: Intern = .{};
    defer incoming.deinit(a);
    var report: Report = .{};
    var source = csv.Reader.init(bytes, "traffic-pred");
    var diagnostic: csv.Diagnostic = .{};
    var first = true;
    while (try source.next(a, &fields, &diagnostic, deadline)) |record| {
        if (first) {
            first = false;
            if (isHeader(record)) continue;
        }
        report.rows += 1;
        const row = parseRow(record, deadline) catch |err| switch (err) {
            error.InvalidPredictedTrafficRow, error.InvalidPredictedProfile, error.InvalidEdgeKey => {
                report.invalid_rows += 1;
                continue;
            },
            else => return err,
        };
        const edge = (try index.find(row.key)) orelse {
            report.unknown_keys += 1;
            continue;
        };
        const gop = try seen.getOrPut(a, edge);
        if (gop.found_existing) {
            report.duplicate_rows += 1;
            continue;
        }
        report.applied_rows += 1;
        report.clamped_speeds += row.clamped;
        const profile = if (row.profile) |*coefficients| try incoming.add(a, coefficients) else predicted.no_profile;
        const data: predicted.EdgeData = .{ .profile = profile, .free_flow = row.free_flow, .constrained = row.constrained };
        if (data.present()) try changes.append(a, .{ .edge = edge, .data = data });
    }

    const scratch = try a.alloc(Update, changes.items.len);
    defer a.free(scratch);
    try radix.sortByU64(Update, a, changes.items, scratch, {}, byEdge, deadline);
    const blocks = try a.alloc(live.RankBlock, predicted.blockCount(edge_count));
    defer a.free(blocks);
    var records: std.ArrayList(predicted.EdgeData) = .empty;
    defer records.deinit(a);
    var profiles: Intern = .{};
    defer profiles.deinit(a);
    var next_change: usize = 0;
    for (blocks, 0..) |*block, group| {
        if (group % 1024 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const before = if (previous) |view| view.blocks[group] else live.RankBlock{ .mask = 0, .first = 0 };
        const lo = next_change;
        var mask = before.mask;
        while (next_change < changes.items.len and @backingInt(changes.items[next_change].edge) / 64 == group) : (next_change += 1) {
            mask |= @as(u64, 1) << @as(u6, @truncate(@backingInt(changes.items[next_change].edge)));
        }
        block.* = .{ .mask = mask, .first = @intCast(records.items.len) };
        var previous_id = before.first;
        var changed_id = lo;
        while (mask != 0) : (mask &= mask - 1) {
            const offset = @ctz(mask);
            const bit = @as(u64, 1) << @as(u6, @intCast(offset));
            const edge = group * 64 + offset;
            const old = if (before.mask & bit != 0) previous.?.records[previous_id] else predicted.EdgeData{};
            previous_id += @intFromBool(before.mask & bit != 0);
            const replaced = changed_id < next_change and @backingInt(changes.items[changed_id].edge) == edge;
            const new = if (replaced) changes.items[changed_id].data else predicted.EdgeData{};
            changed_id += @intFromBool(replaced);
            const coefficients = if (new.profile != predicted.no_profile)
                &incoming.items.items[new.profile].coefficients
            else if (old.profile != predicted.no_profile)
                &previous.?.profiles[old.profile].coefficients
            else
                null;
            const profile = if (coefficients) |projection| try profiles.add(a, projection) else predicted.no_profile;
            report.edges_with_profiles += @intFromBool(profile != predicted.no_profile);
            try records.append(a, .{
                .profile = profile,
                .free_flow = if (new.free_flow != 0) new.free_flow else old.free_flow,
                .constrained = if (new.constrained != 0) new.constrained else old.constrained,
            });
        }
    }
    if (next_change != changes.items.len) return error.InvalidEdgeKeyIndex;
    try predicted.write(dir, uuid, edge_count, blocks, records.items, profiles.items.items, deadline);
    report.updated_edges = records.items.len;
    report.unique_profiles = profiles.items.items.len;
    report.profile_storage_bytes = report.unique_profiles * @sizeOf(codec.StoredProfile);
    if (report.unique_profiles != 0)
        report.profile_dedup_ratio = @as(f64, @floatFromInt(report.edges_with_profiles)) / @as(f64, @floatFromInt(report.unique_profiles));
    return report;
}
