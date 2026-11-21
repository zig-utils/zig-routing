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

## Replay with imported restrictions

The expansion now uses the directed predecessor's stored dead-end flag and
applies vehicle dimensions from the imported access records. Twelve trials
rotated the runners through the same ARM64 Linux environment and Utrecht tiles.
The median total was 36.343 ms for Valhalla, 44.549 ms for the previous native
runner, and 45.175 ms for the updated native runner. The 5x target remains open.

| Request | Edges within 1% or 5 s |
| --- | ---: |
| Auto, 9.1 minutes | 22,137 / 22,150 |
| Auto, two origins, 2 minutes | 784 / 784 |
| Pedestrian, 12 minutes and 1.4 km | 2,945 / 2,945 |
| Auto, reverse, 1 minute | 91 / 91 |

Twelve differences in the first request follow the legal predecessor sequence
4730 → 4775 → 4782. Valhalla's route search traverses the sequence when seeded
on edge 4730. Its isochrone expansion retained the cheaper arrival at edge
4775 from edge 4778, which is barred from continuing to 4782. Native expansion
retains both restriction contexts. Edge 28525 has equal weighted cost and a
6.27-second difference in elapsed time.

## Exact radix queue and grid writes

[#251](https://github.com/zig-utils/zig-routing/issues/251) uses a radix queue
for nondecreasing weighted costs, with label order preserved on ties. The
search reuses the turn row for motor costing, and the rasterizer skips repeated
nondecreasing writes to the same cell. A native CPU sample identified queue
operations, turn handling, and shape decoding and rasterization in the hot
path. The benchmark checks the backing allocator during every warmed request.

Twelve trials rotated the three runners on CPU 0 of the same ARM64 Linux VM.
Each runner used the same four requests and the same Utrecht tiles. The
candidate's grids and label traces were byte-identical to the native baseline
at `219b6a6`. Every warmed run made zero backing allocator calls.

| Request | Settled / popped | Native baseline | Native with radix | Valhalla 3.9.3 |
| --- | ---: | ---: | ---: | ---: |
| Auto, 9.1 minutes | 41,128 / 42,301 | 13.466 ms | 11.475 ms | 10.566 ms |
| Auto, two origins, 2 minutes | 40,436 / 41,631 | 13.166 ms | 11.093 ms | 9.972 ms |
| Pedestrian, 12 minutes and 1.4 km | 35,503 / 35,984 | 7.963 ms | 7.179 ms | 7.182 ms |
| Auto, reverse, 1 minute | 26,322 / 27,168 | 8.774 ms | 7.361 ms | 6.918 ms |
| Median total per trial | 143,389 / 147,084 | 42.922 ms | 37.280 ms | 34.742 ms |

Native elapsed time fell 13.1%. The 5x target on this run requires a median
total of 6.948 ms and remains open. A trial cache for resampled shapes saved
2.6% in a separate paired run and required about 2.3 MiB per worker. The
measured candidate uses the original request-local geometry buffers.

## Reusing graph operands during expansion

[#255](https://github.com/zig-utils/zig-routing/issues/255) reads the
junction record and predecessor class once per expanded label. Successor
checks share the directed edge, class and local turn row. Complex turn
history and conditional access still use the exact predecessor state
and request clock.

Eighteen uninstrumented trials rotated the three runners on CPU 0 of
the same ARM64 Linux VM. All used the earlier Utrecht graph and four
requests. The native baseline used `c332d60`.

| Request | Settled / popped | Native baseline | Native candidate | Valhalla 3.9.3 |
| --- | ---: | ---: | ---: | ---: |
| Auto, 9.1 minutes | 41,128 / 42,301 | 11.584 ms | 11.276 ms | 11.075 ms |
| Auto, two origins, 2 minutes | 40,436 / 41,631 | 11.682 ms | 11.109 ms | 10.168 ms |
| Pedestrian, 12 minutes and 1.4 km | 35,503 / 35,984 | 7.674 ms | 7.139 ms | 7.201 ms |
| Auto, reverse, 1 minute | 26,322 / 27,168 | 7.841 ms | 7.321 ms | 7.135 ms |
| Median total per trial | 143,389 / 147,084 | 38.775 ms | 36.906 ms | 36.355 ms |

Total native time fell 4.8%. All four grids and the settled label
trace were byte-identical. Each warmed request made zero backing
allocator calls.

Twelve separate trials alternated the profiled native runners.
The stage observer samples roughly one in 32 popped labels and
subtracts the measured baseline clock read cost from its intervals.
The table extrapolates the samples to the full four-request trace.
Use the uninstrumented trials for end-to-end time. Stage estimates
include probe overhead and should be compared stage by stage.

| Sampled stage | Native baseline estimate | Native candidate estimate |
| --- | ---: | ---: |
| Queue operations | 8.021 ms | 8.026 ms |
| Successor enumeration and label handling | 18.867 ms | 20.128 ms |
| Restriction and access checks | 12.674 ms | 10.545 ms |
| Edge costing | 3.342 ms | 3.160 ms |
| Turn costing | 6.475 ms | 6.583 ms |
| Rasterization | 16.293 ms | 16.187 ms |

Successor enumeration now includes graph reads previously repeated in
the restriction and costing calls. The before and after probes use the
same instrumentation, introduced at `ab68938`.

```sh
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --profile > stages.tsv
```

The profiled TSV appends sample count, then sampled nanoseconds for
queue, successors, restrictions, edge costing, turn costing and
rasterization. For each request, multiply each stage sample by popped
labels divided by sample count. Summing the four requests gives each
trial's stage estimates.

## Grouped radix buckets and raster arithmetic

The radix queue partitions keys by the highest differing four-bit digit
and caches each bucket's minimum. A redistribution moves each entry past
at least one digit. Single-entry buckets can return the entry directly,
and tied costs still use label order. The rasterizer uses a dense bitset
up to 64 KiB and sparse pages for larger graphs. Tile lookup divides
both axes together with the same floating-point arithmetic, and shape
resampling reuses the latitude cosine and radians of adjacent vertices.

Eighteen uninstrumented trials rotated all six runner orders on CPU 0
of the same ARM64 Linux VM with the matched Utrecht tiles and four
requests. The native baseline used `c10e357`.

| Request | Settled / popped | Native baseline | Native candidate | Valhalla 3.9.3 |
| --- | ---: | ---: | ---: | ---: |
| Auto, 9.1 minutes | 41,128 / 42,301 | 11.397 ms | 10.680 ms | 11.115 ms |
| Auto, two origins, 2 minutes | 40,436 / 41,631 | 11.105 ms | 10.596 ms | 10.329 ms |
| Pedestrian, 12 minutes and 1.4 km | 35,503 / 35,984 | 7.128 ms | 6.719 ms | 7.268 ms |
| Auto, reverse, 1 minute | 26,322 / 27,168 | 7.220 ms | 6.878 ms | 7.276 ms |
| Median total per trial | 143,389 / 147,084 | 37.021 ms | 35.176 ms | 36.271 ms |

Native elapsed time fell 5.0%. All four grids and all 143,389 settled
label records were byte-identical. Every warmed request made zero
backing allocator calls. In twelve separate profiled pairs using the
same sampler, the median raster stage estimate fell from 16.338 ms to
15.875 ms. The queue stage estimate was roughly flat at 8.021 and
8.134 ms under instrumentation.

The fivefold target requires 7.254 ms at this oracle median. Across the
four requests, that is about 50 ns per settled label including the
queue, traversal and grid work. [#251](https://github.com/zig-utils/zig-routing/issues/251)
keeps the original end-to-end gate.

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

For the before-and-after run, build the native benchmark at `219b6a6` and
again with the optimization. Keep the same bundle and Valhalla config for
all runs. Pin each executable to the same Linux CPU and run each of the six
orders of baseline, candidate and oracle twice. For each runner, report the
median of each request's elapsed time and the median of each trial's sum
of elapsed times. Use the optional trace argument for the separate grid and
label comparison.

```sh
taskset -c 0 ./bench-isochrone-base BUNDLE requests.jsonl base-grid.bin base-trace.bin
taskset -c 0 ./bench-isochrone-new BUNDLE requests.jsonl new-grid.bin new-trace.bin
cmp base-grid.bin new-grid.bin
cmp base-trace.bin new-trace.bin
```
