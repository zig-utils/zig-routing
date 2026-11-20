#!/usr/bin/env python3
"""Compare node timezone IDs with pinned Valhalla 3.9.3 local tiles."""

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import sys

PAYLOAD = 65536
POINT = struct.Struct("<ii")
ZONE = struct.Struct("<H")
NODE = struct.Struct("<4Q")


def native(bundle):
    points = POINT.iter_unpack((bundle / "coordinates.bin").read_bytes()[PAYLOAD:])
    zones = ZONE.iter_unpack((bundle / "node_timezones.bin").read_bytes()[PAYLOAD:])
    result = {}
    for point, (zone,) in zip(points, zones, strict=True):
        if result.setdefault(point, zone) != zone:
            raise ValueError(f"native nodes at {point} disagree on their timezone")
    return result


def stock(tile):
    data = tile.read_bytes()
    if not data[16:32].startswith(b"3.9.3"):
        raise ValueError(f"unexpected Valhalla version in {tile.name}")
    count = struct.unpack_from("<Q", data, 40)[0] & ((1 << 21) - 1)
    lng, lat = (round(axis * 1e7) for axis in struct.unpack_from("<2f", data, 8))
    for position, edge, flags, _ in NODE.iter_unpack(data[272:272 + count * NODE.size]):
        y = lat + (position & 0x3fffff) * 10 + ((position >> 22) & 15)
        x = lng + ((position >> 26) & 0x3fffff) * 10 + ((position >> 48) & 15)
        timezone = ((edge >> 40) & 511) | (((flags >> 62) & 1) << 9)
        yield (x, y), timezone


def compare(bundle, tiles):
    zones = native(bundle)
    counts, differences = Counter(), Counter()
    paired = set()
    for tile in sorted(tiles.glob("2/**/*.gph")):
        for (x, y), expected in stock(tile):
            counts["valhalla"] += 1
            if (x, y) in zones:
                match = (x, y)
            else:
                candidates = [(dx * dx + dy * dy, (x + dx, y + dy))
                              for dx in range(-2, 3) for dy in range(-2, 3)
                              if (x + dx, y + dy) in zones]
                if not candidates:
                    counts["unmatched_valhalla"] += 1
                    continue
                match = min(candidates)[1]
            paired.add(match)
            counts["matched"] += 1
            counts["with_timezone"] += expected != 0
            counts["equal"] += zones[match] == expected
            if zones[match] != expected:
                differences[zones[match], expected] += 1
    counts["unmatched_native_locations"] = len(zones) - len(paired)
    return counts, differences.most_common()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("tiles", type=Path)
    args = parser.parse_args()
    counts, differences = compare(args.bundle, args.tiles)
    print(json.dumps({"counts": counts, "differences": differences}, indent=2))
    sys.exit(int(not counts["with_timezone"] or bool(differences) or
                 bool(counts["unmatched_valhalla"] or counts["unmatched_native_locations"])))
