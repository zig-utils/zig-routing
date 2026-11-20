//! Latin search aliases for Greek, Cyrillic, and crossed Latin letters.

const greek = [_][]const u8{
    "a", "v", "g", "d", "e", "z", "i", "th", "i", "k",  "l",  "m", "n",
    "x", "o", "p", "r", "s", "s", "t", "y",  "f", "ch", "ps", "o",
};

const cyrillic = [_][]const u8{
    "a", "b", "v", "g", "d", "e",  "zh", "z",  "i",  "i",    "k", "l", "m", "n", "o",  "p",
    "r", "s", "t", "u", "f", "kh", "ts", "ch", "sh", "shch", "",  "y", "",  "e", "yu", "ya",
};

/// The input has already passed through full Unicode search folding.
/// Null means the scalar has no supported Latin approximation.
pub fn latin(cp: u21) ?[]const u8 {
    if (cp >= 0x03b1 and cp <= 0x03c9) return greek[cp - 0x03b1];
    if (cp >= 0x0430 and cp <= 0x044f) return cyrillic[cp - 0x0430];
    return switch (cp) {
        0x00e6 => "ae", // æ
        0x00f0, 0x0111 => "d", // ð, đ
        0x00f8 => "o", // ø
        0x00fe => "th", // þ
        0x0127 => "h", // ħ
        0x0131 => "i", // ı
        0x0142 => "l", // ł
        0x014b => "ng", // ŋ
        0x0153 => "oe", // œ
        0x0452 => "dj", // ђ
        0x0454 => "ye", // є
        0x0456 => "i", // і
        0x0458 => "j", // ј
        0x0459 => "lj", // љ
        0x045a => "nj", // њ
        0x045b => "c", // ћ
        0x045f => "dz", // џ
        0x0491 => "g", // ґ
        else => null,
    };
}
