// Ported from src/odin/narrative_dictionary.cc and src/odin/util.cc (Valhalla 3.9.3).
const std = @import("std");
const catalog = @import("locale_catalog");
const data = @import("locale_data");
pub const types = @import("dictionary_types");
pub const NarrativeDictionary = types.NarrativeDictionary;
pub const canonical_tags = catalog.canonical;

// Lookup uses the same case-sensitive tags and aliases as Valhalla's locale map.
fn index(tag: []const u8) ?u8 {
    if (tag.len > 5) {
        for (catalog.long) |entry| if (std.mem.eql(u8, entry.name, tag)) return entry.index;
        return null;
    }
    const key = types.shortTagKey(tag);
    var low: usize = 0;
    var high = catalog.short.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = catalog.short[middle];
        const code = record >> 8;
        if (code == key) return @truncate(record);
        if (code < key) low = middle + 1 else high = middle;
    }
    return null;
}

pub fn isSupported(tag: []const u8) bool {
    return index(tag) != null;
}

pub fn lookup(tag: []const u8) ?*const NarrativeDictionary {
    return &data.all[index(tag) orelse return null];
}

/// The caller may use this before any allocation or server initialization.
pub fn forLanguage(tag: []const u8) *const NarrativeDictionary {
    return &data.all[index(tag) orelse catalog.default];
}

test "all compiled languages have every English phrase ID" {
    const english = forLanguage("en-US");
    try std.testing.expectEqual(@as(usize, 36), data.all.len);
    for (&data.all, canonical_tags, 0..) |*current, tag, i| {
        try std.testing.expectEqualStrings(tag, current.language_tag);
        try std.testing.expect(lookup(tag) == &data.all[i]);
        var count: usize = 0;
        inline for (@typeInfo(NarrativeDictionary).@"struct".field_names[2..]) |name| {
            const reference = @field(english, name).phrases;
            const translated = @field(current, name).phrases;
            try std.testing.expectEqual(reference.entries.len, translated.entries.len);
            for (reference.entries) |phrase| {
                try std.testing.expect(translated.get(phrase.id) != null);
                count += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 345), count);
    }
}

test "first locale selection borrows compiled tables without an allocator" {
    try std.testing.expect(forLanguage("en") == forLanguage("en-US"));
    try std.testing.expect(forLanguage("au") == forLanguage("en-AU"));
    try std.testing.expect(forLanguage("pt") == forLanguage("pt-PT"));
    try std.testing.expect(forLanguage("pt-BR") != forLanguage("pt-PT"));
    try std.testing.expect(forLanguage("en-x-pirate") == forLanguage("en-US-x-pirate"));
    try std.testing.expect(lookup("EN-us") == null);
    try std.testing.expect(forLanguage("zh-TW") == forLanguage("en-US"));
    const english = forLanguage("en");
    try std.testing.expectEqualStrings("en_US.UTF-8", english.posix_locale);
    try std.testing.expectEqualStrings("north", english.start_subset.cardinal_directions[0]);
    try std.testing.expectEqualStrings("<KILOMETERS> kilometers", english.start_verbal_subset.metric_lengths[0]);
    try std.testing.expectEqualStrings("Head <CARDINAL_DIRECTION>.", english.start_subset.phrases.get(0).?);
    try std.testing.expectEqualStrings("stops", english.transit_subset.transit_stop_count_labels.get(.other).?);
    try std.testing.expect(english.start_subset.phrases.get(3) == null);
}

test "Valhalla English dictionary subset snapshots" {
    const fixtures = @import("instruction_fixtures.zig");
    const snapshot = @import("reference_snapshot.zig");
    try std.testing.expectEqual(57, fixtures.pinned_dictionary_count);
    try fixtures.compareDictionary(forLanguage("en-US"), snapshot);
}
