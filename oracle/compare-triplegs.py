#!/usr/bin/env python3
"""Compare native trip-leg dumps with captured Valhalla 3.9.3 Api protobufs."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import struct


def decode(data):
    offset = 0

    def varint():
        nonlocal offset
        result = 0
        for shift in range(0, 70, 7):
            byte = data[offset]
            offset += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result
        raise ValueError("oversized varint")

    values = defaultdict(list)
    while offset < len(data):
        field, wire = divmod(varint(), 8)
        if wire == 0:
            value = varint()
        elif wire == 2:
            size = varint()
            value = data[offset : offset + size]
            if len(value) != size:
                raise ValueError("truncated protobuf field")
            offset += size
        elif wire in (1, 5):
            fmt = "<d" if wire == 1 else "<f"
            value = struct.unpack_from(fmt, data, offset)[0]
            offset += struct.calcsize(fmt)
        else:
            raise ValueError(f"unsupported wire type {wire}")
        values[field].append(value)
    return values


def get(record, field, default=0):
    return record[field][-1] if record[field] else default


def nested(record, field):
    return list(map(decode, record[field]))


def leg_records(blob):
    for trip in nested(decode(blob), 2):
        for route in nested(trip, 1):
            yield from nested(route, 1)


def direction_legs(blob):
    for directions in nested(decode(blob), 3):
        for route in nested(directions, 1):
            yield from nested(route, 1)


EDGE_FIELDS = {
    2: "length_km", 3: "speed", 4: "road_class", 5: "begin_heading", 6: "end_heading",
    7: "begin_shape_index", 8: "end_shape_index", 9: "traversability", 10: "use",
    11: "toll", 12: "unpaved", 13: "tunnel", 14: "bridge", 15: "roundabout",
    16: "internal_intersection", 17: "drive_on_left", 18: "surface", 20: "travel_mode",
    21: "vehicle_type", 27: "way_id", 28: "weighted_grade", 29: "max_upward_grade",
    30: "max_downward_grade", 31: "lane_count", 32: "cycle_lane", 33: "bicycle_network",
    34: "sidewalk", 35: "density", 36: "speed_limit", 37: "truck_speed", 38: "truck_route",
    40: "mean_elevation", 44: "default_speed", 46: "destination_only", 49: "source_along_edge",
    50: "target_along_edge", 51: "sac_scale", 52: "shoulder", 53: "indoor",
    58: "country_crossing", 59: "forward", 62: "level_precision", 65: "speed_type",
    66: "traffic_signal",
}
NODE_FIELDS = {3: "admin_index", 4: "type", 5: "fork", 11: "time_zone", 21: "traffic_signal"}
ADMIN_FIELDS = {1: "country_code", 2: "country_text", 3: "state_code", 4: "state_text"}
INTERSECTION_FIELDS = {
    1: "begin_heading", 2: "prev_name_consistency", 3: "curr_name_consistency",
    4: "driveability", 5: "cyclability", 6: "walkability", 7: "use", 8: "road_class", 9: "lane_count",
}
BOOL_FIELDS = {
    "toll", "unpaved", "tunnel", "bridge", "roundabout", "internal_intersection", "drive_on_left",
    "bicycle_network", "truck_route", "destination_only", "shoulder", "indoor", "country_crossing",
    "forward", "traffic_signal", "fork", "prev_name_consistency", "curr_name_consistency",
}
SIGN_GROUPS = (
    "exit_numbers", "exit_onto_streets", "exit_toward_locations", "exit_names",
    "guide_onto_streets", "guide_toward_locations", "junction_names", "guidance_view_junctions",
    "guidance_view_signboards",
)


class Comparison:
    def __init__(self, schema_dir):
        self.enums = defaultdict(set)
        for file in ("common.proto", "trip.proto"):
            text = (schema_dir / file).read_text()
            for name, number in re.findall(r"^\s*(\w+)\s*=\s*(\d+)\s*;", text, re.M):
                self.enums[name].add(int(number))
        self.counts = Counter()
        self.differences = Counter()

    def check(self, key, matches):
        if not matches:
            self.differences[key] += 1

    def fields(self, key, ours, donor, fields):
        for number, name in fields.items():
            value = ours[name]
            given = get(donor, number, b"" if isinstance(value, str) and value not in self.enums else 0)
            if name in BOOL_FIELDS:
                matches = type(value) is bool and value == bool(given)
            elif isinstance(value, str):
                matches = given in self.enums[value] if value in self.enums else value.encode() == given
            elif isinstance(given, int) and given >= 1 << 63 and value < 0:
                matches = value == given - (1 << 64)
            else:
                matches = type(value) is not bool and value == given
            self.check(f"{key}.{name}", matches)

    def names(self, key, ours, records):
        self.check(key, len(ours) == len(records))
        for name, record in zip(ours, records):
            self.check(key, name["value"].encode() == get(record, 1, b"") and
                       name["is_route_number"] == bool(get(record, 2)) and
                       get(record, 4) in self.enums[name["language_tag"]])
            value = name.get("pronunciation")
            donor = nested(record, 3)
            self.check(f"{key}.pronunciation", bool(value) == bool(donor))
            if value and donor:
                self.check(f"{key}.pronunciation", get(donor[0], 1) in self.enums[value["alphabet"]] and
                           get(donor[0], 2, b"") == value["value"].encode())

    def leg(self, ours, donor, metadata_only):
        nodes = ours["node"]
        other = nested(donor, 6)
        native_edges = [node["edge"] for node in nodes if "edge" in node]
        donor_edges = [edge for node in other for edge in nested(node, 1)]
        if [(edge["way_id"], edge["forward"]) for edge in native_edges] != [
            (get(edge, 27), bool(get(edge, 59))) for edge in donor_edges
        ]:
            self.counts["different_paths"] += 1
            return
        self.counts["matched_legs"] += 1
        self.counts["edges"] += len(native_edges)
        for edge, record in zip(native_edges, donor_edges):
            self.names("edge.name", edge["name"], nested(record, 1))
            if metadata_only:
                self.check("edge.turn_lanes", [row["directions_mask"] for row in edge["turn_lanes"]] ==
                           [get(row, 1) for row in nested(record, 42)])
                self.counts["edges_with_turn_lanes"] += bool(edge["turn_lanes"])
                self.counts["signed_edges"] += "sign" in edge
                signs = nested(record, 19)
                for field, group in enumerate(SIGN_GROUPS, 1):
                    ours_signs = [(row["text"].encode(), row["is_route_number"])
                                  for row in edge.get("sign", {}).get(group, [])]
                    donor_signs = [(get(row, 1, b""), bool(get(row, 2)))
                                   for row in (nested(signs[0], field) if signs else [])]
                    self.check(f"edge.sign.{group}", ours_signs == donor_signs)
            else:
                self.fields("edge", edge, record, EDGE_FIELDS)
        if metadata_only:
            return
        self.check("shape", ours["shape"].encode() == get(donor, 8, b""))
        self.check("node.count", len(nodes) == len(other))
        admins = nested(donor, 7)
        self.check("admin.count", len(ours["admin"]) == len(admins))
        for admin, record in zip(ours["admin"], admins):
            self.fields("admin", admin, record, ADMIN_FIELDS)
        for node, record in zip(nodes, other):
            self.fields("node", node, record, NODE_FIELDS)
            native_intersections = node["intersecting_edge"]
            donor_intersections = nested(record, 2)
            self.check("node.intersecting_edge.count", len(native_intersections) == len(donor_intersections))
            self.counts["intersecting_edges"] += len(native_intersections)
            for intersection, cross in zip(native_intersections, donor_intersections):
                self.fields("intersecting_edge", intersection, cross, INTERSECTION_FIELDS)
                self.names("intersecting_edge.name", intersection["name"], nested(cross, 21))
            for number, name in [(1, "elapsed_cost"), (2, "transition_cost")]:
                cost = nested(nested(record, 12)[0], number)
                self.fields(f"node.{name}", node["cost"][name], cost[0], {1: "seconds", 2: "cost"})


def maneuver_types(descriptors):
    schema = (descriptors / "directions.proto").read_text()
    block = re.search(r"message Maneuver\s*\{.*?enum Type\s*\{(.*?)\}", schema, re.S).group(1)
    return {int(number): name for name, number in re.findall(r"^\s*(\w+)\s*=\s*(\d+)\s*;", block, re.M)}


def compare_maneuvers(comparison, ours, donor, directions, result, types):
    native_nodes = ours["node"]
    donor_nodes = nested(donor, 6)
    native_edges = [node["edge"] for node in native_nodes if "edge" in node]
    donor_edges = [edge for node in donor_nodes for edge in nested(node, 1)]
    counts = comparison.counts
    if [(edge["way_id"], edge["forward"]) for edge in native_edges] != [
        (get(edge, 27), bool(get(edge, 59))) for edge in donor_edges
    ]:
        counts["different_paths"] += 1
        return
    records = nested(directions, 6)
    if len(records) < 2:
        comparison.check("directions.missing_maneuvers", False)
        return
    numbers = [get(record, 1) for record in records]
    supported = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15, 16}
    if not set(numbers).issubset(supported):
        counts["advanced_maneuvers"] += 1
        return
    if any(get(edge, 15) or get(edge, 16) or get(edge, 53) or
           get(edge, 10) in (1, 26, 33, 34, 41, 42) for edge in donor_edges):
        counts["advanced_edge_uses"] += 1
        return
    elapsed = nested(nested(donor_nodes[-1], 12)[0], 1)[0]
    cost = get(elapsed, 2)
    actual = native_nodes[-1]["cost"]["elapsed_cost"]["cost"]
    if abs(actual - cost) > abs(cost) * 0.001:
        counts["different_route_costs"] += 1
        return
    counts["matched_legs"] += 1
    steps = result.get("steps", [])
    type_match = [step["type"] for step in steps] == [types.get(number) for number in numbers]
    name_match = [[name["value"].encode() for name in step["street_names"]] for step in steps] == [
        [get(name, 1, b"") for name in nested(record, 3)] for record in records
    ]
    shape_match = ours["shape"].encode() == get(donor, 8, b"")
    summary = nested(directions, 5)[0]
    distance, time = get(summary, 1), get(summary, 2)
    length_match = abs(ours["summary"]["length"] - distance) <= distance * 0.005
    time_match = abs(ours["summary"]["time"] - time) <= time * 0.01
    comparison.check("maneuver.types", type_match)
    comparison.check("maneuver.names", name_match)
    comparison.check("shape", shape_match)
    comparison.check("distance", length_match)
    comparison.check("time", time_match)
    counts["gate_d_passes"] += type_match and name_match and shape_match and length_match and time_match


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("reference", type=Path, help="directory of numbered Api protobufs")
    parser.add_argument("schema", type=Path, help="Valhalla 3.9.3 proto/descriptors directory")
    parser.add_argument("--minimum-legs", type=int, default=1)
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--metadata-only", action="store_true",
                         help="compare names, signs and turn lane masks on independently built bundles")
    options.add_argument("--maneuvers", action="store_true",
                         help="score simple maneuver sequences on matching paths for Gate D")
    args = parser.parse_args()
    comparison = Comparison(args.schema)
    types = maneuver_types(args.schema) if args.maneuvers else {}
    with args.native.open() as rows:
        for line in rows:
            row = json.loads(line)
            if "failure" in row:
                comparison.check("native_route", False)
                continue
            path = args.reference / f"{row['index']}.bin"
            blob = path.read_bytes()
            reference = list(leg_records(blob))
            comparison.check("leg.count", len(row["legs"]) == len(reference))
            if args.maneuvers:
                directions = list(direction_legs(blob))
                comparison.check("directions.leg_count", len(row["legs"]) == len(directions))
                for ours, donor, direction, result in zip(row["legs"], reference, directions, row["maneuvers"]):
                    compare_maneuvers(comparison, ours, donor, direction, result, types)
            else:
                for ours, donor in zip(row["legs"], reference):
                    comparison.leg(ours, donor, args.metadata_only)
    print(json.dumps({"counts": comparison.counts, "differences": comparison.differences}, indent=2))
    if args.maneuvers:
        matched = comparison.counts["matched_legs"]
        structural = ("native_route", "leg.count", "directions.leg_count", "directions.missing_maneuvers")
        return int(matched < args.minimum_legs or comparison.counts["gate_d_passes"] * 100 < matched * 95 or
                   any(comparison.differences[key] for key in structural))
    return int(bool(comparison.differences) or comparison.counts["matched_legs"] < args.minimum_legs)


if __name__ == "__main__":
    raise SystemExit(main())
