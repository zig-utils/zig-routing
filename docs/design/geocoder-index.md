# Geocoder term index

`zr geocode index BUNDLE --threads N` analyzes an existing geocode bundle
and publishes `geocode-index.bin` in that directory. Each worker owns a
range of bundle records. It interns terms and sorts postings locally. The
writer merges the runs in memory, streams postings into a temporary file,
and atomically installs the synced result. The final bytes are independent
of the worker count.

The five fields are name, street, city, postcode, and house number. Names
include language-qualified OSM names and address house names. The street
field also includes the street tag on addresses. The city field uses the
matched city division's names. Text fields use the shared analyzer and
its Latin aliases. The postcode field uses country-aware postcode
normalization and retains leading zeros. Within a field and term, each
document contributes a single posting.

## File layout

The little-endian header contains the magic `ZRGIDX01`, format version,
source bundle UUID, record counts, section sizes, field spans, and an
XXH3 checksum of the payload. The payload contains the posting stream,
dictionary, zero alignment padding, and fixed-width block directory.

Each field is divided into sorted blocks of up to 16 terms. The directory
points to each block's first term and its initial position in the posting
stream. The first term is stored in full. Later terms store the shared
prefix length and the suffix bytes. A prefix search binary searches first
terms and decodes from that position using caller-supplied scratch.

Document IDs concatenate the place, street, address, and POI row numbers
in the bundle. Posting lists sort by decreasing bundle importance and
then increasing ID. Singletons are stored inline in the dictionary.
Multi-record lists start with fixed-width skip offsets, followed by groups
of up to 64 records. Each group starts with an absolute ID. The remaining
IDs use signed ZigZag deltas and varints. A lookup by posting ordinal jumps
to its group and decodes at most 63 preceding IDs.

The mmap loader checks the expected dataset UUID, section bounds, checksum,
term order and encoding, posting IDs, and skip offsets before exposing the
view. `zr geocode inspect BUNDLE` reports field counts, section sizes, and
the ten terms with the largest posting lists when the bundle has an index.

## Verification

```sh
zr geocode index BUNDLE --threads 7
zr geocode inspect BUNDLE
zig build bench-geocode-index -Doptimize=ReleaseFast -- BUNDLE
scripts/fuzz.sh -s 60 geocode-index
```

The benchmark samples prefixes from each field and measures warm time to
the first matching term. It gates p95 at one microsecond and file size at
40% of the analyzed text. The denominator sums the normalized token and
alias bytes emitted for indexed field values before term and posting
deduplication, including normalized postcode bytes.

The 2026-01-01 Luxembourg extract yielded 34,791 terms and 1,956,735
postings. The index was 2,857,912 bytes against 17,437,007 analyzed bytes,
or 16.39%. On an Apple M3 Pro, 98,432 warm lookups measured 209 ns at p50,
416 ns at p95, and 500 ns at p99. The one-worker and seven-worker builds
produced byte-identical files.

The 2026-11-19 Liechtenstein extract yielded 4,586 terms and 113,793
postings. Its 185,800-byte index was 22.19% of the analyzed text, and
59,648 warm lookups measured 375 ns at p95.
