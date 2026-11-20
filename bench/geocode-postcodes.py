#!/usr/bin/env python3
"""Check indexed postcode lookups against independent integer coordinate means."""

import argparse
import collections
import json
import random
import re
import struct
import subprocess
from pathlib import Path


PAYLOAD_OFFSET = 65536
WORLD = 3_600_000_000
SEAM = WORLD // 2
ADDRESS_RECORDS = {
    "places": 72,
    "streets": 72,
    "addresses": 96,
    "pois": 72,
}
POSTCODE = struct.Struct("<4I6iI")


def payload(bundle, name):
    return (bundle / f"{name}.bin").read_bytes()[PAYLOAD_OFFSET:]


def text_at(text, row, offset):
    first, length = struct.unpack_from("<II", row, offset)
    return text[first : first + length]


def normalized(raw, iso):
    value = raw.strip().upper()
    prefixes = (b"LU-", b"L-") if iso == b"LU" else (iso + b"-",)
    for prefix in prefixes:
        if value.startswith(prefix):
            value = value[len(prefix) :]
            break
    value = b"".join(value.split())
    if len(value) <= 32 and re.fullmatch(rb"[A-Z0-9]+(?:-[A-Z0-9]+)*", value):
        return value
    return None


def witnesses(bundle, text, countries, iso):
    points = collections.defaultdict(dict)
    for section, size in ADDRESS_RECORDS.items():
        rows = memoryview(payload(bundle, section))
        for offset in range(0, len(rows), size):
            record = rows[offset : offset + size]
            (country,) = struct.unpack_from("<I", record, 24)
            if country not in countries:
                continue
            token = text_at(text, record, 44)
            if not token:
                continue
            osm_id, lng, lat = struct.unpack_from("<qii", record)
            source = record[52] & 3
            for part in token.split(b";"):
                code = normalized(part, iso)
                if code:
                    points[country, code][source, osm_id] = lng, lat
    return points


def round_mean(total, count):
    quotient, remainder = divmod(abs(total), count)
    result = quotient + (remainder * 2 >= count)
    return result if total >= 0 else -result


def wrap(lng):
    if lng > SEAM:
        return lng - WORLD
    if lng < -SEAM:
        return lng + WORLD
    return lng


def statistics(points):
    origin = points[0][0]
    lngs = [wrap(lng - origin) + origin for lng, _ in points]
    lats = [lat for _, lat in points]
    return (
        (wrap(round_mean(sum(lngs), len(points))), round_mean(sum(lats), len(points))),
        (wrap(min(lngs)), min(lats)),
        (wrap(max(lngs)), max(lats)),
    )


def quantized(point):
    return round(point["lng"] * 10_000_000), round(point["lat"] * 10_000_000)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zr", type=Path)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("country")
    samples = parser.add_mutually_exclusive_group()
    samples.add_argument("--sample", type=int, default=1000)
    samples.add_argument("--all", action="store_true")
    args = parser.parse_args()
    iso = args.country.upper().encode("ascii")
    text = payload(args.bundle, "text")
    countries = {
        row
        for row, (first, length) in enumerate(struct.iter_unpack("<II", payload(args.bundle, "country-codes")), 1)
        if text[first : first + length] == iso
    }
    points = witnesses(args.bundle, text, countries, iso)
    applicable = {}
    total = 0
    for first, length, country, count, *fields in POSTCODE.iter_unpack(payload(args.bundle, "postcodes")):
        if country not in countries:
            continue
        total += 1
        code = text[first : first + length]
        matching = points.get((country, code), {})
        # A polygon is independently covered by the multipolygon fixture.
        # For point-based codes, require a stored feature for each witness.
        if not fields[-1] and count and len(matching) == count:
            applicable[code] = statistics(list(matching.values())), count
    if args.all:
        sample = sorted(applicable)
    else:
        if args.sample < 1 or args.sample > len(applicable):
            raise ValueError(f"requested {args.sample} codes, found {len(applicable)} independent point-based references")
        sample = sorted(random.Random(219).sample(sorted(applicable), args.sample))
    if not sample:
        raise ValueError("no postcode references")
    query = [str(args.zr.resolve()), "geocode", "postcode", str(args.bundle), args.country]
    actual = json.loads(subprocess.check_output([*query, *(code.decode("ascii") for code in sample)]))
    max_error = 0
    for code, result in zip(sample, actual["results"], strict=True):
        (center, minimum, maximum), count = applicable[code]
        record = result["record"]
        if record is None or record["postcode"].encode("ascii") != code or record["address_count"] != count or record["from_boundary"]:
            raise ValueError(f"incorrect postcode result for {code!r}")
        actual_center = quantized(record["center"])
        error = max(abs(wrap(actual_center[0] - center[0])), abs(actual_center[1] - center[1]))
        max_error = max(max_error, error)
        if error > 1 or quantized(record["min"]) != minimum or quantized(record["max"]) != maximum:
            raise ValueError(f"incorrect centroid or extent for {code!r}")
    print(json.dumps({
        "country": args.country.upper(),
        "country_postcodes": total,
        "point_references": len(applicable),
        "lookups_checked": len(sample),
        "max_center_error_e7": max_error,
    }, indent=2))


if __name__ == "__main__":
    main()
