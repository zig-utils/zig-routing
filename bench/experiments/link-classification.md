# Link classification parity

The native builder classifies links before assigning edge class IDs. It
keeps the original directed access and compares the reclassified road
class and use. The same classification drives speed selection and the
type of the sign emitted on the link.

The reference is Valhalla 3.9.3 built with link reclassification and
turn-channel inference enabled. The same extracted OSM inputs were
built natively. Directed arcs were paired by OSM way ID and ordered
endpoints within two units at E7 precision. Pairs with multiple
possible matches were excluded.

The native x86_64 Linux release matched the upstream class, use and sign
records on all 240 directed arcs from the Gurka fixture runs. Those runs
cover explicit and inferred turn channels, inference with reclassification
disabled, road refs, destination refs, a branch across tile boundaries,
merged paths and long slip lanes. The US and Canadian name fixtures also
matched all 24 turn bits.

| Extract | Paired directed arcs | Paired links | Link class or use differences | Sign list differences |
| --- | ---: | ---: | ---: | ---: |
| Liechtenstein | 15,740 | 12 | 0 | 0 |
| Utrecht | 85,068 | 796 | 0 | 0 |

The Utrecht result includes OSM ways 7053595, 7053596, 20124458 and
95594593. Their inferred turn channels now produce the same guide signs
as Valhalla.

Name-continuity comparisons used imported base tiles. Intersections with
a unique match for their complete set of directed E6 approach shapes
were compared in the same local-edge order.

| Extract | Matched intersections | Compared movements | Name continuity differences |
| --- | ---: | ---: | ---: |
| Liechtenstein | 3,221 | 20,187 | 0 |
| Utrecht | 22,121 | 180,483 | 2 |

Both Utrecht differences are movements between ways 200764757 and
200764758. The latter is unnamed in both bundles. The native name table
keeps a `name:nl` value on the former, which has an empty name list in
the oracle. The other 180,481 comparisons matched. The language
selection work tracks this fixture. [Issue #143](https://github.com/zig-utils/zig-routing/issues/143#issuecomment-7031736706)

The full native Utrecht build and the build resumed at enhancement and
turn generation produced byte-identical bundles across worker counts.
The new build identity requires a fresh work directory for checkpoints
made before link classification.

The Linux x86_64 baseline release measured 19,454,328 bytes against the
19,500,000-byte cap. Sharing scalar JSON field writing kept the binary
under the cap. In the local Utrecht height benchmark, serialization
measured 38.7 ns per point, compared with 39.3 ns per point before the
change and a 75 ns budget.
