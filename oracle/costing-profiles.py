#!/usr/bin/env python3
"""Generate deterministic costing profiles and timed routes for gates A and B."""

import argparse
import collections
import json
import random


MODES = ("pedestrian", "bicycle")
MOTOR_MODES = ("auto", "bus", "taxi")
MOTORCYCLE_MODES = ("motorcycle", "motor_scooter")
PROFILES_PER_MODE = 64
PENALTY = (0, 43_200)
FACTOR = (0.1, 100_000)
PREFERENCE = (0, 1)

SHARED = {
    **dict.fromkeys(
        (
            "destination_only_penalty", "maneuver_penalty", "alley_penalty", "gate_cost",
            "gate_penalty", "private_access_penalty", "country_crossing_cost",
            "country_crossing_penalty", "ferry_cost", "service_penalty",
        ),
        PENALTY,
    ),
    **dict.fromkeys(
        (
            "use_ferry", "use_distance", "use_tracks", "use_living_streets", "use_lit",
            "use_curvature", "speed_penalty_factor",
        ),
        PREFERENCE,
    ),
    "service_factor": FACTOR,
    "closure_factor": (1, 10),
    "height": (0, 10),
    "width": (0, 10),
    "length": (0, 50),
    "weight": (0, 100),
    "fixed_speed": (0, 252),
}

PEDESTRIAN = {
    **dict.fromkeys(
        ("mode_factor", "walkway_factor", "sidewalk_factor", "alley_factor", "driveway_factor"),
        FACTOR,
    ),
    **dict.fromkeys(("step_penalty", "elevator_penalty", "bss_rent_cost", "bss_rent_penalty"), PENALTY),
    "walking_speed": (0.5, 25),
    "max_distance": (0, 100_000),
    "max_grade": (0, 90),
    "max_hiking_difficulty": (0, 6),
    "transit_start_end_max_distance": (0, 100_000),
    "transit_transfer_max_distance": (0, 50_000),
    "multimodal_start_end_max_distance": (0, 100_000),
    "use_hills": PREFERENCE,
}

BICYCLE = {
    **dict.fromkeys(("use_roads", "use_hills", "avoid_bad_surfaces"), PREFERENCE),
    **dict.fromkeys(("bss_return_cost", "bss_return_penalty"), PENALTY),
    "cycling_speed": (5, 60),
    "steps_factor": FACTOR,
}

MOTOR = {
    "alley_factor": FACTOR,
    **dict.fromkeys(("use_highways", "use_tolls", "use_rail_ferry"), PREFERENCE),
    **dict.fromkeys(("toll_booth_cost", "toll_booth_penalty", "rail_ferry_cost"), PENALTY),
    "restriction_probability": (0, 100),
    "top_speed": (10, 252),
}

TRUCK = {
    **dict.fromkeys(("use_highways", "use_tolls", "use_truck_route"), PREFERENCE),
    "top_speed": (10, 252),
    "axle_load": (0, 40),
    "axle_count": (2, 20),
    "low_class_penalty": PENALTY,
    "low_class_factor": FACTOR,
    "hgv_no_access_penalty": PENALTY,
}

MOTORCYCLE = {
    **dict.fromkeys(("use_highways", "use_tolls", "use_trails"), PREFERENCE),
    **dict.fromkeys(("toll_booth_cost", "toll_booth_penalty"), PENALTY),
    "top_speed": (10, 252),
}

MOTOR_SCOOTER = {
    **dict.fromkeys(("use_hills", "use_primary"), PREFERENCE),
    "top_speed": (20, 120),
}

INTEGERS = {
    "fixed_speed", "max_distance", "max_grade", "max_hiking_difficulty",
    "transit_start_end_max_distance", "transit_transfer_max_distance",
    "multimodal_start_end_max_distance", "restriction_probability", "top_speed", "axle_count",
}


def sampled(mode, rng):
    ranges = SHARED | {
        "pedestrian": PEDESTRIAN,
        "bicycle": BICYCLE,
        "truck": TRUCK,
        "motorcycle": MOTORCYCLE,
        "motor_scooter": MOTOR_SCOOTER,
    }.get(mode, MOTOR)
    if mode == "motor_scooter":
        # All grade-adjusted speeds must be in the oracle's table.
        ranges["fixed_speed"] = (0, 202)
    settings = [{} for _ in range(PROFILES_PER_MODE)]
    for option, (low, high) in ranges.items():
        # Stratify each option independently and always include both bounds.
        ranks = list(range(PROFILES_PER_MODE))
        rng.shuffle(ranks)
        for row, rank in zip(settings, ranks):
            value = low + (high - low) * rank / (PROFILES_PER_MODE - 1)
            row[option] = int(round(value)) if option in INTEGERS else round(value, 6)
    for index, row in enumerate(settings):
        row["shortest"] = index % 8 == 0
        row["exclude_unpaved"] = index % 13 == 0
        row["exclude_bridges"] = index % 17 == 0
        row["exclude_tunnels"] = index % 19 == 0
        row["exclude_highways"] = index % 23 == 0
        row["exclude_ferries"] = index % 29 == 0
        if mode == "pedestrian":
            row["type"] = ("foot", "wheelchair", "blind")[index % 3]
        elif mode == "bicycle":
            row["bicycle_type"] = ("road", "cross", "hybrid", "mountain")[index % 4]
        elif mode in ("truck", *MOTORCYCLE_MODES):
            if mode == "truck":
                row["hazmat"] = index % 2 == 0
            row["ignore_restrictions"] = index % 7 == 0
            row["ignore_oneways"] = index % 13 == 0
            row["ignore_access"] = index % 19 == 0
            row["ignore_closures"] = index % 23 == 0
            row["exclude_tolls"] = index % 29 == 0
        else:
            row["include_hov2"] = index % 3 == 0
            row["include_hov3"] = index % 3 == 1
            row["include_hot"] = index % 4 == 0
            row["ignore_restrictions"] = index % 7 == 0
            row["ignore_non_vehicular_restrictions"] = index % 11 == 0
            row["ignore_oneways"] = index % 13 == 0
            row["ignore_access"] = index % 19 == 0
            row["ignore_closures"] = index % 23 == 0
            row["exclude_tolls"] = index % 29 == 0
        yield {"mode": mode, "options": row, "paths": []}


def production(corpus, rng, path_count, modes):
    profiles = collections.defaultdict(list)
    for line in corpus:
        if not line.strip() or line.startswith("#"):
            continue
        endpoint, body = line.split("\t", 1)
        if endpoint != "/route":
            continue
        request = json.loads(body)
        mode = request["costing"]
        if mode not in modes and not (mode == "auto" and modes in (("truck",), MOTORCYCLE_MODES)):
            continue
        options = request.get("costing_options", {}).get(mode, {})
        for variant in modes if mode == "auto" else (mode,):
            key = (variant, json.dumps(options, sort_keys=True))
            paths = profiles[key]
            if len(request["locations"]) == 2 and "date_time" not in request:
                route = {**request, "directions_type": "none"}
                if variant != mode:
                    route.update(costing=variant, costing_options={variant: options})
                paths.append(route)
    for (mode, options), paths in sorted(profiles.items()):
        yield {
            "mode": mode,
            "options": json.loads(options),
            "paths": rng.sample(paths, min(path_count, len(paths))),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=argparse.FileType())
    parser.add_argument("--paths-per-profile", type=int, default=8)
    family = parser.add_mutually_exclusive_group()
    family.add_argument("--motor", action="store_true", help="sample auto, bus, taxi and HOV options")
    family.add_argument("--truck", action="store_true", help="sample truck costing options and dimensions")
    family.add_argument("--motorcycle", action="store_true", help="sample motorcycle and motor scooter options")
    family.add_argument("--timed", action="store_true", help="generate timed auto route cases")
    args = parser.parse_args()
    rng = random.Random(0x7A52C057)
    if args.timed:
        profiles = list(production(args.corpus, rng, args.paths_per_profile, ("auto",)))
        if not any(profile["paths"] for profile in profiles):
            parser.error("corpus must provide two-location auto routes")
        for profile in profiles:
            profile["paths"] = [
                {**path, "date_time": {"type": kind, "value": "2026-11-09T" + time}}
                for path in profile["paths"]
                for kind, time in ((1, "06:45"), (1, "18:58"), (2, "19:05"), (3, "12:00"))
            ]
            print(json.dumps(profile, separators=(",", ":")))
        return
    modes = ("truck",) if args.truck else MOTORCYCLE_MODES if args.motorcycle else MOTOR_MODES if args.motor else MODES
    profiles = list(production(args.corpus, rng, args.paths_per_profile, modes))
    if {p["mode"] for p in profiles} != set(modes):
        parser.error(f"corpus must provide production profiles for {', '.join(modes)}")
    for profile in profiles:
        print(json.dumps(profile, separators=(",", ":")))
    for mode in modes:
        if args.motor:
            for options in ({}, {"include_hov2": True}, {"include_hov3": True, "include_hot": True}):
                print(json.dumps({"mode": mode, "options": options, "paths": []}, separators=(",", ":")))
        if args.truck:
            for options in (
                {},
                {"low_class_factor": 0.1, "use_tolls": 1},
                {"hazmat": True, "use_truck_route": 1},
                {"hgv_no_access_penalty": 30, "top_speed": 70},
            ):
                print(json.dumps({"mode": mode, "options": options, "paths": []}, separators=(",", ":")))
        if args.motorcycle:
            variants = ({}, {"use_trails": 1, "use_curvature": 1}, {"use_trails": 0.2, "use_tolls": 1}) if mode == "motorcycle" else (
                {}, {"use_hills": 0, "use_primary": 0}, {"use_hills": 1, "use_primary": 1, "top_speed": 120},
            )
            for options in variants:
                print(json.dumps({"mode": mode, "options": options, "paths": []}, separators=(",", ":")))
        for profile in sampled(mode, rng):
            print(json.dumps(profile, separators=(",", ":")))


if __name__ == "__main__":
    main()
