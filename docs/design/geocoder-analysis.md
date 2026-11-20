# Geocoder text analysis

The shared entry point for index and query text is
`geocode.analyze.Scratch.analyze`. The caller
supplies the language and country, the scratch allocator, and a deadline. The
result borrows the scratch buffers. Each token has a class, a normalized UTF-8
key, and an optional Latin alias. A warmed scratch buffer can be reused for
subsequent inputs without allocator growth.

The Unicode search key applies compatibility decomposition, full case folding,
and combining mark removal. It folds decimal digits to ASCII and removes
default-ignorable scalars. Hangul syllables decompose to Jamo. Punctuation
tailoring joins internal apostrophes and recognizes the separators used in
compound house numbers and postcodes. Invalid UTF-8 returns an error.
[Unicode normalization](https://www.unicode.org/reports/tr15/),
[Unicode 18 case folding](https://www.unicode.org/Public/18.0.0/ucd/CaseFolding.txt)

The tokenizer keeps runs of Latin, Greek, and Cyrillic letters and numbers.
Its East Asian fallback emits one token per Han ideograph and keeps adjacent
Kana or Hangul together. The same token retains its normalized script and
may carry a Latin alias for supported Greek, Cyrillic, and Latin letters.
[Unicode word segmentation](https://www.unicode.org/reports/tr29/)

English and German tables expand street types, directions, and common
shortenings. Initial English `St.` before a name expands to `saint`.
German street compounds split into a name stem and a street type, so
`Buchenstraße` and `Buchen Str.` produce the same keys. Stop words keep their
normalized keys and carry the stop-word class. House tokens reuse the house
number normalization rules for leading zeros, ranges, and fractions.
[USPS street suffixes](https://pe.usps.com/text/pub28/28apc_002.htm),
[USPS directionals](https://pe.usps.com/text/pub28/pub28c2_014.htm)

Country-specific postcode patterns cover the US, Canada, UK, Germany,
Austria, Switzerland, Liechtenstein, Luxembourg, France, the Netherlands,
and Belgium. The country hint determines which pattern is checked. A
leading bare number followed by a name is eligible for the house-number
class. An explicit country prefix or the full ZIP+4 shape identifies a
postcode in that position. Joined and separated forms of the supported
alphanumeric postcodes share one key.
[Canada Post postcode structure](https://www.canadapost-postescanada.ca/cpc/en/support/articles/addressing-guidelines/postal-codes.page)

The generated data packs Unicode Character Database 18.0.0 folds and
character properties. Zig validates the resource and builds its page offsets
at compile time. The checked-in source manifest lists the Unicode files
and their SHA-256 digests. The normal build uses the checked-in resource.
[Unicode 18 character database](https://www.unicode.org/Public/18.0.0/ucd/ReadMe.txt)

```sh
python3 scripts/geocode/generate-unicode.py UCD_DIRECTORY --check
zig build test-geocode-analysis
zig build bench-geocode-analysis -Doptimize=ReleaseFast
```

The fixtures contain 200 English and 200 German name and query pairs with
explicit token text and classes. The single-thread benchmark replays around 16 MiB each
of English, German, and mixed-script input with a zero-capacity allocator
after warm-up. It fails below 20 MB/s. On an Apple M3 Pro in ReleaseFast, the
measured rates were 98.86 MB/s for English, 109.13 MB/s for German, and
83.55 MB/s for the multilingual input.
