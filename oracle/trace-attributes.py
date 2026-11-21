#!/usr/bin/env python3
"""Replay trace attributes on one imported Valhalla tile and compare the wire data."""

import argparse
import http.client
import json
from pathlib import Path
from urllib.parse import urlsplit


FILTER = (
    "edge.id", "edge.way_id", "edge.names", "edge.length", "edge.speed",
    "edge.road_class", "edge.begin_shape_index", "edge.end_shape_index",
    "edge.use", "edge.traversability", "node.elapsed_time", "matched.point",
    "matched.type", "matched.edge_index", "matched.begin_route_discontinuity",
    "matched.end_route_discontinuity", "shape_attributes.time", "shape",
)
ENUMS = {
    "units", "use", "road_class", "traversability", "type", "surface",
    "sidewalk", "cycle_lane", "speed_type", "travel_mode", "vehicle_type",
    "pedestrian_type", "bicycle_type", "hov_type", "driveability",
    "walkability", "cyclability",
}


def prepare(source, output):
    rows = iter(source.read_text().splitlines())
    with output.open("w") as corpus:
        for case, header in enumerate(rows):
            _, count = map(int, header.split())
            shape = []
            for _ in range(count):
                lat, lon, timestamp = map(float, next(rows).split())
                point = {"lat": lat, "lon": lon}
                if timestamp >= 0:
                    point["time"] = timestamp
                shape.append(point)
            request = {
                "id": f"trace-{case}",
                "shape": shape,
                "costing": "auto",
                "shape_match": "map_snap",
                "trace_options": {"turn_penalty_factor": 200},
            }
            print("/trace_attributes", json.dumps(request, separators=(",", ":")),
                  sep="\t", file=corpus)


class Endpoint:
    def __init__(self, url):
        base = urlsplit(url)
        if base.scheme not in {"http", "https"} or not base.hostname:
            raise ValueError("expected an HTTP or HTTPS service URL")
        transport = (http.client.HTTPSConnection if base.scheme == "https"
                     else http.client.HTTPConnection)
        self.connection = transport(base.hostname, base.port, timeout=30)
        self.path = base.path.rstrip("/") + "/trace_attributes"

    def send(self, request):
        content = json.dumps(request, separators=(",", ":"))
        self.connection.request("POST", self.path, content, {"Content-Type": "application/json"})
        response = self.connection.getresponse()
        return response.status, json.loads(response.read())


def schema_diff(expected, actual, pointer=""):
    number = (int, float)
    if type(expected) is not type(actual):
        if type(expected) in number and type(actual) in number:
            return None
        return f"{pointer}: {type(expected).__name__} vs {type(actual).__name__}"
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            return f"{pointer}: differing keys {sorted(expected.keys() ^ actual.keys())}"
        for key in expected:
            diff = schema_diff(expected[key], actual[key], f"{pointer}/{key}")
            if diff:
                return diff
    elif isinstance(expected, list):
        for index, (left, right) in enumerate(zip(expected, actual)):
            diff = schema_diff(left, right, f"{pointer}/{index}")
            if diff:
                return diff
    elif isinstance(expected, str) and pointer.rsplit("/", 1)[-1] in ENUMS and expected != actual:
        return f"{pointer}: {expected!r} vs {actual!r}"
    return None


def edge_ids(result, reference):
    # The oracle contains one tile with no shortcuts. Import preserves its
    # local edge order, and GraphId's tile and level occupy the low 25 bits.
    return [edge["id"] >> 25 if reference else edge["id"] for edge in result["edges"]]


def replay(oracle, native, corpus, output):
    endpoints = Endpoint(oracle), Endpoint(native)
    matched = 0
    divergent = 0
    edges = 0
    checks = 0
    failures = 0
    with output.open("w") as evidence:
        def send(request, variant):
            left, right = (service.send(request) for service in endpoints)
            print(json.dumps({"request": request, "variant": variant, "oracle": left, "native": right}),
                  file=evidence)
            return left, right

        for row in corpus.read_text().splitlines():
            _, request = row.split("\t", 1)
            request = json.loads(request)
            case = request["id"]
            left, right = send(request, "default")
            checks += 1
            if left[0] != right[0]:
                print(f"{case}: status {left[0]} vs {right[0]}")
                failures += 1
                continue
            if left[0] == 200 and edge_ids(left[1], True) != edge_ids(right[1], False):
                divergent += 1
                print(f"{case}: primary directed edges differ")
                continue
            if left[0] == 200:
                matched += 1
                for index, (expected, actual) in enumerate(zip(left[1]["edges"], right[1]["edges"])):
                    edges += 1
                    expected_values = {k: v for k, v in expected.items() if k not in {"id", "end_node"}}
                    actual_values = {k: v for k, v in actual.items() if k not in {"id", "end_node"}}
                    if expected_values != actual_values:
                        print(f"{case}/default: edge {index} attributes differ")
                        failures += 1
            diff = schema_diff(left[1], right[1])
            if diff or (left[0] != 200 and left[1].get("error_code") != right[1].get("error_code")):
                print(f"{case}/default: {diff or 'error codes differ'}")
                failures += 1
            if left[0] != 200:
                continue
            for variant in ("include", "exclude"):
                filtered = dict(request, filters={"action": variant, "attributes": FILTER})
                left, right = send(filtered, variant)
                checks += 1
                diff = schema_diff(left[1], right[1])
                if left[0] != 200 or right[0] != 200 or diff:
                    failures += 1
                    print(f"{case}/{variant}: {left[0]} vs {right[0]} {diff or ''}")

    print(f"{matched} aligned primary paths and {edges} directed edges, {divergent} divergent paths")
    print(f"{checks - divergent} schema/status checks, {failures} failures")
    return matched > 0 and failures == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("traces", type=Path)
    prepare_parser.add_argument("corpus", type=Path)
    replay_parser = commands.add_parser("replay")
    replay_parser.add_argument("oracle")
    replay_parser.add_argument("native")
    replay_parser.add_argument("corpus", type=Path)
    replay_parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.traces, args.corpus)
    elif not replay(args.oracle, args.native, args.corpus, args.output):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
