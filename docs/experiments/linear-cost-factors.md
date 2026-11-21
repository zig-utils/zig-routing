# Linear cost factors on directed edge cuts

Valhalla 3.9.3 correlates the endpoints of each linear feature with NoCost and
recovers the directed ranges with its exact edge walker. The native resolver
uses the same 10 m search radius and zero minimum reachability and node snap
tolerance. A multi-edge feature discards an endpoint portion shorter than 1 m
and applies the configured minimum factor. A single-edge feature uses the
supplied factor. A zero factor excludes the directed edge at the range's start.
A nonzero range with `"allow_types":["all"]` permits travel on that directed
edge. Explicit exclusions take precedence. The opposite edge has its own
ranges.

## Reproducing the pinned discrepancy

Build the `access-regions` fixture with
`zig build gurka-pbf -- FILE.osm.pbf access-regions` and load it into the pinned
oracle. Send this request to `/route`. Edge AB is 400 m. The route traverses
20% to 40% and the feature covers 25% to 75%.

```json
{
  "costing": "auto",
  "directions_type": "none",
  "locations": [
    {"lat": 0, "lon": 0.0007186496357956819, "minimum_reachability": 0},
    {"lat": 0, "lon": 0.0014372992715913639, "minimum_reachability": 0}
  ],
  "linear_cost_factors": [
    {
      "type": "Feature",
      "geometry": {
        "type": "LineString",
        "coordinates": [[0.0008983120447446023, 0], [0.002694936134233807, 0]]
      },
      "properties": {"factor": 0.5}
    }
  ]
}
```

| Feature factor | Valhalla 3.9.3 cost | Valhalla 3.9.3 elapsed time | Native cut multiplier | Native cost | Native elapsed time |
| --- | ---: | ---: | ---: | ---: | ---: |
| No feature | 6.994 | 8.228 s | 1 | 6.994 | 8.228 s |
| 0.5 | -1.748 | -2.057 s | 0.625 | 4.371 | 5.142 s |
| 2 | 24.480 | 28.800 s | 1.750 | 12.240 | 14.400 s |

For the native replay, use those coordinates as `shape` and set
`"shape_match":"edge_walk"` in `zr route --action trace_attributes`. The
Gurka test also sends the cuts through forward and reverse search and
compares the cost and elapsed time with fixed-path recost.

Valhalla's partial cost uses the feature's end as the overlap's end. That
counts 200 m of discounted travel on an 80 m route. The corrected calculation
clips both ends so that the feature covers exactly 60 m. Search and recost
apply the same multiplier to the cost and elapsed time for a fractional cut.
A whole-edge traversal applies the full-edge average to its weighted cost
and uses its ordinary elapsed time.
[Valhalla 3.9.3 partial pricing](https://github.com/valhalla/valhalla/blob/3.9.3/valhalla/sif/dynamiccost.h#L1337-L1364)

Each overlapping range contributes its own `(factor - 1) * overlap / cut_length`.
The mean starts at one, following Valhalla's additive combination of features,
and is bounded below by double precision epsilon for I3. The request's I4
floor is at most one and at most the smallest possible mean across all cuts.
For each edge, summing its discounts as if they all covered the same cut
gives a conservative lower bound. A request that permits additional edges
uses a zero floor for its existing graph potential. Search uses the resulting
floor to scale its base potential before ranking labels.
