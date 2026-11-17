I ran no `zig build` or `zig test`, so none of the "tests present" notes below mean the tests pass. Nothing was modified.

**Bottom line:** no zig-* library gives you a routing-engine foundation. Of the roughly 40 capabilities you listed, only CLI parsing, config loading, TLS, test and benchmark harnesses, XML tokenizing, regex, a thread pool and an embeddable JavaScript engine exist. The protobuf (for OSM PBF and the Valhalla API), HTTP server, geometry, spatial index, SQLite-free databases, Lua and tile encoding all have to be written new. Zig's own standard library covers a lot of the rest (details under Toolchain).

## 1. Library table

All 25 matches of the `zig-utils/zig-*` repositories. Src counts are `.zig` files and lines under `src/`. Dates are the last commit.

| Library | Purpose (from README) | Zig target (`build.zig.zon` / CI / pantry) | Dependencies | Src | Maturity |
|---|---|---|---|---|---|
| zig-benchmarks | mitata-style benchmark framework | min 0.15.0; CI uses goto-bus-stop/setup-zig@v2 | none | 19 / 4,943 | tests/ + 27 tests; v0.1.2; 2026-07-27 |
| zig-bump | bumps the version in build.zig.zon | min 0.17.0-dev.56; CI same | none | 9 / 2,966 | 27 tests; v0.1.6; 2026-07-27 |
| zig-camera | Raspberry Pi 5 capture and recording | min 0.15.2; `.zigversion` 0.15.2; `.zigdevversion` 0.18.0-dev.567 | **system C libs**: zlib, fdk-aac, alsa, x264, x265, libjpeg, sdl2, libcamera | 203 / 50,198 | 671 tests; no tags; 2026-10-24 |
| zig-changelog | changelog from conventional commits | min 0.15.0 | none | 6 / 905 | 3 tests; v0.1.2; 2026-07-27 |
| zig-cli | type-safe CLI framework, prompts, config parsers | min 0.17.0-dev; CI `zig@0.17.0-dev` | none (link_libc) | 33 / 6,510 | 23 tests; v0.1.3; 2026-07-28 |
| zig-config | multi-source config loader (bunfig-style) | min 0.15.1; last commit "build with Zig 0.17" | none (link_libc) | 8 / 2,027 | 34 tests; v0.1.3; 2026-10-06 |
| zig-crosswind | Tailwind CSS alternative (`.name = .zig_css`) | min 0.17.0-dev.1441; pantry.lock pins 0.17.0-dev.2056 | **hard-coded relative path** `../zig-config/src/zig-config.zig` in build.zig | 62 / 19,810 | 133 tests; v0.1.3; 2026-09-08 |
| zig-error-handling | Rust-style `Result(T,E)` | min 0.15.0 | none | 1 / 655 | 22 tests; v0.1.2; 2026-07-27 |
| zig-faker | fake data generator, 55 locales | min 0.15.0; CI 0.17.0-dev.56 | none | 88 / 9,676 | 61 tests; v0.1.2; 2026-07-27 |
| zig-garmin | Garmin GFDI Bluetooth protocol | min 0.16.0; CI and deps.yaml 0.17.0-dev.1441 | none | 4 / 421 | 6 tests; v0.1.2; 2026-10-25 |
| zig-gc | precise mark-sweep garbage collector (for zig-js) | min 0.17.0-dev; CI 0.17.0-dev.956 | none | 2 / 5,874 | 66 tests; no tags; 2026-09-05 |
| zig-injection | SQL injection / XSS detector (libinjection port) | min 0.17.0-dev.1441; CI same | none | 9 / 12,287 | 9 tests; v0.1.2; 2026-09-02 |
| zig-js | JavaScript engine with a JavaScriptCore-style C API | **min 0.18.0-dev**; CI 0.18.0-dev.146 | URL+hash on zig-regex and zig-gc (codeload tarballs) | 98 / 462,146 | 2,875 tests; README claims test262 53,175/53,175; v0.0.1; 2026-11-13 |
| zig-js-ecosystem | downstream CI orchestration for zig-js | n/a | n/a | no src | not a library |
| zig-js-worktrees | scratch zig-js worktrees and build logs | n/a | n/a | no git repo | not a library |
| zig-oura | Oura Ring Bluetooth protocol | min 0.17.0-dev.1441 | none | 7 / 1,067 | 15 tests; v0.1.2; 2026-10-26 |
| zig-regex | regex engine (Thompson NFA, backtracking, DFA, Unicode) | min 0.17.0-dev.1441; CI same | none (deps.yaml lists pcre2 for benchmarks only) | 34 / 31,189 | 209 tests; v0.2.1; 2026-11-11 |
| zig-search-engine | Typesense client | min 0.16.0-dev | none (link_libc) | 4 / 656 | 4 tests; no tags; 2026-07-27 |
| zig-sftp | SFTP v3 protocol codec and session | min 0.17.0-dev.1441 | git+URL+hash on zig-cli | 3 / 815 | 24 tests; v0.1.1; 2026-09-02 |
| zig-starter | project template | min 0.15.1 | none | 4 / 398 | 10 tests; v0.1.2; 2026-07-27 |
| zig-test-framework | Jest-style test runner | no `minimum_zig_version`; CI `zig@0.17.0-dev` | none (link_libc) | 26 / 10,047 | 119 tests; v0.2.2; 2026-07-27 |
| zig-tls | pure-Zig TLS 1.2/1.3 client and server | **min 0.17.0-dev.1476**; CI same; pantry.lock 0.17.0-dev.1509 | none (link_libc; optional AES-GCM assembly) | 55 / 22,880 | 109 tests, fuzz/, bench/; v0.1.2; 2026-08-13 |
| zig-utils | website for the zig-utils org (Bun / ts-cloud) | n/a | n/a | 0 .zig files | not a library |
| zig-waf | web application firewall (ModSecurity/Coraza semantics) | min 0.17.0-dev.1441; pantry.lock 0.17.0-dev.1456 | pantry-registry URL+hash on zig-injection, zig-regex, zig-xml; **C libs**: LMDB, zstd, libpq (static .a from `pantry/`), sqlite3 (system, sqlite-test only), libxml2 | 65 / 43,622 | 533 tests; v0.0.3; "pre-alpha"; 2026-09-02 |
| zig-xml | lenient pull XML/HTML tokenizer | min 0.17.0-dev.1441 | none | 3 / 2,637 | 11 tests; v0.1.0; 2026-07-27 |

## 2. Public API, from the root files I opened

- **zig-cli** (`src/root.zig`): `Command`, `Context`, `Action` (typed builder), `Option`, `Argument`, `Parser`, `Help`, `BaseCommand`, `config` (has `TomlParser.zig`, `Json5Parser.zig`, `JsoncParser.zig`, `ConfigLoader.zig`), `prompt` (Text/Select/Confirm/Spinner/ProgressBar/Table and similar). The module is exported as `zig_cli`.
- **zig-config** (`src/zig-config.zig`): `loadConfig`, `tryLoadConfig`, `deepMerge`, `cloneJsonValue`, `jsonValuesEqual`, `FileLoader`, `EnvProcessor`, `LoadOptions`, `MergeStrategy`, `ConfigResult`. Formats are JSON plus env vars, built on `std.json`. Module `zig_config`.
- **zig-tls** (`src/root.zig`): `client(input, output, config.Client)`, `server(...)`, `Connection`, `Cipher`, `Record`, `config`, `alpn`, `session_ticket`, `nonblock`, `Ktls` / `ktls_linux`, `ecdsa_p256`, `rsa`. Module `tls`.
- **zig-xml** (`src/root.zig`): `Reader` (pull: call `next()`), `Event`, `Element`, `Attribute`, `decode`, `decodeInto`, `entity`. Module `xml`.
- **zig-regex** (`src/root.zig`): `Regex`, `Match`, `SharedRegex`, `RegexCache`, `Builder`, `unicode` / `UnicodeProperty`, `named_captures`, `c_api`. Module `regex`.
- **zig-test-framework** (`src/lib.zig`; `root.zig` is a stub): `expect`, `describe` / `it`, `beforeEach` / `afterAll`, `mock`, `snapshot`, `coverage`, `parallel`, `reporter`, `timeout`. Module `zig_test_framework`.
- **zig-benchmarks** (`src/bench.zig`): `Benchmark`, `BenchmarkSuite`, `BenchmarkOptions`, `Stats`, `Formatter`, `bench`, `benchWithOptions`, `AsyncBenchmark`. Other modules: comparison, export, flamegraph, memory_profiler, ci.
- **zig-error-handling** (`src/result.zig`): `Result(T,E)`, `ok`, `err`, `fromErrorUnion`, `collect`, `partition`, `sequence`, `transpose`.
- **zig-gc**: `Heap`, plus relocation types.
- **zig-js**: `Context.create` / `createWith(.{enable_gc, enable_jit, heap_limit_bytes})`, `evaluate`, `evaluateProtected`, `createHostValue`, `callProtected`, `Value`, `Object`, `NativeFn`, `Worker`, `c_api`, `jit`. Module `js`.
- **zig-search-engine**: `Schema`, `Typesense`, plus `http` (a minimal HTTP/1.1 client over libc TCP using `Connection: close`).
- **zig-sftp**: `Session`, `protocol`, `resolveWithin`.
- **zig-crosswind**: CSS generator modules, plus `core/thread_pool.zig` and `core/memory_pool.zig`, which are internal and not re-exported from the root.
- **zig-waf**: about 40 WAF modules. The useful ones are `src/sqlite.zig` (`Conn`, binds, `Rows`, `migrate`, over libsqlite3), `src/zstd.zig` (one-shot zstd over libzstd) and `persistent_lmdb.zig`. All three wrap C libraries.
- **zig-camera, zig-garmin, zig-oura, zig-injection, zig-faker, zig-bump, zig-changelog, zig-starter**: domain-specific, nothing a router needs.

## 3. Capability checklist

| Capability | Result |
|---|---|
| HTTP server | **MISSING.** `zig-waf/src/daemon.zig` is a 6-line stub that prints "proxy startup is not enabled". `zig-test-framework/src/ui_server.zig` is stubbed ("std.net was removed in Zig 0.16"). The only listener is the example `zig-tls/examples/tls_server.zig`. No kqueue/io_uring/epoll code in any lib. The match in `zig-test-framework/src/watch.zig` is a file watcher. |
| HTTP client | Partial: `zig-search-engine/src/http.zig` (plain TCP, `Connection: close`). |
| TLS | **YES:** zig-tls (client and server, 1.2/1.3). |
| JSON | **MISSING as a library.** Several libs use `std.json` internally. zig-config only does config merging on top of it. |
| Protocol Buffers | **MISSING.** Varint hits are in `zig-js/src/wasm/decode.zig` and `zig-oura` (ad hoc). zig-garmin's README says "full protobuf services" are not implemented. No `.proto` code generation anywhere. |
| zlib / deflate / gzip | **MISSING in pure Zig.** `zig-camera/src/home/zlib_stream.zig` is an extern binding to system libz. |
| LZ4 | **MISSING.** |
| zstd | C binding only: `zig-waf/src/zstd.zig` (libzstd.a). |
| tar | **MISSING.** |
| mmap helpers | **MISSING** as a reusable lib. Only internal uses in zig-camera and zig-js (JIT). |
| SQLite / embedded DB | C binding only: `zig-waf/src/sqlite.zig` (system sqlite3) and `persistent_lmdb.zig` (LMDB). No SpatiaLite. |
| XML | **YES:** zig-xml (lenient pull tokenizer, not validating). |
| Geometry (haversine, polyline, R-tree, projections, GeoTIFF) | **MISSING.** The only "latitude" hits are EXIF GPS tags in zig-camera. |
| CLI parsing | **YES:** zig-cli. |
| Config loading | **YES:** zig-config (JSON / env) and `zig-cli/src/config` (TOML, JSON5, JSONC). No YAML. |
| Logging | **MISSING** (no lib; `std.log` is there). |
| Thread pool | Partial: `zig-crosswind/src/core/thread_pool.zig` (work-stealing), not exported. |
| Lock-free queues | **MISSING** as a library. Internal atomics in zig-gc and zig-js only. |
| Arena / pool allocators | Partial: `zig-crosswind/src/core/memory_pool.zig`, not exported. |
| Priority queue / heap | **MISSING.** |
| Date / time / tzdb | Not exposed. `zig-js/src/iana_offsets.zig` holds per-zone UTC-offset transitions generated from tzdata (up to 2101), and `iana_zones.zig` holds the zone IDs. Both are internal to zig-js and not exported from its root. `zig-test-framework/src/time.zig` is minor. |
| i18n / Unicode | Partial: `zig-regex/src/unicode.zig` (properties, case folding). zig-js has CLDR, normalization and IDNA data (`unicode_normalize.zig`, `cldr_*.zig`), all internal. |
| Test harness | **YES:** zig-test-framework. |
| Benchmark harness | **YES:** zig-benchmarks. |
| Lua | **MISSING.** |
| JavaScript engine | **zig-js is embeddable** as `@import("js")` through `b.addModule("js")` (`zig-js/build.zig:157`). It depends on zig-regex and zig-gc and needs **Zig 0.18.0-dev**. |
| MVT vector tiles | **MISSING.** |
| PNG | Partial: zig-camera `home/png_decoder.zig` and `raster_encoder.zig`. These need system zlib and come from a Linux/Raspberry Pi-oriented library. |
| Integer compression (varint, delta, Elias-Fano) | **MISSING.** |
| Bitsets / hashing | **MISSING** as libraries. |

## 4. What Zig std already covers

On the 0.17-dev toolchain, std provides `std.http` (Server and Client), `std.Io` (Kqueue, Uring, Threaded),
`std.json`, `std.tar`, `std.zip`, `std.leb128`, `std.compress.flate` (compress and decompress), zstd
(decompress), `std.priority_queue`, `std.bit_set`, `std.hash`, `std.tz` and `std.log`.

## 5. Dependency convention

Sibling libraries are consumed as URL + hash pins on a commit
(`git+https://github.com/zig-utils/<lib>.git#<sha>`), wired in `build.zig` with
`b.dependency("<name>", .{ .target = target, .optimize = optimize }).module("<module>")`. Module names:
`tls`, `zig_cli`, `xml`, `regex`, `zig_config`. Path dependencies are used only inside one repository.
