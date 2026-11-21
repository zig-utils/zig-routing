# Trace route stitching

[#180](https://github.com/zig-utils/zig-routing/issues/180) turns the
selected candidate sequence into matched points, directed edge cuts
and recosted legs. The router recovers each selected transition with
the same incoming edge that priced it during Viterbi. The stitcher
merges contiguous cuts on the same edge and keeps cuts separate at
break points and discontinuities. Measurements closer than the
interpolation threshold project in order onto the selected route.

The edge walker uses the endpoint correlations and checks each next
edge against the ordered shape. Its length tolerance is 5%, with a
10 m minimum and 25 m maximum. The final accumulated distance must
agree within 5 m. The walk can revisit a node at a later shape index.
Walk-or-snap falls back to candidate matching when the geometry
fails the walk.

The [route recoster](../../src/search/legs.zig) prices the stitched
cuts with the same traversal and turn costing as an ordinary route.
Timestamped legs use the trace's elapsed time. Map-snapped traces
with a discontinuity use recosted time. Fixtures cover exact walks,
loops, fallback, interpolated break points, timestamps and multiple
partial matches on the same edge with a gap between them.

## Utrecht route replay

The [Viterbi corpus](viterbi.md) contains 120 traces with three clock
settings. Both full matchers thin the measurements at 10 m and use
the same auto costing, candidate search and turn penalty factor of
200. The segments probe reports the primary route for each trace.

Native matches all 1,558 directed segments, including fractions and
gap markers, on all 120 traces against the pinned Viterbi reference
with independently audited directed transitions. The largest cut
difference is `2.851e-8`. Stock Meili matches 114 traces. Its six
differences all arise around the two repeated-node movements described
in the [Viterbi replay](viterbi.md#matched-utrecht-replay). The stock
comparison reports each of them and exits 1.

```sh
./viterbi-reference CONFIG.json viterbi.tsv --segments > stock-segments.tsv
./viterbi-reference CONFIG.json viterbi.tsv --directed-segments > directed-segments.tsv
zig build check-viterbi -- BUNDLE viterbi.tsv --segments > native-segments.tsv
python3 oracle/viterbi.py compare-segments directed-segments.tsv native-segments.tsv
python3 oracle/viterbi.py compare-segments stock-segments.tsv native-segments.tsv
```

A row starts with the trace number and lists edge ID, begin and end
fractions, and the discontinuity flag for each segment in travel order.
The comparison includes stationary cuts and checks every fraction to
`1e-4`.
