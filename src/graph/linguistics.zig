// Ported from valhalla/baldr/graphconstants.h and src/baldr/edgeinfo.cc (Valhalla 3.9.3).
const std = @import("std");

pub const Language = enum(u8) {
    ab = 1,
    am,
    ar,
    az,
    be,
    bg,
    bn,
    bs,
    ca,
    ckb,
    cs,
    da,
    de,
    dv,
    dz,
    el,
    en,
    es,
    et,
    fa,
    fi,
    fr,
    fy,
    gl,
    he,
    hr,
    hu,
    hy,
    id,
    is,
    it,
    ja,
    ka,
    kl,
    km,
    ko,
    lo,
    lt,
    lv,
    mg,
    mk,
    mn,
    mo,
    mt,
    my,
    ne,
    nl,
    no,
    oc,
    pap,
    pl,
    ps,
    pt,
    rm,
    ro,
    ru,
    sk,
    sl,
    sq,
    sr,
    @"sr-Latn",
    sv,
    tg,
    th,
    tk,
    tr,
    uk,
    ur,
    uz,
    vi,
    zh,
    cy,
    ta,
    ms,
    none = 255,
    _,

    pub noinline fn fromTag(text: []const u8) Language {
        return std.meta.stringToEnum(Language, text) orelse .none;
    }

    pub fn valid(self: Language) bool {
        const code = @backingInt(self);
        return (code >= @backingInt(Language.ab) and code <= @backingInt(Language.ms)) or self == .none;
    }
};

pub const Alphabet = enum(u8) {
    ipa = 1,
    katakana = 2,
    jeita = 3,
    nt_sampa = 4,
    none = 5,
    _,

    fn valid(self: Alphabet) bool {
        const code = @backingInt(self);
        return code >= @backingInt(Alphabet.ipa) and code <= @backingInt(Alphabet.none);
    }
};

pub const Pronunciation = struct {
    alphabet: Alphabet,
    text: []const u8,
};

pub const Entry = extern struct {
    text_ref: u32 = 0,
    attr: packed struct(u32) {
        name_index: u8,
        language: Language = .none,
        alphabet: Alphabet = .none,
        reserved: u8 = 0,
    },

    pub fn valid(self: Entry, name_count: usize) bool {
        return self.attr.name_index < name_count and self.attr.language.valid() and self.attr.alphabet.valid() and
            self.attr.reserved == 0 and if (self.attr.alphabet == .none) self.text_ref == 0 else self.text_ref <= std.math.maxInt(u31);
    }

    /// The pinned reader prefers a higher-ranked alphabet for the same
    /// language and retains the first entry when the languages differ.
    pub fn replaces(self: Entry, previous: Entry) bool {
        return self.attr.alphabet != .none and self.attr.language == previous.attr.language and
            @backingInt(self.attr.alphabet) > @backingInt(previous.attr.alphabet);
    }
};

pub const Tag = enum(u8) {
    layer = 1,
    level = 4,
    level_ref = 5,
    levels = 8,
    tunnel = '1',
    bridge = '2',
    _,

    pub fn valid(self: Tag) bool {
        return switch (self) {
            .layer, .level, .level_ref, .levels, .tunnel, .bridge => true,
            else => false,
        };
    }
};

pub const Tagged = extern struct {
    text_ref: u32,
    attr: packed struct(u32) {
        kind: Tag,
        reserved: u24 = 0,
    },

    pub fn valid(self: Tagged) bool {
        return self.attr.kind.valid() and self.attr.reserved == 0 and self.text_ref <= std.math.maxInt(u31);
    }
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Entry) == 8 and @offsetOf(Entry, "text_ref") == 0 and @offsetOf(Entry, "attr") == 4);
    std.debug.assert(@sizeOf(Tagged) == 8 and @offsetOf(Tagged, "text_ref") == 0 and @offsetOf(Tagged, "attr") == 4);
    std.debug.assert(@backingInt(Language.ms) == 74);
}

test "pinned language, alphabet and tagged value identifiers" {
    const testing = std.testing;
    try testing.expectEqual(Language.fr, Language.fromTag("fr"));
    try testing.expectEqual(Language.@"sr-Latn", Language.fromTag("sr-Latn"));
    try testing.expectEqual(Language.none, Language.fromTag("unknown"));
    try testing.expectEqual(61, @backingInt(Language.@"sr-Latn"));
    try testing.expectEqual(4, @backingInt(Alphabet.nt_sampa));
    try testing.expectEqual('1', @backingInt(Tag.tunnel));
    try testing.expectEqual('2', @backingInt(Tag.bridge));
    const ipa: Entry = .{ .text_ref = 2, .attr = .{ .name_index = 254, .language = .fr, .alphabet = .ipa } };
    const sampa: Entry = .{ .text_ref = 3, .attr = .{ .name_index = 254, .language = .fr, .alphabet = .nt_sampa } };
    try testing.expect(ipa.valid(255) and !ipa.valid(254));
    try testing.expect(sampa.replaces(ipa) and !ipa.replaces(sampa));
    var different = sampa;
    different.attr.language = .nl;
    try testing.expect(!different.replaces(ipa));
}
