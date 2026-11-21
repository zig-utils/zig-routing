#!/usr/bin/env python3
"""Replay trace attributes on one imported Valhalla tile and compare the wire data."""

import argparse
import http.client
import json
import struct
from collections import defaultdict
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


def ranked_results(response, reference):
    status, body = response
    if status != 200:
        return {"status": status, "error": body.get("error_code")}
    paths = (body, *body.get("alternate_paths", ()))
    return {
        "status": status,
        "paths": [
            {"edges": edge_ids(path, reference), "raw": path["raw_score"],
             "confidence": path["confidence_score"]}
            for path in paths
        ],
    }


def printed_scores_agree(left, right):
    return all(
        a == b or (a is not None and b is not None and abs(a - b) <= 0.001001)
        for a, b in ((left["raw"], right["raw"]), (left["confidence"], right["confidence"]))
    )


def replay_ranks(oracle, native, corpus, output, alternates):
    endpoints = Endpoint(oracle), Endpoint(native)
    cases = 0
    rank_counts = [0, 0]
    same_edges = 0
    same_scores = 0
    alias_errors = 0
    primary_errors = [0, 0]
    with output.open("w") as evidence:
        for row in corpus.read_text().splitlines():
            _, request = row.split("\t", 1)
            request = json.loads(request)
            request.pop("best_paths", None)
            request.pop("alternates", None)
            modern = dict(request, alternates=alternates)
            legacy = dict(request, best_paths=alternates + 1)
            record = {"request": request}
            for index, (name, endpoint) in enumerate(zip(("oracle", "native"), endpoints)):
                response = endpoint.send(modern)
                deprecated = endpoint.send(legacy)
                ranks = ranked_results(response, index == 0)
                alias = ranked_results(deprecated, index == 0)
                if ranks != alias:
                    alias_errors += 1
                    print(f"{request['id']}/{name}: alternate request aliases differ")
                if response[0] == 200 and (
                    any(w["code"] == 103 for w in response[1].get("warnings", ()))
                    or not any(w["code"] == 103 for w in deprecated[1].get("warnings", ()))
                ):
                    alias_errors += 1
                    print(f"{request['id']}/{name}: unexpected best_paths deprecation warning")
                record[name] = ranks
                record[name + "_legacy"] = alias
                primary = ranked_results(endpoint.send(request), index == 0)
                record[name + "_primary"] = primary
                if ranks.get("error") != 153 and ranks.get("paths", [])[:1] != primary.get("paths", []):
                    primary_errors[index] += 1
                    print(f"{request['id']}/{name}: requesting alternates changed the primary result")
                rank_counts[index] += len(ranks.get("paths", ()))
            for left, right in zip(record["oracle"].get("paths", ()), record["native"].get("paths", ())):
                if left["edges"] != right["edges"]:
                    continue
                same_edges += 1
                same_scores += printed_scores_agree(left, right)
            cases += 1
            print(json.dumps(record, separators=(",", ":")), file=evidence)

    print(f"{cases} traces, {rank_counts[0]} oracle and {rank_counts[1]} native ranked results")
    print(f"{same_edges} paired ranks on the same directed edges, {same_scores} also matching scores")
    print(f"{alias_errors} differences between alternates and best_paths")
    print(f"{primary_errors[0]} oracle and {primary_errors[1]} native primary changes")
    return cases > 0 and alias_errors == primary_errors[1] == 0


def float32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def compare_rank_audit(evidence, directed):
    audited = defaultdict(list)
    with directed.open() as rows:
        for row in rows:
            case, rank, _, score, *fields = row.rstrip("\n").split("\t")
            paths = audited[int(case)]
            if int(rank) != len(paths):
                raise ValueError(f"out-of-order directed rank in trace {case}")
            edges = [int(field.split(",", 1)[0]) for field in fields if not field.startswith("state=")]
            paths.append({"edges": edges, "raw": float32(float(score))})

    directed_paths = 0
    stock_paths = 0
    differences = 0
    with evidence.open() as records:
        for case, row in enumerate(records):
            record = json.loads(row)
            if record["native"].get("error") == 153:
                continue
            native = record["native"].get("paths", ())
            stock = record["oracle"].get("paths", ())
            paths = audited[case]
            if len(native) != len(paths):
                print(f"trace {case}: {len(native)} native ranks, {len(paths)} directed ranks")
                differences += 1
            for rank, (observed, expected) in enumerate(zip(native, paths)):
                expected["confidence"] = None
                if rank == 0:
                    expected["confidence"] = 1.0
                elif expected["raw"]:
                    expected["confidence"] = float32(paths[0]["raw"] / expected["raw"])
                if observed["edges"] == expected["edges"] and printed_scores_agree(observed, expected):
                    directed_paths += 1
                elif rank < len(stock) and observed == stock[rank]:
                    stock_paths += 1
                    print(f"trace {case}, rank {rank}: matches stock with a different directed audit result")
                else:
                    differences += 1
                    print(f"trace {case}, rank {rank}: differs from the directed audit and stock")
    print(f"{directed_paths} directed matches, {stock_paths} stock matches, {differences} unmatched results")
    return directed_paths > 0 and differences == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("traces", type=Path)
    prepare_parser.add_argument("corpus", type=Path)
    for command in ("replay", "replay-ranks"):
        replay_parser = commands.add_parser(command)
        replay_parser.add_argument("oracle")
        replay_parser.add_argument("native")
        replay_parser.add_argument("corpus", type=Path)
        replay_parser.add_argument("output", type=Path)
        if command == "replay-ranks":
            replay_parser.add_argument("--alternates", type=int, default=3)
    audit_parser = commands.add_parser("compare-rank-audit")
    audit_parser.add_argument("evidence", type=Path)
    audit_parser.add_argument("directed", type=Path)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.traces, args.corpus)
    elif args.command == "replay-ranks":
        if args.alternates < 0:
            parser.error("--alternates must be nonnegative")
        if not replay_ranks(args.oracle, args.native, args.corpus, args.output, args.alternates):
            raise SystemExit(1)
    elif args.command == "compare-rank-audit":
        if not compare_rank_audit(args.evidence, args.directed):
            raise SystemExit(1)
    elif not replay(args.oracle, args.native, args.corpus, args.output):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
