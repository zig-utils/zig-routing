#!/usr/bin/env python3
"""Project Valhalla 3.9.3 tag results inside the pinned oracle container."""

import ctypes as c
import json
from pathlib import Path
import re
import struct
import sys


lua = c.CDLL("libluajit-5.1.so.2")
State = c.c_void_p
String = c.c_char_p
Int = c.c_int
Integer = c.c_ssize_t


def bind(name, result, *args):
    function = getattr(lua, name)
    function.restype = result
    function.argtypes = args
    return function


new_state = bind("luaL_newstate", State)
open_libs = bind("luaL_openlibs", None, State)
close = bind("lua_close", None, State)
load = bind("luaL_loadbuffer", Int, State, String, c.c_size_t, String)
call = bind("lua_pcall", Int, State, Int, Int, Int)
get_field = bind("lua_getfield", None, State, Int, String)
create_table = bind("lua_createtable", None, State, Int, Int)
push_string = bind("lua_pushlstring", None, State, String, c.c_size_t)
raw_set = bind("lua_rawset", None, State, Int)
push_integer = bind("lua_pushinteger", None, State, Integer)
to_integer = bind("lua_tointeger", Integer, State, Int)
to_string = bind("lua_tolstring", String, State, Int, c.c_void_p)
set_top = bind("lua_settop", None, State, Int)
GLOBALS_INDEX = -10002


def transform(state, kind, tags):
    get_field(state, GLOBALS_INDEX, b"ways_proc" if kind == "way" else b"nodes_proc")
    create_table(state, 0, len(tags))
    for tag in tags:
        key, value = tag["key"].encode(), tag["value"].encode()
        push_string(state, key, len(key))
        push_string(state, value, len(value))
        raw_set(state, -3)
    push_integer(state, len(tags))
    result_count = 4 if kind == "way" else 2
    if call(state, 2, result_count, 0):
        raise RuntimeError(to_string(state, -1, None))
    # Valhalla drops osm2pgsql's extra roads and polygons return values.
    set_top(state, 2)
    return to_integer(state, 1) == 0


def get(state, key):
    get_field(state, 2, key)
    result = to_string(state, -1, None)
    set_top(state, 2)
    return result


def step_count(raw):
    text = raw.get("step_count", "")
    if not re.fullmatch(r"[0-9]+", text):
        return None
    digits = text.lstrip("0")
    if len(digits) > 10:
        return None
    value = int(digits or "0")
    return value if value <= 0xFFFFFFFF else None


def mtb_scale(text):
    match = re.match(r"\+?(-?)([0-9]+)", text)
    if match is None:
        return None
    sign, digits = match.groups()
    digits = digits.lstrip("0")
    if len(digits) > 10 or (digits and sign == "-"):
        return None
    value = int(digits or "0")
    return value if value <= 0x7FFFFFFF else None


def option(raw, key, values):
    value = raw.get(key)
    return value if value in values else None


TACTILE = ("yes", "no", "partial", "incorrect")
VISIBILITY = ("excellent", "good", "intermediate", "bad", "horrible", "no")
AREA_KEYS = {"building", "landuse", "leisure", "natural"}

# Pinned graphconstants.h NodeType values for flags emitted by nodes_proc.
NODE_TYPES = (
    (b"border_control", 10),
    (b"toll_booth", 3),
    (b"cash_only_toll", 3),
    (b"toll_gantry", 11),
    (b"gate", 1),
    (b"bollard", 2),
    (b"sump_buster", 12),
    (b"building_entrance", 13),
    (b"elevator", 14),
)


def node_fields(state, raw):
    highway = get(state, b"highway")
    signals = {
        key: get(state, key.encode())
        for key in (
            "forward_signal", "backward_signal",
            "forward_stop", "backward_stop", "forward_yield", "backward_yield",
        )
    }
    access = int(get(state, b"access_mask"))
    node_type = next((value for key, value in NODE_TYPES if get(state, key) == b"true"), 0)
    if node_type == 0:
        if get(state, b"amenity") == b"parking":
            node_type = 8
        elif highway == b"motorway_junction":
            node_type = 9
    name = get(state, b"name")
    named = bool(name) and (
        get(state, b"junction") in (b"yes", b"named")
        or get(state, b"barrier") == b"toll_booth"
        or highway == b"toll_gantry"
    )
    attributes = {
        "node_type": node_type,
        "named_intersection": named,
        "traffic_signal": highway == b"traffic_signals",
        "stop_sign": highway == b"stop",
        "yield_sign": highway == b"give_way",
        **{key: value == b"true" for key, value in signals.items()},
        "minor": b"minor" in (get(state, b"stop"), get(state, b"give_way")),
        "direction": any(
            value is not None for key, value in signals.items() if not key.endswith("_signal")
        ),
        "tagged_access": get(state, b"tagged_access") == b"1",
        "private_access": get(state, b"private") == b"true",
        "cash_only_toll": node_type == 3 and get(state, b"cash_only_toll") == b"true",
        "tactile_paving": option(raw, "tactile_paving", TACTILE),
    }
    steps = step_count(raw)
    if access == 2047 and steps is None and not any(attributes.values()):
        return None
    return {"access": access, "step_count": steps, **attributes}


def raw_way_fields(raw):
    # These are carried from OSM tags and have no slot in Valhalla's OSMWay.
    speed = raw.get("maxspeed", "")
    return {
        "speed_zone": speed if re.fullmatch(r"[A-Za-z]{2}:[0-9A-Za-z_:-]+", speed) else None,
        "bridge_name": raw.get("bridge:name", ""),
        "mtb_scale": mtb_scale(raw.get("mtb:scale", "")),
        "mtb_uphill_scale": mtb_scale(raw.get("mtb:scale:uphill", "")),
        "icn": raw.get("icn") == "yes" or "icn_ref" in raw,
        "step_count": step_count(raw),
        "trail_visibility": option(raw, "trail_visibility", VISIBILITY),
        "tactile_paving": option(raw, "tactile_paving", TACTILE),
        "foot": raw.get("foot"),
    }


LIMITS = ("hazmat", "maxheight", "maxwidth", "maxlength", "maxweight", "maxaxleload", "maxaxles")


def f32(number):
    return struct.unpack("<f", struct.pack("<f", number))[0]


def motor_way_fields(state):
    limits = []
    for direction in ("both", "forward", "backward"):
        for kind in LIMITS if direction == "both" else LIMITS[:5]:
            key = kind if direction == "both" else f"{kind}_{direction}"
            raw = get(state, key.encode())
            if raw is None:
                continue
            value, exemption, _ = raw.partition(b"~")
            if kind == "hazmat":
                value = int(value == b"true")
            else:
                try:
                    value = f32(float(value))
                    if kind != "maxaxles":
                        value = f32(value * 100)
                except OverflowError:
                    continue
                # Ignore values outside the integer conversion's defined range.
                if not 0 <= value < 2 ** 64:
                    continue
                value = int(value)
            limits.append({
                "kind": kind, "direction": direction, "value": value,
                "except_destination": bool(exemption),
            })
    return {
        "truck_route": get(state, b"truck_route") == b"true",
        "hov3": get(state, b"hov_type") == b"HOV3",
        "toll": get(state, b"toll") == b"true",
        "motor_limits": limits,
    }


def parse_way_fields(rows):
    columns = next(rows).rstrip("\n").split("\t")
    if columns.pop(0) != "id":
        raise ValueError("Valhalla way projection is missing its id column")
    types = {
        "n": int,
        "b": {"0": False, "1": True}.__getitem__,
        "s": lambda text: bytes.fromhex(text).decode(),
    }
    fields = [(name, types[kind]) for kind, name in (column.split(":") for column in columns)]
    for row in rows:
        identifier, *values = row.rstrip("\n").split("\t")
        yield int(identifier), {
            key: decode(text) for (key, decode), text in zip(fields, values, strict=True)
        }


def dump(state, stream, rows):
    parsed = parse_way_fields(rows)
    for line in stream:
        item = json.loads(line)
        kind, identifier, tags = item["kind"], item["id"], item["tags"]
        try:
            kept = transform(state, kind, tags)
            raw = {tag["key"]: tag["value"] for tag in tags}
            if kind == "node":
                eligible = True
                fields = node_fields(state, raw) if kept else None
            else:
                eligible = item["shape"] != "short" and (
                    item["shape"] != "closed" or AREA_KEYS.isdisjoint(raw)
                )
                fields = None
                if kept and eligible:
                    record = next(parsed, None)
                    if record is None or record[0] != identifier:
                        found = record[0] if record else "end of stream"
                        raise ValueError(f"expected ParseWays record {identifier}, saw {found}")
                    fields = {**record[1], **raw_way_fields(raw), **motor_way_fields(state)}
            print(json.dumps({
                "kind": kind, "id": identifier, "eligible": eligible,
                "kept": kept, "attributes": fields,
            }, ensure_ascii=False, separators=(",", ":")))
        except Exception as error:
            raise RuntimeError(f"{kind} {identifier}: {error}") from error
        finally:
            set_top(state, 0)
    if next(parsed, None) is not None:
        raise ValueError("unmatched records remain in the Valhalla ParseWays output")


def main(graph, projection):
    state = new_state()
    if not state:
        raise MemoryError("luaL_newstate")
    try:
        open_libs(state)
        script = Path(graph).read_bytes()
        if load(state, script, len(script), b"graph.lua") or call(state, 0, 0, 0):
            raise RuntimeError(to_string(state, -1, None))
        with open(projection, encoding="utf-8") as rows:
            dump(state, sys.stdin, rows)
    finally:
        close(state)


if __name__ == "__main__":
    main(*sys.argv[1:])
