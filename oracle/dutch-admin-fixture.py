#!/usr/bin/env python3
"""Encode the upstream Amsterdam test's Netherlands boundary as OSM PBF."""

import argparse
from pathlib import Path
import sqlite3
import struct


def varint(value):
    data = bytearray()
    while value >= 128:
        data.append((value & 127) | 128)
        value >>= 7
    data.append(value)
    return bytes(data)


def signed(value):
    return varint((value << 1) ^ (value >> 63))


def field(number, data):
    return varint(number << 3 | 2) + varint(len(data)) + data


def integer(number, value):
    return varint(number << 3) + varint(value)


def signed_field(number, value):
    return varint(number << 3) + signed(value)


def frame(kind, payload):
    blob = field(1, payload)
    header = field(1, kind) + integer(3, len(blob))
    return struct.pack(">I", len(header)) + header + blob


def rings(data):
    # The pinned fixture uses the uncompressed little-endian SpatiaLite
    # representation of a WGS84 MultiPolygon.
    if data[:2] != b"\0\1" or data[38] != 0x7c or data[-1] != 0xfe:
        raise ValueError("expected the Valhalla fixture's SpatiaLite geometry")
    srid, = struct.unpack_from("<I", data, 2)
    kind, count = struct.unpack_from("<II", data, 39)
    if srid != 4326 or kind != 6:
        raise ValueError("expected a WGS84 MultiPolygon")
    pos = 47
    for _ in range(count):
        kind, ring_count = struct.unpack_from("<II", data, pos + 1)
        if data[pos] != 0x69 or kind != 3:
            raise ValueError("expected an uncompressed polygon member")
        pos += 9
        for index in range(ring_count):
            n, = struct.unpack_from("<I", data, pos)
            end = pos + 4 + 16 * n
            points = struct.iter_unpack("<dd", data[pos + 4:end])
            pos = end
            yield index != 0, [(round(lng * 1e7), round(lat * 1e7)) for lng, lat in points]
    if pos != len(data) - 1:
        raise ValueError("geometry has trailing bytes")


def encode(name, english, iso, geometry):
    words = ["", "type", "boundary", "administrative", "admin_level", "2",
             "name", name, "name:en", english, "ISO3166-1:alpha2", iso, "outer", "inner"]
    strings = field(1, b"".join(field(1, word.encode()) for word in words))
    first_id = 1_000_000_000_000
    points, ways = {}, []
    for inner, ring in rings(geometry):
        refs = [points.setdefault(point, first_id + len(points)) for point in ring]
        ways.append((inner, refs))
    nodes = b"".join(
        field(1, signed_field(1, identifier) + signed_field(8, lat) + signed_field(9, lng))
        for (lng, lat), identifier in points.items()
    )
    way_rows, roles = [], []
    for index, (inner, refs) in enumerate(ways):
        deltas = [refs[0], *(b - a for a, b in zip(refs, refs[1:]))]
        way_rows.append(field(3, integer(1, first_id + index) + field(8, b"".join(map(signed, deltas)))))
        roles.append(13 if inner else 12)
    keys = field(2, bytes([1, 2, 4, 6, 8, 10]))
    values = field(3, bytes([2, 3, 5, 7, 9, 11]))
    members = field(8, bytes(roles)) + field(9, signed(first_id) + signed(1) * (len(ways) - 1))
    relation = integer(1, first_id) + keys + values + members + field(10, bytes([1]) * len(ways))
    header = field(4, b"OsmSchema-V0.6") + field(5, b"Sort.Type_then_ID")
    block = strings + field(2, nodes) + field(2, b"".join(way_rows)) + field(2, field(4, relation))
    return frame(b"OSMHeader", header) + frame(b"OSMData", block)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netherlands_admin", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with sqlite3.connect(args.netherlands_admin.resolve().as_uri() + "?mode=ro", uri=True) as db:
        row, = db.execute("SELECT name, name_en, iso_code, geom FROM admins WHERE iso_code = 'NL' AND admin_level = 2")
    args.output.write_bytes(encode(*row))


if __name__ == "__main__":
    main()
