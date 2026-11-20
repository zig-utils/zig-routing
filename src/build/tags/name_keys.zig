// Ported from src/mjolnir/pbfgraphparser.cc (Valhalla 3.9.3).
const std = @import("std");
const linguistics = @import("../../graph/linguistics.zig");
const Language = linguistics.Language;

pub const Tag = struct { key: Key, text: []const u8 };

pub const Group = enum(u4) { name, ref, int_ref, alt_name, official_name, tunnel, bridge, level, level_ref, _ };
pub const Side = enum(u3) { both, left, right, forward, backward, _ };

const groups = std.StaticStringMap(Group).initComptime(.{
    .{ "tunnel", .tunnel },
    .{ "bridge", .bridge },
    .{ "name", .name },
    .{ "ref", .ref },
    .{ "int_ref", .int_ref },
    .{ "alt_name", .alt_name },
    .{ "official_name", .official_name },
    .{ "level", .level },
});
const alphabets = std.StaticStringMap(linguistics.Alphabet).initComptime(.{
    .{ "ipa", .ipa },
    .{ "katakana", .katakana },
    .{ "jeita", .jeita },
    .{ "nt-sampa", .nt_sampa },
});

pub const Key = packed struct(u32) {
    group: Group,
    side: Side = .both,
    language: linguistics.Language = .none,
    alphabet: linguistics.Alphabet = .none,
    reserved: u9 = 0,

    pub fn valid(self: Key) bool {
        return @backingInt(self.group) <= @backingInt(Group.level_ref) and
            @backingInt(self.side) <= @backingInt(Side.backward) and self.language.valid() and
            @backingInt(self.alphabet) >= @backingInt(linguistics.Alphabet.ipa) and
            @backingInt(self.alphabet) <= @backingInt(linguistics.Alphabet.none) and self.reserved == 0;
    }

    pub fn needsDetails(self: Key) bool {
        return self.side != .both or self.language != .none or self.alphabet != .none or
            @backingInt(self.group) >= @backingInt(Group.tunnel);
    }
};

pub noinline fn parseKey(text: []const u8) ?Key {
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, ":"), ':');
    const base = groups.get(parts.first()) orelse return null;
    var key: Key = .{ .group = base };
    switch (base) {
        .bridge, .tunnel => {
            if (!std.mem.eql(u8, suffix(&parts) orelse return null, "name")) return null;
            if (base == .bridge) return if (suffix(&parts) == null) key else null;
        },
        .level => {
            const qualifier = suffix(&parts) orelse return key;
            return if (std.mem.eql(u8, qualifier, "ref") and suffix(&parts) == null) .{ .group = .level_ref } else null;
        },
        else => {},
    }
    while (suffix(&parts)) |part| {
        if (std.mem.eql(u8, part, "pronunciation") and key.alphabet == .none) {
            key.alphabet = .ipa;
            if (suffix(&parts)) |notation| key.alphabet = alphabets.get(notation) orelse return null;
            if (suffix(&parts) != null) return null;
        } else if (std.meta.stringToEnum(Side, part)) |side| {
            if (key.side != .both or side == .both or (base != .name and (side == .forward or side == .backward))) return null;
            key.side = side;
        } else {
            const tag = if (std.mem.eql(u8, part, "lang")) suffix(&parts) orelse return null else part;
            const language = Language.fromTag(tag);
            if (language == .none or key.language != .none) return null;
            key.language = language;
        }
    }
    return key;
}

// Common tags need only the prefix. Keep the byte scan for each optional
// qualifier in one parser so the rare suffix paths share it.
noinline fn suffix(parts: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    return parts.next();
}
