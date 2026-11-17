# AGENTS.md

Guidance for coding agents (and people) working on zig-routing. Read this, then
[docs/PLAN.md](docs/PLAN.md), before touching code.

## What this project is

A faithful port of the Valhalla routing engine (C++, MIT) to Zig that must be measurably faster and
have zero external dependencies. Upstream reference version: **Valhalla 3.9.3**.

## How to pick work

Work is a dependency graph of GitHub issues, numbered in execution order.

1. Take the **lowest-numbered open issue labelled `ready`**. Skip `epic` issues (they are trackers)
   and `needs-human` issues unless the maintainer has supplied what the issue asks for.
2. Do exactly what the issue's Scope says. Its Acceptance criteria are the definition of done.
3. One issue per pull request. Reference the issue (`Closes #N`).
4. When an issue closes, a workflow flips its dependents from `blocked` to `ready`
   (`scripts/issues/sync-ready.ts`). Never start a `blocked` issue.
5. If an issue turns out to be wrong or too big, say so in a comment and split it; do not silently
   widen or narrow the scope.

## Non-negotiable rules

- **Zero external dependencies.** Zig std and the `zig-utils/zig-*` libraries only. No C libraries,
  no system libraries, no Lua, no SQLite, no vendored third-party code. Docker Valhalla is a
  test-time oracle only and is never linked or shipped.
- **One pinned Zig toolchain** (see `build.zig.zon`). Toolchain bumps are their own change.
- **Faithful semantics.** Endpoints, JSON shapes, option names, ranges, defaults and error codes
  match Valhalla. A file that ports an upstream file starts with `// Ported from <upstream path>`.
  Port the upstream tests along with the code.
- **Exact search.** No heuristic pruning that can change the answer. Parity is judged under
  Valhalla's own cost function (gates A to H in docs/PLAN.md).
- **On-disk structs** are `extern struct` with `packed struct(u32)` (or `u64`) members only, with
  comptime `@sizeOf` / `@offsetOf` assertions and a little-endian assertion. Never a bare
  `packed struct` wider than 64 bits or as an array element.
- **No steady-state allocation.** Request memory comes from the per-thread arena, reset after each
  request. Tests assert zero heap calls after warm-up.
- **No virtual dispatch in hot loops.** Costing is compiled to a POD and read by comptime-generic
  kernels. Cold checks are `noinline`.
- **Every loop that can run long checks the deadline.** No recursion in search code.
- **`std.Io` only through the IO shim.** Raw posix elsewhere.
- **Performance is tested, not hoped for.** If the issue has a budget, the benchmark proving it is
  part of the change. A tracked benchmark regressing more than 3% fails CI.
- **No private details in this public repository**: no hostnames, IPs, ports or internal paths.
- **Writing:** plain hyphens, no em-dashes. Conventional commit messages.

## Layout

```
src/geo        geometry kernel            (upstream midgard)
src/graph      native format and reader   (baldr)
src/costing    costing models             (sif)
src/snap       location correlation       (loki)
src/search     path algorithms            (thor)
src/accel      hierarchy and potentials   (new)
src/match      map matching               (meili)
src/narrative  maneuvers and instructions (odin)
src/api        request parsing, serializers (tyr)
src/elevation  DEM sampling               (skadi)
src/build      OSM to graph               (mjolnir)
src/server     HTTP service               (prime_server)
src/traffic, src/tiles, src/geocode       later phases
src/cli        the zr binary
packages/      new general-purpose pieces (protobuf, lz4, osm, ...) until extracted
test/          unit tests, ASCII-map (gurka-style) tests, fixtures, oracle harness
bench/         benchmarks and results
docs/          plan, design, upstream research
```

## Commands

```bash
zig build test
```

```bash
zig fmt --check .
```

`zr bench` and `zr diff` (Phase 0) are how performance and parity are proven; use them once they
exist.

## Reference material

- [docs/PLAN.md](docs/PLAN.md): scoreboard, architecture, phases, parity gates, experiments.
- [docs/design/engine-and-format.md](docs/design/engine-and-format.md): why the engine and format
  look the way they do, with the published results the design relies on.
- [docs/upstream/valhalla-architecture.md](docs/upstream/valhalla-architecture.md): upstream module
  map, exact tile bitfield layouts, algorithms, build stages, API and tests.
- [docs/upstream/valhalla-perf-issues.md](docs/upstream/valhalla-perf-issues.md): upstream's known
  performance problems, each with issue numbers. These are what we design out.
