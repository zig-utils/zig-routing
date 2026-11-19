#!/usr/bin/env python3
"""Generate deterministic legal-range and production costing profiles for gate A."""

import argparse
import collections
import json
import random


MODES = ("pedestrian", "bicycle")
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

INTEGERS = {
    "fixed_speed", "max_distance", "max_grade", "max_hiking_difficulty",
    "transit_start_end_max_distance", "transit_transfer_max_distance",
    "multimodal_start_end_max_distance",
}


def sampled(mode, rng):
    ranges = SHARED | (PEDESTRIAN if mode == "pedestrian" else BICYCLE)
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
        else:
            row["bicycle_type"] = ("road", "cross", "hybrid", "mountain")[index % 4]
        yield {"mode": mode, "options": row, "paths": []}


def production(corpus, rng, path_count):
    profiles = collections.defaultdict(list)
    for line in corpus:
        if not line.strip() or line.startswith("#"):
            continue
        endpoint, body = line.split("\t", 1)
        if endpoint != "/route":
            continue
        request = json.loads(body)
        mode = request["costing"]
        if mode not in MODES:
            continue
        options = request.get("costing_options", {}).get(mode, {})
        key = (mode, json.dumps(options, sort_keys=True))
        paths = profiles[key]
        if len(request["locations"]) == 2 and "date_time" not in request:
            request["directions_type"] = "none"
            paths.append(request)
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
    args = parser.parse_args()
    rng = random.Random(0x7A52C057)
    profiles = list(production(args.corpus, rng, args.paths_per_profile))
    if {p["mode"] for p in profiles} != set(MODES):
        parser.error("corpus must contain pedestrian and bicycle production profiles")
    for profile in profiles:
        print(json.dumps(profile, separators=(",", ":")))
    for mode in MODES:
        for profile in sampled(mode, rng):
            print(json.dumps(profile, separators=(",", ":")))


if __name__ == "__main__":
    main()
