# zig-routing

A faithful port of the [Valhalla](https://github.com/valhalla/valhalla) routing engine to Zig, built
to be much faster, with no dependencies beyond the Zig standard library and the
[zig-utils](https://github.com/zig-utils) libraries.

> Status: planning complete, implementation tracked in issues. Nothing here routes yet.

## Goals

- **Faithful.** The same HTTP API, request and response JSON, error codes and costing options as
  Valhalla, so existing clients work unchanged.
- **Fast.** Exact search guided by potentials customised to each request's costs, a data-oriented
  graph format, one process with a thread per core, zero steady-state allocation.
- **Zero dependencies.** No C libraries, no Lua, no SQLite, no protobuf library.
- **Beyond routing.** Geocoding and search, vector map tiles and traffic as later phases.

## Where to look

| File | What it is |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | The plan: scoreboard, architecture, phases, verification, risks |
| [docs/design/engine-and-format.md](docs/design/engine-and-format.md) | Design study for the search engine, acceleration and graph format |
| [docs/upstream/valhalla-architecture.md](docs/upstream/valhalla-architecture.md) | Map of upstream Valhalla: modules, tile format, algorithms, build stages, API |
| [docs/upstream/valhalla-perf-issues.md](docs/upstream/valhalla-perf-issues.md) | Upstream's documented performance problems and published numbers |
| [docs/upstream/zig-libs-inventory.md](docs/upstream/zig-libs-inventory.md) | What the zig-utils libraries and Zig std already provide |
| [AGENTS.md](AGENTS.md) | Rules for contributors and coding agents, and how to pick an issue |
| [scripts/issues/](scripts/issues/) | The issue graph as data (outline, bodies, creation and sync scripts) |

## Build

Requires Zig `0.17.0-dev.1857` or newer.

```bash
zig build test
```

```bash
zig build run
```

## Command line

`zr --help` lists commands and shared flags. Use `zr COMMAND --help` for each command's options.
`zr --version` prints the source commit, Zig toolchain and enabled target CPU features.

`zr route '<json>'` dispatches a request in process. To select a different action and read
the request from a file, run `zr --config valhalla.json route --action height --file height.json`.
Successful responses go to stdout. Valhalla error bodies go to stderr with a failing exit code.

### Build a graph bundle

```bash
zr build extract.osm.pbf --output graph --work-dir work --threads 4
zr inspect --verify graph
```

The driver accepts one or more OSM PBF inputs and an optional HGT directory
with `--dem`. It writes stage timing, rows per second, output bytes and peak
RSS to `build-stats.json` in the work directory. The default work directory
is the output path with `.work` appended.

`--from` and `--to` select an inclusive range of stages in dependency order.
For example, stop after enhancement and resume from the elevation checkpoint
boundary:

```bash
zr build extract.osm.pbf --work-dir work --to enhance
zr build --work-dir work --from elevation --output graph
```

The stages run in this order:

```text
read tags node_store edges order assemble enhance elevation turns cold spatial validate finalize
```

Resume uses the completed checkpoints in the same work directory. The last
stage publishes the verified bundle atomically. A repeat can reuse an identical
published bundle, and an existing different bundle is preserved.

`zr inspect BUNDLE` reports a graph bundle's sections, counts and sizes. Add `--verify` to
check every payload checksum, `--edge ID` or `--node ID` to print a record, and `--json` for
machine-readable output.

## Configuration

`zr serve --config valhalla.json` reads Valhalla JSON settings. Use
`zr config check valhalla.json` to print the effective settings and the ignored keys. Startup
also lists ignored keys, with each unsupported subtree listed by its parent path.

Environment variables override file values. Use the `ZR_` prefix and uppercase key paths
joined by underscores, for example `ZR_SERVICE_LIMITS_SKADI_MAX_SHAPE=100000` or
`ZR_LOKI_ACTIONS=height,status`. Explicit `serve` flags take precedence over both sources.

`httpd.service.listen` accepts `tcp://*:PORT`, an IPv4 address, or `localhost` in the same
URI form. `timeout_seconds` sets the processing deadline (`-1` disables it), and
`drain_seconds` bounds draining on shutdown. The service uses `service_limits.skadi`,
`additional_data.elevation` and `loki.actions`.

`zig_routing.threads` defaults to one worker per CPU when set to zero.
`request_memory_bytes`, `max_header_bytes` and `max_body_bytes` set the corresponding
server limits. The schema includes `bundle_path` and `metric_cache_bytes` for the graph and metric cache.

In a build configuration, `zig_routing.build` accepts `inputs`, `dem_dir`,
`work_dir`, `bundle_path` and `threads`. Command-line values override configuration.

## Profiling

`zr bench --counters` records cycles, instructions, cache misses and branch misses for the Linux
load-generator threads after warm-up. Its JSON includes totals and counts per completed request.
On PMUs that expose the L1 data load miss event, `l1_data_load_misses` reports it separately.
When counters are unavailable, latency and throughput are still reported and
`client_hardware_counters` is `null`. `zig build bench-lz4` reports the same counters per
checksummed decompression iteration when the hardware supports them.

Profile a bench run with Linux `perf` or macOS `sample`. Build `zr` first, then set `URL` to the
server and `CORPUS` to the request corpus.

```bash
scripts/flamegraph.sh bench.svg -- zig-out/bin/zr bench "$URL" --corpus "$CORPUS" --duration 10s
```

To profile the service itself while the load generator runs separately, use its process ID:

```bash
scripts/flamegraph.sh serve.folded --pid "$PID" 10
```

Use an output path ending in `.svg` for an SVG or `.folded` for folded stacks. Linux must allow
user-space `perf` sampling of the process. On macOS, the command needs to run long enough for
`sample` to attach.

### Compiled costing

```bash
zig build bench-costing -Doptimize=ReleaseFast -- "$bundle" 100000
```

The benchmark runs 1,024 distinct option compilations against the bundle's
actual class table. It measures cache hits in batches of 64 and enforces the
optional median miss limit in nanoseconds. CI uses a 100 µs limit on Utrecht.

| Extract | Classes | Median compile | p95 compile |
| --- | ---: | ---: | ---: |
| Liechtenstein | 931 | 6.0 µs | 6.1 µs |
| Utrecht | 5,159 | 26.6 µs | 30.7 µs |
| Luxembourg 2026-01-01 | 16,153 | 81.2 µs | 90.5 µs |

These ReleaseFast timings were measured on an Apple M3 Pro. Cache storage is
reserved at startup. Equal compiled tables share a 128-bit key, and the
integer lower bounds account for declared cost and speed floors.

### HTTP echo benchmark

Build the client and the standalone loopback echo server in ReleaseFast:

```bash
zig build -Doptimize=ReleaseFast
zig build echo-server -Doptimize=ReleaseFast
zig-out/bin/echo-server "$PORT" "$WORKERS"
```

In another terminal, generate the request and run the benchmark. Use the same worker and
connection counts for comparative measurements.

```bash
mkdir -p bench/results
printf '/echo\t{"message":"hello"}\n' > bench/results/echo.tsv
zig-out/bin/zr bench "http://127.0.0.1:$PORT" --corpus bench/results/echo.tsv --connections "$WORKERS" --warmup 2s --duration 10s --label zig-routing-echo --commit "$(git rev-parse HEAD)" --out bench/results/echo.json
```

### OSM PBF inflation benchmark

Pass a fetched extract, worker count, and number of passes. The report gives
indexing time, block counts, inflate throughput, and peak RSS.

```bash
zig build bench-osm-pbf -Doptimize=ReleaseFast -- oracle/data/liechtenstein/extract.osm.pbf 4 100
```

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for the Valhalla attribution.
