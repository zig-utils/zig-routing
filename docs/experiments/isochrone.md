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

The original profiled TSV appended sample count, then sampled nanoseconds for
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

## Compact turn movements

[#258](https://github.com/zig-utils/zig-routing/issues/258) tests an immutable
layout with a 32-bit opposing edge ID per directed edge, a 32-bit matrix offset
per junction, and a 32-bit word per local movement. The word holds the existing
turn byte, side flags, simple restriction modes and motor turn geometry. The
matrix is keyed by physical junction because the bundle can share identical
turn rows across different junctions. Simple restrictions still resolve the
actual predecessor across junction aliases. Conditional policy and clock
evaluation run in the search.

The pinned Zig ReleaseFast runners used CPU 0 in the same six-vCPU ARM64 Linux
VM on an Apple M3 Pro. Eighteen trials per dataset rotated through all six
orders of three configurations. The matched Utrecht trial included Valhalla
3.9.3. The larger Luxembourg fixture used the same existing 475,336-edge
bundle in all configurations and included a headings-only control.

| Dataset and request | Settled / popped | Native base | Compact layout | Control |
| --- | ---: | ---: | ---: | ---: |
| Utrecht auto, 9.1 min | 41,128 / 42,301 | 10.883 ms | 10.263 ms | 11.038 ms |
| Utrecht auto, two origins, 2 min | 40,436 / 41,631 | 10.660 ms | 10.023 ms | 10.472 ms |
| Utrecht pedestrian, 12 min and 1.4 km | 35,503 / 35,984 | 6.919 ms | 6.968 ms | 7.296 ms |
| Utrecht auto, reverse, 1 min | 26,322 / 27,168 | 7.134 ms | 6.740 ms | 7.139 ms |
| **Utrecht median total per trial** | **143,389 / 147,084** | **36.054 ms** | **33.853 ms** | **35.857 ms** |
| Luxembourg auto, 18 min | 198,072 / 200,835 | 160.353 ms | 67.661 ms | 69.068 ms |
| Luxembourg auto, two origins, 12 min | 175,062 / 177,561 | 133.251 ms | 60.888 ms | 62.665 ms |
| Luxembourg pedestrian, 18 min and 3 km | 130,003 / 132,836 | 29.508 ms | 29.716 ms | 29.533 ms |
| Luxembourg auto, reverse, 14 min | 173,443 / 177,141 | 133.766 ms | 61.450 ms | 63.271 ms |
| **Luxembourg median total per trial** | **676,580 / 688,373** | **457.304 ms** | **219.948 ms** | **224.812 ms** |

Twelve separate pairs measured a traversal-only sweep and replayed its settled
events through the same rasterizer. Both apply the same padded stopping rule.
Recording happens outside the timed intervals. The split runs have their own
cache state, so the sums can differ from the paired full runs.

| Dataset | Layout | Full grid | Traversal | Raster replay |
| --- | --- | ---: | ---: | ---: |
| Utrecht | Base | 35.948 ms | 21.565 ms | 12.835 ms |
| Utrecht | Compact | 34.632 ms | 19.842 ms | 12.836 ms |
| Luxembourg | Base | 456.157 ms | 364.517 ms | 82.812 ms |
| Luxembourg | Compact | 218.459 ms | 119.541 ms | 84.231 ms |

| Fixture and layout | Construction median | Additional resident table bytes | Median process peak RSS |
| --- | ---: | ---: | ---: |
| Utrecht base | - | - | 19,791,872 |
| Utrecht compact | 1.747 ms | 1,510,304 | 21,086,208 |
| Luxembourg base | - | - | 69,861,376 |
| Luxembourg headings only | 86.516 ms | 475,336 | 73,924,608 |
| Luxembourg compact | 96.576 ms | 8,030,296 | 81,588,224 |

The compact layout reduces Utrecht full time by 6.1%. On Luxembourg the
headings-only control captures most of the improvement by computing each
edge heading once. The full layout saves a further 2.2% there for another
7,554,960 table bytes. Keep the layout as an opt-in benchmark. Utrecht's
fivefold gate is 7.171 ms at this oracle median, below either isolated
stage's current time.

All eight grids and 819,969 settled label records match byte for byte, and
the split replays reproduce the full grid bytes. Every warmed run makes
zero backing allocator calls. The timed-access and multi-via fixtures also
match in both directions. A separate full sweep of the small timed-turn
fixture returns `OutOfMemory` in both runners. The bounded timed-turn tests
compare the accepted movement and arrival cost with active and inactive
conditions, including an advancing request clock.

All 39 native test steps passed. The Linux x86-64 ReleaseFast binary is
14,385,776 bytes, 568 bytes above the base, with five search instantiations
and five costing kernels.

## Exact queue keys and label activity

[#260](https://github.com/zig-utils/zig-routing/issues/260) compares two
ways to reduce work on a settled label. The composite radix queue orders
the original nonnegative float bits followed by the insertion index.
The latter makes equal-cost keys monotone, including zero-cost turns.
It avoids the secondary heap for equal costs and doubles the radix
bucket directory. The other variant records replacement in a spare
flag in the existing 32-byte label. The state slot still controls
relaxation, and each successful replacement retires the old label.
A popped label can then check its own flag. Fractional origins with
restriction history still resolve their status from the reconstructed
turn context. Both changes add zero graph-side bytes.

The same pinned ARM64 Linux ReleaseFast executable ran on CPU 0 of the
six-vCPU VM on an Apple M3 Pro. Sixteen trials used each order of the
four variants equally often. They covered the same 143,389 settled
labels in Utrecht and 676,580 in Luxembourg. Full-grid intervals
include traversal and painting. A separate series times isolated
traversal and raster replay using the same bounds.

| Dataset | Variant | Full grid | Traversal | Raster replay |
| --- | --- | ---: | ---: | ---: |
| Utrecht | Baseline | 35.784 ms | 21.718 ms | 12.570 ms |
| Utrecht | Composite queue | 35.888 ms | 21.609 ms | 12.753 ms |
| Utrecht | Label activity | 35.547 ms | 21.273 ms | 12.960 ms |
| Utrecht | Combined | 36.242 ms | 21.687 ms | 12.715 ms |
| Luxembourg | Baseline | 463.896 ms | 370.547 ms | 84.836 ms |
| Luxembourg | Composite queue | 460.695 ms | 366.403 ms | 84.590 ms |
| Luxembourg | Label activity | 462.047 ms | 367.452 ms | 84.755 ms |
| Luxembourg | Combined | 463.920 ms | 371.755 ms | 84.419 ms |

| Dataset | Variant | Full arena peak bytes | Traversal arena peak bytes | Median RSS bytes |
| --- | --- | ---: | ---: | ---: |
| Utrecht | Baseline | 11,256,208 | 5,764,084 | 19,791,872 |
| Utrecht | Composite queue | 11,280,704 | 5,781,152 | 19,922,944 |
| Utrecht | Label activity | 11,256,208 | 5,764,084 | 20,054,016 |
| Utrecht | Combined | 11,280,704 | 5,781,152 | 19,922,944 |
| Luxembourg | Baseline | 36,431,624 | 29,231,596 | 69,861,376 |
| Luxembourg | Composite queue | 36,506,792 | 29,252,364 | 70,123,520 |
| Luxembourg | Label activity | 36,431,624 | 29,231,596 | 70,123,520 |
| Luxembourg | Combined | 36,506,792 | 29,252,364 | 70,123,520 |

Six separate traversal profiles sampled about one in 32 pops. These
are median cumulative times inside sampled spans, without scaling them
to the whole sweep.

| Dataset and variant | Sampled labels | Queue | State lookups and updates | Label access |
| --- | ---: | ---: | ---: | ---: |
| Utrecht baseline | 4,599 | 0.232 ms | 0.413 ms | 0.447 ms |
| Utrecht combined | 4,599 | 0.240 ms | 0.480 ms | 0.463 ms |
| Luxembourg baseline | 21,519 | 1.098 ms | 1.996 ms | 2.403 ms |
| Luxembourg combined | 21,519 | 1.128 ms | 2.077 ms | 2.396 ms |

Elapsed times are medians of per-trial request totals. Arena peaks are
the largest request in each series. The combined variant was about
1.3% slower on Utrecht and effectively tied on Luxembourg. Checking
label activity alone saved 0.445 ms in isolated Utrecht traversal and
0.237 ms across a full grid trial. The two changes stay opt-in for
reproduction. The full-grid results offer too little gain for the extra
queue storage or production state handling.

All four configurations produced byte-identical grids and settled label
records in both directions. The extended trace includes label flags,
restriction contexts, fractional cuts and the clock. All warmed runs
made zero backing allocator calls. Timed access and timed multi-via
fixtures also matched. Full and traversal arena peaks were 2,364,932
and 5,588 bytes for timed access, and 2,378,656 and 18,608 bytes for
multi-via turns in every variant. The bounded timed-turn test checks
active and inactive restrictions, fractional origins and full settled
state. The full timed-turn fixture still reaches the request arena cap
described above.

All 39 native test steps passed, with 635 tests and two existing skips.
Eleven test and CLI binaries cross-compiled for Linux x86-64. The
symbol-bearing ReleaseFast binary is 14,440,920 bytes, 16 bytes above
the baseline, with five search instantiations and five costing kernels.

### Queue and label reproduction

Use the same pinned ReleaseFast executable for all four variants. Run
the [Utrecht replay](#reproduction) and the [Luxembourg corpus](#movement-layout-reproduction).
Pin the runner to one CPU and repeat these four orders four times.

| First | Second | Third | Fourth |
| --- | --- | --- | --- |
| baseline | ordered_queue | compact | label_activity |
| ordered_queue | label_activity | baseline | compact |
| label_activity | compact | ordered_queue | baseline |
| compact | baseline | label_activity | ordered_queue |

Use `--stages` for a separate series with isolated traversal and raster
replay. The base columns precede the full request arena high-water bytes,
the isolated traversal and raster nanoseconds, and the two isolated
arena high-water values. `--rss` prints process peak RSS in bytes to
stderr. With `--stages --profile`, queue, status and label timings are
sampled in a separate traversal, so the isolated intervals exclude the
instrumentation. Profile columns start with the sample count, then
nanoseconds for queue, status, labels, successors, restrictions, edge
costing, turn costing and rasterization. Use `--trace-states` for the
extended trace. The regular trace still works with earlier runners.

```sh
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --memory --rss --traversal=baseline
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --memory --rss --stages --traversal=compact
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl base.grid base.trace --trace-states --traversal=baseline
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl test.grid test.trace --trace-states --traversal=compact
cmp base.grid test.grid
cmp base.trace test.trace
```

## Node-to-grid lookup trial

A request-local cache reused the grid cell of each short edge's endpoint
nodes. It initialized 122,552 bytes on Utrecht. Eighteen alternating ARM64
Linux pairs at `71b5b01` measured 36.183 ms for the full baseline and
36.227 ms with the cache. The isolated raster replay moved from 12.801 to
12.680 ms in a separate set of eighteen pairs. All grids and traces matched
byte for byte and warmed runs made zero backing allocator calls. The small
replay gain did not carry through to the full workload, so the cache was
discarded.

The isolated timings leave work in both stages. [#260](https://github.com/zig-utils/zig-routing/issues/260)
tracks a more compact exact queue and label store, and [#261](https://github.com/zig-utils/zig-routing/issues/261)
tracks graph-derived geometry reuse. [#251](https://github.com/zig-utils/zig-routing/issues/251)
retains the original paired end-to-end gate.

## Shared raster geometry

[#261](https://github.com/zig-utils/zig-routing/issues/261) evaluates two
immutable geometry tables derived from the existing bundle. The first
precomputes the exact resampling output for the five cell widths,
from 0.001 to 0.005 degrees. The second stores the decoded vertices and the exact
single-precision segment distances used by the same sampler. The
second uses the requested width during replay and shares one set of
distances across widths.

Both tables cover long painted edges. Opposing directions share a row
when their stored geometry and rounded length match. The renderer
keeps storage order during resampling and uses sweep direction during
painting. It copies cached samples into request scratch only when an
origin needs clipping. Short clipped origins use the original stored
shape. Each request still aligns cells around its origin and applies
the same padded bounds.

Twelve trials ran each order of the three configurations twice on CPU 0
in the same ARM64 Linux VM on an Apple M3 Pro. The same Zig ReleaseFast
runner used the original Utrecht requests and the legacy Luxembourg
bundle. Each full-grid time is the median of four-request totals.
The isolated intervals use a separate series with unchanged stop
bounds and replay the actual settled events in their original order.

| Fixture | Geometry | Full grid | Traversal | Raster replay |
| --- | --- | ---: | ---: | ---: |
| Utrecht | Baseline | 35.209 ms | 20.765 ms | 12.942 ms |
| Utrecht | Samples | 30.469 ms | 20.955 ms | 7.853 ms |
| Utrecht | Distances | 30.356 ms | 21.341 ms | 9.057 ms |
| Luxembourg | Baseline | 462.029 ms | 364.874 ms | 85.391 ms |
| Luxembourg | Samples | 446.249 ms | 366.129 ms | 51.593 ms |
| Luxembourg | Distances | 463.414 ms | 365.276 ms | 58.186 ms |

| Fixture | Geometry | Build time | Graph table bytes | Full arena peak bytes | Raster arena peak bytes | Median peak RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Utrecht | Baseline | 0 ms | 0 | 11,256,208 | 5,497,504 | 19,791,872 |
| Utrecht | Samples | 5.544 ms | 3,008,672 | 11,250,272 | 5,493,616 | 22,675,456 |
| Utrecht | Distances | 2.646 ms | 1,931,364 | 11,254,640 | 5,495,568 | 21,721,088 |
| Luxembourg | Baseline | 0 ms | 0 | 36,431,624 | 8,271,264 | 69,992,448 |
| Luxembourg | Samples | 91.356 ms | 32,426,144 | 36,417,928 | 8,261,584 | 105,906,176 |
| Luxembourg | Distances | 27.723 ms | 21,878,020 | 36,428,008 | 8,264,656 | 95,420,416 |

The graph table bytes count retained storage. Process peak RSS includes
construction scratch. Six separate raster profiles sampled about one
in 32 settled labels. Times are cumulative durations in sampled spans at each stage without
scaling them to the full replay. Precomputed samples skip resampling.
Short clipped origins still decode their original shape.

| Fixture and geometry | Samples | Graph and visit setup | Decode | Resample | Paint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Utrecht baseline | 4,484 | 0.148 ms | 0.087 ms | 0.123 ms | 0.121 ms |
| Utrecht samples | 4,484 | 0.150 ms | 0.001 ms | 0 ms | 0.140 ms |
| Utrecht distances | 4,484 | 0.159 ms | 0.001 ms | 0.060 ms | 0.122 ms |
| Luxembourg baseline | 21,149 | 0.947 ms | 0.632 ms | 0.952 ms | 0.629 ms |
| Luxembourg samples | 21,149 | 1.062 ms | 0.003 ms | 0 ms | 0.889 ms |
| Luxembourg distances | 21,149 | 1.128 ms | 0.003 ms | 0.486 ms | 0.632 ms |

Precomputed samples cut isolated raster time by 39.3% on Utrecht and
39.6% on Luxembourg. The full-grid gain was 13.5% and 3.4% respectively.
The distance table saves about one third of the sample table's bytes
and gives the lowest Utrecht full-grid median, with a 0.3% increase
on Luxembourg.
Keep both tables opt-in for benchmarking. They expose a raster gain
whose full-grid impact varies with the fixture, and their graph memory
cost grows with the number and complexity of long roads.

All three configurations produced byte-identical grids and the same
819,969 extended label records in both directions on the large fixtures.
The timed-access and multi-via fixtures also matched. Every warmed full
and split replay made zero backing allocator calls. The Gurka fixture
stores consecutive repeated coordinates and covers short and long
origin cuts, both directions and shapes crossing multiple cells at
each available cell width. It compares the raster bytes and grid bounds
with the original renderer.

All 39 native test steps passed, with 635 tests and two existing skips.
Eleven Linux x86-64 test and CLI binaries cross-compiled. The release
binary measures 14,440,928 bytes, up eight bytes, with five search
instantiations and five costing kernels.

### Raster geometry reproduction

Build the pinned ReleaseFast runner and use the [Utrecht replay](#reproduction)
and [Luxembourg corpus](#movement-layout-reproduction). Repeat all six orders
of the three variants twice on the same Linux CPU. Use a separate series
with `--stages` for the bounded sweep and raster replay. Add
`--raster-profile` to record a separate instrumented replay. After the
stage and memory columns, it appends the sample count and sampled
nanoseconds for graph setup, decoding, resampling and painting.
The layout construction time and graph table bytes go to stderr.

```sh
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --memory --rss
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --memory --rss --geometry
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --memory --rss --geometry-distances
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl base.grid base.trace --trace-states --stages
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl test.grid test.trace --trace-states --stages --geometry
cmp base.grid test.grid
cmp base.trace test.trace
```

Repeat the byte comparison with `--geometry-distances`.

## Combined layout measurements and the fivefold gate

The benchmark can use the movement layout and either geometry layout
together. It tested all three native configurations and Valhalla 3.9.3
on the same Utrecht tile and ARM64 Linux CPU 0. Sixteen rounds used
four balanced orders, recording four requests per round. The results
below are medians of the per-request times and, in the last row, the
per-round totals.

| Utrecht request | Native baseline | Movements and samples | Movements and distances | Valhalla 3.9.3 |
| --- | ---: | ---: | ---: | ---: |
| Auto, 9.1 min | 11.243 ms | 8.742 ms | 9.046 ms | 10.989 ms |
| Auto, two origins, 2 min | 10.393 ms | 8.586 ms | 8.652 ms | 10.526 ms |
| Pedestrian, 12 min and 1.4 km | 6.863 ms | 5.754 ms | 5.950 ms | 7.167 ms |
| Auto, reverse, 1 min | 6.902 ms | 5.557 ms | 5.648 ms | 7.095 ms |
| **Full grid** | **35.519 ms** | **28.315 ms** | **29.077 ms** | **35.581 ms** |

The two native combinations reproduce all four baseline grids and
143,389 extended settled records byte for byte. They keep zero warmed
backing allocator calls. The sample combination adds 4,518,976 graph
table bytes and the distance combination adds 3,441,668 bytes.

In a separate 12-round series, baseline traversal and raster replay
took 21.292 ms and 13.078 ms. The sample combination took 19.530 ms
and 8.189 ms. The distance combination took 19.228 ms and 8.772 ms.
Each series uses its own cache state. The best full result is 1.26x
faster than Valhalla. The fivefold threshold is 7.116 ms in these
trials, below the observed time of either isolated stage.

Two local trials kept the same bounds and byte comparisons. Exact
per-profile edge and turn prices added 9,736,640 table bytes and moved
the same-runner full median from 28.785 ms to 29.349 ms. The timed-access
and multi-via grids and extended traces also matched. Reusing the
projected row for the raster neighbor check moved isolated raster time
from 12.987 ms to 12.954 ms at baseline and from 7.795 ms to 7.869 ms
with the movement and sample layouts. Both trials were discarded.

[#262](https://github.com/zig-utils/zig-routing/issues/262) evaluates a
different traversal structure using the turn-aware cell overlay from
[#162](https://github.com/zig-utils/zig-routing/issues/162). Published
partition-based methods target edges on the boundary of reachability.
The native comparison here requires the full padded grid, including
both arrival metrics, precise accumulated costs and direction-specific
restrictions. [Fast Computation of Isochrones in Road Networks](https://arxiv.org/abs/1512.09090)

Use the same fixture and pinned executable as in the earlier comparisons.
The flags can be combined for both the full and split runs.

```sh
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --layout --geometry --rss --memory
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --layout --geometry-distances --rss --memory
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl combined.grid combined.trace --layout --geometry --trace-states --stages
```

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

### Movement layout reproduction

Use the original Utrecht requests above. For Luxembourg, use the legacy
187,650-node bundle in [the E1 pilot](E1.md). To rebuild it, use the pinned
Luxembourg PBF from E1 with `zr build --output BUNDLE LUXEMBOURG.osm.pbf` at
`8a82c29` and verify dataset ID `f32e9b177f9b82c38156e61eaf518b9c`.
Save these four lines as `luxembourg.jsonl`.

```jsonl
{"costing":"auto","locations":[{"lat":49.61166,"lon":6.13193}],"contours":[{"time":18}]}
{"costing":"auto","locations":[{"lat":49.60411,"lon":6.13489},{"lat":49.63014,"lon":6.17236}],"contours":[{"time":12}]}
{"costing":"pedestrian","locations":[{"lat":49.60983,"lon":6.12984}],"contours":[{"time":18},{"distance":3}]}
{"costing":"auto","locations":[{"lat":49.61971,"lon":6.10644}],"contours":[{"time":14}],"reverse":true}
```

Run the same executable with and without `--layout`. Use the pinned oracle
as the third runner for Utrecht and `--headings-only` for Luxembourg. Run each
of the six orders three times, with `/dev/null` for the grid and `--rss` for
the native peak RSS. Layout construction time and resident table bytes go to
stderr, outside request timing.

```sh
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --rss > base.tsv
taskset -c 0 ./bench-isochrone BUNDLE requests.jsonl /dev/null --layout --rss > layout.tsv
taskset -c 0 ./bench-isochrone LUX_BUNDLE luxembourg.jsonl /dev/null --headings-only --rss > headings.tsv
```

For stage timing, repeat the native pair twelve times, alternating the runner
order and adding `--stages`. The TSV appends traversal and replay nanoseconds.
Use separate runs with grid and trace paths for the byte comparisons.
The timed-access and multi-via corpora use the first location in each pinned
route replay for forward and the last for reverse. Use a six-minute contour
and set `date_time_utc` to the fixture's route timestamp.
[Build and import the restriction fixtures](../../oracle/README.md#timed-access-and-turn-restrictions).
