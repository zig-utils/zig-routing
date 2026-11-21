#!/usr/bin/env python3
"""Build the Utrecht Viterbi replay and compare candidate sequences."""

import argparse
import math
from pathlib import Path


def extract(measurements, corpus):
    points = [line.split()[:2] for line in measurements.read_text().splitlines() if line.strip()]
    if len(points) < 2:
        raise ValueError("at least two measurements are required")
    traces = [points, *[points[start:start + 6] for start in range(0, len(points), 4)]]
    with corpus.open("w") as stream:
        for clock_gap in (-1, 15, 2):
            for trace in traces:
                print(4, len(trace), file=stream)
                for time, (lat, lon) in enumerate(trace):
                    print(lat, lon, -1 if clock_gap < 0 else time * clock_gap, file=stream)


def read(path):
    records = {}
    for line in path.read_text().splitlines():
        case, rank, broken, score, *states = line.split()
        key = int(case), int(rank)
        score = float(score)
        if key in records or not math.isfinite(score) or broken not in ("0", "1"):
            raise ValueError(f"invalid result {key} in {path.name}")
        records[key] = int(broken), score, tuple(map(int, states))
    return records


def compare(reference, native):
    expected, actual = read(reference), read(native)
    extra = actual.keys() - expected.keys()
    missing = expected.keys() - actual.keys()
    differing = 0
    maximum = 0.0
    for key in sorted(expected.keys() & actual.keys()):
        left_break, left_cost, left_path = expected[key]
        right_break, right_cost, right_path = actual[key]
        error = abs(left_cost - right_cost)
        maximum = max(maximum, error)
        if left_path != right_path or left_break != right_break or error > 0.001:
            differing += 1
            print(f"{key} reference break {left_break}, score {left_cost:.8f}, states {left_path}")
            print(f"     native break {right_break}, score {right_cost:.8f}, states {right_path}")
    print(f"{len(expected)} reference paths, {len(actual)} native paths, {differing} differences")
    print(f"Maximum score difference on shared ranks {maximum:.8g}")
    if missing:
        print(f"Missing paths {sorted(missing)}")
    if extra:
        print(f"Extra paths {sorted(extra)}")
    return bool(expected) and not (missing or extra or differing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    extract_cmd = commands.add_parser("extract")
    extract_cmd.add_argument("measurements", type=Path)
    extract_cmd.add_argument("corpus", type=Path)
    compare_cmd = commands.add_parser("compare")
    compare_cmd.add_argument("reference", type=Path)
    compare_cmd.add_argument("native", type=Path)
    args = parser.parse_args()
    if args.command == "extract":
        extract(args.measurements, args.corpus)
    elif not compare(args.reference, args.native):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
