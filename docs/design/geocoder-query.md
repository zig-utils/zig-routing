# Forward geocoding

`geocode.query.Engine` opens the bundle and index together, verifies their
dataset UUID and row counts, and prepares the country names. The engine
can be shared between threads. Each search takes a request arena and a
deadline. Returned strings borrow the arena or the immutable bundle.

```sh
zr geocode search BUNDLE 'Place Guillaume II, Luxembourg' --limit 3
zr geocode search BUNDLE --street 'Place Guillaume II' --city Luxembourg --country LU --layer street
zr geocode search BUNDLE 'Main Street' --near 6.13,49.61 --language fr
```

Free text uses the shared analyzer. Each token has possible field
interpretations, including both house number and postcode for a numeric
token. A country name can be a separate suffix or one of the place tokens.
Structured requests constrain the tokens to their named fields and may
filter by a country name or ISO code. Country codes after a comma select
the country directly.

The engine intersects the unions of postings for each token. Every
posting list shares the same decreasing importance and increasing ID
order. The search advances lower cursors towards the current intersection
key and skips restart groups whose keys precede it. It stops when the
remaining importance and maximum matching bonuses cannot improve the
current result set. Ties use decreasing importance and increasing ID.

When exact retrieval returns no result, the engine traverses eligible
dictionary fields with a banded, UTF-8 scalar edit distance. It reuses the
matching rows for shared prefixes and accepts adjacent transpositions.
Four to eight scalars allow one edit and nine or more allow two. This
applies to names and localities. Numeric identifiers remain exact.

## Ranking weights

| Match or bonus | Points |
| --- | ---: |
| Name, street, or city token | 115, 107, or 72 |
| Street type or direction in the street field | 128 |
| House number or postcode in its primary field | 149 or 150 |
| Number in its alternate numeric field | 95 |
| Token in its structured field | 150 |
| Latin alias | Deduct 10 |
| Each edit | Deduct 40 |
| Importance | One per 128, capped at 64 |
| Place, street, address, or POI | 18, 8, 0, or 12 |
| Preferred language label | 12 |
| Proximity | `160 / (1 + distance_m / 1500)` |

The bbox filter includes both endpoints and supports a box across the
antimeridian. It tests each feature's representative point. A result
contains the source ID and layer, a localized label and formatted
address, its coordinate, and its bounding box. Street results derive
bounds from member-way geometry. Point features use their stored coordinate.

## Regional quality set

```sh
zig build bench-geocode-query -Doptimize=ReleaseFast -- BUNDLE
```

The benchmark draws 500 records with seed 222 from the source bundle.
Before querying, it records the expected source row from each sample.
It uses 100 place names, 100 structured street queries, 100 free-text
addresses, 100 structured addresses, 60 POI names with locality, and
40 structured street names with an adjacent transposition. Street queries
select the street layer. The other cases search all layers. It gates
top-three recall at 85% and warm p99 at 10 ms over five timed passes with
the bundle already open.

On the 2026-01-01 Luxembourg extract, 493 of 500 queries returned the
expected record in the top three, including all 40 queries with a
transposition. On an Apple M3 Pro in ReleaseFast, the 2,500 timed queries
measured 0.34 ms at p50, 3.69 ms at p95, and 6.57 ms at p99.
