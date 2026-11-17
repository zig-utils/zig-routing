I've read #3953 in full and the issues and PRs it links to. I also surveyed about 900 open and 4,000 closed issue titles, then read about 70 issues, 6 Discussions and 35 PRs in depth. Labels: **[V]** means I read it in an issue, PR or the source; **[I]** means it is my inference. Short form: #N = https://github.com/valhalla/valhalla/issues/N (the same URL path also resolves for PRs) and D#N = https://github.com/valhalla/valhalla/discussions/N.

---

## 1. Issue #3953: "Scaling the Routing Service – A Discussion About How to Start Up Faster"

**State [V]:** OPEN, label `enhancement`. Opened 2023-02-07 by kevinkreiser. 2 comments, both 2023-05-31. Nothing has been decided or built.

**What it is about [V]:** A design essay on horizontal autoscaling under bursty load. A new instance can't serve until it has the whole planet tileset on local NVMe, so scale-up lags and existing instances return 504s.

**Numbers in the body [V]:**
- A planet tileset is "anywhere from 70 to 140gb".
- Getting data onto disk "typically 10+ minutes".
- A remote HTTP/S3 round trip is "on the order of 50-100ms". An NVMe miss is "50-100μs", so the issue says the current worst case is "3 orders of magnitude faster than lazy loaded http".

**Current architecture as described [V]:** Multi-process service for isolation. The tileset is a memory-mapped tar, so all processes share the OS page cache ("multi-reader … single-writer (the OS) cache"). Startup was cut by the tar index (#3281).

**Options discussed [V]:**
- **Sharding:** regional extracts such as NA / SA / Afro-Eurasia / Oceania. Cons: you only scale as fast as the largest shard (Afro-Eurasia is "like 70% of the planet data"), you need a connectivity-aware proxy, and you have heterogeneous clusters.
- **Lazy loading (recommended first step):** Redis/Memcached as a global tile cache. At startup, write a sparse, zero-filled tar laid out from `index.bin` and mmap it. A sidecar fills tiles on demand over a domain socket. It writes `graph_tile_size` last as a commit flag; readers treat a zero size as "missing, ask the sidecar".
- Optionally sort tiles in the tar better (cluster levels 0/1/2, or a Hilbert curve) for page-cache coherence.
- Listed risks: global traffic defeats it, and cold instances could take "5 minutes … to reach semi-normal request latencies".

**Comments [V]:**
- j-bbr runs a production sharded k8s proxy: country-sized containers, bbox-based routing to the smallest covering shard, mostly matrix and isochrone traffic under 100 km. Pros: fast startup, simple autoscaling. Con: routes that pass through a third region aren't optimal.
- nilsnolde: for truly global setups "sharding is likely still too slow", and lazy loading becomes more attractive. Connectivity data is available via `loki.use_connectivity`, `/status?verbose` or `valhalla_build_connectivity`.

**Links, followed one level:**
- **#3281 [V]** (PR, merged 2021-10-27): "de-singleton tile extract in graphreader". Adds `index.bin` (tile_id → byte offset) as the first tar member, written by the Python `valhalla_build_extract`, so GraphReader skips the full tar scan. Fixes #3117.
- **#3117 [V]** (closed): its parent. Tar enumeration was slow enough to force a singleton, which blocked reloading tilesets.
  - danpat suggested a space-filling-curve tar order and pointed out that the old scan accidentally pre-warmed the page cache, so skipping it makes the first requests slow.
  - chrstnbwnkl later noted cache warming "has never been implemented"; kevinkreiser confirmed and said the right warming strategy is unknown.
- **#4140 [V]** (cross-references #3953, closed): "planet hardware requirements".
  - nilsnolde: serving needs "a few 100 MB RAM"; the planet is about 80 GB of tiles.
  - ImreSamu's rule of thumb: 64 GB RAM plus 1 TB fast disk.
  - The docs say a planet build takes about 15 h on a quad-core with 16 GB, and elevation is about 1.6 TB.
- **Follow-up evidence lazy loading is still immature [V]:**
  - #6206 (open, 2026-07): with `tile_url` and an empty `tile_dir`, the connectivity map is built once from an empty directory listing. Every `/route` and `/sources_to_targets` then fails with error 170 until `use_connectivity=false`.
  - #6422 (closed): `tile_url` had no download timeouts.
  - #6239 / #6514: no tileset header or checksums, and the tar-index logic is duplicated in C++ and Python.

---

## 2. Open and relevant issues by theme

### a. Route query latency
- **#2604 [V]** (open, 2020): maintainers' framing of the core trade-off.
  - kevinkreiser: "only a very very conservative contraction … a doubling of speed over basic A*".
  - nilsnolde: expects only "20-30%" from further tuning of the existing algorithms.
- **Time-dependent routing [V]:**
  - #1895 (open): shortcuts are skipped for time-dependent routes because there is no time-dependent speed along a shortcut.
  - #1190 (open): no bidirectional time-dependent A*.
  - D#5848: enabling predicted speeds took latency from under 100 ms to about 1.8 s (Riyadh). Partly user data (bloated level-1 tiles) and partly forced unidirectional A*. nilsnolde notes historical-speed storage could shrink to under 0.1% by deduplicating profiles (#5851; PR #5941 merged).
- **Hierarchy heuristics [V]:**
  - #3868 (open): hierarchy limits for unidirectional A* are static.
  - #6091 (open 2026): suboptimal route caused by hierarchy pruning.
  - #3874 (open): truck "forward search exhausted"; `extended_search` doesn't help.
  - #2979 / #3482: long shortcuts cause detours; a 24,000 km shortcut crashed a build.
- **Regressions with no regression harness [V]:** #3007, a long bicycle route got slower when the default reserved-label count was lowered. purew: no "documented systematic way of measuring this performance".
- **Rewrite angle [I]:** a customizable contraction scheme (CCH/MLD-style metric customization per costing) breaks the "flexibility vs. speed" dichotomy the maintainers treat as fixed. Time-dependent support needs shortcut speed profiles.

### b. Matrix (CostMatrix / TimeDistanceMatrix)
- **#2604 [V]:** 33×1 matrix, Sri Lanka, 4 vCPU. Valhalla averages 2,095–5,139 ms versus OSRM's 10–23 ms.
  - Switzerland, from comments: 3855² took about 10 min batched, 12425² was cancelled after 4.5 h, and a single full request used more than 50 GB RAM.
  - nilsnolde: many:many "expands from all locations at the same time, so you basically load the whole Switzerland network into RAM".
- **#973 [V]** (2017, Denver, m4.4xlarge, 16 threads): Valhalla 1000² in 111 s versus OSRM's 31 s.
- **#1825 [V]:** no intra-request parallelism, by design (concurrency comes from serving many requests). 2000² on a 2 GB tar used about 25 GB RAM.
  - danpat: splitting a matrix repeats the expansion from each location in every chunk.
- **#3556 [V]:** 572² Lisbon used about 12 GB. On planet tiles a request took 94 s and 9.5 GB.
  - dnesbitt61: each location has its own EdgeLabel list, DoubleBucketQueue and EdgeStatus, used both as source and as target.
- **#5172 [V]** (open, 37 comments): RSS ratchets up per worker; about 2–2.5 GB per worker reported.
  - Part of the root cause was found in PR #5978: `ankerl::unordered_dense::map::clear()` doesn't free memory, so `ReachedMap` kept its peak capacity forever.
  - Part remains: glibc arena fragmentation, still seen on 3.9.1. The fix attempt #6497 (`malloc_trim`) was closed by a maintainer as AI slop, so that part is unresolved.
- **Also [V]:** #4937 (400×400 → "bad allocation"), #4956 (null cells; second-pass settings), #5811 (1:1 and m:n results differ), #4971 (negative time).
- **Rewrite angle [I]:** shared multi-source search (bucket-based many-to-many or PHAST/RPHAST over a contracted overlay). Per-request arena allocators freed wholesale (chrstnbwnkl's 2 GB monotonic-buffer experiment was fastest in his benchmark). Compact label structs.

### c. Isochrones / expansion
- **[V]** #3823 (open) and #4398: requests hang forever on specific inputs, plus missing cancellation hookup in Dijkstra (kevinkreiser). #3212 and #4459: artefacts.
- **[V]** D#5514: chrstnbwnkl, "isogrid updates are actually not the bottleneck. The graph expansion is". #1501: isochrone serialization (not actually the bottleneck). #4923: no non-serialized API.
- No issue I found gives isochrone timing numbers.

### d. Map matching (meili)
- **[V]** #2529 (open, 44 comments): loki's 0.05° bins (about 5.5 km) are too coarse, so meili keeps its own 100 m grid cache, about 10× faster once warm.
  - Bounding-circle prefilter prototype: median candidate search went from 0.058 ms to 0.0075 ms (7.5×). Merged as PR #5103 (2026-05, reported 2×–15×).
  - The 18 spare GraphId bits couldn't be used compatibly.
- **[V]** #4322 (open) and #4667: memory grows across `trace_attributes` calls. The meili cache is bounded by item count, not bytes.
- **[V]** #6294 (open): unbounded recursion in `expand_from_node`; about 1,300 edges overflows a 1 MB stack.
- **[V]** PR #6040: checking for interrupts on every point cost more than the work itself.

### e. Tile build pipeline (mjolnir)
- **[V]** #5099 (GSoC 2025): "close to 24 hours on a 16core 64gig machine". After PR #5328 nilsnolde reports about 10 h end-to-end.
- **[V]** Per-stage planet timings for 3.7.0, 32 cores, from #6201, in seconds:
  - ParseNodes 3632, ParseWays 2170, BuildLocalTiles 1782, Build 2366, ElevationBuilder 1598, FormTilesInNewLevel 1202, Restrictions 788, Validate 670.
  - Total 3:57 h, against GraphHopper's 3:05 h on the same server (user report).
  - 3.8.x regressed Validate 26× (17,534 s) because bounding circles were computed even when disabled (#6141 / #6218).
- **[V]** #6312 (open): PSRS external sort (PR #6226, up to 3× faster) made a 24-CPU / 70 GB VM go from about 18 h to about a week. The cause was about 6,000 read cursors on non-NVMe disk; fixed by capping sort concurrency at 8 (#6316).
  - Working set: 251 GiB of `.bin` intermediates (way_nodes 108 GiB) against 83 GiB of page cache.
- **[V]** #4548: FOSSGIS parse stage used 1.2 TB of temp space on a 1.7 TB disk; OSMNode had grown 60%.
- **Merged speedups [V]:**
  - PR #5070 (libosmium): admins 2h20m → 39m; parse to `parsenodes` 8h33m → 4h52m.
  - PR #5143 (multithreaded ParseWays): 8844 s → 4407 s.
  - PR #5204 (GEOS + tile clipping): BuildLocalTiles 1998 s → 554 s (Europe).
  - PR #4669: graph build 6 min → 40 s (Switzerland).
  - PR #6378 (multithreaded Filter): 5533 s → 450 s; build_tile_set 20,001 s → 14,905 s (about 4.1 h) on m8gd.4xlarge, but with pedestrian and bicycle disabled.
  - PR #5747: way_nodes.bin 120 → 96 GiB.
- **[V]** Lua: #5369 / #6139. The maintainers now frame removal as maintainability: graph.lua is over 2k untested lines.
- **[V]** Determinism: #5473; #5561 (builds are non-deterministic at 30+ threads); #6112.
- **[V]** Transit: #4183, #5276, #5876, #6412.

### f. Memory footprint, tile cache, mmap, startup
- **[V]** #3745: a 40 GB tar pinned the CPU at 100% on a small VM.
- **[V]** PR #5995: each of the 24 GraphReaders on an 8-CPU box held 205k tile-name strings, about 400 MB total.
- **[V]** #4736: algorithm scratch memory scales with threads; only the mmapped graph is shared.
- **[V]** #6148 (open 2026): level-0/2 tiles up to 96 MB. Some are "uncomfortably close to the max edgeinfo offset (~33 MB)". The tileset grew from about 70 GB four years ago to about 105 GB.
- **[V]** #6520: gzip tiles inflate before size validation.
- **[V]** PR #4455 and PR #6342: Hilbert node ordering. Median distance between consecutive nodes on level 0 drops from 142 m to 46 m. kinkard: Valhalla is "mostly IO bounded". No latency benchmark was produced.

### g. Service architecture
- **[V]** #1825: one worker means about 15 threads (a proxy plus a worker per stage, each with a zmq IO thread).
- **[V]** #4771: throughput doesn't scale with thread count.
- **[V]** #2867 / PR #2873 (still open): tile refcount thread safety is a build flag; the atomic version costs about 5%.
- **[V]** No hot swap of tiles: #2156, #3938 ("not possible as of now in any mode").
- **[V]** #2215: blocking logger.
- **[V]** PR #6105 (2026-09): Windows needed TCP plus shared memory instead of domain sockets.

### h. Data-format limits
All verified in the source (`graphid.h`, `graphconstants.h`, `directededge.h`) or in issues.
- **[V]** GraphId is 3 bits level, 22 bits tile, 21 bits id, so at most 2,097,151 nodes or edges per tile. `endnode_:46`. kMaxEdgeInfoOffset = 2^25 bytes, now nearly hit (#6148). kMaxEdgeLength = 2^24 m (#3482). kMaxEdgesPerNode = 127 (#6217). kMaxShortcutsFromNode = 7.
- **[V]** #5098 (label v4): header "slots" for forward compatibility have been broken since v3.
- **[V]** #4562: tile sizes are hard-coded. #4953: elevation can't be disabled per edge. #1726: OSMWay and name storage.

### i. Correctness bugs that come from the architecture
- **[V]** Shortcuts:
  - #4527: bidirectional A* fails when the meeting point is on a shortcut (EdgeStatus index set to 0).
  - #4609: same start/end shortcut picks the wrong path; "not rare at all".
  - #4656, #4672: shortcuts cost differently from base edges.
  - #5437: unidirectional paths contain shortcuts.
  - #1687 / #1688: GetShortcut loops or mis-ties edges.
  - #5927: GetShortcut null dereference.
- **[V]** Pruning: #6091, #3874, #4258 (`disable_hierarchy_culling` broken), #2085, #1492.
- **[V]** Matrix and route disagree: #3804, #5811, #4956.
- **[V]** Build crashes: #1856, #4791 (opposing edge or index out of bounds).

### j. Portability and build pain
- **[V]** Dependency breakage: #2124 (GEOS 3.8 broke the build), #4673 (boost.geometry with gcc13), #5481 (boost), #3022 (Homebrew boost), #3734 (system RapidJSON).
- **[V]** #4206: prime_server isn't packaged in Debian or Arch.
- **[V]** #6387: bundled tz is required.
- **[V]** ARM: #4623 (GeoTIFF segfault on Mac ARM, 40 comments), #5448 (ARM illegal instruction).
- **[V]** Windows: #5549 (crash), #1748 (pthread); full support only arrived with PR #6105.
- **[V]** #5369 / #6139: Lua. PR #6303: building libvalhalla no longer requires Python.

---

## 3. Upstream benchmarking infrastructure and measured speedups

**Infrastructure [V]:**
- `bench/` (Google Benchmark, added in PR #2222) was **deleted** in PR #4560 (2024-02). #4557: "pretty pointless … CI machines are not the right environment".
- What remains:
  - `run_route_scripts/` (`run_with_server.py`, `run_with_server_matrix.py`, results diff scripts)
  - `run_route_scripts/perf_test/` (siege on `url_de_benchmark_routes.txt`; wrk-bench.sh with route and trace_route Lua scripts)
  - `test_requests/de_benchmark_routes.txt`
  - `valhalla_benchmark_loki` (repaired in #4981 and #5730), `valhalla_benchmark_admins`
  - Rust `benches/` in the new bindings
  - `[TIMING]` log macros for build stages (PR #5136)
- There is no CI performance tracking. External harness: https://github.com/chrstnbwnkl/valhalla-benchmark-matrix.
  - 100 requests took 109.7 s on master and 81.2 s with a 2 GB monotonic buffer. Hardware isn't stated.

**Most informative PRs [V]:**

| PR | Hot spot | Measured |
|---|---|---|
| #4671 | A* heuristic in CostMatrix | −60% request time (20 locations, Germany) |
| #4372 / #4329 | CostMatrix rewritten to mirror bidirectional A* | robustness; no numbers |
| #6013 | `std::set` → unordered_dense in CostMatrix | repeated UK request 21.3 s → ~14 s |
| #5978 / #5690 / #4075 | ReachedMap / matrix memory retention | RSS plateau fixed |
| #4439 | EdgeLabel 56 → 40 B, MMEdgeLabel 80 → 72 B | memory |
| #2719 | DoubleBucketQueue | profile-driven |
| #5384 | `loki::Reach` hashset | `/locate` −10% |
| #5724 | heap allocation per candidate in loki | profiler screenshots |
| #5103 / #2529 | edge bounding circles | search 2×–15×; MVT 280 → 164 ms |
| #5325 | robin_hood → ankerl::unordered_dense | — |
| #5995 | tar-index strings | −400 MB per 8-CPU box |
| #4455 / #6342 | spatial node ordering | locality only |
| #5070, #5143, #5204, #5328, #6226, #6378, #4669, #5747 | build stages | see 2e |

I found nothing about a "FlatTileCache" in upstream issues or PRs. A "second pass" exists only as the config `costmatrix_allow_second_pass` (#5426, #4956); I didn't find a removal PR.

---

## 4. External and public comparisons (scores to beat)

I found no rigorous, peer-reviewed three-way benchmark. The best numbers are in the upstream issues themselves.

| Source | Setup | Numbers |
|---|---|---|
| #2604 (2020) | 4 vCPU 2.8 GHz, 8 GB, Sri Lanka | Route load test (rerun): OSRM 2 ms avg / 510 rps; Valhalla 379 ms avg / 220 rps. 33×1 matrix: OSRM 23 ms, Valhalla 5,139 ms |
| #973 (2017) | m4.4xlarge, Colorado, auto | N×N, Valhalla vs OSRM: 100² 3.1 s vs 0.28 s; 500² 34.5 s vs 6.0 s; 1000² 111 s vs 31 s |
| #2604, MichaelKorn (May 2022) | Ryzen 7 4800H, Germany, Docker | OSRM 1k² 12 s, 2k² 33 s, 2.5k² 46 s; Valhalla 175² already >60 s |
| #2604, DavidPiringer (2022) | 10-core WSL, Switzerland | 3855² ≈ 10 min batched; 12425² >4.5 h; >50 GB unbatched |
| #6201 (2026) | 32 cores (user report) | Planet build: Valhalla 3.7.0 3:57 h vs GraphHopper 3:05 h |
| PR #6378 / #6312 (2026) | m8gd.4xlarge, 16 CPU / 64 GB NVMe | Planet build_tile_set ~4.1 h (no pedestrian/bicycle); "4h" per kinkard |
| #3197 (2021) | 24 threads / 32 GB NVMe vs 8 threads HDD | ~24 h vs 60 h |
| OSRM wiki | 2021 planet | Car ~123 GiB RAM to serve; CH ~230 GiB of files; contract ~12 h (osrm-talk, 2017) |
| GraphHopper deploy.md (mirror) | — | Planet import ~3 h / 60 GB; CH with turn costs ~25 h / 120 GB; LM ~4 h / 80 GB |
| Tileset size | — | 70 GB → ~80 GB (#4140, 2023) → ~105 GB (#6148, 2026); elevation ~1.6 TB |
| FOSSGIS public instance (D#3373, D#6335) | 16 threads | Rate limited to 1 req/user/s and 100 req/s total; >20M request attempts per 24 h (abuse) |
| Blog posts (tanhdev etc.) | unspecified | 100² matrix: OSRM ~21 ms, GraphHopper ~52 ms, Valhalla ~120 ms. Unspecified method, low quality |

I found no talks (FOSS4G 2023 Nolde, FOSSGIS 2026), Mapzen posts or Stadia posts with quantitative results.

---

## 5. Top 10 problems, ranked by evidence strength × user impact

1. **Many-to-many matrix is orders of magnitude behind OSRM in time and memory.** #2604, #973, #1825, #3556, #5172, #4736, #4937, PRs #4671 / #6013 / #5978. [V] The cause is one independent bidirectional search per location, with no shared search or contraction overlay; the maintainers confirm this.
2. **Cold start and scale-out: the planet must be fully local, nothing warms the page cache, and lazy loading is broken.** #3953, #3117, #6206, #6422, #3745. [V]
3. **Planet build is IO-bound, with huge intermediates and fragile across disk types.** About 4–24 h, 250+ GiB of `.bin` files, 1.2 TB scratch. #5099, #6201, #6312, #4548, #3197; PRs #5070 / #5143 / #6226 / #6378. [V]
4. **Per-worker heap retention and duplicated per-thread state.** #5172, #4322, #4667, PR #5995. [V] That an arena-per-request design would fix it is [I].
5. **Conservative contraction caps query speed; time-dependent routing loses shortcuts and bidirectional search.** #2604 (maintainers), #1895, #1190, D#5848, #3868. [V]
6. **Hierarchy and shortcut correctness: wrong or missing routes.** #4527, #4609, #4656, #4672, #5437, #2979, #3482, #6091, #3874. [V]
7. **Spatial lookup in loki/meili with a duplicate meili cache.** #2529, PRs #5103 / #5384 / #5724. [V]
8. **Tile-format ceilings and broken forward compatibility.** 21-bit ids, 25-bit edgeinfo offset nearly exhausted, 127 edges per node, 7 shortcuts per node, broken header slots. #6148, #6217, #5098, #3482, PR #5103. [V]
9. **Unbounded work, hangs and missing cancellation.** #3823, #4398, #6294, #1219, PR #6040. [V]
10. **Memory layout and cache locality of tiles; serialization overhead.** PRs #4455 / #6342, #6148, #5190 (nilsnolde: the JSON layer is "really memory intense and very slow"), #1348. [V] The size of the actual latency gain is [I]; upstream never measured it.

**Honourable mention:** dependency and portability pain (#2124, #4206, #4623, #5549, PR #6105), plus no performance regression harness (`bench/` deleted in #4560; #3007). [V]

**[I] The most important overall inference:** upstream keeps rejecting "OSRM-class" matrix and long-route performance as incompatible with dynamic costing. A rewrite built on customizable contraction, with arenas, NUMA/IO-aware tile layout and native lazy tile loading, attacks problems 1, 2, 4, 5 and 6 together.

Sources:
- [faun.dev GraphHopper vs Valhalla](https://faun.dev/toolbox/graphhopper-vs-valhalla/)
- [sumguy OSRM vs Valhalla vs GraphHopper](https://sumguy.com/osrm-vs-valhalla-vs-graphhopper/)
- [pistack 2026 comparison](https://www.pistack.xyz/posts/2026-04-25-graphhopper-vs-osrm-vs-valhalla-self-hosted-routing-engines-guide-2026/)
- [tanhdev GraphHopper matrix](https://tanhdev.com/posts/graphhopper-distance-matrix-production-guide/)
- [tanhdev OSRM vs GraphHopper](https://tanhdev.com/posts/osrm-vs-graphhopper-architecture-comparison/)
- [OSRM Disk and Memory Requirements](https://github.com/Project-OSRM/osrm-backend/wiki/Disk-and-Memory-Requirements)
- [osrm-talk 2017 contract time](https://lists.openstreetmap.org/pipermail/osrm-talk/2017-September/001531.html)
- [osrm-talk 2021 resources](https://lists.openstreetmap.org/pipermail/osrm-talk/2021-June/002001.html)
- [GraphHopper deploy.md mirror](https://gitee.com/mirrors_graphhopper/graphhopper/blob/master/docs/core/deploy.md)
- [GraphHopper worldwide blog](https://www.graphhopper.com/blog/2022/06/27/host-your-own-worldwide-route-calculator-with-graphhopper/)
- [valhalla-benchmark-matrix](https://github.com/chrstnbwnkl/valhalla-benchmark-matrix)
- [FOSS4G 2023 Valhalla talk](https://talks.osgeo.org/foss4g-2023/talk/LW7AJX/)
- [Valinor talk](https://talks.osgeo.org/foss4g-2026/talk/RVTHSV/)
- [Mapzen Introducing Valhalla](https://mapzen.com/blog/introducing-valhalla)
- [OSM forum ETA comparison](https://community.openstreetmap.org/t/estimated-time-significantly-different-in-valhalla-and-google-maps/143459)
- [routingpy compare notebook](https://nbviewer.org/github/nilsnolde/routingpy/blob/1.3.0/examples/compare_providers.ipynb)
