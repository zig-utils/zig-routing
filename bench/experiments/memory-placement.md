# Graph warm-up startup pilot

Linux arm64 VM with 6 vCPUs on an Apple M3 Pro, Zig
`0.17.0-dev.1857+3c46da14d` in ReleaseFast. The pinned Luxembourg graph had
187,650 nodes and 475,336 directed edges. The service exercised its existing
`/height` endpoint against the Utrecht packed DEM. The binary, config, bundle
and DEM were on VM-local storage. [Pinned Luxembourg fixture](../../oracle/README.md)

| Interval | Samples | Median | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Process launch to first HTTP 200 | 128 | 9.78 ms | 98.20 ms | 308.36 ms |
| Process launch to listener readiness | 128 | 9.19 ms | 97.10 ms | 304.93 ms |
| First height request | 128 | 0.53 ms | 6.24 ms | 7.10 ms |
| Subsequent height requests | 512 | 0.20 ms | 1.94 ms | 7.38 ms |

For each sample, request eviction of the bundle's file cache with
`POSIX_FADV_DONTNEED` and start a fresh service with two HTTP workers. Set
`zig_routing.bundle_path` to the graph, `additional_data.elevation` to the
packed DEM and `zig_routing.mlock_hot` to true. Set the process memlock
limit to zero to exercise rejected locks. Time from process launch, wait
for the JSON listener event, then POST `{"shape":[{"lat":52.09,"lon":5.12}]}`
to `/height`. Record the first response and four repeats, each on its own
connection. Require HTTP 200 and a numeric height on every request.

```sh
zig build -Doptimize=ReleaseFast
zr --config CONFIG --json serve --port 0 --threads 2
zr --json inspect --verify BUNDLE
```

The first shared-storage pilot had a 1.47 s startup p99. In the final
implementation, the listener binds and publishes readiness before the
warm-up worker starts. The table measures that implementation on local
storage. The production first-request latency budget still requires the
route service and production-shaped corpus. The height measurements only
exercise HTTP startup while graph warm-up is enabled.
[#104](https://github.com/zig-utils/zig-routing/issues/104)

`zr inspect` reports the placement and resident bytes for each section.
On Linux the count uses the current process's page table. On macOS it uses
`mincore` residency. Both counts clip the final page to the file length.
[Linux pagemap documentation](https://docs.kernel.org/admin-guide/mm/pagemap.html)
[Apple mincore documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mincore.2.html)
