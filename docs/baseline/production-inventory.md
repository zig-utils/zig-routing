# Production inventory

A read-only inventory of the Valhalla deployment zig-routing replaces ("the production routing
box"), taken on 2026-11-18 (issue P0.03). Every figure comes from commands that only read: process
and service listings, config and log files, `df`, `free`, `/status`. Hostnames, addresses, ports
and credentials are deliberately left out of this public file.

## Summary

- **Valhalla 3.9.0**, not 3.9.3: the oracle is pinned to 3.9.3 (see "Consequences").
- **Only `/height` is used.** Across the 23 days the logs cover (2026-10-27 to 2026-11-18),
  the box answered 203,376 `/height` requests and no `/route`, matrix, isochrone or trace
  requests at all.
- **One nightly burst carries the load.** About 9,000 `/height` requests a night, nearly all
  inside one minute at 02:10 UTC: a consuming app's batch elevation job. Interactive traffic
  is a few hundred requests a day.
- **The latency tail comes from elevation tile inflation.** `/height` p50 is 0.69 ms, but p99
  is 191 ms and the maximum 925 ms. Valhalla keeps 50 inflated `.hgt.gz` tiles; the region
  has 1,417.

## Machine

| | |
|---|---|
| CPU | 8 vCPU, AMD EPYC (Rome), one thread per core, 2.0 GHz |
| Memory | 15.6 GB, 16 GB swap (13 MB in use) |
| Disk | 150 GB virtual SSD, ext4, 85 GB used |
| OS | Ubuntu 24.04.5 LTS, kernel 6.8 |

## Service

- `valhalla_service <config> 6`: one process, 6 workers (26 threads), installed from pantry
  (not Docker), run as a systemd unit that restarts on failure.
- Listens on Valhalla's default HTTP port. The host firewall admits only the consuming app's
  server. HTTP has no timeout (`timeout_seconds: -1`).
- Resident memory: **4.7 GB** after 4 days of uptime, with 9 GB of page cache (tiles and
  elevation). Virtual size 61 GB.
- Logging: prime_server's request and response lines (id, time, method, path, status, bytes),
  appended to one file. Request bodies are not logged.

## Data

| Item | Format | Size | Notes |
|---|---|---|---|
| Routing tiles | tile directory (no `tiles.tar`) | 27 GB | level 0: 118 files (1.0 GB), level 1: 1,139 (2.6 GB), level 2: 17,379 (23 GB) |
| Previous tiles | tile directory | 27 GB | kept as a rollback until the next build |
| Elevation | `.hgt.gz`, 1° SRTM tiles | 8.9 GB | 1,417 tiles in 54 latitude directories, only those the graph covers |
| Admins | SpatiaLite | 36 MB | |
| Timezones | SpatiaLite | 122 MB | |

Coverage: Geofabrik's `us-latest` and `dach-latest` extracts (the US, Germany, Austria and
Switzerland), with hierarchy and shortcuts, all modes included (driving, bicycle, pedestrian,
driveways; no construction, no platforms). Tileset built 2026-11-02.

### Build

A cron job rebuilds monthly (03:00 UTC on the 2nd): it downloads fresh extracts, builds into a
new directory with `valhalla_build_config` defaults and concurrency 6, swaps it in, and
restarts the service. To fit the 150 GB disk, the extracts are deleted after node parsing and
the intermediate `.bin` files after the build stage. Timings on 2026-11-02:

| Stage | Duration |
|---|---|
| Download both extracts (18 GB) | 1 h 57 min |
| Timezones + admins | 6.5 min |
| Parse nodes | 51 min |
| Construct edges, build | 35 min |
| Elevation (already present) | 1 s |
| Enhance through cleanup | 1 h 35 min |
| **Build total, without the download** | **3 h 08 min** |

This is the build-time row of the scoreboard for the production extract (US+DACH, 8 vCPU).

## Configuration

The config is `valhalla_build_config`'s output with paths, concurrency 6 and the elevation
directory set; nothing else was changed. Settings that matter for parity and limits:

| Setting | Value |
|---|---|
| `service_limits.pedestrian` | max_distance 250 km, max_locations 50, matrix 200 km / 2,500 pairs |
| `service_limits.bicycle` | max_distance 500 km, max_locations 50 |
| `service_limits.auto` | max_distance 5,000 km, max_locations 20 |
| `service_limits.skadi` | max_shape 750,000, min_resample 10 m |
| `service_limits.isochrone` | 4 contours, 120 min, 25 km |
| `service_limits.trace` | 200 km, max_shape 16,000 |
| `max_distance_disable_hierarchy_culling` | 0 |
| `thor.bidirectional_astar.hierarchy_limits` | up transitions 400 / 100; expand within 100,000 km / 20 km / 5 km |
| `thor.source_to_target_algorithm` | select_optimal |
| `loki.service_defaults` | minimum_reachability 50, search_cutoff 35 km, radius 0, heading_tolerance 60 |
| `loki.use_connectivity` | true |
| `mjolnir.data_processing` | infer_internal_intersections, infer_turn_channels, apply_country_overrides, use_admin_db; use_direction_on_ways, allow_alt_name, use_urban_tag and use_rest_area off |
| `mjolnir.max_cache_size` | 1 GB, no LRU cache |

## Request mix

From prime_server's log, 2026-10-27 to 2026-11-18 (23 days):

| Endpoint | Requests | Status | Latency p50 / p90 / p99 / max | Response bytes p50 / p90 / p99 / max |
|---|---|---|---|---|
| `/height` (POST) | 203,376 | all 200 | 0.69 / 1.35 / 191 / 925 ms | 1,150 / 4,316 / 5,462 / 6,004 |
| `/status` | 4 | 200 | 1.3 ms | 363 |
| everything else | 0 | | | |

- **Volume:** 6,805 to 12,862 requests a day, a median of about 8,800.
- **Timing:** 97% of all requests arrive in the 02:00 UTC hour, almost all within one minute
  (02:10). The busiest minute held 9,666 requests and the busiest second 794. The rest are
  spread through the day, with 0 to about 100 an hour.
- **Payloads:** responses of 1 to 6 KB, which means short shapes of tens of points (the
  response echoes the shape), not the 1,000-point profiles the corpora also include.

Latency is measured from prime_server's request line to its response line, so it covers
queueing inside Valhalla during the burst, not network time.

### `costing_options` sets

The log has no request bodies, so these come from the consuming apps' source. None was used
against this box in the logged period: their `/route` traffic went elsewhere or did not occur.

| Client | Costing | Options |
|---|---|---|
| Trail app | pedestrian | `walkway_factor 0.6, sidewalk_factor 1, use_tracks 0.8, max_hiking_difficulty 3` |
| Training app, "coast" | pedestrian | `walkway_factor 0.6, sidewalk_factor 1, use_tracks 0.8, use_living_streets 0.8, max_hiking_difficulty 3, step_penalty 30` |
| Training app, "trails" | pedestrian | `walkway_factor 0.5, sidewalk_factor 1, use_tracks 1, use_living_streets 0.6, max_hiking_difficulty 3, step_penalty 30` |
| Training app, "direct" | pedestrian | `step_penalty 30` |
| Training app, "coast" | bicycle | `use_roads 0.2, use_hills 0.4` |
| Training app, "trails" | bicycle | `use_roads 0.1` |
| Training app, default | bicycle | none |

All `/route` requests from both clients send `directions_type: none`. `/height` requests send
`shape` with `range: false`.

## Consequences for the plan

- **Phase 2 (`/height`) is the whole of today's production load.** Cutting `/height` over
  replaces everything the box does now. `/route` parity (Phase 3) protects the apps' fallback
  path and future use, not current traffic.
- **The nightly burst is the workload to benchmark.** That means about 9,000 short-shape
  requests at once, at several connections. The p99 of 191 ms comes from gzip tile inflation
  under a 50-tile cache; the packed DEM (P2.04) removes it (cold first sample 122 ms down to
  0.4 ms on the test tiles).
- **Version.** Production runs 3.9.0 and the oracle 3.9.3. Before the parity gates are applied
  to production traffic, either run the oracle at 3.9.0 too, or upgrade production first. The
  `/height` path (skadi) is the one to check; a difference there would show up in P2.06's
  shadow comparison.
- **Memory headroom.** 4.7 GB resident plus 9 GB of page cache on a 16 GB box. zig-routing's
  RSS target (P4 gate) has to leave the page cache room for the hot tiles.
- **Disk.** Two tile generations plus elevation take 63 GB of 150 GB, and a build needs about
  50 GB of intermediates on top. Our build should stay under that, or under the 100 GiB
  scratch target in the scoreboard.
