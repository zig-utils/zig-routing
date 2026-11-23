# Valhalla 3.9.3 baseline scoreboard

Valhalla ran on native x86-64 Linux on a c7a.2xlarge with eight AMD EPYC 9R14
cores, 16 GiB of RAM and 16 GiB of swap. The 250 GiB gp3 volume was provisioned
for 5,000 IOPS and 500 MiB/s. Six Valhalla workers served requests using the
production pruning settings. The ReleaseFast `zr bench` client, built from
`ccbde15`, used one thread on the same host. The raw reports record the image digest,
kernel, corpus SHA-256 and dataset input checksums. [Raw reports](../bench/baseline)

## Production comparison

| US+DACH workload | Valhalla 3.9.3 | zig-routing target |
| --- | --- | --- |
| Pedestrian and bicycle routes, 1 to 80 km | p50/p99 14.516/618.660 ms at one connection and 42.205/782.238 ms at eight | Phase 3 cutover requires p50 and p99 at or below Valhalla's. Scoreboard target is at least 5x lower. |
| Auto routes, 200 / 1,000 / 4,000 km | p50 45.875 / 83.886 / 346.030 ms at one connection and 58.458 / 119.013 / 433.062 ms at eight. Median settled pairs 101,499.5 / 176,270 / 598,618. | At least 20x fewer edges settled and 10x lower p50 |
| Bulk elevation | 5,956 points/s at one connection and 33,935 points/s at eight | At least 10x points/s |
| Startup to first HTTP response | 0.369 s through the first successful `/status` | Under 1 s, first-request p99 within 2x warm |
| Memory after soak | 89.117 GiB process RSS, 14.151 GiB charged to the container shortly before the final sample | Flat memory use, under 256 MB scratch per thread |
| Regional graph build and peak scratch | 2 h 40 min 20 s, 76.875 GiB of intermediate tile files, 98.620 GiB of peak added filesystem usage | Planet build under 1 h on 32 vCPUs, scratch under 100 GiB |

The targets come from the plan. Dedicated time-dependent, matrix, isochrone,
map-matching and planet baselines are tracked by their phases. Every corpus
in the pinned regional set appears below. [Targets](PLAN.md#scoreboard-what-beat-their-perf-means) ·
[Worldwide replay](https://github.com/zig-utils/zig-routing/issues/264)

## Regional replays

Each cell averages the corresponding metric from the two accepted replays.
All measured requests count toward throughput, including upstream HTTP error
responses. The raw reports give the HTTP status counts. All accepted replays
completed with zero transport errors, timeouts or unsent requests. The
largest p50 difference across the 32 pairs was 4.966%, relative to the smaller
p50.

| Corpus | Corpus requests | 1 conn p50 ms | p99 ms | req/s | 8 conns p50 ms | p99 ms | req/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `de-benchmark.us-dach` | 2550 | 38.535 | 106.430 | 24.1 | 56.099 | 164.626 | 126.8 |
| `height.liechtenstein` | 300 | 0.240 | 1.987 | 2,141.4 | 0.774 | 2.515 | 9,178.3 |
| `height.us-dach` | 1000 | 46.006 | 174.064 | 22.1 | 61.997 | 190.317 | 125.8 |
| `height.utrecht` | 300 | 0.270 | 1.745 | 2,072.5 | 0.864 | 2.376 | 8,924.2 |
| `route-auto-1000km.us-dach` | 500 | 83.886 | 255.853 | 10.6 | 119.013 | 351.273 | 56.9 |
| `route-auto-10km.liechtenstein` | 300 | 3.080 | 6.603 | 309.7 | 4.489 | 9.110 | 1,698.1 |
| `route-auto-10km.us-dach` | 500 | 11.862 | 45.875 | 73.0 | 15.892 | 58.720 | 406.9 |
| `route-auto-10km.utrecht` | 300 | 7.832 | 18.350 | 115.0 | 10.093 | 23.593 | 721.2 |
| `route-auto-200km.us-dach` | 500 | 45.875 | 170.918 | 18.6 | 58.458 | 252.183 | 95.3 |
| `route-auto-4000km.us-dach` | 500 | 346.030 | 591.921 | 2.9 | 433.062 | 910.164 | 15.8 |
| `route-foot-bike.liechtenstein` | 1000 | 2.036 | 8.192 | 401.8 | 3.367 | 9.470 | 2,161.5 |
| `route-foot-bike.us-dach` | 5000 | 14.516 | 618.660 | 15.1 | 42.205 | 782.238 | 80.7 |
| `route-foot-bike.utrecht` | 1000 | 5.472 | 19.792 | 154.2 | 7.373 | 23.396 | 938.3 |
| `upstream.liechtenstein` | 240 | 3.531 | 6.128 | 279.6 | 4.915 | 9.994 | 1,552.2 |
| `upstream.us-dach` | 19800 | 46.531 | 377.487 | 14.0 | 60.686 | 461.373 | 85.2 |
| `upstream.utrecht` | 13 | 1.565 | 11.731 | 403.3 | 2.818 | 15.073 | 2,155.1 |

The point counts sum the input shape lengths for each complete corpus cycle.
Encoded polylines contribute one point per latitude/longitude pair. The
corpora omit resampling. All three regional baselines use the pinned gzip
elevation inputs. The separate raw HGT comparison changes the input encoding
for both servers. [Raw HGT comparison](../oracle/README.md#usdach-height-throughput)

| Dataset | Points per corpus cycle | Points/s at 1 connection | Points/s at 8 connections |
| --- | ---: | ---: | ---: |
| Liechtenstein | 72,310 | 516,154 | 2,212,281 |
| US+DACH | 269,702 | 5,956 | 33,935 |
| Utrecht | 75,189 | 519,426 | 2,236,665 |

## Startup, resident memory and build

| Dataset | Startup through first `/status` | Process RSS after soak |
| --- | ---: | ---: |
| Liechtenstein | 1.172 s | 0.639 GiB |
| Utrecht | 0.241 s | 0.697 GiB |
| US+DACH | 0.369 s | 89.117 GiB |

Startup includes the container launch and polls `/status` every 0.5 seconds
using the existing filesystem cache. The memory column uses `VmRSS` from
`/proc/1/status` inside the container. The large US+DACH process RSS includes
repeated mappings of tile pages. A sample 4.623 seconds before the final RSS
reported 87.564 GiB of file RSS and 14.151 GiB of cgroup memory charges,
including 11.781 GiB for mapped file pages. The cgroup also recorded 7.804 GiB
of swap. [Memory sample](../bench/baseline/memory-near-end.json) ·
[Linux process accounting](https://docs.kernel.org/filesystems/proc.html) ·
[Linux cgroup memory accounting](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory)

US+DACH used the checksum-verified January 1, 2026 US and DACH extracts and
1,493 elevation tiles. The build took 9,620 seconds after input verification.
It produced an archive of 18,630 routing tiles occupying 24.974 GiB. The
five-second disk samples peaked at 76.875 GiB of intermediate tile files and
186.542 GiB of filesystem usage, an increase of 98.620 GiB over the pre-build
sample. [Build report](../bench/baseline/build.json)

## Settled edges

| Auto corpus | Requests | Routes traced | Median settled pairs | Min to max |
| --- | ---: | ---: | ---: | ---: |
| 200 km | 500 | 484 | 101,499.5 | 27,037 to 563,721 |
| 1,000 km | 500 | 493 | 176,270 | 49,880 to 674,265 |
| 4,000 km | 500 | 497 | 598,618 | 339,534 to 1,097,161 |

The trace covers all 1,474 successful routes in the three cohorts. The
remaining 26 requests returned HTTP 400 from Valhalla's route endpoint.
[Per-request report](../bench/baseline/us-dach/expansion.json)

Counts come from Valhalla's `/expansion` action on the same requests as the
timed auto replays. Each successful `/route` was replayed with
`action: "route"`, `dedupe: false` and `skip_opposites: false`. The median
uses distinct pairs of directed edge ID and search direction with status
`settled`. This counts forward and reverse settlements separately. The
raw report also gives the number of settlement events before deduplication.
The pinned protobuf and JSON traces agreed for the first three successful
routes in each distance cohort. Expansion ran separately from the timed
replays, with the oracle's default two workers. [Expansion API](https://github.com/valhalla/valhalla/blob/3.9.3/docs/docs/api/expansion.md)

## Reproduction

Use the pinned Zig toolchain and native Linux oracle image on a host with
the same CPU count, memory and storage configuration. Run the build and
timed replays with the host otherwise idle. Save each run in a new directory.

```sh
bun tools/corpus/generate.ts
zig build -Doptimize=ReleaseFast
oracle/build.sh liechtenstein
oracle/build.sh utrecht
oracle/fetch.sh us-dach
python3 oracle/baseline-build.py us-dach bench/results/baseline/build.json
oracle/baseline.sh liechtenstein bench/results/baseline/liechtenstein
oracle/baseline.sh utrecht bench/results/baseline/utrecht
oracle/baseline.sh us-dach bench/results/baseline/us-dach
```

The runner verifies the pinned build key and corpus checksums. It uses
closed-loop replay and a two-second warm-up at each connection count.
US+DACH normally runs one complete corpus cycle. The two smaller datasets
repeat whole cycles to reach at least 5,000 requests per replay. Each
measurement retains up to four replays and accepts the first consecutive
pair within 5% on p50. An `-accepted.json` file gives the pair when an earlier
replay missed the timing limit.

The main US+DACH run exhausted its attempts at one connection for elevation
and 10 km auto. Both complete original series are in the raw reports.
To reproduce the accepted pairs, give each workload a fresh oracle and
a longer warm-up covering its prior observed corpus cycle. Measure five
complete cycles after the warm-up.

```sh
oracle/baseline.sh us-dach bench/results/baseline/height-c1 \
  --corpus height.us-dach.tsv --connections 1 --minimum-requests 5000 --warmup 78s
oracle/baseline.sh us-dach bench/results/baseline/auto-10km-c1 \
  --corpus route-auto-10km.us-dach.tsv --connections 1 --minimum-requests 2500 --warmup 30s
```

The reruns used the same image, dataset and configuration hashes as the
main series. The accepted JSON files are under
[`us-dach/recovery`](../bench/baseline/us-dach/recovery).
[Benchmark runner details](../oracle/README.md#valhalla-baseline-on-the-benchmark-host)

For settled edges, serve the built US+DACH dataset and use the oracle's HTTP
address as `ORACLE_URL`. Repeat for the requests in the 200, 1,000 and 4,000 km
corpora. Record the HTTP status when a route fails. For each successful
route, count distinct settled pairs from the JSON trace. The first 200 km
request can be checked with the following commands.

```sh
request=$(head -n 1 bench/corpora/route-auto-200km.us-dach.tsv | cut -f2-)
curl --fail --silent --show-error --json "$request" "$ORACLE_URL/route" >/dev/null &&
  jq -c '. + {action:"route", format:"json", dedupe:false, skip_opposites:false,
    expansion_properties:["edge_status","edge_id","expansion_type"]}' <<< "$request" |
  curl --fail --silent --show-error --json @- "$ORACLE_URL/expansion" |
  jq '[.features[].properties | select(.edge_status == "s") |
    [.edge_id, .expansion_type]] | unique | length'
```
