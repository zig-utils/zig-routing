#!/usr/bin/env python3
"""Compare the GTFS reader's table counts with Python's CSV and ZIP readers."""
import argparse
import csv
import io
from pathlib import Path
import sys
import zipfile


TABLES = (
    "agency", "stops", "routes", "trips", "stop_times", "calendar", "calendar_dates",
    "shapes", "frequencies", "transfers", "feed_info", "pathways", "levels",
)


def reference(path):
    csv.field_size_limit(sys.maxsize)
    counts = {}
    with zipfile.ZipFile(path) as archive:
        members = set(archive.namelist())
        for table in TABLES:
            name = table + ".txt"
            counts[table] = 0
            if name in members:
                with archive.open(name) as member:
                    records = csv.reader(io.TextIOWrapper(member, encoding="utf-8-sig", newline=""))
                    next((row for row in records if row), None)
                    counts[table] = sum(bool(row) for row in records)
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip", type=Path)
    parser.add_argument("counts", type=Path)
    args = parser.parse_args()
    native = dict(line.split("\t", 1) for line in args.counts.read_text().splitlines())
    expected = reference(args.zip)
    differences = {name: (expected[name], native.get(name)) for name in TABLES if native.get(name) != str(expected[name])}
    if differences:
        for name, (oracle, actual) in differences.items():
            print(f"{name} expected {oracle} rows, native reported {actual}")
        return 1
    print(f"{args.zip.name} all {len(TABLES)} table counts match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
