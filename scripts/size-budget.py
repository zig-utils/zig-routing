#!/usr/bin/env python3
"""Count emitted search and costing types in a symbol-bearing zr executable."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


METRICS = ("binary_bytes", "search_instantiations", "costing_kernels")
TEXT_SYMBOL = re.compile(r"^\s*[0-9a-fA-F]+\s+[tTwW]\s+(.+)$")
SEARCH = re.compile(r"(?:^|\.)search\.Search(?=\()")
KERNEL = re.compile(r"(?:^|\.)Kernel(?=[.(])")
COST_ENTRY_POINTS = {"edgeCost", "turnCost", "slowAllowed"}


def type_end(symbol, start):
    """Find the member separator after a type, including nested generics."""
    if symbol[start] != "(":
        return start
    depth = 0
    for index in range(start, len(symbol)):
        if symbol[index] == "(":
            depth += 1
        elif symbol[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError(f"unbalanced Zig symbol {symbol!r}")


def measure(binary, nm):
    listing = subprocess.run(
        [nm, "--defined-only", "--format=bsd", str(binary)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout
    searches = set()
    kernels = set()
    saw_code = False
    for line in listing.splitlines():
        match = TEXT_SYMBOL.fullmatch(line)
        if match is None:
            continue
        saw_code = True
        symbol = match.group(1).removeprefix("_")
        search = SEARCH.search(symbol)
        if search:
            end = type_end(symbol, search.end())
            if symbol[end:].startswith("."):
                searches.add(symbol[:end])
            continue
        kernel = KERNEL.search(symbol)
        if kernel:
            end = type_end(symbol, kernel.end())
            member = symbol[end + 1 :].split(".", 1)[0].split("__anon_", 1)[0]
            if symbol[end:].startswith(".") and member in COST_ENTRY_POINTS:
                kernels.add(symbol[:end])
    if not saw_code:
        raise ValueError(f"{binary} has no text symbols")
    return {
        "binary_bytes": binary.stat().st_size,
        "search_instantiations": len(searches),
        "costing_kernels": len(kernels),
    }, sorted(searches | kernels)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--budget", type=Path, default=Path("bench/budgets/binary.json"))
    parser.add_argument("--nm", default="nm")
    args = parser.parse_args()
    try:
        limits = json.loads(args.budget.read_text())
        if not isinstance(limits, dict) or set(limits) != set(METRICS) or any(
            type(limit) is not int or limit < 0 for limit in limits.values()
        ):
            raise ValueError("the budget must specify a nonnegative integer for each metric")
        current, types = measure(args.binary, args.nm)
        baseline, _ = measure(args.base, args.nm) if args.base else (None, [])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot measure binary budget: {error}", file=sys.stderr)
        return 2

    exceeded = False
    for name in METRICS:
        value, limit = current[name], limits[name]
        delta = f", {value - baseline[name]:+,} vs base" if baseline is not None else ""
        status = " OVER BUDGET" if value > limit else ""
        print(f"{name} {value:,} (limit {limit:,}{delta}){status}")
        exceeded |= value > limit
    for name in types:
        print(f"  {name}")
    return int(exceeded)


if __name__ == "__main__":
    sys.exit(main())
