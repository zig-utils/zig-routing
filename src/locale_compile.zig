//! Build-time compiler for the pinned Valhalla locale dictionaries.
const std = @import("std");
const io = @import("infra/io.zig");
const types = @import("narrative/dictionary_types.zig");
const Value = std.json.Value;
const Writer = io.Writer;
const Text = []const u8;

const Source = struct { tag: Text, root: Value };
const Input = struct {
    arena: std.mem.Allocator,
    sources: std.ArrayList(Source) = .empty,

    fn load(self: *Input, path: Text) !void {
        const basename = std.fs.path.basename(path);
        if (!std.mem.endsWith(u8, basename, ".json")) return;
        const tag = basename[0 .. basename.len - ".json".len];
        const mapping = try io.Mapping.mapFile(path, .read_only);
        defer mapping.unmap();
        const root = std.json.parseFromSliceLeaky(Value, self.arena, mapping.bytes, .{ .allocate = .alloc_always }) catch |err| {
            std.debug.print("locale {s} has invalid JSON: {t}\n", .{ tag, err });
            return err;
        };
        try self.sources.append(self.arena, .{ .tag = try self.arena.dupe(u8, tag), .root = root });
    }
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const input_dir = args.next() orelse return error.MissingLocaleDirectory;
    const dictionary_path = args.next() orelse return error.MissingDictionaryOutput;
    const registry_path = args.next() orelse return error.MissingLocaleRegistryOutput;
    if (args.next() != null) return error.ExtraArguments;

    const arena = init.arena.allocator();
    var input: Input = .{ .arena = arena };
    try io.walkFilesUntil(input_dir, .none, &input, Input.load);
    const sources = input.sources.items;
    if (sources.len != 36) return error.Expected36Locales;
    std.mem.sortUnstable(Source, sources, {}, sourceLess);
    const default = for (sources, 0..) |source, i| {
        if (std.mem.eql(u8, source.tag, "en-US")) break i;
    } else return error.MissingDefaultLocale;
    const reference = try field(sources[default].root, "instructions");

    var dictionary = Writer.Allocating.init(arena);
    try dictionary.writer.writeAll("// Generated from the pinned Valhalla locale JSON files.\nconst types = @import(\"dictionary_types\");\npub const all = [_]types.NarrativeDictionary{\n");
    for (sources) |source| emitDictionary(&dictionary.writer, source, reference) catch |err| {
        std.debug.print("locale {s}: {t}\n", .{ source.tag, err });
        return err;
    };
    try dictionary.writer.writeAll("};\n");

    var registry = Writer.Allocating.init(arena);
    try emitRegistry(arena, &registry.writer, sources, default);
    try io.writeFile(dictionary_path, dictionary.written());
    try io.writeFile(registry_path, registry.written());
}

fn sourceLess(_: void, left: Source, right: Source) bool {
    return std.mem.lessThan(u8, left.tag, right.tag);
}

fn emitDictionary(out: *Writer, source: Source, reference: Value) !void {
    if (source.root != .object or source.root.object.count() != 3) return error.InvalidLocaleObject;
    const instructions = try field(source.root, "instructions");
    const posix = try asText(try field(source.root, "posix_locale"));
    const dictionary = @typeInfo(types.NarrativeDictionary).@"struct";
    const names = dictionary.field_names[2..];
    if (instructions != .object or instructions.object.count() != names.len) return error.InvalidInstructionSubsets;
    try out.writeAll(".{ .language_tag = ");
    try emitText(out, source.tag);
    try out.writeAll(", .posix_locale = ");
    try emitText(out, posix);
    try out.writeAll(",\n");
    inline for (names, dictionary.field_types[2..]) |name, Subset| {
        const key = name[0 .. name.len - "_subset".len];
        const value = try field(instructions, key);
        const baseline = try field(reference, key);
        try out.print("    .{s} = .{{ ", .{name});
        emitSubset(Subset, out, source.tag, key, value, baseline) catch |err| {
            std.debug.print("instruction subset {s}: {t}\n", .{ key, err });
            return err;
        };
        try out.writeAll("},\n");
    }
    try out.writeAll("},\n");
}

fn emitSubset(comptime T: type, out: *Writer, locale: Text, subset: Text, value: Value, baseline: Value) !void {
    const fields = @typeInfo(T).@"struct";
    if (value != .object or value.object.count() != fields.field_names.len) return error.InvalidSubsetFields;
    inline for (fields.field_names, fields.field_types) |name, Field| {
        const actual = try field(value, name);
        const expected = try field(baseline, name);
        try out.print(".{s} = ", .{name});
        if (Field == types.PhraseMap) {
            try emitPhrases(out, locale, subset, actual, expected);
        } else if (Field == types.TransitStopCountLabels) {
            try emitPluralLabels(out, locale, subset, actual, expected);
        } else if (Field == Text) {
            const text = try asText(actual);
            try validateTags(locale, subset, name, 0, text, try asText(expected));
            try emitText(out, text);
        } else {
            const count = @typeInfo(Field).array.len;
            if (actual != .array or actual.array.items.len != count or expected != .array or expected.array.items.len != count)
                return error.InvalidLabelArray;
            try out.writeAll(".{ ");
            for (actual.array.items, expected.array.items, 0..) |label, expected_label, index| {
                const actual_text = try asText(label);
                try validateTags(locale, subset, name, @intCast(index), actual_text, try asText(expected_label));
                try emitText(out, actual_text);
                try out.writeAll(", ");
            }
            try out.writeAll("}");
        }
        try out.writeAll(", ");
    }
}

fn emitPhrases(out: *Writer, locale: Text, subset: Text, actual: Value, expected: Value) !void {
    if (actual != .object or expected != .object or actual.object.count() != expected.object.count()) return error.InvalidPhraseIds;
    var texts: [256]?Text = @splat(null);
    var iterator = expected.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const id = try std.fmt.parseInt(u8, key, 10);
        if (texts[id] != null) return error.DuplicatePhraseId;
        const text = try asText(try field(actual, key));
        try validateTags(locale, subset, "phrases", id, text, try asText(entry.value_ptr.*));
        texts[id] = text;
    }
    try out.writeAll(".{ .entries = &.{ ");
    for (texts, 0..) |text, id| {
        if (text) |phrase| {
            try out.print(".{{ .id = {d}, .text = ", .{id});
            try emitText(out, phrase);
            try out.writeAll(" }, ");
        }
    }
    try out.writeAll("} }");
}

fn emitPluralLabels(out: *Writer, locale: Text, subset: Text, actual: Value, expected: Value) !void {
    if (actual != .object or expected != .object or actual.object.count() != expected.object.count()) return error.InvalidTransitStopLabels;
    try out.writeAll(".{ ");
    var labels = expected.object.iterator();
    while (labels.next()) |entry| {
        const name = entry.key_ptr.*;
        _ = std.meta.stringToEnum(types.PluralCategory, name) orelse return error.InvalidPluralCategory;
        const text = try asText(try field(actual, name));
        try validateTags(locale, subset, name, 0, text, try asText(entry.value_ptr.*));
        try out.print(".{s} = ", .{name});
        try emitText(out, text);
        try out.writeAll(", ");
    }
    try out.writeAll("}");
}

fn emitRegistry(arena: std.mem.Allocator, out: *Writer, sources: []const Source, default: usize) !void {
    var entries: std.StringHashMapUnmanaged(u8) = .empty;
    try out.print("// Generated from the pinned Valhalla locale JSON files.\npub const default: u8 = {d};\npub const canonical = [_][]const u8{{\n", .{default});
    for (sources, 0..) |source, i| {
        try addTag(arena, &entries, source.tag, @intCast(i));
        try emitText(out, source.tag);
        try out.writeAll(",\n");
        const aliases = try field(source.root, "aliases");
        if (aliases != .array) return error.InvalidLocaleAliases;
        for (aliases.array.items) |alias| try addTag(arena, &entries, try asText(alias), @intCast(i));
    }
    try out.writeAll("};\npub const short = [_]u64{\n");
    var short: std.ArrayList(u64) = .empty;
    const Long = struct { name: Text, index: u8 };
    var long: std.ArrayList(Long) = .empty;
    var iterator = entries.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const index = entry.value_ptr.*;
        if (name.len <= 5) {
            try short.append(arena, types.shortTagKey(name) << 8 | index);
        } else {
            try long.append(arena, .{ .name = name, .index = index });
        }
    }
    std.mem.sortUnstable(u64, short.items, {}, std.sort.asc(u64));
    for (short.items) |record| try out.print("0x{x},\n", .{record});
    try out.writeAll("};\npub const long = [_]struct { name: []const u8, index: u8 }{\n");
    std.mem.sortUnstable(Long, long.items, {}, struct {
        fn less(_: void, left: Long, right: Long) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.less);
    for (long.items) |entry| {
        try out.writeAll(".{ .name = ");
        try emitText(out, entry.name);
        try out.print(", .index = {d} }},\n", .{entry.index});
    }
    try out.writeAll("};\n");
}

fn addTag(arena: std.mem.Allocator, entries: *std.StringHashMapUnmanaged(u8), tag: Text, index: u8) !void {
    if (tag.len == 0) return error.EmptyLanguageTag;
    const entry = try entries.getOrPut(arena, tag);
    if (entry.found_existing) return error.DuplicateLanguageTag;
    entry.value_ptr.* = index;
}

fn field(value: Value, key: Text) !Value {
    if (value != .object) return error.ExpectedObject;
    return value.object.get(key) orelse {
        std.debug.print("missing locale field {s}\n", .{key});
        return error.MissingLocaleField;
    };
}

fn asText(value: Value) !Text {
    if (value != .string) return error.ExpectedLocaleText;
    return value.string;
}

fn emitText(out: *Writer, value: Text) !void {
    try out.print("\"{f}\"", .{std.zig.fmtString(value)});
}

const validateTags = @import("narrative/locale_placeholders.zig").validate;
