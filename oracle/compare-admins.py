#!/usr/bin/env python3
"""Compare native node admins with Valhalla 3.9.3 local tiles from --end build."""

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import sys

PAYLOAD = 65536
POINTS = struct.Struct("<ii")
IDS = struct.Struct("<H")
REGION = struct.Struct("<qQ8I")
ADMIN_ROW = struct.Struct("<II2s3s3x")
NODE = struct.Struct("<4Q")
EMPTY = ("", "", "", "")


def native(bundle):
    points = POINTS.iter_unpack((bundle / "coordinates.bin").read_bytes()[PAYLOAD:])
    file = bundle / "admins.bin"
    if not file.is_file():
        return {p: EMPTY for p in points}
    data = file.read_bytes()[PAYLOAD:]
    version, regions, cells, pieces, rings, vertices, strings, _ = struct.unpack_from("<8I", data)
    assert version == 1
    region_start = 32 + vertices * 16
    names_start = region_start + regions * 48 + cells * 12 + pieces * 12 + rings * 8
    assert len(data) == names_start + strings
    names = data[names_start:]

    def text(start, count):
        return names[start:start + count].decode()

    areas = [(0, 0, "", "")]
    for _, attr, first, count, _en, _en_count, iso, iso_count, _lang, _lang_count in REGION.iter_unpack(
        data[region_start:region_start + regions * REGION.size]
    ):
        areas.append((attr & 65535, (attr >> 16) & 255, text(first, count), text(iso, iso_count)))
    lookup = [EMPTY]
    for parent, level, name, iso in areas[1:]:
        if level == 2:
            lookup.append((iso, name, "", ""))
        elif level == 4 and parent:
            lookup.append((areas[parent][3], areas[parent][2], iso, name))
        else:
            lookup.append(EMPTY)
    ids = IDS.iter_unpack((bundle / "node_admins.bin").read_bytes()[PAYLOAD:])
    assigned = {}
    for point, (index,) in zip(points, ids, strict=True):
        area = lookup[index]
        if assigned.setdefault(point, area) != area:
            raise ValueError(f"native nodes at {point} have different admin assignments")
    return assigned


def read_tile(file):
    data = file.read_bytes()
    version = data[16:32].split(b"\0", 1)[0]
    assert version.startswith(b"3.9.3"), version
    count = struct.unpack_from("<Q", data, 40)[0] & ((1 << 21) - 1)
    lng, lat = (round(i * 1e7) for i in struct.unpack_from("<2f", data, 8))
    admins = (struct.unpack_from("<Q", data, 72)[0] >> 24) & 65535
    end = struct.unpack_from("<I", data, 96)[0]
    text_start = struct.unpack_from("<I", data, 108)[0]
    assert struct.unpack_from("<I", data, 116 + 24 * 4)[0] == 0, "use tiles from --end build"
    assert admins > 0
    # At the end of BuildLocalTiles the edge bins are empty and the
    # fixed admin rows end at the forward-restriction offset.
    admin_start = end - admins * ADMIN_ROW.size

    def text(offset):
        return data[text_start + offset:data.index(b"\0", text_start + offset)].decode()

    rows = [EMPTY]
    for country, state, ci, si in ADMIN_ROW.iter_unpack(data[admin_start + ADMIN_ROW.size:end]):
        rows.append((ci.rstrip(b"\0").decode(), text(country), si.rstrip(b"\0").decode(), text(state)))
    for position, edge, _flags, _headings in NODE.iter_unpack(data[272:272 + count * NODE.size]):
        y = lat + (position & 0x3fffff) * 10 + ((position >> 22) & 15)
        x = lng + ((position >> 26) & 0x3fffff) * 10 + ((position >> 48) & 15)
        yield (x, y), rows[(edge >> 28) & 4095]


def compare(bundle, tiles):
    by_point = native(bundle)
    points = set()
    counts = Counter()
    fields = Counter()
    examples = []
    for tile in sorted(tiles.glob("2/**/*.gph")):
        for point, expected in read_tile(tile):
            counts["valhalla_nodes"] += 1
            x, y = point
            if point in by_point:
                match = point
            else:
                options = [(dx * dx + dy * dy, (x + dx, y + dy))
                           for dx in range(-2, 3) for dy in range(-2, 3) if (x + dx, y + dy) in by_point]
                if not options:
                    counts["unmatched_nodes"] += 1
                    continue
                match = min(options)[1]
            points.add(match)
            counts["matched_nodes"] += 1
            counts["reference_with_admin"] += expected != EMPTY
            actual = by_point[match]
            counts["native_with_admin"] += actual != EMPTY
            if actual == expected:
                counts["equal"] += 1
                continue
            counts["different"] += 1
            fields[(expected, actual)] += 1
            if len(examples) < 8:
                examples.append((point, expected, actual))
    counts["unique_native_points"] = len(by_point)
    counts["unique_matched_points"] = len(points)
    return dict(counts), fields.most_common(), examples


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("bundle", type=Path)
    p.add_argument("tiles", type=Path)
    counts, differences, examples = compare(**vars(p.parse_args()))
    print(json.dumps({
        "counts": counts,
        "differences": differences,
        "examples": examples,
    }, ensure_ascii=False, indent=2))
    sys.exit(int(not counts.get("matched_nodes") or counts.get("unmatched_nodes", 0) != 0 or bool(differences)))
