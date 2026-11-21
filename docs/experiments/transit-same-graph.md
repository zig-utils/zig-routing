# Same-graph transit replay

The reference uses Valhalla 3.9.3 and the native runner opens a bundle
imported from the reference tiles. Both searches receive the ordered
directed edges, fractions, projections and distances produced by Loki.
Both parse the original departure request and costing options.

## Brockton

Extract the Brockton feed into a directory named `brockton` under
`mjolnir.transit_feeds_dir`. Use the [Massachusetts extract][streets]
and [Brockton feed][feed] with these SHA-256 digests.

| Input | SHA-256 |
| --- | --- |
| Massachusetts OSM PBF, 2026-11-19 | `b88dfb2f441661176c7273c33eb5a92d1d5c3ae26f98c4e402731987eaab12f4` |
| Brockton GTFS archive | `68d6c5b8d403ccdc364a6151b577d1702fdadd41e4065bb6af4ba4b6c4ad167c` |
| Seeded 100-request corpus | `342bab612a81f960605690e0929700cdc427f6127b149ba84c7e12956360cc39` |

In the pinned reference image, use a Valhalla configuration with
`mjolnir.hierarchy` and `mjolnir.shortcuts` set to false,
`mjolnir.tile_extract` empty, and `mjolnir.timezone` pointing to the
database from `valhalla_build_timezones`. Set `mjolnir.tile_dir` and
`mjolnir.transit_dir` to separate directories. A build for the original
November 23 corpus needs the converted level-3 tiles created November 20,
2026. The converter anchors its schedule masks to its build date. Keep
those tiles with the fixture for date-exact regression runs. For a newer
feed, choose a service date present in that feed.

```sh
valhalla_ingest_transit -c CONFIG.json
valhalla_convert_transit -c CONFIG.json
valhalla_build_tiles -c CONFIG.json massachusetts.osm.pbf

g++ -std=c++20 -O2 -I/usr/local/include/valhalla/third_party \
  oracle/transit-itinerary-reference.cc -o transit-itinerary-reference -lvalhalla \
  -lprotobuf-lite -lprime_server -lz -l:libcurl.so.4 -l:liblz4.so.1 \
  -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
```

Use the resulting linked tiles from `mjolnir.tile_dir` for both the
reference replay and the native import.

```sh
python3 oracle/transit-itinerary-parity.py prepare brockton.zip 2026-11-23 corpus.tsv
./transit-itinerary-reference CONFIG.json corpus.tsv > reference.jsonl
python3 oracle/transit-same-graph.py translate TILES reference.jsonl cuts.jsonl
zig build -Doptimize=ReleaseFast
zig-out/bin/zr import-valhalla --output BUNDLE TILES
zig-out/bin/zr inspect --verify BUNDLE
zig build check-transit-itineraries -Doptimize=ReleaseFast -- BUNDLE corpus.tsv cuts.jsonl > native.jsonl
python3 oracle/transit-same-graph.py score cuts.jsonl native.jsonl report.json
```

The verified bundle has 1,709,258 nodes and 4,404,822 directed walking
and road edges. Its transit index has 946 platforms, 946 stations,
946 egresses, 933 ride lines, 63,525 departures and 10 service masks.
Each scheduled ride is stored as a line and its departures. Directed
walking connectors remain in the graph with their source access and
geometry.

The 100 requests supplied 506 directed cuts. Valhalla returned 100
itineraries and native returned 97. Three native searches reached the
request arena limit. Forty itineraries matched the routes, ordered stops
and exact timetable instants. Thirty-nine also matched the displayed
boarding times. Case 34 boards the same trip at 21:32:44, but the displays
show 21:32 and 21:33 because the approaches arrive at different times.

The report records both weighted costs and the native price of both fixed
paths. All 97 native paths reproduced their search costs exactly. All 61
Valhalla paths in itinerary discrepancy cases could be replayed. In each
of the 58 cases with both routes, the native route cost less under its
own costing. The report identifies the first rejected step if an engine's
path cannot be replayed. Repricing uses the exact timetable instant. The
trip-leg display rounds the waiting duration and can show a later minute.
These counts describe the shared topology replay.
The independent [itinerary parity gate][gate] still uses its original
threshold.

## Overtaking fixture

Generate two disconnected walking approaches and a GTFS line between
them. Pick a service date on or after conversion. The example uses the
same date as Brockton.

```sh
python3 oracle/transit-same-graph.py fixture FIXTURE 2026-11-23
zig build gurka-pbf -- FIXTURE/street.osm.pbf transit-overtake
```

Point a copy of the flat reference configuration at `FIXTURE/feeds`, a
separate transit directory and a new tile directory. Set
`loki.use_connectivity` to false for the two disconnected approaches.
Run the same ingest, convert and build commands on
`FIXTURE/street.osm.pbf`. Import those tiles and then run the fixture.

```sh
./transit-itinerary-reference FIXTURE_CONFIG.json FIXTURE/overtake.tsv --offers > reference.jsonl
python3 oracle/transit-same-graph.py translate FIXTURE_TILES reference.jsonl cuts.jsonl
zig-out/bin/zr import-valhalla --output FIXTURE_BUNDLE FIXTURE_TILES
zig build check-transit-itineraries -Doptimize=ReleaseFast -- FIXTURE_BUNDLE FIXTURE/overtake.tsv cuts.jsonl > native.jsonl
python3 oracle/transit-same-graph.py check-fixture reference.jsonl native.jsonl
```

Both tables offer trip 1 first at 07:01:45, arriving at 07:21:45. Trip 2
departs at 07:03:45 and arrives at 07:04:45. The reference displays its
selected boarding time as 07:02 and native displays 07:04. The runner
prices both departures from the same starting time and along the same
walking approaches in each engine.

| Engine | First offer cost | Later offer cost | Selected trip |
| --- | ---: | ---: | ---: |
| Valhalla 3.9.3 | 9,482.293 | 1,039.627 | 1 |
| zig-routing | 9,488.126 | 1,045.460 | 2 |

[streets]: https://download.geofabrik.de/north-america/us/massachusetts/massachusetts-261119.osm.pbf
[feed]: https://data.trilliumtransit.com/gtfs/brockton-ma-us/brockton-ma-us.zip
[gate]: https://github.com/zig-utils/zig-routing/issues/190
