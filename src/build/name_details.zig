// Ported from src/mjolnir/pbfgraphparser.cc and src/mjolnir/osmway.cc (Valhalla 3.9.3).
const std = @import("std");
const checkpoint = @import("checkpoint.zig");
const io = @import("../infra/io.zig");
const linguistics = @import("../graph/linguistics.zig");
const names = @import("tags/names.zig");
const admin = @import("../graph/admin.zig");
const cold = @import("../graph/cold.zig");
const ColdBuilder = @import("cold_builder.zig").Builder;
const Language = linguistics.Language;
const language_slots = @backingInt(Language.ms) + 1;
const LanguageMask = std.StaticBitSet(language_slots);

fn languageSlot(language: Language) usize {
    return if (language == .none) 0 else @backingInt(language);
}

const keys = @import("tags/name_keys.zig");
pub const Group = keys.Group;
const Side = keys.Side;
const Key = keys.Key;
pub const parseKey = keys.parseKey;

pub const Row = extern struct {
    text: names.Id,
    key: Key,
};

comptime {
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(Row) == 8 and @offsetOf(Row, "text") == 0 and @offsetOf(Row, "key") == 4);
}

pub const Range = extern struct { first: u32 = 0, end: u32 = 0 };
comptime {
    std.debug.assert(@sizeOf(Range) == 8 and @offsetOf(Range, "first") == 0 and @offsetOf(Range, "end") == 4);
}

// Valhalla's kSupportedLanguages from valhalla/mjolnir/adminconstants.h.
const SupportedLanguage = struct { level: u8, tags: []const u8 };
const supported_languages = std.StaticStringMap(SupportedLanguage).initComptime([_]struct { []const u8, SupportedLanguage }{
    .{ "Cymru / Wales", .{ .level = 0, .tags = "cy;en" } },
    .{ "United Kingdom", .{ .level = 2, .tags = "en" } },
    .{ "Ireland", .{ .level = 4, .tags = "ga" } },
    .{ "Northern Ireland / Tuaisceart Éireann", .{ .level = 4, .tags = "ga" } },
    .{ "Japan", .{ .level = 2, .tags = "ja;en" } },
    .{ "Canada", .{ .level = 2, .tags = "en;fr" } },
    .{ "Belarus", .{ .level = 2, .tags = "ru;be" } },
    .{ "Singapore", .{ .level = 2, .tags = "en;zh;ms;ta" } },
    .{ "Saudi Arabia", .{ .level = 2, .tags = "ar;en" } },
    .{ "Catalonia", .{ .level = 4, .tags = "ca" } },
    .{ "Valencian Community", .{ .level = 4, .tags = "ca" } },
    .{ "Spain", .{ .level = 2, .tags = "es" } },
});

pub const Languages = struct {
    order: [@backingInt(Language.ms)]Language = undefined,
    len: usize = 0,
    defaults: LanguageMask = .empty,

    pub noinline fn fromAreas(index: *const admin.View, areas: []const admin.Id, deadline: io.Deadline) !Languages {
        var result: Languages = .{};
        for (areas, 0..) |id, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const region = (try index.region(id)) orelse return error.InvalidAdminIndex;
            try result.append(try index.text(region.default_language), true, deadline);
            const supported = supported_languages.get(try index.text(region.name)) orelse
                supported_languages.get(try index.text(region.english_name)) orelse continue;
            if (supported.level == region.attr.level or (supported.level == 0 and
                (region.attr.level == 2 or region.attr.level == 4))) try result.append(supported.tags, false, deadline);
        }
        return result;
    }

    fn append(self: *Languages, text: []const u8, is_default: bool, deadline: io.Deadline) !void {
        const separator: []const u8 = if (std.mem.indexOf(u8, text, " - ") != null) " - " else ";";
        var parts = std.mem.splitSequence(u8, text, separator);
        while (parts.next()) |part| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const language = Language.fromTag(part);
            if (language == .none) continue;
            if (std.mem.indexOfScalar(Language, self.items(), language) != null) {
                if (is_default) self.defaults.unset(languageSlot(language));
                continue;
            }
            self.order[self.len] = language;
            self.len += 1;
            if (is_default) self.defaults.set(languageSlot(language));
        }
    }

    pub fn items(self: *const Languages) []const Language {
        return self.order[0..self.len];
    }
};

pub const Catalog = struct {
    a: std.mem.Allocator,
    deadline: io.Deadline,
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(self: *Catalog) void {
        self.rows.deinit(self.a);
    }

    pub noinline fn addWay(self: *Catalog, strings: *names.StringTable, indexed: *const names.Indexed) !Range {
        if (indexed.detail_tags.len == 0) return .{};
        const directional_names = for (indexed.detail_tags, 0..) |row, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (row.key.side != .both and row.key.alphabet == .none and
                (row.key.group == .name or row.key.group == .alt_name or row.key.group == .official_name)) break true;
        } else false;
        const duplicate_alt = !directional_names and indexed.alt_name.text == indexed.name.text;
        const duplicate_official = !directional_names and
            (indexed.official_name.text == indexed.name.text or indexed.official_name.text == indexed.alt_name.text);
        const first = self.rows.items.len;
        errdefer self.rows.shrinkRetainingCapacity(first);
        for (indexed.detail_tags, 0..) |row, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if ((row.key.group == .alt_name and duplicate_alt) or
                (row.key.group == .official_name and duplicate_official)) continue;
            try self.rows.append(self.a, .{ .text = try strings.intern(row.text), .key = row.key });
        }
        for ([_]Group{ .name, .ref }, [_][]const u8{ indexed.base_name, indexed.base_ref }) |group, value| {
            if (value.len != 0) try self.rows.append(self.a, .{
                .text = try strings.intern(value),
                .key = .{ .group = group },
            });
        }
        return .{
            .first = std.math.cast(u32, first) orelse return error.TooManyNameTags,
            .end = std.math.cast(u32, self.rows.items.len) orelse return error.TooManyNameTags,
        };
    }

    pub fn tags(self: *const Catalog, range: Range) []const Row {
        return self.rows.items[range.first..range.end];
    }

    pub fn save(self: *const Catalog, tx: *checkpoint.Transaction) !void {
        if (self.rows.items.len != 0) try tx.writeArray(self.rows.items, .way_name_details);
    }

    pub fn load(self: *Catalog, saved: *const checkpoint.Existing, strings: *const names.StringTable) !void {
        if (saved.manifest.files.get(.way_name_details) == null) return;
        const mapping = try saved.map(.way_name_details, self.deadline);
        defer mapping.unmap();
        const rows = try checkpoint.array(Row, mapping);
        for (rows, 0..) |row, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (!row.key.valid() or row.text == .empty or strings.get(row.text) == null) return error.InvalidCheckpoint;
        }
        try self.rows.appendSlice(self.a, rows);
    }
};

pub const Token = struct {
    text: []const u8,
    language: Language = .none,
};

/// Reuses the temporary vectors for Valhalla's name and phoneme ordering.
pub const Selector = struct {
    a: std.mem.Allocator,
    deadline: io.Deadline,
    base: std.ArrayList(Token) = .empty,
    localized: std.ArrayList(Token) = .empty,
    unlabeled: std.ArrayList(Token) = .empty,
    multilingual: std.ArrayList(Token) = .empty,
    matching: std.ArrayList(Token) = .empty,
    supported: std.ArrayList(Token) = .empty,

    pub fn deinit(self: *Selector) void {
        inline for (.{ &self.base, &self.localized, &self.unlabeled, &self.multilingual, &self.matching, &self.supported }) |list|
            list.deinit(self.a);
    }

    pub const Options = struct {
        distinct_side: bool = false,
        allow_empty: bool = false,
    };

    pub noinline fn select(self: *Selector, rows: []const Row, key: Key, strings: *const names.StringTable, languages: *const Languages, options: Options, out: *std.ArrayList(Token)) !void {
        inline for (.{ &self.base, &self.localized, &self.unlabeled, &self.multilingual, &self.matching, &self.supported, out }) |list|
            list.clearRetainingCapacity();
        var values: [language_slots]?[]const u8 = @splat(null);
        var inherited: [language_slots]?[]const u8 = @splat(null);
        var has_languages = false;
        for (rows, 0..) |row, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (row.key.group != key.group or row.key.alphabet != key.alphabet) continue;
            const table = if (row.key.side == key.side) &values else if (key.side != .both and
                row.key.side == .both and row.key.language != .none) &inherited else continue;
            table[languageSlot(row.key.language)] = strings.get(row.text) orelse return error.InvalidStringId;
            has_languages = has_languages or row.key.language != .none;
        }
        const base_value = values[0] orelse "";
        try self.split(&self.base, base_value, ";", .none, options.allow_empty);
        for (languages.items()) |language| {
            if (values[languageSlot(language)]) |value| try self.split(&self.localized, value, ";", language, options.allow_empty);
            if (base_value.len != 0) {
                if (inherited[languageSlot(language)]) |value| try self.split(&self.localized, value, ";", language, options.allow_empty);
            }
        }
        if (self.localized.items.len == 0) {
            // With a single default language, an ordinary name inherits it.
            // Multiple defaults need an authored language list to disambiguate.
            if (languages.len != 0 and languages.defaults.count() == languages.len and
                (languages.len == 1 or has_languages))
            {
                for (self.base.items, 0..) |*token, i| {
                    if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
                    token.language = languages.order[0];
                }
            }
            try out.appendSlice(self.a, self.base.items);
            return;
        }

        var ranks: [language_slots]u8 = @splat(255);
        ranks[0] = 0;
        var next_rank: u8 = 1;
        for (self.base.items) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (multilingualDelimiter(token.text)) |separator| {
                try self.split(&self.multilingual, token.text, separator, .none, false);
                if (!options.distinct_side) try self.split(&self.unlabeled, token.text, separator, .none, false);
            } else if (try self.find(self.localized.items, token.text)) |found| {
                if (ranks[languageSlot(found.language)] == 255) {
                    ranks[languageSlot(found.language)] = next_rank;
                    next_rank += 1;
                }
            } else {
                try self.unlabeled.append(self.a, token);
            }
        }
        var missing: LanguageMask = .empty;
        for (languages.items()) |language| {
            missing.set(languageSlot(language));
            if (ranks[languageSlot(language)] == 255) {
                ranks[languageSlot(language)] = next_rank;
                next_rank += 1;
            }
        }
        for (self.localized.items) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            missing.unset(languageSlot(token.language));
            if (try self.find(self.multilingual.items, token.text) != null) {
                try self.matching.append(self.a, token);
            } else {
                try self.supported.append(self.a, token);
            }
        }
        if (!options.distinct_side and self.matching.items.len != 0) {
            var retained: usize = 0;
            for (self.unlabeled.items) |token| {
                if (self.deadline.expired()) return error.DeadlineExceeded;
                if (try self.find(self.matching.items, token.text) != null) continue;
                self.unlabeled.items[retained] = token;
                retained += 1;
            }
            self.unlabeled.shrinkRetainingCapacity(retained);
        }
        var missing_iter = missing.iterator(.{});
        const inferred: Language = if (missing.count() == 1) @fromBackingInt(@intCast(missing_iter.next().?)) else .none;
        if (self.matching.items.len != 0) {
            if (!options.distinct_side and inferred != .none and self.unlabeled.items.len != 0) {
                try self.appendLanguage(out, self.unlabeled.items, inferred);
                try out.appendSlice(self.a, self.matching.items);
                try self.sort(out.items, &ranks);
            } else try out.appendSlice(self.a, self.matching.items);
        }
        if (self.supported.items.len != 0) {
            const start = out.items.len;
            try self.appendLanguage(out, self.unlabeled.items, inferred);
            try out.appendSlice(self.a, self.supported.items);
            if (inferred == .none or self.unlabeled.items.len == 0) try self.sort(out.items[start..], &ranks);
        }
    }

    fn split(self: *Selector, out: *std.ArrayList(Token), text: []const u8, separator: []const u8, language: Language, allow_empty: bool) !void {
        if (text.len == 0) return;
        var iterator = std.mem.splitSequence(u8, text, separator);
        while (iterator.next()) |value| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            if (value.len == 0 and !allow_empty) continue;
            try out.append(self.a, .{ .text = value, .language = language });
        }
    }

    fn find(self: *const Selector, tokens: []const Token, text: []const u8) !?Token {
        for (tokens, 0..) |token, i| {
            if (i % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
            if (std.mem.eql(u8, token.text, text)) return token;
        }
        return null;
    }

    fn appendLanguage(self: *Selector, out: *std.ArrayList(Token), tokens: []const Token, language: Language) !void {
        for (tokens) |token| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            try out.append(self.a, .{ .text = token.text, .language = language });
        }
    }

    fn sort(self: *const Selector, tokens: []Token, ranks: *const [language_slots]u8) !void {
        for (1..@max(1, tokens.len)) |i| {
            if (self.deadline.expired()) return error.DeadlineExceeded;
            const token = tokens[i];
            const rank = ranks[languageSlot(token.language)];
            var at = i;
            while (at != 0 and ranks[languageSlot(tokens[at - 1].language)] > rank) : (at -= 1) {
                if (at % 256 == 0 and self.deadline.expired()) return error.DeadlineExceeded;
                tokens[at] = tokens[at - 1];
            }
            tokens[at] = token;
        }
    }
};

fn multilingualDelimiter(text: []const u8) ?[]const u8 {
    for ([_][]const u8{ " - ", " / " }) |separator| {
        const index = std.mem.indexOf(u8, text, separator) orelse continue;
        if (index + separator.len < text.len) return separator;
    }
    return null;
}

pub const Resolved = struct {
    refs: std.ArrayList(u32) = .empty,
    tagged: std.ArrayList(linguistics.Tagged) = .empty,
    linguistic: std.ArrayList(linguistics.Entry) = .empty,

    fn clear(self: *Resolved) void {
        self.refs.clearRetainingCapacity();
        self.tagged.clearRetainingCapacity();
        self.linguistic.clearRetainingCapacity();
    }

    fn count(self: Resolved) usize {
        return self.refs.items.len + self.tagged.items.len;
    }

    pub fn details(self: Resolved) cold.NameDetails {
        return .{ .linguistic = self.linguistic.items, .tagged = self.tagged.items };
    }

    pub fn detailsEqual(self: Resolved, other: Resolved) bool {
        return std.mem.eql(u8, std.mem.sliceAsBytes(self.tagged.items), std.mem.sliceAsBytes(other.tagged.items)) and
            std.mem.eql(u8, std.mem.sliceAsBytes(self.linguistic.items), std.mem.sliceAsBytes(other.linguistic.items));
    }
};

/// The two directions share the cold string table and use independent name
/// indices. Temporary token lists are reused for each edge and group.
pub const Builder = struct {
    selector: Selector,
    sides: [2]Resolved = @splat(.{}),
    names: std.ArrayList(Token) = .empty,
    phonemes: std.ArrayList(Token) = .empty,
    areas: std.ArrayList(admin.Id) = .empty,
    levels: std.ArrayList(cold.LevelRange) = .empty,
    level_bytes: std.ArrayList(u8) = .empty,
    level_value: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Builder) void {
        const a = self.selector.a;
        self.selector.deinit();
        self.names.deinit(a);
        self.phonemes.deinit(a);
        self.areas.deinit(a);
        self.levels.deinit(a);
        self.level_bytes.deinit(a);
        self.level_value.deinit(a);
        for (&self.sides) |*side| {
            side.refs.deinit(a);
            side.tagged.deinit(a);
            side.linguistic.deinit(a);
        }
    }

    pub const Input = struct {
        rows: []const Row,
        legacy: []const u32,
        indoor: cold.Indoor,
        ref_first: bool,
        forward: bool,
        point: cold_point.PointLL,
    };

    const cold_point = @import("../geo/point.zig");
    const Sides = [@backingInt(Group.level_ref) + 1]Side;

    pub noinline fn resolve(self: *Builder, table: *ColdBuilder, strings: *names.StringTable, country_index: ?*const admin.View, input_names: *const Input) !void {
        const deadline = self.selector.deadline;
        const output = &self.sides[@intFromBool(!input_names.forward)];
        output.clear();
        var languages: Languages = .{};
        if (country_index) |index| {
            try index.languageAreas(input_names.point, &self.areas, self.selector.a, deadline);
            languages = try Languages.fromAreas(index, self.areas.items, deadline);
        }
        var altered = false;
        var present: u16 = 0;
        var sides: Sides = @splat(.both);
        const side: Side = if (input_names.forward) .right else .left;
        const orientation: Side = if (input_names.forward) .forward else .backward;
        for (input_names.rows, 0..) |row, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const key = row.key;
            const group = @backingInt(key.group);
            present |= @as(u16, 1) << group;
            altered = altered or (group < @backingInt(Group.tunnel) and key.needsDetails());
            if (key.language != .none or key.alphabet != .none) continue;
            if (key.side == side or (key.side == orientation and sides[group] == .both)) sides[group] = key.side;
        }
        // Valhalla selects a shared pronunciation variant. A sided ref or
        // tunnel can take precedence over a forward or backward street name.
        var phoneme_side: Side = .both;
        for ([_]Group{ .tunnel, .ref, .alt_name, .official_name, .name }) |group| {
            const selected = sides[@backingInt(group)];
            if (selected == .both) continue;
            phoneme_side = selected;
            break;
        }
        if (altered) {
            const reference_order: []const Group = if (input_names.ref_first)
                &.{ .ref, .int_ref, .name, .alt_name, .official_name }
            else
                &.{ .name, .ref, .int_ref, .alt_name, .official_name };
            for (reference_order) |group| {
                if (!hasGroup(present, group)) continue;
                try self.resolveGroup(output, table, strings, input_names.rows, &languages, group, sides[@backingInt(group)], phoneme_side, null);
            }
        } else {
            try output.refs.appendSlice(self.selector.a, input_names.legacy);
            if (languages.len == 1 and languages.defaults.isSet(languageSlot(languages.order[0]))) {
                for (0..input_names.legacy.len) |i| {
                    try self.addLinguistic(output, i, languages.order[0], .none, 0);
                }
            }
        }
        if (hasGroup(present, .tunnel))
            try self.resolveGroup(output, table, strings, input_names.rows, &languages, .tunnel, sides[@backingInt(Group.tunnel)], phoneme_side, .tunnel);
        if (hasGroup(present, .bridge))
            try self.resolveGroup(output, table, strings, input_names.rows, &languages, .bridge, .both, .both, .bridge);
        if (input_names.indoor.layer != 0 and output.count() < cold.max_names) {
            const bytes = [_]u8{@bitCast(input_names.indoor.layer)};
            try self.addTagged(output, table, strings, &bytes, .layer);
        }
        if (input_names.indoor.levels.len != 0 and output.count() < cold.max_names) {
            try self.addLevels(output, table, strings, input_names);
        }
        if (hasGroup(present, .level_ref))
            try self.resolveGroup(output, table, strings, input_names.rows, &languages, .level_ref, .both, .both, .level_ref);
        std.sort.insertion(linguistics.Entry, output.linguistic.items, {}, beforeName);
    }

    noinline fn resolveGroup(self: *Builder, output: *Resolved, table: *ColdBuilder, strings: *names.StringTable, rows: []const Row, languages: *const Languages, group: Group, side: Side, phoneme_side: Side, tag: ?linguistics.Tag) !void {
        const start = output.count();
        if (start == cold.max_names) return;
        const key: Key = .{ .group = group, .side = side };
        const distinct_side = phoneme_side != .both;
        try self.selector.select(rows, key, strings, languages, .{ .distinct_side = distinct_side }, &self.names);
        const written = self.names.items[0..@min(self.names.items.len, cold.max_names - start)];
        for (written) |token| {
            if (tag) |kind| {
                try self.addTagged(output, table, strings, token.text, kind);
            } else {
                const route = group == .ref or group == .int_ref;
                const reference = try table.nameRef(try strings.intern(token.text), route);
                try output.refs.append(self.selector.a, reference);
            }
        }
        if (written.len == 0 or group == .bridge or group == .level_ref) return;
        const positional = for (written) |token| {
            if (token.language != .none) break false;
        } else true;
        var has_pronunciation: [cold.max_names]bool = @splat(false);
        pronunciations: for ([_]linguistics.Alphabet{ .ipa, .nt_sampa, .katakana, .jeita }) |alphabet| {
            var pron_key = key;
            pron_key.side = phoneme_side;
            pron_key.alphabet = alphabet;
            try self.selector.select(rows, pron_key, strings, languages, .{
                .distinct_side = distinct_side,
                .allow_empty = true,
            }, &self.phonemes);
            if (self.phonemes.items.len == 0) continue;
            if (positional and self.phonemes.items.len > written.len) {
                for (self.phonemes.items) |candidate| {
                    if (self.selector.deadline.expired()) return error.DeadlineExceeded;
                    if (candidate.language != .none) continue :pronunciations;
                }
            }
            try self.appendPhonemes(output, table, strings, written, start, alphabet, positional, &has_pronunciation);
        }
        for (written, 0..) |token, i| {
            if (!has_pronunciation[i] and token.language != .none)
                try self.addLinguistic(output, start + i, token.language, .none, 0);
        }
    }

    fn appendPhonemes(self: *Builder, output: *Resolved, table: *ColdBuilder, strings: *names.StringTable, written: []const Token, start: usize, alphabet: linguistics.Alphabet, positional: bool, has_pronunciation: *[cold.max_names]bool) !void {
        var used: [cold.max_names]bool = @splat(false);
        const candidates = self.phonemes.items[0..@min(self.phonemes.items.len, cold.max_names)];
        for (written, 0..) |token, i| {
            if (self.selector.deadline.expired()) return error.DeadlineExceeded;
            const match = if (positional)
                (if (i < candidates.len) i else continue)
            else blk: {
                for (candidates, 0..) |candidate, j| {
                    if (!used[j] and token.language == candidate.language) break :blk j;
                }
                continue;
            };
            used[match] = true;
            const pronunciation = candidates[match];
            if (pronunciation.text.len == 0 and pronunciation.language == .none) continue;
            const notation: linguistics.Alphabet = if (pronunciation.text.len == 0) .none else alphabet;
            const text_ref = if (notation == .none) 0 else try table.nameRef(try strings.intern(pronunciation.text), false);
            try self.addLinguistic(output, start + i, pronunciation.language, notation, text_ref);
            has_pronunciation[i] = true;
        }
    }

    fn addLinguistic(self: *Builder, output: *Resolved, index: usize, language: Language, alphabet: linguistics.Alphabet, text_ref: u32) !void {
        try output.linguistic.append(self.selector.a, .{
            .text_ref = text_ref,
            .attr = .{ .name_index = @intCast(index), .language = language, .alphabet = alphabet },
        });
    }

    fn addTagged(self: *Builder, output: *Resolved, table: *ColdBuilder, strings: *names.StringTable, text: []const u8, kind: linguistics.Tag) !void {
        const text_ref = try table.nameRef(try strings.intern(text), false);
        try output.tagged.append(self.selector.a, .{ .text_ref = text_ref, .attr = .{ .kind = kind } });
    }

    noinline fn addLevels(self: *Builder, output: *Resolved, table: *ColdBuilder, strings: *names.StringTable, input_names: *const Input) !void {
        const a = self.selector.a;
        const deadline = self.selector.deadline;
        const precision: u6 = blk: {
            for (input_names.rows, 0..) |row, i| {
                if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
                if (row.key.group != .level) continue;
                break :blk try levelPrecision(strings.get(row.text) orelse return error.InvalidStringId, deadline);
            }
            break :blk 0;
        };
        const power = decimal_powers[precision];
        try self.levels.resize(a, input_names.indoor.levels.len);
        for (input_names.indoor.levels, self.levels.items, 0..) |range, *copy, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            copy.* = range;
        }
        std.sort.heap(cold.LevelRange, self.levels.items, {}, beforeLevel);
        self.level_bytes.clearRetainingCapacity();
        try appendLevel(&self.level_bytes, a, precision);
        var emitted = false;
        for (self.levels.items, 0..) |range, i| {
            if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
            const first = scaledLevel(range.bounds.first, power) orelse continue;
            const last = scaledLevel(range.bounds.last, power) orelse continue;
            if (emitted) try appendLevel(&self.level_bytes, a, 1048575);
            try appendLevel(&self.level_bytes, a, first);
            if (first != last) try appendLevel(&self.level_bytes, a, last);
            emitted = true;
        }
        if (!emitted) return;
        self.level_value.clearRetainingCapacity();
        const size = std.math.cast(i32, self.level_bytes.items.len) orelse return error.TooManyLevels;
        try appendLevel(&self.level_value, a, size);
        try self.level_value.appendSlice(a, self.level_bytes.items);
        try self.addTagged(output, table, strings, self.level_value.items, .levels);
    }
};

fn hasGroup(present: u16, group: Group) bool {
    return present & (@as(u16, 1) << @backingInt(group)) != 0;
}

fn beforeName(_: void, a: linguistics.Entry, b: linguistics.Entry) bool {
    return a.attr.name_index < b.attr.name_index;
}

// Beyond exponent 54, even the smallest nonzero f32 exceeds i32 once
// scaled. The pinned encoder computes the scale in double precision.
const decimal_powers = powers: {
    var values: [55]f64 = undefined;
    values[0] = 1;
    for (1..values.len) |i| values[i] = values[i - 1] * 10;
    break :powers values;
};

fn levelPrecision(text: []const u8, deadline: io.Deadline) !u6 {
    var longest: u6 = 0;
    var decimals = false;
    var previous_digit = false;
    var count: u6 = 0;
    for (text, 0..) |byte, i| {
        if (i % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        const digit = std.ascii.isDigit(byte);
        if (decimals and digit) {
            count = @min(decimal_powers.len - 1, count + 1);
            longest = @max(longest, count);
        } else {
            decimals = byte == '.' and previous_digit;
            count = 0;
        }
        previous_digit = digit;
    }
    return longest;
}

fn beforeLevel(_: void, a: cold.LevelRange, b: cold.LevelRange) bool {
    return a.bounds.first < b.bounds.first;
}

fn scaledLevel(value: f32, power: f64) ?i32 {
    const number: f32 = @floatCast(@as(f64, value) * power);
    if (!(number >= -2147483648 and number < 2147483648)) return null;
    return @intFromFloat(number);
}

test "level precision follows fractional digits after an integer" {
    try std.testing.expectEqual(1, try levelPrecision("0-2;3.5;.05", .none));
    try std.testing.expectEqual(10, try levelPrecision("0.0000000001", .none));
    try std.testing.expectEqual(1, scaledLevel(0.0000000001, decimal_powers[10]));
}

fn appendLevel(out: *std.ArrayList(u8), a: std.mem.Allocator, level: i32) !void {
    var value = (@as(u32, @bitCast(level)) << 1) ^ @as(u32, @bitCast(level >> 31));
    while (value > 127) : (value >>= 7) {
        try out.append(a, 128 | @as(u8, @as(u7, @truncate(value))));
    }
    try out.append(a, @intCast(value));
}

test "name tags carry their directional spelling, language and phoneme alphabet" {
    const testing = std.testing;
    try testing.expectEqual(Key{ .group = .name, .side = .left, .language = .fr, .alphabet = .ipa }, parseKey("name:left:fr:pronunciation").?);
    try testing.expectEqual(Key{ .group = .name, .side = .forward, .language = .ja, .alphabet = .katakana }, parseKey("name:forward:ja:pronunciation:katakana").?);
    try testing.expectEqual(Key{ .group = .ref, .side = .right, .alphabet = .nt_sampa }, parseKey("ref:right:pronunciation:nt-sampa").?);
    try testing.expectEqual(Key{ .group = .tunnel, .language = .@"sr-Latn" }, parseKey("tunnel:name:sr-Latn").?);
    try testing.expectEqual(Key{ .group = .name, .language = .fr }, parseKey("name:lang:fr:").?);
    try testing.expectEqual(Key{ .group = .level_ref }, parseKey("level:ref").?);
    try testing.expectEqual(null, parseKey("destination:pronunciation"));
    try testing.expectEqual(null, parseKey("name:invalid:pronunciation"));
    try testing.expectEqual(null, parseKey("name:forward:backward"));
}

// Ported from test/gurka/test_phonemes_w_langs.cc, MultiPhonemes.
test "supported languages keep repeated spellings and ignore unsupported translations" {
    const testing = std.testing;
    var strings = names.StringTable.init(testing.allocator);
    defer strings.deinit();
    var selector: Selector = .{ .a = testing.allocator, .deadline = .none };
    defer selector.deinit();
    var selected: std.ArrayList(Token) = .empty;
    defer selected.deinit(testing.allocator);
    var languages: Languages = .{};
    try languages.append("en;zh;ms;ta", false, .none);
    const tags: []const keys.Tag = &.{
        .{ .key = .{ .group = .name }, .text = "Rochor" },
        .{ .key = .{ .group = .name, .language = .en }, .text = "Rochor" },
        .{ .key = .{ .group = .name, .language = .ms }, .text = "Rochor" },
        .{ .key = .{ .group = .name, .language = .ta }, .text = "ரோச்சோர்" },
        .{ .key = .{ .group = .name, .language = .zh }, .text = "梧槽" },
        .{ .key = .{ .group = .name, .language = .fr }, .text = "Rochor français" },
    };
    var rows: [tags.len]Row = undefined;
    for (tags, &rows) |tag, *row| row.* = .{ .key = tag.key, .text = try strings.intern(tag.text) };
    try selector.select(&rows, .{ .group = .name }, &strings, &languages, .{}, &selected);
    const expected: []const Token = &.{
        .{ .text = "Rochor", .language = .en },
        .{ .text = "梧槽", .language = .zh },
        .{ .text = "Rochor", .language = .ms },
        .{ .text = "ரோச்சோர்", .language = .ta },
    };
    try testing.expectEqual(expected.len, selected.items.len);
    for (expected, selected.items) |want, got| {
        try testing.expectEqualStrings(want.text, got.text);
        try testing.expectEqual(want.language, got.language);
    }
}

// Ported from test/gurka/test_phonemes_w_langs.cc, Alts.
test "sided aliases inherit translations from the unsided tags" {
    const a = std.testing.allocator;
    var strings = names.StringTable.init(a);
    defer strings.deinit();
    var selector: Selector = .{ .a = a, .deadline = .none };
    defer selector.deinit();
    var selected: std.ArrayList(Token) = .empty;
    defer selected.deinit(a);
    var languages: Languages = .{};
    try languages.append("fr - nl", true, .none);
    const rows: []const Row = &.{
        .{ .key = .{ .group = .alt_name, .side = .right }, .text = try strings.intern("Chaussée de Gand - Steenweg op Gent") },
        .{ .key = .{ .group = .alt_name, .side = .right, .language = .nl }, .text = try strings.intern("Steenweg op Gent") },
        .{ .key = .{ .group = .alt_name, .language = .fr }, .text = try strings.intern("Chaussée de Gand") },
    };
    try selector.select(rows, .{ .group = .alt_name, .side = .right }, &strings, &languages, .{ .distinct_side = true }, &selected);
    try std.testing.expectEqual(2, selected.items.len);
    try std.testing.expectEqualStrings("Chaussée de Gand", selected.items[0].text);
    try std.testing.expectEqual(Language.fr, selected.items[0].language);
    try std.testing.expectEqualStrings("Steenweg op Gent", selected.items[1].text);
    try std.testing.expectEqual(Language.nl, selected.items[1].language);
}
