#!/usr/bin/env python3
"""Generate and score a repeatable timetable corpus for a one-feed bundle."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import date, datetime, timedelta
import io
import json
import math
from pathlib import Path
import random
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from zipfile import ZipFile


def rows(feed, table):
    with feed.open(f"{table}.txt") as source:
        yield from csv.DictReader(io.TextIOWrapper(source, encoding="utf-8-sig", newline=""))


def prepare(args):
    weekday = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")[args.date.weekday()]
    service_day = args.date.strftime("%Y%m%d")
    with ZipFile(args.feed) as feed:
        stops = {r["stop_id"]: {"lat": float(r["stop_lat"]), "lon": float(r["stop_lon"])} for r in rows(feed, "stops")}
        services = set()
        if "calendar.txt" in feed.namelist():
            for row in rows(feed, "calendar"):
                if row[weekday] == "1" and row["start_date"] <= service_day <= row["end_date"]:
                    services.add(row["service_id"])
        if "calendar_dates.txt" in feed.namelist():
            for row in rows(feed, "calendar_dates"):
                if row["date"] == service_day:
                    update = services.add if row["exception_type"] == "1" else services.discard
                    update(row["service_id"])
        trips = {r["trip_id"] for r in rows(feed, "trips") if r["service_id"] in services}
        stops_by_trip = defaultdict(list)
        for row in rows(feed, "stop_times"):
            if row["trip_id"] in trips and row["departure_time"]:
                stops_by_trip[row["trip_id"]].append(row)

    rng = random.Random(190)
    order = sorted(stops_by_trip)
    rng.shuffle(order)
    count = 0
    with args.output.open("w", encoding="utf-8") as output:
        for trip in order:
            stop_times = sorted(stops_by_trip[trip], key=lambda row: int(row["stop_sequence"]))
            if len(stop_times) < 16:
                continue
            first = rng.randrange(min(12, len(stop_times) - 15))
            last = rng.randrange(first + 15, len(stop_times))
            origin, destination = (stops[stop_times[i]["stop_id"]] for i in (first, last))
            north = (origin["lat"] - destination["lat"]) * 111000
            east = (origin["lon"] - destination["lon"]) * 82000
            if math.hypot(north, east) < 2700:
                continue
            hour, minute, second = map(int, stop_times[first]["departure_time"].split(":"))
            if not 5 <= hour <= 23:
                continue
            boarding = datetime.combine(args.date, datetime.min.time()).replace(hour=hour, minute=minute, second=second)
            at = boarding - timedelta(minutes=rng.randint(3, 12))
            request = {
                "locations": [origin, destination],
                "costing": rng.choice(["transit", "multimodal"]),
                "date_time": {"type": 1, "value": at.strftime("%Y-%m-%dT%H:%M")},
            }
            if args.short_walk:
                request["costing_options"] = {
                    "pedestrian": {"transit_start_end_max_distance": 300, "transit_transfer_max_distance": 150},
                    "transit": {"use_bus": 0.6, "use_rail": 0.6},
                }
            output.write("/route\t" + json.dumps(request, separators=(",", ":")) + "\n")
            count += 1
            if count == args.count:
                break
    if count != args.count:
        raise SystemExit(f"Generated {count} of {args.count} requests")


def fetch(args):
    def request(row):
        path, payload = row.split("\t", 1)
        query = Request(args.url.rstrip("/") + path, payload.encode(), {"Content-Type": "application/json"})
        try:
            with urlopen(query, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            return json.load(error)

    with args.corpus.open(encoding="utf-8") as corpus, args.output.open("w", encoding="utf-8") as output:
        with ThreadPoolExecutor(4) as workers:
            for response in workers.map(request, corpus):
                output.write(json.dumps(response, separators=(",", ":")) + "\n")


def oracle_itinerary(result, feed):
    rides = []
    for leg in result["trip"]["legs"]:
        for maneuver in leg["maneuvers"]:
            info = maneuver.get("transit_info")
            if not info:
                continue
            stops = info["transit_stops"]
            ids = tuple(stop["onestop_id"].removeprefix(feed + "_").removesuffix("_transit_station") for stop in stops)
            rides.append((info["onestop_id"].removeprefix(feed + "_"), ids, datetime.fromisoformat(stops[0]["departure_date_time"])))
    return rides


def native_itinerary(result):
    rides = []
    for leg in result["legs"]:
        nodes = leg["node"]
        previous_trip = None
        for node, following in zip(nodes, nodes[1:]):
            info = node.get("edge", {}).get("transit_route_info")
            if not info:
                previous_trip = None
                continue
            route = info["onestop_id"].split(":", 3)[-1]
            origin = node["transit_platform_info"]
            target = following["transit_platform_info"]
            start = origin["onestop_id"].split(":", 3)[-1]
            end = target["onestop_id"].split(":", 3)[-1]
            trip = info["trip_id"]
            if previous_trip == trip and rides[-1][0] == route and rides[-1][1][-1] == start:
                rides[-1] = (route, (*rides[-1][1], end), rides[-1][2])
            else:
                rides.append((route, (start, end), datetime.fromisoformat(origin["departure_date_time"])))
            previous_trip = trip
    return rides


def score(args):
    counters = Counter()
    with args.oracle.open(encoding="utf-8") as oracle, args.native.open(encoding="utf-8") as native:
        for index, (reference_row, native_row) in enumerate(zip(oracle, native, strict=True)):
            reference, candidate = json.loads(reference_row), json.loads(native_row)
            if candidate["index"] != index:
                raise ValueError(f"Expected native case {index}, received {candidate['index']}")
            counters["requests"] += 1
            if "error_code" in reference:
                counters["oracle_errors"] += 1
                counters["matching_errors"] += candidate.get("error_code") == reference["error_code"]
                continue
            expected = oracle_itinerary(reference, args.feed_name)
            counters["oracle_itineraries"] += 1
            if "legs" not in candidate:
                counters["native_errors"] += 1
                continue
            actual = native_itinerary(candidate)
            counters["matching_lines"] += [ride[0] for ride in actual] == [ride[0] for ride in expected]
            counters["matching_lines_and_stops"] += [ride[:2] for ride in actual] == [ride[:2] for ride in expected]
            counters["matching_itineraries"] += actual == expected
    total = counters["oracle_itineraries"]
    fraction = counters["matching_itineraries"] / total if total else 0
    print(json.dumps({**counters, "itinerary_equality": fraction, "required": args.required}, sort_keys=True))
    if fraction < args.required:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    corpus = commands.add_parser("prepare")
    corpus.add_argument("feed", type=Path)
    corpus.add_argument("date", type=date.fromisoformat)
    corpus.add_argument("output", type=Path)
    corpus.add_argument("--count", type=int, default=100)
    corpus.add_argument("--short-walk", action="store_true")
    replay = commands.add_parser("fetch")
    replay.add_argument("url")
    replay.add_argument("corpus", type=Path)
    replay.add_argument("output", type=Path)
    compare = commands.add_parser("score")
    compare.add_argument("feed_name")
    compare.add_argument("oracle", type=Path)
    compare.add_argument("native", type=Path)
    compare.add_argument("--required", type=float, default=0.95)
    args = parser.parse_args()
    {"prepare": prepare, "fetch": fetch, "score": score}[args.command](args)


if __name__ == "__main__":
    main()
