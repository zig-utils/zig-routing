#!/usr/bin/env python3
"""Compare a Valhalla tag golden with zr NDJSON, in PBF order."""

import argparse
from collections import Counter, defaultdict
import gzip
from itertools import zip_longest
import json
import sys


MISSING = object()

# The sole parser pass after tag transformation which can change a dumped field.
# See oracle/README.md for the Valhalla pass and the exact pair of Use codes.
ALLOW = {("way", "attributes.use", 9, 0)}

DEFAULT_NODE = {
    "access": 2047,
    "node_type": 0,
    "named_intersection": False,
    "traffic_signal": False,
    "forward_signal": False,
    "backward_signal": False,
    "stop_sign": False,
    "forward_stop": False,
    "backward_stop": False,
    "yield_sign": False,
    "forward_yield": False,
    "backward_yield": False,
    "minor": False,
    "direction": False,
    "tagged_access": False,
    "private_access": False,
    "cash_only_toll": False,
    "step_count": None,
    "tactile_paving": None,
}


def annotate(record):
    if record["kind"] == "node" and record.get("attributes", MISSING) is None:
        return {**record, "attributes": DEFAULT_NODE}
    return record


def differences(want, got, prefix=""):
    for key in want.keys() | got.keys():
        expected, actual = want.get(key, MISSING), got.get(key, MISSING)
        field = prefix + key
        if isinstance(expected, dict) and isinstance(actual, dict):
            yield from differences(expected, actual, field + ".")
        elif type(expected) is not type(actual) or expected != actual:
            yield field, expected, actual


def describe(value):
    return "<missing>" if value is MISSING else json.dumps(value, ensure_ascii=False)


def compare(golden, current, limit):
    compared, failures, allowed = Counter(), Counter(), Counter()
    examples = defaultdict(list)

    def report(kind, field, identifier, expected, actual):
        key = f"{kind}.{field}"
        accepted = type(expected) is int and type(actual) is int and (
            kind, field, expected, actual
        ) in ALLOW
        (allowed if accepted else failures)[key] += 1
        sample = examples[accepted, key]
        if len(sample) < limit:
            sample.append(f"{identifier}: {describe(expected)} → {describe(actual)}")

    for old, new in zip_longest(golden, current):
        expected = json.loads(old) if old is not None else None
        actual = json.loads(new) if new is not None else None
        if expected is None or actual is None:
            present = expected if actual is None else actual
            report(
                present["kind"], "record", present["id"],
                "present" if expected else MISSING, "present" if actual else MISSING,
            )
            continue
        kind, identifier = expected["kind"], expected["id"]
        if (kind, identifier) != (actual["kind"], actual["id"]):
            report(kind, "identity", identifier, f"{kind} {identifier}", f"{actual['kind']} {actual['id']}")
            continue
        compared[kind] += 1
        if (expected.get("attributes", MISSING) is None) != (actual.get("attributes", MISSING) is None):
            expected, actual = annotate(expected), annotate(actual)
        for field, before, after in differences(expected, actual):
            report(kind, field, identifier, before, after)

    for accepted, counts in ((False, failures), (True, allowed)):
        for field, count in sorted(counts.items()):
            label = "allowed" if accepted else "unexplained"
            sample = "; ".join(examples[accepted, field])
            print(f"{field}: {count} {label}" + (f" ({sample})" if sample else ""))

    print(f"{compared['node']} nodes, {compared['way']} ways, "
          f"{sum(failures.values())} unexplained differences, {sum(allowed.values())} allowed")
    return not failures and bool(compared)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("golden", help="gzip-compressed Valhalla NDJSON")
    parser.add_argument("--keep", type=int, default=8, help="first differing OSM IDs per field")
    args = parser.parse_args()
    if args.keep < 0:
        parser.error("--keep must be nonnegative")
    with gzip.open(args.golden, "rt", encoding="utf-8") as golden:
        return 0 if compare(golden, sys.stdin, args.keep) else 1


if __name__ == "__main__":
    sys.exit(main())
