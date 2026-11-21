# Reverse geocoding

`geocode.reverse.Engine` opens a geocoding bundle and prepares its spatial
index. A lookup has a coordinate, radius, layer, limit, and preferred
language. It returns the admin hierarchy at the input point and a list
of features with their own hierarchies.

```sh
zr geocode reverse BUNDLE 6.13,49.61 --layer address --radius 200 --limit 3
zr geocode reverse BUNDLE 6.13,49.61 --layer city --language fr
zig build bench-geocode-reverse -Doptimize=ReleaseFast -- BUNDLE
```

## Spatial search

The engine indexes addresses, place and POI anchors, street segments,
and interpolation shapes in the routing engine's 1/256-degree grid.
It shares the cell directory and delta-varint encoding with the graph.
The lookup visits populated cells in order of their minimum distance
to the input point. It stops when all remaining cells lie beyond the
radius or the worst distance in its current result set.

Streets use the projection onto their member-way geometry. Several
segments can contribute to one street, and the result uses the
closest segment. Interpolations compare the nearest supported house
numbers along each segment, using along-shape distance and the existing
interpolation rules. Estimates carry an `approximate` flag. Results
sort by great-circle distance, then by feature kind and source row.
An exact address wins a distance tie against an interpolation or a
street. Batch lookups visit points by grid cell and return responses in
input order.

## Administrative boundaries

New bundles include three optional mmap sections for polygons, hole
rings, and E7 coordinates. Each polygon names its existing admin row.
The loader verifies checksums, UUIDs, coordinate ranges, and all spans.
An R-tree over the persisted geometry finds the containing regions
even far from named streets. It uses the same smallest-area rule as
extraction. A `city` or `country` lookup selects that containment
level. Nearest-feature search falls back to the most specific containing
region when no feature meets the radius.

Earlier bundles support reverse lookup of their stored features and
hierarchies. Bundles with the polygon sections also resolve the hierarchy
at arbitrary input points. Points beyond the coverage of both features
and regions return an empty result.

## Regional benchmark

The benchmark draws 10,000 distinct address rows from the bundle with
seed 224. It queries the exact coordinates and checks the OSM ID and
source kind of the returned address. It also times a companion pass
with small coordinate offsets. Both latency distributions use a warm
engine and request arena. The benchmark checks ocean lookup and counts
backing allocator calls during timed requests.

On the 2026-01-01 Luxembourg extract, 9,993 of 10,000 lookups returned
the sampled OSM address. On an Apple M3 Pro in ReleaseFast, p99 was
57 microseconds at the address coordinates and 92 microseconds with
offsets. The ocean query returned an empty result. The timed pass recorded
zero backing allocator calls.
