# Locate

Send a JSON request to `/locate` on a server configured with
`zig_routing.bundle_path`. The CLI uses the same action.

```sh
zr --config CONFIG.json route --action locate '{"locations":[{"lat":52.078937,"lon":5.115321}],"costing":"auto","verbose":true}'
```

The response contains one object per input location. The concise form
reports the way, projected coordinate, side of street and fraction along
each directed candidate. Set `verbose` to include reachability, OpenLR,
and graph edge and node attributes. An off-graph input returns empty
candidate arrays. An input whose graph data cannot be read returns null
arrays and includes a reason in verbose mode.

## Format differences

- In `edge_id`, `node_id` and `edge.end_node`, both `id` and `value`
  hold the unsigned dense index in the configured native bundle.
  `level` and `tile_id` are zero. These IDs can change when rebuilding
  the bundle.
- `bounding_circle` encloses the native edge geometry. Its center is
  the midpoint of the shape's bounds, and its radius is rounded up to
  whole metres.
- The native graph has no hierarchy transitions or per-node elevation.
  Node counts describe native outgoing edges, `transition_count` is
  zero, and `elevation` uses Valhalla's unavailable sentinel of `-500`.
  Unstored named intersections use `false`. Tile-only optional edge
  metadata with no native representation is omitted.
- `live_speed` is an empty object and `predicted_speeds` an empty array.
- `format: "osrm"` selects an [OSRM nearest-style response](https://project-osrm.org/docs/v5.24.0/api/#nearest-service)
  with one nearest waypoint per location and a `NoSegment` error when
  an input cannot snap. Each waypoint uses `[longitude, latitude]` and
  has dense endpoint IDs in `nodes`. The response omits OSRM hints.
  Valhalla 3.9.3 uses its normal locate array for this format option.

## Oracle validation

Use the [Utrecht extract](../../oracle/datasets.tsv) and the
[matching single-level build and import](../experiments/isochrone.md#reproduction).
Run the pinned Valhalla and native HTTP services on those graphs and give
`zr diff` a TSV with `/locate`, a tab and one JSON request per line.
These requests reproduce an ordered tie at the second location and an
extra native unreachable candidate at the first location, respectively.

```jsonl
{"locations":[{"lat":52.112579,"lon":5.07434,"radius":30,"search_cutoff":250},{"lat":52.078277,"lon":5.129571,"radius":30,"search_cutoff":250}],"costing":"pedestrian","verbose":true}
{"locations":[{"lat":52.053613,"lon":5.050598},{"lat":52.126265,"lon":5.095931}],"costing":"motorcycle","verbose":true}
```

The paired-candidate comparison across 240 input locations checked 619
projected coordinates and fractions within `1e-6`. Candidate ordering
and reachability differences are tracked in [#247](https://github.com/zig-utils/zig-routing/issues/247).
An independent build from the same small OSM map verified that a directed
height restriction appears in both implementations. The same-graph importer
also preserves directed access records for verbose comparisons.
[Restriction import](https://github.com/zig-utils/zig-routing/issues/246).
