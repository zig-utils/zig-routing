# Build pipeline pilot

Three paired ReleaseFast runs on the same Apple M3 Pro with four workers.
Each run built the pinned Luxembourg extract into a fresh work directory and
verified every section. All six bundles had identical section SHA-256 digests.
[Per-stage JSON and section digests](build-luxembourg.json)

| Median | Baseline | Indexed decode and compact checkpoints |
| --- | ---: | ---: |
| Whole build wall time | 10.261 s | 7.754 s |
| Tags | 3.993 s | 2.824 s |
| Node store | 1.724 s | 0.872 s |
| Edges | 3.320 s | 2.872 s |
| Tag-stage directory files | 120.92 MiB | 0.81 MiB |
| Retained allocated scratch | 327.86 MiB | 154.24 MiB |
| Process RSS high-water mark | 181.17 MiB | 179.58 MiB |

The whole build took 24.4% less time and retained 53.0% less allocated scratch.
Retained scratch is the allocated space in the completed work tree. The JSON
keeps every stage's artifact bytes, rows, rows per second, elapsed time and
cumulative process RSS high-water mark. The first consuming stage includes
opening and verifying the mapped PBF index.

The build reuses one PBF frame index per input. Tags and node collection
inflate blocks in a bounded worker pool and consume them in input order.
Edge generation decodes between its parallel construction batches. Set
`--pbf-buffer-bytes` or `zig_routing.build.pbf_buffer_bytes` to cap decoded
buffers at build time. The default is 512 MiB. A budget below one compressed
block's decoded size fails before that stage publishes a checkpoint.

Tag checkpoints encode occupied radix directory slots and their child IDs
as sequential varints. The live lookup caches the last successful branch
prefixes. Resuming from an older raw-directory checkpoint produced all
the same verified bundle bytes.

The continental profile and the planet run require the pinned inputs,
CCH stages and a 32 vCPU / 128 GB class host with enough scratch storage.
The planet wall-time and peak-scratch budgets remain open.
[Planet build issue](https://github.com/zig-utils/zig-routing/issues/108)
