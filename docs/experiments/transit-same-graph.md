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

At the initial replay baseline, the 100 requests supplied 506 directed cuts. Valhalla returned 100
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

With the origin and destination costing corrections, 43 itineraries
matched at exact departure times and 42 matched the trip-leg displays.
The native replay priced 93 of the 100 reference paths within 0.01 of
their Valhalla weights. The largest difference was 8.012 cost units.
In the 55 discrepancies with routes from both engines, the native path
cost less under native costing. Its median advantage was 653.947 cost
units. Three native requests still reached the arena limit.

## Request arena

The same 100 requests and 506 directed cuts were replayed under the
original 256 MiB replay arena cap. Before the storage change, each failing
request allocated about 3.5 million 68-byte labels. The records took
236 to 241 MB of the live request arena when allocation failed.

Scheduled search now stores 28-byte labels for ordinary walking and
boarding state. Wide distances and context IDs use sparse storage with
their full precision. The graph supplies the arrival node and the route
unpacker reconstructs walking turns from the same costing call used
during expansion. Fractional endpoints and boarding transitions retain
their exact values. The reverse potential settles within the existing
cost ceiling, which gives the forward search a stronger admissible bound
than the previous 32,768-node stop. With compact labels alone, case 9
still reached the cap. With the stronger bound alone, case 46 still
reached it.

| Case | Peak before | Peak after | Native weighted cost |
| --- | ---: | ---: | ---: |
| 9 | 255.86 MiB | 76.54 MiB | 17,275.842 |
| 35 | 255.85 MiB | 36.88 MiB | 15,152.825 |
| 46 | 249.79 MiB | 136.74 MiB | 19,675.543 |

All 100 searches completed. The 97 previously successful searches
retained their exact weighted costs. Fixed-path replay reproduced all
100 native costs. Across the corpus, the peak fell from 255.86 MiB to
136.74 MiB. The median rose from 2.89 MiB to 6.20 MiB as the reverse
search retained more costs for the forward bound.

The second replay in the same arena made zero backing allocator calls.
In the 100-request 20 ms cancellation trial, the largest observed
deadline overrun was 3.833 microseconds before the change and 0.833
microseconds after it. Three 250 ms trials over the original failing
cases had maxima of 4.042 and 1.250 microseconds respectively. Every
request in those trials stopped at its deadline.

Deferring trip context storage until a boarding passes the cost bound reduced peak request
memory on 42 of the same 100 requests. The largest request fell from 136.74 MiB to 135.34 MiB.
All route steps, weights, and boarding instants were identical across four alternating pairs on
Apple M3 Pro. Median search-only userspace CPU time changed by -0.28%. The second replay used
zero backing allocator calls.

Skipping recurring timezone gap calculations after finding a valid UTC instant preserved
all 100 routes, weights, and boarding instants. With both changes, median search-only userspace
CPU time fell 7.72% against the same baseline on Apple M3 Pro. The four paired reductions ranged
from 3.95% to 11.97%.

Resolving the preceding occurrence of each recurring timezone rule then reduced median userspace
CPU time by 4.71% against the version with both earlier changes. Across eight alternating pairs,
the change ranged from an 8.51% reduction to a 2.23% increase. Every itinerary and peak request
allocation matched the baseline. Recurrence checks covered 81,200 bundled rule boundaries across
one Gregorian cycle and 150,000 synthetic instants, including transitions that cross year boundaries.

```sh
zig build check-transit-itineraries -Doptimize=ReleaseFast -- \
  BUNDLE corpus.tsv cuts.jsonl --measure --repeat 2 > native-measured.jsonl
zig build check-transit-itineraries -Doptimize=ReleaseFast -- \
  BUNDLE corpus.tsv cuts.jsonl --measure --deadline-ms 20 > deadline-measured.jsonl
```

## Pinned costing audit

The audit maps both paths back to the source tiles and checks each
directed movement, endpoint cut, boarding instant, schedule, transfer
and walking limit with the Valhalla 3.9.3 costing models. The audit uses
the traveled fraction at the destination. It records separately when
the stock search would count the rest of the destination edge against
its walking limit.

```sh
python3 oracle/transit-same-graph.py prepare-audit TILES native.jsonl paths.jsonl
./transit-itinerary-reference CONFIG.json corpus.tsv --audit paths.jsonl > audit.jsonl
python3 oracle/transit-same-graph.py score-audit audit.jsonl native.jsonl paths.jsonl audit-report.json --require-verified-cost
```

| Brockton metric | Requests |
| --- | ---: |
| Both paths verified and priced | 100 |
| Stock itinerary match with displayed times | 42 |
| Match with exact boarding instants | 43 |
| Native path cheaper under pinned costing | 66 |
| Native path within 0.01 cost units of stock | 34 |
| Stock path cheaper under pinned costing | 0 |

The cost check requires a complete pinned audit for every path pair. It fails if a path
cannot be audited, the native path differs from the audit input, or the native cost exceeds
the stock path cost by more than 0.01. Stock itinerary and exact boarding matches remain in the
report.

Eleven of the 66 cheaper paths fit within 2,415 m using their final cut
and exceed the limit when the whole destination edge is counted.
Fifty-five are cheaper with no final-edge limit difference. Among the
58 displayed itinerary differences, 47 are in that second group and
11 have the limit difference. The report keeps those access findings
and the strict stock match rate alongside the cost comparison.

The first stock cost difference is at boarding step 29, 29, 53 and 38
in cases 46, 80, 83 and 87 respectively. Each stock increment includes
the 8.011-unit pinned boarding transition. The stock expansion updates
its mode as it iterates through outgoing edges, which can make a
boarding transition depend on an earlier outgoing edge. Case 62 first
differs at step 19, where the stock seconds-of-week calculation rounds
readiness to 70,382 while the epoch clock gives 70,381. Native case 46
first differs at step 52. The prior ride's fractional seconds carry
through the pinned elapsed time, giving 1,361.049 seconds at boarding
readiness. Native arrives at 1,360.706 seconds, so its wait costs one
additional unit for the same scheduled departure.

### Brockton case 0

On directed edge 6057822576026, the pinned search records a permanent
label with cost 2,054.948 and 1,935 m of walking already used. The
verified alternative arrives on the same edge with cost 2,557.914 and
38 m of walking used. Both paths reach their incoming edges under
pinned costing. The remaining walk along the cheaper complete route
is 1,526 m. The permanent label would need 3,461 m and the alternative
needs 1,564 m. The stock search's single label per directed edge keeps
the cheaper prefix and skips subsequent offers to its permanent edge.
Its resulting route costs 4,448.231. The feasible alternative costs
4,187.851. The report finds the same walking-resource conflict in
43 cases with verified cheaper routes.

The overtaking fixture's audit also verifies both departures with
pinned costing. `GetNextDeparture` offers trip 1 first from the same
walking prefix. Trip 2 is feasible and cheaper by 8,442.666 cost
units. The independent 95% stock itinerary gate in #190 still uses
its original threshold.

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
| zig-routing | 9,482.293 | 1,039.627 | 2 |

## Toronto scheduled routes

The Gurka test ports the scheduled paths in Valhalla's `route_trip1` and `route_trip4`
to fixed-date feeds. The native route action boards at 07:00, continues through the
07:03 stop, and arrives at 07:06 on the first request. The second boards at 23:58
and arrives at 00:02 the next day. The tests check ordered stops, trip headsigns,
and leg lengths to the upstream one-metre tolerance. Native total elapsed time
was 0.764 s lower on the first request and 0.720 s lower on the second than the
upstream summary values. [Pinned Gurka scenarios][toronto]

[streets]: https://download.geofabrik.de/north-america/us/massachusetts/massachusetts-261119.osm.pbf
[feed]: https://data.trilliumtransit.com/gtfs/brockton-ma-us/brockton-ma-us.zip
[gate]: https://github.com/zig-utils/zig-routing/issues/190
[toronto]: https://github.com/valhalla/valhalla/blob/3.9.3/test/gurka/test_gtfs.cc#L996-L1103
