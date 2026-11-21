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
