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
these differences and exits 1.

## Directed path audit

The independent reference enumerates feasible path prefixes on the same
Valhalla tiles. It keeps the full predecessor chain and uses Valhalla's auto
costing to check edge access, simple turns and complex restrictions. It
prices the source and target cuts from the oracle's own correlations and
applies the same strict distance and elapsed-time bounds as Meili. After
every target has a feasible route, a prefix longer than all current winners
cannot improve a destination. No arrivals are merged by node or edge.

Audit source candidate 2 at rows 36 through 38, with zero-based indices.
These are the same measurements with an unlimited clock, a 15-second
measurement gap and a 2-second gap. The bounded cases allow less than
75 seconds and 10 seconds of travel, respectively.

```sh
printf '36\t2\n37\t2\n38\t2\n' > audit-columns.tsv
./trace-transitions-reference CONFIG.json transitions.tsv audit-columns.tsv > directed.tsv
python3 oracle/trace-transitions.py audit oracle.tsv native.tsv directed.tsv
```

| Clock gap | Feasible path prefixes examined | Native paths verified |
| --- | ---: | ---: |
| Unlimited | 12,513 | 9 / 9 |
| 15 seconds | 3,852 | 9 / 9 |
| 2 seconds | 0 | 9 / 9 unreachable |

The first target takes 55.888 seconds at 776.220 metres on the verified path,
compared with 66.688 seconds at 926.220 metres in stock Meili. Across the
27 audited pairs, the maximum absolute errors were `2.930e-5` metres,
`1.248e-6` seconds, `2.531e-7` for emission and `6.592e-6` for transition
score. The audit checks the directed path as well as the metrics and requires
coverage of every stock score difference. [Issue #252](https://github.com/zig-utils/zig-routing/issues/252).
