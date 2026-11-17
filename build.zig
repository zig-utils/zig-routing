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

    // The library: every routing module hangs off src/root.zig.
    const lib_mod = b.addModule("routing", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_cli", .module = zig_cli },
            .{ .name = "zig_config", .module = zig_config },
            .{ .name = "tls", .module = tls },
            .{ .name = "xml", .module = xml },
        },
    });

    // The one binary: `zr serve | build | route | bench | diff | inspect`.
    const exe = b.addExecutable(.{
        .name = "zr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "routing", .module = lib_mod },
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

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

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
