//! The x86-64-v3 executable enters here using baseline instructions.
const std = @import("std");
const builtin = @import("builtin");
const program = @import("program");

// x86-64 psABI levels v2 and v3. The standard library's native detection
// also checks that the OS saves the AVX register state before enabling AVX.
const required = std.Target.x86.featureSet(&.{
    .cx16,  .sahf,  .popcnt, .sse3, .ssse3, .sse4_1, .sse4_2,
    .avx,   .avx2,  .bmi,    .bmi2, .f16c,  .fma,    .lzcnt,
    .movbe, .xsave,
});

fn supportsV3() bool {
    // A complete OS and ABI query needs only the processor feature probe.
    const native = std.zig.system.resolveTargetQuery(.failing, .{
        .cpu_arch = .x86_64,
        .os_tag = builtin.os.tag,
        .abi = builtin.abi,
        .cpu_model = .native,
    }) catch return false;
    return native.cpu.features.isSuperSetOf(required);
}

pub fn main(init: std.process.Init) !u8 {
    if (!supportsV3()) {
        std.debug.print("This executable requires x86-64-v3 CPU and OS support. Use the baseline x86-64 build.\n", .{});
        return 1;
    }
    return @call(.never_inline, program.main, .{init});
}
