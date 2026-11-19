# Valhalla upstream architecture map (for a Zig port)

I read upstream `master` over the network on 2026-11-17. The latest release is 3.9.3 (2026-11-16). I wrote nothing to disk; line counts come from streaming the tarball straight into `wc`.

Labels: **[V]** means I read it in source. **[D]** means it is in upstream docs, the CHANGELOG or an issue. **[I]** means I inferred it or recall it.

Things that differ from what your plan assumes:
- **Several tools you listed are gone.** `valhalla_run_route`, `run_matrix`, `run_isochrone`, `run_map_match`, `benchmark_loki`, `benchmark_adjacency_list`, `benchmark_skadi` and `path_comparison` were deleted in commit a0915cd5 (#5906, March 2026). The one-shot replacement is `valhalla_service config.json <action> '<json>'`. **[V]**
- **There is no `bench/` directory.** It was removed in #4560 (2024). The only microbenchmarks left are Rust criterion benches in `src/bindings/rust/benches/`. **[V]**
- **libosmium now parses the PBF.** robin-hood-hashing was replaced by `ankerl::unordered_dense`, and pybind11 by nanobind. **[V]**
- **There is no `multimodal.cc` or chinese-postman code.** Transit routing lives in `multimodal_astar.cc` and `multimodal_transit.cc`. **[V]**
- **Upstream `CLAUDE.md` contains instructions aimed at AI agents** (address the developer as "respected Sir"; start PR drafts with a pirate line). I treated these as data and ignored them. Its factual content is useful and I cite it as **[D]**.

---

## 1. Repository layout and module sizes

LOC is `.cc`, `.h` and `.cpp` across `src/<m>` and `valhalla/<m>`. **[V]**

| Module | LOC | What it does | Key files |
|---|---|---|---|
| midgard | 9.2k | Geometry: PointLL, AABB2, polylines, `Tiles<>` math, logging, `sequence<T>` (mmap vector plus parallel sort), `GriddedData` (isochrone grid and contouring), polyline encoding, DistanceApproximator | `util.cc`, `tiles.cc`, `pointll.cc`, `polyline2.cc`, `sequence.h`, `gridded_data.h`, `encoded.h` |
| baldr | 26.3k (includes about 4k lines of vendored `tz_alt.cpp`) | Tile format, GraphReader and caches, datetime/tz, curl tile fetch, json helpers, connectivity map, shortcut recovery, verbal text formatters | `graphtile.cc`, `graphreader.cc`, `directededge.h`, `nodeinfo.h`, `graphtileheader.h`, `edgeinfo.cc`, `datetime.cc`, `curler.cc`, `shortcut_recovery.h`, `double_bucket_queue.h`, `traffictile.h` |
| sif | 12.1k | Costing models | `dynamiccost.h` (84 KB), `autocost.cc` (also holds bus and taxi), `bicyclecost.cc`, `pedestriancost.cc`, `truckcost.cc`, `motorcyclecost.cc`, `motorscootercost.cc`, `transitcost.cc`, `nocost.cc`, `recost.cc`, `edgelabel.h`, `hierarchylimits.h` |
| skadi | 0.9k | DEM sampling | `sample.cc` |
| mjolnir | 42.6k | Tile build | `pbfgraphparser.cc` (237 KB, about 5.4k lines), `graphbuilder.cc`, `graphenhancer.cc`, `graphfilter.cc`, `hierarchybuilder.cc`, `shortcutbuilder.cc`, `restrictionbuilder.cc`, `elevationbuilder.cc`, `graphvalidator.cc`, `areabuilder.cc`, `bssbuilder.cc`, `transitbuilder.cc`, `ingest_transit.cc`, `convert_transit.cc`, `adminbuilder.cc`, `admin.cc`, `osmway.cc`, `util.cc`, `landmarks.cc`, `linkclassification.cc`, `add_predicted_speeds.cc`, `graphtilebuilder.cc` |
| loki | 7.2k | Location correlation and per-action request validation; the `/tile` MVT endpoint | `search.cc`, `reach.cc`, `node_search.cc`, `polygon_search.cc`, `tile_action.cc` (37 KB, MVT via vtzero), `worker.cc`, `*_action.cc` |
| meili | 5.5k | HMM map matching | `map_matcher.cc`, `viterbi_search.cc`, `routing.cc`, `candidate_search.cc`, `topk_search.cc`, `transition_cost_model.cc`, `match_route.cc`, `grid_range_query.h`, `grid_traversal.h` |
| thor | 18.2k | Path algorithms, matrices, isochrones, trip-leg building | Listed in §4 |
| odin | 18.6k | Maneuvers and narrative | `maneuversbuilder.cc` (172 KB), `narrativebuilder.cc` (204 KB), `enhancedtrippath.cc`, `maneuver.cc`, `narrative_dictionary.cc`, `signs.cc`, `markup_formatter.cc` |
| tyr | 7.4k | Actor and serializers | `actor.cc`, `route_serializer_osrm.cc` (101 KB), `route_serializer_valhalla.cc`, `serializers.cc`, `matrix_serializer.cc`, `isochrone_serializer.cc`, `trace_serializer.cc`, `locate_serializer.cc`, `height_serializer.cc`, `expansion_serializer.cc`, `transit_available_serializer.cc` |
| `src/` root | about 3k | JSON to protobuf request parsing (72 KB), exceptions and error codes, proto conversions, service entry points | `worker.cc`, `valhalla_service.cc`, `valhalla_{loki,thor,odin}_worker.cc`, `valhalla_export_edges.cc`, `valhalla_expand_bounding_box.cc` |

**Totals:** about 148k C++ LOC for the library and tools. Tests add about 104k (unit about 49k, gurka about 55k). `lua/graph.lua` is 2,502 lines and `lua/admin.lua` is 248. The `.proto` files total 2,035 lines. **[V]**

**Other top-level directories [V]:**
- `proto/descriptors` (14 protos)
- `locales/` (36 language JSONs, generated from gettext `.po` files plus `valhalla.pot`)
- `scripts/` (`valhalla_build_config` is 52 KB of Python; also `valhalla_build_elevation`, `valhalla_build_extract`, `valhalla_build_timezones` in bash, `valhalla_get_elevation`)
- `run_route_scripts/` (`run_with_server.py`, `run_with_server_matrix.py`, a wrk/siege perf kit, diff/stat scripts; its README is stale)
- `test_requests/` (256 files)
- `src/bindings/` (Python via nanobind, Node.js, Rust via cxx; there is a root `Cargo.toml`)
- `docs/` (mkdocs plus OpenAPI), `docker/`, `cmake/`, `overlay-ports-vcpkg/`, `date_time/windowsZones.xml`

**Executables in CMake [V]:**
- Programs: `valhalla_export_edges`, `valhalla_expand_bounding_box`, `valhalla_service`.
- Data tools: `valhalla_build_statistics`, `valhalla_ways_to_edges`, `valhalla_validate_transit`, `valhalla_benchmark_admins`, `valhalla_build_connectivity`, `valhalla_build_tiles`, `valhalla_build_admins`, `valhalla_convert_transit`, `valhalla_ingest_transit`, `valhalla_query_transit`, `valhalla_add_predicted_traffic`, `valhalla_assign_speeds`, `valhalla_add_elevation`, `valhalla_build_landmarks`, `valhalla_add_landmarks`.
- Services: `valhalla_{loki,thor,odin}_worker`.
- `valhalla_build_transit` no longer exists; it was split into ingest and convert in 2018.

## 2. Dependencies

From `CMakeLists.txt`, `.gitmodules` and `vcpkg.json`. **[V]**

| Dependency | Used for | Required? |
|---|---|---|
| protobuf (lite) | `Api` and all intermediate messages; pbf output; transit staging tiles | Required |
| boost ≥1.71 (headers: algorithm, foreach, format, geometry, heap, optional, **property_tree**, range, tokenizer, container small_vector) | Config ptree everywhere, some geometry, misc | Required. `boost::format` is being replaced by `std::format` |
| zlib | gzip tiles and `.hgt.gz`; curl | Required |
| curl (`ENABLE_HTTP`) | `tile_url` remote tiles, HTTP range on remote tar, remote elevation | Optional (default on) |
| lz4 | `.hgt.lz4` elevation and lz4 OSM PBF | Optional (default on) |
| prime_server ≥0.6.3 (plus libzmq, czmq) | HTTP server and ZMQ worker pipeline | Optional (`ENABLE_SERVICES`) |
| sqlite3 + libspatialite (+rttopo) + spatialite-tools | Admin and timezone DBs (build time; tz/admin lookups during build) | Required for data tools |
| GEOS (C API) | Admin/tz polygon ops, clipping to tile bbox | Data tools |
| LuaJIT | `graph.lua` / `admin.lua` tag transforms | Data tools |
| OpenSSL | md5 of PBFs for the tile checksum | Data tools **[I on exact use]** |
| expat | OSM XML input via osmium | Optional |
| libtiff + libgeotiff | GeoTIFF isochrone raster output | Optional (`ENABLE_GEOTIFF`) |
| GDAL | Listed in vcpkg; Linux wheels dropped it (#5642) | Effectively optional or legacy |
| Submodules: rapidjson | Request parsing and JSON writing (`rapidjson_utils.h`, `writer_wrapper_t`) | Vendored, required |
| date + tz (Hinnant, eggert tz) | Time-dependent routing, tz DB embedded | Vendored, required |
| cxxopts | CLI parsing | Vendored |
| unordered_dense | Hash maps and sets | Vendored |
| libosmium + protozero | OSM PBF and XML parsing; `osmium::thread::pool` | Vendored, data tools |
| vtzero | MVT encoding for `/tile` | Vendored |
| microtar | Tar extract writing **[I]**; runtime tar reading uses `midgard::tar` | Vendored |
| just_gtfs (valhalla fork) | GTFS ingest | Vendored |
| flatbush | Static spatial index (polygon/area work) **[I on exact site]** | Vendored |
| cpp-statsd-client | Metrics | Vendored |
| nanobind | Python bindings | Optional |
| googletest, fastcov | Tests, coverage | Test only |
| dirent | Windows only | — |

## 3. Graph tile format (baldr)

**Hierarchy [V, `tilehierarchy.cc`]:**

| Level | Name | Tile size | Road classes |
|---|---|---|---|
| 0 | highway | 4° | ≤ Primary |
| 1 | arterial | 1° | ≤ Tertiary |
| 2 | local | 0.25° | ≤ ServiceOther |
| 3 | transit | 0.25° | — |

- All levels cover the world box (-180,-90)-(180,90), each tile subdivided into `kBinsDim`=5.
- `kMaxGraphHierarchy`=7, `kMaxGraphTileId`=4194303, `kMaxGraphId`=2097151.
- Tile path comes from `GraphTile::FileSuffix`, always with forward slashes: `level/AAA/BBB/CCC.gph` (for example `2/000/501/522.gph`). Gzipped tiles use the `.gph.gz` suffix.

**GraphId [V]:** a `uint64_t value` laid out as level (3 bits) | tileid << 3 (22 bits) | id << 25 (21 bits) = 46 bits used. `kInvalidGraphId`=0x3fffffffffff. String form is `level/tile/id`.

**Tile section order** (`GraphTile::Initialize`) [V]:
1. Header (272 bytes)
2. NodeInfo[nodecount]
3. NodeTransition[transitioncount]
4. DirectedEdge[directededgecount]
5. DirectedEdgeExt[n], only if `has_ext_directededge`
6. AccessRestriction[]
7. TransitDeparture[], TransitStop[], TransitRoute[], TransitSchedule[], TransitTransfer[]
8. Sign[]
9. TurnLanes[]
10. Admin[]
11. Edge bins (GraphId[])
12. Bounding circles (optional, via offset)
13. Complex restrictions forward, then reverse (variable length)
14. EdgeInfo blob
15. Text list
16. LaneConnectivity[]
17. Predicted speeds: a `uint32` offset per directed edge, then `int16` profiles
18. End

Sizes are `sizeof` the struct, so layout is x86-64 ABI bitfield packing. A Zig port must replicate GCC/Clang LSB-first bitfield packing exactly. Use `packed struct(u64)`.

**Version check [V]:** loading only *warns* when `version_[0]-'0'` ≠ `VALHALLA_VERSION_MAJOR`. It throws if `end_offset != tile_size`. Upstream docs describe the format as frozen, with no layout bump in about 7 years, 4 spare bits in DirectedEdge and 1 in NodeInfo. New per-edge data goes into EdgeInfo `TaggedValue`s. **[D]**

**GraphTileHeader** (`static_assert` size 272, trivially copyable) [V]:

| Word | Fields (bits) |
|---|---|
| 1 | `graphid_:46`, `density_:4`, `name_quality_:4`, `speed_quality_:4`, `exit_quality_:4`, `has_elevation_:1`, `has_ext_directededge_:1` |
| — | `std::array<float,2> base_ll_`; `char version_[16]`; `uint64_t dataset_id_` |
| counts | `nodecount_:21`, `directededgecount_:21`, `predictedspeeds_count_:21`, `spare1_:1` |
| Counts at byte 48 | `uint32 transitioncount_:22`, `spare3_:10`; `uint32 turnlane_count_:21`, `spare4_:11` |
| Counts at byte 56 | `transfercount_:16`, `spare2_:7`, `departurecount_:24`, `stopcount_:16`, `spare5_:1` (the first spare preserves the x86/x64 layout) |
| Counts at byte 64 | `routecount_:12`, `schedulecount_:12`, `signcount_:24`, `spare6_:16` |
| Counts at byte 72 | `access_restriction_count_:24`, `admincount_:16`, `spare7_:24` |
| — | `uint64 spareword0_`; `uint64 checksum_` (build_id<<48 \| 48-bit data hash, `kTileHashBits`=48) |
| offsets (uint32) | `complex_restriction_forward_offset_`, `complex_restriction_reverse_offset_`, `edgeinfo_offset_`, `textlist_offset_`, `date_created_`, `bin_offsets_[25]`, `lane_connectivity_offset_`, `predictedspeeds_offset_`, `tile_size_`, `boundingcircles_offset_`, `empty_slots_[10]` |

The CHANGELOG says `date_created_` was removed (#6115) and the `json` query parameter was removed (#6099). The current source still has the field and still parses `?json=`. Treat these as unresolved discrepancies.

**DirectedEdge** (48 bytes, 6 words) [V, `directededge.h`]:

| Word | Fields (bits) |
|---|---|
| 1 | `endnode_:46`, `restrictions_:8`, `opp_index_:7`, `forward_:1`, `leaves_tile_:1`, `ctry_crossing_:1` |
| 2 | `edgeinfo_offset_:25`, `access_restriction_:12`, `start_restriction_:12`, `end_restriction_:12`, `complex_restriction_:1`, `dest_only_:1`, `not_thru_:1` |
| 3 | `speed_:8`, `free_flow_speed_:8`, `constrained_flow_speed_:8`, `truck_speed_:8`, `name_consistency_:8`, `use_:6`, `lanecount_:4`, `density_:4`, `classification_:3`, `surface_:3`, `toll_:1`, `roundabout_:1`, `truck_route_:1`, `has_predicted_speed_:1` |
| 4 | `forwardaccess_:12`, `reverseaccess_:12`, `max_up_slope_:5`, `max_down_slope_:5`, `sac_scale_:3`, `cycle_lane_:2`, `bike_network_:1`, `use_sidepath_:1`, `dismount_:1`, `sidewalk_left_:1`, `sidewalk_right_:1`, `shoulder_:1`, `lane_conn_:1`, `turnlanes_:1`, `sign_:1`, `internal_:1`, `tunnel_:1`, `bridge_:1`, `traffic_signal_:1`, `spare1_:1`, `deadend_:1`, `bss_connection_:1`, `stop_sign_:1`, `yield_sign_:1`, `hov_type_:1`, `indoor_:1`, `lit_:1`, `dest_only_hgv_:1`, `spare4_:3` |
| 5 | `turntype_:24`, `edge_to_left_:8`, `length_:24`, `weighted_grade_:4` (default 6), `curvature_:4` |
| 6 | union `StopOrLine {StopImpact{stopimpact:24, edge_to_right:8}; uint32 lineid}`, then `localedgeidx_:7`, `opp_local_idx_:7`, `shortcut_:7`, `superseded_:7`, `is_shortcut_:1`, `speed_type_:1`, `named_:1`, `link_:1` |

`DirectedEdgeExt` is `uint64 spare0_` and is unused.

**NodeInfo** (32 bytes) [V]:

| Word | Fields (bits) |
|---|---|
| 1 | `lat_offset_:22`, `lat_offset7_:4`, `lon_offset_:22`, `lon_offset7_:4`, `access_:12` |
| 2 | `edge_index_:21`, `edge_count_:7`, `admin_index_:12`, `timezone_:9`, `intersection_:4`, `type_:4`, `density_:4`, `traffic_signal_:1`, `mode_change_:1`, `named_:1` |
| 3 | `transition_index_:21`, `transition_count_:3`, `local_driveability_:16`, `local_edge_count_:3`, `drive_on_right_:1`, `tagged_access_:1`, `private_access_:1`, `cash_only_toll_:1`, `elevation_:15`, `timezone_ext_1_:1`, `spare2_:1` |
| 4 | `uint64 headings_` (8 bits per local edge, 2° resolution; on the transit level holds a way id or encoded lon/lat) |

**Other fixed records [V]:**
- **NodeTransition:** `endnode_:46`, `up_:1`, `spare_:17`.
- **Sign:** `index_:22`, `type_:8`, `route_num_type_:1`, `tagged_:1`, `uint32 text_offset_`.
- **TurnLanes:** `edgeindex_:22`, `spare_:10`, `text_offset_`.
- **AccessRestriction:** `edgeindex_:22`, `type_:6`, `modes_:12`, `except_destination_:1`, `spare_:23`, `uint64 value_`.
- **ComplexRestriction** (variable length, `kMaxViasPerRestriction`=31):
  - Word 1: `from_graphid_:46`, `has_dt_:1`, `begin_day_dow_:5`, `begin_month_:4`, `begin_week_:3`, `begin_hrs_:5`.
  - Word 2: `to_graphid_:46`, `dt_type_:1`, `end_day_dow_:5`, `end_month_:4`, `end_week_:3`, `end_hrs_:5`.
  - Word 3: `type_:4`, `modes_:12`, `via_count_:5`, `dow_:7`, `begin_mins_:6`, `end_mins_:6`, `probability_:7`, `spare_:17`.
  - Then the via GraphIds.
- **Admin:** `country_offset_`, `state_offset_`, `char country_iso_[kCountryIso]`, `state_iso_[kStateIso]`, `spare_[3]`.
- **LaneConnectivity:** `to_:22`, `from_:42` (way id), plus two `uint64` lane masks.
- **TransitDeparture:**
  - Word 1: `lineid_:20`, `routeindex_:12`, `tripid_:32`.
  - Word 2: `blockid_:20`, `schedule_index_:12`, `headsign_offset_:24`, `type_:2`, `wheelchair_accessible_:1`, `bicycle_accessible_:1`, `spare_:4`.
  - Then a union of fixed `{departure_time_:17, elapsed_time_:17}` and frequency `{departure_time_:17, end_time_:17, frequency_:13, elapsed_time_:17}`.
- **TransitStop:** `one_stop_offset_:24`, `name_offset_:24`, `generated_:1`, `traversability_:2`, `spare_:13`.
- **TransitRoute:** colors as two `uint32`, then 24-bit text offsets.
- **TransitSchedule:** `uint64 days_`, then `days_of_week_:7`, `end_day_:6`.
- **TransitTransfer:** `from_stopid_`, `to_stopid_`, `type_:4`, `mintime_:16`.

**EdgeInfo** (variable length) [V]:
- `EdgeInfoInner`:
  - Word 1: `wayid_:32`.
  - Word 2: `mean_elevation_:12`, `bike_network_:4`, `speed_limit_:8`, `extended_wayid0_:8`.
  - Word 3: `name_count_:4`, `encoded_shape_size_:16`, `extended_wayid1_:8`, `extended_wayid_size_:2`, `has_elevation_:1`, `spare0_:1`.
- Then `NameInfo[name_count]`, the encoded shape, optional extended way-id bytes 2 and 3, and optional encoded elevation.
- `NameInfo` is `name_offset_:24`, `additional_fields_:4`, `is_route_num_:1`, `tagged_:1`, `spare_:2`.
- Shape7 uses seven bits per varint group. The default coordinate precision in 3.9.3 is six decimal places, as in polyline6 API output.
- Tagged values are stored in the text list with a 1-byte `TaggedValue` prefix: `kLayer`=1, `kLinguistic`=2, `kBssInfo`=3, `kLevel`=4, `kLevelRef`=5, `kLandmark`=6, `kConditionalSpeedLimits`=7, `kLevels`=8, `kOSMNodeIds`=9, `kTunnel`='1', `kBridge`='2'.
- Linguistic header: `language_:8`, `length_:8`, `phonetic_alphabet_:3`, `name_index_:4`, `spare_:1`.
- `kMaxNamesPerEdge`=15, `kMaxEncodedShapeSize`=65535.

**Bins [V]:** `kBinCount`=25. Each `bin_offsets_[i]` is the end offset into a GraphId array of edges intersecting that 1/5-tile cell. Per #2529 bins are 0.05°×0.05° (that matches 0.25°/5).

**Predicted speeds [V]:** `kSpeedBucketSizeMinutes`=5, so 2016 buckets per week. `kCoefficientCount`=200 `int16`, DCT-II compressed, base64 encoded when ingested by `valhalla_add_predicted_traffic`. `PredictedSpeeds::speed(idx, seconds_of_week)` decompresses on demand.

**Speed resolution order [D]:** live → predicted → constrained → free-flow → base, in `GraphTile::GetSpeed`.

**Tar extract [V]:**
- `index.bin` entries are `{uint64 offset; uint32 tile_id (level+tileid); uint32 size}`.
- It must be the first file for remote tars, which are read with HTTP range requests.
- Without an index, the tar is scanned (`data_processing.scan_tar`).
- Tiles are `TarballGraphMemory` views into one mmap.

**traffic.tar [V]:**
- `TrafficTileHeader{uint64 tile_id; uint64 last_update; uint32 directed_edge_count; uint32 traffic_tile_version (= VALHALLA_VERSION_MAJOR); uint32 spare2, spare3}`, 32 bytes.
- Followed by `TrafficSpeed` × edges, 64 bits each: `overall_encoded_speed:7`, `encoded_speed1..3:7`, `breakpoint1:8`, `breakpoint2:8`, `congestion1..3:6`, `has_incidents:1`, `spare:1`. Speeds are in 2 kph units; raw 127 means unknown.
- Accessed through `volatile` pointers into a writable mmap, so external processes update it in place.

## 4. Algorithms

**thor files [V]:** `bidirectional_astar.cc` (74 KB), `unidirectional_astar.cc` (forward and reverse templates; `timedep_*` no longer exist), `multimodal_astar.cc`, `multimodal_transit.cc`, `dijkstras.cc`, `isochrone.cc`, `costmatrix.cc` (67 KB), `timedistancematrix.cc`, `timedistancebssmatrix.cc`, `optimizer.cc` (7 KB), `map_matcher.cc`, `route_matcher.cc`, `triplegbuilder.cc` (97 KB), `centroid.cc`, `alternates.cc`, `expansion_action.cc`, `trace_attributes_action.cc`, `trace_route_action.cc`, `route_action.cc`, `matrix_action.cc`, `optimized_route_action.cc`, `status_action.cc`, `worker.cc`.

`locate`, `height` and `transit_available` are handled by loki, or loki plus skadi. There is no chinese postman.

**Shared machinery [V]:**
- **`DoubleBucketQueue<label_t>`:**
  - Bucket width = `costing->UnitSize()`; range = `kBucketCount` (20000) × bucketsize.
  - Each bucket is a `std::vector<uint32_t>` of label indices, plus an overflow bucket.
  - `decrease()` does a linear `erase(remove)` in the old bucket.
- **`PathAlgorithm`:** `kInterruptIterationsInterval`=5000, `max_reserved_labels_count`, `clear_reserved_memory`.
- **`EdgeStatus`:** `std::unordered_map<uint32_t tile, EdgeStatusInfo*>`. Each value is a heap array sized to the tile's edge count. `EdgeStatusInfo{index_:28, set_:4}`.
- **`EdgeLabel` (base):**
  - `predecessor_`, `path_distance_:25`, `restrictions_:7`
  - `edgeid_:46`, `opp_index_:7`, `opp_local_idx_:7`, `mode_:4`
  - `endnode_:46`, `use_:6`, `classification_:3`, plus flags (`shortcut`, `dest_only`, `origin`, `destination`, `toll`, `not_thru`, `deadend`, `on_complex_rest`, `closure_pruning`)
  - `path_id_:7`, `restriction_idx_:8`, `internal_turn_:2`, plus misc flags and `destonly_access_restr_mask_:7`
  - `Cost cost_` (cost and secs), `float sortcost_`
- **Label subclasses:**
  - `PathEdgeLabel` adds `transition_cost_`.
  - `BDEdgeLabel` adds `transition_cost_`, `opp_edgeid_:63`, `not_thru_pruning_:1`, `float distance_`.
  - `MMEdgeLabel` adds `prior_stopid_`, `tripid_`, `blockid_:21`, `transit_operator_:10`, `has_transit_:1`, `walking_distance_`, `distance_`.
- **`AStarHeuristic`:** `sqrtf(DistanceApproximator::DistanceSquared(ll)) * costfactor_`, where the factor comes from `AStarCostFactor()` (pure virtual).
- **HierarchyLimits:**
  - `kDefaultMaxUpTransitions = {0,400,100,0…}`
  - `kDefaultExpansionWithinDist = {∞, 100000, 5000, 0…}`
  - `kDefaultExpansionWithinDistBidir = {∞, 20000, 5000, 0…}`
  - `StopExpanding(limits, dist)` gates downward transitions and expansion per level.
- **Shortcuts:** levels 0 and 1 get shortcut edges. Base edges are flagged `superseded`. Shortcuts are used by bidirectional A* but not by time-dependent unidirectional A* [D]. `shortcut_recovery.h` / `GraphReader::RecoverShortcut` expand them [V].

**BidirectionalAStar [V]:**
- `kThresholdDelta`=420 (config `bidirectional_astar.threshold_delta`).
- On the first meeting, `cost_threshold_ = c + threshold_delta`.
- For alternatives: `kAlternativeCostExtend`=1.2× + delta, plus `kAlternativeIterationsDelta`=100000.
- `SetForwardConnection` / `SetReverseConnection` check the opposite side's `EdgeStatus`.
- `not_thru` pruning: a label carries `not_thru_pruning` and edges with `not_thru` are pruned. Pruning is disabled on the second pass in `route_action`.
- Destination-only edges are disallowed in bidirectional search: `set_allow_destination_only(false)`.

**Algorithm selection [V]:**
- `route_action.cc` uses bidirectional A* by default.
- It uses `UnidirectionalAStar` forward or reverse for `depart_at` / `arrive_by` when the distance is under `max_timedep_distance` (default 500 km [D]) and `prioritize_bidirectional` is false.
- It uses multimodal for transit and multimodal costing.

**Matrix [V]:**
- `CostMatrix` is bidirectional many-to-many.
  - Defaults: `kMaxMatrixIterations`=2M, min/max iterations 100/2800, `costmatrix.max_reserved_locations`=25, `check_reverse_connection` on.
  - There is a second pass for failed pairs.
  - No `std::thread` appears in `costmatrix.cc`; it is single-threaded per request **[V by grep]**.
- `TimeDistanceMatrix` runs one Dijkstra per source (one-to-many). `TimeDistanceBSSMatrix` is the bikeshare variant.
- `kCostMatrixThreshold`=5: if sources ≤5 or targets ≤5, `TimeDistanceMatrix` is used.
- With time-dependence, `TimeDistanceMatrix` is the default unless `prioritize_bidirectional` is set.

**Other thor algorithms:**
- **Isochrone [V/I]:** Dijkstras expansion into a `GriddedData` grid, then contouring in `midgard/gridded_data.h` (marching-squares-style). Output is GeoJSON or GeoTIFF.
- **Optimizer [V size, I detail]:** a small simulated-annealing/ant-style TSP over the cost matrix.
- **Centroid:** multi-origin expansion to find a convergence point.

**sif [V]:**
- `DynamicCost` virtuals include `Allowed`, `AllowedReverse`, `Allowed(NodeInfo*)`, three `EdgeCost` overloads, `TransitionCost`, `TransitionCostReverse`, `AStarCostFactor`, `UnitSize`, `IsExcluded` ×2, `BSSCost`, `TransferCost`, and setters.
- Factory registrations: auto, bicycle, bus, taxi, motor_scooter, motorcycle, pedestrian, truck, transit. `multimodal`, `none`, `bikeshare` and `auto_pedestrian` map to `NoCost`.
- The hot loop calls these through a `shared_ptr<DynamicCost>` with virtual dispatch, about 3–4 calls per relaxed edge (for example `bidirectional_astar.cc` lines 254–283).
- Options are parsed in `ParseBaseCostOptions` and per-model parsers. `recost.cc` recomputes a fixed path.
- `EvaluateRestrictions` handles conditional access and uses `boost::container::small_vector`.

**loki [V]:**
- `search.cc`: bin search, projection, filtering, then reachability.
- `reach.cc`: small-radius Dijkstra for `minimum_reachability`.
- `node_search.cc`: bbox node lookup.
- `polygon_search.cc`: avoid/exclude polygons to edge exclusions.
- `connectivity_map` lives in baldr.
- Bounding circles in tiles speed up `/locate` and `/tile`.
- `linear_cost_factors` are resolved in loki.

**meili [V files, D flow]:**
- Flow: `OfflineMatch` → candidate search → Viterbi (`viterbi_search.cc`, `topk_search.cc`) with emission and transition cost models → `match_route.cc` → `thor/map_matcher.cc::FormPath` → `TripLegBuilder`.
- Meili keeps its own 100 m grid cache (`grid_range_query.h`). #2529 says this is roughly 10× faster than plain loki lookups once warm.

**odin [V]:**
- Flow: EnhancedTripLeg → `ManeuversBuilder` → `NarrativeBuilder`, using `locales/*.json` compiled into `locales.h` by `ValhallaBin2Header.cmake`.
- There are 36 locale JSONs, including en-US-x-pirate, he-IL and zh-CN.
- Also signs, markup formatter, and verbal text formatters (in baldr).

**tyr [V]:**
- `actor_t` is the in-process orchestration used by `valhalla_service` one-shot mode, the bindings and gurka.
- Supported formats (`kFormatActionSupport`):

| Format | Endpoints |
|---|---|
| json | All |
| gpx | route, optimized_route, trace_route |
| osrm | route, optimized_route, trace_route, trace_attributes, locate, status, sources_to_targets, expansion |
| pbf | route, optimized_route, trace_route, centroid, trace_attributes, status, sources_to_targets, isochrone, expansion |
| geotiff | isochrone |
| mvt | tile |

**skadi [V]:**
- `HGT_DIM` is 3601 (1″ SRTM), raw `int16`.
- Tiles are `.hgt`, `.hgt.gz` or `.hgt.lz4`, named by the regex `[NS]dd[WE]ddd`.
- `cache_item_t` holds a `mem_map` and is decompressed on use. Sampling is bilinear.
- Tiles can be fetched remotely through the curl tile getter.
- GeoTIFF support is for isochrone output, not DEM input.

## 5. mjolnir build pipeline

`BuildStage` [V, `valhalla/mjolnir/util.h`], driven by `build_tile_set()` in `src/mjolnir/util.cc`:

| # | Stage | What it does | Outputs |
|---|---|---|---|
| 0 | kInitialize | Setup, PBF md5 | — |
| 1 | kParseWays | `PBFGraphParser::ParseWays`: osmium pool, one ordering thread, up to `kMaxLuaConcurrency`=8 LuaJIT states (`kWaysChunksPerLua`=8) | `ways.bin` (OSMWay), `way_nodes.bin` (OSMWayNode without coords), `access.bin` |
| 2 | kParseRelations | Restrictions, routes, areas | `complex_from_restrictions.bin`, `complex_to_restrictions.bin` |
| 3 | kParseAreaWays | Pedestrian areas | — |
| 4 | kParseNodes | Fills coords and node attributes, then sorts `way_nodes` (PSRS) | `way_nodes.bin` (with coords), `bss_nodes.bin`, `linguistics_node.bin` |
| 5 | kBuildAreas | Voronoi medial-axis traversals for pedestrian areas | — |
| 6 | kConstructEdges | `GraphBuilder::BuildEdges` | `edges.bin`, `nodes.bin`, `edge_shapes.bin`, `edge_node_ids.bin`, `tile_manifest.json` |
| 7 | kBuild | `GraphBuilder::Build`, multithreaded per tile | Level-2 tiles with admins, tz, signs, lanes |
| 8 | kEnhance | Density, speeds, turn types, link reclassification, country access defaults (`countryaccess.cc`), name consistency | — |
| 9 | kFilter | Filter or aggregate edges for `include_*` flags (now multithreaded) | — |
| 10 | kTransit | Merge transit tiles | — |
| 11 | kBss | Bike-share connections | — |
| 12 | kHierarchy | Copy edges up to levels 0/1, add NodeTransitions | `new_nodes_to_old_nodes.bin`, `old_nodes_to_new_nodes.bin` |
| 13 | kShortcuts | Build shortcuts (no threading found by grep) | — |
| 14 | kRestrictions | Complex restrictions | — |
| 15 | kElevation | Elevation. Note that in code, elevation runs **before** restrictions | — |
| 16 | kValidate | Opposing edges, stats, bins | — |
| 17 | kCleanup | Remove temp files | — |

**Supporting machinery:**
- **`midgard::sequence<T>`** [V]: an mmap'd file-backed vector. Its sort is PSRS (Shi & Schaeffer), with concurrency capped at 8.
- **`UnorderedIdTable`** [V]: a 64-bit-word bitset keyed by `id/64` in a hash map, used for OSM node and way id marks.
- **Lua** [V]: `graph.lua` defines tag tables (highway, road_class, access, per-mode node tables, …) and `nodes_proc`, `ways_proc`. `admin.lua` adds `rels_proc` and `rel_members_proc`. The script is embedded, or overridden with `graph_lua_name`.
- **Admins** [V]: `valhalla_build_admins` uses osmium plus `admin.lua`, writing an sqlite/spatialite DB with GEOS-built polygons.
- **Timezones** [V]: `valhalla_build_timezones` is a bash script. It downloads the timezone-boundary-builder 2026f shapefile and imports it with spatialite_tool into a `tz_world` table.
- **GTFS** [V files]: `valhalla_ingest_transit` (just_gtfs → `transit.proto` pbf tiles) → `valhalla_convert_transit` (level-3 `.gph`) → the kTransit stage.
- **Structs:** `OSMWay` is in `osmway.h` (68 KB header). `OSMNode` and `OSMRestriction` are in `osm*.h`.
- **Planet scale [D, CLAUDE.md]:**
  - About 85 GiB PBF in, about 95 GiB tiles out, about 205k tiles.
  - About 1B directed edges, about 500M nodes, about 3B way nodes; `way_node.bin` is about 110 GiB.
  - About 7 h on an m8gd.8xlarge (32 vCPU, 128 GiB).
- **Older planet build times:**
  - About 24 h on 16 cores / 64 GB, with parsing single-threaded at the time (#5099, 2025).
  - 1.5–2 days on 16 threads (#3389).
  - `ParseNodes` took 10,803 s in March 2026 (#5955).
  - About 15 h on a quad-core with 16 GB per the old mjolnir docs.

## 6. Service layer

**Pipeline [V]:**
- `valhalla_service config [concurrency]` starts the prime_server `http_server_t`, then loki_proxy → loki workers → thor proxy/workers → odin proxy/workers.
- With `--inproc-sockets` (default true) these are threads using `inproc://` ZMQ.
- The separate `valhalla_{loki,thor,odin}_worker` binaries allow distributed deployment.
- Between stages the full `Api` protobuf is serialized and re-parsed (`request.SerializeAsString()` in `loki/worker.cc`).
- Concurrency defaults to `hardware_concurrency`. Each worker thread handles one request at a time.
- Interrupts: prime_server's interrupt socket feeds a `std::function` that is checked every 5000 iterations and in `GraphReader::SetInterrupt`.
- `quiesce` drain is 28 s.

**Endpoints** (`Options::Action`, URL path = `/name`) [V]: `route`, `locate`, `sources_to_targets`, `optimized_route`, `isochrone`, `trace_route`, `trace_attributes`, `height`, `transit_available`, `expansion`, `centroid`, `status`, `tile` (`/tile` with z/x/y produces MVT).

**Request parsing [V]:**
- GET and POST are accepted.
- `Content-Type: application/x-protobuf` means the body is an `Api` message.
- Otherwise JSON comes from `?json=` or the body, and other query params are merged in.
- `from_json` in `src/worker.cc` (72 KB) fills `Options`.

**Protos (14) [V]:** `api`, `common`, `directions`, `expansion`, `incidents`, `info`, `isochrone`, `matrix`, `options` (20 KB), `sign`, `status`, `transit`, `transit_fetch`, `trip`. All are `LITE_RUNTIME`.

**Config [V]:**
- `scripts/valhalla_build_config` generates `valhalla.json`, which is read into a `boost::property_tree` singleton.
- Example service limits: auto `max_distance` 5,000,000 m, `max_locations` 20, `max_matrix_distance` 400 km, `max_matrix_location_pairs` 2500. Bicycle and pedestrian use 250–500 km.

**Tile caches [V]:**
- Default is `FlatTileCache`: a vector indexed by tile id, with `DEFAULT_MAX_CACHE_SIZE` = 1 GiB.
- `SimpleTileCache` is an `unordered_map`. `TileCacheLRU` has soft or hard memory control.
- `SynchronizedTileCache` wraps one global cache behind a mutex (`global_synchronized_cache`).
- By default each worker thread has its own GraphReader and cache.
- For tar-extract tiles, `GetGraphTile` does a cache lookup, then a lookup in the `tiles` map, then wraps a pointer into the mmap. No copy is made; `AVERAGE_MM_TILE_SIZE` is used for accounting.
- `tile_url` fetches tiles over curl (5 s connect timeout, retries on 408/429/5xx, remote tar via `index.bin` and range requests).

## 7. Testing and benchmarking

**Unit tests [V]:**
- 124 files in `test/*.cc`. The largest are `narrativebuilder` (498 KB), `parse_request`, `maneuversbuilder`, `mapmatch`, `astar`.
- Also `test/pinpoints` (68 path-pbf fixtures), `test/scripts` (Python), `test/bindings`, `test/traffic_matcher_tiles`.

**Gurka [V]:**
- 136 `test/gurka/test_*.cc` files plus `gurka.cc` / `gurka.h`.
- `map_to_coordinates(ascii_map, gridsize_m)` turns characters into nodes.
- `gurka::ways` / `nodes` / `relations` are tag maps. These are written to a synthetic OSM PBF and then run through `buildtiles` (full `build_tile_set`, with optional `start_stage` / `end_stage`).
- `do_action` runs through `actor_t`. Assertions include `expect_path`, `expect_maneuvers`, `osrm::expect_steps`.
- `findWay` / `findWayNodes` inspect the temp `.bin` files.

**Fixtures [V]:** `test/data` has PBFs for utrecht (11.8 MB), liechtenstein, baltimore, harrisburg, nyc, rome, paris_bss, whitelion_bristol, amsterdam, melbourne and others; admin sqlite files; traffic CSVs.

**Benchmarks [V]:**
- No Google Benchmark targets remain.
- Rust criterion benches: `actor_bench.rs`, `config_bench.rs`, `tiles_bench.rs`.
- `run_route_scripts/perf_test` has `url_de_benchmark_routes.txt` (544 KB of German route URLs) for siege (`-c 4 -r 2550`), plus wrk scripts (`route.lua`, `trace_route.lua`) and throughput plotting.
- `run_with_server.py` and `run_with_server_matrix.py` replay `test_requests/` against a server for RAD-style diffing.

**Published numbers (sparse):**
- **Edges touched per route [D, CLAUDE.md]:**

| Route | Distance | Algorithm | Edges touched |
|---|---|---|---|
| London → Birmingham | 190 km | Bidirectional | ~485k |
| London → Birmingham | 190 km | Unidirectional | ~550k |
| Berlin → Prague | 350 km | Bidirectional | ~420k |
| Berlin → Prague | 350 km | Unidirectional | ~3M |
| Paris → Berlin | 1000 km | Bidirectional | ~800k |
| San Francisco → New York | 4679 km | Bidirectional | ~1M |

- **Planet build and size:** see §5.
- **Pedestrian areas** on a planet build: about 2 min parsing and 9 min building ([docs/docs/concepts/pedestrian-areas.md](https://github.com/valhalla/valhalla/blob/master/docs/docs/concepts/pedestrian-areas.md)).
- **User test on Sri Lanka, 4 vCPU** ([#2604](https://github.com/valhalla/valhalla/issues/2604)):
  - Route: Valhalla 1000 req/s, average 13 ms. OSRM 700 req/s.
  - 33×1 matrix: Valhalla 45 req/s, average 2095 ms. OSRM 100 req/s, 10 ms. This predates the current CostMatrix.
- **Matrix scaling plots:** [#1809](https://github.com/valhalla/valhalla/issues/1809).
- **No official latency, throughput or memory benchmarks** turned up in the docs, README or blog searches. Third-party comparisons are anecdotal: [sumguy.com](https://sumguy.com/osrm-vs-valhalla-vs-graphhopper/) claims about 20–80 ms per route versus single-digit ms for OSRM, with no reproducible method. The [routingpy notebook](https://nbviewer.org/github/nilsnolde/routingpy/blob/1.3.0/examples/compare_providers.ipynb) compares outputs, not performance. Other search hits were [Interline tilepacks](https://interline.io/valhalla/tilepacks) (40 GB OSM plus 1.6 TB elevation in) and [pistack](https://www.pistack.xyz/posts/2026-04-25-graphhopper-vs-osrm-vs-valhalla-self-hosted-routing-engines-guide-2026/).
- **Characterization from an OSRM core developer** ([#1514](https://github.com/valhalla/valhalla/issues/1514)): Valhalla is "reasonably fast point-to-point", OSRM has "very high performance".

For a "beat their scores" baseline, you will most likely need to produce your own numbers: the siege/wrk kit on a fixed tileset, plus `run_with_server*.py`.

## 8. Performance characteristics a rewrite could attack

1. **No contraction hierarchies; only a 3-level hierarchy plus shortcuts. [V]** Time-dependent unidirectional search ignores shortcuts and explodes to about 3M edges on Berlin→Prague [D]. CCH/CRP-style customizable preprocessing could keep dynamic costing.
2. **Virtual dispatch through `shared_ptr<DynamicCost>` in the relax loop. [V]** `Allowed`, `AllowedReverse`, `EdgeCost` and `TransitionCost` run per edge. Comptime-specialized costing in Zig would remove it.
3. **Tile lookups. [V]** `GetGraphTile(id, tile&)` short-circuits when the tile is the same. Otherwise it does a cache `Get` (FlatTileCache vector index by default, a hash map for the others), plus refcounted `graph_tile_ptr` copies. Cross-tile `endnode` hops pay this cost.
4. **EdgeStatus is an `unordered_map<tile, heap array>` [V]**, so there is a hash per edge status lookup. Label storage is a `std::vector` with `reserve(max_reserved_labels_count)` and possible reallocation [V]. `DoubleBucketQueue::decrease` does a linear erase within a bucket [V].
5. **Protobuf round-trip between loki, thor and odin even in-process [V]**, plus full `Api` serialization. JSON is parsed with rapidjson into protobuf, then serialized back out to JSON [V].
6. **Matrices.** CostMatrix is single-threaded per request [V by grep]. TimeDistanceMatrix runs one Dijkstra per source [V]. Matrix throughput is the weakest published area [D, #2604].
7. **One request per worker thread; no intra-request parallelism [V/I].**
8. **Build pipeline.**
   - Way parsing is now parallel, but Lua is capped at 8 states [V].
   - Node parsing and sort were the bottleneck (10,803 s) [D]; PSRS sort is now capped at 8 threads [V].
   - Shortcut building has no threading [V]. Hierarchy building has a "TODO: thread this" [V].
   - Tile-thread load imbalance [D, #3389].
   - The roughly 110 GiB `way_nodes.bin` dominates I/O [D].
9. **Config lookups use `boost::property_tree`, often at construction rather than per request [V/I].**
10. **Meili duplicates loki's spatial index** with its own grid cache, because bins are coarse (0.05°) [D, #2529].
11. **EdgeInfo decoding is lazy.** Shape is decoded on demand and the tag cache is a mutable `std::multimap` [V], which is costly for trace_attributes and odin.
12. **Bitfield-packed structs are a compatibility constraint, not an opportunity.** To read upstream tiles you must keep the x86-64 GCC bitfield layout, including the header padding quirk [V].
