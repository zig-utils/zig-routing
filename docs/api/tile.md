# Graph vector tiles

`/tile` returns a Mapbox Vector Tile for the requested XYZ coordinate.
Configure `zig_routing.bundle_path` to serve a native graph. The CLI
writes the same binary response to stdout.

```sh
zr --config CONFIG.json route --action tile '{"tile":{"z":14,"x":8424,"y":5406}}' > graph.mvt
```

The `edges` layer contains the road class and level. The `nodes` layer
contains level, ID, type and traffic signal state. Use the Valhalla
`filters` object to select optional attributes and
`tile_options.exclude_layers` to omit layers. Enable
`service_limits.tile.allow_verbose` to allow requests to select all
attributes with `verbose: true`. The `generalize` option scales the
zoom-dependent line simplification tolerance and defaults to 4. The
tile extent is 4096 and the geometry buffer is 128 units.
[Valhalla tile API](https://valhalla.github.io/valhalla/api/tile/).
[Mapbox Vector Tile specification](https://mapbox.github.io/vector-tile-spec/).

`loki.service_defaults.mvt_min_zoom_road_class` sets the minimum
zoom for each of the eight road classes in order. A valid coordinate
below the first threshold returns an empty tile. A request above the last
threshold returns error 175. Successful responses use
`application/vnd.mapbox-vector-tile` and
`Cache-Control: public, max-age=1800` by default. Change the cache
lifetime with `loki.service_defaults.mvt_max_age`.

Feature IDs and directional ID properties use dense graph IDs. The flat
native graph reports `tile_level=0`. The graph renderer covers the
`edges` and `nodes` layers. Unknown live speeds use Valhalla's 254 km/h
sentinel, with zero breakpoints and congestion.

## Oracle and latency checks

Use the [Utrecht extract](../../oracle/datasets.tsv) with the
[same single-level graph for both services](../experiments/isochrone.md#reproduction).
Use Valhalla 3.9.3's pinned vtzero decoder to check both binary responses.
Five tile coordinates exercise residential edges, road class thresholds
and adjacent tiles.

| z/x/y | Edge features | Node features |
| --- | ---: | ---: |
| 14/8424/5406 | 2,591 | 1,877 |
| 14/8425/5406 | 1,915 | 1,397 |
| 14/8423/5406 | 1,913 | 1,426 |
| 13/4212/2703 | 2,736 | 2,372 |
| 8/131/84 | 1,281 | 1,248 |

To measure the urban tile, start both versions with one worker on the
same machine and platform. Leave Valhalla's on-disk MVT cache disabled.
Run the client on the same network.

Three paired runs on an ARM64 Linux VM on an Apple M3 Pro used
1,000 requests per run after a one-second warm-up. The median p50
was 2.204 ms for native and 4.186 ms for Valhalla. Every measured
request succeeded.

```sh
printf '%s\t%s\n' /tile '{"tile":{"z":14,"x":8424,"y":5406}}' > graph-tile.tsv
zr bench NATIVE_URL --corpus graph-tile.tsv --dataset utrecht --connections 1 --threads 1 --warmup 1s --requests 1000 --out native.json
zr bench VALHALLA_URL --corpus graph-tile.tsv --dataset utrecht --connections 1 --threads 1 --warmup 1s --requests 1000 --out oracle.json
```
