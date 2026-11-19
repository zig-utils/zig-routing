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

    const exe = b.addExecutable(.{
        .name = "zr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "routing", .module = lib_mod },
                .{ .name = "zig_cli", .module = zig_cli },
                .{ .name = "build_options", .module = version_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zr");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const help_test = b.addRunArtifact(exe);
    help_test.addArg("--help");
    for ([_][]const u8{ "serve", "build", "route", "bench", "diff", "inspect", "config", "dem", "import-valhalla" }) |name| {
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

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

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

    // Fuzz targets (test/fuzz.zig). `zig build test` replays their seeds; `zig build fuzz
    // --fuzz` fuzzes, ReleaseSafe by default so bounds and overflow checks stay on.
    const fuzz_filter = b.option([]const u8, "fuzz-target", "Fuzz one target: request, http, polyline, lz4, dem, protobuf, config, osm-pbf");
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
