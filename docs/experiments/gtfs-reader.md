# GTFS Schedule reader

The importer streams stored and DEFLATE ZIP members into temporary memory
and verifies each member's CRC. It maps columns by header name and keeps
the 13 supported tables in an arena. Table diagnostics carry the file,
logical CSV record, column and known field name. Service times can extend
beyond midnight. [GTFS Schedule reference](https://gtfs.org/documentation/schedule/reference/).

Stop times use columnar storage. Workers split on logical CSV record
boundaries, parse into disjoint row ranges and intern text locally. The
loader merges text IDs in input order. A quoted line break stays with its
record, and changing the worker count preserves row order and text IDs.

## Public-feed checks

Download the static feed ZIP files. The record counts below are from
2026-11-20.

| Feed | Stops | Trips | Stop times | Median million rows/s |
| --- | ---: | ---: | ---: | ---: |
| [Brockton Area Transit](https://data.trilliumtransit.com/gtfs/brockton-ma-us/brockton-ma-us.zip) | 963 | 2,325 | 85,809 | 10.54 |
| [MBTA](https://cdn.mbta.com/MBTA_GTFS.zip) | 10,292 | 98,881 | 2,416,466 | 18.81 |
| [TriMet](https://developer.trimet.org/schedule/gtfs.zip) | 6,029 | 52,877 | 2,638,858 | 15.28 |

MassDOT provides the Brockton and MBTA data.
[Massachusetts developer feeds](https://www.mass.gov/lists/mbta-and-transit-data-for-developers).
[TriMet developer resources](https://developer.trimet.org/GTFS.shtml).

```sh
zig build bench-gtfs -Doptimize=ReleaseFast -- FEED.zip 8 > counts.tsv
python3 oracle/check-gtfs-counts.py FEED.zip counts.tsv
scripts/fuzz.sh -s 60 gtfs-csv
```

The benchmark times stop-time parsing, including boundary planning,
parallel decoding and the text merge. ZIP inflation and the other feed
tables are outside that interval. The rates are medians of five runs per
feed with eight workers on an Apple M3 Pro.
