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

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for the Valhalla attribution.
