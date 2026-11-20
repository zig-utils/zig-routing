#!/usr/bin/env python3
"""Compare a geocode bundle with independent OSM PBF tag queries.

The reference reader handles the raw and zlib blobs in the test extracts.
It does not import the geocoder, its PBF reader, or a protobuf library.
"""

import argparse
import collections
import hashlib
import json
import struct
import zlib
from pathlib import Path


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("invalid varint")


def integers(data):
    offset = 0
    while offset < len(data):
        value, offset = varint(data, offset)
        yield value


def fields(data):
    offset = 0
    data = memoryview(data)
    while offset < len(data):
        tag, offset = varint(data, offset)
        wire = tag & 7
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire == 2:
            length, offset = varint(data, offset)
            end = offset + length
            if end > len(data):
                raise ValueError("truncated protobuf field")
            value = data[offset:end]
            offset = end
        else:
            raise ValueError(f"unsupported protobuf wire type {wire}")
        yield tag >> 3, value


def blocks(path):
    with path.open("rb") as source:
        while prefix := source.read(4):
            (length,) = struct.unpack(">I", prefix)
            header = dict(fields(source.read(length)))
            blob = dict(fields(source.read(header[3])))
            if header[1] == b"OSMData":
                yield blob[1] if 1 in blob else zlib.decompress(blob[3])


def pairs(table, keys, values):
    return {table[key]: table[value] for key, value in zip(keys, values, strict=True)}


def tagged_objects(path):
    for block in blocks(path):
        groups = []
        for number, value in fields(block):
            if number == 1:
                table = [bytes(text) for field, text in fields(value) if field == 1]
            if number == 2:
                groups.append(value)
        for group in groups:
            for entity, raw in fields(group):
                if entity in (1, 3, 4):
                    keys = []
                    values = []
                    for number, field in fields(raw):
                        if number == 2:
                            keys.extend(integers(field) if isinstance(field, memoryview) else [field])
                        if number == 3:
                            values.extend(integers(field) if isinstance(field, memoryview) else [field])
                    if keys:
                        yield entity, pairs(table, keys, values)
                elif entity == 2:
                    packed = (value for number, value in fields(raw) if number == 10)
                    tags = (value for chunk in packed for value in integers(chunk))
                    result = {}
                    for key in tags:
                        if key:
                            result[table[key]] = table[next(tags)]
                        elif result:
                            yield entity, result
                            result = {}
                    if result:
                        raise ValueError("unterminated dense tags")


POI = set(b"amenity shop tourism leisure historic healthcare office craft emergency public_transport railway aeroway".split())
NAMED_POI = {b"man_made", b"natural"}


def reference(path):
    counts = dict.fromkeys(("places", "street_ways", "addresses", "pois"), 0)
    for entity, tags in tagged_objects(path):
        populated = {key for key, value in tags.items() if value}
        active = populated - {key for key in populated if tags[key] == b"no"}
        named = b"name" in populated
        counts["places"] += b"place" in active
        counts["street_ways"] += entity == 3 and named and b"highway" in active
        counts["addresses"] += not populated.isdisjoint({b"addr:housenumber", b"addr:housename"})
        counts["pois"] += not active.isdisjoint(POI) or (named and not active.isdisjoint(NAMED_POI))
    return counts


RECORDS = {"places": 72, "streets": 72, "addresses": 96, "pois": 72, "admins": 24, "names": 16, "text": 1, "street-ways": 8}
HEADER = struct.Struct("<8sII16sIIQQ8s")
PAYLOAD_OFFSET = 65536


def bundle_counts(path, identity):
    sections = {}
    for ordinal, (name, size) in enumerate(RECORDS.items(), 1):
        with (path / f"{name}.bin").open("rb") as source:
            magic, version, kind, uuid, item_size, _, count, _, _ = HEADER.unpack(source.read(HEADER.size))
            if (magic, version, kind, uuid, item_size) != (b"ZRGEOCOD", 1, ordinal, identity, size):
                raise ValueError(f"wrong header for {name}")
            source.seek(PAYLOAD_OFFSET)
            payload = source.read()
            if len(payload) != count * size:
                raise ValueError(f"wrong payload length for {name}")
            sections[name] = (count, payload)

    admin_count, admins = sections["admins"]
    counts = collections.Counter()
    city_streets = set()
    for name in ("places", "streets", "addresses", "pois"):
        count, payload = sections[name]
        counts[name] = count
        per_class = collections.Counter()
        for offset in range(0, len(payload), RECORDS[name]):
            country, state, county, city, district = struct.unpack_from("<5I", payload, offset + 24)
            for rank, region in enumerate((country, state, county, city, district)):
                if region and (region > admin_count or admins[(region - 1) * RECORDS["admins"] + 20] & 7 != rank):
                    raise ValueError(f"wrong hierarchy ID in {name}")
            per_class["country"] += bool(country)
            per_class["city"] += bool(city)
            per_class["both"] += bool(country and city)
            if name == "streets":
                begin, length = struct.unpack_from("<2I", payload, offset + 64)
                if begin != counts["street_ways"] or length == 0:
                    raise ValueError("street-way membership is not contiguous")
                counts["street_ways"] += length
                if city:
                    start, end = struct.unpack_from("<2I", payload, offset + 16)
                    names = sections["names"][1]
                    primary = next(
                        struct.unpack_from("<2I", names, entry + 8)
                        for entry in range(start * RECORDS["names"], (start + end) * RECORDS["names"], RECORDS["names"])
                        if struct.unpack_from("<I", names, entry + 4)[0] == 0
                    )
                    key = (city, primary)
                    if key in city_streets:
                        raise ValueError("duplicate street name in a municipality")
                    city_streets.add(key)
        print(f"{name}: {count} records, {per_class['country']} country, {per_class['city']} city, {per_class['both']} both")
        counts["country_and_city"] += per_class["both"]
        counts["records"] += count
    if counts["street_ways"] != sections["street-ways"][0]:
        raise ValueError("street memberships do not cover the section")
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pbf", type=Path)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--admin-pbf", action="append", default=[], type=Path)
    args = parser.parse_args()
    identity = hashlib.sha256(b"zr-geocode-admin-v1" if args.admin_pbf else b"zr-geocode-v1")
    for path in [args.pbf, *args.admin_pbf]:
        if args.admin_pbf:
            identity.update(struct.pack("<Q", path.stat().st_size))
        with path.open("rb") as source:
            while chunk := source.read(1 << 20):
                identity.update(chunk)
    stored = bundle_counts(args.bundle, identity.digest()[:16])
    expected = reference(args.pbf)
    result = {}
    for name, count in expected.items():
        error = abs(stored[name] - count) / max(count, 1)
        result[name] = {"reference": count, "stored": stored[name], "relative_error": error}
    coverage = stored["country_and_city"] / max(stored["records"], 1)
    coverage_report = {
        "records": stored["records"],
        "country_and_city": stored["country_and_city"],
        "fraction": coverage,
    }
    print(json.dumps({"classes": result, "coverage": coverage_report}, indent=2))
    return int(coverage < 0.99 or any(record["relative_error"] > 0.005 for record in result.values()))


if __name__ == "__main__":
    raise SystemExit(main())
