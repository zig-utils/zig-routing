# Address interpolation and postcodes

`zr geocode build` writes the address and postcode sections alongside the
base geocoder sections. The reader accepts the original eight-section bundles.
A bundle with address data carries all seven address sections under the same
dataset identity. That identity includes the primary extract, any supplied
administrative extracts, and the bundle generation.

```sh
zig-out/bin/zr geocode build extract.osm.pbf geocode --threads 7
zig-out/bin/zr geocode postcode geocode LU 1240 1500 L-2210
python3 bench/geocode-postcodes.py zig-out/bin/zr geocode LU
```

Address linkage uses the tagged street name, including the mapped translations
of a street name. It searches the address's municipality first, then finds
the nearest geometry with the same name in the country. A linked house number
references a member way and a fraction of that way's length. The per-street rows
sort numeric keys and retain letter suffixes, units, explicit ranges, and
reduced fractions. Raw labels stay on the original address records.

Interpolation respects `all`, `even`, `odd`, and `alphabetic` ways. It handles
both numbering directions and uses intermediate tagged nodes as anchors when
they follow the scheme. Estimates follow distance along the mapped way and
carry an `approximate` flag. Individually tagged endpoint addresses remain in
the exact-address rows. [OSM address interpolation](https://wiki.openstreetmap.org/wiki/Addresses)

Postcodes are indexed by country and normalized code. The extent and planar
area-weighted centroid of a mapped postal boundary include the effects of holes
and separate polygons. For codes without a polygon, the extent and centroid
come from the located features tagged with that code. In the lookup response,
a minimum longitude greater than the maximum denotes an extent crossing the
antimeridian. A missing code has a null result in the requested position.
[OSM postal boundaries](https://wiki.openstreetmap.org/wiki/Tag:boundary=postal_code)

Address rendering uses a table for Austria, Liechtenstein, Luxembourg, and
Switzerland. The table controls house number order, unit separators, and
Luxembourg's postcode prefix. The default formats a house number before its
street name and preserves the supplied locality and postcode. [POST Luxembourg](https://www.post.lu/en/particuliers/colis-courrier/bien-rediger-une-adresse),
[Austrian Post](https://ella.post.at/b/faq),
[Liechtenstein Post](https://post.li/wp-content/uploads/2025/04/Anleitung_neues-Versandtool-1.pdf),
[Swiss Post](https://www.post.ch/en/sending-letters/addressing-and-designing/addressing-consignments-correctly)

The postcode benchmark selects a seeded sample from point-derived codes whose
stored source records account for every contributing feature. It verifies
each lookup against integer coordinate sums and exact extents. The PBF fixture
also checks a polygon-derived postcode with independently known bounds and
centroid.

For a country with mapped postal boundaries, the source-polygon check reuses
the PBF boundary assembler and computes the reference centroid using integer
shoelace moments. It samples relation-derived codes and compares the indexed
center and extent with that reference.

```sh
zig build check-geocode-postcodes -Doptimize=ReleaseFast -- austria.osm.pbf geocode AT 1000
```

## Verification

| Geofabrik extract | Reference | Postcodes checked | Maximum centroid error |
| --- | --- | ---: | ---: |
| Austria, November 19, 2026 | Postal polygons | 1,000 | 0 E7 units |
| Switzerland, November 19, 2026 | Tagged feature positions | 1,000 | 1 E7 unit |
| Luxembourg, January 1, 2026 | Tagged feature positions | 1,000 | 1 E7 unit |
| Liechtenstein, November 19, 2026 | Tagged feature positions, including postal-only ways | All 13 | 0 E7 units |

The shared polygon index groups large rings by latitude. Lookup visits every
edge whose latitude range can contain the query, using the same ray crossing
and hole rules as the full ring scan. The Austrian, Swiss, and Luxembourg
bundles matched byte for byte before and after the indexing change.
