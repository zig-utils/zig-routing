#!/usr/bin/env python3
"""Compile pinned IANA TZif data to the native graph rules format."""

import argparse
from pathlib import Path
import re
import struct

ABBR = r"(?:[A-Za-z]{3,}|<[-+A-Za-z0-9]+>)"
CLOCK = r"[+-]?\d{1,3}(?::\d{2}(?::\d{2})?)?"
FOOTER = re.compile(rf"{ABBR}({CLOCK})(?:{ABBR}({CLOCK})?,([^,]+),([^,]+))?")
MONTH = re.compile(rf"M(\d{{1,2}})\.([1-5])\.([0-6])(?:/({CLOCK}))?")


def valhalla_ids(source):
    table = source.read_text().split("tz_name_to_id =", 1)[1].split("};", 1)[0]
    rows = {}
    for name, base, extension in re.findall(r'\{"([^"]+)", (\d+)(?: \| \(1 << (\d+)\))?\}', table):
        rows[name] = int(base) | (1 << int(extension) if extension else 0)
    if len(rows) != table.count('{"') or not rows or max(rows.values()) >= 1024:
        raise ValueError("Valhalla timezone table has an unsupported index")
    return rows


def seconds(text):
    fields = list(map(int, text.lstrip("-+").split(":")))
    if any(field >= 60 for field in fields[1:]):
        raise ValueError(f"invalid clock value {text}")
    total = sum(field * scale for field, scale in zip(fields, (3600, 60, 1)))
    return -total if text.startswith("-") else total


def offset_bits(value, dst):
    if not -(1 << 23) <= value < 1 << 23 or dst not in (0, 1):
        raise ValueError("UTC offset or DST flag cannot be stored")
    return (value & 0xffffff) | (dst << 24)


def month_rule(text):
    match = MONTH.fullmatch(text)
    if match is None:
        raise ValueError(f"unsupported TZif calendar rule {text}")
    month, week, weekday = map(int, match.groups()[:3])
    clock = seconds(match[4]) if match[4] else 7200
    if not 1 <= month <= 12 or not -(1 << 20) <= clock < 1 << 20:
        raise ValueError(f"invalid TZif calendar rule {text}")
    return month | (week << 4) | (weekday << 7) | ((clock & 0x1fffff) << 10)


def future(footer, last):
    if not footer:
        return last, last, 0, 0
    match = FOOTER.fullmatch(footer)
    if match is None:
        raise ValueError(f"unsupported TZif footer {footer}")
    standard = -seconds(match[1])
    if match[3] is None:
        return offset_bits(standard, False), 0, 0, 0
    daylight = standard + 3600 if match[2] is None else -seconds(match[2])
    return offset_bits(standard, False), offset_bits(daylight, True), month_rule(match[3]), month_rule(match[4])


def tzif(path):
    data = path.read_bytes()

    def header(cursor):
        magic, version, *counts = struct.unpack_from(">4sc15x6I", data, cursor)
        if magic != b"TZif" or version not in (b"2", b"3", b"4"):
            raise ValueError(f"unsupported TZif header for {path.name}")
        return counts

    utc, standard, leap, count, types, chars = header(0)
    second = 44 + 5 * count + 6 * types + chars + 8 * leap + standard + utc
    utc, standard, leap, count, types, chars = header(second)
    if not 1 <= types <= 256 or leap:
        raise ValueError(f"expected POSIX TZif records for {path.name}")

    pos = second + 44
    times = struct.unpack_from(f">{count}q", data, pos)
    pos += 8 * count
    indices = data[pos:pos + count]
    pos += count
    offsets = []
    for index in range(types):
        value, dst, _ = struct.unpack_from(">lBB", data, pos + 6 * index)
        offsets.append(offset_bits(value, dst))
    pos += 6 * types + chars + standard + utc
    footer = data[pos:]
    if not footer.startswith(b"\n") or not footer.endswith(b"\n"):
        raise ValueError(f"invalid TZif footer for {path.name}")
    steps = tuple(zip(times, (offsets[i] for i in indices), strict=True))
    if any(a[0] >= b[0] for a, b in zip(steps, steps[1:])):
        raise ValueError(f"unordered TZif transitions for {path.name}")
    last = steps[-1][1] if steps else offsets[0]
    return offsets[0], steps, future(footer[1:-1].decode("ascii"), last)


def compile_rules(ids, directory, version):
    canonical = {identifier: name for name, identifier in ids.items()}
    strings = bytearray()
    spans = {}
    names = bytearray()
    for name, identifier in sorted(ids.items()):
        encoded = name.encode("ascii")
        spans[name] = len(strings), len(encoded)
        strings.extend(encoded)
        names.extend(struct.pack("<III", *spans[name], identifier))

    times, offsets, zones = [], [], bytearray()
    for identifier, name in sorted(canonical.items()):
        initial, steps, recurring = tzif(directory / name)
        zones.extend(struct.pack("<10I", identifier, len(times), len(steps), initial, *recurring, *spans[name]))
        for instant, offset in steps:
            times.append(instant)
            offsets.append(offset)

    return b"".join((
        struct.pack("<8s8s4I", b"ZRTZBIN1", version, len(canonical), len(times), len(ids), len(strings)),
        struct.pack(f"<{len(times)}q", *times),
        struct.pack(f"<{len(offsets)}I", *offsets),
        zones, names, strings,
    ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("datetime_source", type=Path)
    parser.add_argument("tzif_directory", type=Path)
    parser.add_argument("iana_version")
    parser.add_argument("output", type=Path)
    parser.add_argument("--zone", action="append", help="compile only this named zone (repeatable)")
    args = parser.parse_args()
    if not re.fullmatch(r"\d{4}[a-z]", args.iana_version):
        parser.error("expected an IANA release version such as 2026f")
    ids = valhalla_ids(args.datetime_source)
    if args.zone:
        unknown = set(args.zone) - ids.keys()
        if unknown:
            parser.error(f"unknown Valhalla timezone: {', '.join(sorted(unknown))}")
        ids = {name: identifier for name, identifier in ids.items() if name in args.zone}
    args.output.write_bytes(compile_rules(ids, args.tzif_directory, args.iana_version.encode("ascii")))


if __name__ == "__main__":
    main()
