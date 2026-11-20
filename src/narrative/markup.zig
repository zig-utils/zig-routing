// Ported from src/odin/markup_formatter.cc (Valhalla 3.9.3).
const std = @import("std");
const io = @import("../infra/io.zig");
const trip = @import("../api/trip.zig");

pub const Formatter = struct {
    enabled: bool = false,
    phoneme_format: []const u8 = "",

    /// Returns true when the pronunciation supplied the entire spoken name.
    pub fn write(self: Formatter, out: *io.Writer, text: []const u8, pronunciation: ?trip.Pronunciation, deadline: io.Deadline) !bool {
        if (!self.enabled or self.phoneme_format.len == 0) return false;
        const spoken = pronunciation orelse return false;
        const alphabet: []const u8 = switch (spoken.alphabet) {
            .kIpa => "ipa",
            .kKatakana => "katakana",
            .kJeita => "jeita",
            .kNtSampa => "nt-sampa",
            else => return error.InvalidPronunciationAlphabet,
        };
        const Tag = enum { QUOTES, PHONETIC_ALPHABET, TEXTUAL_STRING, VERBAL_STRING };
        var rest = self.phoneme_format;
        var wrote = false;
        while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
            if (deadline.expired()) return error.DeadlineExceeded;
            const close = std.mem.indexOfScalarPos(u8, rest, start + 1, '>') orelse break;
            const tag = std.meta.stringToEnum(Tag, rest[start + 1 .. close]) orelse {
                try out.writeAll(rest[0 .. start + 1]);
                wrote = true;
                rest = rest[start + 1 ..];
                continue;
            };
            try out.writeAll(rest[0..start]);
            const value = switch (tag) {
                .QUOTES => if (spoken.alphabet == .kNtSampa) "'" else "\"",
                .PHONETIC_ALPHABET => alphabet,
                .TEXTUAL_STRING => text,
                .VERBAL_STRING => spoken.value,
            };
            try out.writeAll(value);
            wrote = wrote or start != 0 or value.len != 0;
            rest = rest[close + 1 ..];
        }
        try out.writeAll(rest);
        return wrote or rest.len != 0;
    }
};
