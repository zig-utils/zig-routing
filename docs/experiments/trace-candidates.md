# Trace candidate search

The matcher queries the routing spatial index with each measurement's
effective radius, the larger of search radius and GPS accuracy capped at
the configured maximum. It keeps both allowed directions of each
interior match and one candidate per snapped node. The request-local
cache limits bytes for decoded shapes and their geometry metadata.
When a single-level Valhalla import includes source hashes, the matcher
uses the bin order and hashes to reconstruct the pinned Linux oracle's
two Meili set passes. It derives fine cells from the shared spatial
index and shares the same request cache budget for their ordered entries.

The test corpus contains 156 distinct Utrecht measurements from
`test/mapmatch.cc` in Valhalla 3.9.3. Use the [Utrecht extract](../../oracle/datasets.tsv)
and the [matching single-level build and import](isochrone.md#reproduction).
Extract the measurements from the pinned source.

```sh
python3 oracle/trace-candidates.py extract VALHALLA_SOURCE/test/mapmatch.cc measurements.tsv
```

Run both probes on the same Linux platform. Compile the reference inside
the pinned Valhalla image.

```sh
g++ -std=c++20 -O2 -I/usr/local/include/valhalla/third_party \
  oracle/trace-candidates-reference.cc -o trace-candidates-reference -lvalhalla \
  -lprotobuf-lite -lprime_server -lz -l:libcurl.so.4 -l:liblz4.so.1 \
  -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
./trace-candidates-reference CONFIG.json measurements.tsv oracle.tsv > oracle-times.tsv
zig build bench-candidates -Doptimize=ReleaseFast -- BUNDLE measurements.tsv native.tsv > native-times.tsv
python3 oracle/trace-candidates.py compare measurements.tsv oracle.tsv native.tsv
```

Each probe warms the full set, then reports the measurement index, query
time in nanoseconds and candidate count. The comparison uses both the
node and directed edge IDs. Reimport with the current `zr import-valhalla`
to include the source hashes and preserve the pinned tile's local ordering.

Seven paired trials on one vCPU of an ARM64 Linux VM on an Apple M3 Pro
gave a median per-trial p50 of 3.417 microseconds for native and 5.333
microseconds for Valhalla. The legacy native path measured 3.833
microseconds on the same graph without source hashes. Trial order rotated
and compilation and fuzzing had finished before measurements began.

All 156 measurements agree on the ordered directed candidates and
snapped nodes. All 1,307 paired directed candidates agree on distance
within 1 mm. At 52.0911, 5.09806, both engines retain incident edges
28948 and 28951 for node 10501. [Issue #248](https://github.com/zig-utils/zig-routing/issues/248).
