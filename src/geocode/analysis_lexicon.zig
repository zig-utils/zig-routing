//! Language-specific equivalents for normalized geocoding tokens.
const std = @import("std");

pub const Language = enum {
    und,
    en,
    de,

    pub fn fromTag(tag: []const u8) Language {
        const base = tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len];
        if (std.ascii.eqlIgnoreCase(base, "en")) return .en;
        if (std.ascii.eqlIgnoreCase(base, "de")) return .de;
        return .und;
    }
};

pub const Kind = enum(u8) { word, house_number, postcode, street_type, direction, stop_word };
pub const Expansion = struct { text: []const u8, kind: Kind };
const Group = struct { kind: Kind, spellings: []const []const u8, preserve: bool = false };

const english = table(&.{
    .{ .kind = .street_type, .spellings = &.{ "street", "st", "str", "strt" } },
    .{ .kind = .street_type, .spellings = &.{ "avenue", "ave", "av", "aven" } },
    .{ .kind = .street_type, .spellings = &.{ "road", "rd" } },
    .{ .kind = .street_type, .spellings = &.{ "boulevard", "blvd", "boul", "bvd" } },
    .{ .kind = .street_type, .spellings = &.{ "drive", "dr", "drv" } },
    .{ .kind = .street_type, .spellings = &.{ "lane", "ln" } },
    .{ .kind = .street_type, .spellings = &.{ "court", "ct" } },
    .{ .kind = .street_type, .spellings = &.{ "place", "pl" } },
    .{ .kind = .street_type, .spellings = &.{ "square", "sq" } },
    .{ .kind = .street_type, .spellings = &.{ "terrace", "ter", "terr" } },
    .{ .kind = .street_type, .spellings = &.{ "parkway", "pkwy", "pky" } },
    .{ .kind = .street_type, .spellings = &.{ "highway", "hwy", "hiway" } },
    .{ .kind = .street_type, .spellings = &.{ "circle", "cir", "circ" } },
    .{ .kind = .street_type, .spellings = &.{ "crescent", "cres", "crs" } },
    .{ .kind = .street_type, .spellings = &.{ "alley", "aly", "ally" } },
    .{ .kind = .street_type, .spellings = &.{ "trail", "trl" } },
    .{ .kind = .street_type, .spellings = &.{ "plaza", "plz" } },
    .{ .kind = .street_type, .spellings = &.{ "center", "centre", "ctr" } },
    .{ .kind = .street_type, .spellings = &.{ "way", "wy" } },
    .{ .kind = .street_type, .spellings = &.{ "walk", "wk" } },
    .{ .kind = .street_type, .spellings = &.{ "close", "cl" } },
    .{ .kind = .street_type, .spellings = &.{ "parade", "pde" } },
    .{ .kind = .street_type, .spellings = &.{ "bridge", "brg" } },
    .{ .kind = .street_type, .spellings = &.{ "junction", "jct", "jctn" } },
    .{ .kind = .street_type, .spellings = &.{ "extension", "ext" } },
    .{ .kind = .direction, .spellings = &.{ "north", "n" } },
    .{ .kind = .direction, .spellings = &.{ "south", "s" } },
    .{ .kind = .direction, .spellings = &.{ "east", "e" } },
    .{ .kind = .direction, .spellings = &.{ "west", "w" } },
    .{ .kind = .direction, .spellings = &.{ "northeast", "ne" } },
    .{ .kind = .direction, .spellings = &.{ "northwest", "nw" } },
    .{ .kind = .direction, .spellings = &.{ "southeast", "se" } },
    .{ .kind = .direction, .spellings = &.{ "southwest", "sw" } },
    .{ .kind = .word, .spellings = &.{ "mount", "mt" } },
    .{ .kind = .word, .spellings = &.{ "fort", "ft" } },
    .{ .kind = .word, .spellings = &.{ "saint", "snt" } },
    .{ .kind = .word, .spellings = &.{ "apartment", "apt" } },
    .{ .kind = .word, .spellings = &.{ "suite", "ste" } },
    .{ .kind = .stop_word, .spellings = &.{ "a", "an", "and", "at", "by", "in", "of", "on", "the", "to" }, .preserve = true },
});

const german = table(&.{
    .{ .kind = .street_type, .spellings = &.{ "strasse", "str", "stras" } },
    .{ .kind = .street_type, .spellings = &.{ "allee", "all" } },
    .{ .kind = .street_type, .spellings = &.{ "gasse", "g" } },
    .{ .kind = .street_type, .spellings = &.{ "platz", "pl" } },
    .{ .kind = .street_type, .spellings = &.{"weg"} },
    .{ .kind = .street_type, .spellings = &.{"ring"} },
    .{ .kind = .street_type, .spellings = &.{"ufer"} },
    .{ .kind = .street_type, .spellings = &.{ "promenade", "prom" } },
    .{ .kind = .street_type, .spellings = &.{ "chaussee", "chauss" } },
    .{ .kind = .street_type, .spellings = &.{"steig"} },
    .{ .kind = .street_type, .spellings = &.{"pfad"} },
    .{ .kind = .street_type, .spellings = &.{"damm"} },
    .{ .kind = .street_type, .spellings = &.{"markt"} },
    .{ .kind = .direction, .spellings = &.{ "nord", "n" } },
    .{ .kind = .direction, .spellings = &.{ "sud", "s", "sued" } },
    .{ .kind = .direction, .spellings = &.{ "ost", "o" } },
    .{ .kind = .direction, .spellings = &.{ "west", "w" } },
    .{ .kind = .direction, .spellings = &.{ "nordost", "no" } },
    .{ .kind = .direction, .spellings = &.{ "nordwest", "nw" } },
    .{ .kind = .direction, .spellings = &.{ "sudost", "so", "suedost" } },
    .{ .kind = .direction, .spellings = &.{ "sudwest", "sw", "suedwest" } },
    .{ .kind = .word, .spellings = &.{ "sankt", "st", "skt" } },
    .{ .kind = .word, .spellings = &.{ "doktor", "dr" } },
    .{ .kind = .word, .spellings = &.{ "professor", "prof" } },
    .{ .kind = .word, .spellings = &.{ "bahnhof", "bf", "bhf" } },
    .{ .kind = .word, .spellings = &.{ "hauptbahnhof", "hbf" } },
    .{ .kind = .stop_word, .spellings = &.{ "am", "an", "auf", "aus", "bei", "das", "der", "die", "im", "in", "und", "von", "zu", "zum", "zur" }, .preserve = true },
});

fn table(comptime groups: []const Group) std.StaticStringMap(Expansion) {
    comptime var count: usize = 0;
    inline for (groups) |group| count += group.spellings.len;
    var entries: [count]struct { []const u8, Expansion } = undefined;
    var offset: usize = 0;
    for (groups) |group| {
        for (group.spellings) |spelling| {
            entries[offset] = .{ spelling, .{
                .kind = group.kind,
                .text = if (group.preserve) spelling else group.spellings[0],
            } };
            offset += 1;
        }
    }
    return std.StaticStringMap(Expansion).initComptime(entries);
}

pub fn expand(language: Language, word: []const u8, name_initial: bool) ?Expansion {
    return switch (language) {
        .und => null,
        .en => if (name_initial and std.mem.eql(u8, word, "st"))
            .{ .text = "saint", .kind = .word }
        else
            english.get(word),
        .de => german.get(word),
    };
}

pub fn compoundStreetType(language: Language, word: []const u8) ?struct { stem: []const u8, suffix: Expansion } {
    if (language != .de) return null;
    for ([_][]const u8{ "promenade", "strasse", "chaussee", "allee", "gasse", "platz", "steig", "pfad", "damm", "ufer", "ring", "str", "weg" }) |suffix| {
        if (word.len > suffix.len + 1 and std.mem.endsWith(u8, word, suffix))
            return .{ .stem = word[0 .. word.len - suffix.len], .suffix = german.get(suffix).? };
    }
    return null;
}
