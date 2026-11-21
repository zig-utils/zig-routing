#!/usr/bin/env python3
"""Build trace columns and compare instrumented Valhalla 3.9.3 costs."""

import argparse
from math import isfinite
from pathlib import Path
import sys


FIELDS = ("source emission", "target emission", "distance", "seconds", "turn cost", "transition")
TOLERANCE = 1e-4


def extract(measurements, corpus):
    rows = [line.split()[:2] for line in measurements.read_text().splitlines() if line.strip()]
    with corpus.open("w") as stream:
        for first, second in zip(rows, rows[1:]):
            for seconds in ("-1", "15", "2"):
                stream.write("\t".join(first + second + ["35", seconds]) + "\n")


def read(path):
    rows = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        key = tuple(map(int, fields[:3]))
        values = tuple(map(float, fields[3:9]))
        if len(values) != len(FIELDS) or not all(map(isfinite, values)) or key in rows:
            raise ValueError(f"{path.name} contains an invalid candidate pair {key}")
        path_edges = fields[9] if len(fields) == 10 else ""
        rows[key] = values, path_edges
    return rows


def compare(oracle, native):
    expected, actual = read(oracle), read(native)
    if expected.keys() != actual.keys():
        print(f"Missing candidate pairs {sorted(expected.keys() - actual.keys())[:10]}")
        print(f"Extra candidate pairs {sorted(actual.keys() - expected.keys())[:10]}")
        return False
    maxima = [0.0] * len(FIELDS)
    differences = reachable = 0
    for key, (left, left_path) in expected.items():
        right, right_path = actual[key]
        reachable += left[2] >= 0
        failures = []
        for index, (a, b) in enumerate(zip(left, right, strict=True)):
            error = abs(a - b)
            maxima[index] = max(maxima[index], error)
            if error > TOLERANCE:
                failures.append(f"{FIELDS[index]} {a:.8g} vs {b:.8g}")
        if failures:
            differences += 1
            if differences <= 10:
                print(f"{key} {', '.join(failures)}")
                print(f"    oracle edges {left_path}, native edges {right_path}")
    print(f"{len(expected)} candidate pairs, {reachable} reachable, {differences} differences")
    print("Maximum absolute errors " + ", ".join(f"{name} {error:.6g}" for name, error in zip(FIELDS, maxima)))
    return bool(reachable) and differences == 0


def audit(oracle, native, directed):
    stock, actual, exact = read(oracle), read(native), read(directed)
    if stock.keys() != actual.keys():
        print("The stock and native probes emitted different candidate pairs")
        return False
    divergences = {
        key for key, (values, _) in stock.items()
        if any(abs(a - b) > TOLERANCE for a, b in zip(values, actual[key][0], strict=True))
    }
    missing = divergences - exact.keys()
    extra = exact.keys() - actual.keys()
    if missing or extra:
        print(f"Missing directed checks {sorted(missing)[:10]}")
        print(f"Unexpected directed checks {sorted(extra)[:10]}")
        return False

    maxima = [0.0] * len(FIELDS)
    passed = 0
    for key, (values, path) in exact.items():
        native_values, native_path = actual[key]
        errors = [abs(a - b) for a, b in zip(values, native_values, strict=True)]
        maxima = list(map(max, maxima, errors))
        if max(errors) <= TOLERANCE and path == native_path:
            passed += 1
        else:
            print(f"{key} directed {values} {path}, native {native_values} {native_path}")

    print(f"{len(stock)} stock pairs, {len(divergences)} stock divergences")
    print(f"{passed}/{len(exact)} directed checks matched the native paths and metrics")
    print("Maximum directed absolute errors " + ", ".join(f"{name} {error:.6g}" for name, error in zip(FIELDS, maxima)))
    return bool(exact) and passed == len(exact)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    extract_cmd = commands.add_parser("extract")
    extract_cmd.add_argument("measurements", type=Path)
    extract_cmd.add_argument("corpus", type=Path)
    compare_cmd = commands.add_parser("compare")
    compare_cmd.add_argument("oracle", type=Path)
    compare_cmd.add_argument("native", type=Path)
    audit_cmd = commands.add_parser("audit")
    audit_cmd.add_argument("oracle", type=Path)
    audit_cmd.add_argument("native", type=Path)
    audit_cmd.add_argument("directed", type=Path)
    args = parser.parse_args()
    if args.command == "extract":
        extract(args.measurements, args.corpus)
    elif args.command == "compare" and not compare(args.oracle, args.native):
        sys.exit(1)
    elif args.command == "audit" and not audit(args.oracle, args.native, args.directed):
        sys.exit(1)


if __name__ == "__main__":
    main()
