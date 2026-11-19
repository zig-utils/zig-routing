# Graph enhancement parity

The reference is the Valhalla 3.9.3 tile archive for each pinned extract. Import
the archive with `zr import-valhalla --output ORACLE_BUNDLE TILES_ARCHIVE` and
build the matching extract with `zr build EXTRACT --drive-side left --threads 4
--output NATIVE_BUNDLE`. The imported tiles in these runs recorded left-hand
driving. Both graphs used that side for the turn comparison.

Directed edges were paired by OSM way ID and their complete travel-direction
E6 shapes. Turn matrices were paired by the entire set of outgoing edge keys
at nodes of up to eight edges, then compared in that common order.

| Extract | Matched directed edges | Speed and density mismatches | Matched intersections | Compared turns | Turn type, side and stop-impact mismatches |
| --- | ---: | ---: | ---: | ---: | ---: |
| Liechtenstein | 9,858 | 0 | 2,791 | 16,532 | 0 |
| Utrecht | 64,529 | 0 | 19,210 | 149,227 | 0 |

Speed comparisons covered base, free-flow, constrained-flow and truck speeds.
The baseline before this change differed on 3,296 and 42,777 base speeds,
respectively. The matched sample covers 62.6% of Liechtenstein's native
directed edges and 75.6% of Utrecht's. The comparison found 5,902 and 20,804
native edge shapes without a matching complete key, and 3,489 and 11,428
native nodes without an identical set of approaches.

Both extracts produced byte-identical verified bundles at 1, 4 and 16
workers. A configured speed run used a global 135 km/h base setting on
11,274 eligible Liechtenstein directions. Resuming from the saved inputs
after relocating the configuration file reproduced the fresh bundle.
Supplying changed configuration bytes was rejected before enhancement.

The remaining CLI inputs are the destination country and state from the
admin index and the directed exit-sign flags from the sign build. Assembly
accepts both inputs and has a fixture that exercises their combined speed
rule. [Admin index](https://github.com/zig-utils/zig-routing/issues/120),
[Signs and exits](https://github.com/zig-utils/zig-routing/issues/141)
