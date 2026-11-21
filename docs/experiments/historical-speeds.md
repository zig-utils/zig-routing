# Learning historical speeds

`zr traffic learn-predicted BUNDLE TRACES.jsonl --threads 8` reads one
timestamped trace per line. Each point needs a numeric latitude and
longitude and an increasing Unix time in seconds.

```json
{"shape":[{"lat":52.090993,"lon":5.096991,"time":1767484800},{"lat":52.090970,"lon":5.096771,"time":1767484802}]}
```

The matcher attributes elapsed time to directed edge fractions using
recosted traversal times as weights. It drops the first and last matched
segments of each trace before aggregating. Segments that cross a five-minute
boundary contribute separately to each local time-of-week bucket. A trace
contributes at most one speed sample to any directed edge and bucket.

Buckets require at least three samples after outlier rejection.
`--minimum-samples` can raise that threshold. The mean of the
retained speeds is smoothed over neighboring supported buckets.
Free-flow and constrained speeds fill gaps, with road-class averages
used where the edge has no static traffic speeds.

The command writes the existing `traffic-pred.bin` format under the
bundle writer lock. The writer deduplicates the learned coefficients and
carries forward speeds and profiles on unaffected edges. The JSON report
contains aggregate counts, coverage, and the retained-sample fraction
for each road class. Trace identifiers, timestamps, and coordinates
stay in the input and temporary request memory.

The Gurka regression learns a known speed from timestamped geometry,
rejects an outlier and verifies that the first and last edges are absent
from the overlay. A synthetic weekly profile checks all 2,016 decoded
five-minute buckets against known speeds and enforces a 5% error limit.

## Utrecht throughput

Generate synthetic traces from the validated native
[trace-attributes replay](trace-attributes.md#same-tile-oracle).
Use a separate copy of the imported graph for each run.

```sh
python3 bench/traffic/prepare-history.py trace-attributes-results.jsonl aligned.jsonl
python3 bench/traffic/prepare-history.py trace-attributes-results.jsonl noisy.jsonl \
  --perturb-metres 1.5
time zr traffic learn-predicted BUNDLE aligned.jsonl --threads 8
time zr traffic learn-predicted BUNDLE noisy.jsonl --threads 8
```

Both corpora contain 1,024,088 points in 14,873 traces. The noisy
corpus adds independent seeded perturbations of up to 1.5 m per
coordinate axis. All traces in both corpora contribute to profiles.

| ReleaseFast corpus, eight workers | Wall time | Points/s | Profiles |
|---|---:|---:|---:|
| Geometry-aligned, median of three | 0.55 s | 1,861,978 | 54 |
| Noisy GPS, one run | 2.09 s | 489,994 | 60 |

The timed command includes opening the bundle, parsing traces, matching,
time attribution, outlier rejection, DCT and writing the overlay. These
runs used native arm64 macOS. The three geometry-aligned trials took
0.73, 0.52 and 0.55 seconds.

The endpoint matcher now uses Valhalla's trace defaults, including
zero minimum reachability. This avoids searching the graph for
route-style reachability before either edge walking or map snapping.
On the noisy corpus, the remaining cost concentrates in directed
transition expansion, endpoint correlation, and candidate-grid search.
[#257](https://github.com/zig-utils/zig-routing/issues/257) tracks the
one-million-point target for that workload.

## Exact matching improvements on noisy traces

The matcher reuses graph-derived candidate encounter lists for the same
grid window and resolves an edge walk's destination once an origin can
lead to a geometric match. Snap-bin scans rule out distant small
bounding circles by latitude before decoding their full centers. The
lookup caches hold graph data only.

Viterbi retains a bounded amount of the directed paths already used to
score its rows. A move whose nonnegative transition score cannot
improve the queue can be skipped for a single result. Distance expansion
uses compact keys for ordinary clock-bounded arrival lists and stops
offering full traversals that cannot improve a destination. It still
examines reachable fractional cuts on those arcs. The learning batch
shares a bounded table of compiled untimed prices across workers.

Six trials alternated the baseline at `e74fead` and the candidate on
native ARM64 macOS on the same Apple M3 Pro. Both ran the original
1,024,088-point corpora with eight workers. Each run started from a clean
copy of the indexed Utrecht bundle and timed the command through overlay
publication.

| Corpus | Baseline wall time | Candidate wall time | Baseline points/s | Candidate points/s |
| --- | ---: | ---: | ---: | ---: |
| Noisy GPS | 2.080 s | 1.390 s | 492,350 | 736,754 |
| Geometry-aligned | 0.445 s | 0.335 s | 2,301,321 | 3,056,979 |

Noisy wall time fell 33.2%. Median process CPU time fell from 14.925 s
to 9.960 s. Median maximum resident memory moved from 130.11 MiB to
132.30 MiB. The one-million-point gate requires 1.024 s and remains open.

Separate one-second CPU samples at 1 ms intervals recorded 393 and 243
top-of-stack samples in endpoint correlation before and after. Insertion
into the candidate encounter sets fell from 276 to 25 samples. The main
distance expansion loop had 503 and 565 samples. Counts identify hot
code within each run. The alternating trials measure total runtime.

```sh
zr traffic learn-predicted BUNDLE noisy.jsonl --threads 8 > report.json &
pid=$!
sample "$pid" 1 1 -file learn-predicted-sample.txt
wait "$pid"
```

Every report and overlay matched the corresponding baseline byte for
byte. All 14,873 noisy traces contributed, yielding 750,315 samples and
60 profiles. The ordered candidate probe matched all 156 measurements.
The directed auditor matched all 186 ranked state paths and all 120
stitched traces. A separate action replay reproduced all 360 primary and
ranked results from the earlier trace-attributes audit. The historical
accuracy and privacy tests remain in the full native suite.

[#259](https://github.com/zig-utils/zig-routing/issues/259) tracks
sharing exact transition bounds across origins of a destination column.
