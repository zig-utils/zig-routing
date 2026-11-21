#!/usr/bin/env python3
"""Translate Valhalla IDs and score fixed-cut transit comparisons."""

import argparse
from datetime import date, datetime
import json
import math
import mmap
from pathlib import Path
import struct
from collections import Counter, defaultdict

TILE_MASK = (1 << 25) - 1
INDEX_MASK = (1 << 21) - 1


def fixture(args):
    """Make two fixed departures for the Gurka transit-overtake streets."""
    feed = args.directory / "feeds" / "overtake"
    feed.mkdir(parents=True, exist_ok=True)
    ymd = args.date.strftime("%Y%m%d")
    tables = {
        "agency": "agency_id,agency_name,agency_url,agency_timezone\nA,Fixture,https://example.org/,America/New_York\n",
        "routes": "route_id,agency_id,route_short_name,route_long_name,route_type\nR,A,R,Overtaking fixture,3\n",
        "stops": (
            "stop_id,stop_name,stop_lat,stop_lon,wheelchair_boarding\n"
            "B,West platform,42.07,-71.06,1\n"
            "C,East platform,42.07,-71.035,1\n"
        ),
        "calendar": (
            "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
            f"S,1,1,1,1,1,1,1,{ymd},{ymd}\n"
        ),
        "trips": "route_id,service_id,trip_id,trip_headsign\nR,S,slow,Slow\nR,S,fast,Fast\n",
        "stop_times": (
            "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
            "slow,07:01:45,07:01:45,B,1\nslow,07:21:45,07:21:45,C,2\n"
            "fast,07:03:45,07:03:45,B,1\nfast,07:04:45,07:04:45,C,2\n"
        ),
    }
    for name, rows in tables.items():
        (feed / f"{name}.txt").write_text(rows, encoding="utf-8")
    request = {
        "locations": [
            {"lat": 42.07, "lon": -71.0603, "minimum_reachability": 0, "search_cutoff": 100},
            {"lat": 42.07, "lon": -71.0347, "minimum_reachability": 0, "search_cutoff": 100},
        ],
        "costing": "multimodal",
        "costing_options": {"pedestrian": {"transit_start_end_max_distance": 100}},
        "date_time": {"type": 1, "value": f"{args.date.isoformat()}T07:00"},
    }
    (args.directory / "overtake.tsv").write_text("/route\t" + json.dumps(request) + "\n", encoding="utf-8")


def tile_ids(tiles):
    """Mirror the importer's sorted source IDs for roads, walks and rides."""
    paths = []
    for path in tiles.rglob("*.gph"):
        with path.open("rb") as source:
            key = struct.unpack("<Q", source.read(8))[0] & TILE_MASK
        if key & 7 in (2, 3):
            paths.append((key & 7, key, path))
    next_edge = next_line = 0
    bases = {}
    walks = {}
    rides = {}
    for level, key, path in sorted(paths):
        if key in bases:
            raise ValueError(f"Duplicate tile ID {key}")
        with path.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as tile:
            header = struct.unpack_from("<10Q", tile)
            nodes, edges = header[5] & INDEX_MASK, (header[5] >> 21) & INDEX_MASK
            transitions = header[6] & ((1 << 22) - 1)
            edge_start = 272 + nodes * 32 + transitions * 8
            bases[key] = (next_edge, edges)
            if level == 2:
                for local in range(edges):
                    flags = struct.unpack_from("<Q", tile, edge_start + local * 48 + 40)[0]
                    if flags & (1 << 60):
                        raise ValueError("The paired corpus requires flat road tiles without shortcuts")
                next_edge += edges
                continue
            transit_start = edge_start + edges * (48 + (8 if header[0] >> 63 else 0))
            transit_start += (header[9] & ((1 << 24) - 1)) * 16
            departures = (header[7] >> 23) & ((1 << 24) - 1)
            line_map = {}
            for i in range(departures):
                line = struct.unpack_from("<I", tile, transit_start + 24 * i)[0] & ((1 << 20) - 1)
                if line not in line_map:
                    line_map[line] = next_line
                    next_line += 1
            for local in range(edges):
                use = (struct.unpack_from("<Q", tile, edge_start + local * 48 + 16)[0] >> 40) & 63
                edge = key | local << 25
                if use in (50, 51):
                    line = struct.unpack_from("<I", tile, edge_start + local * 48 + 40)[0]
                    rides[edge] = line_map[line]
                else:
                    walks[edge] = next_edge
                    next_edge += 1

    def edge_id(edge):
        key = edge & TILE_MASK
        base, count = bases[key]
        local = edge >> 25
        if local >= count:
            raise ValueError(f"Invalid Valhalla edge ID {edge}")
        return base + local if key & 7 == 2 else walks[edge]

    return edge_id, rides


def translate(args):
    edge_id, rides = tile_ids(args.tiles)
    with args.reference.open(encoding="utf-8") as reference, args.output.open("w", encoding="utf-8") as out:
        for index, row in enumerate(reference):
            result = json.loads(row)
            if result["index"] != index:
                raise ValueError(f"Unexpected reference case {result['index']}")
            for location in result.get("cuts", []):
                for group in ("edges", "filtered"):
                    for cut in location[group]:
                        cut["edge"] = edge_id(cut["edge"])
            for step in result.get("steps", []):
                raw = step["edge"]
                if "trip" in step:
                    step["line"] = rides[raw]
                    del step["edge"]
                else:
                    step["edge"] = edge_id(raw)
            out.write(json.dumps(result, separators=(",", ":")) + "\n")


def itinerary(steps, boarding="board"):
    """Group adjacent rides on the same trip into an ordered stop sequence."""
    result = []
    prior_trip = None
    for step in steps:
        if "trip" not in step:
            prior_trip = None
            continue
        if prior_trip == step["trip"] and result[-1]["route"] == step["route"]:
            result[-1]["stops"].append(step["destination"])
        else:
            result.append({
                "route": step["route"],
                "stops": [step["origin"], step["destination"]],
                "board": step.get(boarding),
            })
        prior_trip = step["trip"]
    return result


def score(args):
    counts = Counter()
    failure_codes = defaultdict(Counter)
    differences = []
    with args.reference.open(encoding="utf-8") as oracle, args.native.open(encoding="utf-8") as native:
        for index, rows in enumerate(zip(oracle, native, strict=True)):
            a, b = map(json.loads, rows)
            if a["index"] != index or b["index"] != index:
                raise ValueError(f"Misaligned result at {index}")
            counts["requests"] += 1
            counts["fixed_cut_requests"] += len(a.get("cuts", [])) == 2
            counts["directed_cuts"] += sum(len(cut["edges"]) + len(cut["filtered"]) for cut in a.get("cuts", []))
            for name, row in (("oracle", a), ("native", b)):
                if "steps" in row:
                    counts[f"{name}_routes"] += 1
                else:
                    failure_codes[name][str(row.get("error_code", row.get("failure")))] += 1
            expected = itinerary(a["steps"]) if "steps" in a else None
            actual = itinerary(b["steps"]) if "steps" in b else None
            if expected is not None and actual is not None:
                counts["matching_itineraries"] += expected == actual
                counts["matching_ordered_stops"] += [r["stops"] for r in expected] == [r["stops"] for r in actual]
                counts["matching_exact_itineraries"] += itinerary(a["steps"], "board_time") == itinerary(b["steps"], "board_time")
            if actual is not None:
                own_recost = b.get("native_recost", {})
                if "cost" not in own_recost or not math.isclose(b["cost"], own_recost["cost"], abs_tol=0.01):
                    raise ValueError(f"Native fixed path did not reproduce its search cost in case {index}")
            if expected != actual:
                recost = b.get("oracle_recost")
                if expected is not None and (recost is None or "failure" in recost):
                    counts["oracle_path_reprice_errors"] += 1
                if recost is not None:
                    counts["oracle_paths_repriced"] += "cost" in recost
                    counts["oracle_paths_blocked"] += "blocked_at" in recost
                    if "blocked_at" in recost:
                        step = a["steps"][recost["blocked_at"]]
                        counts["oracle_paths_blocked_at_boarding" if "trip" in step else "oracle_paths_blocked_on_street"] += 1
                    if "cost" in recost and "cost" in b:
                        counts["native_path_cheaper_at_native_cost"] += b["cost"] < recost["cost"] - 0.01
                        counts["oracle_path_cheaper_at_native_cost"] += recost["cost"] < b["cost"] - 0.01
                differences.append({
                    "index": index,
                    "oracle": expected,
                    "native": actual,
                    "oracle_cost": a.get("cost"),
                    "native_cost": b.get("cost"),
                    "oracle_path_at_native_cost": recost,
                    "native_path_at_native_cost": b.get("native_recost"),
                })
    if counts["requests"] < args.minimum:
        raise ValueError(f"Expected at least {args.minimum} cases")
    output = {
        **counts,
        "failure_codes": failure_codes,
        "itinerary_equality": counts["matching_itineraries"] / counts["oracle_routes"] if counts["oracle_routes"] else 0.0,
        "differences": differences,
    }
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    del output["differences"]
    print(json.dumps(output, sort_keys=True))


def check_fixture(args):
    reference = json.loads(args.reference.read_text(encoding="utf-8"))
    native = json.loads(args.native.read_text(encoding="utf-8"))
    result = {}
    timetable = None
    for name, row in (("oracle", reference), ("native", native)):
        first, later = row["offers"]
        departures = [(o["trip"], o["start"], o["duration"]) for o in row["offers"]]
        if timetable is not None and departures != timetable:
            raise ValueError("Fixture departure identities differ")
        timetable = departures
        if not (first["start"] < later["start"] and later["start"] + later["duration"] < first["start"] + first["duration"]):
            raise ValueError("The later departure should arrive first")
        if later["cost"] >= first["cost"]:
            raise ValueError(f"The later departure should cost less in {name}")
        ride, = [step for step in row["steps"] if "trip" in step]
        selected = ride["trip"]
        expected = first if name == "oracle" else later
        if selected != expected["trip"] or not math.isclose(row["cost"], expected["cost"], abs_tol=0.01):
            raise ValueError(f"Unexpected itinerary selection in {name}")
        displayed = datetime.fromisoformat(ride["board"])
        if int(displayed.timestamp()) // 60 != ride["board_time"] // 60 + 1:
            raise ValueError(f"Expected distinct timetable and display minutes in {name}")
        result[name] = {"first_offered": first, "lowest_cost": later, "selected_trip": selected}
    print(json.dumps(result, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    cuts = commands.add_parser("translate")
    cuts.add_argument("tiles", type=Path)
    cuts.add_argument("reference", type=Path)
    cuts.add_argument("output", type=Path)
    overtaking = commands.add_parser("fixture")
    overtaking.add_argument("directory", type=Path)
    overtaking.add_argument("date", type=date.fromisoformat)
    report = commands.add_parser("score")
    report.add_argument("reference", type=Path)
    report.add_argument("native", type=Path)
    report.add_argument("output", type=Path)
    report.add_argument("--minimum", type=int, default=100)
    check = commands.add_parser("check-fixture")
    check.add_argument("reference", type=Path)
    check.add_argument("native", type=Path)
    args = parser.parse_args()
    {"translate": translate, "score": score, "fixture": fixture, "check-fixture": check_fixture}[args.command](args)


if __name__ == "__main__":
    main()
