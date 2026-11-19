# OSM PBF fuzz seeds

The source extracts and their SHA-256 sums are pinned in
[oracle/datasets.tsv](../../../oracle/datasets.tsv). Each seed is the
unmodified first `OSMHeader` frame followed by one complete `OSMData`
frame from the same file. Frame indices count from zero and include
each big-endian header-length prefix.

| Seed | Data frame | Uncompressed payload | Seed SHA-256 |
| --- | ---: | --- | --- |
| `liechtenstein.pbf` | 15 | DenseNodes, 91,418 bytes | `47b498a1ca4c5265777e8448a620f132eff8e3c69d6933525cc1860f1b91970b` |
| `utrecht.pbf` | 168 | Relations, 15,754 bytes | `2776e0958d20025dfe92733198efd6f40a57bb7c48bddb89ab638fb2c4ca2c9c` |

The framing target uses the compressed bytes. The primitive and dense-node
targets inflate the same seeds during setup.

`range-manifest.bin` is the version 1 range manifest exported from
`test/graph_fixture.zig` by `zr bundle-manifest`. It contains 1,488 bytes
and all 13 section kinds, including both a full 64 KiB extent and a short
final extent for each nonempty section. SHA-256
`f5f6a09fb9d537ed174e063b3627c6620b93eea8b4fc8cbd79c1282000145734`.
