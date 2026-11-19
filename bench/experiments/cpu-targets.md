# CPU release profiles

Build and test a profile with the pinned Zig toolchain.

| Target | CPU option | ReleaseFast linker |
| --- | --- | --- |
| `x86_64-linux-gnu` | `baseline` or `x86_64_v3` | Full LTO |
| `aarch64-linux-gnu` | `baseline` | Full LTO |
| `x86_64-macos` | `baseline` or `x86_64_v3` | Zig Mach-O linker |
| `aarch64-macos` | `baseline` | Zig Mach-O linker |

```sh
zig build test -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3 -Doptimize=ReleaseFast
zig build bench-cpu -Dtarget=x86_64-linux-gnu -Dcpu=baseline -Doptimize=ReleaseFast
zig build bench-cpu -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3 -Doptimize=ReleaseFast
```

The pinned Zig toolchain requires LLD for LTO and rejects LLD for Mach-O. macOS LTO remains open in [#110](https://github.com/zig-utils/zig-routing/issues/110).

The benchmark runs the production closest-segment projection and precision-6 polyline encoder over the same 64 seeded shapes. It covers shapes with 3, 9, 33 and 65 vertices, discards two warm-up batches and reports the median of nine batches of 4,000 repetitions. CI compares the two x86-64 builds on the same runner and checks their output digests. AArch64 results report the cost on their own hardware.

| Target | Host processor | Snap projection (ns/segment) | Polyline encode (ns/point) |
| --- | --- | ---: | ---: |
| macOS AArch64 baseline | Apple M3 Pro | 8.762 | 4.520 |

The CCH weight and triangle passes and predicted-speed DCT are tracked in [#93](https://github.com/zig-utils/zig-routing/issues/93) and [#199](https://github.com/zig-utils/zig-routing/issues/199).
