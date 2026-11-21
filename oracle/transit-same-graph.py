#!/usr/bin/env python3
"""Translate Valhalla IDs and score fixed-cut transit comparisons."""

import argparse
from bisect import bisect_right
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

    road_bases = sorted((base, key, count) for key, (base, count) in bases.items() if key & 7 == 2)
    road_starts = [base for base, _, _ in road_bases]
    walk_edges = {dense: raw for raw, dense in walks.items()}
    ride_edges = {dense: raw for raw, dense in rides.items()}

    def raw_walk(edge):
        if edge in walk_edges:
            return walk_edges[edge]
        index = bisect_right(road_starts, edge) - 1
        if index >= 0:
            base, key, count = road_bases[index]
            if edge - base < count:
                return key | (edge - base) << 25
        raise ValueError(f"Invalid native edge {edge}")

    return edge_id, rides, raw_walk, ride_edges


def translate(args):
    edge_id, rides, _, _ = tile_ids(args.tiles)
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


def prepare_audit(args):
    _, _, raw_walk, ride_edges = tile_ids(args.tiles)
    with args.native.open(encoding="utf-8") as native, args.output.open("w", encoding="utf-8") as out:
        for index, row in enumerate(native):
            result = json.loads(row)
            if result["index"] != index:
                raise ValueError(f"Unexpected native case {result['index']}")
            steps = []
            for step in result.get("steps", []):
                if "trip" in step:
                    steps.append({
                        "edge": ride_edges[step["line"]], "trip": step["trip"],
                        "board_time": step["board_time"], "cost": step["cost"], "elapsed": step["elapsed"],
                    })
                else:
                    steps.append({
                        "edge": raw_walk(step["edge"]), "begin": step["begin"], "end": step["end"],
                        "cost": step["cost"], "elapsed": step["elapsed"],
                    })
            out.write(json.dumps({"index": index, "steps": steps}, separators=(",", ":")) + "\n")


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


def first_cost_difference(audit, expected):
    i = audit.get("first_cost_difference")
    if i is None:
        return None
    step = audit["steps"][i]
    delta = expected[i]["cost"] - step["cost"]
    kind = "costing"
    result = {"step": i, "expected": expected[i]["cost"], "pinned": step["cost"]}
    if "ready" in step:
        def close(value):
            return math.isclose(delta, value, rel_tol=0, abs_tol=0.01)

        if step["boarding_transition"] and close(step["boarding_transition"]):
            kind = "stock_boarding_transition"
            result["transition_cost"] = step["boarding_transition"]
        elif step["stock_second"] != step["exact_second"] and close(step["exact_second"] - step["stock_second"]):
            kind = "stock_seconds_of_week_rounding"
            result.update(exact_second=step["exact_second"], stock_second=step["stock_second"])
        elif i and close(int(audit["steps"][i - 1]["elapsed"]) - int(expected[i - 1]["elapsed"])):
            kind = "boarding_clock_accumulation"
            result.update(pinned_ready_elapsed=audit["steps"][i - 1]["elapsed"],
                          original_ready_elapsed=expected[i - 1]["elapsed"])
    result["kind"] = kind
    return result


def walking_label_witness(row, path):
    """Find a settled prefix that cannot walk the remaining verified suffix."""
    audit = row["native_audit"]
    if "cost" not in audit:
        return None
    priced = audit["steps"]
    labels = row["stock_labels"]
    last_ride = max((i for i, move in enumerate(path) if "trip" in move), default=-1)
    limit = audit["walking_limit"]
    for i in range(max(1, last_ride + 1), len(path) - 1):
        kept, previous = labels[i], labels[i - 1]
        if not kept or not previous or not kept["settled"] or not previous["settled"]:
            continue
        if kept["trip"] or kept.get("predecessor") == path[i - 1]["edge"]:
            continue
        if (previous["trip"] != path[i - 1].get("trip", 0) or
                previous["walking_distance"] != priced[i - 1]["walking_distance"]):
            continue
        if any(not math.isclose(previous[field], priced[i - 1][field], rel_tol=0, abs_tol=0.01)
               for field in ("cost", "elapsed")):
            continue
        suffix = priced[-1]["walking_distance"] - priced[i]["walking_distance"]
        if (kept["cost"] >= priced[i]["cost"] or
                kept["walking_distance"] + suffix <= limit or priced[-1]["walking_distance"] > limit):
            continue
        return {
            "step": i, "edge": path[i]["edge"],
            "stock_label": kept, "native_label": priced[i],
            "native_predecessor": path[i - 1]["edge"],
            "remaining_walk": suffix, "walking_limit": limit,
        }
    return None


def score_audit(args):
    totals = Counter()
    details = []
    with args.oracle.open(encoding="utf-8") as oracle, args.native.open(encoding="utf-8") as native, \
            args.paths.open(encoding="utf-8") as paths:
        for index, lines in enumerate(zip(oracle, native, paths, strict=True)):
            stock, result, raw = map(json.loads, lines)
            if any(row["index"] != index for row in (stock, result, raw)):
                raise ValueError(f"Misaligned audit case {index}")
            totals["requests"] += 1
            display_match = itinerary(stock["steps"]) == itinerary(result["steps"])
            exact_match = itinerary(stock["steps"], "board_time") == itinerary(result["steps"], "board_time")
            totals["stock_itinerary_matches"] += display_match
            totals["exact_boarding_matches"] += exact_match
            audits = stock["stock_audit"], stock["native_audit"]
            entry = {"index": index, "stock_itinerary_match": display_match, "exact_boarding_match": exact_match}
            for name, audit, original in zip(("stock", "native"), audits, (stock, result)):
                entry[name] = {k: v for k, v in audit.items() if k != "steps"}
                diagnosis = first_cost_difference(audit, original["steps"])
                if diagnosis:
                    entry[name]["first_difference"] = diagnosis
                    totals[diagnosis["kind"] if diagnosis["kind"] != "costing" else f"{name}_costing"] += 1

            if all("cost" in audit for audit in audits):
                totals["repriced_pairs"] += 1
                stock_cost, native_cost = (audit["cost"] for audit in audits)
                gap = native_cost - stock_cost
                comparison = "tie" if abs(gap) <= 0.01 else "native_cheaper" if gap < 0 else "native_miss"
                entry["comparison"] = comparison
                totals[comparison] += 1
                if audits[1].get("terminal_gate"):
                    totals["stock_full_edge_limit"] += 1
                if comparison == "native_cheaper":
                    witness = walking_label_witness(stock, raw["steps"])
                    if witness:
                        entry["stock_label_witness"] = witness
                        totals["stock_label_witnesses"] += 1
            else:
                if any("cost" not in audit and "blocked_at" not in audit for audit in audits):
                    raise ValueError(f"Missing audit result for case {index}")
                totals["diagnosed_blocked_pairs"] += 1
            details.append(entry)
    if len(details) < args.minimum:
        raise ValueError(f"Expected at least {args.minimum} itinerary audit cases")
    for key in ("native_cheaper", "native_miss", "tie", "stock_full_edge_limit",
                "stock_label_witnesses", "diagnosed_blocked_pairs"):
        totals[key] += 0
    args.output.write_text(json.dumps({"totals": totals, "cases": details}, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print(json.dumps(totals, sort_keys=True))


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
    audit = commands.add_parser("prepare-audit")
    audit.add_argument("tiles", type=Path)
    audit.add_argument("native", type=Path)
    audit.add_argument("output", type=Path)
    overtaking = commands.add_parser("fixture")
    overtaking.add_argument("directory", type=Path)
    overtaking.add_argument("date", type=date.fromisoformat)
    report = commands.add_parser("score")
    report.add_argument("reference", type=Path)
    report.add_argument("native", type=Path)
    report.add_argument("output", type=Path)
    report.add_argument("--minimum", type=int, default=100)
    audit_report = commands.add_parser("score-audit")
    audit_report.add_argument("oracle", type=Path)
    audit_report.add_argument("native", type=Path)
    audit_report.add_argument("paths", type=Path)
    audit_report.add_argument("output", type=Path)
    audit_report.add_argument("--minimum", type=int, default=100)
    check = commands.add_parser("check-fixture")
    check.add_argument("reference", type=Path)
    check.add_argument("native", type=Path)
    args = parser.parse_args()
    {"translate": translate, "prepare-audit": prepare_audit, "score": score, "score-audit": score_audit, "fixture": fixture, "check-fixture": check_fixture}[args.command](args)


if __name__ == "__main__":
    main()
