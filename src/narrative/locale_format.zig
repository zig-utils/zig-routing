// Ported from get_localized_time in src/odin/util.cc and the locale facets
// used in src/odin/narrativebuilder.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const datetime = @import("../graph/datetime.zig");

pub const Numbers = struct {
    decimal: u8 = '.',
    thousands: ?u8 = null,

    pub fn write(self: Numbers, out: *io.Writer, number: f32) !void {
        if (!std.math.isFinite(number) or number < 0 or number >= @as(f32, @floatFromInt(std.math.maxInt(u64))))
            return error.InvalidDistance;
        const integral: u64 = @intFromFloat(number);
        var digits: [20]u8 = undefined;
        const integer = std.fmt.bufPrint(&digits, "{d}", .{integral}) catch unreachable;
        for (integer, 0..) |digit, index| {
            if (self.thousands) |separator| {
                if (index != 0 and (integer.len - index) % 3 == 0) try out.writeByte(separator);
            }
            try out.writeByte(digit);
        }
        if (number != @trunc(number)) {
            try out.writeByte(self.decimal);
            const tenths: u8 = @intFromFloat(@round((number - @trunc(number)) * 10));
            try out.writeByte('0' + tenths);
        }
    }
};

const Clock = enum {
    colon,
    colon_unpadded,
    am_pm,
    twelve_hour,
    finnish,
    norwegian,
    japanese,
    korean,
    chinese,
};

pub const Format = struct {
    numbers: Numbers = .{},
    clock: Clock = .colon,

    pub fn forPosixLocale(locale: []const u8) Format {
        return formats.get(locale) orelse .{};
    }

    pub fn writeLocalTime(self: Format, out: *io.Writer, date_time: []const u8) !void {
        const split = std.mem.indexOfScalar(u8, date_time, 'T') orelse return;
        // Upstream parses a local time with a numeric UTC offset. An invalid
        // timestamp with a T leaves the local time at the epoch.
        const start_of_offset = split + 6;
        const local = if (date_time.len > start_of_offset and hasOffset(date_time[start_of_offset..]))
            datetime.Local.parse(date_time[0..start_of_offset])
        else
            null;
        const hour: u8 = if (local) |value| value.hour else 0;
        const minute: u8 = if (local) |value| value.minute else 0;
        const hour12 = if (hour % 12 == 0) @as(u8, 12) else hour % 12;
        switch (self.clock) {
            .colon => try out.print("{d:0>2}:{d:0>2}", .{ hour, minute }),
            .colon_unpadded => try out.print("{d}:{d:0>2}", .{ hour, minute }),
            .am_pm => try out.print("{d}:{d:0>2} {s}", .{ hour12, minute, if (hour < 12) "AM" else "PM" }),
            .twelve_hour => try out.print("{d:0>2}:{d:0>2}", .{ hour12, minute }),
            .finnish => try out.print("{d:0>2}.{d:0>2}.", .{ hour, minute }),
            .norwegian => try out.print("kl. {d:0>2}.{d:0>2} +00", .{ hour, minute }),
            .japanese => try out.print("{d:0>2}時{d:0>2}分", .{ hour, minute }),
            .korean => try out.print("{d:0>2}시 {d:0>2}분", .{ hour, minute }),
            .chinese => try out.print("{d:0>2}时{d:0>2}分", .{ hour, minute }),
        }
    }
};

fn hasOffset(value: []const u8) bool {
    if (value.len < 3 or (value[0] != '-' and value[0] != '+')) return false;
    if (!std.ascii.isDigit(value[1]) or !std.ascii.isDigit(value[2])) return false;
    const minutes = if (value.len > 3 and value[3] == ':') value[4..] else value[3..];
    return minutes.len == 0 or (minutes.len >= 2 and std.ascii.isDigit(minutes[0]) and std.ascii.isDigit(minutes[1]));
}

// The pinned Linux oracle's POSIX locale data, independent of the host's
// installed locales. Thousands grouping is by three whenever it is enabled.
const formats = std.StaticStringMap(Format).initComptime([_]struct { []const u8, Format }{
    .{ "ar_SA.UTF-8", .{ .clock = .colon_unpadded } },
    .{ "bg_BG.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = null }, .clock = .colon_unpadded } },
    .{ "ca_ES.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "cs_CZ.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "da_DK.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "de_DE.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "el_GR.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = null } } },
    .{ "en_AU.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' } } },
    .{ "en_GB.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' } } },
    .{ "en_US.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' }, .clock = .am_pm } },
    .{ "es_ES.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "et_EE.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "fi_FI.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' }, .clock = .finnish } },
    .{ "fr_FR.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "he_IL.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' } } },
    .{ "hi_IN.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' }, .clock = .twelve_hour } },
    .{ "hu_HU.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "it_IT.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "ja_JP.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' }, .clock = .japanese } },
    .{ "ko_KR.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' }, .clock = .korean } },
    .{ "mn_MN.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "nb_NO.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' }, .clock = .norwegian } },
    .{ "nl_NL.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "pl_PL.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "pt_BR.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "pt_PT.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = null } } },
    .{ "ro_RO.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "ru_RU.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "sk_SK.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "sl_SI.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = null } } },
    .{ "sv_SE.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "tr_TR.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "uk_UA.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = ' ' } } },
    .{ "vi_VN.UTF-8", .{ .numbers = .{ .decimal = ',', .thousands = '.' } } },
    .{ "zh_CN.UTF-8", .{ .numbers = .{ .decimal = '.', .thousands = ',' }, .clock = .chinese } },
});

test "Valhalla localized departure and arrival times" {
    const cases = [_]struct { locale: []const u8, morning: []const u8, evening: []const u8 }{
        .{ .locale = "ar_SA.UTF-8", .morning = "8:17", .evening = "18:01" },
        .{ .locale = "bg_BG.UTF-8", .morning = "8:17", .evening = "18:01" },
        .{ .locale = "ca_ES.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "cs_CZ.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "da_DK.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "de_DE.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "el_GR.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "en_AU.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "en_GB.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "en_US.UTF-8", .morning = "8:17 AM", .evening = "6:01 PM" },
        .{ .locale = "es_ES.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "et_EE.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "fi_FI.UTF-8", .morning = "08.17.", .evening = "18.01." },
        .{ .locale = "fr_FR.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "he_IL.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "hi_IN.UTF-8", .morning = "08:17", .evening = "06:01" },
        .{ .locale = "hu_HU.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "it_IT.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "ja_JP.UTF-8", .morning = "08時17分", .evening = "18時01分" },
        .{ .locale = "ko_KR.UTF-8", .morning = "08시 17분", .evening = "18시 01분" },
        .{ .locale = "mn_MN.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "nb_NO.UTF-8", .morning = "kl. 08.17 +00", .evening = "kl. 18.01 +00" },
        .{ .locale = "nl_NL.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "pl_PL.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "pt_BR.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "pt_PT.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "ro_RO.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "ru_RU.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "sk_SK.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "sl_SI.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "sv_SE.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "tr_TR.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "uk_UA.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "vi_VN.UTF-8", .morning = "08:17", .evening = "18:01" },
        .{ .locale = "zh_CN.UTF-8", .morning = "08时17分", .evening = "18时01分" },
    };
    var out = io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    for (cases) |case| {
        const format = Format.forPosixLocale(case.locale);
        try format.writeLocalTime(&out.writer, "2020-01-02T08:17-05:00");
        try std.testing.expectEqualStrings(case.morning, out.written());
        out.clearRetainingCapacity();
        try format.writeLocalTime(&out.writer, "2020-01-02T18:01+09:00");
        try std.testing.expectEqualStrings(case.evening, out.written());
        out.clearRetainingCapacity();
    }
}
