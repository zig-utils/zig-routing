# Geocoder extraction

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/zr geocode build extract.osm.pbf geocode --threads 8 --timeout 300s
zig-out/bin/zr geocode inspect geocode
python3 bench/geocode-check.py extract.osm.pbf geocode
```

The command writes to a new directory and emits a JSON report with tag counts,
located counts, merged street counts, administrative coverage, and OSM attribution.
The count for street ways describes source segments. The count for streets
describes merged records.

An extract can include features outside its nominal boundary, for example ways
that cross it. Supply repeatable `--admin-pbf FILE` options with neighboring
extracts from the same OSM snapshot to complete the administrative polygons.
The primary extract defines the feature corpus. Each extra extract contributes
boundary data, and its contents affect the bundle identity. Pass the same
`--admin-pbf` options to the reference check.

Geocoder extraction reads place tags, named highways, house numbers and house
names, and the POI categories defined in `src/geocode/tags.zig`. It retains the
unqualified name and language-qualified names. Population, place type, capital
status, Wikidata and Wikipedia links contribute to importance. Features without
usable source geometry are counted in the report's tagged totals. Relations
can obtain geometry from child relations, including untagged children.

The extractor reuses the routing boundary assembler and the shared polygon
R-tree. Administrative assignment uses point-in-polygon containment. Explicit
settlement tags take precedence over the default mapping of OSM levels to state,
county, municipality, and district. For example, Luxembourg uses level 6 for
cantons, level 8 for communes, and level 9 for urban quarters. The numeric levels
vary by jurisdiction. [OSM administrative levels](https://wiki.openstreetmap.org/wiki/Tag:boundary=administrative),
[Luxembourg boundary tagging](https://wiki.openstreetmap.org/wiki/WikiProject_Luxembourg/Borders)

Each street groups ways with the same primary name and municipality. It retains
source way IDs and the combined names of the component ways. Streets with
unknown municipalities keep their individual way records. An explicit
`addr:postcode` value stays attached to the feature.

The bundle consists of eight little-endian mmap sections. Each section has a
64-byte header, a shared 128-bit dataset ID, a record count, and an XXH3 checksum
over the payload. Arrays begin at a 64 KiB boundary. Records refer to names,
strings, administrative rows, and street ways through checked spans and IDs.
The reader verifies section identity, checksums, lengths, and references when
opening the bundle. Publication uses a staged directory and an exclusive rename.

Published geocoding results derived from these bundles carry
**© OpenStreetMap contributors** and identify the Open Database License.
[OpenStreetMap copyright and attribution](https://www.openstreetmap.org/copyright)

## Verification

The independent reference check compares tag counts with stored record and
street-way counts. It also checks the division of each stored admin reference
and verifies that each municipality has one street record per primary name.

On an Apple M3 Pro, a ReleaseFast run with seven decoder workers and one
consumer built the January 1, 2026 Luxembourg country extract in 12.39 seconds.
It matched all four reference counts and assigned both country and city to
257,538 of 262,146 records. The extract includes features in neighboring
countries.

The November 19, 2026 Liechtenstein extract matched all four reference counts
and assigned both divisions to 20,154 of 20,357 records. Adding the same-date
Austrian and Swiss extracts for boundary geometry took 52.35 seconds with the
same eight-thread limit. With those polygons, all 20,325 merged output records
had both divisions. [Geofabrik Liechtenstein downloads](https://download.geofabrik.de/europe/liechtenstein.html)
