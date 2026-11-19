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
| Linux x86-64 baseline | AMD EPYC 9V74 | 8.072 | 7.016 |
| Linux x86-64-v3 | AMD EPYC 9V74 | 6.742 | 3.813 |
| Linux AArch64 baseline | Neoverse-N2 | 9.075 | 4.330 |
| macOS x86-64 baseline | Intel Core i7-8700B | 9.732 | 19.982 |
| macOS x86-64-v3 | Intel Core i7-8700B | 8.741 | 5.344 |
| macOS AArch64 baseline | Apple M1 (virtual) | 4.689 | 3.047 |
| macOS AArch64 baseline | Apple M3 Pro | 8.762 | 4.520 |

On the paired AMD EPYC run, v3 took 16.47% less time per projection segment and 45.65% less time per encoded point. The paired Intel run measured decreases of 10.18% and 73.26%. Output digests matched for each pair. These timings compare the release builds. Dispatch costs need their own measurement. [Linux x86-64 run](https://github.com/zig-utils/zig-routing/actions/runs/44630457768/job/135935371445), [macOS x86-64 run](https://github.com/zig-utils/zig-routing/actions/runs/44630457768/job/135935371711)

The CCH weight and triangle passes and predicted-speed DCT are tracked in [#93](https://github.com/zig-utils/zig-routing/issues/93) and [#199](https://github.com/zig-utils/zig-routing/issues/199).
