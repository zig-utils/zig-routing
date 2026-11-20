# zig-routing core design: speedup technique, graph format, hot loop

Figures marked (est.) are my extrapolations; cited figures come from the papers listed under Sources. A few upstream details are from memory and marked as such.

## Verdict on your leaning

Keep CH-Potentials plus one exact edge-based search, comptime costing, monolithic hot SoA and a traffic overlay. Change four things:

1. **Scalar scaling by the minimum cost factor is the fatal weak point.** Strasser and Zeitz measured it: on OSM Germany a uniform 5% gap between query weights and lower bound takes the query from 0.6 ms to 15.7 ms, and "no highways" runs at 343 ms, only 5.4x faster than Dijkstra. `walkway_factor: 0.6` leaves the bound 40% loose on every non-walkway edge, which is the collapsed regime for exactly the pedestrian and bicycle clients you must serve.
2. **A node-based CCH cannot produce turn-exact matrices, and an edge-based CCH does not fit 16 GB.** "CCH canonical metrics for matrices" needs a different structure.
3. **40-bit ids are unnecessary.** Planet has 1B directed edges against a 4.29B limit for u32.
4. **Choose nested dissection, not Hilbert, and make node id equal to CCH elimination rank.**

## Q1. Speedup technique

### Evaluation

| Technique | Preprocessing | Query | Verdict |
|---|---|---|---|
| Engineering only (SoA, monomorphised costing, dense ids) | none | About 1 µs per label upstream to 120-250 ns (est.), so 4-8x with the same label counts. SF to NY at 1M labels is 150-250 ms; time-dependent Berlin to Prague at 3M labels is 0.4-0.7 s. | Necessary but insufficient, and still inexact because of hierarchy pruning. |
| ALT | 16 landmarks x 2 directions x 4 B = 128 B/node: 14 GB for US+DACH, 64 GB for planet | 88 ms against 15.7 ms for CH-Potentials in the same setup | Dominated on speed and memory. Reject. |
| CH-Potentials, fixed per-mode lower bound | CH build 295 s for 16M-node Germany | 0.6 ms tight; 2.8 ms with turns; 26 ms no tunnels; 127 ms live traffic; 196-210 ms predicted plus live; 343 ms no highways | Excellent when tight, collapses when the request diverges from the bound. |
| CCH | Europe (18M nodes): order 341 s; customisation 4.1 s on one thread, 0.81 s on 8 (basic); queries 0.14-0.30 ms. Edge-based: graph about 3x, customisation about 3x. | Sub-millisecond on a static metric | No time dependence, no per-request excludes. Edge-based memory is about 5-7 GB per metric for the US+DACH car graph (est.). |
| CRP / MLD | Europe customisation 1.05 s on 12 cores | 1.65 ms | Turn-native, small per-metric data (est. 0.3-0.7 GB for US+DACH), per-cell traffic updates. No time dependence, and a poor potential provider (est. 30-50 ms per long route against 0.6 ms). |

Per-request customisation is infeasible above metro scale. Top-level CCH arcs depend on all lower triangles, so "lazy" customisation degenerates into full customisation: about 5 s on 8 threads for US+DACH and 15-25 s for planet (est., scaled from Europe). It only works for bundles of about 2M nodes or fewer, at 50-100 ms (est.).

### Recommendation: metric-keyed CCH potentials plus one exact edge-based A*

**One search core.** Use unidirectional label-setting A* on the real graph. Labels are per directed edge, and the full dynamic costing is evaluated at relax time. Arrive-by runs the mirrored reverse search. Time dependence, live traffic, avoid polygons, excluded edges and truck dimension or hazmat checks all happen in this search, so none of them need hierarchy support.

**One potential provider.** Build a node-based, turn-free CCH and evaluate potentials lazily (the memoised PHAST variant from the CH-Potentials paper, which the CCH survey calls Lazy RPHAST). The metric is customised for the request's compiled static cost table, not for a per-mode canonical bound:

- Costing compiles options into a small POD: a class-to-factor table, a speed-to-seconds-per-metre table, a turn-class-to-cost table and scalars.
- The metric key is a 128-bit hash of that POD's static projection. Different raw options that compile to the same tables share a key.
- Customisation is one vectorisable pass, `w(e) = floor(len * spm[lb_speed] * factor[class] + min_in_turn(e) + entry_penalty(e))`, followed by triangle relaxation.
- Your clients send constant option sets, so the hit rate approaches 100% after the first few seconds. Metrics persist to disk and are mmap'd on restart.

**Fallback ladder.**

- **L0, exact key cached.** The potential is loose only by turn costs above the folded minimum, restrictions, traffic and excludes.
- **L1, key miss.** Pick the cached metric M of the same mode that maximises `sigma = min over classes of f_req(c) / f_M(c)`. This is a loop over the class table, not over edges. Use `h = sigma * h_M`, optionally the max over two cached metrics, which stays consistent. Enqueue background customisation once the key has been seen twice in 60 s. This is your scalar idea, demoted to a transient.
- **L2, no CCH mapped.** Haversine times minimum seconds per metre, which matches upstream behaviour.
- **Slider-style clients with unbounded keys.** The admission filter plus LRU bound memory. Optionally snap class factors down to a geometric grid so the key count is finite, at a tightness cost.

**Factors below the lower bound.** With an exact key this cannot happen, because the bound is built from the request's own factors. In L1, sigma handles it. Factors that can fall below 1 upstream are the walkway, sidewalk, alley and driveway factors (minimum 0.1, from memory), `use_highways` (down to -0.125 times class weight), `use_tolls` (-0.015), the 0.6 turn-channel factor, the density table (minimum about 0.85, from memory), ferry factors and bicycle lane and network discounts. As I recall, upstream's pedestrian `AStarCostFactor` multiplies all sub-1 factors together and its first pass ignores ferries, so upstream is itself both looser and inadmissible there.

**Admissibility invariant the costing layer must expose.**

- **I1.** `edgeLB(class, len, lb_speed) <= EdgeCost(e, t, traffic)` for every time and traffic state. `lb_speed` is a build-time per-edge maximum over speed limit, free-flow, constrained and every predicted bucket.
- **I2.** `0 <= turnLB(e_out) <= TransitionCost(pred, e_out)` for every legal predecessor.
- **I3.** Costs are non-negative and either finite or infinite. Infinite means forbidden.
- **I4.** Request features declare themselves monotone (they only remove edges or add cost) or else supply a scalar floor `rho <= 1`. Avoid polygons, excludes, closures, conditional access and restrictions are monotone. Per-edge user cost factors (`EdgeFactor`) and live speeds above `lb_speed` need the floor; traffic ingest maintains the global live-to-bound ratio, normally 1.
- **I5.** Lower-bound weights are floor-rounded to integer ticks and potentials are multiplied by `(1 - 2^-20)` to absorb f32 rounding.
- **Enforcement.** A comptime-enabled relax-time assertion `h(u) <= c(u,v) + h(v)`, plus a property fuzzer over the full legal option ranges.

**Turn costs and restrictions.** Upstream's transition costs are large in cities, so fold the minimum incoming turn cost and entry penalties (steps, gates, toll booths) into the lower-bound edge weight. Simple restrictions live in the turn table. Complex multi-via restrictions become a restriction-automaton state in the label, materialised as virtual edge ids for via edges (under 0.1% of edges, est.). This is exact, unlike walking the predecessor chain under label dominance. Restrictions only increase cost, so potentials are unaffected.

**Time dependence and traffic.** Phase 1 uses the free-flow bound. Expect the published 10-16x-over-Dijkstra regime in the worst case: 127-210 ms Germany-wide, 90 ms on TDEur17. Berlin to Prague should take about 100-150k labels (est.) against upstream's 3M. Phase 3 adds time-dependent potentials after Werner and Zeitz, who report up to an order of magnitude over static potentials with live updates in a fraction of a minute.

**Expected p2p cost, exact key cached, one thread (est.).**

| Route | Labels | Latency |
|---|---|---|
| 10 km | 1-5k | 0.3-1 ms |
| 200 km | 5-20k | 1-4 ms |
| 1000 km | 20-80k | 4-15 ms |
| 4000 km | 60-250k | 10-40 ms |

Potential setup is about 0.2 ms: an elimination-tree climb of roughly 1,000-1,300 vertices and 190-270k arcs on Europe and Germany. With traffic or time dependence, multiply long routes by 10-30. In L1 at sigma = 0.6, a 10 km pedestrian route is about 100k labels (15 ms), and a 200 km bicycle route is 0.3-1 s.

**Planet preprocessing (est.).** Ordering takes 20-30 minutes on 32 cores with a parallel recursive inertial-flow implementation. A full customisation takes 15-25 s. CCH topology is about 10 GB; each metric is 6 GB compressed to u16 or 12 GB as u32.

### Other query types

- **Matrix.** This is the weakest part of the primary architecture. Version 1 shares one potential context per target across all sources, runs exact A* per pair in parallel over targets, and gets a free lower-bound matrix for pruning. Urban pairs cost 0.2-1.5 ms because residual turn-cost looseness widens the corridor, so 50x50 is about 60-450 ms on 8 cores (est.). That is better than upstream but not OSRM-class. Pedestrian and bicycle matrices use bounded exact bidirectional many-to-many.
- **Matrix, planned phase 2.** Build a turn-aware multilevel cell overlay (CRP-style cliques over cut arcs) on the same separator tree, customised per metric key. One-to-many is about 2-5 ms per source, so 1000x1000 is about 1 s wall on 8 cores (est.). Experiment E6 decides whether this moves ahead of other work.
- **Isochrones.** Use bounded Dijkstra on the same core with a bucket queue; no potentials are needed. A 60-minute auto isochrone is 1-3M labels, or 150-450 ms (est.). A 15-minute pedestrian one is under 2 ms. The phase-2 overlay enables isoCRP-style sweeps.
- **Map matching.** Run one bounded one-to-many search per candidate per Viterbi column on the same core, with no potentials. The snap index and decoded shapes are shared and held in the request arena. Expect 5-10x from engineering, plus parallelism across trace segments.
- **Alternates.** Use the penalty method: re-run with path edges penalised, which keeps potentials admissible. Filter by stretch, sharing and local optimality. Each alternate costs about 1-2x the base query.

## Q2. Graph format

**Shape.** A bundle is a directory with one little-endian file per section. Hot topology is monolithic, in nested-dissection order. Node id equals CCH elimination rank, so cells are contiguous id ranges, the upward search visits increasing ids, and no permutation arrays are needed. Cold data is chunked by ND cell (about 64k edges), not by lat/lon tile.

- **Ids.** Node and directed-edge ids are u32 behind opaque `enum(u32)` types, so widening is a recompile plus a format bump.
- **Updates.** Full rebuild per bundle. The server loads several bundles and dispatches by location, so DACH can be rebuilt without touching the US.
- **Regional coverage.** The optional `coverage.bin` section stores one E7 bounding box over the saved nodes and road shapes. West greater than east denotes an antimeridian crossing. Registry setup can derive bounds from node coordinates for older bundles. In overlapping coverage, registry order decides between bundles that can snap all locations to one connected component. If each location snaps and the snaps span different bundles, the request returns Valhalla error 170. Routing across regions requires a merged bundle.
- **File header (64 B).** Magic, format version, 16-byte dataset UUID, section kind, record size, count and xxh3 of the payload. Startup checks headers, UUIDs and sizes. The `verify` command checks payload hashes offline. The header begins at file offset 0 and the payload begins at 64 KiB, with zero bytes between. The checksum is seedless XXH3-64 over the payload. Bundle creation stages `nodes.bin`, `edges.bin`, `first_edge.bin` and `turns.bin` in a sibling directory and publishes all four in one exclusive rename.

```zig
const EdgeHot = extern struct {            // 16 B, indexed by directed edge id
    head: u32,                             // end node
    geom: packed struct(u32) { len_m: u24, grade: u4, curvature: u4 },
    cls:  packed struct(u32) { class_id: u20, local: u5, opp_local: u5, cold_checks: u1, pred_speed: u1 },
    speed: [4]u8,                          // speed, free_flow, constrained, truck (kph)
};
const NodeHot = extern struct {            // 8 B (+ first_edge: u32 in its own array)
    turn_off: u32,                         // into deduplicated u8 turn-table pool
    attr: packed struct(u32) { access: u16, type: u4, density: u4, signal: u1, _pad: u7 },
};
// turn entry u8: turn_type:3 | stop_impact:3 | name_consistent:1 | restricted:1
// lookup: pool[turn_off + in_local * degree + out_local]
```

- **Opposing edge.** `first_edge[head] + opp_local`, with no stored index. This lifts upstream's 7-bit opposing index.
- **Edge classes.** `class_id` indexes a deduplicated table of categorical tuples: use, road class, surface, 16-bit access masks, toll, tunnel, bridge, roundabout, link, internal, destination-only, SAC scale, lit, sidewalk, cycle lane, bike network, dismount, HOV, truck route, restriction start and end flags. The per-request factor table is indexed by it.
- **Turn model.** Per-node turn tables, deduplicated globally (0.796 B/node on the pinned Luxembourg extract, see [measurements](../../oracle/README.md#turn-tables)). The edge-expanded graph is never materialised; labels are per edge. Simple restrictions sit in the turn entry. Complex, timed and per-mode restrictions go in `restr.bin`, keyed by first edge with automaton states. Truck dimensions and hazmat go in a side table reached only when `cold_checks` is set.
- **Cold data.** `cold_idx: u32` names the shared undirected record and its travel direction. That record contains the u64 way ID, an E7 delta zigzag varint shape with a u32 length, shared string references, speed limit and mean elevation. Signs, lanes and elevation samples are later sections. Node coordinates (2 x i32), timezone and admin (u16) are separate warm arrays. See the [cold section layout and measurements](../../oracle/README.md#cold-graph-data).
- **Node ordering.** The builder applies the Hilbert permutation before emitting any ID-keyed sections. The metadata records the kind and hash of the permutation. See the [locality measurements](../../oracle/README.md#node-ordering).
- **Build identity.** The dataset UUID includes ordered OSM input fingerprints, drive side, node ordering and the selected DEM tiles' bytes. The tile catalog chooses duplicates by encoding and then byte order, and hashes tiles in geographic index order. Paths and worker counts stay outside the identity. Checkpoint reports carry run timings outside the bundle. The builder uses portable trigonometry with a fixed rounding order for stored lengths, curvature, turn headings, density and elevation resampling.
- **Lifted limits.** 21-bit per-tile ids to dense u32. 7-bit opposing index removed. 8 local edges with turn data to 32 (the build splits rarer cases). 15 names to 255. 65535-byte shapes to u32. 12-bit access masks to 16.
- **Spatial index.** One structure serves routing snap, map matching and `/locate`. It is a fixed grid of 1/256 degree with a sorted directory of non-empty cells and delta-varint lists of undirected edge IDs. The pinned Luxembourg extract uses 2.76 payload bytes per undirected edge. See the [spatial layout and measurements](../../oracle/README.md#spatial-index).
- **Live traffic.** `traffic-live.bin` holds upstream's 8-byte record per drivable edge, addressed by rank over a drivable bitmap. An external process writes it; readers do a single aligned u64 load. The header carries an epoch and the live-to-bound ratio. The build emits a stable key map (way id plus OSM node pair to edge id) for ingest, because ids change per build.
- **Predicted traffic.** `traffic-pred.bin` keeps the 200 x i16 DCT coefficients for covered edges only.
- **Acceleration data.** `cch.topo` carries the dataset UUID and an order hash. `metric-<key>.bin` carries the CCH hash, the metric key, a costing ABI integer and the traffic epoch. Metrics are disposable caches.
- **Metric compression.** Customise in u32 scratch, then store u16 minifloats rounded down once (4-bit exponent, 12-bit mantissa, at most 0.024% looseness). A rounded-down metric is still an exact distance of a smaller metric, so it stays admissible and consistent.

**Sizes (est.).** I assume US+DACH is 27% of planet: 110M nodes and 270M directed edges. Measure this in E5.

| Component | Per unit | Planet | US+DACH |
|---|---|---|---|
| EdgeHot + first_edge + NodeHot + turn tables | 16 B/edge, 13 B/node | 22.5 GB | 5.8 GB |
| cold_idx, coordinates, timezone (evictable) | 4 B/edge, 10 B/node | 9 GB | 2.2 GB |
| Cold shapes, names, attributes (page cache) | about 25 B/edge | 25-30 GB | 7 GB |
| Spatial index | 1.5-3 B/edge | 2-3 GB | 0.5 GB |
| CCH topology, query-hot part | about 16 B/node | 8 GB | 1.8 GB |
| One metric, u16 up and down | about 12 B/node | 6 GB | 1.3 GB |

**16 GB budget for US+DACH.** Hot graph 5.8, CCH 1.8, three metrics 3.9, spatial resident 0.3, live traffic 0.3 and eight threads of scratch 0.6 come to about 12.7 GB. That leaves about 3 GB for the OS and cold page cache. It is tight: the knobs are two metrics instead of three and keeping cold data on NVMe. Planet needs about 55-60 GB resident with three metrics, so plan for 96-128 GB; 64 GB works only with two metrics.

### Directed-edge field mapping

`classes.bin` is v1 section kind 5. Each record is a 20-byte `EdgeClass` made of five packed
32-bit words. The builder interns complete records, sorts the distinct tuples lexicographically
by their little-endian bytes, then remaps handles to the final 20-bit IDs in `EdgeHot`.
The capacity is 1,048,576 distinct tuples.

| Valhalla 3.9.3 `DirectedEdge` fields | Native representation |
| --- | --- |
| `endnode_`, `localedgeidx_`, `opp_local_idx_` | `EdgeHot.head`, `EdgeHot.cls.local`, `EdgeHot.cls.opp_local` |
| `opp_index_` | Derived as `first_edge[head] + opp_local` |
| `length_`, `weighted_grade_`, `curvature_` | `EdgeHot.geom` |
| `speed_`, `free_flow_speed_`, `constrained_flow_speed_`, `truck_speed_`, `has_predicted_speed_` | `EdgeHot.speed` and `EdgeHot.cls.pred_speed`. Predicted profiles and live samples use their traffic sections. |
| `use_`, `classification_`, `surface_`, `sac_scale_`, `cycle_lane_`, `bike_network_`, `lanecount_`, `density_` | `EdgeClass.category`. The Valhalla bicycle-network predicate uses the national, regional, local and MTB bits. The OSM international-network bit is retained as attribution. |
| `forwardaccess_`, `reverseaccess_`, `hov_type_` | `EdgeClass.access` stores two 16-bit masks relative to the directed edge. `flags.hov3` distinguishes HOV3 from HOV2. HOV-only access is derived from the forward mask. |
| `toll_`, `tunnel_`, `bridge_`, `roundabout_`, `link_`, `internal_`, `truck_route_`, `dest_only_`, `dest_only_hgv_`, `not_thru_`, `deadend_` | `EdgeClass.flags` |
| `lit_`, `sidewalk_left_`, `sidewalk_right_`, `shoulder_`, `dismount_`, `use_sidepath_`, `named_`, `indoor_`, `bss_connection_`, `ctry_crossing_`, `speed_type_` | `EdgeClass.flags` |
| `traffic_signal_`, `stop_sign_`, `yield_sign_` | `EdgeClass.flags` for controls carried by the segment. Intersection controls are supplied by the corresponding node and turn data. |
| `max_up_slope_`, `max_down_slope_`, `access_restriction_` | `EdgeClass.detail`. The mask selects applicable cold restriction rules when `EdgeHot.cls.cold_checks` is set. |
| `start_restriction_`, `end_restriction_`, `complex_restriction_` | `EdgeClass.restrictions` stores both mode masks, with `flags.complex_restriction` for via edges. Sequences and conditions live in the restriction sections. |
| `restrictions_`, `name_consistency_`, `turntype_`, `stopimpact_.s.stopimpact` | Per-pair `TurnEntry` fields for restrictions, name consistency, turn type and stop impact |
| `edge_to_left_`, `stopimpact_.s.edge_to_right` | Local intersection geometry supplies these per-turn side relationships for transition costing. |
| `edgeinfo_offset_`, `forward_`, `sign_`, `turnlanes_`, `lane_conn_` | Cold edge index and orientation, signs, turn lanes and lane connectivity |
| `stopimpact_.lineid` | Transit line and schedule data |
| `shortcut_`, `superseded_`, `is_shortcut_`, `leaves_tile_` | CCH arcs are separate from the base graph. The base graph uses dense bundle IDs. |

The way projection sets directional access, lane count, cycle lane, shoulder and segment controls.
Later build stages fill attributes that depend on relations, restrictions, names, elevation or
graph topology. The class table keeps those categorical values in the same lookup used by costing.

On the pinned Liechtenstein PBF, `zig build check-edges -- INPUT.osm.pbf SCRATCH_DIR 4 right`
reported 279 base classes across 15,760 directed edges. Utrecht reported 1,379 across 85,336.
The class table checksum was identical with 1, 4 and 8 workers on each extract.

### Transit timetable sections

A bundle with transit carries sections 27 through 38 together. They use the v1 section
header and payload checksum. `zr inspect --verify` reports their sizes and verifies both
checksums and timetable references. The `transit_metadata.bin` record carries the transit
layout version and the timetable start date as civil days since 1970-01-01.

| Section | Bytes per record | Contents |
| --- | ---: | --- |
| `transit_metadata` | 12 | Layout version and calendar epoch |
| `transit_stops` | 32 | Platforms, their attributes and parent stations |
| `transit_stations` | 28 | Stations and their attributes |
| `transit_egresses` | 56 | Street entrances with optional OSM way and location hints |
| `transit_routes` | 40 | Vehicle type, operator, names and colours |
| `transit_lines` | 32 | Directional stop pair, route, shape ID and timetable spans |
| `transit_departures` | 44 | Fixed and frequency departures, trips, blocks, schedules and access flags |
| `transit_occurrences` | 8 | Sorted departure instants for lines using frequency service |
| `transit_schedules` | 24 | Dense calendar span, weekly mask and exception span |
| `transit_days` | 4 | 32 consecutive days of calendar validity |
| `transit_exceptions` | 8 | Added or removed service on a relative civil day |
| `transit_transfers` | 32 | Stop, route and trip references, transfer type and minimum time |

All strings reference the shared `cold.bin` name table, including headsigns, onestop IDs
and route colours. Route and schedule IDs use u32. A schedule can cover any span of days
within its u32 day count. Exceptions override the bitset and the weekly mask. The mask
uses Sunday as bit zero and applies outside the bitset.

Transfer records retain the optional route and trip qualifiers used by
[`transfers.txt`](https://gtfs.org/documentation/schedule/reference/#transferstxt).

Canonical departures are sorted by line and start time. A fixed-only line searches its
canonical slice directly. For lines with frequency service, the writer stores one
occurrence per offered time, including any fixed departures on that line. Each frequency
series starts at its first time and advances by its headway up to its exclusive end.
The index costs eight bytes per stored occurrence and orders ties by canonical record
position. Both paths use a single binary search and return a borrowed record and its
offered time. Callers can check service dates and access flags on that record.

### Building transit from GTFS

`zr build --gtfs feed.zip --output graph roads.osm.pbf` builds one feed.
For multiple feeds, set the ordered `zig_routing.build.gtfs_inputs` list in the
configuration. Feed fingerprints contribute to the bundle UUID. Platform,
route and trip identifiers belong to their feed's namespace.

The transit stage runs between segment generation and node ordering. It
resolves the stop hierarchy, uses supplied station pathways, and creates
entrances and platform connections for stations without pathways. The
street spatial index finds walkable edges within 500 m of each entrance.
Approach shapes follow the street from each endpoint to the projection and
then reach the entrance. Street and pathway directions determine access to
the resulting edges. At stations with complete pathway times, generated
transfers use the shortest permitted path's time.

The stage checkpoints the augmented segments, transit records and names.
Run with `--to transit` to publish this checkpoint and `--from order` to
resume graph assembly from it. Graph ordering assigns dense node IDs and
the cold stage interns transit names alongside road names. Service dates use
the stop's inherited timezone. When the build includes timezone rules,
transit nodes take their feed timezone alongside the street timezone index.

The `transit` object in `build-stats.json` counts platforms reachable from
and able to return to a street. It reports missing coordinates, entrances
without a walkable street, missing station pathways and one-way access.
It also counts timetable legs, pathways and transfers with missing endpoints.

The Brockton city build produced 1,460 lines and 83,484 departures. All 963
platform nodes in the installed bundle had a pedestrian connection in both
directions. All 18 transit checkpoint artifacts were byte-identical across
one and eight workers.
[Brockton Area Transit GTFS](https://data.trilliumtransit.com/gtfs/brockton-ma-us/brockton-ma-us.zip) ·
[2026-11-19 Massachusetts street extract](https://download.geofabrik.de/north-america/us/massachusetts/massachusetts-261119.osm.pbf)

## Q3. Hot loop in Zig

```zig
pub fn Search(comptime K: type, comptime Q: type) type { return struct {
  pub fn run(s: *@This(), ctl: *const Ctl) !LabelIdx {
    var pops: u32 = 0;
    while (s.q.pop()) |top| {
      const L = s.labels.items[top.label];
      const st = s.status.ptr(L.edge);
      if (st.label != top.label) continue;                 // stale entry (lazy deletion)
      if (L.flags.target) return top.label;
      st.state = .settled;
      pops +%= 1;
      if (pops & 1023 == 0 and ctl.cancelled()) return error.Cancelled;
      const e = s.g.edge[L.edge];
      const first = s.g.first_edge[e.head];
      const deg = s.g.first_edge[e.head + 1] - first;
      const row = s.g.turnRow(e.head, e.cls.opp_local, deg);  // []const u8
      for (0..deg) |i| {
        const o = s.g.edge[first + i];
        const f = s.k.class_factor[o.cls.class_id];        // +inf = not allowed
        if (row[i] & turn_restricted != 0 or f == inf) continue;
        const os = s.status.ptr(first + i);                // excluded edges are pre-marked
        if (os.state == .settled or os.state == .excluded) continue;
        if (o.cls.cold_checks == 1 and !K.slowAllowed(s.k, s.g, first + i, L)) continue; // noinline
        const c = K.edgeCost(s.k, o, f, L.secs, s.g.traffic) + K.turnCost(s.k, e, o, row[i]);
        const g2 = L.cost + c.cost;
        if (os.state == .open and s.labels.items[os.label].cost <= g2) continue;
        const nl = s.labels.push(.{ .edge = first + i, .pred = top.label, .cost = g2, .secs = L.secs + c.secs, ... });
        os.* = .{ .state = .open, .label = nl };
        s.q.push(.{ .key = g2 + s.pot.get(o.head) * s.k.sigma, .label = nl });
        @prefetch(&s.g.first_edge[o.head], .{});
      }
    }
    return error.NoPath;
  }
};}
```

- **Costing.** Do not write nine monomorphised models. Use three or four kernels (motor, bicycle, pedestrian, multimodal) driven by the compiled POD. The models differ in tables, not code, so roughly four kernels by five algorithms gives about 20 small instantiations. Compiling options costs about 100 µs (est.) and is cached under the metric key.
- **Label (32 B).** `cost f32, secs f32, pred u32, edge u32, dist_m u32, tcost f32, flags u32, ctx u32`. Multimodal uses a wider label. Costs stay f32 so recosting matches upstream arithmetic.
- **Queue.** A comptime parameter. Default is a 4-ary heap of `{key u32, label u32}` with lazy deletion and no decrease-key; non-negative f32 bit patterns order correctly as u32. Potential-guided searches have a few thousand entries that fit in L1/L2. Isochrones and bounded matrix sweeps use a two-level bucket queue.
- **Status and potential memo.** Dense per-thread arrays are impossible: 270M edges x 4 B x 8 threads is 8.6 GB. Use a two-level paged array: a directory indexed by `id >> 12`, with 16 KB pages bump-allocated from the request arena on first touch. ND order clusters touched ids. Reset by clearing the touched directory slots and rewinding the pool. No hashing and no epoch counters.
- **Memory.** One arena per worker, reset per request, with high-water retention so steady state allocates nothing. Serialisers write into arena buffers.
- **SIMD via `@Vector`.** Point-to-segment projection batches for snapping; group-varint shape decode and polyline encode; the 200-term DCT dot product (about 20 ns per bucket, est.); the customisation weight pass and triangle min-plus; isochrone grid updates.
- **Threads.** Thread-per-core, run-to-completion workers over a shared immutable mmap, with the HTTP parser in-process and no inter-stage protobuf. Matrix and isochrone requests fork-join over idle workers, bounded per request. Cancellation is a deadline plus an atomic flag checked every 1024 pops and set by the I/O side on disconnect.
- **Zig pitfalls.**
  - Use `extern struct` for on-disk records with `packed struct(u32)` bitfield members. Never use a bare `packed struct` wider than 64 bits or as an array element type.
  - Add comptime `@sizeOf` and `@offsetOf` assertions and a comptime little-endian assertion.
  - mmap slices need `@alignCast` at the section boundary only.
  - Mark cold checks `noinline` and watch instantiation count in CI by binary-size budget.
  - Quarantine std.Io behind a single shim file (accept, read, write, mmap, clock) and use raw posix elsewhere.

## Faithfulness and test gating

Do not build a compat algorithm. Reproducing hierarchy pruning means porting upstream's shortcut builder, level transitions and expansion order for a throwaway. Do these instead:

1. Import Valhalla tiles (test-only) so both engines run on the same graph.
2. Run the oracle with hierarchy pruning disabled. I recall a `disable_hierarchy_pruning` costing option with a distance cap in service limits; verify it exists in your pinned version.

| Gate | Metric | Threshold |
|---|---|---|
| A. Costing parity (hard) | Per-call EdgeCost and TransitionCost on 10^7 sampled (pred, edge, options, time); recost of oracle paths against oracle-reported cost | Relative error <= 1e-5 per call; <= 1e-4 per path |
| B. Optimality (hard) | `our_cost(our_path) <= our_cost(oracle_path) + eps` | 100%; any violation is a search or admissibility bug |
| C. Same-graph equality, pruning disabled | Cost ratio | Within 1e-4 on >= 99.9% |
| D. Default oracle | Among routes within 0.1% cost: geometry overlap >= 0.98, maneuver type and name sequence equal, time within 1%, distance within 0.5% | >= 95% of routes; strictly cheaper routes are classified by cause, not failed |
| E. Matrix | Cell difference <= 1% or 5 s; remainder must be ours cheaper | >= 99% of cells |
| F. Isochrone | Edge reach times within 1% or 5 s; polygon IoU | IoU >= 0.97 |
| G. Map matching | Matched edge sequence equality | >= 99% of traces |
| H. API | Golden JSON key sets, types, enums, error codes | Exact |

## Risks and first-three-weeks experiments

| # | Experiment | Pass | If it fails |
|---|---|---|---|
| E1 | Edge-based Dijkstra on imported Germany, pedestrian and auto kernels | <= 150 ns per settled label at 10^6 labels; >= 5x upstream label throughput | Revisit record layout |
| E2 | Exact-key potentials with real upstream costing, folding on and off | Median labels <= 20x path edges, p95 <= 100x; pedestrian 10 km p95 < 1 ms; auto 500 km p95 < 15 ms | Stronger folding or an edge-based bound for motor |
| E3 | L1 scaling at `walkway_factor: 0.6` | p95 no worse than upstream for the same request | L1 needs two-metric max or grid snapping |
| E4 | Own inertial-flow order plus customisation on US+DACH | Order <= 30 min on 8 vCPU; customisation <= 10 s on 8 threads; <= 4 arcs/node; metric <= 1.5 GB | Better partitioner before anything else |
| E5 | Full bundle under mixed load, three metrics | RSS <= 13 GB; confirm node and edge counts | Two metrics or per-mode sub-CCH |
| E6 | 50x50 urban and 200x200 regional auto matrix, version 1 | <= 100 ms and <= 1.5 s on 8 cores; >= 5x upstream | Pull the overlay forward |
| E7 | Berlin to Prague with `date_time`; synthetic congestion (30% of edges at half speed) | <= 150k labels and <= 40 ms; congested p95 <= 250 ms | Pull time-dependent potentials forward |
| E8 | Gates A-C on 100k random routes | Thresholds above | Costing port is wrong; stop and fix |

Top risks, in order:

1. **Turn-cost looseness in cities.** Upstream's transition costs are large, so E2 is the make-or-break experiment.
2. **Metric-key explosion** from slider-style clients thrashing memory and CPU.
3. **Ordering quality** from a home-grown partitioner inflating triangles and customisation time.
4. **Undiscovered non-monotone costing quirks** breaking I1-I4; the fuzzer is the defence.
5. **Complex-restriction exactness** diverging from upstream's dominance behaviour and showing up as parity noise.
6. **Matrix version 1** not being "much faster" without the overlay.
7. **Zig 0.17-dev churn.**

## Sources

- [Strasser and Zeitz, A Fast and Tight Heuristic for A* in Road Networks](https://arxiv.org/abs/1910.12526) ([HTML with tables](https://arxiv.org/html/1910.12526v2))
- [Customizable Contraction Hierarchies: A Survey](https://arxiv.org/html/2502.10519)
- [Dibbelt, Strasser and Wagner, Customizable Contraction Hierarchies](https://ar5iv.arxiv.org/html/1402.0402)
- [Buchhold, Wagner, Zeitz and Zündorf, Customizable Contraction Hierarchies with Turn Costs](https://drops.dagstuhl.de/entities/document/10.4230/OASIcs.ATMOS.2020.9)
- [Werner and Zeitz, Combining Predicted and Live Traffic with Time-Dependent A* Potentials](https://arxiv.org/abs/2207.00381v1)
- [Zeitz, Fast Computation of Shortest Smooth Paths and Uniformly Bounded Stretch with Lazy RPHAST](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.SEA.2022.3)
- [Valhalla pedestriancost.cc](https://raw.githubusercontent.com/valhalla/valhalla/master/src/sif/pedestriancost.cc) and [autocost.cc](https://raw.githubusercontent.com/valhalla/valhalla/master/src/sif/autocost.cc)

### Critical Files for Implementation

Nothing exists yet. These are proposed paths in the new repository, plus the upstream files that define the semantics to port.

- [`src/graph/format.zig`](../../src/graph/format.zig): extern structs, section headers, writer and comptime layout assertions
- `zig-routing/src/sif/compiled.zig` (proposed): options to compiled POD, metric key, and the I1-I5 lower-bound interface
- `zig-routing/src/thor/search.zig` (proposed): `Search(K, Q)`, labels, paged status and queues
- `zig-routing/src/accel/cch.zig` (proposed): ordering, customisation, lazy potentials and the metric cache
- Upstream reference: `valhalla/src/sif/pedestriancost.cc`, `valhalla/src/sif/autocost.cc` and `valhalla/src/sif/dynamiccost.cc` for gate A
