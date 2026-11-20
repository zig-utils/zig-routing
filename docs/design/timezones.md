# Timezones

The native graph uses Valhalla 3.9.3's stable zone IDs. IDs split after the
original release carry the extension bit at position 9. Renamed zones keep
their original IDs. ID zero represents an unassigned node.

The builder reads the timezone-boundary-builder 2026f GeoJSON release
`timezones-with-oceans-1970.geojson.zip`. Pass its extracted GeoJSON and the
repository's compiled IANA 2026f rules to the graph build.

```sh
zig-out/bin/zr build input.osm.pbf --output bundle \
  --timezones combined-with-oceans-1970.json \
  --timezone-rules src/graph/timezones/iana-2026f.ztz
```

The same paths can be supplied as `zig_routing.build.timezone_geojson` and
`zig_routing.build.timezone_rules`. Their contents are fingerprinted with
the build inputs. Resuming before the cold stage requires both inputs to
match the recorded fingerprints.

The build clips polygons into the same sparse grid used for admins and keeps
the cells intersecting the graph's buffered local tiles. A tile with one eligible
zone uses that zone for every node. In a tile with several zones, the node takes
the lowest ID whose polygon covers it. The resulting two-byte node IDs and rules
are written to the warm `node_timezones` and `timezone_rules` sections together.

The rules store historical transition instants and UTC offsets in separate
arrays. The final TZif rule supplies a fixed offset or a pair of Gregorian
recurrences for dates beyond the explicit transitions. The bundle reader
borrows those sections and has no runtime dependency on a system timezone
database. Lookup takes a timezone ID and UTC Unix seconds and returns an
offset in seconds and the daylight-saving flag.

## Regenerating the rules

Valhalla 3.9.3 pins IANA 2026f. Use its `src/baldr/datetime.cc` as the
source of stable IDs. Compile the IANA source files to POSIX TZif with
`zic` and run the generator over those files. This regeneration step is
separate from the graph build.

```sh
zic -b slim -d "$tzif_dir" africa antarctica asia australasia europe \
  northamerica southamerica etcetera backward
python3 tools/timezones/compile.py "$valhalla/src/baldr/datetime.cc" \
  "$tzif_dir" 2026f src/graph/timezones/iana-2026f.ztz
python3 tools/timezones/compile.py "$valhalla/src/baldr/datetime.cc" \
  "$tzif_dir" 2026f test/fuzz/seeds/timezone-rules.bin \
  --zone Europe/Amsterdam --zone Europe/London
```

IANA publishes the [rules release](https://www.iana.org/time-zones/releases/2026f).
The [boundary release](https://github.com/evansiroky/timezone-boundary-builder/releases/tag/2026f)
is derived from OpenStreetMap and distributed under the Open Database License.
