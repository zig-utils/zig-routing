#!/usr/bin/env python3
"""Extract pinned Utrecht measurements and compare candidate sets on a flat import."""
import argparse
from collections import defaultdict
import json
from math import sqrt
from pathlib import Path
import re
import sys


def extract(source, dest):
    rows = {}
    for literal in re.findall(r'"shape"\s*:\s*\[(.*?)\]', source.read_text(), re.DOTALL):
        try:
            trace = json.loads("[" + literal + "]")
        except json.JSONDecodeError:
            continue
        for point in trace:
            if not isinstance(point, dict) or "lat" not in point or "lon" not in point:
                continue
            lat, lon = float(point["lat"]), float(point["lon"])
            if 52.02 <= lat <= 52.17 and 5.02 <= lon <= 5.20:
                rows[lat, lon, float(point.get("radius", 50)), float(point.get("accuracy", 5))] = None
    dest.write_text("".join("\t".join(map(str, row)) + "\n" for row in rows))
    print(f"{len(rows)} measurements")


def read(path, upstream):
    found = defaultdict(dict)
    source_tiles = set()
    with path.open() as stream:
        for line in stream:
            row, node, edge, fraction, lat, lon, dist = line.split()
            node, edge = int(node), int(edge)
            if upstream:
                source_tiles.add(edge & ((1 << 25) - 1))
                edge >>= 25
                if node >= 0:
                    source_tiles.add(node & ((1 << 25) - 1))
                    node >>= 25
            found[int(row)][(node, edge)] = (float(fraction), float(lat), float(lon), sqrt(float(dist)))
    if len(source_tiles) > 1:
        raise ValueError("the directed-ID comparison requires matching single-tile graph order")
    return found


def compare(corpus, oracle, native):
    expected, actual = read(oracle, True), read(native, False)
    rows = sum(1 for line in corpus.read_text().splitlines() if line.strip())
    exact = equivalent = shared = close = 0
    for row in range(rows):
        left, right = expected[row], actual[row]
        exact += left.keys() == right.keys()
        # At a graph node, Meili keeps the first incident edge pair it
        # encounters. Count equal node states separately from exact edges.
        left_states = {(n, e if n < 0 else -1) for n, e in left}
        right_states = {(n, e if n < 0 else -1) for n, e in right}
        equivalent += left_states == right_states
        for key in left.keys() & right.keys():
            shared += 1
            close += abs(left[key][3] - right[key][3]) <= 0.001
    print(f"exact directed sets {exact}/{rows}, equivalent node states {equivalent}/{rows}")
    print(f"paired directed distances within 1 mm {close}/{shared}")
    for row in range(rows):
        left, right = expected[row], actual[row]
        if left.keys() != right.keys():
            print(f"first directed mismatch at row {row}: oracle {sorted(left.keys() - right.keys())}, "
                  f"native {sorted(right.keys() - left.keys())}")
            break
    return exact == rows and close == shared


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    extract_cmd = commands.add_parser("extract")
    extract_cmd.add_argument("source", type=Path)
    extract_cmd.add_argument("dest", type=Path)
    compare_cmd = commands.add_parser("compare")
    for name in ("corpus", "oracle", "native"):
        compare_cmd.add_argument(name, type=Path)
    args = parser.parse_args()
    if args.command == "extract":
        extract(args.source, args.dest)
    elif not compare(args.corpus, args.oracle, args.native):
        sys.exit(1)


if __name__ == "__main__":
    main()
