#!/usr/bin/env python3
"""Generate timestamped synthetic traffic traces from the Utrecht attribute replay."""

import argparse
import json
import math
from pathlib import Path
import random

METRES_PER_DEGREE = 111_194.9
BASE_EPOCH = 1_767_484_800


def decode(shape):
    coordinate = [0, 0]
    axis = value = shift = 0
    points = []
    for char in shape:
        byte = ord(char) - 63
        value |= (byte & 31) << shift
        if byte & 32:
            shift += 5
            continue
        coordinate[axis] += ~(value >> 1) if value & 1 else value >> 1
        axis ^= 1
        value = shift = 0
        if axis == 0:
            points.append(tuple(part / 1e6 for part in coordinate))
    if axis or shift:
        raise ValueError("incomplete route shape")
    return points


def connected_runs(result):
    points = decode(result["shape"])
    start = end = None
    for edge in result["edges"]:
        first = edge["begin_shape_index"]
        if start is None or first != end:
            if start is not None:
                yield tuple(points[start:end + 1])
            start = first
        end = edge["end_shape_index"]
    if start is not None:
        yield tuple(points[start:end + 1])


def routes(replay):
    ordered = {}
    with replay.open() as source:
        for row in source:
            record = json.loads(row)
            status, result = record["native"]
            if record["variant"] != "default" or status != 200:
                continue
            for run in connected_runs(result):
                if len(run) >= 31:
                    ordered[run] = None
    return sorted(ordered, key=len, reverse=True)[:16]


def sample(route, epoch, perturbation, rng):
    shape = []
    previous = None
    for lat, lon in route:
        if previous is not None:
            scale = math.cos(math.radians((previous[0] + lat) / 2))
            metres = METRES_PER_DEGREE * math.hypot(previous[0] - lat, scale * (previous[1] - lon))
            epoch += max(0.001, metres * 3.6 / 50)
        previous = lat, lon
        if perturbation:
            scale = math.cos(math.radians(lat))
            lat += rng.uniform(-perturbation, perturbation) / METRES_PER_DEGREE
            lon += rng.uniform(-perturbation, perturbation) / (METRES_PER_DEGREE * scale)
        shape.append({"lat": round(lat, 7), "lon": round(lon, 7), "time": round(epoch, 6)})
    return {"shape": shape}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("replay", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--points", type=int, default=1_024_000)
    parser.add_argument("--perturb-metres", type=float, default=0)
    args = parser.parse_args()
    candidates = routes(args.replay)
    if not candidates or args.points < 1 or args.perturb_metres < 0:
        parser.error("expected connected replay routes and positive point count")
    rng = random.Random(204)
    points = traces = 0
    with args.output.open("w") as stream:
        while points < args.points:
            route = candidates[traces % len(candidates)]
            epoch = BASE_EPOCH + traces % 2016 * 300
            record = sample(route, epoch, args.perturb_metres, rng)
            print(json.dumps(record, separators=(",", ":")), file=stream)
            points += len(route)
            traces += 1
    print(f"{points} points in {traces} synthetic traces")


if __name__ == "__main__":
    main()
