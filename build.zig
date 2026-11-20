const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reused zig-utils libraries (the only dependencies this project may have).
    const dep_args = .{ .target = target, .optimize = optimize };
    const zig_cli = b.dependency("zig_cli", dep_args).module("zig_cli");
    const zig_config = b.dependency("zig_config", dep_args).module("zig_config");
    const tls = b.dependency("tls", dep_args).module("tls");
    const xml = b.dependency("xml", dep_args).module("xml");
    const perf_counters = b.dependency("zig_benchmarks", dep_args).module("perf_counters");

    // Packages written for this project, each extractable into its own zig-* repo later.
    const lz4 = b.addModule("lz4", .{ .root_source_file = b.path("packages/lz4/lz4.zig"), .target = target, .optimize = optimize });
    const protobuf = b.addModule("protobuf", .{ .root_source_file = b.path("packages/protobuf/root.zig"), .target = target, .optimize = optimize });

    const dictionary_types = b.createModule(.{ .root_source_file = b.path("src/narrative/dictionary_types.zig") });
    const locale_compiler = b.addExecutable(.{
        .name = "compile-locales",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/locale_compile.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const compile_locales = b.addRunArtifact(locale_compiler);
    compile_locales.addDirectoryArg(b.path("locales"));
    const locale_data = b.createModule(.{
        .root_source_file = compile_locales.addOutputFileArg("locale_data.zig"),
        .imports = &.{.{ .name = "dictionary_types", .module = dictionary_types }},
    });
    const locale_catalog = b.createModule(.{ .root_source_file = compile_locales.addOutputFileArg("locale_catalog.zig") });

    // The library: every routing module hangs off src/root.zig.
    const lib_mod = b.addModule("routing", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig_cli", .module = zig_cli },
            .{ .name = "zig_config", .module = zig_config },
            .{ .name = "tls", .module = tls },
            .{ .name = "xml", .module = xml },
            .{ .name = "lz4", .module = lz4 },
            .{ .name = "protobuf", .module = protobuf },
            .{ .name = "perf_counters", .module = perf_counters },
            .{ .name = "dictionary_types", .module = dictionary_types },
            .{ .name = "locale_data", .module = locale_data },
            .{ .name = "locale_catalog", .module = locale_catalog },
        },
    });

    const version_options = b.addOptions();
    const commit = b.option([]const u8, "commit", "Source commit for release builds") orelse switch (b.runFallible(
        &.{ "git", "rev-parse", "HEAD" },
        .{ .cwd = .{ .path = b.root.joinString(b.allocator, ".") catch @panic("OOM") }, .stderr_behavior = .ignore },
    )) {
        .success => |value| std.mem.trim(u8, value, "\r\n"),
        else => "unknown",
    };
    version_options.addOption([]const u8, "commit", commit);

    const exe = cpuExecutable(b, "zr", b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "routing", .module = lib_mod },
            .{ .name = "zig_cli", .module = zig_cli },
            .{ .name = "build_options", .module = version_options.createModule() },
        },
    }));
    // Keep the symbol table and DWARF in Linux release binaries. Compress
    // the debug sections so additional actions fit the executable budget.
    if (target.result.os.tag == .linux and optimize != .debug) exe.compress_debug_sections = .zlib;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zr");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const help_test = b.addRunArtifact(exe);
    help_test.addArg("--help");
    for ([_][]const u8{ "serve", "build", "route", "bench", "diff", "inspect", "tags", "config", "dem", "import-valhalla", "parity", "bundle-manifest", "fetch-bundle" }) |name| {
        help_test.expectStdOutMatch(name);
    }
    test_step.dependOn(&help_test.step);

    const unknown_command = b.addRunArtifact(exe);
    unknown_command.addArg("not-a-command");
    unknown_command.expectExitCode(2);
    unknown_command.expectStdErrMatch("Unknown command 'not-a-command'");
    test_step.dependOn(&unknown_command.step);

    const unknown_flag = b.addRunArtifact(exe);
    unknown_flag.addArgs(&.{ "serve", "--json", "--unknown" });
    unknown_flag.expectExitCode(2);
    unknown_flag.expectStdErrMatch("\"kind\":\"UnknownOption\"");
    test_step.dependOn(&unknown_flag.step);

    const version_test = b.addRunArtifact(exe);
    version_test.addArg("--version");
    version_test.expectStdOutMatch("commit ");
    version_test.expectStdOutMatch("features ");
    test_step.dependOn(&version_test.step);

    const route_test = b.addRunArtifact(exe);
    route_test.addArgs(&.{ "route", "{bad json" });
    route_test.expectExitCode(1);
    route_test.expectStdErrMatch("\"error_code\":100");
    test_step.dependOn(&route_test.step);

    const route_files = b.addWriteFiles();
    const height_config = route_files.add("valhalla.json",
        \\{"additional_data":{"elevation":""},"loki":{"actions":["height"]}}
    );
    const height_request = route_files.add("height.json",
        \\{"shape":[{"lat":0,"lon":0}]}
    );
    const height_test = b.addRunArtifact(exe);
    height_test.addArg("--config");
    height_test.addFileArg(height_config);
    height_test.addArgs(&.{ "route", "--action", "height", "--file" });
    height_test.addFileArg(height_request);
    height_test.expectStdOutMatch("\"height\":[null]");
    test_step.dependOn(&height_test.step);

    lib_mod.addImport("zig_test_framework", b.dependency("zig_test_framework", dep_args).module("zig_test_framework"));
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const analysis_mod = b.createModule(.{
        .root_source_file = b.path("test/geocode_analysis.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    });
    const run_analysis_tests = b.addRunArtifact(b.addTest(.{ .root_module = analysis_mod }));
    test_step.dependOn(&run_analysis_tests.step);
    b.step("test-geocode-analysis", "Check the English and German analysis corpora").dependOn(&run_analysis_tests.step);
    const bench_analysis = b.addExecutable(.{ .name = "bench-geocode-analysis", .root_module = analysis_mod });
    const run_bench_analysis = b.addRunArtifact(bench_analysis);
    b.step("bench-geocode-analysis", "Check warm geocoding text analysis throughput on one core").dependOn(&run_bench_analysis.step);

    const bench_geocode_index = b.addExecutable(.{ .name = "bench-geocode-index", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_geocode_index.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_geocode_index = b.addRunArtifact(bench_geocode_index);
    run_bench_geocode_index.addPassthruArgs();
    b.step("bench-geocode-index", "Check warm prefix lookup and geocoder index size").dependOn(&run_bench_geocode_index.step);

    const narrative_tests = b.addTest(.{
        .name = "test-narrative",
        .root_module = lib_mod,
        .filters = &.{"narrative."},
    });
    b.step("test-narrative", "Run the narrative snapshot suite").dependOn(&b.addRunArtifact(narrative_tests).step);

    const fixture_io = b.createModule(.{
        .root_source_file = b.path("src/infra/io.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    const fixture_converter = b.addExecutable(.{
        .name = "narrative-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/narrative_fixtures.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "io", .module = fixture_io }},
        }),
    });
    const refresh_narrative = b.addRunArtifact(fixture_converter);
    refresh_narrative.addPassthruArgs();
    b.step("narrative-fixtures", "Check or refresh the pinned narrative fixtures").dependOn(&refresh_narrative.step);
    const fixture_scanner_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("scripts/narrative_cpp.zig"),
        .target = b.graph.host,
    }) });
    test_step.dependOn(&b.addRunArtifact(fixture_scanner_tests).step);

    const graph_imports: []const std.Build.Module.Import = &.{.{ .name = "routing", .module = lib_mod }};
    const graph_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/graph_reader.zig"),
        .target = target,
        .optimize = optimize,
        .imports = graph_imports,
    }) });
    test_step.dependOn(&b.addRunArtifact(graph_tests).step);
    const graph_fixture = b.addExecutable(.{
        .name = "graph-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/graph_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = graph_imports,
        }),
    });
    const graph_fixture_dir = b.addRunArtifact(graph_fixture).addOutputDirectoryArg2("graph-fixture", .{});
    const graph_inspect = b.addRunArtifact(exe);
    graph_inspect.addArgs(&.{ "inspect", "--verify", "--json", "--edge", "0", "--node", "1" });
    graph_inspect.addDirectoryArg2(graph_fixture_dir.path(b, "bundle"), .{});
    graph_inspect.expectStdOutMatch("\"verified\":true");
    graph_inspect.expectStdOutMatch("\"file\":\"edges.bin\",\"count\":2");
    graph_inspect.expectStdOutMatch("\"file\":\"classes.bin\",\"count\":2");
    graph_inspect.expectStdOutMatch("\"file\":\"transit_departures.bin\",\"count\":5,\"record_size\":44,\"bytes\":65756");
    graph_inspect.expectStdOutMatch("\"file\":\"transit_occurrences.bin\",\"count\":9,\"record_size\":8,\"bytes\":65608");
    graph_inspect.expectStdOutMatch("\"placement\":\"hot\",\"resident_bytes\":");
    graph_inspect.expectStdOutMatch("\"placement\":\"warm\",\"resident_bytes\":");
    graph_inspect.expectStdOutMatch("\"placement\":\"cold\",\"resident_bytes\":");
    graph_inspect.expectStdOutMatch("\"edge\":{\"id\":0,\"head\":1,\"opposing\":1");
    graph_inspect.expectStdOutMatch("\"speeds\":{\"speed\":140");
    graph_inspect.expectStdOutMatch("\"node\":{\"id\":1,\"first_edge\":1,\"degree\":1");
    test_step.dependOn(&graph_inspect.step);

    const gurka_imports: []const std.Build.Module.Import = &.{
        .{ .name = "routing", .module = lib_mod },
        .{ .name = "protobuf", .module = protobuf },
    };
    const gurka_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/gurka/examples.zig"),
        .target = target,
        .optimize = optimize,
        .imports = gurka_imports,
    }) });
    test_step.dependOn(&b.addRunArtifact(gurka_tests).step);
    const gurka_emit = b.addExecutable(.{
        .name = "gurka-emit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/gurka/emit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = gurka_imports,
        }),
    });
    const emit_pbf = b.addRunArtifact(gurka_emit);
    emit_pbf.addPassthruArgs();
    b.step("gurka-pbf", "Emit the Gurka intersection fixture as OSM PBF").dependOn(&emit_pbf.step);

    const tag_fixture = b.addRunArtifact(gurka_emit).addOutputFileArg("intersection.osm.pbf");
    const tag_dump = b.addRunArtifact(exe);
    tag_dump.addArgs(&.{ "tags", "dump" });
    tag_dump.addFileArg(tag_fixture);
    tag_dump.expectStdOutMatch("{\"kind\":\"way\",\"id\":9001,\"eligible\":true,\"kept\":true,");
    tag_dump.expectStdOutMatch("\"name\":\"Main Street\"");
    test_step.dependOn(&tag_dump.step);

    // Stage timings (ReleaseFast): zig build perf
    const perf = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/perf_height.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    b.step("perf", "Stage timings for bulk requests").dependOn(&b.addRunArtifact(perf).step);

    const echo_server = b.addExecutable(.{
        .name = "echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_http_echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "routing", .module = lib_mod }},
        }),
    });
    const install_echo = b.addInstallArtifact(echo_server, .{});
    b.step("echo-server", "Install the standalone HTTP benchmark fixture").dependOn(&install_echo.step);

    for ([_]*std.Build.Module{ lz4, protobuf }) |pkg| test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pkg })).step);

    // Package benchmarks (always ReleaseFast).
    const bench_lz4 = b.addExecutable(.{ .name = "bench-lz4", .root_module = b.createModule(.{
        .root_source_file = b.path("packages/lz4/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lz4", .module = b.createModule(.{ .root_source_file = b.path("packages/lz4/lz4.zig"), .target = target, .optimize = .ReleaseFast }) },
            .{ .name = "perf_counters", .module = perf_counters },
        },
    }) });
    const run_bench_lz4 = b.addRunArtifact(bench_lz4);
    run_bench_lz4.addPassthruArgs();
    b.step("bench-lz4", "LZ4 throughput").dependOn(&run_bench_lz4.step);

    const bench_osm_pbf = b.addExecutable(.{ .name = "bench-osm-pbf", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_osm_pbf.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_osm_pbf = b.addRunArtifact(bench_osm_pbf);
    run_bench_osm_pbf.addPassthruArgs();
    b.step("bench-osm-pbf", "OSM PBF index and inflate throughput").dependOn(&run_bench_osm_pbf.step);

    const check_osm_pbf = b.addExecutable(.{ .name = "check-osm-pbf", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_osm_pbf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_osm_pbf = b.addRunArtifact(check_osm_pbf);
    run_check_osm_pbf.addPassthruArgs();
    b.step("check-osm-pbf", "Report OSM PBF primitive counts and tag checksums").dependOn(&run_check_osm_pbf.step);

    const check_postcodes = b.addExecutable(.{ .name = "check-geocode-postcodes", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_geocode_postcodes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_postcodes = b.addRunArtifact(check_postcodes);
    run_check_postcodes.addPassthruArgs();
    b.step("check-geocode-postcodes", "Check postcode lookup against source polygon centroids").dependOn(&run_check_postcodes.step);

    const bench_node_store = b.addExecutable(.{ .name = "bench-node-store", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_node_store.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_node_store = b.addRunArtifact(bench_node_store);
    run_bench_node_store.addPassthruArgs();
    b.step("bench-node-store", "Verify node locations and measure store size, lookups and peak RSS").dependOn(&run_bench_node_store.step);

    const check_edges = b.addExecutable(.{ .name = "check-edges", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_edges.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_edges = b.addRunArtifact(check_edges);
    run_check_edges.addPassthruArgs();
    b.step("check-edges", "Report counts from the ways-to-edges stage").dependOn(&run_check_edges.step);

    const check_assembly = b.addExecutable(.{ .name = "check-assembly", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_assembly.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_assembly = b.addRunArtifact(check_assembly);
    run_check_assembly.addPassthruArgs();
    b.step("check-assembly", "Build and validate topology from a PBF and time warm bundle opens").dependOn(&run_check_assembly.step);

    const check_snap = b.addExecutable(.{ .name = "check-snap", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_snap.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_snap = b.addRunArtifact(check_snap);
    run_check_snap.addPassthruArgs();
    b.step("check-snap", "Report correlation candidates and native snap times for a corpus").dependOn(&run_check_snap.step);

    const bench_costing = b.addExecutable(.{ .name = "bench-costing", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_costing.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_costing = b.addRunArtifact(bench_costing);
    run_bench_costing.addPassthruArgs();
    b.step("bench-costing", "Measure compile cache hits and misses over a graph bundle").dependOn(&run_bench_costing.step);

    const bench_search = b.addExecutable(.{ .name = "bench-search", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_search.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "routing", .module = lib_mod }, .{ .name = "perf_counters", .module = perf_counters } },
    }) });
    const run_bench_search = b.addRunArtifact(bench_search);
    run_bench_search.addPassthruArgs();
    b.step("bench-search", "Measure edge-based Dijkstra throughput and counters on a graph bundle").dependOn(&run_bench_search.step);

    const bench_isochrone = b.addExecutable(.{ .name = "bench-isochrone", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_isochrone.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_isochrone = b.addRunArtifact(bench_isochrone);
    run_bench_isochrone.addPassthruArgs();
    b.step("bench-isochrone", "Measure isochrone expansion and write arrival grids").dependOn(&run_bench_isochrone.step);

    const bench_candidates = b.addExecutable(.{ .name = "bench-candidates", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_candidates.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_candidates = b.addRunArtifact(bench_candidates);
    run_bench_candidates.addPassthruArgs();
    b.step("bench-candidates", "Measure Meili candidate search and write correlations").dependOn(&run_bench_candidates.step);

    const bench_gtfs = b.addExecutable(.{ .name = "bench-gtfs", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_gtfs.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_gtfs = b.addRunArtifact(bench_gtfs);
    run_bench_gtfs.addPassthruArgs();
    b.step("bench-gtfs", "Count feed rows and measure parallel GTFS stop-time parsing").dependOn(&run_bench_gtfs.step);

    const bench_edge_keys = b.addExecutable(.{ .name = "bench-edge-keys", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_edge_keys.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_edge_keys = b.addRunArtifact(bench_edge_keys);
    run_bench_edge_keys.addPassthruArgs();
    b.step("bench-edge-keys", "Verify stable edge-key round trips and time warm lookups").dependOn(&run_bench_edge_keys.step);

    const bench_live_traffic = b.addExecutable(.{ .name = "bench-live-traffic", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_live_traffic.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_live_traffic = b.addRunArtifact(bench_live_traffic);
    run_bench_live_traffic.addPassthruArgs();
    b.step("bench-live-traffic", "Time live speed reads and stress the shared traffic overlay").dependOn(&run_bench_live_traffic.step);

    const bench_traffic_feed = b.addExecutable(.{ .name = "bench-traffic-feed", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_traffic_feed.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_traffic_feed = b.addRunArtifact(bench_traffic_feed);
    run_bench_traffic_feed.addPassthruArgs();
    b.step("bench-traffic-feed", "Apply and verify a large distinct-key CSV traffic batch").dependOn(&run_bench_traffic_feed.step);

    const bench_predicted_speed = b.addExecutable(.{ .name = "bench-predicted-speed", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_predicted_speed.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_predicted_speed = b.addRunArtifact(bench_predicted_speed);
    run_bench_predicted_speed.addPassthruArgs();
    b.step("bench-predicted-speed", "Measure dependent warm SIMD predicted-speed lookups").dependOn(&run_bench_predicted_speed.step);

    const bench_mvt = b.addExecutable(.{ .name = "bench-mvt", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_mvt.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_mvt = b.addRunArtifact(bench_mvt);
    b.step("bench-mvt", "Measure warm MVT encoding and allocation counts").dependOn(&run_bench_mvt.step);

    const bench_exclusions = b.addExecutable(.{ .name = "bench-exclusions", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_exclusions.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_exclusions = b.addRunArtifact(bench_exclusions);
    run_bench_exclusions.addPassthruArgs();
    b.step("bench-exclusions", "Check the request budget for a large avoid polygon").dependOn(&run_bench_exclusions.step);

    const bench_partition = b.addExecutable(.{ .name = "bench-partition", .root_module = b.createModule(.{
        .root_source_file = b.path("test/bench_partition.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_bench_partition = b.addRunArtifact(bench_partition);
    run_bench_partition.addPassthruArgs();
    b.step("bench-partition", "Report nested-dissection separator sizes, balance and time").dependOn(&run_bench_partition.step);

    const bench_cpu = cpuExecutable(b, "bench-cpu", b.createModule(.{
        .root_source_file = b.path("test/bench_cpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }));
    b.step("bench-cpu", "Time snap projection and polyline encoding").dependOn(&b.addRunArtifact(bench_cpu).step);

    const motor_costing_parity = b.addExecutable(.{
        .name = "motor-costing-parity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/motor_costing_parity.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "routing", .module = lib_mod }},
        }),
    });
    const run_motor_costing = b.addRunArtifact(motor_costing_parity);
    run_motor_costing.addPassthruArgs();
    b.step("motor-costing-parity", "Compare motor costing calls with the Valhalla oracle").dependOn(&run_motor_costing.step);

    const transit_costing_parity = b.addExecutable(.{
        .name = "transit-costing-parity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/transit_costing_parity.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "routing", .module = lib_mod }},
        }),
    });
    const run_transit_costing = b.addRunArtifact(transit_costing_parity);
    run_transit_costing.addPassthruArgs();
    b.step("transit-costing-parity", "Compare transit costing calls with the Valhalla oracle").dependOn(&run_transit_costing.step);

    const check_tripleg = b.addExecutable(.{ .name = "check-tripleg", .root_module = b.createModule(.{
        .root_source_file = b.path("test/check_tripleg.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "routing", .module = lib_mod }},
    }) });
    const run_check_tripleg = b.addRunArtifact(check_tripleg);
    run_check_tripleg.addPassthruArgs();
    b.step("check-tripleg", "Dump native trip legs for a route corpus").dependOn(&run_check_tripleg.step);

    // Fuzz targets (test/fuzz.zig). `zig build test` replays their seeds; `zig build fuzz
    // --fuzz` fuzzes, ReleaseSafe by default so bounds and overflow checks stay on.
    const fuzz_filter = b.option([]const u8, "fuzz-target", "Fuzz one target: request, http, polyline, lz4, dem, protobuf, config, osm-pbf, osm-primitives, osm-dense, node-store, graph-bundle, live-traffic, traffic-feed, predicted-speed, mvt, geocode-bundle, geocode-address, geocode-analysis, geocode-index, build-checkpoint, valhalla-tile, costing-reference, motor-costing, range-manifest, http-range, usage-directory, speed-config, motor-tags, admin-index, timezone-geojson, timezone-rules, datetime");
    const fuzz_opt: @TypeOf(optimize) = .ReleaseSafe;
    const seed_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "routing", .module = lib_mod },
            .{ .name = "lz4", .module = lz4 },
            .{ .name = "protobuf", .module = protobuf },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(seed_tests).step);
    const fuzz_lz4 = b.createModule(.{ .root_source_file = b.path("packages/lz4/lz4.zig"), .target = target, .optimize = fuzz_opt });
    const fuzz_protobuf = b.createModule(.{ .root_source_file = b.path("packages/protobuf/root.zig"), .target = target, .optimize = fuzz_opt });
    const fuzz_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = fuzz_opt,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig_cli", .module = b.dependency("zig_cli", .{ .target = target, .optimize = fuzz_opt }).module("zig_cli") },
            .{ .name = "zig_config", .module = b.dependency("zig_config", .{ .target = target, .optimize = fuzz_opt }).module("zig_config") },
            .{ .name = "tls", .module = b.dependency("tls", .{ .target = target, .optimize = fuzz_opt }).module("tls") },
            .{ .name = "xml", .module = b.dependency("xml", .{ .target = target, .optimize = fuzz_opt }).module("xml") },
            .{ .name = "lz4", .module = fuzz_lz4 },
            .{ .name = "protobuf", .module = fuzz_protobuf },
            .{ .name = "dictionary_types", .module = dictionary_types },
            .{ .name = "locale_data", .module = locale_data },
            .{ .name = "locale_catalog", .module = locale_catalog },
            .{ .name = "perf_counters", .module = perf_counters },
        },
    });
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = fuzz_opt,
            .imports = &.{
                .{ .name = "routing", .module = fuzz_lib },
                .{ .name = "lz4", .module = fuzz_lz4 },
                .{ .name = "protobuf", .module = fuzz_protobuf },
            },
        }),
        .filters = if (fuzz_filter) |f| b.dupeStrings(&.{b.fmt("fuzz {s}", .{f})}) else &.{},
    });
    b.step("fuzz", "Fuzz the input parsers (add --fuzz; -Dfuzz-target=NAME for one)").dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Every reused library compiles and is callable on the pinned toolchain.
    const smoke_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/deps_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_cli", .module = zig_cli },
            .{ .name = "zig_config", .module = zig_config },
            .{ .name = "tls", .module = tls },
            .{ .name = "xml", .module = xml },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(smoke_tests).step);
}

fn cpuExecutable(b: *std.Build, name: []const u8, program: *std.Build.Module) *std.Build.Step.Compile {
    const target = program.resolved_target.?;
    const guarded = target.result.cpu.model == &std.Target.x86.cpu.x86_64_v3 and
        target.query.cpu_features_add.isEmpty() and target.query.cpu_features_sub.isEmpty();
    const root = if (guarded) blk: {
        var baseline = target.query;
        baseline.cpu_model = .baseline;
        break :blk b.createModule(.{
            .root_source_file = b.path("src/cli/cpu_entry.zig"),
            .target = b.resolveTargetQuery(baseline),
            .optimize = program.optimize,
            .imports = &.{.{ .name = "program", .module = program }},
        });
    } else program;
    const exe = b.addExecutable(.{ .name = name, .root_module = root });
    // The pinned Zig Mach-O linker does not support LTO.
    if (program.optimize == std.builtin.OptimizeMode.fast and target.result.os.tag == .linux) exe.lto = .full;
    return exe;
}
