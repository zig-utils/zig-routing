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
