#!/usr/bin/env python3
"""Check Brockton transit tile coverage and time the native HTTP action."""
import argparse
from collections import Counter
import json
import random
from time import perf_counter_ns
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def send(url, payload, get=False):
    endpoint = url.rstrip("/") + "/transit_available"
    document = json.dumps(payload, separators=(",", ":"))
    if get:
        request = Request(endpoint + "?" + urlencode({"json": document}))
    else:
        request = Request(endpoint, document.encode(), {"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=10) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


def check_equal(oracle, native, payload, get=False):
    expected = send(oracle, payload, get=get)
    actual = send(native, payload, get=get)
    if actual != expected:
        if actual[0] == expected[0] == 200:
            indices = [i for i, (a, b) in enumerate(zip(json.loads(actual[1]), json.loads(expected[1]))) if a != b]
            raise AssertionError(f"Response differs at location indexes {indices[:10]} or in JSON formatting")
        raise AssertionError(f"Expected {expected!r}, received {actual!r}")
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle_url")
    parser.add_argument("native_url")
    parser.add_argument("road_only_url")
    args = parser.parse_args()
    edge_cases = [
        {"lat": 42.0803851, "lon": -71.0390241},
        {"lat": 42.24, "lon": -71.249999, "radius": 0},
        {"lat": 42.24, "lon": -71.250001, "radius": 0},
        {"lat": 42.24, "lon": -71.250001, "radius": 1},
        {"lat": 41.99, "lon": -71.1, "radius": 0},
        {"lat": 41.99, "lon": -71.1, "radius": 2000},
        {"lat": 0, "lon": 0, "radius": 20},
        {"lat": 90, "lon": 180, "radius": 2000},
        {"lat": 0, "lon": -179.99, "radius": 2000},
        {"lat": 0, "lon": 179.99, "radius": 2000},
        *({"lat": 42.1, "lon": -71.1, "radius": radius} for radius in (-1, -1.6, 2.6, "-1", "2.6", 4294967296, 4294967295, 1e25, True, None)),
    ]
    check_equal(args.oracle_url, args.native_url, {"locations": edge_cases}, get=True)
    for invalid in ({}, {"locations": []}, {"locations": [{"lat": 91, "lon": 0}]}, {"locations": [{"lat": 0}]}):
        check_equal(args.oracle_url, args.native_url, invalid)

    rng = random.Random(193)
    locations = edge_cases + [
        {"lat": rng.uniform(41.7, 42.6), "lon": rng.uniform(-71.6, -70.5), "radius": rng.choice([0, 1, 25, 500, 2000, 10000, 50000])}
        for _ in range(1000)
    ]
    payload = {"locations": locations}
    status, expected = check_equal(args.oracle_url, args.native_url, payload)
    assert status == 200
    native = json.loads(expected)
    counts = Counter(row["istransit"] for row in native)
    assert counts[True] and counts[False]
    road_status, road_response = send(args.road_only_url, payload)
    assert road_status == 200
    assert json.loads(road_response) == [{**row, "istransit": False} for row in native]

    document = json.dumps(payload, separators=(",", ":")).encode()
    request = Request(args.native_url.rstrip("/") + "/transit_available", document, {"Content-Type": "application/json"})
    timings = []
    for _ in range(25):
        start = perf_counter_ns()
        with urlopen(request, timeout=10) as response:
            assert response.read() == expected
        timings.append((perf_counter_ns() - start) / len(locations))
    timings.sort()
    worst = timings[-1]
    print(f"{len(locations)} byte-identical locations ({counts[True]} served, {counts[False]} unserved), {len(locations)} road-only false")
    print(f"HTTP time per location over 25 batches: median {timings[len(timings) // 2]:.0f} ns, max {worst:.0f} ns")
    if worst >= 1_000_000:
        raise SystemExit("Exceeded 1 ms per location")


if __name__ == "__main__":
    main()
