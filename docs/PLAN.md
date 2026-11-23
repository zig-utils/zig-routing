# zig-routing: a faithful, faster Zig port of Valhalla

## Context

We self-host Valhalla on a single 8 vCPU / 16 GB server ("the production routing box"), built from OSM for the US and Germany/Austria/Switzerland. The goal is to replace that box's
Valhalla with our own engine, written in Zig with no dependencies beyond Zig std and our own `zig-*`
libraries, that is API-faithful to Valhalla and measurably faster on every axis, then grow it into a
Mapbox / Apple Maps grade stack (geocoding and search, vector map tiles, live and historical traffic).

Decisions already made:

- **Name:** `zig-routing`.
- **Graph format:** our own native format from day one (not Valhalla `.gph` tiles).
- **Scope beyond Valhalla parity:** geocoding and search, vector map tiles, live and historical traffic,
  as later phases.

### What production actually sends today (the first cutover target)

| Caller | Endpoint | Request shape |
|---|---|---|
| Trail app | `POST /route` | `costing: pedestrian`, `costing_options.pedestrian {walkway_factor 0.6, sidewalk_factor 1, use_tracks 0.8, max_hiking_difficulty 3}`, `directions_type: none`, reads `trip.legs[].shape` (polyline6) |
| Trail app | `POST /height` | bulk: hundreds of thousands of trails |
| Training app | `POST /route` | pedestrian and bicycle, per-request options (`walkway_factor`, `use_tracks`, `use_living_streets`, `max_hiking_difficulty`, `step_penalty`; `use_roads`, `use_hills`), `directions_type: none`, legs up to 80 km |
| Training app | `POST /height` | route climb profile |
| `ts-maps` Valhalla providers | also has `/isochrone`, `/sources_to_targets` clients | not yet called by an app |

Both apps already use a server chain (`VALHALLA_URL` then `VALHALLA_FALLBACK_URL`), so cutover is an
env change with an automatic fallback. Every real request carries custom `costing_options`, so a
design that is only fast for default profiles does not count.

### Upstream facts that shape the plan (read from master, release 3.9.3, 2026-11-16)

- ~148k LOC C++ (mjolnir 42.6k, baldr 26.3k, odin 18.6k, thor 18.2k, sif 12.1k, midgard 9.2k, tyr 7.4k,
  loki 7.2k, meili 5.5k, skadi 0.9k) plus ~104k LOC of tests (124 unit files, 136 gurka files),
  `lua/graph.lua` 2,502 lines, 14 `.proto` files, 36 locale JSONs.
- Hard deps we must replace: protobuf, boost (property_tree et al.), prime_server + ZeroMQ, rapidjson,
  SQLite + SpatiaLite + GEOS, LuaJIT, libosmium + protozero, zlib, lz4, curl, Hinnant date/tz, vtzero,
  just_gtfs, libtiff/geotiff.
- Upstream has **no benchmark suite** (`bench/` deleted in #4560, no CI perf tracking, the
  `valhalla_run_*` / `valhalla_benchmark_*` tools were removed in March 2026). "Their perf scores" are
  scattered issue numbers, so we must measure the baseline ourselves on identical hardware and data.
- License: Valhalla is MIT. A port is fine with attribution (`NOTICE`, per-file "ported from" notes,
  locale files carried with their license).

### Upstream's documented pain points (what we design out)

| # | Problem | Evidence | Our answer |
|---|---|---|---|
| 1 | Many-to-many matrix is orders of magnitude behind OSRM in time and RAM (one independent search per location, single-threaded) | #2604, #973, #1825, #3556, #5172, #4937 | shared many-to-many over an acceleration structure, parallel, arena memory |
| 2 | Cold start / scale-out: whole tileset must be local, nothing warms the cache, lazy loading broken | **#3953**, #3117, #6206, #6422 | one mmap, zero-parse startup, native range-fetch lazy loading and warm-up in the format |
| 3 | Planet build is IO-bound with 250+ GiB intermediates, 4 to 24 h | #5099, #6201, #6312, #4548 | no Lua, compact intermediates, parallel every stage |
| 4 | Per-worker heap ratchets up, per-thread duplicated state | #5172, #4322, #4667, PR #5995 | per-request arenas reset wholesale, shared immutable graph |
| 5 | "Very conservative contraction": only ~2x over plain A*; time-dependent routes lose shortcuts and bidirectional search | #2604, #1895, #1190, D#5848 | exact goal-directed search that works with dynamic costs and time |
| 6 | Hierarchy pruning and shortcuts cause wrong or missing routes | #4527, #4609, #4656, #6091, #3874, #2979 | exact search, no heuristic pruning, no shortcut recovery |
| 7 | loki bins too coarse, meili keeps a duplicate grid | #2529, PR #5103 | one fine spatial index shared by snap, match, locate |
| 8 | Format ceilings (21-bit ids, 25-bit edgeinfo offset, 127 edges/node, 7 shortcuts/node), broken forward compat | #6148, #6217, #5098, #6239 | wide ids, sectioned file with version, checksums and a section table |
| 9 | Hangs, unbounded recursion, missing cancellation | #3823, #4398, #6294 | deadline checked in every loop, no recursion in search |
| 10 | Protobuf round-trips between loki/thor/odin, slow JSON layer, ~15 threads per worker | #5190, #1825, #4771 | single process, thread per core, direct structs, streaming JSON writer |

---

## Scoreboard: what "beat their perf" means

Phase 0 measured Valhalla 3.9.3 on the production box class and the US+DACH extract.
The [baseline scoreboard](SCOREBOARD.md) records those measurements alongside the targets below.

| Axis | Upstream reference | zig-routing target |
|---|---|---|
| `/route` pedestrian/bicycle with custom options, 1 to 80 km (our real traffic) | to be measured in Phase 0 | p50 and p99 at least 5x lower |
| `/route` auto 200 / 1000 / 4000 km | ~485k / ~800k / ~1M edges touched (upstream notes) | at least 20x fewer edges settled, p50 at least 10x lower |
| Time-dependent 350 km | ~3M edges (no shortcuts, unidirectional) | same engine as static, at least 50x fewer |
| Matrix 100x100, 1000x1000 | 1000x1000 = 111 s (2017, #973); OSRM 12 to 31 s | 1000x1000 under 5 s with the v2 overlay, beating OSRM's published numbers; v1 at least 5x Valhalla |
| Matrix RAM | 572x572 = 12 GB (#3556) | under 1 GB |
| `/height` bulk | to be measured | at least 10x points/s |
| Isochrone, map matching | to be measured | at least 5x |
| Planet build | ~4 h (16 vCPU, no ped/bike) to ~7 h (32 vCPU full) | under 1 h on 32 vCPU, scratch under 100 GiB |
| Startup to first request | tar scan / page-cache cold | under 1 s, first-request p99 within 2x of warm |
| RSS per worker after soak | 2 to 2.5 GB and growing (#5172) | flat, under 256 MB scratch per thread |

Results are published in the repo (`bench/RESULTS.md`) with hardware, data and commit, and tracked in
CI on a fixed box so regressions are visible (the thing upstream lacks).

---

## Architecture

### Principles

1. **Faithful semantics, new implementation.** Same endpoints, request and response JSON, error codes,
   costing formulas and option names/ranges/defaults as Valhalla. Costing and narrative are ported
   function by function with a "ported from `src/sif/pedestriancost.cc`" note per file.
2. **Exact search.** No hierarchy pruning heuristics. Where Valhalla's pruned search returns a worse
   route, ours may differ by being cheaper; parity is defined under Valhalla's own cost function
   (see Verification).
3. **Data-oriented.** Dense ids, struct-of-arrays hot data, cold data out of the cache's way, zero
   steady-state allocation per request.
4. **One process, thread per core.** Shared immutable mmap; per-thread scratch arenas; no IPC, no
   intermediate protobuf.
5. **Zero external deps.** No C libraries, no Lua, no SQLite. Docker Valhalla is used only as a
   dev-time test oracle, never linked or shipped.

### Module map (upstream to ours)

`src/`

| Ours | Upstream | Contents |
|---|---|---|
| `geo/` | midgard | PointLL, AABB, distance approximator, polyline 5/6/7 codec, tile and cell math, Hilbert order, clipping, simplification, marching-squares contouring, packed R-tree |
| `graph/` | baldr | native format, reader, ids, attribute enums, access masks, datetime + timezones, restrictions, signs, lanes, traffic overlay |
| `costing/` | sif | `auto` (+bus, taxi), `truck`, `motorcycle`, `motor_scooter`, `bicycle`, `pedestrian`, `transit`, `none`; option parsing; recost |
| `snap/` | loki | candidate search, projection, reachability, node search, avoid-polygon search, connectivity |
| `search/` | thor | bidirectional and unidirectional A*, Dijkstra base, multimodal, matrix, isochrone, expansion, centroid, alternates, optimizer, trip-leg builder |
| `accel/` | (new) | lower-bound metrics, contraction hierarchy potentials, customizable hierarchy for matrices |
| `match/` | meili | HMM / Viterbi, top-k, candidate search, transition and emission models, route matching |
| `narrative/` | odin | maneuver builder, narrative builder, signs, markup, locale dictionaries |
| `api/` | tyr + `src/worker.cc` | request parsing (JSON, query string, pbf), serializers (Valhalla JSON, OSRM, GPX, pbf, GeoJSON, MVT), error codes |
| `elevation/` | skadi | `.hgt` / `.hgt.gz` / `.hgt.lz4` sampling, bilinear, mmap cache |
| `build/` | mjolnir | OSM PBF reader, tag transform (replaces `graph.lua` / `admin.lua`), graph construction, enhancement, restrictions, admins, timezones, elevation stamping, transit, validation |
| `server/` | prime_server + service | HTTP/1.1 server, routing table, limits, deadlines, metrics, hot reload |
| `traffic/`, `tiles/`, `geocode/` | (later phases) | live/predicted speeds, basemap vector tiles, search |
| `cli/` | tools | one binary `zr`: `build`, `serve`, `route`, `bench`, `diff`, `inspect`, `import-valhalla` |

### Dependencies: reuse, std, and new libraries

| Need | Source |
|---|---|
| CLI | `zig-cli` (`src/root.zig`: `Command`, `Option`, `Parser`) |
| Config (reads Valhalla-style `valhalla.json`) | `zig-config` (`loadConfig`, `deepMerge`) |
| Benchmarks | `zig-benchmarks` (`BenchmarkSuite`, `Stats`, flamegraph, CI export) |
| Tests | `std.testing` + `zig-test-framework` (snapshots for narrative and serializer goldens) |
| TLS (HTTPS fetch of tiles, traffic feeds, DEM) | `zig-tls` |
| XML (OSM XML input, GPX) | `zig-xml` |
| Conditional-restriction / opening-hours patterns | `zig-regex` where a hand-written parser is not clearer |
| JSON, inflate/deflate, tar, zip, md5, heaps, bitsets, TZif, event loop | Zig std (`std.json`, `std.compress.flate`, `std.tar`, `std.zip`, `std.crypto`, `std.priority_queue`, `std.tz`, `std.Io` Kqueue/Uring) |
| **New, written for this project** | protobuf wire codec with comptime message schemas (OSM PBF, Valhalla pbf API, MVT, GTFS-realtime); LZ4 block/frame; OSM PBF reader; geo kernel; HTTP server tuned for thread-per-core; IANA tz rules + timezone polygons; GTFS (CSV in zip) |

The new pieces start as `packages/` inside the repo (path deps, so APIs can move daily) and are
extracted to standalone `zig-<name>` repos (`zig-protobuf`, `zig-geo`, `zig-lz4`,
`zig-osm`, `zig-http`, `zig-tz`) once stable, consumed by the house convention (URL + hash pin). Scaffold from `zig-starter`.

**Toolchain:** pin one Zig 0.17-dev build through `deps.yaml` / pantry (pantry-mirrored, since
ziglang.org dev builds get garbage-collected). Candidates today: `0.17.0-dev.1857` or newer. `zig-tls` needs at least `.1476`, so the pin is
`.1857` or newer after confirming `zig-cli`, `zig-config`, `zig-tls`, `zig-xml`, `zig-benchmarks`
build on it. `zig-js` (0.18-dev) is deliberately not used: tag transforms are native Zig, not script.

### Native graph format (v1)

A **bundle** is a directory per region (US, DACH, later planet), one little-endian file per section,
mmap'd. The server loads several bundles and dispatches by location, so DACH rebuilds without touching
the US. Each file has a 64-byte header (magic, format version, dataset UUID, section kind, record
size, count, xxh3 of the payload); startup checks headers only, `zr inspect --verify` checks hashes.
Sections are 64 KiB aligned so they can be range-fetched and lazily filled (the #3953 problem).

- **Ids:** dense `u32` node and directed-edge ids behind opaque `enum(u32)` types (planet is ~1B edges
  against a 4.29B ceiling; widening is a recompile plus a format bump). No level/tile/id triples.
- **Node order:** nested dissection, and node id equals elimination rank of the acceleration
  hierarchy. Cells are contiguous id ranges, so locality, cold-data chunking and the hierarchy share
  one ordering and need no permutation arrays.
- **Hot topology (struct of arrays):**

```zig
const EdgeHot = extern struct {   // 16 B per directed edge (Valhalla: 48 B)
    head: u32,                    // end node
    geom: packed struct(u32) { len_m: u24, grade: u4, curvature: u4 },
    cls:  packed struct(u32) { class_id: u20, local: u5, opp_local: u5, cold_checks: u1, pred_speed: u1 },
    speed: [4]u8,                 // speed, free_flow, constrained, truck (kph)
};
const NodeHot = extern struct {   // 8 B, plus first_edge: u32 in its own array (CSR)
    turn_off: u32,                // into a deduplicated per-intersection turn-table pool
    attr: packed struct(u32) { access: u16, type: u4, density: u4, signal: u1, _pad: u7 },
};
// turn entry (u8): turn_type:3 | stop_impact:3 | name_consistent:1 | restricted:1
```

- **Edge classes:** `class_id` indexes a deduplicated table of the categorical tuple costing reads
  (use, road class, surface, access masks, toll, tunnel, bridge, roundabout, link, internal,
  destination-only, sac_scale, lit, sidewalk, cycle lane, bike network, dismount, hov, truck route).
  A request's compiled factor table is indexed by it, so "is this edge allowed and what is its
  factor" is one load.
- **Turn model:** per-node turn tables, labels per directed edge; the edge-expanded graph is never
  materialised. Simple restrictions are a bit in the turn entry. Complex (multi-via), timed and
  per-mode restrictions live in `restr.bin`; truck dimensions and hazmat in a side table reached only
  when `cold_checks` is set.
- **Cold data**, chunked by cell: way id (u64), shape (delta varint, 1e-7 degrees), names in a
  deduplicated string table, signs, lanes, lane connectivity, speed limits, elevation samples, admin
  and timezone. Read by narrative, serializers and `/locate`, never by the relax loop.
- **One spatial index** for snapping, map matching and `/locate`: a 1/256 degree grid with a sorted
  directory of non-empty cells and delta-varint edge lists.
- **Traffic overlays** beside the base files: `traffic-live.bin` (one 8-byte record per drivable edge,
  written in place by a feeder, read with one aligned load) and `traffic-pred.bin` (deduplicated
  weekly profiles). A stable key map (way id + node pair to edge id) is emitted for ingest because
  ids change per build.
- **Limits lifted vs Valhalla:** 21-bit per-tile ids, 7-bit opposing index (ours is computed, not
  stored), 25-bit edgeinfo offset, 15 names per edge, 65,535-byte shapes, 12-bit access masks.

Estimated sizes (to be confirmed by experiment E5; assumes US+DACH is ~27% of planet):

| Component | Planet | US+DACH |
|---|---|---|
| Hot topology + turn tables | 22.5 GB | 5.8 GB |
| Coordinates, cold index (evictable) | 9 GB | 2.2 GB |
| Cold shapes/names/attributes (page cache) | 25 to 30 GB | 7 GB |
| Spatial index | 2 to 3 GB | 0.5 GB |
| Acceleration topology | 8 GB | 1.8 GB |
| One customised metric | 6 GB | 1.3 GB |

US+DACH resident set with three cached metrics and eight threads of scratch is ~12.7 GB of the
box's 16 GB: tight but workable, with "two metrics" as the pressure valve. Planet wants 96 to 128 GB.

### Query engine

**The core problem:** Valhalla's defining feature is arbitrary per-request costing, and classic
speedups (CH, MLD) assume a fixed metric. A fixed per-mode lower bound scaled by the request's
smallest factor is not good enough either: published measurements show a uniform 5% gap between
query weights and the bound slows such searches ~25x, and `walkway_factor: 0.6` is a 40% gap on
exactly the requests our apps send.

**Chosen design: one exact search, guided by potentials customised to the request's own costs.**

1. **One search core.** Label-setting A* on the real graph, labels per directed edge, the full
   dynamic costing evaluated at relax time (time-dependence, live traffic, avoid polygons, excluded
   edges, truck checks, restrictions all live here, none need hierarchy support). Arrive-by is the
   mirrored search. Used by route, isochrone (no potential), map matching (bounded), matrix.
2. **Costing compiles to data.** Each request's options compile (about 100 microseconds, cached) into
   a small POD: class-to-factor table, speed-to-seconds table, turn-class-to-cost table, scalars.
   Three or four comptime-monomorphised kernels (motor, bicycle, pedestrian, multimodal) read it, with
   no virtual calls. The nine Valhalla models differ in tables more than in code.
3. **Potentials from a customizable contraction hierarchy.** A node-based, turn-free CCH is built
   once per bundle. A **metric** is customised for the compiled cost table (lower-bound edge weight
   = length x seconds-per-metre at the edge's fastest speed x class factor + minimum incoming turn
   cost + entry penalty), keyed by a 128-bit hash of that table. A* potentials are read lazily from
   it (the CH-Potentials / lazy RPHAST technique). Because the bound is built from the request's own
   factors, sub-1 factors cannot break it. Customising US+DACH is an estimated 5 to 10 s on 8
   threads; metrics persist to disk and are mmap'd on restart. Our apps send a handful of constant
   option sets, so after first use every request hits a cached metric.
4. **Fallback ladder.**
   - L0: exact metric cached (the normal case).
   - L1: key miss: use the closest cached metric of the same mode scaled by the worst class-factor
     ratio (still admissible), and customise the new key in the background once it repeats.
   - L2: no hierarchy mapped: haversine x fastest speed, i.e. upstream's behaviour.
   An admission filter plus LRU bounds memory for slider-style clients.
5. **Admissibility contract** every costing kernel must satisfy, enforced by a relax-time assertion
   in debug builds and a property fuzzer over the legal option ranges: (I1) edge lower bound never
   exceeds the real edge cost at any time or traffic state; (I2) turn lower bound never exceeds the
   real transition cost; (I3) costs are non-negative, forbidden is infinite; (I4) request features
   are either monotone (only remove edges or add cost) or supply a scalar floor; (I5) bounds are
   rounded down.
6. **Complex restrictions** become an automaton state in the label (exact), instead of upstream's
   predecessor-chain walk.
7. **Matrix.** v1: one potential context per target shared across sources, exact search per pair,
   parallel across cores. v2 (pulled forward if experiment E6 says so): a turn-aware multilevel
   overlay on the same separator tree, customised per metric key, for one-to-many in a few
   milliseconds per source.
8. **Alternates:** penalty method on the same search. **Time-dependent and live traffic:** same
   search with the free-flow bound first, time-dependent potentials later.

**Hot loop mechanics**

- Label 32 B (`cost f32, secs f32, pred u32, edge u32, dist u32, tcost f32, flags u32, ctx u32`);
  costs stay `f32` so recosting matches upstream arithmetic.
- Queue is a comptime parameter: 4-ary heap of `{key u32, label u32}` with lazy deletion for guided
  searches, exact radix queue for isochrones, and two-level bucket queue for other sweeps.
- Edge status and potential memo: two-level paged arrays (directory by `id >> 12`, pages bumped from
  the request arena). No hashing, no per-thread dense arrays (those would be 8.6 GB on US+DACH),
  reset by rewinding the arena.
- One arena per worker, reset per request, high-water retained: zero steady-state allocation.
- `@Vector` SIMD for snap projections, shape decode / polyline encode, predicted-speed DCT,
  customisation passes, isochrone grid updates.
- Deadline plus atomic cancel flag checked every 1024 pops.
- Zig rules: `extern struct` on disk with `packed struct(u32)` members only, comptime size/offset
  and endianness assertions, cold checks `noinline`, a binary-size budget in CI to catch
  instantiation bloat, `std.Io` behind one shim file.

**Expected results (estimates until measured):** with an exact metric cached, 10 km ~0.3 to 1 ms,
200 km ~1 to 4 ms, 1000 km ~4 to 15 ms, 4000 km ~10 to 40 ms on one thread; time-dependent or
traffic-heavy long routes 10 to 30x that until time-dependent potentials land.

### Performance engineering rules (apply to every phase)

The architecture above is where the order-of-magnitude wins come from. These rules keep the
constant factors and the tail honest; each becomes its own tracked issue.

- **Budgets, not hopes.** Every endpoint has a per-phase time budget (parse, snap, search, build
  legs, serialize) recorded in the access log and asserted in `zr bench`. A PR that regresses a
  tracked benchmark by more than 3% fails CI on the dedicated bench box.
- **Zero steady-state allocation.** A counting allocator in tests asserts no heap calls after
  warm-up for every endpoint. Per-request memory is capped; over the cap is a clean error, not OOM.
- **Measure the machine.** Benchmarks record cache misses, branch misses and instructions per
  settled label (perf counters on Linux), not only wall time. Flamegraphs are attached to every
  perf PR.
- **Memory placement.** Hot sections get transparent huge pages (`MADV_HUGEPAGE`) and optional
  `mlock`; cold sections `MADV_RANDOM`; a warm-up pass (`MADV_WILLNEED` over hot sections, then the
  cells under recent traffic) runs at startup so first requests are not page-fault bound (the gap
  upstream left open in #3117).
- **Build flags.** `ReleaseFast`, LTO, an `x86-64-v3` build for the production box plus a baseline
  x86-64 and an aarch64 build; hot kernels dispatch on CPU features where it pays (AVX2 / NEON).
- **IO path.** `SO_REUSEPORT` listener per thread, pipelined keep-alive, `writev` of arena buffers
  with no copies, response compression off by default (CPU is better spent on routing behind a
  private network).
- **Parsing and serialization.** Requests are scanned straight into structs (no DOM, no
  intermediate protobuf). Responses stream through a writer with fixed-precision number printing
  and SIMD polyline encoding. Locale templates and the tag-transform tables are compiled in at
  comptime, so nothing is parsed at startup.
- **Elevation.** DEM tiles are served from our own block-compressed, mmap-friendly layout (built
  once from `.hgt`); bulk `/height` sorts points by tile and samples in SIMD batches.
- **Tail latency under load.** Separate scheduling classes so a large matrix or isochrone cannot
  starve short routes; bounded intra-request parallelism; admission control and load shedding with
  the upstream-compatible error; deadlines everywhere.
- **Caching where it is exact.** Compiled costing and customised metrics by key; potential contexts
  for hot targets; an optional response cache keyed by snapped edges, metric key and traffic epoch.
- **Build throughput.** Every stage reports rows per second and peak RSS; intermediates are
  sequential, compact and never externally sorted when input order already gives sortedness.
- **Scale-out.** Bundles are range-fetchable from object storage, so a new instance serves from a
  sparse local file while it fills (the design #3953 asks for).

**What this plan can and cannot promise.** The layout, single-process service, exact search and
build design are well-understood wins. The headline multipliers rest on experiments E1 to E8:
published results support them, but they are estimates until measured on our data, which is why
those experiments come first in Phase 4 and each has a fallback.

### Build pipeline (replaces mjolnir)

Stages, all parallel, each restartable (`zr build --from <stage>`):

1. **Read PBF**: blobs inflated and decoded on all cores (std flate, or LZ4); dense nodes delta-decoded
   straight into a sorted node-location table. OSM ids are already nearly sorted in a PBF, so node
   coordinates go into a compact delta-coded on-disk array indexed by id, instead of upstream's
   ~110 GiB `way_nodes.bin` external sort.
2. **Tag transform**: `graph.lua` (2,502 lines) and `admin.lua` ported to Zig as comptime
   perfect-hash tag tables plus plain functions. Runs on every core (upstream caps Lua at 8 states).
   Golden-tested against upstream's Lua output for every tag combination in the test PBFs.
3. **Ways to edges**: intersection detection by node use count (bitset), edge splitting, shape capture.
4. **Graph assembly**: nodes ordered for locality, CSR adjacency, attributes, names, signs, turn lanes,
   lane connectivity, opposing-edge links, per-node turn data.
5. **Enhance**: port of `graphenhancer.cc`, `countryaccess.cc`, `linkclassification.cc` (density,
   speeds, turn types, link reclassification, country access defaults, name consistency).
6. **Admins and timezones**: admin polygons assembled from OSM boundary relations with our own ring
   builder (replaces GEOS + SpatiaLite), timezone polygons from timezone-boundary-builder GeoJSON,
   both stored in a packed polygon index inside the graph file. No SQLite.
7. **Restrictions**: simple, complex (multi-via), conditional/timed, access restrictions.
8. **Elevation stamping**: grades, slopes, mean elevation from DEM.
9. **Acceleration**: lower-bound metrics and hierarchy, per mode (see Query engine).
10. **Spatial index, bins, validation, stats, checksums.**
11. Later: transit (GTFS ingest), bike share, landmarks, predicted traffic.

### Server

- HTTP/1.1 keep-alive on `std.Io` (io_uring on Linux, kqueue on macOS), thread per core, each thread
  with a reusable scratch arena reset after every request.
- Valhalla-compatible: every action as `GET ?json=` and `POST` body, `application/x-protobuf` in and
  out, the same `service_limits`, same error JSON (`error_code`, `error`, `status_code`, `status`).
- Deadline and cancellation checked inside every search loop; client disconnect cancels work.
- `/status` (with `verbose`), Prometheus-style metrics, access log with per-phase timings.
- Hot reload: new graph file mapped beside the old one and swapped atomically (upstream cannot, #3938).
- Config: reads the existing `valhalla.json` keys we honor, plus our own section.

---

## Phases

Ordered so the box is replaced as early as possible (Phases 1 to 3 cover 100% of what our apps send
today), then widened to full Valhalla parity, then the extra services. Each phase ends with its gate
green in CI. Sizes are the upstream code being ported.

### Phase 0: Baseline, oracle and harness

- Read-only inventory of the production routing box: Valhalla version, `valhalla.json`, tileset and DEM size,
  RSS, and a day of real request shapes from the consuming apps.
- Reproduce that setup locally and on a bench box: Valhalla 3.9.3 in Docker on the same US+DACH PBFs.
- Request corpora: upstream `test_requests/` (256 files), `de_benchmark_routes`, plus a synthetic
  corpus shaped like our production traffic (pedestrian/bicycle with our option sets, bulk `/height`).
- `zr bench` (load generator + latency histograms) and `zr diff` (replays a corpus against two servers
  and scores parity). Record the baseline scoreboard.
- Scaffold the repo, pin the toolchain, CI (build, test, fmt) matching the other `zig-*` repos.
- **Gate:** baseline numbers committed; `zr diff valhalla valhalla` reports 100% parity.

### Phase 1: Foundations

`geo/` kernel (midgard, 9.2k), polyline codecs, protobuf wire codec, LZ4, streaming JSON writer and
request parser, HTTP server, config loading, error codes, the gurka-style ASCII-map test DSL
(`test/gurka/gurka.h` ported so upstream's 136 gurka tests can be carried over as the behaviour spec).

- **Gate:** midgard unit tests ported and green; HTTP server beats prime_server on an echo benchmark.

### Phase 2: Elevation, the first production slice (`/height`)

Port skadi (0.9k): `.hgt`, `.hgt.gz`, `.hgt.lz4`, bilinear sampling, mmap cache, `range`, `shape` and
`encoded_polyline` inputs, `height_precision`, `resample_distance`. No graph needed.

- Deploy `zr serve` on the production routing box on a second port reading the same DEM files; shadow-compare
  against Valhalla; then point the consuming apps' elevation calls at it with Valhalla as
  fallback.
- **Gate:** byte-identical `/height` responses on the corpus; at least 10x points/s; a
  bulk elevation repair run completes against it.

### Phase 3: Pedestrian and bicycle routing, the second production slice (`/route`)

- OSM PBF reader, tag transform for all attributes (not only foot/bike, the transform is ported once),
  graph assembly, native format v1, spatial index.
- `snap/` (loki `search.cc`, `reach.cc`), the exact search core at ladder level L2 (no hierarchy
  yet), `pedestriancost.cc` and `bicyclecost.cc` ported in full with every option, elevation-aware
  costs (`use_hills`, grades).
- `/route` with `directions_type: none` (shape, summary, legs), multiple locations, `via`/`through`
  types, `units`, error codes 154/171/442 etc. as upstream.
- Runs experiments E1 and E8 below as part of the phase.
- **Gate:** parity gates A, B and C (see Verification) on the pedestrian/bicycle corpus, length/time
  within 1%, and p50/p99 no worse than Valhalla. Then cut over: `VALHALLA_URL` points at
  zig-routing, Valhalla stays as fallback for a soak.

### Phase 4: Acceleration and scale

Nested-dissection ordering (our own inertial-flow partitioner), CCH build and customisation, lazy
potentials, the metric cache and fallback ladder, lazy loading and warm-up, planet-scale build.
This is where the 5x-and-up scoreboard rows are won. It starts with the de-risking experiments,
each with a pass line and a consequence:

| # | Experiment | Pass | If it fails |
|---|---|---|---|
| E1 | Edge-based Dijkstra on Germany, pedestrian + auto kernels | at most 150 ns per settled label, at least 5x upstream label throughput | revisit record layout |
| E2 | Exact-key potentials with real costing, turn-cost folding on/off | pedestrian 10 km p95 under 1 ms; auto 500 km p95 under 15 ms | stronger folding or an edge-based bound for motor |
| E3 | L1 scaling at `walkway_factor: 0.6` | p95 no worse than upstream | two-metric max or factor-grid snapping |
| E4 | Ordering + customisation on US+DACH | order under 30 min and customisation under 10 s on 8 threads; metric under 1.5 GB | better partitioner first |
| E5 | Full bundle, mixed load, three metrics | RSS under 13 GB | two metrics or per-mode hierarchy |
| E6 | 50x50 urban and 200x200 regional matrix, v1 | under 100 ms and 1.5 s on 8 cores | pull the matrix overlay forward |
| E7 | Berlin to Prague with `date_time`, synthetic congestion | under 150k labels, 40 ms; congested p95 under 250 ms | pull time-dependent potentials forward |
| E8 | Parity gates A to C on 100k random routes | thresholds in Verification | costing port is wrong: stop and fix |

- **Gate:** E1 to E8 pass or their fallback is in place; pedestrian/bicycle p50 and p99 at least 5x
  better than Valhalla; planet build under target; US+DACH serves within the 16 GB box.

### Phase 5: Motor vehicle costing and full restriction semantics

`autocost.cc` (auto, bus, taxi), `truckcost.cc` (dimensions, hazmat, axle load), `motorcyclecost.cc`,
`motorscootercost.cc`; simple, complex and timed restrictions; access restrictions; destination-only
and private access; closures; avoid/exclude locations and polygons; time-dependent routing
(`date_time` types 0 to 3) with timezones and DST; `recost`; `linear_cost_factors`; alternates.

- **Gate:** upstream `astar`, `sif`, restriction and time-dependent gurka suites ported and green;
  auto/truck corpora at cost parity.

### Phase 6: Narrative and serializers (odin 18.6k + tyr 7.4k)

Trip-leg builder (`triplegbuilder.cc`), maneuver builder, narrative builder, all 36 locales, signs,
lanes, verbal instructions; Valhalla JSON, OSRM, GPX and pbf output; `directions_type`
`maneuvers` / `instructions`.

- **Gate:** upstream `narrativebuilder`, `maneuversbuilder` and OSRM serializer tests ported and green;
  maneuver-for-maneuver equality with Valhalla on the corpus where paths match.

### Phase 7: The remaining graph endpoints

`/sources_to_targets` (with `verbose`, `shape_format`), `/optimized_route`, `/isochrone` (polygons,
lines, `denoise`, `generalize`, GeoTIFF later), `/expansion`, `/centroid`, `/locate`, `/status`,
`/transit_available`, `/tile` (Valhalla's graph MVT).

- **Gate:** matrix, isochrone and expansion scoreboard rows; matrix cells within tolerance of
  Valhalla's `/route` for the same pair (upstream's own matrix disagrees with its routes, #5811).

### Phase 8: Map matching (meili 5.5k)

`/trace_route`, `/trace_attributes` (`shape_match` `edge_walk` / `map_snap` / `walk_or_snap`), using
the shared spatial index and bounded goal-directed searches.

- **Gate:** upstream `mapmatch` tests ported and green; throughput target met; memory bounded in bytes.

### Phase 9: Transit and multimodal

GTFS ingest (zip + CSV), transit level, `multimodal_astar`, `transitcost`, bike share, transit
narrative.

### Phase 10: Traffic

Live speed overlay (separate mmap, updated in place by a feeder), predicted speeds with deduplicated
weekly profiles, incidents, ingestion from feeds, traffic-aware ETAs on the same accelerated search.

### Phase 11: Vector map tiles

Basemap MVT built from the same OSM extract (schema chosen to match the styles `ts-maps` renders),
served by the same binary, with tile caching and range-request archives.

### Phase 12: Geocoding and search

Forward and reverse geocoding and autocomplete from OSM (addresses, places, POIs), with Photon- and
Nominatim-compatible endpoints so `ts-maps`' existing `PhotonGeocoder` / `NominatimGeocoder` clients
work unchanged; replaces the public servers the apps call today.

### Phase 13: Cutover complete

Remove the Valhalla fallback, decommission the old service, publish bindings (C ABI and a Bun FFI
package for Stacks apps), write the migration guide in `ts-maps` docs.

---

## Verification

1. **Ported upstream tests.** Unit tests (`test/*.cc`) ported with each module; gurka tests ported onto
   our ASCII-map DSL. They are the behaviour spec.
2. **Differential oracle (`zr diff`).** A corpus replayed against Valhalla and zig-routing, scored by
   these gates. "Faithful" is defined under Valhalla's own cost function, because an exact search
   will sometimes return a strictly cheaper route than Valhalla's pruned one. No "compat" algorithm
   reproducing hierarchy pruning is built; instead the oracle is also run with hierarchy pruning
   disabled (the option's exact name and limits are confirmed against 3.9.3 in Phase 0).

   | Gate | Metric | Threshold |
   |---|---|---|
   | A. Costing parity (hard) | per-call edge and transition cost on 10^7 sampled cases; recost of oracle paths vs oracle-reported cost | 1e-5 per call, 1e-4 per path |
   | B. Optimality (hard) | our cost of our path is at most our cost of the oracle's path | 100% |
   | C. Same graph, pruning off | cost ratio | within 1e-4 on 99.9% |
   | D. Default oracle | among routes within 0.1% cost: shape overlap at least 0.98, maneuver type and name sequence equal, time within 1%, distance within 0.5% | 95%; cheaper routes are classified by cause, not failed |
   | E. Matrix | cell within 1% or 5 s, remainder must be ours cheaper | 99% of cells |
   | F. Isochrone | polygon intersection-over-union | at least 0.97 |
   | G. Map matching | matched edge sequence equal | 99% of traces |
   | H. API | JSON keys, types, enums, error codes; `/height` values | exact |
3. **Same-graph oracle.** `zr import-valhalla` (test-only, never a runtime path) converts Valhalla
   tiles into our format so algorithm differences are separated from tag-transform and builder
   differences. It needs the exact upstream bitfield layouts (`directededge.h`, `nodeinfo.h`,
   `graphtileheader.h`), which are recorded in the research notes for this plan.
4. **Tag-transform goldens.** Upstream `graph.lua` run under LuaJIT in the oracle container over every
   way/node in the test PBFs; our Zig transform must produce identical attribute tables.
5. **Fuzzing.** `std.testing.fuzz` on the request parser, PBF reader, format loader, polyline codec.
6. **Performance.** `zr bench` on the fixed corpora, results in `bench/RESULTS.md`, tracked per commit
   on a dedicated box; flamegraphs via `zig-benchmarks`.
7. **Production shadow.** zig-routing runs beside Valhalla on the production routing box; a sample of live
   requests is mirrored and diffed before each cutover step; the apps' existing fallback chain is the
   rollback.

## Risks

- **Size.** ~148k LOC plus tests is a multi-month program. Mitigation: production value lands in
  Phases 2 and 3; every phase is independently shippable.
- **Zig 0.17-dev churn** (`std.Io` especially). Mitigation: one pinned toolchain, IO behind a thin
  internal interface, toolchain bumps as their own change.
- **Tag-transform and costing parity** are thousands of small rules. Mitigation: goldens against
  upstream Lua and line-by-line ports with the upstream tests.
- **Narrative parity** (odin is mostly rules and strings). Mitigation: port its 498 KB test file.
- **Turn-cost looseness in cities** (Valhalla's transition costs are large, which loosens any
  turn-free bound). This is the make-or-break experiment, E2.
- **Metric-key explosion** from clients that send ever-changing options. Mitigation: admission
  filter, LRU, optional factor-grid snapping (E3).
- **Home-grown partitioner quality** inflating hierarchy size and customisation time (E4).
- **Matrix v1 not "much faster"** without the overlay (E6 decides).
- **Hidden non-monotone costing quirks** breaking the admissibility contract. Mitigation: the
  option-range fuzzer and the debug relax-time assertion.
- **16 GB box.** Mitigation: memory budget is a Phase 3 and Phase 4 gate.
- **Data licenses:** OSM and timezone-boundary-builder are ODbL; attribution in responses and docs.

## GitHub issue graph

The plan is tracked as GitHub issues that agents work top to bottom.

- **Repository:** `zig-utils/zig-routing` (the org the other `zig-*` libraries live in; the name is
  free). Public.
- **Context agents need, committed first** so every issue can link to it instead of repeating it:
  `AGENTS.md` (rules: zero deps, pinned toolchain, extern-struct rules, perf rules, how to pick an
  issue, how to run tests/bench/diff), `docs/PLAN.md` (this plan), `docs/ARCHITECTURE.md` (format
  and engine design), `docs/upstream/` (the research: Valhalla module map and file list, exact tile
  bitfield layouts, build stages, API and proto inventory, the perf-issue survey with numbers),
  `docs/SCOREBOARD.md`, `NOTICE` (Valhalla MIT attribution).
- **Milestones:** one per phase (`P0 Baseline` to `P13 Cutover`).
- **Labels:** `phase:0..13`, `area:geo|graph|costing|snap|search|accel|match|narrative|api|elevation|build|server|traffic|tiles|geocode|cli|infra`,
  `type:port|new|perf|test|infra|experiment`, `size:S|M|L`, `ready` / `blocked`, `gate`.
- **Shape:** one tracking epic per phase with a task list, then leaf issues sized for one agent
  session each. Roughly 180 leaf issues:

  | Phase | Issues | Examples |
  |---|---|---|
  | P0 | ~8 | scaffold + toolchain pin; box inventory; Docker oracle; corpora; `zr bench`; `zr diff`; baseline scoreboard |
  | P1 | ~16 | PointLL/AABB/distance; polyline codecs; cell math; protobuf wire codec; LZ4; JSON writer; request parser; HTTP server; error codes; ASCII-map test DSL |
  | P2 | ~7 | hgt reader; bilinear sampler; `/height` API; DEM repack; SIMD batch; shadow deploy; cutover |
  | P3 | ~22 | PBF blob reader; dense nodes; tag transform (several issues by tag family); ways to edges; graph assembly; format writer/reader; spatial index; snap; search core; pedestrian costing; bicycle costing; `/route` serializer; parity run; cutover |
  | P4 | ~20 | E1 to E8 (one issue each); partitioner; CCH build; customisation; lazy potentials; metric cache; fallback ladder; restriction automaton; lazy loading; warm-up; planet build |
  | P5 | ~18 | auto, bus, taxi, truck, motorcycle, motor scooter; restriction families; time-dependent search; timezones; alternates; avoid polygons; recost |
  | P6 | ~16 | trip-leg builder; maneuver builder (split by rule family); narrative builder; locales; signs/lanes; OSRM, GPX, pbf serializers |
  | P7 | ~14 | matrix v1; matrix overlay; isochrone + contouring; expansion; centroid; optimized route; locate; status; graph MVT |
  | P8 | ~8 | candidate search; Viterbi; transition/emission models; trace_route; trace_attributes |
  | P9 to P12 | ~40 | GTFS ingest, multimodal; traffic overlay, feeder, predicted speeds; basemap tiles; geocoder index, query, API compat |
  | P13 + perf rules | ~13 | fallback removal; bindings; migration guide; one issue per performance rule above |

- **Issue template** (every leaf issue): Goal; Upstream reference (files at the pinned 3.9.3 commit,
  and the upstream tests to port); Scope and out of scope; Design notes (links into `docs/`);
  Acceptance criteria (tests, parity gate, perf budget); `Blocked by #N` list; size.
- **Order:** issues are created in dependency order from a checked-in manifest
  (`scripts/issues.json` + a small script that calls `gh issue create`, throttled to stay under
  GitHub's content-creation limits), so issue numbers ascend in execution order. A pinned
  "Start here" issue states the rule for agents: take the lowest-numbered open issue labelled
  `ready` whose blockers are all closed; when an issue closes, its dependents flip from `blocked` to
  `ready`.

## First steps

1. Create the repository from `zig-starter`, pin the toolchain, add CI, commit the
   `docs/` and `AGENTS.md` context.
2. Create the public `zig-utils/zig-routing` repository, push, then create milestones, labels and
   the full issue graph from the manifest. Report the count and the link.
3. Phase 0 inventory of the production routing box (read-only) and the Docker oracle.
4. `zr bench` + `zr diff`, baseline scoreboard.
5. Phase 1 foundations, then Phase 2 (`/height`) as the first deployable slice.
