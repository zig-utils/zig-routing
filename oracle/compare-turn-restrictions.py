#!/usr/bin/env python3
"""Compare simple turn bits in native bundles and imported Valhalla bundles."""

import argparse
from collections import Counter
import json
from pathlib import Path
import runpy
import struct
import sys

geometry = runpy.run_path(str(Path(__file__).with_name("compare-access.py")))
payload = geometry["payload"]
way_shapes = geometry["way_shapes"]
align = geometry["align"]


def movements(bundle):
    csr = [offset for offset, in struct.iter_unpack("<I", payload(bundle, "first_edge"))]
    nodes = list(struct.iter_unpack("<II", payload(bundle, "nodes")))
    classes = list(struct.iter_unpack("<IIIII", payload(bundle, "classes")))
    edges = list(struct.iter_unpack("<IIII", payload(bundle, "edges")))
    refs = [offset for offset, in struct.iter_unpack("<I", payload(bundle, "cold_idx"))]
    shapes = list(way_shapes(bundle))
    turns = payload(bundle, "turns")
    keys = []
    for (_, _, packed, _), ref in zip(edges, refs, strict=True):
        flags = classes[packed & geometry["CLASS_ID"]][2]
        if flags & geometry["NODE_CONNECTOR"]:
            keys.append(None)
            continue
        way, shape = shapes[ref & (geometry["REVERSE_SHAPE"] - 1)]
        keys.append((way, shape[::-1] if ref & geometry["REVERSE_SHAPE"] else shape))

    restricted = Counter()
    turns_compared = 0
    for (offset, _), (first, last) in zip(nodes, zip(csr, csr[1:]), strict=True):
        degree = last - first
        for local, (head, _, packed, _) in enumerate(edges[first:last]):
            incoming = csr[head] + ((packed >> 25) & 31)
            key = keys[incoming]
            if key is None:
                continue
            row = offset + local * degree
            for outgoing, target in enumerate(keys[first:last]):
                if target is None:
                    continue
                turns_compared += 1
                if turns[row + outgoing] & 128:
                    restricted[key, target] += 1
    return Counter(key for key in keys if key is not None), restricted, turns_compared


def compare(native, stock):
    actual_edges, actual, actual_turns = movements(native)
    expected_edges, expected, expected_turns = movements(stock)
    paired = dict(align(actual_edges, expected_edges))
    matched_edges = sum(min(actual_edges[a], expected_edges[b]) for a, b in paired.items())
    actual_in_reference_order = Counter()
    unmapped_restrictions = 0
    for (incoming, outgoing), count in actual.items():
        if incoming in paired and outgoing in paired:
            actual_in_reference_order[paired[incoming], paired[outgoing]] += count
        else:
            unmapped_restrictions += count
    missing = expected - actual_in_reference_order
    extra = actual_in_reference_order - expected
    counts = {
        "matched_edges": matched_edges,
        "rounded_edge_keys": sum(a != b for a, b in paired.items()),
        "unmatched_native_edges": actual_edges.total() - matched_edges,
        "unmatched_valhalla_edges": expected_edges.total() - matched_edges,
        "native_movements": actual_turns,
        "valhalla_movements": expected_turns,
        "native_restricted_movements": actual.total(),
        "valhalla_restricted_movements": expected.total(),
        "missing_restrictions": missing.total(),
        "extra_restrictions": extra.total() + unmapped_restrictions,
    }
    return counts, missing.most_common(5), extra.most_common(5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("valhalla", type=Path)
    args = parser.parse_args()
    counts, missing, extra = compare(args.native, args.valhalla)
    print(json.dumps({"counts": counts, "missing_examples": missing, "extra_examples": extra}, indent=2))
    sys.exit(int(not counts["matched_edges"] or counts["native_movements"] != counts["valhalla_movements"] or
                 any(counts[field] for field in ("unmatched_native_edges", "unmatched_valhalla_edges",
                                             "missing_restrictions", "extra_restrictions"))))
