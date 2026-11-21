# Isochrone grid pilot

[#164](https://github.com/zig-utils/zig-routing/issues/164) adds the
arrival grid shared by time and distance contours. The pilot measures
grid construction and Dijkstra expansion after location correlation. It
uses the pinned Valhalla 3.9.3 Utrecht PBF and an ARM64 Linux VM on an
Apple M3 Pro. Both runners use the same tiles built with hierarchy and
shortcuts disabled, then imported into the native format.

Each runner warms a request once and times the second run. Five paired
trials alternate the runner order. Median elapsed times follow.

| Request | Valhalla | Native |
| --- | ---: | ---: |
| Auto, 9.1 minutes | 9.326 ms | 10.864 ms |
| Auto, two origins, 2 minutes | 8.594 ms | 10.572 ms |
| Pedestrian, 12 minutes and 1.4 km | 6.542 ms | 6.797 ms |
| Auto, reverse, 1 minute | 6.306 ms | 6.996 ms |
| Median total per trial | 31.029 ms | 35.205 ms |

The 5x target remains open. All 377 in-contour arrival cells in the last
three requests meet the 1% or 5 s tolerance. The first request matches
4,969 of 5,097 cells. Its edge trace shows a native path taking the
tile-local movement from 22355 to 22352. Valhalla rejects the predecessor
chain under a complex turn restriction. Once the importer preserved that rule,
both engines rejected the movement and reached edge 22394 at 76.554 seconds.
[Restriction import follow-up](https://github.com/zig-utils/zig-routing/issues/246).

## Reproduction

Set `mjolnir.hierarchy` and `mjolnir.shortcuts` to `false` in a Valhalla
3.9.3 build config pointing at a fresh tile directory and extract. Use the
Utrecht input from [the oracle manifest](../../oracle/datasets.tsv). Build
the tiles and import the same directory into a native bundle.

```sh
valhalla_build_tiles -c CONFIG.json UTRECHT.osm.pbf
valhalla_build_extract -c CONFIG.json -v
zig build -Doptimize=ReleaseFast
zig-out/bin/zr import-valhalla --output BUNDLE TILE_DIR
```

Set `service_limits.isochrone.max_locations` to at least 2. Save these
requests to `requests.jsonl`.

```jsonl
{"costing":"auto","locations":[{"lat":52.078937,"lon":5.115321}],"contours":[{"time":9.1}]}
{"costing":"auto","locations":[{"lat":52.075911,"lon":5.086633},{"lat":52.109455,"lon":5.128852}],"contours":[{"time":2}]}
{"costing":"pedestrian","locations":[{"lat":52.0903,"lon":5.1111}],"contours":[{"time":12},{"distance":1.4}]}
{"costing":"auto","locations":[{"lat":52.093199,"lon":5.042799}],"contours":[{"time":1}],"reverse":true}
```

Inside the pinned Linux oracle image, compile and run the test reference.
Run the native benchmark on the same Linux platform and CPU.

```sh
g++ -std=c++20 -O2 -I/usr/local/include/valhalla/third_party \
  oracle/isochrone-reference.cc -o isochrone-reference -lvalhalla \
  -lprotobuf-lite -lprime_server -lz -l:libcurl.so.4 -l:liblz4.so.1 \
  -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
./isochrone-reference CONFIG.json requests.jsonl oracle-grid.bin > oracle.tsv
zig build bench-isochrone -Doptimize=ReleaseFast -- BUNDLE requests.jsonl native-grid.bin > native.tsv
```

Each TSV row gives the request index, elapsed nanoseconds, grid columns,
rows, cell size and bounds. The native runner appends the settled and
popped label counts. Each grid file concatenates rows of little-endian
float pairs holding minutes and kilometres. A fourth argument to
`bench-isochrone` writes label traces. The oracle accepts an
optional final TSV path for its label trace. Dumping traces happens
outside the timed expansion.
