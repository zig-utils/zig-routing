# Valhalla oracle

Valhalla 3.9.3 in Docker, used only at development time to check zig-routing's answers byte for
byte and to measure the performance baseline. Nothing here is linked into or shipped with `zr`.

## Requirements

Docker with the Compose plugin. On macOS, Colima works (installed through pantry: `pantry install -g
github.com/abiosoft/colima docker.com/cli`). The scripts find pantry's `docker` even when its bin
directory is not on PATH.

The oracle runs the **linux/amd64** image by default (under emulation on Apple silicon), because
production runs x86-64 and the arm64 build is compiled with fused multiply-add contraction, which
changes last-bit floating point results. Set `ORACLE_PLATFORM=linux/arm64` for native speed when
measuring performance.

## Use

```bash
oracle/up.sh liechtenstein 8102
```

```bash
oracle/down.sh liechtenstein
```

`up.sh` fetches (checksum-verified), builds and serves on demand. `fetch.sh` and `build.sh` can
be run on their own.

| Dataset | Source | Tiles | Disk after build | Peak build memory (sampled) | Build time |
|---|---|---:|---:|---:|---:|
| liechtenstein | upstream `test/data` at tag 3.9.3 + SRTM N47E009 | 5 | 16 MiB | 355 MiB | 16-31 s |
| utrecht | upstream `test/data` at tag 3.9.3 + SRTM N52E005 | 3 | 30 MiB | 528 MiB | 40-47 s |

Measured with six vCPUs and amd64 emulation in Colima. Disk includes the cached inputs, tile
directory and tar extract. Memory is the container's peak cgroup usage, which includes file cache.

The image is pinned by digest in [compose.yaml](compose.yaml). [datasets.tsv](datasets.tsv)
pins PBFs and lists the SHA-256 of each elevation tile, either inline or by reference to a
file under `elevation/`. The build key includes the referenced manifest contents. The
image's `valhalla_build_config` generates both configs with flags in
[build-tiles.sh](build-tiles.sh). The build uses upstream defaults with the inventory's
concurrency of six and the dataset's elevation directory. Fixture servers disable Loki's
connectivity precheck because road networks are clipped at the extract boundaries. The
production profile retains the connectivity precheck, builds the administrative and timezone
databases, and can pass two PBFs to the same tile build. The build date stored in Valhalla
tile headers and tar metadata can differ between builds. Use the same platform when
comparing graphs or exact responses.

### Production datasets

```bash
oracle/up.sh germany 8102
oracle/up.sh us-dach 8103
```

The Germany manifest pins Geofabrik's January 1, 2026 extract and all 107 SRTM cells covered
by the completed local graph tiles. Valhalla 3.9.3 served `/status` and passed `/height` and
auto, pedestrian, and bicycle `/route` checks in Berlin. The same shortest-auto request
received warning 205 in default mode and ran with pruning disabled in opt-in mode.

The US+DACH manifest pins the January 1, 2026 US and DACH Geofabrik extracts and all
1,493 SRTM cells covered by the completed local graph tiles. The two extracts are passed
to a single Valhalla tile build. The pinned image served `/status`, numerical `/height`
results, and auto, pedestrian, and bicycle routes in Berlin, San Francisco, Vienna, and Zurich.
The opt-in profile honored the hierarchy setting on a shortest-auto route in San Francisco.
The initial corpus replay returned 1,000/1,000 successful height requests and 494/500
successful 10 km auto routes, with no transport errors or timeouts.

Measured on native x86-64 Linux with eight vCPUs, 32 GiB RAM, and six build workers:

| Dataset | Graph tiles | Peak intermediate tile files | Peak builder cgroup memory | Dataset directory | Build time |
|---|---:|---:|---:|---:|---:|
| germany | 1,150 | 14.34 GiB | 27.25 GiB | 14.66 GiB | 20m 50s |
| us-dach | 18,630 | 76.87 GiB | 30.03 GiB | 75.58 GiB | 3h 22m 36s |

The dataset directory includes the extracts, elevation, unpacked tiles, and the tile tar.
Intermediate files and container memory were sampled during the build. Container memory
includes file cache. Build time covers graph preparation, construction, and tarring.
Elevation coverage comes from Valhalla's `valhalla_build_elevation` tool on the completed
level 2 graph, including tiles added during final validation and binning.

The US+DACH build ran on a 250 GiB SSD. Peak filesystem usage was 153.27 GiB,
including the staged inputs and other test data on the same volume. Provisioned SSD
performance was increased from 3,000 IOPS and 125 MiB/s to 5,000 IOPS and 275 MiB/s
during hierarchy construction. The resulting tile archive was 24.97 GiB.

### Hierarchy pruning

Both server modes share a single graph. The default retains Valhalla's zero-metre
`service_limits.max_distance_disable_hierarchy_culling` limit. The `unpruned` mode raises it
to 5,000,000 metres. For motorized costing, send
`costing_options.<costing>.disable_hierarchy_pruning: true` to opt in. Valhalla 3.9.3 sums the
straight-line distances between route locations and checks each source-target pair for matrix
requests. Above the configured limit, Valhalla ignores the option and returns warning 205.
Bicycle and pedestrian already run without this pruning. See Valhalla 3.9.3's
[distance check](https://github.com/valhalla/valhalla/blob/3.9.3/src/loki/worker.cc#L476-L521).

The two modes can run side by side on different local ports:

```bash
oracle/up.sh utrecht 8103
oracle/up.sh utrecht 8104 unpruned
bun oracle/check-pruning.ts http://127.0.0.1:8103 http://127.0.0.1:8104
oracle/down.sh utrecht unpruned
oracle/down.sh utrecht
```

The check sends the same `shortest: true` auto request to both servers. It verifies warning 205
on the default server and a different, cheaper route on the opt-in server.

## Checks

### Costing parity (gate A)

Build `zr` in ReleaseFast and generate the route corpora. Run the gate against
a pinned extract with the following commands.

```bash
zig build -Doptimize=ReleaseFast
bun tools/corpus/generate.ts
oracle/costing-parity.sh liechtenstein bench/results/costing-liechtenstein.json
```

The runner imports the oracle's local tiles into a native bundle and gives
Valhalla the same level-2 graph. It samples admissible traversal and turn
calls across 64 legal-range profiles per mode and the exact production
profiles from the corpus. It also requests routes for the production
profiles and compares their edge-by-edge recosts at the oracle's fractions.
The C++ sampler links the pinned Valhalla library inside the oracle container.

The JSON report carries counts and maximum relative errors by cost call and
profile. Gate A requires 10 million calls per mode, a path recost for each
mode, relative error of at most `1e-5` per call and `1e-4` per path. The
runner keeps the reference file and diagnostic log under `bench/results/`.
Each failing call lists the options and both native and Valhalla edge IDs.

```bash
zig-out/bin/zr parity costing BUNDLE costs.bin --out report.json
```

For auto, bus and taxi, run the motor gate with the same pinned tile set.
The profiles exercise HOV-2, HOV-3 and high-occupancy toll access through
auto. They also vary fixed and top speeds, costs and preferences across
their legal ranges.

```bash
oracle/costing-parity.sh --motor utrecht bench/results/costing-motor-utrecht.json
```

Utrecht and Liechtenstein each used 68 profiles and 3.4 million samples
of each call type per mode. All 40.8 million forward and reverse
transition samples and 48 path recosts matched exactly. The largest
relative error across 20.4 million edge cost samples was `3.3e-7`.

The graph retains one quantized heading byte per directed edge. Imported
tiles preserve Valhalla's stored bearings for exact turn duration. Native
builds use the same bearings for maneuver type and turn duration. Older
bundles can recover bearings from their directed shapes.

Run the truck gate with:

```bash
oracle/costing-parity.sh --truck utrecht bench/results/costing-truck-utrecht.json
oracle/costing-parity.sh --truck liechtenstein bench/results/costing-truck-liechtenstein.json
```

Each extract supplied 69 profiles and 3.45 million samples of each call type.
The gate used compiled tables for 67 profiles per extract and the raw
formula for the two profiles with signed weights.
All 13.8 million forward and reverse transitions and 15 fixed-path recosts
matched exactly. The maximum relative error across 6.9 million edge costs
was `3.35e-7`.

The samples include the upstream minimum `low_class_factor` of `0.1`. With
`use_tolls: 1`, 24,533 of 50,000 Utrecht samples had negative weights.
The raw truck evaluator preserves these values for parity. Exact metric
compilation requires nonnegative class factors under I3. See
[#128](https://github.com/zig-utils/zig-routing/issues/128).

To measure the auto relaxation loop with the production cost functions:

```bash
zig build bench-search -Doptimize=ReleaseFast -- "$bundle" 32 100000 82 --auto
```

On an Apple M3 Pro, 12 alternating baseline and candidate pairs on the
imported Utrecht bundle settled 866,133 labels per run, with identical settle
and pop counts per source. Median elapsed time was 167.70 ns per settled label
at `3a1e0b2` and 167.48 ns with truck costing present. The median paired change
was +0.36%.

Run Gate A for motorcycle and motor scooter costing with:

```bash
oracle/costing-parity.sh --motorcycle utrecht bench/results/costing-motorcycle-utrecht.json
oracle/costing-parity.sh --motorcycle liechtenstein bench/results/costing-motorcycle-liechtenstein.json
```

Each extract contributed 68 profiles and 3.4 million samples of each call
type per mode. All 27.2 million forward and reverse transitions and 26
fixed-path recosts matched exactly. The largest relative error across
13.6 million edge costs was `3.57e-7`.

The scooter oracle profiles keep the grade-adjusted speed within the pinned
Valhalla speed table. Native tests cover the full fixed-speed range and its
downhill maximum of 315 km/h using the same seconds-per-metre formula.

### Transit costing

The Valhalla sampler covers bus, rail and neutral edge weights, boarding
transitions, and both transfer cost methods. It checks the parsed transit
options alongside the pedestrian mode factor and walking distance limits.
The Zig checker compares cost and elapsed seconds within a relative error
of `1e-5`.

```bash
mkdir -p bench/results/transit-costing
repo_dir=$PWD
sample_dir=$repo_dir/bench/results/transit-costing
docker run --rm \
  --mount "type=bind,source=$repo_dir/oracle/transit-costing-reference.cc,target=/reference.cc,readonly" \
  --mount "type=bind,source=$sample_dir,target=/work" \
  --entrypoint bash ghcr.io/valhalla/valhalla:3.9.3 -euc '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      g++ libboost-dev libprotobuf-dev rapidjson-dev zlib1g-dev
    g++ -std=c++20 -O2 -Wno-psabi -I/usr/local/include/valhalla/third_party \
      /reference.cc -o /work/reference -lvalhalla -lprotobuf-lite -lprime_server -lz \
      -l:libcurl.so.4 -l:liblz4.so.1 -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
    /work/reference > /work/costs.jsonl
  '
zig build transit-costing-parity -Doptimize=ReleaseFast -- "$sample_dir/costs.jsonl"
```

The ARM64 oracle run produced 4,098 option samples and 16,392 cost calls.
The maximum relative error for these calls was `1.184e-7`.

### Scheduled transit itineraries

Use the same GTFS archive and street extract to build the native bundle
and the Valhalla 3.9.3 tiles. For Valhalla, extract the feed under a
directory named `brockton` in `mjolnir.transit_feeds_dir`, then run
`valhalla_ingest_transit`, `valhalla_convert_transit`, and
`valhalla_build_tiles` with the same configuration. Start the oracle
service on the resulting tiles.

```bash
python3 oracle/transit-itinerary-parity.py prepare "$feed_zip" 2026-11-23 corpus.tsv
python3 oracle/transit-itinerary-parity.py fetch "$oracle_url" corpus.tsv reference.jsonl
zig build check-tripleg -- "$native_bundle" corpus.tsv 100 --multimodal > native.jsonl
python3 oracle/transit-itinerary-parity.py score brockton reference.jsonl native.jsonl
```

The scorer compares the ordered ride lines, the complete stop sequence
of each ride, and the boarding time at the response's minute precision.
It counts oracle and native errors separately. The default threshold is
95%. Pass `--short-walk` to `prepare` for the second corpus with a 300 m
access and egress limit, a 150 m transfer limit and equal bus and rail
preferences.

The default replay returned 97 native routes out of 100. It matched
25 sequences of lines and stops and 22 sequences including boarding
time. The streets were built independently from the same PBF, so the
comparison includes street connectivity and correlation differences.
For the fixed-cut replay using shared streets and timetables, see
[same-graph transit replay](../docs/experiments/transit-same-graph.md).
[Issue #190](https://github.com/zig-utils/zig-routing/issues/190) ·
[Issue #249](https://github.com/zig-utils/zig-routing/issues/249)

Run the same requests with `--multimodal --deadline-ms 20` to measure
cancellation after preloading the graph pages. The output gives elapsed
time and duration after expiry in nanoseconds. Across 300 requests with
2 ms, 20 ms and 100 ms budgets, the largest overrun was 0.954 ms.

### Transit availability

`/transit_available` checks the quarter-degree transit tiles that meet
each location's radius box. The native service indexes the platforms
referenced by scheduled lines when it opens a bundle. A road-only
bundle returns `istransit: false` for every valid location.

```bash
python3 oracle/transit-available-parity.py "$oracle_url" "$native_url" "$road_only_url"
```

Use the Brockton oracle and native bundles from the itinerary check,
plus a native road-only bundle. The runner compares response bytes
for seeded locations, radius and tile boundaries, and validation
errors. It also checks the road-only response and times 25 batches
through the native HTTP action.

The Brockton run matched all 1,020 locations byte for byte, including
365 positive and 655 negative results. The road-only bundle returned
1,020 negative results. Median HTTP time was 1.046 microseconds per
location and the slowest batch averaged 1.130 microseconds per location.

### Timed route optimality (gate B)

```bash
oracle/costing-parity.sh --timed liechtenstein bench/results/timed-liechtenstein.json
oracle/costing-parity.sh --timed utrecht bench/results/timed-utrecht.json
```

The runner builds a complete local graph for each pinned extract with
Valhalla's hierarchy and shortcuts disabled. It selects eight auto requests
and adds morning and evening departures, an arrival time, and an invariant
time. Both searches use the same directed endpoint edges and fractional cuts.
The shared fixed-path recost walks both routes' directed edges and cuts with
the request clock before comparing weighted costs. Gate B requires the native
route to cost at most as much as the replay of the oracle path.

All 64 routes met Gate B with zero excess cost. In the two pinned extracts
the timed paths also matched all 64 static paths. Gurka fixtures cover changes
from populated speed layers and timed restrictions, waiting at break stops,
and local waypoint times across a timezone boundary and a DST transition.

### Destination-only, private access and not-thru routes

```bash
oracle/costing-parity.sh --access access-regions bench/results/access-regions.json
```

The Gurka fixture tests destinations on private roads, the default penalty
for entering a destination-only road, a private gate, and a turn restriction
that requires travelling through a not-thru entrance and leaving by the
same road. The runner compares both hierarchy settings on the same flat
fixture. Native search uses the oracle's endpoint cuts and completes every
case on its first search.

Gate B passed all 18 comparisons, with nine routes per hierarchy setting.
Seven routes in each setting had the same directed edges and endpoint cuts.
The remaining two were the same crossing in opposite directions with
`destination_only_penalty: 0`. Native search used the restricted shortcut
at weighted costs of 162.89 in both directions. Valhalla's first pass chose
the public detour through a private gate at costs of 689.86 and 680.86.
These Gate D differences are due to destination-only pruning. Toggling
hierarchy pruning left the two differences unchanged.

On the stock Utrecht graph, the hierarchy control route changed shape and
weighted cost from 10,107.671 to 10,090.671 when Valhalla accepted the
pruning opt-out. [Hierarchy check](#hierarchy-pruning)

### Speed resolution

Synthetic overlays exercise live coverage and the one-hour fade, predicted
five-minute buckets, and the strict 07:00 to 19:00 interval for constrained
flow. Tests check the selected source bits, closure state, and the truck cap
on the final traversal speed. The resolver uses an empty provider by default.

Native builds and imports write one upper-speed byte per directed edge in
`lb_speeds.bin`. This accounts for the edge's stored speeds and future
overlays up to 252 km/h. The reader derives the same bound for older bundles
and checks stored bounds when opening new ones.

### OSM tag parity

CI compares the normal build tag transform against compressed NDJSON goldens for the
Liechtenstein and Utrecht extracts pinned in [datasets.tsv](datasets.tsv). It also checks a
Gurka fixture with directional limits, an HOV lane, and a cash-only toll booth. To compare
the extracts:

```bash
zig build -Doptimize=ReleaseFast
oracle/tag-goldens.sh compare
```

To regenerate a golden, use a clean Valhalla 3.9.3 checkout at
`5c7f918e61306521d79cc4496d40c19c5305fa4b`, Docker, and a host C++20 compiler for the test-only
`OSMWay` artifact reader. The generator uses the pinned image in [compose.yaml](compose.yaml).
Pass the dataset name or the path to a local country PBF. The script leaves disk-backed parser
artifacts in `bench/results/` by default.

```bash
oracle/tag-goldens.sh generate valhalla-3.9.3 liechtenstein oracle/tag-goldens/liechtenstein.jsonl.gz
oracle/tag-goldens.sh generate valhalla-3.9.3 utrecht oracle/tag-goldens/utrecht.jsonl.gz
zig build gurka-pbf -- bench/results/motor-vehicle.osm.pbf motor-vehicle
oracle/tag-goldens.sh generate valhalla-3.9.3 bench/results/motor-vehicle.osm.pbf oracle/tag-goldens/motor-vehicle.jsonl.gz
oracle/tag-goldens.sh generate valhalla-3.9.3 country.osm.pbf bench/results/country.jsonl.gz
zig-out/bin/zr tags dump country.osm.pbf | python3 oracle/tag-compare.py bench/results/country.jsonl.gz --keep 10
```

`zr tags dump` writes one record per OSM node and way in PBF order. Each record has its OSM ID,
kind, input shape eligibility, tag selection, and normalized attributes. A node with default
attributes has a null attribute object. For dropped ways and ways that fail Valhalla's input shape
filter, the attribute object is also null. The filter excludes ways with fewer than two references
and closed ways tagged `building`, `landuse`, `leisure`, or `natural`.

For regeneration, `zr tags dump --raw` supplies source tags. The oracle runs Valhalla's unmodified
`ways_proc` and `nodes_proc` under LuaJIT for every record. Way fields finalized in C++ come from
`valhalla_build_tiles --end parseways`. The parser enables construction, platforms, driveways,
pedestrian areas, and alternate names to exercise those fields. It disables inferred turn channels
to compare the explicit tag. The supplemental country speed label, bridge name, international cycle
network, MTB scales, foot designation, step count, trail visibility, and tactile paving are
projected from the original OSM tags because Valhalla has no corresponding parser fields.
Motor limits come from the normalized Lua tags and use the parser's float-to-integer
conversion. The direction in the dump refers to the original OSM way order.

The comparator reports a count and up to `--keep` OSM IDs for each differing field. Only
`way.attributes.use` with Valhalla `9` (`culdesac`) and Zig `0` (`road`) is allowed. Valhalla's
`clarify_and_fix` geometry pass changes the use from road after tag parsing. The golden covers
the tag transform before that geometry pass. The checked-in extracts have 3 such ways in
Liechtenstein and 34 in Utrecht.

### Admin assignments

`zr build` stitches the administrative relations in its OSM input and packs
their polygons into a sparse grid. Point queries use the clipped polygons.
Node assignments also follow Valhalla's tile rule when a local tile intersects
a single eligible admin. A state carries the country whose geometry covers it.

Create the oracle database with `valhalla_build_admins` in the pinned image,
using the same PBF and the path named by `mjolnir.admin`. Build local tiles
with that configuration using `valhalla_build_tiles --end build` before
running the comparison.

```bash
zig-out/bin/zr build extract.osm.pbf --output native-bundle
python3 oracle/compare-admins.py native-bundle valhalla-tile-dir
```

The comparator matches graph coordinates within two E7 units per axis. It
compares both country and state names and ISO codes. These comparisons applied
no border exclusions.

| Input | Matched nodes | Same admin | Nodes with an admin |
| --- | ---: | ---: | ---: |
| Liechtenstein | 6,280 | 6,280 | 6,280 |
| Utrecht | 30,638 | 30,638 | 0 |
| Gurka admin fixture | 8 | 8 | 8 |

Utrecht's state relation has a missing member in the pinned extract. The Gurka
fixture exercises a complete state, a separate island, an enclave occupying a
country's hole, and an unclosed boundary.

### Country access parity

Build the Valhalla reference through `enhance`, then run its `validate` stage on
those local tiles to set border flags. Keeping the local graph makes it possible
to compare trunks, cycleways and their opposing directions together.

```bash
valhalla_build_tiles -c valhalla.json --end enhance input.osm.pbf
valhalla_build_tiles -c valhalla.json --start validate --end validate input.osm.pbf
zig-out/bin/zr import-valhalla --output reference-bundle valhalla-tile-dir/2
python3 oracle/compare-access.py native-bundle reference-bundle
```

Generate the two-country input with `zig build gurka-pbf -- input.osm.pbf country-access`.
Use the same input for both builders. For the original Amsterdam test, Valhalla's
configuration points to the `netherlands_admin.sqlite` from the pinned checkout.
Generate the equivalent OSM boundary input from that test database and pass it
alongside `test/data/amsterdam.osm.pbf` to the native builder.

```bash
python3 oracle/dutch-admin-fixture.py valhalla-3.9.3/test/data/netherlands_admin.sqlite netherlands.osm.pbf
zig-out/bin/zr build --output native-bundle valhalla-3.9.3/test/data/amsterdam.osm.pbf netherlands.osm.pbf
```

The comparator pairs edges by OSM way ID and ordered shape. It accepts a unique
shape match within one E6 unit per axis. It compares the forward and reverse
masks, country-crossing flag and source node's driving side exactly.

| Input | Matching directed edges | Paired with E6 tolerance | Differences |
| --- | ---: | ---: | ---: |
| Netherlands-Belgium Gurka fixture | 10 | 0 | 0 |
| Pinned Amsterdam fixture | 178 | 42 | 0 |
| Liechtenstein | 15,760 | 4,546 | 0 |
| Utrecht | 85,336 | 12,650 | 0 |
| Luxembourg 260101 | 475,332 | 114,448 | 0 |

Country overrides were enabled for all comparisons. Utrecht includes the
70 motorroad arcs whose access depends on the reclassified link class.
The Luxembourg comparison leaves four directions unpaired because their
short shapes have multiple possible matches at E6 precision.

With admin lookup enabled, both builders use left for unassigned Utrecht
nodes. The driving-side fixture verifies eight directed arcs with lookup
enabled and disabled. It also compares the directed shoulder and cycle
lane fields. Generate it with
`zig build gurka-pbf -- input.osm.pbf driving-side`.

The fixtures derive from OpenStreetMap data © OpenStreetMap contributors, under the
[Open Database License](https://www.openstreetmap.org/copyright).

### Node timezones

Use the pinned image's `valhalla_build_timezones` to build its reference
database. Point `mjolnir.timezone` at that database and build local tiles
with `valhalla_build_tiles --end build`. Build the native bundle from the
same PBF and the 2026f boundary release as described in the
[timezone design](../docs/design/timezones.md).

```bash
python3 oracle/compare-timezones.py native-bundle valhalla-tile-dir
zig-out/bin/zr inspect --verify native-bundle
```

The comparison reads both the nine-bit zone index and its extension bit.
Node coordinates pair within two E7 units per axis.

| Input | Paired nodes | Matching timezone IDs |
| --- | ---: | ---: |
| Liechtenstein | 6,280 | 6,280 |
| Utrecht | 30,638 | 30,638 |

### Date and time request validation

Run both services with elevation data for the date and time error corpus.
It covers missing values for the three explicit time modes, range and syntax
errors, and unsupported modes for transit and isochrones. The height requests
also check that accepted dates reach Valhalla's missing-shape error.

```bash
zig-out/bin/zr diff "$native_url" "$valhalla_url" --corpus oracle/corpora/date-time-errors.txt
```

All 24 requests match the stock service's status, JSON schema and error code.

### Simple turn restrictions

The build resolves ordinary single-node restrictions into the existing turn
byte. It preserves Valhalla's first-match rule and eight-exit mask even when
native local edge indices differ. The reader exposes sparse mode masks for
tagged mode restrictions and movements across aliases for the P5.10 checks.
The build report counts parsed and resolved relations, deferred forms,
missing members and truncated masks.

Build the same input PBF with both builders. For the reference, run
`valhalla_build_tiles --end enhance`, then run its `validate` stage to
set the opposing indices before importing the local tiles.

```bash
zig build gurka-pbf -- fixture.osm.pbf simple-turns
zig-out/bin/zr import-valhalla --output reference-bundle valhalla-tile-dir/2
python3 oracle/compare-turn-restrictions.py native-bundle reference-bundle
```

| Input | Paired directed edges | Turn movements | Restricted movements matched |
| --- | ---: | ---: | ---: |
| Gurka fixture | 22 | 50 | 3 |
| Liechtenstein | 15,760 | 44,574 | 2 |
| Utrecht | 85,336 | 261,602 | 296 |

### Complex turn restrictions

The native build writes `restr.bin` when it resolves one or more forbidden
via-way sequences. For an only restriction, each wrong exit from a mandatory
prefix becomes a forbidden sequence. Both search directions use the same
rules in their respective travel order. The search keeps distinct labels
for distinct prefixes that reach the same edge.

Generate the two fixtures with the native Gurka tool. Build local Valhalla
tiles from the same PBF with hierarchy and shortcuts disabled. Run the
reference builder through `enhance`, then run its `restrictions` stage.

```bash
zig build gurka-pbf -- only.osm.pbf only-turns
zig build gurka-pbf -- multi-via.osm.pbf multi-via-turns
```

The via-way rules match the directed edge sequences and mode masks in the
pinned reference tiles after pairing by OSM way and directed geometry.

| Input | Forward sequences matched | Reverse sequences matched |
| --- | ---: | ---: |
| Gurka only turn fixture | 6 | 6 |
| Gurka split multi-via fixture | 1 | 1 |
| Liechtenstein | 0 | 0 |
| Utrecht | 3 | 3 |

The test suite ports the three upstream only-restriction cases and checks
384 seeded searches against an independently expanded state graph. It also
checks partial-edge endpoints and restriction state across junction aliases.

On the restriction-free Luxembourg bundle, run the search benchmark on the
baseline and candidate with the same sources and label limit.

```bash
zig build bench-search -Doptimize=ReleaseFast -- "$bundle" 32 125000 82
```

On an Apple M3 Pro, eight alternating baseline and candidate pairs gave
median paired throughput changes of +0.90% for pedestrian and -1.45% for
the motor stub. Both settled and popped the same number of labels at every
source. Individual timings varied. The loop for bundles without an automaton
is compiled without restriction checks.

### Timed access and turn restrictions

The two fixtures port the upstream conditional access and timed turn cases.
They exercise bicycle, pedestrian and motor access, destination-only edges,
missing request time, and transitions in both search directions. The condition
parser tests compare 238 packed values from 161 upstream test and extract
inputs against Valhalla 3.9.3. The calendar evaluator also passes the 135
local date and time assertions in the upstream restriction test.

```bash
zig build gurka-pbf -- timed-access.osm.pbf timed-access
zig build gurka-pbf -- timed-turns.osm.pbf timed-turns
zig build test
```

Build the same PBFs through the reference `restrictions` stage with hierarchy
and shortcuts disabled. Pair directed edges by OSM way and directed geometry,
then compare the type, mode mask, packed condition and destination exemption.
For turns, compare each sequence and its condition in each search direction.

| Input | Timed access records matched | Forward timed turns matched | Reverse timed turns matched |
| --- | ---: | ---: | ---: |
| Gurka timed access fixture | 300 | 0 | 0 |
| Gurka timed turn fixture | 0 | 1 | 1 |
| Utrecht | 10 | 0 | 0 |
| Luxembourg | 437 | 0 | 0 |

The pinned builder emits a timed sequence for a conditional via-node turn and
an ordinary sequence for a via-way relation with the same annotation. The
native builder preserves both representations. The tests also exercise a timed
automaton output reached through a failure link.

The same-graph importer reads both direction-specific restriction sections and
the sorted access records. To replay routes against those records, pass a TSV
output path after `multi-via-turns`, `timed-turns`, `timed-access`, or `timed-access-detour`
when running `zig build gurka-pbf`. Build the fixtures with hierarchy and
shortcuts disabled and point `mjolnir.timezone` at the oracle timezone database
with ocean zones. Run `tripleg-reference` on the TSV, import those same tiles,
then run `zig build check-tripleg -- BUNDLE ROUTES.tsv 4`. The requests cover
depart-at and arrive-by search, distinct approaches to a multi-via restriction,
and active and inactive turn and access conditions.

In the `timed-access` fixture, both searches reject the R-to-U request
at 06:00 on March 9 and use RS, ST and TU at 08:00 on January 12, for
both departure and arrival times. Reverse expansion checks the dead-end
flag on the edge that enters the junction in search order. The flag at U
had also allowed a reversal at T when ST was closed.

### Location, polygon and closure exclusions

Replay the exclusion validation corpus against the native service and
Valhalla 3.9.3 with the default exclusion limits.

```bash
zig-out/bin/zr diff "$native_url" "$valhalla_url" --corpus oracle/corpora/exclusions-errors.txt
```

All 13 requests match the reference HTTP status and error body, including the
OSRM response. The graph tests cover detours, fractional origin and destination
cuts, and directional closure filtering with an in-memory traffic policy.
Search marks excluded edges in its status pages before relaxation and retains
the excluded fractions for partial-edge endpoints.
Four Utrecht rings selected the same directed edges as the reference after
pairing by OSM way and directed geometry. The sets contained 6,370, 1,070, 62
and 1,784 edges.

Run the exclusion budget check against a native Utrecht bundle.

```bash
zig build bench-exclusions -Doptimize=ReleaseFast -- "$bundle" 5.12 52.09
```

The check parses, validates and resolves a 100-vertex ring. On an Apple M3 Pro
it excluded 6,370 directed edges. Across 32 requests, the median was 1.86 ms
and the maximum was 2.12 ms against a 50 ms deadline. There were zero heap
calls after warm-up.

### Way splitting and edge counts

```bash
mkdir -p bench/results
zig build check-edges -- oracle/data/liechtenstein/extract.osm.pbf bench/results 4
zig build check-edges -- oracle/data/utrecht/extract.osm.pbf bench/results 4
```

The check counts distinct emitted endpoints and one edge per segment in OSM way orientation. The
Valhalla comparison uses level-2 tile headers after `valhalla_build_tiles --end build` with the
default oracle options and the same PBFs. Each segment contributes two directed-edge records there.

| Extract | Zig nodes | Zig edges | Oracle base level-2 nodes | Oracle base level-2 directed edges | Oracle final level-2 nodes | Oracle final level-2 directed edges |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Liechtenstein | 6,280 | 7,880 | 6,280 | 15,760 | 6,090 | 13,938 |
| Utrecht | 30,638 | 42,668 | 30,638 | 85,336 | 28,906 | 75,658 |

The base comparison has zero allowed count differences. For the final level-2 totals, the
allow-list is the measured change at Valhalla's hierarchy stage. It moved 190 nodes and 1,822
directed edges out of level 2 in Liechtenstein, and 1,732 nodes and 9,678 directed edges in Utrecht.
The counts were unchanged after the filter stage and again from hierarchy through validation.

The splitter counts missing references and skips the entire unresolved way, as Valhalla does.
It counts and omits same-node edges. Exact overlapping shapes with the same endpoint IDs are
counted in either orientation and retained. Edges between distinct nodes at identical coordinates
are retained with their measured zero length. Valhalla applies its minimum stored length during
directed-edge assembly.

### CSR assembly and warm opens

```bash
work=$(mktemp -d)
zig build check-assembly -- oracle/data/liechtenstein/extract.osm.pbf "$work/liechtenstein" "$work" 4 right
zig build check-assembly -- oracle/data/utrecht/extract.osm.pbf "$work/utrecht" "$work" 4 right
```

The check assembles a bundle, verifies every section checksum and checks every directed edge
against its opposing edge. It reports the directed edges per second for the CSR assembly,
validation and section writing, plus peak RSS for the whole build. It then times 32 warm opens
and requires each to finish in under 50 ms. CI runs both extracts.

ReleaseFast on an Apple M3 Pro with four workers produced these results from the pinned PBFs.

| Extract | Nodes | Directed edges | Assembly edges/s | Peak RSS | Slowest warm open | Validation errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Liechtenstein | 6,280 | 15,760 | 2.89 million | 57.0 MiB | 0.096 ms | 0 |
| Utrecht | 30,638 | 85,336 | 5.80 million | 85.5 MiB | 0.149 ms | 0 |

The assembler assigns provisional IDs in segment encounter order and groups outgoing arcs by
final source node. It retains up to 32 arcs at each node. Higher-degree junctions use co-located aliases
linked by zero-length arcs, with slots reserved at both ends of each link. The class table marks
these arcs explicitly. All real segments use Valhalla's minimum stored length of one metre.

### Germany build reproducibility

The January 1, 2026 Germany extract and its 107 pinned SRTM tiles produced the same
26 section SHA-256 hashes on macOS ARM64 with ten workers and Linux x86-64 with eight
workers. Both ReleaseFast builds verified 23,098,100 nodes and 58,764,002 directed edges
with dataset UUID `5824147f09d28d8f8c9cf34cf92feb6e` and Hilbert ordering hash
`299c120d94338f39`. The builder source was identical at `68e78f7` and `ccbde15`,
and both hosts used Zig `0.17.0-dev.1857+3c46da14d`.
[Linux section hashes](https://github.com/zig-utils/zig-routing/issues/109#issuecomment-7083762215) ·
[macOS section hashes](https://github.com/zig-utils/zig-routing/issues/109#issuecomment-7083897830)

```bash
oracle/fetch.sh germany
zig build -Doptimize=ReleaseFast
work=$(mktemp -d)
zig-out/bin/zr build oracle/data/germany/extract.osm.pbf --dem oracle/data/germany/elevation \
  --output "$work/bundle" --work-dir "$work/stages" --threads 8
zig-out/bin/zr inspect --verify "$work/bundle"
(cd "$work/bundle" && shasum -a 256 *.bin | LC_ALL=C sort -k2 | shasum -a 256)
```

The sorted hash list has SHA-256
`5de17039bb10e65fbc70dfe0e1d374ab95c6dbb798435a1be2735545df529ee6`.

### Turn tables

Each node's `turn_off` selects a dense matrix in `turns.bin`. The incoming row uses the
opposing arc's local index at the junction. Each byte stores the Valhalla turn type in
bits 0-2, initial stop impact in bits 3-5, and shared-name consistency in bit 6.
Bit 7 is reserved for turn restrictions. The builder samples the shape close to the
junction and quantizes the bearing as Valhalla does. It compares the indexed street names
and refs. Country-specific base names and language filtering require admin data.

The assembler interns complete matrices by their bytes. This preserves direct row access
and gives larger graphs more opportunities for reuse. The budget counts the section payload,
excluding the fixed v1 header and alignment padding.

| Extract | Nodes | Distinct matrices | Pool bytes | Bytes/node |
| --- | ---: | ---: | ---: | ---: |
| Liechtenstein | 6,280 | 1,370 | 14,621 | 2.328 |
| Utrecht | 30,638 | 4,259 | 54,387 | 1.775 |
| Luxembourg 2026-01-01 | 187,650 | 11,819 | 149,451 | 0.796 |

CI verifies the [Geofabrik Luxembourg extract](https://download.geofabrik.de/europe/luxembourg.html)
against SHA-256 `d8f3e1dabb4d9d5489500c35432eb393089c32222cfff8cf50706852f0696a80` and runs the
country budget with `zig build check-assembly -Doptimize=ReleaseFast -- INPUT.osm.pbf OUTPUT_BUNDLE SCRATCH_DIR 4 right --sub-byte-turns`.

### Cold graph data

`cold_idx.bin` stores one `u32` per directed edge. Its low 31 bits identify the undirected
record and its high bit reverses the OSM-order shape. Within `cold.bin`, a directory groups
contiguous record IDs in chunks of up to 256. The builder assigns IDs in order of first
encounter in the CSR, so the records follow local adjacency in the assembled graph.

Each record holds the 64-bit OSM way ID, encoded shape length and vertex count, the
mean-elevation slot, speed limit, and up to 255 references into a shared string table.
Shapes use E7 coordinate deltas with zigzag varints. The elevation slot starts at Valhalla's
missing-data value, -500 m. Names and route refs borrow mapped bytes. Shape decoding writes
in travel order into the caller's arena. Synthetic alias links have two coincident vertices
and use way ID zero.

An optional trailer holds static vehicle limits as integer centimetres, hundredths of
the local ton, axle counts, and a hazmat allow flag. General and directional values
can coexist in one record. The edge class carries the affected mode mask, and
`EdgeHot.cls.cold_checks` indicates when that direction has limits to read.

The assembly check verifies each opposing pair's cold index and shape endpoints, and reads
every name reference. `cold_bytes_per_directed_edge` includes both cold section payloads,
including their directories and strings. It excludes each section's fixed header and padding.
`edges_per_second` measures the hot topology and turn-table stage. `elapsed_ns` covers
PBF decoding and all writes through bundle commit.

| Extract | Undirected records | Total cold payload bytes | Bytes per directed edge |
| --- | ---: | ---: | ---: |
| Liechtenstein | 7,880 | 607,780 | 38.56 |
| Utrecht | 42,668 | 2,390,111 | 28.01 |
| Luxembourg 2026-01-01 | 237,668 | 15,006,731 | 31.57 |

### Edge elevation

`check-assembly` takes `--dem DIR` for Valhalla-layout HGT tiles or `--dem-pack FILE`
for a `zr dem pack` archive. The builder groups undirected edges by their starting DEM
tile and processes ranges in parallel. Each worker keeps a local sampler. Grading uses
Valhalla's stored E6 shape precision, 60 m spherical postings and final endpoint. The
bundle's cold shapes retain all E7 coordinates. Weighted grades are directional and
the mean elevation uses Valhalla's 2 m bins. Max slopes are stored in `slopes.bin`
as two 5-bit values per directed edge. Edges shorter than 10 m keep flat grades and
slopes and still get a mean elevation. Bridges, tunnels and ferries use endpoint
interpolation with Valhalla's grade and slope clamps.

The pinned Liechtenstein DEM covered all 7,880 edges and 31,013 grade postings.
With both builds running on Linux x86-64, the Valhalla 3.9.3 `/locate` comparison
matched weighted grade, both max slopes and mean elevation on all 2,864 distinct
directed edges returned for 1,200 queries at middle-segment midpoints, with seed 64.
The match keys use the OSM way ID
and the complete travel-direction shape at oracle precision. The sample covers
1,957 non-flat grades and 66 bridge or tunnel directions.

The build reports `elevation.dem_configured` and per-edge and per-posting coverage.
With no DEM configured, Liechtenstein had 7,880 flat edges and zero postings.
An empty DEM directory reported 7,880 missing edges and kept the same grades and
mean-elevation slots. In a partial tile, grade intervals with a missing endpoint
contribute zero. For an interpolated edge, either missing endpoint keeps the grade flat.

### Graph enhancement

The build computes node density in Valhalla's quarter-degree tile frames, with a
2 km reference radius, E7 grid cells, latitude scaling and a 4-bit result. Each edge
gets the integer average of its endpoints' densities. Geometry-dependent cul-de-sac
classification happens before the road lengths go into the density grid. The tag
goldens continue to cover the preceding tag transform.

Nodes store regular, false, dead-end or fork intersection types. Real edges inherit
the dead-end flag from their destination. Low-class edges use Valhalla's not-thru
walk with its 256-expansion limit and local order. The walk uses a scratch ordering
and the CSR edge indices stay in segment encounter order. Co-located aliases contribute
to their logical junction and synthetic connectors carry no dead-end or not-thru flag.
With admin lookup enabled, the admin region supplies the driving side.
Unassigned nodes use Valhalla's left fallback, with an optional native
`--drive-side` override. With `mjolnir.data_processing.use_admin_db` set to
`false`, ways use `driving_side` and untagged ways use the right fallback
or the explicit build option. A junction takes the side of the last real
edge in Valhalla's incident order. Directed shoulders and cycle lanes use
the source side. Build checkpoints retain the lookup mode and fallback.
The updated build identity requires a fresh work directory for older
checkpoints.

Against pinned Valhalla 3.9.3 tiles stopped after Enhance, all 6,280 Liechtenstein
node densities and road-length inputs matched. With the full oracle, 1,600 seeded
`/locate` queries matched 1,372 nodes and 6,850 directed edges. Every matched node
density and intersection type agreed. Edge density, dead-end and not-thru also agreed
on every matched edge, including 862 edges entering dead ends. Edge matches use the
way ID and full travel-direction shape at E6 precision.

### Spatial index

The `spatial.bin` payload holds an eight-byte header, a sorted directory of (cell ID,
list offset) pairs, and unsigned delta-varint lists. Each undirected edge is represented
by the smaller of its two directed CSR indices. The opposing index gives the other
direction. The builder traverses every segment of every shape at 1/256 degree resolution
and covers both sides of cell boundaries and the antimeridian. Memberships are sorted
and deduplicated before the section is written.

The mapped reader looks up cells without allocating. Segment queries return occupied
cells along the walk. Radius queries bound the scan on the sphere and return occupied
cells in increasing distance to their closed cell rectangles, with cell ID as the tie
break. Both allocate temporary results from the caller's arena.

| Extract | Undirected edges | Occupied cells | Payload bytes | Bytes per undirected edge |
| --- | ---: | ---: | ---: | ---: |
| Liechtenstein | 7,880 | 1,166 | 24,263 | 3.08 |
| Utrecht | 42,668 | 881 | 66,214 | 1.55 |
| Luxembourg 2026-01-01 | 237,668 | 22,258 | 655,990 | 2.76 |

The byte counts use encounter order and include the spatial directory and lists. CI enforces at most three
payload bytes per undirected edge on the pinned Luxembourg extract. The assembly check
looks up every stored vertex and segment midpoint and checks every encoded edge list.

### Node ordering

The assembler defaults to Hilbert order over logical node coordinates. It applies
the permutation before assigning alias and edge IDs, so adjacency, opposing arcs,
turn offsets, cold indexes, elevations and spatial lists all reference final IDs.
Equal Hilbert keys follow provisional ID order. Aliases of a logical node occupy
consecutive slots. The metadata section stores the ordering kind and XXH3-64 of the
little-endian provisional IDs in final logical node order. `zr inspect --json`
reports both fields.

Build the same input with `check-assembly --order encounter` and `--order hilbert`
to compare the median absolute ID gap between adjacent nodes. A route fixture
checks the mapped graph and reconstructs the same shortest-length route after
the permutation.

| Extract | Median ID gap, encounter | Median ID gap, Hilbert | Spatial bytes per undirected edge, Hilbert |
| --- | ---: | ---: | ---: |
| Liechtenstein | 10 | 3 | 2.86 |
| Utrecht | 21 | 3 | 1.43 |
| Luxembourg 2026-01-01 | 19 | 2 | 2.32 |

### Snap candidates

Candidate search reads the native spatial index in order of the projection metric's
lower bound. It projects batches of shape segments at the oracle's E6 precision,
retains candidates within the requested radius or the nearest eligible edge, then
expands node snaps to admissible entering and leaving arcs. The optional cold-record
trailer stores the OSM layer and level ranges used by the search filters. The
request arena retains its capacity between requests.

Build each bundle from the pinned extract and compare the generated pedestrian and
bicycle route corpus locations against the running Valhalla 3.9.3 oracle:

```bash
dataset=liechtenstein
corpus="bench/corpora/route-foot-bike.$dataset.tsv"
zig build check-snap -- "$bundle" "$corpus" > "$results"
bun oracle/check-snap.ts "$oracle_url" "$corpus" "$results"
```

The score checks the first candidate's OSM way, complete E6 shape, direction,
projected coordinate within 2 microdegrees and fraction along within 0.001. The
oracle receives `minimum_reachability=0` to isolate candidate search. Native
timings cover the snap call after parsing on an Apple M3 Pro (macOS arm64,
ReleaseFast). Utrecht's 15 differences involve `motorroad=yes` access, covered by
[#121](https://github.com/zig-utils/zig-routing/issues/121).

| Extract | Same first candidate | Agreement | Native median | Native p95 | Native p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Liechtenstein | 2,404 / 2,404 | 100.00% | 8.291 µs | 41.584 µs | 89.125 µs |
| Utrecht | 2,406 / 2,421 | 99.38% | 9.083 µs | 22.292 µs | 34.500 µs |

New bundles include `components.bin`, a weak component ID per dense node.
Snap reach is directional and bounded by the request minimum (50 by default,
with explicit values capped at 100). The lookup uses request-local paged
status for directed arcs and logical nodes. The route preflight takes both
accepted and heading or side fallback candidates into account. It reports
Valhalla error 171 when a location has no candidate and 170 when the locations
share no weak component. A shared component still requires a directed path.

### Trip leg fields

`zig build check-tripleg -Doptimize=ReleaseFast -- BUNDLE CORPUS CASES` routes
auto requests and writes the typed leg for each corpus row as JSONL. Explicit
departure and arrival times are accepted for deterministic replay.
The Valhalla actor retains its protobuf trip when using the normal JSON route
request. Compile `tripleg-reference.cc` inside the pinned image using the same
compiler and libraries as `costing-parity.sh`. Run it as
`tripleg-reference CONFIG CORPUS REFERENCE_DIR CASES` to capture those messages.

Use a flat oracle build and the corresponding `zr import-valhalla` bundle to
compare partial lengths, shapes, headings, node costs and intersections on the
same graph. Use `compare-triplegs.py NATIVE.jsonl REFERENCE_DIR DESCRIPTORS`
with the 3.9.3 `proto/descriptors` directory and `--minimum-legs` to require
coverage. The report counts paths with different directed OSM ways separately.
The local tile importer preserves edge and node signs. Use `--metadata-only`
with a bundle built from the same OSM extract to check street names, sign
groups and lane masks together.

For simple urban maneuver parity, use JSON route requests with
`directions_type` set to `instructions` and the default distance units. Add
`--maneuvers` after the case count in `check-tripleg` and pass `--maneuvers`
to `compare-triplegs.py`. This compares type and name sequences, the encoded
shape, length and time on matching paths within 0.1% of oracle cost.
The initial Utrecht sample uses the first 300 `route-auto-10km` corpus rows
with each destination moved to 6% of the straight-line distance from its
original start, rounded to six decimal places in each coordinate.

For the highway and junction rules, use the first 200 full-length Utrecht
`route-auto-10km` requests with `directions_type` set to `instructions`. Pass
`--highway-maneuvers` to `compare-triplegs.py` and use the imported bundle with
signs. The report includes motorway and per-maneuver coverage alongside the
Gate D score.

For visual text, run `check-tripleg` with `--instructions` and capture the
Valhalla Api protobufs from the same requests with the language set explicitly.
Score each locale separately with
`compare-triplegs.py native.jsonl REFERENCE_DIR DESCRIPTORS --minimum-legs 180 --instructions`.
The instruction check requires byte equality for every maneuver on legs with
matching directed paths and maneuver type and street name sequences.
Use `--verbal-instructions` with both programs to compare succinct, alert,
pre-transition and post-transition cues and the multi-cue flag on the same
legs. The pinned narration snapshots exercise metric and US customary units,
route-number formatting, and the phoneme template independently.

For pedestrian facilities and active lanes, generate fixtures with their
request corpora. Use the same PBF and right-hand traffic on both builders,
with admin lookup disabled.

```bash
zig build gurka-pbf -- fixture.osm.pbf indoor routes.tsv
zig build check-tripleg -Doptimize=ReleaseFast -- BUNDLE routes.tsv 8 --maneuvers --pedestrian > native.jsonl
python3 oracle/compare-triplegs.py native.jsonl REFERENCE_DIR DESCRIPTORS --minimum-legs 8 --narrative-fixtures
```

The fixture comparison checks each directed path, maneuver type and name,
lane mask, lane state, and active direction. To also compare the visual text,
use `check-tripleg --instructions` and add `--instructions` to the comparison.
Use `--pedestrian` for `indoor`
and `level-change`. The driving fixtures are `ferry`, `turn-lanes`,
`split-lanes`, `shared-lanes`, `short-arrival-lanes`, `uturn-lanes`,
`internal-lanes`, `restricted-lanes`, `fork-lanes`, and `short-fork-lanes`.
For `internal-lanes`, run both with and without internal intersection
inference. Set `--minimum-legs` to the number of rows in the request corpus.

### HTTP and route checks

`compare-height.ts` sends the same random `/height` requests (shapes, encoded polylines at
precision 5 and 6, ranges, resampling, every height precision, ids) to two servers and reports how
many responses are byte-identical:

```bash
bun oracle/compare-height.ts http://127.0.0.1:8102 http://127.0.0.1:18005 4000 99 --box=47.0,9.0,48.0,10.0
```

Run `zr` on Linux for this (for example the Linux build inside the same image): responses depend on
the platform libm, and upstream's numbers come from glibc.

#### US+DACH height throughput

Valhalla 3.9.3 and `zr` at `5bedf4f` ran on the same native x86-64 Linux host with eight
vCPUs, 32 GiB RAM and six workers per server. Both height comparisons passed all 1,000
requests in `height.us-dach.tsv` with exact status, JSON schema and elevation values.
The Zig server sampled its 6.14 GB DEM pack derived from all 1,493 pinned elevation files.

| Valhalla input | Connections | Median Valhalla points/s | Median Zig points/s | Median paired speedup |
|---|---:|---:|---:|---:|
| Pinned gzip | 1 | 4,346 | 627,214 | 143.42x |
| Pinned gzip | 8 | 21,311 | 4,149,262 | 197.63x |
| Uncompressed HGT | 1 | 248,787 | 637,895 | 2.57x |
| Uncompressed HGT | 8 | 1,846,431 | 4,421,344 | 2.39x |

Each comparison used three alternating `zr bench` pairs after a two-second warm-up,
one client thread at one connection, and two at eight connections. Each gzip run replayed
3,000 requests (809,106 points). Each uncompressed run replayed 15,000 requests
(4,045,530 points). The uncompressed input contained the same HGT bytes expanded from the
pinned gzip files. Every measured request returned HTTP 200 in both configurations.
The uncompressed Valhalla comparison remains below the 10x target.

On a second native x86-64 Linux host with eight AMD EPYC 9R14 vCPUs and 16 GiB RAM,
Valhalla 3.9.3 read uncompressed HGT. Zig at `942c752` read both the 6.14 GB pack
and the same uncompressed HGT. The packed DEM and raw HGT both came from the
1,493 pinned elevation files. All three Zig runs matched Valhalla's status, JSON
schema and exact elevations for all 1,000 corpus requests.

| Zig input and revision | Connections | Median Valhalla points/s | Median Zig points/s | Median paired speedup |
| --- | ---: | ---: | ---: | ---: |
| Packed, `ccbde15` | 1 | 551,730 | 2,460,624 | 4.47x |
| Packed, `942c752` | 1 | 551,730 | 2,489,279 | 4.51x |
| Raw HGT, `942c752` | 1 | 551,730 | 4,613,008 | 8.37x |
| Packed, `ccbde15` | 8 | 2,351,405 | 12,589,735 | 5.37x |
| Packed, `942c752` | 8 | 2,351,405 | 13,059,263 | 5.50x |
| Raw HGT, `942c752` | 8 | 2,351,405 | 18,318,796 | 7.68x |

Each server ran six workers. The client used one thread and a separate two-second
warm-up before each of three alternating measured replays. Each replay used 30,000
requests at one connection or 60,000 at eight connections. All measured requests
returned HTTP 200. With the updated Zig binary, the raw-input runs used about half
the server CPU time of the packed-input runs for the same work. The packed result
remains below 10x at both loads. [Performance gate](https://github.com/zig-utils/zig-routing/issues/42)

#### Request replay

`zr bench` measures throughput and latency against either server. A corpus is one request per
line, `PATH<TAB>BODY`. The standard corpora come from `tools/corpus/generate.ts` (see
`bench/corpora/manifest.json` for what each one holds and which dataset it needs):

```bash
bun tools/corpus/generate.ts
```

```bash
zig-out/bin/zr bench http://127.0.0.1:8102 --corpus bench/corpora/route-foot-bike.liechtenstein.tsv --connections 8 --duration 10s --label valhalla --out valhalla.json
```

```bash
zig-out/bin/zr bench http://127.0.0.1:18102 --corpus bench/corpora/route-foot-bike.liechtenstein.tsv --connections 8 --duration 10s --label zr --out zr.json
```

```bash
zig-out/bin/zr bench --compare valhalla.json zr.json
```

To replay a corpus exactly once, in order (a parity or acceptance run rather than a load test),
use one client thread and a request count equal to the line count:
`--threads 1 --requests $(wc -l < FILE) --warmup 0`.

On the pinned Liechtenstein, Utrecht and US+DACH oracles, all 16 regional corpora exceeded
the 95% HTTP 200 threshold. Valhalla returned HTTP 200 for 33,570 of 33,803 requests, with
a per-corpus minimum of 96.8% and zero transport errors or timeouts. Regenerating with
seed 1 reproduced the recorded hashes for all 17 corpora, including the unchanged worldwide
archive. The worldwide replay requires a planet oracle. [Regional replay](https://github.com/zig-utils/zig-routing/issues/7) · [Planet replay](https://github.com/zig-utils/zig-routing/issues/264)

Oracle validation keeps only HTTP 200 candidates in the generated corpora it processes.
Footpath islands in the test extracts make some pedestrian pairs unroutable. Utrecht rejects
about 45% of its random pedestrian candidates. Refresh the recorded rejections against running
oracles with:

```bash
bun tools/corpus/generate.ts --validate liechtenstein=http://127.0.0.1:8102 --validate utrecht=http://127.0.0.1:8103
```

#### Valhalla baseline on the benchmark host

On the native x86-64 Linux host with 8 vCPUs and 16 GB RAM, stage the pinned built datasets
for Liechtenstein, Utrecht, and US+DACH. Set `ORACLE_DATA` if the data lives outside
`oracle/data`. Generate the corpora and build the load generator before running each dataset
with the host otherwise idle.

```bash
oracle/fetch.sh us-dach
python3 oracle/baseline-build.py us-dach bench/results/baseline/build.json
```

Run the build measurement with freshly fetched inputs. It invokes the same tile builder,
records its wall time, and samples intermediate tile files and filesystem usage every
five seconds. The build log is saved alongside the JSON report.

```bash
bun tools/corpus/generate.ts
zig build -Doptimize=ReleaseFast
oracle/baseline.sh liechtenstein bench/results/baseline/liechtenstein
oracle/baseline.sh utrecht bench/results/baseline/utrecht
oracle/baseline.sh us-dach bench/results/baseline/us-dach
```

The runner checks the build key and corpus checksums. It starts a separate Valhalla 3.9.3
container with six workers, then measures each corpus at one connection and at core-count
connections. Each replay covers one complete cycle on US+DACH. Liechtenstein and Utrecht
repeat complete cycles to reach at least 5,000 requests per replay. The client uses one
thread and a two-second warm-up.
Results include latency, throughput, HTTP status counts, kernel, RAM, and the pinned image and
input checksums. Startup measures container launch through the first successful `/status`
response using the existing filesystem cache. RSS is the Valhalla process resident memory
after the replays. The runner uses the first consecutive pair of replays whose p50 values
agree within 5%, with up to four replays at each load. It writes every replay and records which
pair it used if the first two differed by more than 5%. Use a fresh output directory for a rerun.

#### Comparing servers

For numbers worth quoting, run both servers and the client inside the VM (a Linux `zr` built with
`-Dtarget=aarch64-linux-gnu`, the oracle with `ORACLE_PLATFORM=linux/arm64`, all on one Docker
network) so Colima's port forwarding and amd64 emulation do not dominate.

`zr diff` compares two servers response by response; with the same oracle on both sides every
gate must report 100%:

```bash
zig-out/bin/zr diff http://127.0.0.1:8102 http://127.0.0.1:18102 --corpus bench/corpora/route-foot-bike.liechtenstein.tsv --out diff.json --worst worst/
```

`oracle/bench-vm.sh DATASET CORPUS [LABEL]` is the comparison to quote: Valhalla and a Linux
arm64 `zr` as containers on one Docker network inside the VM, with the `zr bench` client in a
third container, each server given the same worker count, at one connection and at as many as the
VM has CPUs. It ends with the `/status` round trip at one connection, the floor that bounds any
single-connection ratio. `ZR_ELEVATION=pack` serves a pack built with `zr dem pack` instead of
the tiles. Results land in `bench/results/` (gitignored).

```bash
oracle/bench-vm.sh utrecht bench/corpora/height.utrecht.tsv
```

Germany and US+DACH builds are tracked in [#239](https://github.com/zig-utils/zig-routing/issues/239).

## Gurka fixture check

`oracle/check-gurka.sh` emits a synthetic intersection from the ASCII-map fixture and runs the
pinned Valhalla tile builder. It checks for graph tiles, three routable ways and one turn restriction.
Use `ORACLE_PLATFORM=linux/arm64` to run the arm64 oracle. The generated PBF, tiles and build log
are written under `bench/results/`.

### Refresh narrative snapshots

The fixtures come from the pinned Valhalla checkout at
`5c7f918e61306521d79cc4496d40c19c5305fa4b`. Generate the Zig tables and check
that a second read of the upstream sources produces the same bytes.

```bash
zig build narrative-fixtures -- VALHALLA_CHECKOUT src/narrative/instruction_fixtures.zig
zig build narrative-fixtures -- VALHALLA_CHECKOUT src/narrative/instruction_fixtures.zig --check
zig build test-narrative --summary all
```

On an upstream repin, review the inventory and fixture diff against the new
C++ tests before updating the pinned counts in `snapshot_coverage_test.zig`.
The inventory accounts for the explicitly disabled sharp-turn fixture and
the 26 transit narrative tests tracked in #191. The maneuver builder inventory
checks the 19 upstream test names against their typed fixtures. The generator
also reads the pinned sign-list and English dictionary tests.

The snapshot matcher compares the supplied reference strings byte for byte.
It leaves them unchanged even when update mode is enabled.
