# Trace transition validation

Use the pinned Utrecht measurements and the matching single-level import
from [trace candidate search](trace-candidates.md). Reimport with the current
`zr import-valhalla` so Meili sees the source bin order.

```sh
python3 oracle/trace-transitions.py extract measurements.tsv transitions.tsv
g++ -std=c++20 -O2 -I/usr/local/include/valhalla/third_party \
  oracle/trace-transitions-reference.cc -o trace-transitions-reference -lvalhalla \
  -lprotobuf-lite -lprime_server -lz -l:libcurl.so.4 -l:liblz4.so.1 \
  -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
./trace-transitions-reference CONFIG.json transitions.tsv > oracle.tsv
zig build check-trace-transitions -Doptimize=ReleaseFast -- BUNDLE transitions.tsv > native.tsv
python3 oracle/trace-transitions.py compare oracle.tsv native.tsv
```

Compile and run the reference in the Valhalla 3.9.3 Linux image. Each row
contains two latitude and longitude pairs, a search radius in metres and
the elapsed time in seconds. The generator uses 35 metres and runs each
adjacent measurement pair without a clock limit and with 15 and 2 second
clock gaps. Both probes parse the default auto costing options.

The comparator checks emissions, distance, elapsed time, turn cost and
transition score. It reports the directed paths for pairs that differ. On
the 465 Utrecht columns, both engines reached the same 4,104 of 7,149
candidate pairs. Costs agreed within `1e-4` on 7,131 of 7,149 pairs. The
maximum transition-score error on those pairs was `3.075e-5`.

All 18 other pairs come from the origin at 52.0797372, 5.1293068 and
destination at 52.0792731, 5.1343818 with no clock limit or a 15 second
clock gap. At node 27822, Valhalla settles the arrival on edge 77666,
which cannot turn onto 77702. Its per-node label prevents consideration
of the arrival on 77710, which can make that turn. The native expansion
retains that directed state and reaches the first of the nine destinations
in 776.220 metres instead of 926.220 metres. The pinned costing permits
every move on the shorter route. The full stock-oracle comparison reports
these differences. [Exact-route validation follow-up](https://github.com/zig-utils/zig-routing/issues/252).
