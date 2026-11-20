# Trace candidate search

The matcher queries the routing spatial index with each measurement's
effective radius, the larger of search radius and GPS accuracy capped at
the configured maximum. It keeps both allowed directions of each
interior match and one candidate per snapped node. The request-local
cache limits bytes for decoded shapes and their geometry metadata.

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
node and directed edge IDs. The input graph must preserve the pinned
tile's local ordering.

Five paired trials on an ARM64 Linux VM on an Apple M3 Pro gave a median
per-trial p50 of 4.292 microseconds for native and 6.084 microseconds for
Valhalla. The trial order alternated.

All 156 measurements agree on interior-edge and snapped-node identities.
All 1,115 paired directed candidates agree on distance within 1 mm.
The directed-edge sets agree on 84 measurements. At 52.0911, 5.09806, for
example, both versions return node 10501. Valhalla retains incident
edges 28948 and 28951, and the native graph retains edge 28949.
Exact representative-edge parity remains open. [Issue #248](https://github.com/zig-utils/zig-routing/issues/248).
