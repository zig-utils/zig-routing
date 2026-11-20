// Ported from src/mjolnir/pbfgraphparser.cc and
// valhalla/mjolnir/uniquenames.h (Valhalla 3.9.3).

const std = @import("std");
const io = @import("../../infra/io.zig");
const attrs = @import("attrs.zig");
const input = @import("input.zig");

pub const Id = enum(u32) { empty = 0, _ };

pub const LocalizedId = struct {
    text: Id = .empty,
    language: Id = .empty,
};

pub const Options = struct {
    allow_alt_name: bool = false,
    use_admin_db: bool = true,
    use_direction_on_ways: bool = false,
};

pub const Indexed = struct {
    name: LocalizedId,
    alt_name: LocalizedId,
    official_name: LocalizedId,
    ref: LocalizedId,
    int_ref: LocalizedId,
    tunnel_name: LocalizedId,
    bridge_name: Id,
    destination: LocalizedId,
    destination_forward: LocalizedId,
    destination_backward: LocalizedId,
    destination_ref: LocalizedId,
    destination_ref_to: LocalizedId,
    destination_street: LocalizedId,
    destination_street_to: LocalizedId,
    destination_int_ref: Id,
    destination_int_ref_to: Id,
    junction_ref: LocalizedId,
    junction_name: LocalizedId,
    turn_lanes_forward: Id,
    turn_lanes_backward: Id,
};

/// Borrow the raw spellings. Joining, deduplication and ownership happen
/// during indexing, so the way transform itself allocates nothing.
pub fn read(tags: *const input.Scratch) attrs.Names {
    const highway = tags.id(.highway);
    const use_unsigned = (highway == .motorway or highway == .trunk or highway == .primary) and
        tags.get(.name) == null and tags.get(.@"name:en") == null and tags.get(.alt_name) == null and
        tags.get(.official_name) == null and tags.get(.ref) == null and tags.get(.int_ref) == null;
    return .{
        .name = tags.text(.name),
        .alt_name = tags.text(.alt_name),
        .official_name = tags.text(.official_name),
        .ref = if (use_unsigned) tags.text(.unsigned_ref) else tags.text(.ref),
        .int_ref = tags.text(.int_ref),
        .direction = tags.text(.direction),
        .int_direction = tags.text(.int_direction),
        .tunnel_name = tags.text(.@"tunnel:name"),
        .bridge_name = tags.text(.@"bridge:name"),
        .destination = tags.text(.destination),
        .destination_forward = tags.text(.@"destination:forward"),
        .destination_backward = tags.text(.@"destination:backward"),
        .destination_ref = tags.text(.@"destination:ref"),
        .destination_ref_to = tags.text(.@"destination:ref:to"),
        .destination_street = tags.text(.@"destination:street"),
        .destination_street_to = tags.text(.@"destination:street:to"),
        .destination_int_ref = tags.text(.@"destination:int_ref"),
        .destination_int_ref_to = tags.text(.@"destination:int_ref:to"),
        .junction_ref = tags.text(.@"junction:ref"),
        .junction_name = tags.text(.@"junction:name"),
    };
}

const Group = enum {
    name,
    alt_name,
    official_name,
    ref,
    int_ref,
    tunnel_name,
    destination,
    destination_forward,
    destination_backward,
    destination_ref,
    destination_ref_to,
    destination_street,
    destination_street_to,
    junction_name,
    junction_ref,
};

const localized_prefixes = std.StaticStringMap(Group).initComptime(.{
    .{ "name", .name },                                   .{ "alt_name", .alt_name },
    .{ "official_name", .official_name },                 .{ "ref", .ref },
    .{ "int_ref", .int_ref },                             .{ "tunnel:name", .tunnel_name },
    .{ "destination", .destination },                     .{ "destination:forward", .destination_forward },
    .{ "destination:backward", .destination_backward },   .{ "destination:ref", .destination_ref },
    .{ "destination:ref:to", .destination_ref_to },       .{ "destination:street", .destination_street },
    .{ "destination:street:to", .destination_street_to }, .{ "junction:ref", .junction_ref },
    .{ "junction:name", .junction_name },
});

// From stringLanguage in valhalla/baldr/graphconstants.h.
const languages = std.StaticStringMap(void).initComptime(.{
    .{"ab"},      .{"am"},  .{"ar"}, .{"az"}, .{"be"}, .{"bg"}, .{"bn"}, .{"bs"}, .{"ca"}, .{"ckb"}, .{"cs"}, .{"da"},
    .{"de"},      .{"dv"},  .{"dz"}, .{"el"}, .{"en"}, .{"es"}, .{"et"}, .{"fa"}, .{"fi"}, .{"fr"},  .{"fy"}, .{"gl"},
    .{"he"},      .{"hr"},  .{"hu"}, .{"hy"}, .{"id"}, .{"is"}, .{"it"}, .{"ja"}, .{"ka"}, .{"kl"},  .{"km"}, .{"ko"},
    .{"lo"},      .{"lt"},  .{"lv"}, .{"mg"}, .{"mk"}, .{"mn"}, .{"mo"}, .{"mt"}, .{"my"}, .{"ne"},  .{"nl"}, .{"no"},
    .{"oc"},      .{"pap"}, .{"pl"}, .{"ps"}, .{"pt"}, .{"rm"}, .{"ro"}, .{"ru"}, .{"sk"}, .{"sl"},  .{"sq"}, .{"sr"},
    .{"sr-Latn"}, .{"sv"},  .{"tg"}, .{"th"}, .{"tk"}, .{"tr"}, .{"uk"}, .{"ur"}, .{"uz"}, .{"vi"},  .{"zh"}, .{"cy"},
    .{"ta"},      .{"ms"},
});

const Localized = struct {
    key: []const u8,
    group: Group,
    language: []const u8,
    text: []const u8,
};

fn localeTag(key: []const u8, value: []const u8) ?Localized {
    // Pronunciations and side-specific metadata belong to narrative stages.
    const trimmed = std.mem.trimEnd(u8, key, ":");
    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    const language = trimmed[colon + 1 ..];
    if (!languages.has(language)) return null;
    var prefix = trimmed[0..colon];
    if (std.mem.endsWith(u8, prefix, ":lang")) prefix = prefix[0 .. prefix.len - ":lang".len];
    return .{
        .key = key,
        .group = localized_prefixes.get(prefix) orelse return null,
        .language = language,
        .text = value,
    };
}

/// Owns the build's strings and the reusable indexing buffers. Interned
/// strings and IDs survive later calls. Use one table from one writer.
pub const StringTable = struct {
    gpa: std.mem.Allocator,
    storage: std.heap.ArenaAllocator,
    ids: std.StringHashMapUnmanaged(Id) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    localized: std.ArrayList(Localized) = .empty,
    directed_ref: std.ArrayList(u8) = .empty,
    directed_int_ref: std.ArrayList(u8) = .empty,
    merged: std.ArrayList(u8) = .empty,
    filtered: std.ArrayList(u8) = .empty,
    name_text: std.ArrayList(u8) = .empty,
    language_text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) StringTable {
        return .{ .gpa = gpa, .storage = .init(gpa) };
    }

    pub fn deinit(self: *StringTable) void {
        self.ids.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.localized.deinit(self.gpa);
        self.directed_ref.deinit(self.gpa);
        self.directed_int_ref.deinit(self.gpa);
        self.merged.deinit(self.gpa);
        self.filtered.deinit(self.gpa);
        self.name_text.deinit(self.gpa);
        self.language_text.deinit(self.gpa);
        self.storage.deinit();
    }

    pub fn get(self: *const StringTable, id: Id) ?[]const u8 {
        if (id == .empty) return "";
        const index = @backingInt(id) - 1;
        return if (index < self.strings.items.len) self.strings.items[index] else null;
    }

    pub fn intern(self: *StringTable, text: []const u8) !Id {
        if (text.len == 0) return .empty;
        if (self.ids.get(text)) |id| return id;
        if (self.strings.items.len >= std.math.maxInt(u32)) return error.TooManyStrings;
        const id: Id = @fromBackingInt(@intCast(self.strings.items.len + 1));
        try self.ids.ensureUnusedCapacity(self.gpa, 1);
        try self.strings.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.storage.allocator().dupe(u8, text);
        self.ids.putAssumeCapacityNoClobber(owned, id);
        self.strings.appendAssumeCapacity(owned);
        return id;
    }

    pub fn indexWay(self: *StringTable, way: attrs.WayAttrs, tags: anytype, options: Options, deadline: io.Deadline) !Indexed {
        try self.collect(tags, options, deadline);
        const names = way.names;
        const ref = try directed(&self.directed_ref, self.gpa, names.ref orelse "", names.direction, options, deadline);
        const int_ref = try directed(&self.directed_int_ref, self.gpa, names.int_ref orelse "", names.int_direction, options, deadline);
        const merged = try self.mergeRefs(ref, int_ref, deadline);
        const name = try self.withoutRefNames(names.name orelse "", merged, deadline);
        return .{
            .name = try self.compose(.name, name, options, deadline),
            .alt_name = if (options.allow_alt_name) try self.compose(.alt_name, names.alt_name orelse "", options, deadline) else .{},
            .official_name = try self.compose(.official_name, names.official_name orelse "", options, deadline),
            .ref = try self.compose(.ref, merged, options, deadline),
            .int_ref = try self.compose(.int_ref, int_ref, options, deadline),
            .tunnel_name = try self.compose(.tunnel_name, names.tunnel_name orelse "", options, deadline),
            .bridge_name = try self.intern(names.bridge_name orelse ""),
            .destination = try self.compose(.destination, names.destination orelse "", options, deadline),
            .destination_forward = try self.compose(.destination_forward, names.destination_forward orelse "", options, deadline),
            .destination_backward = try self.compose(.destination_backward, names.destination_backward orelse "", options, deadline),
            .destination_ref = try self.compose(.destination_ref, names.destination_ref orelse "", options, deadline),
            .destination_ref_to = try self.compose(.destination_ref_to, names.destination_ref_to orelse "", options, deadline),
            .destination_street = try self.compose(.destination_street, names.destination_street orelse "", options, deadline),
            .destination_street_to = try self.compose(.destination_street_to, names.destination_street_to orelse "", options, deadline),
            .destination_int_ref = try self.intern(names.destination_int_ref orelse ""),
            .destination_int_ref_to = try self.intern(names.destination_int_ref_to orelse ""),
            .junction_ref = try self.compose(.junction_ref, names.junction_ref orelse "", options, deadline),
            .junction_name = try self.compose(.junction_name, names.junction_name orelse "", options, deadline),
            .turn_lanes_forward = try self.intern(way.turn_lanes.forward orelse way.turn_lanes.general orelse ""),
            .turn_lanes_backward = try self.intern(way.turn_lanes.backward orelse ""),
        };
    }

    fn collect(self: *StringTable, tags: anytype, options: Options, deadline: io.Deadline) !void {
        self.localized.clearRetainingCapacity();
        var iter = input.Iterator.init(tags, deadline);
        var count: usize = 0;
        while (try iter.next()) |tag| : (count += 1) {
            if (count % 1024 == 0) try check(deadline);
            const part = localeTag(tag.key, tag.value) orelse continue;
            if (part.group == .alt_name and !options.allow_alt_name) continue;
            for (self.localized.items) |*previous| {
                try check(deadline);
                if (!std.mem.eql(u8, previous.key, part.key)) continue;
                previous.* = part;
                break;
            } else {
                try self.localized.append(self.gpa, part);
            }
        }
    }

    fn mergeRefs(self: *StringTable, ref: []const u8, int_ref: []const u8, deadline: io.Deadline) ![]const u8 {
        if (int_ref.len == 0) return ref;
        self.merged.clearRetainingCapacity();
        try self.merged.appendSlice(self.gpa, ref);
        var international = std.mem.splitScalar(u8, int_ref, ';');
        while (international.next()) |part| {
            try check(deadline);
            if (!try hasToken(ref, part, deadline)) try appendToken(&self.merged, self.gpa, part);
        }
        return self.merged.items;
    }

    fn withoutRefNames(self: *StringTable, name: []const u8, ref: []const u8, deadline: io.Deadline) ![]const u8 {
        if (name.len == 0 or ref.len == 0) return name;
        self.filtered.clearRetainingCapacity();
        var parts = std.mem.splitScalar(u8, name, ';');
        while (parts.next()) |part| {
            try check(deadline);
            if (!try hasToken(ref, part, deadline)) try appendToken(&self.filtered, self.gpa, part);
        }
        return self.filtered.items;
    }

    fn compose(self: *StringTable, group: Group, base: []const u8, options: Options, deadline: io.Deadline) !LocalizedId {
        var count: usize = 0;
        for (self.localized.items) |part| {
            try check(deadline);
            if (part.group != group or part.text.len == 0) continue;
            count += 1;
        }
        if (count == 0) return .{ .text = try self.intern(base) };

        self.name_text.clearRetainingCapacity();
        self.language_text.clearRetainingCapacity();
        const split = if (group == .name and count == 1 and std.mem.indexOfScalar(u8, base, ';') == null)
            try self.nameDelimiter(group, base, deadline)
        else
            null;
        const base_count = if (split) |separator| try self.appendSplit(base, separator, deadline) else blk: {
            try self.name_text.appendSlice(self.gpa, base);
            break :blk try countTokens(base, deadline);
        };

        if (options.use_admin_db and base_count != 0) try self.language_text.appendNTimes(self.gpa, ';', base_count);
        var first_language = true;
        for (self.localized.items) |part| {
            try check(deadline);
            if (part.group != group or part.text.len == 0) continue;
            var token_count: usize = undefined;
            if (split) |separator| {
                if (options.use_admin_db) try self.name_text.append(self.gpa, ';');
                token_count = if (options.use_admin_db) try self.appendSplit(part.text, separator, deadline) else base_count;
            } else {
                if (options.use_admin_db) try appendToken(&self.name_text, self.gpa, part.text);
                token_count = try countTokens(part.text, deadline);
            }
            for (0..token_count) |_| {
                try check(deadline);
                if (!first_language) try self.language_text.append(self.gpa, ';');
                try self.language_text.appendSlice(self.gpa, part.language);
                first_language = false;
            }
        }
        const text = try self.intern(self.name_text.items);
        const lang = try self.intern(self.language_text.items);
        return .{ .text = text, .language = lang };
    }

    fn nameDelimiter(self: *const StringTable, group: Group, base: []const u8, deadline: io.Deadline) !?[]const u8 {
        if (base.len == 0) return null;
        for (self.localized.items) |part| {
            try check(deadline);
            if (part.group != group or !std.mem.eql(u8, part.text, base)) continue;
            for ([_][]const u8{ " - ", " / " }) |delimiter| {
                if (std.mem.indexOf(u8, base, delimiter) != null) return delimiter;
            }
        }
        return null;
    }

    fn appendSplit(self: *StringTable, text: []const u8, delimiter: []const u8, deadline: io.Deadline) !usize {
        var scan = std.mem.splitSequence(u8, text, delimiter);
        var count: usize = 0;
        while (scan.next()) |part| {
            try check(deadline);
            if (part.len == 0 and scan.peek() == null) break;
            if (count != 0) try self.name_text.append(self.gpa, ';');
            try self.name_text.appendSlice(self.gpa, part);
            count += 1;
        }
        return count;
    }
};

fn check(deadline: io.Deadline) error{DeadlineExceeded}!void {
    if (deadline.expired()) return error.DeadlineExceeded;
}

fn appendToken(out: *std.ArrayList(u8), gpa: std.mem.Allocator, token: []const u8) !void {
    if (out.items.len != 0) try out.append(gpa, ';');
    try out.appendSlice(gpa, token);
}

fn hasToken(list: []const u8, token: []const u8, deadline: io.Deadline) !bool {
    var scan = std.mem.splitScalar(u8, list, ';');
    while (scan.next()) |part| {
        try check(deadline);
        if (std.mem.eql(u8, token, part)) return true;
    }
    return false;
}

fn countTokens(text: []const u8, deadline: io.Deadline) !usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text, 0..) |byte, i| {
        if (i % 1024 == 0) try check(deadline);
        count += @intFromBool(byte == ';');
    }
    return count;
}

fn directed(out: *std.ArrayList(u8), gpa: std.mem.Allocator, refs: []const u8, direction: ?[]const u8, options: Options, deadline: io.Deadline) ![]const u8 {
    const suffixes = direction orelse return refs;
    if (!options.use_direction_on_ways or refs.len == 0 or suffixes.len == 0) return refs;
    if (try countTokens(refs, deadline) != try countTokens(suffixes, deadline)) return refs;
    out.clearRetainingCapacity();
    var ref_parts = std.mem.splitScalar(u8, refs, ';');
    var dir_parts = std.mem.splitScalar(u8, suffixes, ';');
    while (ref_parts.next()) |ref| {
        try check(deadline);
        try appendToken(out, gpa, ref);
        const suffix = dir_parts.next().?;
        if (suffix.len != 0) {
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, suffix);
        }
    }
    return out.items;
}

// Ported from src/baldr/streetname_us.cc (Valhalla 3.9.3).
pub fn usBaseName(value: []const u8) []const u8 {
    const directions = [_][]const u8{ "North", "East", "South", "West", "Northeast", "Southeast", "Southwest", "Northwest" };
    var first: usize = 0;
    var last = value.len;
    inline for (directions) |word| {
        if (std.mem.startsWith(u8, value, word ++ " ")) first = word.len + 1;
        if (std.mem.endsWith(u8, value, " " ++ word)) last = value.len - word.len - 1;
    }
    // Overlapping delimiters make the unsigned length passed to C++ substr
    // extend through the end of the remaining string.
    return value[first..if (last < first) value.len else last];
}

// Ported from test/streetname_us.cc.
test "US base names preserve spelling while removing full compass directions" {
    const cases = [_][2][]const u8{
        .{ "North Main Street", "Main Street" },
        .{ "East Chestnut Avenue", "Chestnut Avenue" },
        .{ "South Main Street", "Main Street" },
        .{ "West 26th Street", "26th Street" },
        .{ "US 220 North", "US 220" },
        .{ "US 22 East", "US 22" },
        .{ "I 81 South", "I 81" },
        .{ "PA 283 West", "PA 283" },
        .{ "Constitution Avenue Northeast", "Constitution Avenue" },
        .{ "Constitution Avenue Northwest", "Constitution Avenue" },
        .{ "Independence Avenue Southeast", "Independence Avenue" },
        .{ "Independence Avenue Southwest", "Independence Avenue" },
        .{ "North South Street Northwest", "South Street" },
        .{ "East North Avenue Southwest", "North Avenue" },
        .{ "North East", "East" },
        .{ "Main Street", "Main Street" },
        .{ "Broadway", "Broadway" },
        .{ "Main St NW", "Main St NW" },
        .{ "", "" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], usBaseName(case[0]));
}
