// Ported from lua/admin.lua and src/mjolnir/pbfadminparser.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const Iterator = @import("tags/input.zig").Iterator;

pub const Attributes = struct {
    level: u8,
    name: []const u8 = "",
    english_name: []const u8 = "",
    iso_code: []const u8 = "",
    default_language: []const u8 = "",
    drive_on_right: bool = true,
    allow_intersection_names: bool = false,
};

const Key = enum {
    type,
    boundary,
    admin_level,
    name,
    english_name,
    iso_code,
    alpha2,
    country_iso,
    state_iso,
    default_language,
    political_division,
};

const keys = std.StaticStringMap(Key).initComptime(.{
    .{ "type", .type },
    .{ "boundary", .boundary },
    .{ "admin_level", .admin_level },
    .{ "name", .name },
    .{ "name:en", .english_name },
    .{ "iso_code", .iso_code },
    .{ "ISO3166-1:alpha2", .alpha2 },
    .{ "ISO3166-1", .country_iso },
    .{ "ISO3166-2", .state_iso },
    .{ "default_language", .default_language },
    .{ "political_division", .political_division },
});

const french_overseas = std.StaticStringMap(void).initComptime(.{
    .{"Guyane"},
    .{"Guadeloupe"},
    .{"La Réunion"},
    .{"Martinique"},
    .{"Mayotte"},
    .{"Saint-Pierre-et-Miquelon"},
    .{"Saint-Barthélemy"},
    .{"Saint-Martin (France)"},
    .{"Polynésie Française"},
    .{"Wallis-et-Futuna"},
    .{"Nouvelle-Calédonie"},
    .{"Île de Clipperton"},
    .{"Terres australes et antarctiques françaises"},
});

const intersection_names = std.StaticStringMap(void).initComptime(.{
    .{"Japan"},
    .{"North Korea"},
    .{"South Korea"},
    .{"Nicaragua"},
});

/// Returned strings borrow the source block.
pub fn transform(tags: anytype, deadline: io.Deadline) !?Attributes {
    var values: std.EnumArray(Key, ?[]const u8) = .initFill(null);
    var iter = Iterator.init(tags, deadline);
    var count: usize = 0;
    while (try iter.next()) |tag| : (count += 1) {
        if (count % 256 == 0 and deadline.expired()) return error.DeadlineExceeded;
        if (keys.get(tag.key)) |key| values.set(key, tag.value);
    }

    const eql = std.mem.eql;
    if (!eql(u8, values.get(.type) orelse "", "boundary")) return null;
    const boundary = values.get(.boundary) orelse "";
    const territorial = eql(u8, boundary, "administrative") or eql(u8, boundary, "territorial");
    const raw_level = values.get(.admin_level);
    const language = values.get(.default_language);
    var name = values.get(.name) orelse "";
    const english = values.get(.english_name) orelse "";
    const num_level = if (raw_level) |raw| std.fmt.parseInt(u8, raw, 10) catch null else null;
    if (language != null and ((territorial and (num_level orelse 0) > 4) or
        eql(u8, boundary, "political") or eql(u8, values.get(.political_division) orelse "", "linguistic_community")))
    {
        return .{
            .level = if (raw_level == null) 15 else num_level orelse return null,
            .name = name,
            .english_name = if (eql(u8, english, name)) "" else english,
            .default_language = language.?,
            .drive_on_right = false,
        };
    }
    if (!territorial) return null;

    var level: u8 = undefined;
    var iso = values.get(.iso_code);
    var default_language = language orelse "";
    switch (num_level orelse return null) {
        2 => {
            if (!eql(u8, raw_level.?, "2") or eql(u8, name, "France")) return null;
            level = if (eql(u8, english, "Abkhazia") or eql(u8, english, "South Ossetia")) 4 else 2;
        },
        3 => {
            if (!eql(u8, raw_level.?, "3")) return null;
            const manila = eql(u8, name, "Metro Manila");
            const hong_kong = eql(u8, english, "Hong Kong");
            const metropolitan_france = eql(u8, english, "Metropolitan France");
            if (!manila and !hong_kong and !metropolitan_france and !french_overseas.has(name)) return null;
            if (!manila and !hong_kong and language == null) default_language = "fr";
            level = if (manila) 4 else 2;
            if (metropolitan_france) {
                name = "France";
                iso = "FR";
            }
        },
        4 => {
            if (!eql(u8, raw_level.?, "4")) return null;
            level = 4;
        },
        6 => {
            if (!eql(u8, raw_level.?, "6") or !eql(u8, name, "District of Columbia")) return null;
            level = 4;
        },
        else => return null,
    }
    if (eql(u8, name, "Metro Manila")) level = 4;
    if (level == 2) {
        iso = values.get(.alpha2) orelse values.get(.country_iso) orelse iso;
        if (iso == null and eql(u8, name, "British Sovereign Base Areas")) iso = "GB";
    } else if (values.get(.state_iso)) |raw| {
        iso = stateCode(raw) orelse iso;
    }
    return .{
        .level = level,
        .name = name,
        .english_name = if (eql(u8, name, english)) "" else english,
        .iso_code = iso orelse "",
        .default_language = default_language,
        .drive_on_right = !(left_driving.has(name) or left_driving.has(english)),
        .allow_intersection_names = intersection_names.has(name) or intersection_names.has(english),
    };
}

fn stateCode(raw: []const u8) ?[]const u8 {
    // Only these lengths can be retained by the Lua filter.
    if (raw.len < 2 or raw.len > 6) return null;
    if (std.mem.indexOfScalar(u8, raw, '-')) |position| {
        return if (position == 2 and (raw.len == 5 or raw.len == 6)) raw[3..] else null;
    }
    return switch (raw.len) {
        2, 3 => raw,
        4, 5 => raw[2..],
        else => null,
    };
}

const left_driving = std.StaticStringMap(void).initComptime(.{
    .{"Anguilla"},
    .{"Antigua and Barbuda"},
    .{"Australia"},
    .{"Bangladesh"},
    .{"Barbados"},
    .{"Bermuda"},
    .{"Bhutan"},
    .{"Botswana"},
    .{"British Virgin Islands"},
    .{"Brunei Darussalam"},
    .{"Cayman Islands"},
    .{"Cook Islands"},
    .{"Cyprus"},
    .{"Dominica"},
    .{"East Timor"},
    .{"England"},
    .{"Falkland Islands"},
    .{"Grenada"},
    .{"Guernsey"},
    .{"Guyana"},
    .{"Hong Kong"},
    .{"India"},
    .{"Indonesia"},
    .{"Ireland"},
    .{"Isle of Man"},
    .{"Jamaica"},
    .{"Japan"},
    .{"Jersey"},
    .{"Kenya"},
    .{"Kiribati"},
    .{"Lesotho"},
    .{"Macao"},
    .{"Malawi"},
    .{"Malaysia"},
    .{"Maldives"},
    .{"Malta"},
    .{"Mauritius"},
    .{"Moçambique"},
    .{"Montserrat"},
    .{"Namibia"},
    .{"Naoero"},
    .{"Nepal"},
    .{"New Zealand"},
    .{"Niue"},
    .{"Northern Ireland"},
    .{"Pakistan"},
    .{"Papua Niugini"},
    .{"Pitcairn Islands"},
    .{"Republic of Ireland"},
    .{"Saint Helena, Ascension and Tristan da Cunha"},
    .{"Saint Kitts and Nevis"},
    .{"Saint Lucia"},
    .{"Saint Vincent and the Grenadines"},
    .{"Samoa"},
    .{"Sesel"},
    .{"Singapore"},
    .{"Solomon Islands"},
    .{"Soomaaliya"},
    .{"South Africa"},
    .{"Sri Lanka"},
    .{"Suriname"},
    .{"Alba / Scotland"},
    .{"Swatini"},
    .{"Tanzania"},
    .{"Thailand"},
    .{"The Bahamas"},
    .{"Tokelau"},
    .{"Tonga"},
    .{"Trinidad and Tobago"},
    .{"Turks and Caicos Islands"},
    .{"Tuvalu"},
    .{"Uganda"},
    .{"United Kingdom"},
    .{"United States Virgin Islands"},
    .{"Viti"},
    .{"Cymru / Wales"},
    .{"Zambia"},
    .{"Zimbabwe"},
});

test "Valhalla country and state exceptions preserve names, languages and ISO fields" {
    const testing = std.testing;
    const Tag = @import("osm.zig").Tag;
    const prefix = [_]Tag{ .{ .key = "type", .value = "boundary" }, .{ .key = "boundary", .value = "territorial" } };
    const metropolis = prefix ++ [_]Tag{
        .{ .key = "admin_level", .value = "3" },
        .{ .key = "name", .value = "France métropolitaine" },
        .{ .key = "name:en", .value = "Metropolitan France" },
    };
    const france = (try transform(&metropolis, .none)).?;
    try testing.expectEqual(2, france.level);
    try testing.expectEqualStrings("France", france.name);
    try testing.expectEqualStrings("FR", france.iso_code);
    try testing.expectEqualStrings("fr", france.default_language);
    const national = prefix ++ [_]Tag{
        .{ .key = "admin_level", .value = "2" },
        .{ .key = "name", .value = "France" },
    };
    try testing.expectEqual(null, try transform(&national, .none));
    const district = prefix ++ [_]Tag{
        .{ .key = "admin_level", .value = "6" },
        .{ .key = "name", .value = "District of Columbia" },
        .{ .key = "ISO3166-2", .value = "US-DC" },
    };
    const dc = (try transform(&district, .none)).?;
    try testing.expectEqual(4, dc.level);
    try testing.expectEqualStrings("DC", dc.iso_code);
    const tokyo = prefix ++ [_]Tag{
        .{ .key = "admin_level", .value = "2" },
        .{ .key = "name", .value = "日本" },
        .{ .key = "name:en", .value = "Japan" },
        .{ .key = "ISO3166-1", .value = "JP" },
    };
    const japan = (try transform(&tokyo, .none)).?;
    try testing.expect(!japan.drive_on_right and japan.allow_intersection_names);
    try testing.expectEqualStrings("JP", japan.iso_code);
    const linguistic = [_]Tag{
        .{ .key = "type", .value = "boundary" },
        .{ .key = "boundary", .value = "political" },
        .{ .key = "default_language", .value = "nl" },
        .{ .key = "name", .value = "Language community" },
    };
    const area = (try transform(&linguistic, .none)).?;
    try testing.expectEqual(15, area.level);
    try testing.expectEqualStrings("nl", area.default_language);
}
