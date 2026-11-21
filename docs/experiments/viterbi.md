# Meili Viterbi replay

[#179](https://github.com/zig-utils/zig-routing/issues/179) adds lazy Viterbi
and top-k state sequences. The queue preserves the pinned Meili order for
equal accumulated costs. Each search keeps candidate IDs, predecessor
labels and queue storage in the request arena. The first result includes
the contiguous sub-matches across gaps. Alternatives stop when the next
path has a discontinuity.

Routing runs once per expanded source candidate and saves its transition
scores and arrival edges for the next column. The incoming edge carries
into the departure check at an interior snap. Continuing in the same
direction is allowed. Reversing there still needs to pass the costing's
turn checks.

## Matched Utrecht replay

The 156 Utrecht measurements yield 120 traces. Each of three clock settings
runs the full list and overlapping six-point windows. The probes request up
to four paths. Both use the same single-level tiles, candidate order, auto
profile and scoring formulas.

| Reference | Paths | Native sequences |
| --- | ---: | --- |
| Stock Meili | 183 | 174 agree, 9 differ, 3 additional native paths |
| Meili with independent directed-state routing | 186 | All 186 agree |

The directed-state run includes 120 primary results and 66 alternatives.
Ninety-eight primary results contain breaks. Its maximum score difference
from native is `1.812e-5`.

In trace 28 the arrival on edge 35861 at node 12962 cannot immediately
reverse onto 36270. Valhalla's costing permits the loop along 36271 and
36267 back to node 12962 and onward to 36270. Stock Meili has already
settled the node at the first arrival and loses the second turn state.
The independent reference verifies the 78.481 m continuation in 8.072 s.
Trace 29 likewise needs to revisit node 12855 from edge 35954 to continue
onto 35951. The stock comparison continues to expose these differences.

The independent mode runs the pinned Viterbi and top-k code with the
[directed path auditor](trace-transitions.md#directed-path-audit) scoring
its transitions. For the longer replay, it discards a prefix only when a
prefix with the same incoming edge and relevant complex restriction suffix
has lower or equal distance and, under a clock bound, lower or equal
elapsed time. It uses the raw tile's Valhalla costing for all moves and
checks the source and target fractions against the same bounds.

## Reproduction

Prepare the [candidate fixture](trace-candidates.md) and the matching
single-level native import. Run both probes on the same Linux platform.
Compile the reference in the pinned Valhalla 3.9.3 image.

```sh
python3 oracle/viterbi.py extract measurements.tsv viterbi.tsv
g++ -std=c++20 -O2 -I/usr/local/include/valhalla/third_party \
  oracle/viterbi-reference.cc -o viterbi-reference -lvalhalla \
  -lprotobuf-lite -lprime_server -lz -l:libcurl.so.4 -l:liblz4.so.1 \
  -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
./viterbi-reference CONFIG.json viterbi.tsv > stock.tsv
./viterbi-reference CONFIG.json viterbi.tsv --directed > directed.tsv
zig build check-viterbi -- BUNDLE viterbi.tsv > native.tsv
python3 oracle/viterbi.py compare directed.tsv native.tsv
python3 oracle/viterbi.py compare stock.tsv native.tsv
```

Each result row gives the trace number, path rank, break flag, score and
candidate state IDs in measurement order. A missing candidate is
written as `-1`. The stock comparison exits 1 for the differences above.
