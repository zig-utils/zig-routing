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

## Toolchain

The pin is **Zig `0.17.0-dev.1857+3c46da14d`**: `minimum_zig_version` in `build.zig.zon`, `deps.yaml`
for pantry, and the CI workflow all name it, and CI fails if they disagree. Install it with pantry
(`pantry install` in the repo) or from a ziglang.org mirror that still serves that dev build.

Changes in this dev std that bite ported code and memory of older Zig:

- `std.time.Timer`, `std.time.nanoTimestamp` and `std.fs.cwd()` are gone; clocks and files take an
  `Io`. Use the IO shim (`src/infra/io.zig`) instead of reaching for them.
- The `**` array repetition operator is gone: write `var a: [100]u64 = @splat(0);`.
- `std.ArrayList(T){}` no longer initialises: use `.empty`.
- `std.meta.Int` is gone: use the `@Int(.unsigned, bits)` builtin.
- `b.args` is gone in build scripts: use `run.addPassthruArgs()`.
- Dependencies are fetched into `./zig-pkg/` (gitignored), so format-check named paths, not `.`.

## Commands

```bash
zig build test
```

CI runs the suite a second time with the Gurka test bundles built in nested-dissection order.
Tests that depend on the order ask for it explicitly; the rest follow `-Dtest-order`.

```bash
zig build test -Dtest-order=nested_dissection
```

```bash
zig fmt --check build.zig build.zig.zon src test packages
```

```bash
zig build -Doptimize=ReleaseFast
```

The binary budget in [bench/budgets/binary.json](bench/budgets/binary.json) covers the installed
Linux x86-64 baseline ReleaseFast executable, including its symbols. CI builds the candidate and
base with the pinned toolchain, then reports the file size and distinct emitted search and costing
types. Run the same check with:

```bash
zig build -Dtarget=x86_64-linux-gnu -Dcpu=baseline -Doptimize=ReleaseFast
python3 scripts/size-budget.py zig-out/bin/zr --base /path/to/base/bin/zr
```

When a feature needs a higher limit, include the before and after counts, binary sizes, and reason
in the issue and change the relevant budget entry in the same commit. Check the reported type names
for accidental instantiations first.

Before pushing from macOS, cross-compile for Linux: production runs there, and OS-specific code
(epoll, glibc symbols) otherwise only fails in CI.

```bash
zig build test -Dtarget=x86_64-linux-gnu
```

That command ends by reporting that the host cannot run Linux binaries; that is expected. Any
`error:` line before it is a real failure.

`zr bench` and `zr diff` (Phase 0) are how performance and parity are proven. `zr bench URL
--corpus FILE --out result.json` replays a corpus (closed loop, or open loop with `--rate`) and
writes percentiles, throughput and errors with the hardware, dataset and commit; `zr bench
--compare a.json b.json` prints the deltas. Quote numbers only from runs where both servers sit on
the same machine class and platform (an emulated amd64 oracle against a native `zr` is not a
comparison). `zr diff A_URL B_URL --corpus FILE` sends every request to both servers and scores
the pairs against the parity gates (status, JSON schema and enums, error codes, exact `/height`
values, route legs, length, time and shape overlap). It exits 1 when a gate is below its threshold,
and `--worst DIR` writes the worst cases as one-line corpora that reproduce them. New gates are
entries in `default_scorers` in `src/cli/diff.zig`.

The corpora live in `bench/corpora/`, written by `bun tools/corpus/generate.ts` (seeded, about 15 s
with the upstream fetch). Only `manifest.json` is committed. It lists each corpus's dataset,
counts per endpoint and costing, and SHA-256, and `--check` proves a regeneration is
byte-identical (CI runs it). After changing a generator, refresh the oracle-rejected candidates
with `--validate DATASET=URL` for every dataset with a running oracle, and commit the manifest.

`zig build perf` times /height by stage (parse, sample, serialize per point) on the bulk corpus
and fails when a stage exceeds `bench/budgets/height.json`. To capture a flamegraph while
`zr bench` drives a running server, pass its process ID:

```bash
scripts/flamegraph.sh out.svg --pid "$PID" 10
```

Use `zr bench --counters` for client hardware counters when Linux exposes them.
`docs/perf/` keeps the reference profiles.

Every parser of untrusted input gets a fuzz target in `test/fuzz.zig` (one byte slice per run,
seeds included; `zig build test` replays the seeds). Malformed input must return an error, never
panic or read out of bounds.

```bash
scripts/fuzz.sh -s 60 lz4
```

That runs a target for 60 seconds in a ReleaseSafe build (omit the names to run all of them).
The nightly `Fuzz` workflow runs each target for 10 minutes and uploads crashing inputs. A crasher
goes into `test/fuzz/crashers/` with a `replayStream` test in `test/fuzz/regressions.zig`,
committed with the fix. `zig build` exits 0 even when a fuzz test crashes, so use the script,
which detects the saved input, rather than reading the exit status of
`zig build fuzz --fuzz=N` yourself.

## Reference material

- [docs/PLAN.md](docs/PLAN.md): scoreboard, architecture, phases, parity gates, experiments.
- [docs/design/engine-and-format.md](docs/design/engine-and-format.md): why the engine and format
  look the way they do, with the published results the design relies on.
- [docs/upstream/valhalla-architecture.md](docs/upstream/valhalla-architecture.md): upstream module
  map, exact tile bitfield layouts, algorithms, build stages, API and tests.
- [docs/upstream/valhalla-perf-issues.md](docs/upstream/valhalla-perf-issues.md): upstream's known
  performance problems, each with issue numbers. These are what we design out.
