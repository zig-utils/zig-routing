#!/usr/bin/env python3
"""Compare masks and driving side on native and imported Valhalla bundles."""

import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import struct
import sys

PAYLOAD = 65536
CLASS_ID = (1 << 20) - 1
REVERSE_SHAPE = 1 << 31
NODE_CONNECTOR = 1 << 27
COUNTRY_CROSSING = 1 << 25
DRIVE_ON_LEFT = 1 << 27


def payload(bundle, section):
    return (bundle / f"{section}.bin").read_bytes()[PAYLOAD:]


def quantize_e6(coordinate, offset):
    degrees = (coordinate + offset * 10_000_000) * 1e-7 - offset
    scaled = degrees * 1e6
    return math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)


def signed_deltas(data):
    value = shift = 0
    for byte in data:
        value |= (byte & 127) << shift
        if byte & 128:
            shift += 7
        else:
            yield (value >> 1) ^ -(value & 1)
            value = shift = 0
    if shift:
        raise ValueError("truncated cold shape")


def decode_shape(data):
    lat = lng = 0
    deltas = signed_deltas(data)
    for dy, dx in zip(deltas, deltas, strict=True):
        lat = (lat + dy + (1 << 31)) % (1 << 32) - (1 << 31)
        lng = (lng + dx + (1 << 31)) % (1 << 32) - (1 << 31)
        yield quantize_e6(lat, 90), quantize_e6(lng, 180)


def way_shapes(bundle):
    data = payload(bundle, "cold")
    count, _, _ = struct.unpack_from("<IIQ", data)
    chunks_start = 16 + 8 * ((count + 255) // 256 + 1)
    for index in range(count):
        chunk, local = divmod(index, 256)
        directory = chunks_start + struct.unpack_from("<Q", data, 16 + 8 * chunk)[0]
        chunk_records = min(256, count - chunk * 256)
        start = directory + 8 * (chunk_records + 1) + struct.unpack_from("<Q", data, directory + 8 * local)[0]
        way, length, vertices = struct.unpack_from("<QII", data, start)
        shape = tuple(decode_shape(data[start + 20:start + 20 + length]))
        if len(shape) != vertices:
            raise ValueError(f"cold record for way {way} has an invalid shape count")
        yield way, shape


def edges(bundle):
    shapes = list(way_shapes(bundle))
    csr = [offset for offset, in struct.iter_unpack("<I", payload(bundle, "first_edge"))]
    nodes = list(struct.iter_unpack("<II", payload(bundle, "nodes")))
    classes = list(struct.iter_unpack("<IIIII", payload(bundle, "classes")))
    hot = list(struct.iter_unpack("<IIII", payload(bundle, "edges")))
    cold = [index for index, in struct.iter_unpack("<I", payload(bundle, "cold_idx"))]
    result = defaultdict(Counter)
    for node, (start, end) in enumerate(zip(csr, csr[1:])):
        drives_left = bool(nodes[node][1] & DRIVE_ON_LEFT)
        for slot in range(start, end):
            _, access, flags, _, _ = classes[hot[slot][2] & CLASS_ID]
            if flags & NODE_CONNECTOR:
                continue
            way, shape = shapes[cold[slot] & (REVERSE_SHAPE - 1)]
            if cold[slot] & REVERSE_SHAPE:
                shape = shape[::-1]
            result[way, shape][(access & 65535, access >> 16, bool(flags & COUNTRY_CROSSING), drives_left)] += 1
    return result


def same_shape(a, b):
    return all(abs(x - y) <= 1 for p, q in zip(a, b, strict=True) for x, y in zip(p, q, strict=True))


def align(native, oracle):
    exact = native.keys() & oracle.keys()
    remaining = defaultdict(list)
    for key in oracle.keys() - exact:
        way, shape = key
        remaining[way, len(shape)].append(key)
    offsets = {}
    targets = Counter()
    for key in native.keys() - exact:
        way, shape = key
        options = [other for other in remaining[way, len(shape)] if same_shape(shape, other[1])]
        targets.update(options)
        if len(options) == 1:
            offsets[key] = options[0]
    # Every rounded match must be unique in both directions.
    return [(key, key) for key in sorted(exact)] + [
        (key, other) for key, other in sorted(offsets.items()) if targets[other] == 1
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("valhalla", type=Path)
    args = parser.parse_args()
    native, oracle = map(edges, (args.native, args.valhalla))
    pairs = align(native, oracle)
    counts = Counter(
        unmatched_native=sum(map(Counter.total, native.values())),
        unmatched_valhalla=sum(map(Counter.total, oracle.values())),
    )
    samples = []
    for left, right in pairs:
        actual, expected = native[left], oracle[right]
        left_count, right_count = actual.total(), expected.total()
        matched = min(left_count, right_count)
        equal = (actual & expected).total()
        counts["matched"] += matched
        counts["equal"] += equal
        counts["unmatched_native"] -= matched
        counts["unmatched_valhalla"] -= matched
        if left != right:
            counts["rounded"] += matched
        if matched > equal:
            counts["mismatches"] += matched - equal
            if len(samples) < 10:
                samples.append({"edge": left, "native": sorted(actual.items()), "valhalla": sorted(expected.items())})
    print(json.dumps({"counts": counts, "samples": samples}, indent=2))
    return int(counts["equal"] != counts["matched"] or counts["matched"] == 0 or
               counts["unmatched_native"] != 0 or counts["unmatched_valhalla"] != 0)


if __name__ == "__main__":
    sys.exit(main())
