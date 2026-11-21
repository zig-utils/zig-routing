# Trace attributes

[#182](https://github.com/zig-utils/zig-routing/issues/182) exposes
`/trace_attributes` through the HTTP service and `zr route --action
trace_attributes`. It builds a TripLeg from the recosted directed cuts
and applies the strict attributes controller before loading optional edge
data. A cut after a discontinuity starts at a new shape index. Match-point
discontinuity flags follow the neighboring state IDs, while segment
discontinuities govern the edge cuts.

The protobuf response is a Valhalla `Api` containing `Trip`. The JSON
response uses the same attribute fields with both `json` and `osrm`
format options. Native edge IDs are the dense IDs in the loaded bundle.
An imported tile without elevation supplies the Valhalla unavailable
grade value. The worker retains separate storage for matching caches and
transition scratch across requests, independently of response buffers
waiting for the socket.

## Same-tile oracle

Import the single-level Utrecht tile from the
[isochrone replay](isochrone.md#reproduction). Run both services on that
tile, using the pinned Valhalla 3.9.3 oracle and a native import. The
[measurement corpus](viterbi.md#matched-utrecht-replay) supplies 120
traces with three clock settings. Each service uses the same
`turn_penalty_factor` of 200 for the replay.

```sh
python3 oracle/viterbi.py extract measurements.tsv traces.tsv
python3 oracle/trace-attributes.py prepare traces.tsv trace-attributes.tsv
python3 oracle/trace-attributes.py replay "$ORACLE_URL" "$NATIVE_URL" \
  trace-attributes.tsv trace-attributes-results.jsonl
```

The comparison records raw HTTP results for every primary path. It
compares default, strict include and strict exclude schemas on the paths
that agree. Source local IDs are recovered from the Valhalla GraphIds by
shifting 25 bits. The import of this single tile preserves source edge order.

117 primary paths agree, covering 1,226 directed edges. The matching
edges have the same scalar attributes after mapping their IDs. All
351 default, include and exclude comparisons pass schema and status.
With nine additional requests covering validation, OSRM and timestamp
handling, `zr diff` passes all 360 Gate H status and schema checks and
all seven error checks.
The three primary differences are traces 0, 28 and 29, which also appear
among the stock differences in the [route stitching comparison](trace-routes.md).
The replay retains those responses. The first alternate on trace 1
also agrees in directed edges, confidence and raw score. Higher alternate
ranks and action-level candidate admission are tracked in
[#256](https://github.com/zig-utils/zig-routing/issues/256).

A protobuf replay with only `matched.distance_from_trace_point`
produces six filtered points and two leg endpoint correlations on both
services. All six distances agree to six decimal places. The upstream
HTTP server identifies this protobuf response as JSON. The native
server sends `application/x-protobuf`.

## Ranked paths

[#256](https://github.com/zig-utils/zig-routing/issues/256) preserves the
selected path's incoming edge through a stationary transition. A cached
Viterbi row may carry an incoming edge from another candidate sequence.
Using that edge to stitch a stationary point could insert an unrelated
zero-length cut and fail path formation. The stitcher uses the traversed
edges, checks for duplicate directed sequences before recosting, and
admits an alternate only after its path can be priced. A discontinuous
primary can still be returned. A discontinuous candidate ends alternate
enumeration.

The 120-trace replay requests up to four paths with both `alternates` and
`best_paths`. Both spellings agree within each service, with warning 103
on successful deprecated requests. Three 156-point traces exceed the
same alternate shape limit and return error 153. The native action
preserves the single-path primary, including its score, on all 117
eligible traces. It returns 189 ranked paths, up from 155. Stock returns
125 and fails 15 requests in `cut_segments` while forming alternates.

The independent directed probe reproduces the edges, raw score and
confidence of 185 native ranks within one printed unit (0.001). All
four remaining ranks are on trace 30, where native and stock agree.
The transition from measurement 1 to 2 is 1,996 m in both
audits. Stock and native use edges 35875 and 35880, while the independent
enumerator reaches the same junction through 35873, 35876 and 36265.
Both branches are 123 m. The directed probe's first equal-distance
arrival has a turn sum of 467.928 versus 507.270 for stock on that
transition, accounting for the 13.114 raw score difference.

| Zero-based traces | Evidence |
| --- | --- |
| 2, 10, 15, 26, 82 and repeated clock variants | Stationary edge aliases previously broke native recost. Trace 2 inserted a `[1, 1]` cut on 28947 after reaching the node on 28936. The alias now resolves on 28936 and the duplicate route is rejected before recost. |
| 1, 41 | Rank 2 follows the same 18 directed edges. The audited and stock candidates at column 3 have emissions of 3.830 and 23.477 and split the route at different cuts. Their raw scores are 357.781 and 361.470. |
| 13, 53 and 33, 73 | The stock and audited cuts agree at rank 1. The audited candidates at columns 3 and 1 respectively have lower emissions. Raw scores are 122.213 versus 139.839 and 280.625 versus 337.440. |
| 29 | The directed route through the repeated node yields 709.247. Stock's 740.275 route is also present as native rank 2. |
| 20, 26, 82, 86 | The directed probe also finds the native alternatives beyond the stock list or between its ranks. For trace 86, stock's score 41.128 shifts to rank 2 behind the admitted 39.170 path. |

Use the same graph, config and 120-trace inputs as above. Compile the
probe with the [pinned Viterbi recipe](viterbi.md#reproduction).

```sh
python3 oracle/trace-attributes.py replay-ranks "$ORACLE_URL" "$NATIVE_URL" \
  trace-attributes.tsv action-ranks.jsonl
./viterbi-reference CONFIG.json traces.tsv --stock-ranks > stock-ranks.tsv
./viterbi-reference CONFIG.json traces.tsv --action-ranks > directed-ranks.tsv
python3 oracle/trace-attributes.py compare-rank-audit action-ranks.jsonl directed-ranks.tsv
```

The JSON lines keep every rank's directed edges and scores from each
request spelling, plus the single-path control. The TSV reports cuts
and per-column candidate IDs, emission scores, transition lengths
and turn sums. The stock probe reports the exception when OfflineMatch
cannot form paths. The directed probe enumerates ranked states with the
pinned cost implementation and the [directed auditor](trace-transitions.md#directed-path-audit).

The final build passes the original 351 filter and schema comparisons
and all 360 Gate H status and schema checks. All 100,000 requests in the
repeated-request check succeed. The worker uses 7,136 KiB after warm-up
and 6,416 KiB after the last batch. The warmed allocator assertions
also pass.

## Repeated requests

Run a ReleaseFast native service with one worker. Put
`/trace_attributes`, a tab and this request in `repeated-trace.tsv`.

```json
{"shape":[{"lat":52.090993,"lon":5.096991},{"lat":52.09097,"lon":5.096771}],"costing":"auto","shape_match":"map_snap","id":"case2"}
```

Warm the connection and matcher with 2,000 successful requests, then
sample the service process RSS after every 20,000 calls.

```sh
zr bench "$NATIVE_URL" --corpus repeated-trace.tsv --connections 1 \
  --requests 2000 --warmup 0s --out warm.json
for batch in 1 2 3 4 5; do
  zr bench "$NATIVE_URL" --corpus repeated-trace.tsv --connections 1 \
    --requests 20000 --warmup 0s --out "batch-$batch.json"
  ps -o rss= -p "$NATIVE_PID"
done
```

| Requests after warm-up | RSS (KiB) |
|---:|---:|
| 0 | 7,216 |
| 20,000 | 7,216 |
| 40,000 | 7,216 |
| 60,000 | 7,216 |
| 80,000 | 7,216 |
| 100,000 | 7,216 |

All 100,000 calls succeeded. The Gurka tests also assert zero backing
allocator calls when the same filtered request runs on a warm worker.

## Linux executable budget

The x86-64 baseline ReleaseFast executable is 13,893,552 bytes,
up 2,349,448 bytes from 11,544,104. Five static search instantiations
serve auto/bus/taxi, truck, motorcycle/scooter, pedestrian and bicycle.
The count of emitted costing kernels increases from two to five because
bicycle, pedestrian and truck costing now run in the service. Auto and
motorcycle costing inline. The byte cap remains 19,500,000.
